defmodule EtherCAT.Slave.CoE do
  @moduledoc """
  CANopen over EtherCAT (CoE) mailbox protocol — expedited SDO downloads.

  Implements the acyclic mailbox channel for writing SDO objects to a slave
  in PreOp state. Only expedited SDO download (≤ 4 bytes per object) is
  supported — sufficient for all slave configuration objects.

  ## Protocol outline

      Master                           Slave
        │── FPWR → SM0 (recv mailbox) ──►│
        │                                │  (PDI processes request)
        │◄── FPRD ← SM1 (send mailbox) ──│
        │   (poll SM1 status bit 3 first)│

  Mailbox frame = 6-byte mailbox header + 2-byte CoE header + 8-byte SDO body (16 bytes).

  ## SM control bytes

  - SM0 (recv, master writes): `ctrl = 0x26`
    - bits[1:0] = 0b10  mailbox mode
    - bits[3:2] = 0b01  ECAT writes / PDI reads
    - bit[5]    = 1     AL event IRQ
  - SM1 (send, master reads): `ctrl = 0x22`
    - bits[1:0] = 0b10  mailbox mode
    - bits[3:2] = 0b00  ECAT reads / PDI writes
    - bit[5]    = 1     AL event IRQ
  """

  alias EtherCAT.Link
  alias EtherCAT.Link.Transaction
  alias EtherCAT.Slave.Registers

  @poll_limit 1000
  @poll_interval_ms 1

  # -- Public API -------------------------------------------------------------

  @doc """
  Perform an expedited SDO download (write) for an object ≤ 4 bytes.

  - `mailbox_config` — `%{recv_offset, recv_size, send_offset, send_size}` from SII
  - `index`          — CoE object index (e.g. `0x8000`)
  - `subindex`       — CoE subindex (e.g. `0x19`)
  - `value`          — integer value to write
  - `size`           — byte size: `1`, `2`, or `4`

  Returns `:ok` or `{:error, reason}`.
  """
  @spec write_sdo(pid(), non_neg_integer(), map(), integer(), integer(), integer(), 1 | 2 | 4) ::
          :ok | {:error, term()}
  def write_sdo(link, station, mailbox_config, index, subindex, value, size) do
    frame = build_request(index, subindex, value, size)
    # Mailbox SM0 only closes (signals PDI) when the last byte of recv_size is written.
    # Pad the frame to recv_size so SM0 fully closes and the slave processes the request.
    padded = frame <> :binary.copy(<<0>>, mailbox_config.recv_size - byte_size(frame))

    with :ok <- write_mailbox(link, station, mailbox_config.recv_offset, padded),
         :ok <- wait_response(link, station),
         {:ok, response} <- read_mailbox(link, station, mailbox_config.send_offset, mailbox_config.send_size) do
      validate_response(response, index, subindex)
    end
  end

  # -- Frame builder ----------------------------------------------------------

  # SDO command bytes for expedited download with size indicator set:
  #   0x2F = 1 byte  (e = 1, s = 1, n = 3 → 0b0010_1111)
  #   0x2B = 2 bytes (e = 1, s = 1, n = 2 → 0b0010_1011)
  #   0x27 = 3 bytes (e = 1, s = 1, n = 1 → 0b0010_0111)
  #   0x23 = 4 bytes (e = 1, s = 1, n = 0 → 0b0010_0011)
  defp sdo_command(1), do: 0x2F
  defp sdo_command(2), do: 0x2B
  defp sdo_command(4), do: 0x23

  defp build_request(index, subindex, value, size) do
    cmd = sdo_command(size)

    # Mailbox header: length=10 (CoE hdr 2 + SDO 8), address=0, channel/prio=0, type=CoE(3)
    # CoE header: number=0, service=2 (SDO request) in bits [15:12]
    <<10::16-little, 0::16, 0::8, 0x03::8,
      0x00, 0x20,
      cmd::8, index::16-little, subindex::8, value::32-little>>
  end

  # -- Transport helpers -------------------------------------------------------

  defp write_mailbox(link, station, recv_offset, frame) do
    case Link.transaction(link, &Transaction.fpwr(&1, station, {recv_offset, frame})) do
      {:ok, [%{wkc: wkc}]} when wkc > 0 -> :ok
      {:ok, [%{wkc: 0}]} -> {:error, :no_response}
      {:error, _} = err -> err
    end
  end

  defp wait_response(link, station), do: wait_response(link, station, @poll_limit)

  defp wait_response(_link, _station, 0), do: {:error, :response_timeout}

  defp wait_response(link, station, remaining) do
    case Link.transaction(link, &Transaction.fprd(&1, station, Registers.sm_status(1))) do
      {:ok, [%{data: <<status::8>>, wkc: wkc}]} when wkc > 0 ->
        case <<status::8>> do
          <<_::4, 1::1, _::3>> ->
            # bit[3] set = mailbox full = response ready
            :ok

          _ ->
            Process.sleep(@poll_interval_ms)
            wait_response(link, station, remaining - 1)
        end

      {:ok, [%{wkc: 0}]} ->
        {:error, :no_response}

      {:error, _} = err ->
        err
    end
  end

  defp read_mailbox(link, station, send_offset, send_size) do
    case Link.transaction(link, &Transaction.fprd(&1, station, {send_offset, send_size})) do
      {:ok, [%{data: data, wkc: wkc}]} when wkc > 0 -> {:ok, data}
      {:ok, [%{wkc: 0}]} -> {:error, :no_response}
      {:error, _} = err -> err
    end
  end

  # -- Response validation ----------------------------------------------------

  # Mailbox header is 6 bytes, CoE header is 2 bytes, SDO command at byte 8.
  # SDO download response command = 0x60 (success).
  # SDO abort transfer command    = 0x80 (abort code at bytes 12–15).

  defp validate_response(<<_mbox_hdr::binary-size(6), _coe_hdr::binary-size(2), 0x60::8, _::binary>>, _idx, _sub) do
    :ok
  end

  defp validate_response(
         <<_::binary-size(6), _::binary-size(2), 0x80::8, _idx_echo::16-little, _sub_echo::8,
           abort_code::32-little, _::binary>>,
         index,
         subindex
       ) do
    {:error, {:sdo_abort, index, subindex, abort_code}}
  end

  defp validate_response(response, index, subindex) do
    {:error, {:unexpected_response, index, subindex, response}}
  end
end
