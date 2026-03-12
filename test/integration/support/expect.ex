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
    actual = EtherCAT.state()

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
    assert {:ok, %{next_fault: nil, pending_faults: [], scheduled_faults: []}} =
             EtherCAT.Simulator.info()

    :ok
  end

  @spec signal(atom(), atom(), keyword() | map()) :: :ok
  def signal(slave_name, signal_name, expectations) do
    assert {:ok, info} = EtherCAT.Simulator.signal_snapshot(slave_name, signal_name)
    assert_map_subset(info, expectations, "signal #{inspect(slave_name)}.#{inspect(signal_name)}")
    :ok
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
    IO.puts(:stderr, Trace.format(trace, title: "Trace for #{label}"))
  end
end
