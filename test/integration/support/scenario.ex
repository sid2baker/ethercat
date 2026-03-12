defmodule EtherCAT.Integration.Scenario do
  @moduledoc false

  import ExUnit.Assertions

  alias EtherCAT.Integration.Expect
  alias EtherCAT.Integration.Trace
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Fault

  defstruct steps: [], trace?: false

  @type context :: %{assigns: map(), trace: Trace.t() | nil}
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
    ctx = %{assigns: %{}, trace: trace}

    try do
      Enum.reduce(scenario.steps, ctx, &run_step/2)
      :ok
    rescue
      error ->
        maybe_dump_trace(trace)
        reraise error, __STACKTRACE__
    after
      if trace, do: Trace.stop(trace)
    end
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
end
