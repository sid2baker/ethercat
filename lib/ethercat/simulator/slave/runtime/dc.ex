defmodule EtherCAT.Simulator.Slave.Runtime.DC do
  @moduledoc false

  alias EtherCAT.Slave.ESC.Registers
  alias EtherCAT.Simulator.Slave.Runtime.Device

  @ethercat_epoch_offset_ns 946_684_800_000_000_000
  @default_speed_counter_start 0x1000
  @default_sync_diff_ns 250
  @dc_range_start 0x0900
  @dc_range_end 0x09D0

  @type t :: %{
          clock_offset_ns: integer(),
          system_time_offset_ns: integer(),
          system_time_delay_ns: non_neg_integer(),
          speed_counter_start: non_neg_integer(),
          sync_diff_ns: non_neg_integer(),
          latched_port_times: %{optional(0 | 1 | 2 | 3) => non_neg_integer()},
          latched_ecat_time_ns: non_neg_integer()
        }

  @spec new(non_neg_integer()) :: t()
  def new(position) when is_integer(position) and position >= 0 do
    clock_offset_ns = position * 1_000
    local_time_ns = current_local_time_ns(clock_offset_ns)

    %{
      clock_offset_ns: clock_offset_ns,
      system_time_offset_ns: 0,
      system_time_delay_ns: 0,
      speed_counter_start: @default_speed_counter_start,
      sync_diff_ns: @default_sync_diff_ns,
      latched_port_times: port_times(local_time_ns, 0),
      latched_ecat_time_ns: local_time_ns
    }
  end

  @spec handles_range?(non_neg_integer(), non_neg_integer()) :: boolean()
  def handles_range?(offset, length)
      when is_integer(offset) and offset >= 0 and is_integer(length) and length > 0 do
    range_end = offset + length
    not (range_end <= @dc_range_start or offset >= @dc_range_end)
  end

  @spec read_register(Device.t(), non_neg_integer(), non_neg_integer()) :: binary()
  def read_register(%Device{} = slave, offset, length) do
    slave
    |> refreshed_memory()
    |> binary_part(offset, length)
  end

  @spec write_register(Device.t(), non_neg_integer(), binary()) :: Device.t()
  def write_register(%Device{dc_state: dc_state} = slave, offset, data) do
    updated_state =
      case {offset, data} do
        {0x0900, <<_::32>>} ->
          local_time_ns = current_local_time_ns(dc_state.clock_offset_ns)

          %{
            dc_state
            | latched_ecat_time_ns: local_time_ns,
              latched_port_times: port_times(local_time_ns, dc_state.system_time_delay_ns)
          }

        {0x0910, <<0::32>>} ->
          %{
            dc_state
            | system_time_offset_ns: 0,
              sync_diff_ns: @default_sync_diff_ns
          }

        {0x0920, <<offset_ns::64-signed-little>>} ->
          %{
            dc_state
            | system_time_offset_ns: offset_ns,
              sync_diff_ns: min(dc_state.sync_diff_ns, 50)
          }

        {0x0928, <<delay_ns::32-little>>} ->
          %{dc_state | system_time_delay_ns: delay_ns}

        {0x0930, <<speed_counter_start::16-little>>} ->
          %{dc_state | speed_counter_start: speed_counter_start, sync_diff_ns: 0}

        _other ->
          dc_state
      end

    slave
    |> write_memory(offset, data)
    |> Map.put(:dc_state, updated_state)
    |> refresh_memory()
  end

  @spec refresh_memory(Device.t()) :: Device.t()
  def refresh_memory(%Device{dc_state: nil} = slave), do: slave

  def refresh_memory(%Device{} = slave) do
    %{slave | memory: refreshed_memory(slave)}
  end

  defp refreshed_memory(%Device{memory: memory, dc_state: dc_state}) do
    local_time_ns = current_local_time_ns(dc_state.clock_offset_ns)
    system_time_ns = local_time_ns + dc_state.system_time_offset_ns

    memory
    |> put_binary(
      offset(Registers.dc_recv_time(0)),
      <<Map.fetch!(dc_state.latched_port_times, 0)::32-little>>
    )
    |> put_binary(
      offset(Registers.dc_recv_time(1)),
      <<Map.fetch!(dc_state.latched_port_times, 1)::32-little>>
    )
    |> put_binary(
      offset(Registers.dc_recv_time(2)),
      <<Map.fetch!(dc_state.latched_port_times, 2)::32-little>>
    )
    |> put_binary(
      offset(Registers.dc_recv_time(3)),
      <<Map.fetch!(dc_state.latched_port_times, 3)::32-little>>
    )
    |> put_binary(
      offset(Registers.dc_recv_time_ecat()),
      <<dc_state.latched_ecat_time_ns::64-little>>
    )
    |> put_binary(offset(Registers.dc_system_time()), <<system_time_ns::64-little>>)
    |> put_binary(
      offset(Registers.dc_system_time_offset()),
      <<dc_state.system_time_offset_ns::64-signed-little>>
    )
    |> put_binary(
      offset(Registers.dc_system_time_delay()),
      <<dc_state.system_time_delay_ns::32-little>>
    )
    |> put_binary(offset(Registers.dc_system_time_diff()), <<dc_state.sync_diff_ns::32-little>>)
    |> put_binary(
      offset(Registers.dc_speed_counter_start()),
      <<dc_state.speed_counter_start::16-little>>
    )
  end

  defp current_local_time_ns(clock_offset_ns) do
    System.os_time(:nanosecond) - @ethercat_epoch_offset_ns + clock_offset_ns
  end

  defp port_times(local_time_ns, system_time_delay_ns) do
    %{
      0 => truncate_32(local_time_ns + 40 + system_time_delay_ns),
      1 => truncate_32(local_time_ns + 80 + system_time_delay_ns),
      2 => truncate_32(local_time_ns + 120 + system_time_delay_ns),
      3 => truncate_32(local_time_ns + 160 + system_time_delay_ns)
    }
  end

  defp truncate_32(value) when is_integer(value) do
    rem(value, 0x1_0000_0000)
  end

  defp write_memory(%{memory: memory} = slave, offset, data) do
    %{slave | memory: put_binary(memory, offset, data)}
  end

  defp put_binary(binary, offset, value) do
    prefix = binary_part(binary, 0, offset)
    suffix_offset = offset + byte_size(value)
    suffix = binary_part(binary, suffix_offset, byte_size(binary) - suffix_offset)
    prefix <> value <> suffix
  end

  defp offset({offset, _length}), do: offset
end
