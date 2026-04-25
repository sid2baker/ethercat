defmodule EtherCAT.Simulator.FaultSpec do
  @moduledoc false

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

  @mailbox_steps [:request, :upload_init, :upload_segment, :download_init, :download_segment]
  @mailbox_abort_stages [:request, :upload_segment, :download_segment]
  @milestone_mailbox_steps [:upload_init, :upload_segment, :download_init, :download_segment]
  @mailbox_protocol_atom_stages %{
    counter_mismatch: @mailbox_steps,
    drop_response: @mailbox_steps,
    toggle_mismatch: [:upload_segment, :download_segment],
    invalid_coe_payload: @mailbox_steps,
    invalid_segment_padding: [:upload_segment]
  }
  @mailbox_protocol_tuple_specs %{
    mailbox_type: {@mailbox_steps, 0, 15},
    coe_service: {@mailbox_steps, 0, 15},
    sdo_command: {[:upload_init], 0, 255},
    segment_command: {[:upload_segment, :download_segment], 0, 255}
  }

  @type command_name ::
          :aprd
          | :apwr
          | :aprw
          | :fprd
          | :fpwr
          | :fprw
          | :brd
          | :bwr
          | :brw
          | :lrd
          | :lwr
          | :lrw
          | :armw
          | :frmw

  @type mailbox_step ::
          :request | :upload_init | :upload_segment | :download_init | :download_segment

  @type mailbox_abort_stage :: :request | :upload_segment | :download_segment

  @type milestone_mailbox_step ::
          :upload_init | :upload_segment | :download_init | :download_segment

  @type mailbox_protocol_fault_kind ::
          :drop_response
          | :counter_mismatch
          | :toggle_mismatch
          | {:mailbox_type, 0..15}
          | {:coe_service, 0..15}
          | :invalid_coe_payload
          | {:sdo_command, 0..255}
          | :invalid_segment_padding
          | {:segment_command, 0..255}

  @type exchange_fault ::
          :drop_responses
          | {:wkc_offset, integer()}
          | {:command_wkc_offset, command_name(), integer()}
          | {:logical_wkc_offset, atom(), integer()}
          | {:disconnect, atom()}

  @type milestone ::
          {:healthy_exchanges, pos_integer()}
          | {:healthy_polls, atom(), pos_integer()}
          | {:mailbox_step, atom(), milestone_mailbox_step(), pos_integer()}

  @type slave_fault ::
          {:retreat_to_safeop, atom()}
          | {:power_cycle, atom()}
          | {:latch_al_error, atom(), non_neg_integer()}
          | {:mailbox_abort, atom(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
          | {:mailbox_abort, atom(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
             mailbox_abort_stage()}
          | {:mailbox_protocol_fault, atom(), non_neg_integer(), non_neg_integer(),
             mailbox_step(), mailbox_protocol_fault_kind()}

  @type fault_script_step ::
          exchange_fault()
          | slave_fault()
          | {:wait_for_milestone, milestone()}

  @type immediate_fault ::
          exchange_fault()
          | {:next_exchange, exchange_fault()}
          | {:next_exchanges, pos_integer(), exchange_fault()}
          | {:fault_script, [fault_script_step(), ...]}
          | slave_fault()

  @type schedulable_fault ::
          immediate_fault()
          | {:after_ms, non_neg_integer(), schedulable_fault()}
          | {:after_milestone, milestone(), schedulable_fault()}

  @type fault :: schedulable_fault()

  defguard exchange_command?(command_name) when command_name in @exchange_commands
  defguard mailbox_step?(stage) when stage in @mailbox_steps
  defguard mailbox_abort_stage?(stage) when stage in @mailbox_abort_stages
  defguard milestone_mailbox_step?(stage) when stage in @milestone_mailbox_steps

  @spec normalize_effect(term()) :: {:ok, exchange_fault() | slave_fault()} | :error
  def normalize_effect(effect) do
    case normalize_exchange_effect(effect) do
      {:ok, _fault} = ok -> ok
      :error -> normalize_slave_effect(effect)
    end
  end

  defp normalize_exchange_effect(:drop_responses), do: {:ok, :drop_responses}

  defp normalize_exchange_effect({:wkc_offset, delta}) when is_integer(delta),
    do: {:ok, {:wkc_offset, delta}}

  defp normalize_exchange_effect({:command_wkc_offset, command_name, delta})
       when exchange_command?(command_name) and is_integer(delta) do
    {:ok, {:command_wkc_offset, command_name, delta}}
  end

  defp normalize_exchange_effect({:logical_wkc_offset, slave_name, delta})
       when is_atom(slave_name) and is_integer(delta) do
    {:ok, {:logical_wkc_offset, slave_name, delta}}
  end

  defp normalize_exchange_effect({:disconnect, slave_name}) when is_atom(slave_name) do
    {:ok, {:disconnect, slave_name}}
  end

  defp normalize_exchange_effect(_effect), do: :error

  defp normalize_slave_effect({:retreat_to_safeop, slave_name}) when is_atom(slave_name) do
    {:ok, {:retreat_to_safeop, slave_name}}
  end

  defp normalize_slave_effect({:power_cycle, slave_name}) when is_atom(slave_name) do
    {:ok, {:power_cycle, slave_name}}
  end

  defp normalize_slave_effect({:latch_al_error, slave_name, code})
       when is_atom(slave_name) and is_integer(code) and code >= 0 do
    {:ok, {:latch_al_error, slave_name, code}}
  end

  defp normalize_slave_effect({:mailbox_abort, slave_name, index, subindex, abort_code})
       when is_atom(slave_name) and is_integer(index) and index >= 0 and is_integer(subindex) and
              subindex >= 0 and is_integer(abort_code) and abort_code >= 0 do
    {:ok, {:mailbox_abort, slave_name, index, subindex, abort_code}}
  end

  defp normalize_slave_effect({:mailbox_abort, slave_name, index, subindex, abort_code, nil})
       when is_atom(slave_name) and is_integer(index) and index >= 0 and is_integer(subindex) and
              subindex >= 0 and is_integer(abort_code) and abort_code >= 0 do
    {:ok, {:mailbox_abort, slave_name, index, subindex, abort_code}}
  end

  defp normalize_slave_effect({:mailbox_abort, slave_name, index, subindex, abort_code, stage})
       when is_atom(slave_name) and is_integer(index) and index >= 0 and is_integer(subindex) and
              subindex >= 0 and is_integer(abort_code) and abort_code >= 0 and
              mailbox_abort_stage?(stage) do
    {:ok, {:mailbox_abort, slave_name, index, subindex, abort_code, stage}}
  end

  defp normalize_slave_effect(
         {:mailbox_protocol_fault, slave_name, index, subindex, stage, fault_kind}
       )
       when is_atom(slave_name) and is_integer(index) and index >= 0 and is_integer(subindex) and
              subindex >= 0 and mailbox_step?(stage) do
    {:ok, {:mailbox_protocol_fault, slave_name, index, subindex, stage, fault_kind}}
  end

  defp normalize_slave_effect(_effect), do: :error

  @spec valid_exchange_fault?(term()) :: boolean()
  def valid_exchange_fault?(fault) do
    case normalize_effect(fault) do
      {:ok, normalized_fault} -> exchange_fault?(normalized_fault)
      :error -> false
    end
  end

  @spec valid_slave_fault?(term()) :: boolean()
  def valid_slave_fault?({:mailbox_abort, _slave_name, _index, _subindex, _abort_code, nil}),
    do: false

  def valid_slave_fault?(fault) do
    case normalize_effect(fault) do
      {:ok, normalized_fault} -> slave_fault?(normalized_fault)
      :error -> false
    end
  end

  @spec valid_milestone?(term()) :: boolean()
  def valid_milestone?({:healthy_exchanges, count}) when is_integer(count) and count > 0,
    do: true

  def valid_milestone?({:healthy_polls, slave_name, count})
      when is_atom(slave_name) and is_integer(count) and count > 0,
      do: true

  def valid_milestone?({:mailbox_step, slave_name, step, count})
      when is_atom(slave_name) and milestone_mailbox_step?(step) and is_integer(count) and
             count > 0,
      do: true

  def valid_milestone?(_milestone), do: false

  @spec valid_mailbox_protocol_fault?(mailbox_step(), term()) :: boolean()
  def valid_mailbox_protocol_fault?(stage, fault_kind)
      when mailbox_step?(stage) and is_atom(fault_kind) do
    stage in Map.get(@mailbox_protocol_atom_stages, fault_kind, [])
  end

  def valid_mailbox_protocol_fault?(stage, {fault_kind, value})
      when mailbox_step?(stage) and is_integer(value) do
    case Map.fetch(@mailbox_protocol_tuple_specs, fault_kind) do
      {:ok, {stages, min, max}} -> stage in stages and value >= min and value <= max
      :error -> false
    end
  end

  def valid_mailbox_protocol_fault?(_stage, _fault_kind), do: false

  defp exchange_fault?(:drop_responses), do: true
  defp exchange_fault?({:wkc_offset, _delta}), do: true
  defp exchange_fault?({:command_wkc_offset, _command_name, _delta}), do: true
  defp exchange_fault?({:logical_wkc_offset, _slave_name, _delta}), do: true
  defp exchange_fault?({:disconnect, _slave_name}), do: true
  defp exchange_fault?(_fault), do: false

  defp slave_fault?({:retreat_to_safeop, _slave_name}), do: true
  defp slave_fault?({:power_cycle, _slave_name}), do: true
  defp slave_fault?({:latch_al_error, _slave_name, _code}), do: true
  defp slave_fault?({:mailbox_abort, _slave_name, _index, _subindex, _abort_code}), do: true

  defp slave_fault?({:mailbox_abort, _slave_name, _index, _subindex, _abort_code, _stage}),
    do: true

  defp slave_fault?({:mailbox_protocol_fault, _slave_name, _index, _subindex, stage, fault_kind}) do
    valid_mailbox_protocol_fault?(stage, fault_kind)
  end

  defp slave_fault?(_fault), do: false
end
