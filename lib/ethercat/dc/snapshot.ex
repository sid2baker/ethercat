defmodule EtherCAT.DC.Snapshot do
  @moduledoc false

  @ordered_ports [0, 3, 1, 2]
  @time_wrap 0x1_0000_0000
  @half_wrap div(@time_wrap, 2)

  @type port_time_map :: %{optional(0 | 1 | 2 | 3) => non_neg_integer() | nil}

  @type t :: %__MODULE__{
          station: non_neg_integer(),
          active_ports: [0 | 1 | 2 | 3],
          port_times: port_time_map(),
          entry_port: 0 | 1 | 2 | 3 | nil,
          return_port: 0 | 1 | 2 | 3 | nil,
          span_ns: non_neg_integer(),
          ecat_time_ns: non_neg_integer() | nil,
          speed_counter_start: non_neg_integer() | nil
        }

  defstruct [
    :station,
    :active_ports,
    :port_times,
    :entry_port,
    :return_port,
    :span_ns,
    :ecat_time_ns,
    :speed_counter_start
  ]

  @spec new(
          non_neg_integer(),
          binary(),
          port_time_map(),
          non_neg_integer() | nil,
          non_neg_integer() | nil
        ) :: t()
  def new(station, dl_status, port_times, ecat_time_ns, speed_counter_start) do
    active_ports = active_ports(dl_status)
    timestamps = active_timestamps(active_ports, port_times)
    {entry_port, entry_time, return_port, return_time} = boundary_ports(timestamps)

    %__MODULE__{
      station: station,
      active_ports: active_ports,
      port_times: port_times,
      entry_port: entry_port,
      return_port: return_port,
      span_ns: receive_span(entry_time, return_time),
      ecat_time_ns: ecat_time_ns,
      speed_counter_start: speed_counter_start
    }
  end

  @spec dc_capable?(t()) :: boolean()
  def dc_capable?(%__MODULE__{ecat_time_ns: nil}), do: false

  def dc_capable?(%__MODULE__{ecat_time_ns: 0, port_times: port_times}) do
    Enum.any?(port_times, fn
      {_port, time} when is_integer(time) and time > 0 -> true
      _ -> false
    end)
  end

  def dc_capable?(%__MODULE__{}), do: true

  @spec active_ports(binary()) :: [0 | 1 | 2 | 3]
  def active_ports(<<dl_low, dl_high>>) do
    <<phy3::1, phy2::1, phy1::1, phy0::1, _::4>> = <<dl_low>>

    <<comm3::1, loop3::1, comm2::1, loop2::1, comm1::1, loop1::1, comm0::1, loop0::1>> =
      <<dl_high>>

    port_statuses =
      [
        {0, %{phy: phy0, loop: loop0, comm: comm0}},
        {1, %{phy: phy1, loop: loop1, comm: comm1}},
        {2, %{phy: phy2, loop: loop2, comm: comm2}},
        {3, %{phy: phy3, loop: loop3, comm: comm3}}
      ]
      |> Map.new()

    Enum.filter(@ordered_ports, fn port ->
      port_active?(Map.fetch!(port_statuses, port))
    end)
  end

  defp port_active?(%{comm: 1}), do: true
  defp port_active?(%{phy: 1, loop: 0}), do: true
  defp port_active?(_), do: false

  defp active_timestamps(active_ports, port_times) do
    active_ports
    |> Enum.map(fn port -> {port, Map.get(port_times, port)} end)
    |> Enum.filter(fn
      {_port, time} when is_integer(time) -> true
      _ -> false
    end)
  end

  defp boundary_ports([]), do: {nil, nil, nil, nil}
  defp boundary_ports([{port, time}]), do: {port, time, port, time}

  defp boundary_ports(timestamps) do
    {entry_port, entry_time} = Enum.min_by(timestamps, fn {_port, time} -> time end)
    {return_port, return_time} = Enum.max_by(timestamps, fn {_port, time} -> time end)

    if return_time - entry_time > @half_wrap do
      {return_port, return_time, entry_port, entry_time}
    else
      {entry_port, entry_time, return_port, return_time}
    end
  end

  defp receive_span(nil, _), do: 0
  defp receive_span(_, nil), do: 0
  defp receive_span(start_time, end_time) when end_time >= start_time, do: end_time - start_time
  defp receive_span(start_time, end_time), do: @time_wrap - start_time + end_time
end
