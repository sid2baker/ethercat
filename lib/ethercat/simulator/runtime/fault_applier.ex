defmodule EtherCAT.Simulator.Runtime.FaultApplier do
  @moduledoc false

  alias EtherCAT.Simulator.FaultSpec
  alias EtherCAT.Simulator.Runtime.Faults
  alias EtherCAT.Simulator.Runtime.Slaves
  alias EtherCAT.Simulator.Runtime.Subscriptions
  alias EtherCAT.Simulator.Runtime.Wiring
  alias EtherCAT.Simulator.Slave.Runtime.Device
  alias EtherCAT.Simulator.State

  @type apply_result :: {:ok, State.t()} | {:error, term()}
  @type callbacks :: %{
          required(:apply_immediate_fault) => (State.t(), FaultSpec.immediate_fault() ->
                                                 apply_result()),
          required(:apply_script_step) => (State.t(), FaultSpec.fault_script_step() ->
                                             apply_result())
        }

  @spec callbacks() :: callbacks()
  def callbacks do
    %{
      apply_immediate_fault: &apply_immediate_fault/2,
      apply_script_step: &apply_script_step/2
    }
  end

  @spec apply_immediate_fault(State.t(), FaultSpec.immediate_fault()) :: apply_result()
  def apply_immediate_fault(state, :drop_responses) do
    {:ok, %{state | faults: Faults.inject(state.faults, :drop_responses)}}
  end

  def apply_immediate_fault(state, {:wkc_offset, delta}) when is_integer(delta) do
    {:ok, %{state | faults: Faults.inject(state.faults, {:wkc_offset, delta})}}
  end

  def apply_immediate_fault(state, {:command_wkc_offset, command_name, delta})
      when is_atom(command_name) and is_integer(delta) do
    {:ok,
     %{state | faults: Faults.inject(state.faults, {:command_wkc_offset, command_name, delta})}}
  end

  def apply_immediate_fault(state, {:logical_wkc_offset, slave_name, delta})
      when is_atom(slave_name) and is_integer(delta) do
    {:ok,
     %{state | faults: Faults.inject(state.faults, {:logical_wkc_offset, slave_name, delta})}}
  end

  def apply_immediate_fault(state, {:disconnect, slave_name}) when is_atom(slave_name) do
    {:ok, %{state | faults: Faults.inject(state.faults, {:disconnect, slave_name})}}
  end

  def apply_immediate_fault(state, {:retreat_to_safeop, slave_name}) do
    apply_slave_update(state, slave_name, &Device.retreat_to_safeop/1)
  end

  def apply_immediate_fault(state, {:power_cycle, slave_name}) do
    apply_slave_update(state, slave_name, &Device.power_cycle/1)
  end

  def apply_immediate_fault(state, {:latch_al_error, slave_name, code})
      when is_integer(code) and code >= 0 do
    apply_slave_update(state, slave_name, &Device.latch_al_error(&1, code))
  end

  def apply_immediate_fault(state, {:mailbox_abort, slave_name, index, subindex, abort_code})
      when is_integer(index) and index >= 0 and is_integer(subindex) and subindex >= 0 and
             is_integer(abort_code) and abort_code >= 0 do
    apply_slave_update(
      state,
      slave_name,
      &Device.inject_mailbox_abort(&1, index, subindex, abort_code)
    )
  end

  def apply_immediate_fault(
        state,
        {:mailbox_abort, slave_name, index, subindex, abort_code, stage}
      )
      when is_integer(index) and index >= 0 and is_integer(subindex) and subindex >= 0 and
             is_integer(abort_code) and abort_code >= 0 do
    apply_slave_update(
      state,
      slave_name,
      &Device.inject_mailbox_abort(&1, index, subindex, abort_code, stage)
    )
  end

  def apply_immediate_fault(
        state,
        {:mailbox_protocol_fault, slave_name, index, subindex, stage, fault_kind}
      )
      when is_integer(index) and index >= 0 and is_integer(subindex) and subindex >= 0 do
    apply_slave_update(
      state,
      slave_name,
      &Device.inject_mailbox_protocol_fault(&1, index, subindex, stage, fault_kind)
    )
  end

  def apply_immediate_fault(_state, _fault), do: {:error, :invalid_fault}

  @spec apply_script_step(State.t(), FaultSpec.fault_script_step()) :: apply_result()
  def apply_script_step(
        state,
        {:mailbox_protocol_fault, slave_name, index, subindex, stage, fault_kind}
      )
      when is_integer(index) and index >= 0 and is_integer(subindex) and subindex >= 0 do
    apply_slave_update(
      state,
      slave_name,
      &Device.inject_mailbox_protocol_fault_once(&1, index, subindex, stage, fault_kind)
    )
  end

  def apply_script_step(state, step), do: apply_immediate_fault(state, step)

  defp apply_slave_update(state, slave_name, fun) do
    before_signals = Wiring.capture_signal_values(state.slaves)

    case Slaves.update(state.slaves, slave_name, fun) do
      {:ok, slaves} ->
        {:ok, %{state | slaves: slaves} |> finalize_signal_changes(before_signals)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finalize_signal_changes(
         %{slaves: slaves, connections: connections, subscriptions: subscriptions} = state,
         before_signals
       ) do
    {slaves, changes} = Wiring.settle(slaves, connections, before_signals)
    :ok = Subscriptions.notify(subscriptions, self(), changes)
    %{state | slaves: slaves}
  end
end
