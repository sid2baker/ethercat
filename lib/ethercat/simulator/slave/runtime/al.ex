defmodule EtherCAT.Simulator.Slave.Runtime.AL do
  @moduledoc false

  alias EtherCAT.Slave.ESC.Registers
  alias EtherCAT.Simulator.Slave.Behaviour

  @alerr_none 0x0000
  @alerr_invalid_state_change 0x0011
  @alerr_unknown_state 0x0012
  @al_status elem(Registers.al_status(), 0)
  @al_status_code elem(Registers.al_status_code(), 0)

  @spec apply_control(map(), non_neg_integer()) :: {:ok, map()} | {:error, map()}
  def apply_control(slave, request) do
    case decode_request(request) do
      {:ok, target_state} ->
        apply_transition(slave, target_state)

      :error ->
        {:error, commit_state(slave, slave.state, true, @alerr_unknown_state)}
    end
  end

  @spec retreat_to_safeop(map()) :: map()
  def retreat_to_safeop(slave) do
    commit_state(slave, :safeop, false, @alerr_none)
  end

  @spec latch_error(map(), non_neg_integer()) :: map()
  def latch_error(slave, status_code) when is_integer(status_code) and status_code >= 0 do
    commit_state(slave, slave.state, true, status_code)
  end

  @spec clear_error(map()) :: map()
  def clear_error(slave) do
    commit_state(slave, slave.state, false, @alerr_none)
  end

  @spec valid_transition?(atom(), atom()) :: boolean()
  def valid_transition?(state, state), do: true
  def valid_transition?(_state, :init), do: true
  def valid_transition?(:init, :preop), do: true
  def valid_transition?(:init, :bootstrap), do: true
  def valid_transition?(:preop, :safeop), do: true
  def valid_transition?(:preop, :bootstrap), do: true
  def valid_transition?(:safeop, :preop), do: true
  def valid_transition?(:safeop, :op), do: true
  def valid_transition?(:op, :safeop), do: true
  def valid_transition?(:op, :preop), do: true
  def valid_transition?(:bootstrap, :preop), do: true
  def valid_transition?(:bootstrap, :init), do: true
  def valid_transition?(_from, _to), do: false

  defp apply_transition(slave, target_state) do
    if valid_transition?(slave.state, target_state) do
      case Behaviour.transition(
             slave.behavior,
             slave.state,
             target_state,
             slave,
             slave.behavior_state
           ) do
        {:ok, behavior_state} ->
          updated_slave =
            slave
            |> Map.put(:behavior_state, behavior_state)
            |> commit_state(target_state, false, @alerr_none)

          {:ok, updated_slave}

        {:error, status_code, behavior_state} ->
          updated_slave =
            slave
            |> Map.put(:behavior_state, behavior_state)
            |> commit_state(slave.state, true, status_code)

          {:error, updated_slave}
      end
    else
      {:error, commit_state(slave, slave.state, true, @alerr_invalid_state_change)}
    end
  end

  defp decode_request(0x01), do: {:ok, :init}
  defp decode_request(0x02), do: {:ok, :preop}
  defp decode_request(0x03), do: {:ok, :bootstrap}
  defp decode_request(0x04), do: {:ok, :safeop}
  defp decode_request(0x08), do: {:ok, :op}
  defp decode_request(_request), do: :error

  defp commit_state(slave, state, error?, status_code) do
    slave
    |> Map.put(:state, state)
    |> Map.put(:al_error?, error?)
    |> Map.put(:al_status_code, status_code)
    |> write_memory(@al_status, encode_status(state, error?))
    |> write_memory(@al_status_code, <<status_code::16-little>>)
  end

  defp encode_status(al_state, error?) do
    state_code =
      case al_state do
        :init -> 0x01
        :preop -> 0x02
        :bootstrap -> 0x03
        :safeop -> 0x04
        :op -> 0x08
      end

    error_bit = if error?, do: 1, else: 0
    <<0::3, error_bit::1, state_code::4, 0::8>>
  end

  defp write_memory(%{memory: memory} = slave, offset, data) do
    %{slave | memory: replace_binary(memory, offset, data)}
  end

  defp replace_binary(binary, offset, value) do
    prefix = binary_part(binary, 0, offset)
    suffix_offset = offset + byte_size(value)
    suffix = binary_part(binary, suffix_offset, byte_size(binary) - suffix_offset)
    prefix <> value <> suffix
  end
end
