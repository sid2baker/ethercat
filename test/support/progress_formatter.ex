defmodule EtherCAT.TestProgressFormatter do
  @moduledoc false

  use GenServer

  @impl true
  def init(opts) do
    {:ok, %{seen: MapSet.new(), trace?: opts[:trace] || false}}
  end

  @impl true
  def handle_cast(
        {:test_started, %ExUnit.Test{state: {:excluded, _reason}}},
        state
      ) do
    {:noreply, state}
  end

  def handle_cast(
        {:test_started, %ExUnit.Test{state: {:skipped, _reason}}},
        state
      ) do
    {:noreply, state}
  end

  def handle_cast({:test_started, %ExUnit.Test{tags: %{file: file}}}, %{trace?: false} = state) do
    file
    |> Path.relative_to_cwd()
    |> phase_for()
    |> maybe_print_phase(state)
  end

  def handle_cast(_, state), do: {:noreply, state}

  defp maybe_print_phase(nil, state), do: {:noreply, state}

  defp maybe_print_phase(phase, %{seen: seen} = state) do
    if MapSet.member?(seen, phase) do
      {:noreply, state}
    else
      IO.puts("\n[tests] #{phase_label(phase)}")
      {:noreply, %{state | seen: MapSet.put(seen, phase)}}
    end
  end

  defp phase_for("test/integration/hardware/" <> _), do: :hardware_integration
  defp phase_for("test/integration/simulator/" <> _), do: :simulator_integration
  defp phase_for("test/integration/support/" <> _), do: :integration_support
  defp phase_for("test/" <> _), do: :unit
  defp phase_for(_), do: nil

  defp phase_label(:hardware_integration), do: "hardware integration tests"
  defp phase_label(:integration_support), do: "integration support tests"
  defp phase_label(:simulator_integration), do: "simulator integration tests"
  defp phase_label(:unit), do: "unit tests"
end
