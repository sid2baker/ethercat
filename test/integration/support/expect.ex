defmodule EtherCAT.Integration.Expect do
  @moduledoc false

  import ExUnit.Assertions

  alias EtherCAT.Integration.Trace
  alias EtherCAT.IntegrationSupport.SimulatorRing

  @default_attempts 20
  @sleep_ms 20

  @spec eventually((-> term()), keyword()) :: term()
  def eventually(fun, opts \\ []) when is_function(fun, 0) do
    attempts = Keyword.get(opts, :attempts, @default_attempts)
    trace = Keyword.get(opts, :trace)
    label = Keyword.get(opts, :label, "eventually assertion")

    eventually_attempt(fun, attempts, trace, label)
  end

  @spec stays((-> term()), keyword()) :: :ok
  def stays(fun, opts \\ []) when is_function(fun, 0) do
    attempts = Keyword.get(opts, :attempts, 5)

    stays_attempt(fun, attempts)
  end

  @spec master_state(atom() | [atom(), ...]) :: :ok
  def master_state(expected) do
    assert {:ok, actual} = EtherCAT.state()

    assert match_expected?(actual, expected),
           "expected master state #{inspect(expected)}, got #{inspect(actual)}"

    :ok
  end

  @spec domain(atom(), keyword() | map()) :: :ok
  def domain(domain_id, expectations) do
    assert {:ok, info} = EtherCAT.domain_info(domain_id)
    assert_map_subset(info, expectations, "domain #{inspect(domain_id)}")
    :ok
  end

  @spec slave(atom(), keyword() | map()) :: :ok
  def slave(slave_name, expectations) do
    assert {:ok, info} = EtherCAT.slave_info(slave_name)
    assert_map_subset(info, expectations, "slave #{inspect(slave_name)}")
    :ok
  end

  @spec slave_fault(atom(), term()) :: :ok
  def slave_fault(slave_name, expected_fault) do
    actual_fault = SimulatorRing.fault_for(slave_name)

    assert actual_fault == expected_fault,
           "expected fault for #{inspect(slave_name)} to be #{inspect(expected_fault)}, got #{inspect(actual_fault)}"

    :ok
  end

  @spec simulator_queue_empty() :: :ok
  def simulator_queue_empty do
    assert {:ok, info} = EtherCAT.Simulator.info()

    assert %{next_fault: nil, pending_faults: [], scheduled_faults: []} = info

    udp_info = Map.get(info, :udp, %{next_fault: nil, pending_faults: []})

    assert %{next_fault: nil, pending_faults: []} = udp_info

    :ok
  end

  @spec signal(atom(), atom(), keyword() | map()) :: :ok
  def signal(slave_name, signal_name, expectations) do
    assert {:ok, info} = EtherCAT.Simulator.signal_snapshot(slave_name, signal_name)
    assert_map_subset(info, expectations, "signal #{inspect(slave_name)}.#{inspect(signal_name)}")
    :ok
  end

  @spec trace_event(Trace.t(), [atom()], keyword()) :: :ok
  def trace_event(%Trace{} = trace, event_name, opts \\ []) when is_list(event_name) do
    measurements = Keyword.get(opts, :measurements, %{})
    metadata = Keyword.get(opts, :metadata, %{})

    case Enum.find(
           Trace.snapshot(trace),
           &trace_event_match?(&1, event_name, measurements, metadata)
         ) do
      nil ->
        flunk("""
        expected trace to contain #{inspect(event_name)}
        measurements: #{inspect(Map.new(measurements))}
        metadata: #{inspect(Map.new(metadata))}

        #{Trace.format(trace, limit: 200)}
        """)

      _entry ->
        :ok
    end
  end

  @spec trace_note(Trace.t(), String.t(), keyword()) :: :ok
  def trace_note(%Trace{} = trace, label, opts \\ []) when is_binary(label) do
    metadata = Keyword.get(opts, :metadata, %{})

    case Enum.find(Trace.snapshot(trace), &trace_note_match?(&1, label, metadata)) do
      nil ->
        flunk("""
        expected trace to contain note #{inspect(label)}
        metadata: #{inspect(Map.new(metadata))}

        #{Trace.format(trace, limit: 200)}
        """)

      _entry ->
        :ok
    end
  end

  @type trace_sequence_step ::
          {:event, [atom()], keyword()}
          | {:note, String.t(), keyword()}

  @spec trace_sequence(Trace.t(), [trace_sequence_step(), ...]) :: :ok
  def trace_sequence(%Trace{} = trace, steps) when is_list(steps) and steps != [] do
    entries = Trace.snapshot(trace)

    case find_trace_sequence(entries, steps, 0) do
      :ok ->
        :ok

      {:error, failed_step, matched_count} ->
        flunk("""
        expected trace to contain ordered sequence step #{matched_count + 1}:
        #{inspect(failed_step)}

        #{Trace.format(trace, limit: 200)}
        """)
    end
  end

  defp eventually_attempt(fun, 0, trace, label) do
    fun.()
  rescue
    error in [ExUnit.AssertionError, MatchError] ->
      maybe_dump_trace(trace, label)
      reraise error, __STACKTRACE__
  end

  defp eventually_attempt(fun, attempts, trace, label) do
    fun.()
  rescue
    _error in [ExUnit.AssertionError, MatchError] ->
      Process.sleep(@sleep_ms)
      eventually_attempt(fun, attempts - 1, trace, label)
  else
    result ->
      result
  end

  defp stays_attempt(_fun, 0), do: :ok

  defp stays_attempt(fun, attempts) do
    fun.()
    Process.sleep(@sleep_ms)
    stays_attempt(fun, attempts - 1)
  end

  defp assert_map_subset(actual, expectations, label) do
    Enum.each(Map.new(expectations), fn {key, expected} ->
      assert Map.has_key?(actual, key),
             "#{label} missing key #{inspect(key)} in #{inspect(actual)}"

      actual_value = Map.fetch!(actual, key)

      assert match_expected?(actual_value, expected),
             "#{label} expected #{inspect(key)} to match #{inspect(expected)}, got #{inspect(actual_value)}"
    end)
  end

  defp match_expected?(actual, expected) when is_function(expected, 1), do: expected.(actual)
  defp match_expected?(actual, expected) when is_list(expected), do: actual in expected
  defp match_expected?(actual, expected), do: actual == expected

  defp maybe_dump_trace(nil, _label), do: :ok

  defp maybe_dump_trace(trace, label) do
    IO.puts(:stderr, Trace.format(trace, title: "Trace for #{label}", limit: 200))
  end

  defp trace_event_match?(
         %{
           kind: :telemetry,
           event: event,
           measurements: actual_measurements,
           metadata: actual_metadata
         },
         event_name,
         measurements,
         metadata
       )
       when event == event_name do
    map_matches?(actual_measurements, measurements) and map_matches?(actual_metadata, metadata)
  end

  defp trace_event_match?(_entry, _event_name, _measurements, _metadata), do: false

  defp trace_note_match?(
         %{kind: :note, label: actual_label, metadata: actual_metadata},
         label,
         metadata
       )
       when actual_label == label do
    map_matches?(actual_metadata, metadata)
  end

  defp trace_note_match?(_entry, _label, _metadata), do: false

  defp find_trace_sequence(_entries, [], _matched_count), do: :ok

  defp find_trace_sequence(entries, [step | remaining_steps], matched_count) do
    case Enum.find_index(entries, &trace_sequence_match?(&1, step)) do
      nil ->
        {:error, step, matched_count}

      index ->
        next_entries = Enum.drop(entries, index + 1)
        find_trace_sequence(next_entries, remaining_steps, matched_count + 1)
    end
  end

  defp trace_sequence_match?(entry, {:event, event_name, opts}) do
    measurements = Keyword.get(opts, :measurements, %{})
    metadata = Keyword.get(opts, :metadata, %{})
    trace_event_match?(entry, event_name, measurements, metadata)
  end

  defp trace_sequence_match?(entry, {:note, label, opts}) do
    metadata = Keyword.get(opts, :metadata, %{})
    trace_note_match?(entry, label, metadata)
  end

  defp map_matches?(actual, expectations) do
    Enum.all?(Map.new(expectations), fn {key, expected} ->
      Map.has_key?(actual, key) and match_expected?(Map.fetch!(actual, key), expected)
    end)
  end
end
