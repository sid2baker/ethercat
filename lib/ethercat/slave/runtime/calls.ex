defmodule EtherCAT.Slave.Runtime.Calls do
  @moduledoc false

  alias EtherCAT.Slave
  alias EtherCAT.Slave.Mailbox
  alias EtherCAT.Slave.Runtime.Bootstrap
  alias EtherCAT.Slave.Runtime.Configuration
  alias EtherCAT.Slave.Runtime.Outputs
  alias EtherCAT.Slave.Runtime.DeviceState
  alias EtherCAT.Slave.Runtime.Signals
  alias EtherCAT.Slave.Runtime.Status

  @type handler_opts :: [
          paths: %{optional({atom(), atom()}) => [atom()]},
          initialize_to_preop: (%Slave{} -> Bootstrap.init_result()),
          walk_path: (%Slave{}, [atom()] ->
                        {:ok, %Slave{}} | {:error, term(), %Slave{}})
        ]

  @spec handle(term(), term(), atom(), %Slave{}, handler_opts()) ::
          :gen_statem.event_handler_result(atom())
  def handle(from, :state, state, _data, _opts) do
    {:keep_state_and_data, [{:reply, from, state}]}
  end

  def handle(from, :identity, _state, data, _opts) do
    {:keep_state_and_data, [{:reply, from, data.identity}]}
  end

  def handle(from, :error, _state, data, _opts) do
    {:keep_state_and_data, [{:reply, from, data.error_code}]}
  end

  def handle(from, :info, state, data, _opts) do
    {:keep_state_and_data, [{:reply, from, {:ok, Status.info_snapshot(state, data)}}]}
  end

  def handle(from, :snapshot, state, data, _opts) do
    {:keep_state_and_data, [{:reply, from, {:ok, DeviceState.snapshot(state, data)}}]}
  end

  def handle(from, :capabilities, _state, data, _opts) do
    {:keep_state_and_data,
     [{:reply, from, EtherCAT.Driver.Runtime.capabilities(data.driver, data.config || %{})}]}
  end

  def handle(from, {:request, target}, state, _data, _opts) when state == target do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def handle(
        from,
        {:request, target},
        :preop,
        %{configuration_error: reason},
        _opts
      )
      when target in [:safeop, :op] and not is_nil(reason) do
    {:keep_state_and_data, [{:reply, from, {:error, {:preop_configuration_failed, reason}}}]}
  end

  def handle(from, {:request, target}, state, data, opts) do
    case Map.get(Keyword.fetch!(opts, :paths), {state, target}) do
      nil ->
        {:keep_state_and_data, [{:reply, from, {:error, :invalid_transition}}]}

      steps ->
        case Keyword.fetch!(opts, :walk_path).(data, steps) do
          {:ok, new_data} ->
            {:next_state, target, new_data, [{:reply, from, :ok}]}

          {:error, reason, new_data} ->
            {:keep_state, new_data, [{:reply, from, {:error, reason}}]}
        end
    end
  end

  def handle(from, {:configure, opts}, :preop, data, _handler_opts) do
    case Configuration.maybe_reconfigure_preop(data, opts) do
      {:ok, new_data} ->
        {:keep_state, new_data, [{:reply, from, :ok}]}

      {:error, reason, new_data} ->
        {:keep_state, new_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle(from, {:configure, _opts}, _state, _data, _handler_opts) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_preop}}]}
  end

  def handle(from, :retry_preop_configuration, :preop, %{configuration_error: nil}, _handler_opts) do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def handle(from, :retry_preop_configuration, :preop, data, _handler_opts) do
    case Configuration.retry_failed_preop(data) do
      {:ok, new_data} ->
        {:keep_state, new_data, [{:reply, from, :ok}]}

      {:error, reason, new_data} ->
        {:keep_state, new_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle(from, :retry_preop_configuration, _state, _data, _handler_opts) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_preop}}]}
  end

  def handle(from, {:subscribe, signal_name, pid}, _state, data, _opts) do
    case Signals.subscribe_pid(data, signal_name, pid) do
      {:ok, new_data} ->
        {:keep_state, new_data, [{:reply, from, :ok}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle(from, {:subscribe_events, pid}, _state, data, _opts) do
    {:keep_state, DeviceState.event_subscribe(data, pid), [{:reply, from, :ok}]}
  end

  def handle(from, {:write_output, _signal_name, _value}, :down, _data, _opts) do
    {:keep_state_and_data, [{:reply, from, {:error, :slave_down}}]}
  end

  def handle(from, {:write_output, signal_name, value}, _state, data, _opts) do
    previous_value = Map.get(DeviceState.signal_image(data), signal_name, :unset)

    case Outputs.write_signal(data, signal_name, value) do
      {:ok, new_data} ->
        updated_at_us = System.monotonic_time(:microsecond)
        next_data = DeviceState.record_output_value(new_data, signal_name, value, updated_at_us)

        if previous_value != value do
          dispatch_output_event(next_data, signal_name, value, updated_at_us)
        end

        {:keep_state, next_data, [{:reply, from, :ok}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle(from, {:read_input, signal_name}, _state, data, _opts) do
    {:keep_state_and_data, [{:reply, from, Signals.read_input(data, signal_name)}]}
  end

  def handle(from, {:command, _command_name, _args}, :down, _data, _opts) do
    {:keep_state_and_data, [{:reply, from, {:error, :slave_down}}]}
  end

  def handle(from, {:command, command_name, args}, _state, data, _opts)
      when is_atom(command_name) and is_map(args) do
    case DeviceState.command(data, command_name, args) do
      {:ok, ref, new_data} ->
        {:keep_state, new_data, [{:reply, from, {:ok, ref}}]}

      {:error, reason, new_data} ->
        {:keep_state, new_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle(from, {:download_sdo, index, subindex, sdo_data}, state, data, _opts)
      when state in [:preop, :safeop, :op] do
    case Mailbox.download_sdo(data, index, subindex, sdo_data) do
      {:ok, new_data} ->
        {:keep_state, new_data, [{:reply, from, :ok}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle(from, {:download_sdo, _index, _subindex, _sdo_data}, _state, _data, _opts) do
    {:keep_state_and_data, [{:reply, from, {:error, :mailbox_not_ready}}]}
  end

  def handle(from, {:upload_sdo, index, subindex}, state, data, _opts)
      when state in [:preop, :safeop, :op] do
    case Mailbox.upload_sdo(data, index, subindex) do
      {:ok, value, new_data} ->
        {:keep_state, new_data, [{:reply, from, {:ok, value}}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle(from, {:upload_sdo, _index, _subindex}, _state, _data, _opts) do
    {:keep_state_and_data, [{:reply, from, {:error, :mailbox_not_ready}}]}
  end

  defp dispatch_output_event(data, signal_name, value, updated_at_us) do
    event =
      EtherCAT.Event.signal_changed(
        data.name,
        signal_name,
        value,
        data.device_cycle,
        updated_at_us
      )

    DeviceState.dispatch_event(data, event)
  end
end
