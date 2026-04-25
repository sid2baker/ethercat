defmodule EtherCAT.Simulator.Fault do
  @moduledoc """
  Builder API for `EtherCAT.Simulator.inject_fault/1`.

  This keeps the public fault surface readable without changing the simulator's
  internal tuple representation.

  Typical usage:

      alias EtherCAT.Simulator.Fault

      EtherCAT.Simulator.inject_fault(Fault.drop_responses())

      EtherCAT.Simulator.inject_fault(
        Fault.disconnect(:outputs)
        |> Fault.next(30)
      )

      EtherCAT.Simulator.inject_fault(
        Fault.script([
          Fault.drop_responses(),
          Fault.wait_for(Fault.healthy_polls(:outputs, 10)),
          Fault.retreat_to_safeop(:outputs)
        ])
      )

      Fault.describe(Fault.disconnect(:outputs) |> Fault.next(3))
  """

  alias EtherCAT.Simulator.FaultSpec

  require FaultSpec

  @type mailbox_step :: EtherCAT.Simulator.mailbox_step()

  @type milestone :: EtherCAT.Simulator.milestone()

  @type schedule ::
          :immediate
          | {:next_exchange, pos_integer()}
          | {:after_ms, non_neg_integer()}
          | {:after_milestone, milestone()}

  @type raw_fault ::
          EtherCAT.Simulator.fault()
          | EtherCAT.Simulator.immediate_fault()
          | EtherCAT.Simulator.fault_script_step()

  @type effect ::
          :drop_responses
          | {:wkc_offset, integer()}
          | {:command_wkc_offset, atom(), integer()}
          | {:logical_wkc_offset, atom(), integer()}
          | {:disconnect, atom()}
          | {:retreat_to_safeop, atom()}
          | {:power_cycle, atom()}
          | {:latch_al_error, atom(), non_neg_integer()}
          | {:mailbox_abort, atom(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
             mailbox_step() | nil}
          | {:mailbox_protocol_fault, atom(), non_neg_integer(), non_neg_integer(),
             mailbox_step(), term()}
          | {:nested, t() | raw_fault()}
          | {:script, [t()]}
          | {:wait_for_milestone, milestone()}

  @type t :: %__MODULE__{
          effect: effect(),
          schedule: schedule()
        }

  defstruct effect: nil, schedule: :immediate

  @spec drop_responses() :: t()
  def drop_responses, do: %__MODULE__{effect: :drop_responses}

  @spec wkc_offset(integer()) :: t()
  def wkc_offset(delta) when is_integer(delta), do: %__MODULE__{effect: {:wkc_offset, delta}}

  @spec command_wkc_offset(atom(), integer()) :: t()
  def command_wkc_offset(command_name, delta)
      when FaultSpec.exchange_command?(command_name) and is_integer(delta) do
    %__MODULE__{effect: {:command_wkc_offset, command_name, delta}}
  end

  @spec logical_wkc_offset(atom(), integer()) :: t()
  def logical_wkc_offset(slave_name, delta)
      when is_atom(slave_name) and is_integer(delta) do
    %__MODULE__{effect: {:logical_wkc_offset, slave_name, delta}}
  end

  @spec disconnect(atom()) :: t()
  def disconnect(slave_name) when is_atom(slave_name),
    do: %__MODULE__{effect: {:disconnect, slave_name}}

  @spec retreat_to_safeop(atom()) :: t()
  def retreat_to_safeop(slave_name) when is_atom(slave_name),
    do: %__MODULE__{effect: {:retreat_to_safeop, slave_name}}

  @spec power_cycle(atom()) :: t()
  def power_cycle(slave_name) when is_atom(slave_name),
    do: %__MODULE__{effect: {:power_cycle, slave_name}}

  @spec latch_al_error(atom(), non_neg_integer()) :: t()
  def latch_al_error(slave_name, code)
      when is_atom(slave_name) and is_integer(code) and code >= 0 do
    %__MODULE__{effect: {:latch_al_error, slave_name, code}}
  end

  @spec mailbox_abort(atom(), non_neg_integer(), non_neg_integer(), non_neg_integer(), keyword()) ::
          t()
  def mailbox_abort(slave_name, index, subindex, abort_code, opts \\ [])
      when is_atom(slave_name) and is_integer(index) and index >= 0 and is_integer(subindex) and
             subindex >= 0 and is_integer(abort_code) and abort_code >= 0 do
    stage = Keyword.get(opts, :stage)

    %__MODULE__{
      effect: {:mailbox_abort, slave_name, index, subindex, abort_code, stage}
    }
  end

  @spec mailbox_protocol_fault(
          atom(),
          non_neg_integer(),
          non_neg_integer(),
          mailbox_step(),
          term()
        ) :: t()
  def mailbox_protocol_fault(slave_name, index, subindex, stage, fault_kind)
      when is_atom(slave_name) and is_integer(index) and index >= 0 and is_integer(subindex) and
             subindex >= 0 and FaultSpec.mailbox_step?(stage) do
    %__MODULE__{
      effect: {:mailbox_protocol_fault, slave_name, index, subindex, stage, fault_kind}
    }
  end

  @spec script([t(), ...]) :: t()
  def script(steps) when is_list(steps) and steps != [] do
    %__MODULE__{effect: {:script, steps}}
  end

  @spec wait_for(milestone()) :: t()
  def wait_for(milestone), do: %__MODULE__{effect: {:wait_for_milestone, milestone}}

  @spec next(t(), pos_integer()) :: t()
  def next(%__MODULE__{} = fault, count \\ 1) when is_integer(count) and count > 0 do
    %{fault | schedule: {:next_exchange, count}}
  end

  @spec after_ms(t(), non_neg_integer()) :: t()
  def after_ms(%__MODULE__{} = fault, delay_ms)
      when is_integer(delay_ms) and delay_ms >= 0 do
    nest_schedule(fault, {:after_ms, delay_ms})
  end

  @spec after_milestone(t(), milestone()) :: t()
  def after_milestone(%__MODULE__{} = fault, milestone) do
    nest_schedule(fault, {:after_milestone, milestone})
  end

  @spec healthy_exchanges(pos_integer()) :: milestone()
  def healthy_exchanges(count) when is_integer(count) and count > 0,
    do: {:healthy_exchanges, count}

  @spec healthy_polls(atom(), pos_integer()) :: milestone()
  def healthy_polls(slave_name, count)
      when is_atom(slave_name) and is_integer(count) and count > 0 do
    {:healthy_polls, slave_name, count}
  end

  @spec mailbox_step(atom(), mailbox_step(), pos_integer()) :: milestone()
  def mailbox_step(slave_name, step, count)
      when is_atom(slave_name) and FaultSpec.milestone_mailbox_step?(step) and
             is_integer(count) and count > 0 do
    {:mailbox_step, slave_name, step, count}
  end

  @spec normalize(t() | raw_fault()) :: {:ok, raw_fault()} | :error
  def normalize(%__MODULE__{} = fault) do
    with {:ok, raw_effect} <- normalize_effect(fault.effect),
         {:ok, raw_fault} <- apply_schedule(raw_effect, fault.schedule) do
      {:ok, raw_fault}
    end
  end

  def normalize(raw_fault), do: {:ok, raw_fault}

  @spec describe(t() | raw_fault()) :: String.t()
  def describe(%__MODULE__{} = fault) do
    case normalize(fault) do
      {:ok, raw_fault} -> describe(raw_fault)
      :error -> inspect(fault)
    end
  end

  def describe(:drop_responses), do: "drop responses"
  def describe({:wkc_offset, delta}), do: "WKC offset #{delta}"

  def describe({:command_wkc_offset, command_name, delta}),
    do: "command #{command_name} WKC offset #{delta}"

  def describe({:logical_wkc_offset, slave_name, delta}),
    do: "logical WKC offset #{delta} for #{slave_name}"

  def describe({:disconnect, slave_name}), do: "disconnect #{slave_name}"
  def describe({:retreat_to_safeop, slave_name}), do: "retreat #{slave_name} to SAFEOP"
  def describe({:power_cycle, slave_name}), do: "power cycle #{slave_name}"

  def describe({:latch_al_error, slave_name, code}),
    do: "latch AL error #{hex(code, 4)} on #{slave_name}"

  def describe({:mailbox_abort, slave_name, index, subindex, abort_code}) do
    "mailbox abort #{hex(abort_code, 8)} on #{slave_name} for #{hex(index, 4)}:#{hex(subindex, 2)}"
  end

  def describe({:mailbox_abort, slave_name, index, subindex, abort_code, stage}) do
    "mailbox abort #{hex(abort_code, 8)} on #{slave_name} for #{hex(index, 4)}:#{hex(subindex, 2)} during #{stage}"
  end

  def describe({:mailbox_protocol_fault, slave_name, index, subindex, stage, fault_kind}) do
    "mailbox protocol fault #{describe_mailbox_fault_kind(fault_kind)} on #{slave_name} for #{hex(index, 4)}:#{hex(subindex, 2)} during #{stage}"
  end

  def describe({:next_exchange, fault}), do: "next exchange #{describe(fault)}"
  def describe({:next_exchanges, count, fault}), do: "next #{count} exchanges #{describe(fault)}"
  def describe({:after_ms, delay_ms, fault}), do: "after #{delay_ms}ms #{describe(fault)}"

  def describe({:after_milestone, milestone, fault}) do
    "after #{describe_milestone(milestone)} #{describe(fault)}"
  end

  def describe({:fault_script, steps}) when is_list(steps) do
    "fault script [#{Enum.map_join(steps, ", ", &describe/1)}]"
  end

  def describe({:wait_for_milestone, milestone}),
    do: "wait for #{describe_milestone(milestone)}"

  def describe(other), do: inspect(other)

  defp normalize_effect({:nested, %__MODULE__{} = nested_fault}) do
    normalize(nested_fault)
  end

  defp normalize_effect({:nested, raw_fault}) do
    {:ok, raw_fault}
  end

  defp normalize_effect({:script, steps}) when is_list(steps) and steps != [] do
    with {:ok, normalized_steps} <- normalize_script_steps(steps) do
      {:ok, {:fault_script, normalized_steps}}
    end
  end

  defp normalize_effect({:wait_for_milestone, milestone}) do
    {:ok, {:wait_for_milestone, milestone}}
  end

  defp normalize_effect(effect), do: FaultSpec.normalize_effect(effect)

  defp normalize_script_steps(steps) do
    Enum.reduce_while(steps, {:ok, []}, fn
      %__MODULE__{schedule: :immediate, effect: {:wait_for_milestone, milestone}}, {:ok, acc} ->
        {:cont, {:ok, acc ++ [{:wait_for_milestone, milestone}]}}

      %__MODULE__{schedule: :immediate} = step, {:ok, acc} ->
        case normalize_effect(step.effect) do
          {:ok, {:wait_for_milestone, milestone}} ->
            {:cont, {:ok, acc ++ [{:wait_for_milestone, milestone}]}}

          {:ok, raw_step} ->
            {:cont, {:ok, acc ++ [raw_step]}}

          :error ->
            {:halt, :error}
        end

      %__MODULE__{}, _acc ->
        {:halt, :error}

      raw_step, {:ok, acc} ->
        {:cont, {:ok, acc ++ [raw_step]}}
    end)
  end

  defp apply_schedule({:wait_for_milestone, _milestone}, :immediate), do: :error
  defp apply_schedule(raw_effect, :immediate), do: {:ok, raw_effect}

  defp apply_schedule(raw_effect, {:next_exchange, 1}), do: {:ok, {:next_exchange, raw_effect}}

  defp apply_schedule(raw_effect, {:next_exchange, count})
       when is_integer(count) and count > 1 do
    {:ok, {:next_exchanges, count, raw_effect}}
  end

  defp apply_schedule(raw_effect, {:after_ms, delay_ms})
       when is_integer(delay_ms) and delay_ms >= 0 do
    {:ok, {:after_ms, delay_ms, raw_effect}}
  end

  defp apply_schedule(raw_effect, {:after_milestone, milestone}) do
    {:ok, {:after_milestone, milestone, raw_effect}}
  end

  defp apply_schedule(_raw_effect, _schedule), do: :error

  defp nest_schedule(%__MODULE__{schedule: :immediate} = fault, schedule) do
    %{fault | schedule: schedule}
  end

  defp nest_schedule(%__MODULE__{} = fault, schedule) do
    %__MODULE__{effect: {:nested, fault}, schedule: schedule}
  end

  defp describe_milestone({:healthy_exchanges, count}), do: "#{count} healthy exchanges"

  defp describe_milestone({:healthy_polls, slave_name, count}),
    do: "#{count} healthy polls for #{slave_name}"

  defp describe_milestone({:mailbox_step, slave_name, step, count}),
    do: "#{count} mailbox #{step} steps for #{slave_name}"

  defp describe_milestone(other), do: inspect(other)

  defp describe_mailbox_fault_kind(:drop_response), do: "drop response"
  defp describe_mailbox_fault_kind(:counter_mismatch), do: "counter mismatch"
  defp describe_mailbox_fault_kind(:toggle_mismatch), do: "toggle mismatch"
  defp describe_mailbox_fault_kind(:invalid_coe_payload), do: "invalid CoE payload"
  defp describe_mailbox_fault_kind(:invalid_segment_padding), do: "invalid segment padding"

  defp describe_mailbox_fault_kind({:mailbox_type, mailbox_type}),
    do: "mailbox type #{hex(mailbox_type, 2)}"

  defp describe_mailbox_fault_kind({:coe_service, service}),
    do: "CoE service #{hex(service, 2)}"

  defp describe_mailbox_fault_kind({:sdo_command, command}),
    do: "SDO command #{hex(command, 2)}"

  defp describe_mailbox_fault_kind({:segment_command, command}),
    do: "segment command #{hex(command, 2)}"

  defp describe_mailbox_fault_kind(other), do: inspect(other)

  defp hex(value, width) when is_integer(value) and value >= 0 do
    value
    |> Integer.to_string(16)
    |> String.upcase()
    |> String.pad_leading(width, "0")
    |> then(&("0x" <> &1))
  end
end
