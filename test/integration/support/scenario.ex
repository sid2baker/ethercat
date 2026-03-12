defmodule EtherCAT.Integration.Scenario do
  @moduledoc false

  import ExUnit.Assertions

  alias EtherCAT.Integration.Expect
  alias EtherCAT.Integration.Trace
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault

  defstruct steps: [], trace?: false

  @type context :: %{assigns: map(), trace: Trace.t() | nil, teardowns: pid()}
  @type t :: %__MODULE__{steps: [step()], trace?: boolean()}
  @type step :: {:act, String.t(), (context() -> term())}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec trace(t()) :: t()
  def trace(%__MODULE__{} = scenario), do: %{scenario | trace?: true}

  @spec act(t(), String.t(), (context() -> term())) :: t()
  def act(%__MODULE__{} = scenario, label, fun) when is_binary(label) and is_function(fun, 1) do
    append_step(scenario, {:act, label, fun})
  end

  @spec inject_fault(t(), Fault.t() | EtherCAT.Simulator.fault()) :: t()
  def inject_fault(%__MODULE__{} = scenario, fault) do
    label = "inject fault: #{Fault.describe(fault)}"

    act(scenario, label, fn _ctx ->
      assert :ok = Simulator.inject_fault(fault)
    end)
  end

  @spec clear_faults(t()) :: t()
  def clear_faults(%__MODULE__{} = scenario) do
    act(scenario, "clear simulator faults", fn _ctx ->
      assert :ok = Simulator.clear_faults()
    end)
  end

  @spec inject_fault_on_event(
          t(),
          [atom()],
          Fault.t() | EtherCAT.Simulator.fault(),
          keyword()
        ) :: t()
  def inject_fault_on_event(%__MODULE__{} = scenario, event_name, fault, opts \\ [])
      when is_list(event_name) do
    event_label = Enum.join(event_name, ".")
    label = "arm fault on #{event_label}: #{Fault.describe(fault)}"

    act(scenario, label, fn %{teardowns: teardowns, trace: trace} = ctx ->
      metadata = Keyword.get(opts, :metadata, %{})
      measurements = Keyword.get(opts, :measurements, %{})
      handler_id = "ethercat-scenario-trigger-#{System.unique_integer([:positive, :monotonic])}"

      :ok =
        :telemetry.attach(
          handler_id,
          event_name,
          &__MODULE__.handle_trigger_event/4,
          %{
            event_name: event_name,
            measurements: Map.new(measurements),
            metadata: Map.new(metadata),
            fault: fault,
            trace: trace,
            handler_id: handler_id
          }
        )

      register_teardown(teardowns, fn -> :telemetry.detach(handler_id) end)
      ctx
    end)
  end

  @spec capture(t(), atom(), (context() -> term())) :: t()
  def capture(%__MODULE__{} = scenario, key, fun) when is_atom(key) and is_function(fun, 1) do
    act(scenario, "capture #{inspect(key)}", fn %{assigns: assigns} = ctx ->
      value = fun.(ctx)
      %{ctx | assigns: Map.put(assigns, key, value)}
    end)
  end

  @spec expect_eventually(t(), String.t(), (context() -> term()), keyword()) :: t()
  def expect_eventually(%__MODULE__{} = scenario, label, fun, opts \\ [])
      when is_binary(label) and is_function(fun, 1) do
    act(scenario, label, fn %{trace: trace} = ctx ->
      Expect.eventually(fn -> fun.(ctx) end, Keyword.merge(opts, trace: trace, label: label))
    end)
  end

  @spec run(t()) :: :ok
  def run(%__MODULE__{} = scenario) do
    trace = if scenario.trace?, do: Trace.start_capture(), else: nil
    {:ok, teardowns} = Agent.start_link(fn -> [] end)
    ctx = %{assigns: %{}, trace: trace, teardowns: teardowns}

    try do
      Enum.reduce(scenario.steps, ctx, &run_step/2)
      :ok
    rescue
      error ->
        maybe_dump_trace(trace)
        reraise error, __STACKTRACE__
    after
      run_teardowns(teardowns)
      Agent.stop(teardowns)
      if trace, do: Trace.stop(trace)
    end
  end

  @doc false
  def handle_trigger_event(event, measurements, metadata, config) do
    if telemetry_match?(event, measurements, metadata, config) do
      :telemetry.detach(config.handler_id)

      spawn(fn ->
        maybe_note_trace(
          config.trace,
          "telemetry trigger matched",
          %{event: event, metadata: metadata, fault: Fault.describe(config.fault)}
        )

        case Simulator.inject_fault(config.fault) do
          :ok ->
            maybe_note_trace(
              config.trace,
              "telemetry-triggered fault injected",
              %{event: event, fault: Fault.describe(config.fault)}
            )

          {:error, reason} ->
            maybe_note_trace(
              config.trace,
              "telemetry-triggered fault injection failed",
              %{event: event, fault: Fault.describe(config.fault), reason: reason}
            )
        end
      end)
    end

    :ok
  end

  defp append_step(%__MODULE__{steps: steps} = scenario, step),
    do: %{scenario | steps: steps ++ [step]}

  defp run_step({:act, label, fun}, %{trace: trace} = ctx) do
    if trace, do: Trace.note(trace, label)

    case fun.(ctx) do
      %{assigns: _assigns} = next_ctx -> next_ctx
      _other -> ctx
    end
  end

  defp maybe_dump_trace(nil), do: :ok
  defp maybe_dump_trace(trace), do: IO.puts(:stderr, Trace.format(trace, title: "Scenario trace"))

  defp register_teardown(teardowns, fun) when is_pid(teardowns) and is_function(fun, 0) do
    Agent.update(teardowns, &[fun | &1])
  end

  defp run_teardowns(teardowns) when is_pid(teardowns) do
    teardowns
    |> Agent.get(& &1)
    |> Enum.each(fn fun -> fun.() end)
  end

  defp telemetry_match?(event, measurements, metadata, config) do
    event == config.event_name and
      map_matches?(measurements, config.measurements) and
      map_matches?(metadata, config.metadata)
  end

  defp map_matches?(actual, expectations) do
    Enum.all?(expectations, fn {key, expected} ->
      Map.has_key?(actual, key) and actual[key] == expected
    end)
  end

  defp maybe_note_trace(nil, _label, _metadata), do: :ok
  defp maybe_note_trace(trace, label, metadata), do: Trace.note(trace, label, metadata)
end
