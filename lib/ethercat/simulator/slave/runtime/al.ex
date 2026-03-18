defmodule EtherCAT.Simulator.Slave.Runtime.AL do
  @moduledoc false

  alias EtherCAT.Slave.ESC.Registers
  alias EtherCAT.Simulator.Slave.Behaviour
  alias EtherCAT.Simulator.Slave.Runtime.Logical
  alias EtherCAT.Simulator.Slave.Runtime.Memory

  @alerr_none 0x0000
  @alerr_invalid_state_change 0x0011
  @alerr_unknown_state 0x0012
  @alerr_invalid_mailbox_config 0x0016
  @alerr_invalid_output_config 0x001D
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

  @spec reset_to_init(map()) :: map()
  def reset_to_init(slave) do
    commit_state(slave, :init, false, @alerr_none)
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
      with :ok <- validate_transition_configuration(slave, target_state) do
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
        {:error, status_code} ->
          {:error, commit_state(slave, slave.state, true, status_code)}
      end
    else
      {:error, commit_state(slave, slave.state, true, @alerr_invalid_state_change)}
    end
  end

  defp validate_transition_configuration(slave, :preop), do: validate_mailbox_config(slave)

  defp validate_transition_configuration(slave, state) when state in [:safeop, :op] do
    with :ok <- validate_mailbox_config(slave),
         :ok <- validate_process_data_config(slave) do
      :ok
    end
  end

  defp validate_transition_configuration(_slave, _target_state), do: :ok

  defp validate_mailbox_config(%{mailbox_config: %{recv_size: 0, send_size: 0}}), do: :ok

  defp validate_mailbox_config(%{mailbox_config: mailbox_config, memory: memory}) do
    with :ok <-
           validate_sync_manager(
             memory,
             0,
             mailbox_config.recv_offset,
             mailbox_config.recv_size,
             0x26
           ),
         :ok <-
           validate_sync_manager(
             memory,
             1,
             mailbox_config.send_offset,
             mailbox_config.send_size,
             0x22
           ) do
      :ok
    else
      :error -> {:error, @alerr_invalid_mailbox_config}
    end
  end

  defp validate_process_data_config(%{output_size: output_size, input_size: input_size} = slave) do
    with :ok <-
           validate_process_data_sync_manager(
             slave.memory,
             2,
             slave.output_phys,
             output_size,
             0x24
           ),
         :ok <-
           validate_process_data_sync_manager(slave.memory, 3, slave.input_phys, input_size, 0x20),
         :ok <- validate_process_data_fmmu(slave, 0x02, slave.output_phys, output_size),
         :ok <- validate_process_data_fmmu(slave, 0x01, slave.input_phys, input_size) do
      :ok
    else
      :error -> {:error, @alerr_invalid_output_config}
    end
  end

  defp validate_process_data_sync_manager(_memory, _index, _start, 0, _control), do: :ok

  defp validate_process_data_sync_manager(memory, index, start, size, control) do
    validate_sync_manager(memory, index, start, size, control)
  end

  defp validate_process_data_fmmu(_slave, _type, _phys_start, 0), do: :ok

  defp validate_process_data_fmmu(slave, type, phys_start, size) do
    if Logical.maps_physical_region?(slave, type, phys_start, size) do
      :ok
    else
      :error
    end
  end

  defp validate_sync_manager(memory, index, start, size, control) do
    if read_u16(memory, offset(Registers.sm_start(index))) == start and
         read_u16(memory, offset(Registers.sm_length(index))) == size and
         read_u8(memory, offset(Registers.sm_control(index))) == control and
         read_u8(memory, offset(Registers.sm_activate(index))) == 0x01 do
      :ok
    else
      :error
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
    |> write_memory(@al_status, Memory.encode_al_status(state, error?))
    |> write_memory(@al_status_code, <<status_code::16-little>>)
  end

  defp write_memory(%{memory: memory} = slave, offset, data) do
    %{slave | memory: Memory.replace(memory, offset, data)}
  end

  defp offset({offset, _length}), do: offset

  defp read_u8(memory, offset) do
    <<value::8>> = binary_part(memory, offset, 1)
    value
  end

  defp read_u16(memory, offset) do
    <<value::16-little>> = binary_part(memory, offset, 2)
    value
  end
end
