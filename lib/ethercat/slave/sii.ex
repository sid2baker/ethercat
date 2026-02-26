defmodule EtherCAT.Slave.SII do
  @moduledoc """
  SII EEPROM interface for EtherCAT slaves.

  Provides read, write, and reload operations against the slave EEPROM
  via ESC registers 0x0500–0x050F. All protocol details (busy-polling,
  error-bit clearing, missing-ACK retries) are handled internally.

  Word addressing is used throughout — the EEPROM uses 16-bit words.

  ## Examples

      alias EtherCAT.Slave.SII

      # Read vendor ID (words 0x08–0x09)
      {:ok, <<vendor_id::32-little>>} = SII.read(link, 0x1000, 0x08, 2)

      # Write configured station alias (word 0x04)
      :ok = SII.write(link, 0x1000, 0x04, <<0x00, 0x10>>)

      # Reload ESC configuration from EEPROM
      :ok = SII.reload(link, 0x1000)
  """

  alias EtherCAT.Link
  alias EtherCAT.Link.Transaction
  alias EtherCAT.Slave.Registers

  # -- Command values (written to bits [10:8] of control register) ------------

  @cmd_nop    <<0, 0>>
  @cmd_read   <<0, 1>>
  @cmd_write  <<1, 2>>
  @cmd_reload <<0, 4>>

  # @cmd_read    = 0x0100 → <<0x00, 0x01>> little-endian
  # @cmd_write   = 0x0201 → <<0x01, 0x02>> little-endian (write-enable + write cmd)
  # @cmd_reload  = 0x0400 → <<0x00, 0x04>> little-endian

  # -- Protocol-level limits --------------------------------------------------

  @max_ack_retries 10
  @busy_poll_limit 1000
  @busy_poll_interval_ms 1

  # Category headers start at word 0x0040
  @category_start 0x0040

  # -- Public API -------------------------------------------------------------

  @doc """
  Read the valid SII contents by walking the category structure.

  Reads the fixed header (words 0x00–0x3F), then follows category
  headers starting at word 0x40 until the end marker (type 0xFFFF).

  Returns `{:ok, binary}` or `{:error, reason}`.
  """
  @spec dump(pid(), non_neg_integer()) :: {:ok, binary()} | {:error, atom()}
  def dump(link, station) do
    with {:ok, end_word} <- find_end(link, station) do
      read(link, station, 0x0000, end_word)
    end
  end

  @doc """
  Read `word_count` words from the EEPROM starting at `word_address`.

  Returns `{:ok, binary}` with `word_count * 2` bytes, or `{:error, reason}`.
  """
  @spec read(pid(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          {:ok, binary()} | {:error, atom()}
  def read(link, station, word_address, word_count) do
    with {:ok, chunk_words} <- read_data_register_size(link, station) do
      read_chunks(link, station, word_address, word_count, chunk_words, [])
    end
  end

  @doc """
  Write `data` to the EEPROM starting at `word_address`.

  `data` must be a binary whose byte size is a multiple of 2 (whole words).
  Each word is written individually per the SII protocol.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec write(pid(), non_neg_integer(), non_neg_integer(), binary()) ::
          :ok | {:error, atom()}
  def write(link, station, word_address, data) when rem(byte_size(data), 2) == 0 do
    write_words(link, station, word_address, data)
  end

  @doc """
  Reload ESC configuration from EEPROM.

  The slave re-reads configuration areas A (and B if present) and applies
  them to its registers. Note: configured station alias and enhanced link
  detection bits are only loaded at power-on, not on reload.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec reload(pid(), non_neg_integer()) :: :ok | {:error, atom()}
  def reload(link, station) do
    with :ok <- ensure_ready(link, station),
         :ok <- write_reg(link, station, Registers.eeprom_control(), @cmd_reload),
         :ok <- wait_busy(link, station) do
      check_errors(link, station)
    end
  end

  # -- Read internals ---------------------------------------------------------

  # Walk category headers from word 0x40 to find the end of valid SII data.
  # Each category: [type::16-little, size::16-little, data::size*2 bytes]
  # End marker: type == 0xFFFF
  defp find_end(link, station), do: find_end(link, station, @category_start)

  defp find_end(link, station, addr) do
    case read(link, station, addr, 2) do
      {:ok, <<0xFFFF::16-little, _::16>>} ->
        # End marker — include it in the dump
        {:ok, addr + 1}

      {:ok, <<_type::16-little, size::16-little>>} ->
        find_end(link, station, addr + 2 + size)

      {:error, _} = err ->
        err
    end
  end

  defp read_chunks(_link, _station, _addr, 0, _chunk_words, acc) do
    {:ok, :erlang.iolist_to_binary(Enum.reverse(acc))}
  end

  defp read_chunks(link, station, addr, remaining, chunk_words, acc) do
    with {:ok, chunk_data} <- read_one(link, station, addr, chunk_words) do
      take = min(remaining, chunk_words)
      <<used::binary-size(take * 2), _::binary>> = chunk_data

      read_chunks(
        link,
        station,
        addr + chunk_words,
        remaining - take,
        chunk_words,
        [used | acc]
      )
    end
  end

  defp read_one(link, station, word_address, chunk_words) do
    retry_on_ack(@max_ack_retries, fn ->
      with :ok <- ensure_ready(link, station),
           :ok <- write_reg(link, station, Registers.eeprom_address(), <<word_address::32-little>>),
           :ok <- write_reg(link, station, Registers.eeprom_control(), @cmd_read),
           :ok <- wait_busy(link, station),
           :ok <- check_errors(link, station) do
        read_reg(link, station, Registers.eeprom_data(), chunk_words * 2)
      end
    end)
  end

  # -- Write internals --------------------------------------------------------

  defp write_words(_link, _station, _addr, <<>>), do: :ok

  defp write_words(link, station, addr, <<word::binary-size(2), rest::binary>>) do
    with :ok <- write_one(link, station, addr, word) do
      write_words(link, station, addr + 1, rest)
    end
  end

  defp write_one(link, station, word_address, <<_::binary-size(2)>> = word) do
    retry_on_ack(@max_ack_retries, fn ->
      with :ok <- ensure_ready(link, station),
           :ok <- write_reg(link, station, Registers.eeprom_address(), <<word_address::32-little>>),
           :ok <- write_reg(link, station, Registers.eeprom_data(), word),
           # Write-enable (bit 0) + write command (bits 10:8) in the same frame
           :ok <- write_reg(link, station, Registers.eeprom_control(), @cmd_write),
           :ok <- wait_busy(link, station) do
        check_errors(link, station)
      end
    end)
  end

  # -- Protocol helpers -------------------------------------------------------

  defp ensure_ready(link, station) do
    with :ok <- wait_busy(link, station) do
      clear_errors_if_needed(link, station)
    end
  end

  defp wait_busy(link, station), do: wait_busy(link, station, @busy_poll_limit)

  defp wait_busy(_link, _station, 0), do: {:error, :busy_timeout}

  defp wait_busy(link, station, remaining) do
    case read_reg(link, station, Registers.eeprom_control()) do
      {:ok, <<_lo, _hi_rest::5, busy::1, _::2>>} when busy == 0 ->
        :ok

      {:ok, _} ->
        Process.sleep(@busy_poll_interval_ms)
        wait_busy(link, station, remaining - 1)

      {:error, _} = err ->
        err
    end
  end

  defp clear_errors_if_needed(link, station) do
    case read_reg(link, station, Registers.eeprom_control()) do
      {:ok, <<_lo, hi::binary-size(1)>>} ->
        if has_errors?(hi) do
          write_reg(link, station, Registers.eeprom_control(), @cmd_nop)
        else
          :ok
        end

      {:error, _} = err ->
        err
    end
  end

  defp check_errors(link, station) do
    case read_reg(link, station, Registers.eeprom_control()) do
      {:ok, <<_lo, hi::binary-size(1)>>} -> check_error_bits(hi)
      {:error, _} = err -> err
    end
  end

  # High byte of control/status register (0x0503), laid out MSB first:
  #
  #   bit 15: busy
  #   bit 14: error write enable
  #   bit 13: error acknowledge/command
  #   bit 12: error device information
  #   bit 11: error checksum
  #   bit 10:8: command (3 bits)
  #
  # As a byte: <<busy::1, wr_en_err::1, ack_err::1, dev_err::1, csum_err::1, cmd::3>>

  defp check_error_bits(<<_busy::1, 1::1, _::6>>), do: {:error, :write_enable_error}
  defp check_error_bits(<<_busy::1, _::1, 1::1, _::5>>), do: {:error, :acknowledge_error}
  defp check_error_bits(<<_busy::1, _::2, 1::1, _::4>>), do: {:error, :device_info_error}
  defp check_error_bits(<<_busy::1, _::3, 1::1, _::3>>), do: {:error, :checksum_error}
  defp check_error_bits(_), do: :ok

  defp has_errors?(<<_busy::1, we::1, ack::1, dev::1, csum::1, _cmd::3>>) do
    we + ack + dev + csum > 0
  end

  defp has_errors?(_), do: false

  defp retry_on_ack(0, _fun), do: {:error, :acknowledge_error}

  defp retry_on_ack(remaining, fun) do
    case fun.() do
      {:error, :acknowledge_error} ->
        Process.sleep(@busy_poll_interval_ms)
        retry_on_ack(remaining - 1, fun)

      other ->
        other
    end
  end

  # Data register size: bit 6 of control/status.
  # 0 = 4 bytes (2 words), 1 = 8 bytes (4 words)
  defp read_data_register_size(link, station) do
    case read_reg(link, station, Registers.eeprom_control()) do
      {:ok, <<_lo_rest::7, size_bit::1, _hi>>} ->
        if size_bit == 1, do: {:ok, 4}, else: {:ok, 2}

      {:error, _} = err ->
        err
    end
  end

  # -- Register I/O -----------------------------------------------------------

  # Accepts a {addr, size} tuple from Registers for fixed-size registers,
  # or a bare address + explicit size for runtime-sized registers (eeprom_data).
  defp read_reg(link, station, {addr, size}) do
    case Link.transaction(link, &Transaction.fprd(&1, station, addr, size)) do
      {:ok, [%{data: data, wkc: wkc}]} when wkc > 0 -> {:ok, data}
      {:ok, [%{wkc: 0}]} -> {:error, :no_response}
      {:error, _} = err -> err
    end
  end

  defp read_reg(link, station, addr, size) when is_integer(addr) do
    case Link.transaction(link, &Transaction.fprd(&1, station, addr, size)) do
      {:ok, [%{data: data, wkc: wkc}]} when wkc > 0 -> {:ok, data}
      {:ok, [%{wkc: 0}]} -> {:error, :no_response}
      {:error, _} = err -> err
    end
  end

  defp write_reg(link, station, {addr, _size}, data) do
    case Link.transaction(link, &Transaction.fpwr(&1, station, addr, data)) do
      {:ok, [%{wkc: wkc}]} when wkc > 0 -> :ok
      {:ok, [%{wkc: 0}]} -> {:error, :no_response}
      {:error, _} = err -> err
    end
  end

  defp write_reg(link, station, addr, data) when is_integer(addr) do
    case Link.transaction(link, &Transaction.fpwr(&1, station, addr, data)) do
      {:ok, [%{wkc: wkc}]} when wkc > 0 -> :ok
      {:ok, [%{wkc: 0}]} -> {:error, :no_response}
      {:error, _} = err -> err
    end
  end
end
