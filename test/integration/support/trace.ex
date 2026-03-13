defmodule EtherCAT.Integration.Trace do
  @moduledoc false

  defstruct [:handler_id, :agent, :started_at_ms]

  @type t :: %__MODULE__{
          handler_id: String.t(),
          agent: pid(),
          started_at_ms: integer()
        }

  @spec start_capture(keyword()) :: t()
  def start_capture(_opts \\ []) do
    started_at_ms = System.monotonic_time(:millisecond)
    {:ok, agent} = Agent.start_link(fn -> [] end)

    trace = %__MODULE__{
      handler_id: "ethercat-integration-trace-#{System.unique_integer([:positive, :monotonic])}",
      agent: agent,
      started_at_ms: started_at_ms
    }

    :ok =
      :telemetry.attach_many(
        trace.handler_id,
        EtherCAT.Telemetry.events(),
        &__MODULE__.handle_event/4,
        trace
      )

    note(trace, "trace started")
    trace
  end

  @spec stop(t()) :: :ok
  def stop(%__MODULE__{} = trace) do
    :telemetry.detach(trace.handler_id)

    if Process.alive?(trace.agent) do
      Agent.stop(trace.agent)
    end

    :ok
  end

  @spec note(t(), String.t(), map()) :: :ok
  def note(%__MODULE__{} = trace, label, metadata \\ %{}) when is_binary(label) do
    append(trace, %{kind: :note, label: label, metadata: metadata})
    :ok
  end

  @spec snapshot(t()) :: [map()]
  def snapshot(%__MODULE__{} = trace) do
    trace.agent
    |> Agent.get(&Enum.reverse/1)
  end

  @spec format(t(), keyword()) :: String.t()
  def format(%__MODULE__{} = trace, opts \\ []) do
    title = Keyword.get(opts, :title, "Integration trace")
    limit = Keyword.get(opts, :limit)
    entries = snapshot(trace)
    visible_entries = maybe_limit_entries(entries, limit)

    header =
      case {limit, length(entries) > length(visible_entries)} do
        {limit, true} when is_integer(limit) -> "[showing last #{limit} trace entries]"
        _other -> nil
      end

    formatted_entries =
      visible_entries
      |> Enum.map(&format_entry/1)
      |> Enum.join("\n")

    [title, header, formatted_entries]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  @spec handle_event([atom()], map(), map(), t()) :: :ok
  def handle_event(event, measurements, metadata, %__MODULE__{} = trace) do
    append(trace, %{
      kind: :telemetry,
      event: event,
      measurements: measurements,
      metadata: metadata
    })

    :ok
  end

  defp append(%__MODULE__{} = trace, entry) do
    event = Map.put(entry, :at_ms, System.monotonic_time(:millisecond) - trace.started_at_ms)
    Agent.cast(trace.agent, fn entries -> [event | entries] end)
  end

  defp maybe_limit_entries(entries, nil), do: entries

  defp maybe_limit_entries(entries, limit) when is_integer(limit) and limit > 0 do
    Enum.take(entries, -limit)
  end

  defp format_entry(%{kind: :note, at_ms: at_ms, label: label, metadata: metadata}) do
    metadata_suffix =
      case metadata do
        map when map_size(map) == 0 -> ""
        map -> " " <> inspect(map)
      end

    "[t+#{at_ms}ms] #{label}#{metadata_suffix}"
  end

  defp format_entry(%{
         kind: :telemetry,
         at_ms: at_ms,
         event: event,
         measurements: measurements,
         metadata: metadata
       }) do
    "[t+#{at_ms}ms] " <> describe_event(event, measurements, metadata)
  end

  defp describe_event([:ethercat, :master, :state, :changed], _measurements, metadata) do
    "master #{inspect(metadata.from)} -> #{inspect(metadata.to)}"
  end

  defp describe_event([:ethercat, :master, :slave_fault, :changed], _measurements, metadata) do
    "master slave fault #{metadata.slave} #{inspect(metadata.from)} -> #{inspect(metadata.to)}"
  end

  defp describe_event([:ethercat, :slave, :down], _measurements, metadata) do
    "slave #{metadata.slave} down"
  end

  defp describe_event([:ethercat, :slave, :health, :fault], measurements, metadata) do
    "slave #{metadata.slave} health fault al_state=#{measurements.al_state} error_code=#{measurements.error_code}"
  end

  defp describe_event([:ethercat, :domain, :cycle, :missed], _measurements, metadata) do
    "domain #{metadata.domain} missed cycle: #{inspect(metadata.reason)}"
  end

  defp describe_event([:ethercat, :domain, :stopped], _measurements, metadata) do
    "domain #{metadata.domain} stopped: #{inspect(metadata.reason)}"
  end

  defp describe_event([:ethercat, :bus, :frame, :dropped], _measurements, metadata) do
    "frame dropped: #{inspect(metadata.reason)}"
  end

  defp describe_event([:ethercat, :dc, :lock, :changed], _measurements, metadata) do
    "dc lock #{inspect(metadata.from)} -> #{inspect(metadata.to)}"
  end

  defp describe_event(event, measurements, metadata) do
    "#{Enum.join(event, ".")} #{inspect(measurements)} #{inspect(metadata)}"
  end
end
