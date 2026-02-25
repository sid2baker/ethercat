defmodule EtherCAT.IO do
  @moduledoc """
  Cyclic process data exchange for EtherCAT slaves.

  Two-step operation:

  1. `configure/2` — write SM and FMMU registers to each slave (call once, in preop).
     Returns a `t:layout/0` describing the logical process image.

  2. `cycle/3` — send one LRW datagram covering the whole process image.
     Outputs are written in; inputs are read back out.

  ## Layout

  The process image is a contiguous logical address space. Each slave with
  process data contributes a slice:

      %{
        image_size: 4,
        outputs: [%{station: 0x1002, log_offset: 0, size: 2}],
        inputs:  [%{station: 0x1001, log_offset: 2, size: 2}]
      }

  ## SM/FMMU profiles

  Slave-specific SM and FMMU configurations are keyed by `product_code` in the
  application environment:

      config :ethercat, :io_profiles, %{
        0x07113052 => %{...},   # EL1809
        0x0AF93052 => %{...}    # EL2809
      }

  If no profile is found for a slave, it is skipped (e.g. couplers).
  """

  alias EtherCAT.{Command, Link, Slave}

  @type layout :: %{
          image_size: non_neg_integer(),
          outputs: [slice()],
          inputs: [slice()]
        }

  @type slice :: %{station: non_neg_integer(), log_offset: non_neg_integer(), size: pos_integer()}

  # Built-in profiles for known Beckhoff I/O terminals.
  # Each entry describes:
  #   sms:   list of {sm_index, start_addr, len, ctrl} to write
  #   fmmus: list of {fmmu_index, phys_addr, size, type} — log_offset assigned at configure time
  #   role:  :input | :output  (determines where in the image this slave sits)
  #   size:  process data size in bytes
  @builtin_profiles %{
    # EL1809 — 16-channel digital input
    0x07113052 => %{
      role: :input,
      size: 2,
      sms: [{0, 0x1000, 2, 0x20}],
      fmmus: [{0, 0x1000, 2, :read}]
    },
    # EL2809 — 16-channel digital output
    0x0AF93052 => %{
      role: :output,
      size: 2,
      sms: [{0, 0x0F00, 1, 0x44}, {1, 0x0F01, 1, 0x44}],
      fmmus: [{0, 0x0F00, 2, :write}]
    }
  }

  # -- Public API ------------------------------------------------------------

  @doc """
  Configure SM and FMMU registers for all slaves and build the process image layout.

  `slaves` is the `[{station, pid}]` list from `Master.slaves/0`.
  Typically called after `go_operational/0`; SM/FMMU writes are accepted in any state.
  """
  @spec configure(pid(), [{non_neg_integer(), pid()}]) :: {:ok, layout()} | {:error, term()}
  def configure(link, slaves) do
    profiles = Map.merge(@builtin_profiles, Application.get_env(:ethercat, :io_profiles, %{}))

    # Assign logical offsets: outputs first, then inputs
    {outputs, inputs, image_size} = build_image_map(slaves, profiles)

    with :ok <- configure_all(link, slaves, profiles, outputs, inputs) do
      {:ok, %{image_size: image_size, outputs: outputs, inputs: inputs}}
    end
  end

  @doc """
  Run one cyclic process image exchange.

  Writes `outputs` into the image, sends a single LRW datagram, returns `inputs`.

  `outputs` is `%{station => binary()}`. Stations not in the map get zeros.
  Returns `{:ok, %{station => binary()}}` with one entry per input slave.
  """
  @spec cycle(pid(), layout(), %{non_neg_integer() => binary()}) ::
          {:ok, %{non_neg_integer() => binary()}} | {:error, term()}
  def cycle(link, %{image_size: size, outputs: out_slices, inputs: in_slices}, outputs) do
    image = build_image(size, out_slices, outputs)

    case Link.transact(link, [Command.lrw(0x0000, image)]) do
      {:ok, [%{data: response}]} ->
        inputs = extract_inputs(response, in_slices)
        {:ok, inputs}

      {:error, _} = err ->
        err
    end
  end

  # -- Image assembly --------------------------------------------------------

  defp build_image_map(slaves, profiles) do
    stations = Enum.map(slaves, fn {station, _pid} -> station end)

    {outputs, out_offset} =
      Enum.flat_map_reduce(stations, 0, fn station, offset ->
        case profile_for(station, :output, profiles) do
          nil -> {[], offset}
          p -> {[%{station: station, log_offset: offset, size: p.size}], offset + p.size}
        end
      end)

    {inputs, total} =
      Enum.flat_map_reduce(stations, out_offset, fn station, offset ->
        case profile_for(station, :input, profiles) do
          nil -> {[], offset}
          p -> {[%{station: station, log_offset: offset, size: p.size}], offset + p.size}
        end
      end)

    {outputs, inputs, total}
  end

  defp profile_for(station, role, profiles) do
    case Slave.identity(station) do
      %{product_code: pc} ->
        case Map.get(profiles, pc) do
          %{role: ^role} = p -> p
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp build_image(size, out_slices, outputs) do
    image = :binary.copy(<<0>>, size)

    Enum.reduce(out_slices, image, fn %{station: s, log_offset: off, size: n}, acc ->
      data = Map.get(outputs, s, :binary.copy(<<0>>, n))
      # Pad or truncate to expected size
      data = binary_pad(data, n)
      <<before::binary-size(off), _::binary-size(n), rest::binary>> = acc
      <<before::binary, data::binary, rest::binary>>
    end)
  end

  defp extract_inputs(image, in_slices) do
    Map.new(in_slices, fn %{station: s, log_offset: off, size: n} ->
      <<_::binary-size(off), data::binary-size(n), _::binary>> = image
      {s, data}
    end)
  end

  defp binary_pad(data, size) when byte_size(data) >= size, do: binary_part(data, 0, size)
  defp binary_pad(data, size), do: data <> :binary.copy(<<0>>, size - byte_size(data))

  # -- SM / FMMU configuration -----------------------------------------------

  defp configure_all(link, slaves, profiles, out_slices, in_slices) do
    all_slices = out_slices ++ in_slices
    offset_map = Map.new(all_slices, fn %{station: s, log_offset: off} -> {s, off} end)

    Enum.reduce_while(slaves, :ok, fn {station, _pid}, :ok ->
      case configure_slave(link, station, profiles, offset_map) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp configure_slave(link, station, profiles, offset_map) do
    case Slave.identity(station) do
      %{product_code: pc} ->
        case Map.get(profiles, pc) do
          nil ->
            :ok

          %{sms: sms, fmmus: fmmus} ->
            log_offset = Map.get(offset_map, station, 0)

            with :ok <- write_sms(link, station, sms),
                 :ok <- write_fmmus(link, station, fmmus, log_offset) do
              :ok
            end
        end

      _ ->
        :ok
    end
  end

  defp write_sms(link, station, sms) do
    Enum.reduce_while(sms, :ok, fn {idx, start, len, ctrl}, :ok ->
      reg = sm_reg(start, len, ctrl)
      offset = 0x0800 + idx * 8

      case write_reg(link, station, offset, reg) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp write_fmmus(link, station, fmmus, base_log_offset) do
    Enum.reduce_while(fmmus, :ok, fn {idx, phys, size, dir}, :ok ->
      type = if dir == :read, do: 0x01, else: 0x02
      reg = fmmu_reg(base_log_offset, size, phys, type)
      offset = 0x0600 + idx * 16

      case write_reg(link, station, offset, reg) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  # SM register: §8 Table 25
  # <<start::16-le, len::16-le, ctrl::8, status=0::8, activate=1::8, pdi=0::8>>
  defp sm_reg(start, len, ctrl) do
    <<start::16-little, len::16-little, ctrl::8, 0::8, 0x01::8, 0::8>>
  end

  # FMMU register: §7 Table 24
  # <<log::32-le, size::16-le, log_start_bit=0::8, log_stop_bit=7::8,
  #   phys::16-le, phys_start_bit=0::8, type::8, activate=1::8, reserved::24>>
  defp fmmu_reg(log, size, phys, type) do
    <<log::32-little, size::16-little, 0::8, 7::8, phys::16-little, 0::8, type::8, 0x01::8,
      0::24>>
  end

  defp write_reg(link, station, offset, data) do
    case Link.transact(link, [Command.fpwr(station, offset, data)]) do
      {:ok, [%{wkc: 0}]} -> {:error, :no_response}
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end
end
