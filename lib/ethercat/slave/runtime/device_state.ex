defmodule EtherCAT.Slave.Runtime.DeviceState do
  @moduledoc false

  alias EtherCAT.Domain
  alias EtherCAT.Domain.Freshness
  alias EtherCAT.Slave
  alias EtherCAT.Driver
  alias EtherCAT.Event
  alias EtherCAT.SlaveDescription
  alias EtherCAT.SlaveSnapshot
  alias EtherCAT.Slave.Runtime.Outputs
  alias EtherCAT.Slave.Runtime.Signals

  @type slave_snapshot :: SlaveSnapshot.t()

  @spec initialize(%Slave{}) :: %Slave{}
  def initialize(%Slave{} = data) do
    case Driver.Runtime.init_state(data.driver, data.config || %{}) do
      {:ok, driver_state} ->
        %{
          data
          | driver_state: driver_state,
            device_state: %{},
            output_state: %{},
            device_faults: [],
            device_cycle: nil,
            device_updated_at_us: nil,
            driver_error: nil
        }

      {:error, reason} ->
        %{
          data
          | driver_state: %{},
            device_state: %{},
            output_state: %{},
            device_faults: [{:driver_init_failed, reason}],
            device_cycle: nil,
            device_updated_at_us: nil,
            driver_error: {:driver_init_failed, reason}
        }
    end
  end

  @spec refresh(%Slave{}, integer(), integer(), [atom()]) :: %Slave{}
  def refresh(data, cycle, updated_at_us, changed_signal_names \\ [])

  def refresh(%Slave{} = data, cycle, updated_at_us, changed_signal_names)
      when is_integer(cycle) and cycle >= 0 and is_integer(updated_at_us) do
    previous_state = public_state(data)

    with {:ok, decoded_inputs} <- decoded_inputs(data),
         {:ok, next_state, next_driver_state, notices, faults} <-
           Driver.Runtime.project_state(
             data.driver,
             decoded_inputs,
             empty_to_nil(data.device_state),
             data.driver_state,
             data.config || %{}
           ) do
      updated =
        %{
          data
          | driver_state: next_driver_state,
            device_state: next_state,
            device_faults: faults,
            device_cycle: cycle,
            device_updated_at_us: updated_at_us,
            driver_error: nil
        }

      signal_events =
        if initialized_projection?(data) do
          signal_events(data.name, previous_state, public_state(updated), cycle, updated_at_us)
        else
          []
        end

      Signals.dispatch_sampled_inputs(updated, changed_signal_names, decoded_inputs)

      dispatch_events(
        updated,
        signal_events ++
          fault_events(data.name, data.device_faults, faults, cycle, updated_at_us) ++
          notice_events(data.name, notices, cycle, updated_at_us)
      )

      updated
    else
      {:error, :not_ready} ->
        data

      {:error, {:stale, _details}} ->
        data

      {:error, reason} ->
        updated =
          %{
            data
            | device_faults: [{:driver_update_failed, reason}],
              device_cycle: cycle,
              device_updated_at_us: updated_at_us,
              driver_error: {:driver_update_failed, reason}
          }

        dispatch_events(
          updated,
          fault_events(
            data.name,
            data.device_faults,
            updated.device_faults,
            cycle,
            updated_at_us
          )
        )

        updated
    end
  end

  @spec snapshot(atom(), %Slave{}) :: slave_snapshot()
  def snapshot(al_state, %Slave{} = data) do
    description =
      effective_description(data,
        al_state: al_state,
        updated_at_us: data.device_updated_at_us,
        faults: data.device_faults || []
      )

    %SlaveSnapshot{
      name: data.name,
      driver: data.driver,
      al_state: al_state,
      cycle: data.device_cycle,
      device_type: description.device_type,
      endpoints: description.endpoints,
      commands: description.commands,
      state: public_state(data, description),
      faults: data.device_faults || [],
      updated_at_us: data.device_updated_at_us,
      driver_error: data.driver_error
    }
  end

  @spec command(%Slave{}, atom(), map()) ::
          {:ok, reference(), %Slave{}} | {:error, term(), %Slave{}}
  def command(%Slave{} = data, command_name, args) when is_atom(command_name) and is_map(args) do
    with :ok <- validate_command_args(command_name, args) do
      ref = make_ref()
      ts = System.monotonic_time(:microsecond)
      cycle = data.device_cycle

      command = %{
        ref: ref,
        name: command_name,
        args: resolve_command_args(data, command_name, args)
      }

      previous_state = public_state(data)

      case do_command(data, command, previous_state) do
        {:ok, next_data, notices} ->
          dispatch_events(
            next_data,
            signal_events(data.name, previous_state, public_state(next_data), cycle, ts) ++
              [Event.internal(data.name, {:command_accepted, ref}, cycle, ts)] ++
              notice_events(data.name, notices, cycle, ts)
          )

          {:ok, ref, next_data}

        {:error, reason, next_data} ->
          dispatch_events(
            next_data,
            [Event.internal(data.name, {:command_failed, ref, reason}, cycle, ts)]
          )

          {:error, reason, next_data}
      end
    else
      {:error, reason} ->
        {:error, reason, data}
    end
  end

  defp do_command(data, command, _previous_public_state) do
    with {:ok, output_intents, next_driver_state, notices} <-
           Driver.Runtime.command(
             data.driver,
             command,
             signal_image(data),
             data.driver_state,
             data.config || %{}
           ),
         {:ok, output_data} <- apply_output_intents(data, output_intents) do
      {:ok, %{output_data | driver_state: next_driver_state, driver_error: nil}, notices}
    else
      {:error, reason} ->
        {:error, reason, data}
    end
  end

  @spec signal_image(%Slave{}) :: map()
  def signal_image(%Slave{} = data) do
    Map.merge(data.device_state || %{}, data.output_state || %{})
  end

  @spec public_state(%Slave{}, SlaveDescription.t() | nil) :: map()
  def public_state(%Slave{} = data, _description \\ nil), do: signal_image(data)

  @spec decoded_inputs(%Slave{}) :: {:ok, map()} | {:error, term()}
  def decoded_inputs(%Slave{signal_registrations: registrations} = data)
      when is_map(registrations) do
    registrations
    |> Enum.filter(fn {_name, registration} -> registration.direction == :input end)
    |> Enum.reduce_while({:ok, %{}}, fn {signal_name, registration}, {:ok, acc} ->
      case read_input_value(data, signal_name, registration) do
        {:ok, value} ->
          {:cont, {:ok, Map.put(acc, signal_name, value)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  def decoded_inputs(_data), do: {:ok, %{}}

  @spec event_subscribe(%Slave{}, pid()) :: %Slave{}
  def event_subscribe(%Slave{} = data, pid) when is_pid(pid) do
    refs =
      if Map.has_key?(data.subscriber_refs, pid) do
        data.subscriber_refs
      else
        Map.put(data.subscriber_refs, pid, Process.monitor(pid))
      end

    %{
      data
      | subscriber_refs: refs,
        event_subscriptions: MapSet.put(data.event_subscriptions, pid)
    }
  end

  defp read_input_value(data, signal_name, registration) do
    case Domain.sample(registration.domain_id, {data.name, registration.sm_key}) do
      {:error, _} = err ->
        err

      {:ok, %{freshness: %{state: :not_ready}}} ->
        {:error, :not_ready}

      {:ok, %{freshness: %{state: :stale} = freshness}} ->
        {:error, {:stale, Freshness.stale_details(freshness)}}

      {:ok, %{value: sm_bytes, freshness: %{state: :fresh}}} ->
        raw = Signals.extract_sm_bits(sm_bytes, registration.bit_offset, registration.bit_size)
        {:ok, data.driver.decode_signal(signal_name, data.config, raw)}
    end
  end

  defp effective_description(data, opts) do
    SlaveDescription.configured(
      data.name,
      data.driver,
      data.config || %{},
      opts
    )
  end

  defp validate_command_args(:set_output, %{signal: signal_name, value: _value})
       when is_atom(signal_name),
       do: :ok

  defp validate_command_args(:set_output, %{signal: signal_name})
       when is_atom(signal_name),
       do: {:error, :invalid_output_value}

  defp validate_command_args(:set_output, _args), do: {:error, :invalid_output_signal}
  defp validate_command_args(_command_name, _args), do: :ok
  defp resolve_command_args(_data, _command_name, args), do: args

  defp apply_output_intents(data, intents) do
    updated_at_us = System.monotonic_time(:microsecond)

    with {:ok, next_data} <- Outputs.write_signals(data, intents) do
      {:ok,
       Enum.reduce(intents, next_data, fn
         {:write, signal_name, value}, current_data ->
           record_output_value(current_data, signal_name, value, updated_at_us)

         _other, current_data ->
           current_data
       end)}
    end
  end

  defp dispatch_events(%Slave{} = data, events) when is_list(events) do
    Enum.each(events, &dispatch_event(data, &1))
  end

  @spec record_output_value(%Slave{}, atom(), term(), integer()) :: %Slave{}
  def record_output_value(%Slave{} = data, signal_name, value, updated_at_us)
      when is_atom(signal_name) and is_integer(updated_at_us) do
    %{
      data
      | output_state: Map.put(data.output_state || %{}, signal_name, value),
        device_updated_at_us: updated_at_us
    }
  end

  @spec dispatch_event(%Slave{}, Event.t()) :: :ok
  def dispatch_event(%Slave{event_subscriptions: subscribers}, %Event{} = event) do
    Enum.each(subscribers || MapSet.new(), fn pid ->
      send(pid, event)
    end)

    dispatch_public_event(event)
    :ok
  end

  @spec dispatch_public_event(Event.t()) :: :ok
  def dispatch_public_event(%Event{slave: slave} = event) do
    subscribers =
      lookup_public_subscribers(:all) ++
        if(is_atom(slave), do: lookup_public_subscribers({:slave, slave}), else: [])

    subscribers
    |> MapSet.new()
    |> Enum.each(&send(&1, event))

    :ok
  end

  defp lookup_public_subscribers(key) do
    case Process.whereis(EtherCAT.SubscriptionRegistry) do
      nil ->
        []

      _registry_pid ->
        EtherCAT.SubscriptionRegistry
        |> Registry.lookup(key)
        |> Enum.map(&elem(&1, 0))
    end
  end

  defp signal_events(slave, previous, current, cycle, ts) do
    previous = previous || %{}
    current = current || %{}
    missing = make_ref()

    previous
    |> Map.keys()
    |> Kernel.++(Map.keys(current))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce([], fn signal_name, acc ->
      previous_value = Map.get(previous, signal_name, missing)
      current_value = Map.get(current, signal_name, missing)

      if previous_value == current_value do
        acc
      else
        value = if current_value == missing, do: nil, else: current_value
        [Event.signal_changed(slave, signal_name, value, cycle, ts) | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp fault_events(slave, previous, current, cycle, ts) do
    previous = previous || []
    current = current || []

    raised =
      Enum.reduce(current, [], fn fault, acc ->
        if fault in previous,
          do: acc,
          else: [Event.fault_raised(slave, fault, %{}, cycle, ts) | acc]
      end)
      |> Enum.reverse()

    cleared =
      Enum.reduce(previous, [], fn fault, acc ->
        if fault in current,
          do: acc,
          else: [Event.fault_cleared(slave, fault, %{}, cycle, ts) | acc]
      end)
      |> Enum.reverse()

    raised ++ cleared
  end

  defp notice_events(slave, notices, cycle, ts) do
    Enum.map(notices || [], &Event.internal(slave, &1, cycle, ts))
  end

  defp initialized_projection?(%Slave{device_cycle: nil, device_state: state})
       when is_map(state) and map_size(state) == 0,
       do: false

  defp initialized_projection?(%Slave{device_cycle: nil, device_state: nil}), do: false

  defp initialized_projection?(_data), do: true

  defp empty_to_nil(%{} = map) when map_size(map) == 0, do: nil
  defp empty_to_nil(map), do: map
end
