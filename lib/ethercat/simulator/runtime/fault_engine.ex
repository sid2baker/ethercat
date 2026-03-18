defmodule EtherCAT.Simulator.Runtime.FaultEngine do
  @moduledoc false

  alias EtherCAT.Bus.Datagram
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Runtime.Faults
  alias EtherCAT.Simulator.Runtime.Milestones
  alias EtherCAT.Simulator.State

  @exchange_commands [
    :aprd,
    :apwr,
    :aprw,
    :fprd,
    :fpwr,
    :fprw,
    :brd,
    :bwr,
    :brw,
    :lrd,
    :lwr,
    :lrw,
    :armw,
    :frmw
  ]
  @mailbox_abort_stages [:request, :upload_segment, :download_segment]
  @mailbox_protocol_stages [
    :request,
    :upload_init,
    :upload_segment,
    :download_init,
    :download_segment
  ]

  @type apply_result :: {:ok, State.t()} | {:error, term()}
  @type callbacks :: %{
          required(:apply_immediate_fault) => (State.t(), Simulator.immediate_fault() ->
                                                 apply_result()),
          required(:apply_script_step) => (State.t(), Simulator.fault_script_step() ->
                                             apply_result())
        }

  @spec inject(State.t(), Simulator.fault(), callbacks()) :: apply_result()
  def inject(state, {:after_ms, delay_ms, fault}, _callbacks)
      when is_integer(delay_ms) and delay_ms >= 0 do
    schedule_fault(state, delay_ms, fault)
  end

  def inject(state, {:after_milestone, milestone, fault}, _callbacks) do
    schedule_fault_after_milestone(state, milestone, fault)
  end

  def inject(state, {:next_exchange, _fault} = planned_fault, _callbacks) do
    apply_planned_fault(state, planned_fault)
  end

  def inject(state, {:next_exchanges, _count, _fault} = planned_fault, _callbacks) do
    apply_planned_fault(state, planned_fault)
  end

  def inject(state, {:fault_script, steps}, callbacks) do
    apply_fault_script(state, steps, callbacks)
  end

  def inject(state, fault, %{apply_immediate_fault: apply_immediate_fault}) do
    apply_immediate_fault.(state, fault)
  end

  @spec clear_scheduled_faults([map()]) :: :ok
  def clear_scheduled_faults(scheduled_faults) do
    Enum.each(scheduled_faults, fn
      %{kind: :timer, timer_ref: timer_ref} ->
        Process.cancel_timer(timer_ref)

      _scheduled_fault ->
        :ok
    end)
  end

  @spec handle_timer(State.t(), pos_integer(), callbacks()) :: State.t()
  def handle_timer(state, id, callbacks) do
    case pop_scheduled_fault(state.scheduled_faults, id) do
      {:ok, %{fault: fault}, scheduled_faults} ->
        state = %{state | scheduled_faults: scheduled_faults}

        case inject(state, fault, callbacks) do
          {:ok, next_state} -> next_state
          {:error, _reason} -> state
        end

      :error ->
        state
    end
  end

  @spec resume_after_planned_fault(State.t(), map() | nil, callbacks()) :: State.t()
  def resume_after_planned_fault(state, planned_fault_entry, callbacks) do
    maybe_resume_fault_script(state, planned_fault_entry, callbacks)
  end

  @spec after_exchange(
          State.t(),
          [Datagram.t()],
          [Datagram.t()],
          Faults.t(),
          map() | nil,
          callbacks()
        ) :: State.t()
  def after_exchange(state, datagrams, responses, faults, planned_fault_entry, callbacks) do
    state
    |> trigger_milestone_faults(datagrams, responses, faults, planned_fault_entry, callbacks)
    |> maybe_resume_fault_script(planned_fault_entry, callbacks)
  end

  defp apply_planned_fault(state, planned_fault) do
    case Faults.enqueue(state.faults, planned_fault) do
      {:ok, faults} -> {:ok, %{state | faults: faults}}
      :error -> {:error, :invalid_fault}
    end
  end

  defp apply_fault_script(state, steps, callbacks) when is_list(steps) do
    if valid_fault_script_steps?(steps) do
      resume_fault_script(state, System.unique_integer([:positive, :monotonic]), steps, callbacks)
    else
      {:error, :invalid_fault}
    end
  end

  defp resume_fault_script(state, _script_id, [], _callbacks), do: {:ok, state}

  defp resume_fault_script(state, script_id, steps, callbacks) do
    {exchange_steps, rest_steps} = Enum.split_while(steps, &fault_script_exchange_step?/1)

    cond do
      exchange_steps != [] ->
        with {:ok, faults} <- Faults.enqueue_script_steps(state.faults, script_id, exchange_steps) do
          state = %{state | faults: faults}
          {:ok, maybe_store_script_resume(state, script_id, length(exchange_steps), rest_steps)}
        else
          :error -> {:error, :invalid_fault}
        end

      steps == [] ->
        {:ok, state}

      true ->
        advance_non_exchange_script_step(state, script_id, steps, callbacks)
    end
  end

  defp advance_non_exchange_script_step(
         state,
         script_id,
         [{:wait_for_milestone, milestone} | rest_steps],
         _callbacks
       ) do
    if Milestones.valid?(milestone) do
      scheduled_fault = %{
        id: System.unique_integer([:positive, :monotonic]),
        kind: :script_milestone,
        script_id: script_id,
        milestone: milestone,
        remaining: Milestones.initial_remaining(milestone),
        steps: rest_steps
      }

      {:ok, %{state | scheduled_faults: state.scheduled_faults ++ [scheduled_fault]}}
    else
      {:error, :invalid_fault}
    end
  end

  defp advance_non_exchange_script_step(state, script_id, [step | rest_steps], callbacks) do
    case callbacks.apply_script_step.(state, step) do
      {:ok, next_state} -> resume_fault_script(next_state, script_id, rest_steps, callbacks)
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_store_script_resume(state, _script_id, _count, []), do: state

  defp maybe_store_script_resume(state, script_id, count, steps) do
    scheduled_fault = %{
      id: System.unique_integer([:positive, :monotonic]),
      kind: :script_resume,
      script_id: script_id,
      remaining_exchange_steps: count,
      steps: steps
    }

    %{state | scheduled_faults: state.scheduled_faults ++ [scheduled_fault]}
  end

  defp schedule_fault(state, delay_ms, fault) do
    if valid_schedulable_fault?(fault) do
      id = System.unique_integer([:positive, :monotonic])
      due_at_ms = System.monotonic_time(:millisecond) + delay_ms
      timer_ref = Process.send_after(self(), {:apply_scheduled_fault, id, fault}, delay_ms)

      scheduled_fault = %{
        id: id,
        kind: :timer,
        timer_ref: timer_ref,
        due_at_ms: due_at_ms,
        fault: fault
      }

      {:ok, %{state | scheduled_faults: state.scheduled_faults ++ [scheduled_fault]}}
    else
      {:error, :invalid_fault}
    end
  end

  defp schedule_fault_after_milestone(state, milestone, fault) do
    if valid_schedulable_fault?(fault) and Milestones.valid?(milestone) do
      scheduled_fault = %{
        id: System.unique_integer([:positive, :monotonic]),
        kind: :milestone,
        milestone: milestone,
        remaining: Milestones.initial_remaining(milestone),
        fault: fault
      }

      {:ok, %{state | scheduled_faults: state.scheduled_faults ++ [scheduled_fault]}}
    else
      {:error, :invalid_fault}
    end
  end

  defp pop_scheduled_fault(scheduled_faults, id) do
    {matches, scheduled_faults} = Enum.split_with(scheduled_faults, &(&1.id == id))

    case matches do
      [entry] -> {:ok, entry, scheduled_faults}
      [] -> :error
    end
  end

  defp trigger_milestone_faults(
         state,
         datagrams,
         responses,
         faults,
         planned_fault_entry,
         callbacks
       ) do
    planned_fault = fault_entry_fault(planned_fault_entry)
    observations = Milestones.observe(datagrams, responses, state.slaves, faults, planned_fault)

    {scheduled_faults, ready_actions} =
      Enum.reduce(state.scheduled_faults, {[], []}, fn
        %{kind: :milestone, milestone: milestone, remaining: remaining, fault: fault} = entry,
        {kept, ready} ->
          progress = Milestones.progress(milestone, observations)
          next_remaining = max(remaining - progress, 0)

          if next_remaining == 0 do
            {kept, ready ++ [{:fault, fault}]}
          else
            {kept ++ [%{entry | remaining: next_remaining}], ready}
          end

        %{kind: :script_milestone, milestone: milestone, remaining: remaining, steps: steps} =
            entry,
        {kept, ready} ->
          progress = Milestones.progress(milestone, observations)
          next_remaining = max(remaining - progress, 0)

          if next_remaining == 0 do
            {kept, ready ++ [{:script, entry.script_id, steps}]}
          else
            {kept ++ [%{entry | remaining: next_remaining}], ready}
          end

        entry, {kept, ready} ->
          {kept ++ [entry], ready}
      end)

    Enum.reduce(ready_actions, %{state | scheduled_faults: scheduled_faults}, fn
      {:fault, fault}, current_state ->
        case inject(current_state, fault, callbacks) do
          {:ok, next_state} -> next_state
          {:error, _reason} -> current_state
        end

      {:script, script_id, steps}, current_state ->
        case resume_fault_script(current_state, script_id, steps, callbacks) do
          {:ok, next_state} -> next_state
          {:error, _reason} -> current_state
        end
    end)
  end

  defp maybe_resume_fault_script(state, %{source: {:script, script_id}}, callbacks) do
    case pop_script_resume(state.scheduled_faults, script_id) do
      {:ok, nil, scheduled_faults} ->
        %{state | scheduled_faults: scheduled_faults}

      {:ok, steps, scheduled_faults} ->
        case resume_fault_script(
               %{state | scheduled_faults: scheduled_faults},
               script_id,
               steps,
               callbacks
             ) do
          {:ok, next_state} -> next_state
          {:error, _reason} -> %{state | scheduled_faults: scheduled_faults}
        end

      :error ->
        state
    end
  end

  defp maybe_resume_fault_script(state, _planned_fault_entry, _callbacks), do: state

  defp pop_script_resume(scheduled_faults, script_id) do
    case Enum.reduce_while(scheduled_faults, {:not_found, [], []}, fn
           %{
             kind: :script_resume,
             script_id: ^script_id,
             remaining_exchange_steps: 1,
             steps: steps
           },
           {:not_found, left, right} ->
             {:halt, {:ok, steps, Enum.reverse(left, right)}}

           %{kind: :script_resume, script_id: ^script_id, remaining_exchange_steps: count} = entry,
           {:not_found, left, right} ->
             updated = %{entry | remaining_exchange_steps: count - 1}
             {:halt, {:ok, nil, Enum.reverse(left, [updated | right])}}

           entry, {:not_found, left, right} ->
             {:cont, {:not_found, [entry | left], right}}

           _entry, result ->
             {:halt, result}
         end) do
      {:not_found, _left, _right} -> :error
      result -> result
    end
  end

  defp fault_entry_fault(nil), do: nil
  defp fault_entry_fault(%{fault: fault}), do: fault

  defp valid_schedulable_fault?({:next_exchange, fault}),
    do: valid_exchange_fault?(fault)

  defp valid_schedulable_fault?({:next_exchanges, count, fault})
       when is_integer(count) and count > 0 do
    valid_exchange_fault?(fault)
  end

  defp valid_schedulable_fault?({:after_ms, delay_ms, fault})
       when is_integer(delay_ms) and delay_ms >= 0 do
    valid_schedulable_fault?(fault)
  end

  defp valid_schedulable_fault?({:after_milestone, milestone, fault}) do
    Milestones.valid?(milestone) and valid_schedulable_fault?(fault)
  end

  defp valid_schedulable_fault?({:fault_script, steps}) when is_list(steps) do
    valid_fault_script_steps?(steps)
  end

  defp valid_schedulable_fault?(fault),
    do: valid_exchange_fault?(fault) or valid_slave_fault?(fault)

  defp valid_fault_script_steps?(steps) when is_list(steps) do
    steps != [] and Enum.all?(steps, &valid_fault_script_step?/1)
  end

  defp valid_fault_script_step?({:wait_for_milestone, milestone}),
    do: Milestones.valid?(milestone)

  defp valid_fault_script_step?(step), do: valid_exchange_fault?(step) or valid_slave_fault?(step)

  defp fault_script_exchange_step?(step), do: valid_exchange_fault?(step)

  defp valid_mailbox_protocol_fault?(stage, :counter_mismatch)
       when stage in @mailbox_protocol_stages,
       do: true

  defp valid_mailbox_protocol_fault?(stage, :drop_response)
       when stage in @mailbox_protocol_stages,
       do: true

  defp valid_mailbox_protocol_fault?(stage, :toggle_mismatch)
       when stage in [:upload_segment, :download_segment],
       do: true

  defp valid_mailbox_protocol_fault?(stage, {:mailbox_type, mailbox_type})
       when stage in @mailbox_protocol_stages and is_integer(mailbox_type) and
              mailbox_type >= 0 and mailbox_type <= 15,
       do: true

  defp valid_mailbox_protocol_fault?(stage, {:coe_service, service})
       when stage in @mailbox_protocol_stages and is_integer(service) and service >= 0 and
              service <= 15,
       do: true

  defp valid_mailbox_protocol_fault?(stage, :invalid_coe_payload)
       when stage in @mailbox_protocol_stages,
       do: true

  defp valid_mailbox_protocol_fault?(stage, {:sdo_command, command})
       when stage == :upload_init and is_integer(command) and command >= 0 and command <= 255,
       do: true

  defp valid_mailbox_protocol_fault?(stage, :invalid_segment_padding)
       when stage == :upload_segment,
       do: true

  defp valid_mailbox_protocol_fault?(stage, {:segment_command, command})
       when stage in [:upload_segment, :download_segment] and is_integer(command) and
              command >= 0 and command <= 255,
       do: true

  defp valid_mailbox_protocol_fault?(_stage, _fault_kind), do: false

  defp valid_exchange_fault?(:drop_responses), do: true
  defp valid_exchange_fault?({:wkc_offset, delta}) when is_integer(delta), do: true

  defp valid_exchange_fault?({:command_wkc_offset, command_name, delta})
       when command_name in @exchange_commands and is_integer(delta),
       do: true

  defp valid_exchange_fault?({:logical_wkc_offset, slave_name, delta})
       when is_atom(slave_name) and is_integer(delta),
       do: true

  defp valid_exchange_fault?({:disconnect, slave_name}) when is_atom(slave_name), do: true
  defp valid_exchange_fault?(_fault), do: false

  defp valid_slave_fault?({:retreat_to_safeop, slave_name}) when is_atom(slave_name), do: true
  defp valid_slave_fault?({:power_cycle, slave_name}) when is_atom(slave_name), do: true

  defp valid_slave_fault?({:latch_al_error, slave_name, code})
       when is_atom(slave_name) and is_integer(code) and code >= 0,
       do: true

  defp valid_slave_fault?({:mailbox_abort, slave_name, index, subindex, abort_code})
       when is_atom(slave_name) and is_integer(index) and index >= 0 and is_integer(subindex) and
              subindex >= 0 and is_integer(abort_code) and abort_code >= 0,
       do: true

  defp valid_slave_fault?({:mailbox_abort, slave_name, index, subindex, abort_code, stage})
       when is_atom(slave_name) and is_integer(index) and index >= 0 and is_integer(subindex) and
              subindex >= 0 and is_integer(abort_code) and abort_code >= 0 and
              stage in @mailbox_abort_stages,
       do: true

  defp valid_slave_fault?(
         {:mailbox_protocol_fault, slave_name, index, subindex, stage, fault_kind}
       )
       when is_atom(slave_name) and is_integer(index) and index >= 0 and is_integer(subindex) and
              subindex >= 0,
       do: valid_mailbox_protocol_fault?(stage, fault_kind)

  defp valid_slave_fault?(_fault), do: false
end
