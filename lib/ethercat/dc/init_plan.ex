defmodule EtherCAT.DC.InitStep do
  @moduledoc false

  @type t :: %__MODULE__{
          station: non_neg_integer(),
          delay_ns: non_neg_integer(),
          offset_ns: integer(),
          speed_counter_start: non_neg_integer()
        }

  @enforce_keys [:station, :delay_ns, :offset_ns, :speed_counter_start]
  defstruct [:station, :delay_ns, :offset_ns, :speed_counter_start]
end

defmodule EtherCAT.DC.InitPlan do
  @moduledoc false

  alias EtherCAT.DC.InitStep
  alias EtherCAT.DC.Snapshot

  @type t :: %__MODULE__{
          ref_station: non_neg_integer(),
          master_time_ns: integer(),
          steps: [InitStep.t()]
        }

  defstruct [:ref_station, :master_time_ns, :steps]

  @spec build([Snapshot.t()], integer()) :: {:ok, t()} | {:error, term()}
  def build(snapshots, master_time_ns) when is_list(snapshots) do
    dc_snapshots = Enum.filter(snapshots, &Snapshot.dc_capable?/1)

    case dc_snapshots do
      [] ->
        {:error, :no_dc_capable_slave}

      [%Snapshot{station: ref_station} = ref_snapshot | rest] ->
        with {:ok, ref_time_ns} <- fetch_ecat_time(ref_snapshot),
             {:ok, ref_speed_counter_start} <- fetch_speed_counter_start(ref_snapshot) do
          ref_offset_ns = master_time_ns - ref_time_ns

          steps =
            rest
            |> Enum.reduce_while(
              {:ok,
               [
                 %InitStep{
                   station: ref_station,
                   delay_ns: 0,
                   offset_ns: ref_offset_ns,
                   speed_counter_start: ref_speed_counter_start
                 }
               ], ref_snapshot, 0},
              fn snapshot, {:ok, acc, previous, cumulative_delay_ns} ->
                case build_step(
                       snapshot,
                       previous,
                       cumulative_delay_ns,
                       ref_time_ns,
                       ref_offset_ns
                     ) do
                  {:ok, step} ->
                    {:cont, {:ok, [step | acc], snapshot, step.delay_ns}}

                  {:error, _} = err ->
                    {:halt, err}
                end
              end
            )

          case steps do
            {:ok, steps_rev, _last_snapshot, _last_delay_ns} ->
              {:ok,
               %__MODULE__{
                 ref_station: ref_station,
                 master_time_ns: master_time_ns,
                 steps: Enum.reverse(steps_rev)
               }}

            {:error, _} = err ->
              err
          end
        end
    end
  end

  defp build_step(snapshot, previous, cumulative_delay_ns, ref_time_ns, ref_offset_ns) do
    with {:ok, ecat_time_ns} <- fetch_ecat_time(snapshot),
         {:ok, speed_counter_start} <- fetch_speed_counter_start(snapshot) do
      hop_delay_ns = linear_hop_delay(previous, snapshot)
      delay_ns = cumulative_delay_ns + hop_delay_ns

      {:ok,
       %InitStep{
         station: snapshot.station,
         delay_ns: delay_ns,
         offset_ns: ref_time_ns - ecat_time_ns + ref_offset_ns,
         speed_counter_start: speed_counter_start
       }}
    end
  end

  defp fetch_ecat_time(%Snapshot{station: station, ecat_time_ns: nil}),
    do: {:error, {:missing_ecat_time, station}}

  defp fetch_ecat_time(%Snapshot{ecat_time_ns: ecat_time_ns}), do: {:ok, ecat_time_ns}

  defp fetch_speed_counter_start(%Snapshot{station: station, speed_counter_start: nil}),
    do: {:error, {:missing_speed_counter_start, station}}

  defp fetch_speed_counter_start(%Snapshot{speed_counter_start: speed_counter_start}),
    do: {:ok, speed_counter_start}

  defp linear_hop_delay(%Snapshot{span_ns: previous_span_ns}, %Snapshot{span_ns: current_span_ns})
       when previous_span_ns > current_span_ns,
       do: div(previous_span_ns - current_span_ns, 2)

  defp linear_hop_delay(_previous, _current), do: 0
end
