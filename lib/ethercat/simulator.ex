defmodule EtherCAT.Simulator do
  @moduledoc File.read!(Path.join(__DIR__, "simulator.md"))

  use GenServer

  alias EtherCAT.Bus.Datagram
  alias EtherCAT.Simulator.Fault
  alias EtherCAT.Simulator.RawSocket
  alias EtherCAT.Simulator.Runtime.Faults
  alias EtherCAT.Simulator.Runtime.Milestones
  alias EtherCAT.Simulator.Runtime.Router
  alias EtherCAT.Simulator.Runtime.Snapshot
  alias EtherCAT.Simulator.Runtime.Topology
  alias EtherCAT.Simulator.State
  alias EtherCAT.Simulator.Slave.Runtime.Device
  alias EtherCAT.Simulator.Runtime.Subscriptions
  alias EtherCAT.Simulator.Runtime.Wiring

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

  @type exchange_fault ::
          :drop_responses
          | {:wkc_offset, integer()}
          | {:command_wkc_offset,
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
             | :frmw, integer()}
          | {:logical_wkc_offset, atom(), integer()}
          | {:disconnect, atom()}

  @type milestone ::
          {:healthy_exchanges, pos_integer()}
          | {:healthy_polls, atom(), pos_integer()}
          | {:mailbox_step, atom(),
             :upload_init | :upload_segment | :download_init | :download_segment, pos_integer()}
  @type slave_fault ::
          {:retreat_to_safeop, atom()}
          | {:latch_al_error, atom(), non_neg_integer()}
          | {:mailbox_abort, atom(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
          | {:mailbox_abort, atom(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
             :request | :upload_segment | :download_segment}
          | {:mailbox_protocol_fault, atom(), non_neg_integer(), non_neg_integer(),
             :request | :upload_init | :upload_segment | :download_init | :download_segment,
             :drop_response
             | :counter_mismatch
             | :toggle_mismatch
             | {:mailbox_type, 0..15}
             | {:coe_service, 0..15}
             | :invalid_coe_payload
             | {:sdo_command, 0..255}
             | :invalid_segment_padding
             | {:segment_command, 0..255}}

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

  @type signal_ref :: {atom(), atom()}
  @type connection :: %{
          source: signal_ref(),
          target: signal_ref()
        }

  @default_name __MODULE__
  @supervisor EtherCAT.Simulator.Supervisor

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: @default_name,
      start: {__MODULE__, :start, [opts]}
    }
  end

  @spec start(keyword()) :: Supervisor.on_start() | {:error, term()}
  def start(opts) do
    with {:ok, normalized_opts} <- normalize_start_opts(opts) do
      EtherCAT.Simulator.Supervisor.start_link(normalized_opts)
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: @default_name)

  @spec stop() :: :ok
  def stop, do: stop_root()

  defp stop_root do
    case Process.whereis(@supervisor) do
      nil -> stop_named_process(@default_name)
      _pid -> stop_named_process(@supervisor)
    end
  end

  @spec process_datagrams([Datagram.t()]) ::
          {:ok, [Datagram.t()]} | {:error, :no_response | :not_found | :timeout}
  def process_datagrams(datagrams),
    do: process_datagrams(datagrams, [])

  @doc false
  @spec process_datagrams([Datagram.t()], keyword()) ::
          {:ok, [Datagram.t()]} | {:error, :no_response | :not_found | :timeout}
  def process_datagrams(datagrams, opts) when is_list(opts),
    do: safe_call({:process_datagrams, datagrams, opts}, 5_000)

  @spec info() :: {:ok, map()} | {:error, :not_found | :timeout}
  def info do
    with {:ok, info} <- safe_call(:info, 5_000) do
      {:ok, info |> maybe_put_default_udp_info() |> maybe_put_default_raw_info()}
    end
  end

  @spec device_snapshot(atom()) :: {:ok, map()} | {:error, :not_found | :timeout}
  def device_snapshot(slave_name), do: safe_call({:device_snapshot, slave_name}, 5_000)

  @spec signal_snapshot(atom(), atom()) ::
          {:ok, map()} | {:error, :not_found | :unknown_signal | :timeout}
  def signal_snapshot(slave_name, signal_name),
    do: safe_call({:signal_snapshot, slave_name, signal_name}, 5_000)

  @spec inject_fault(Fault.t() | fault()) ::
          :ok | {:error, :invalid_fault | :not_found | :timeout}
  def inject_fault(fault) do
    case Fault.normalize(fault) do
      {:ok, normalized_fault} -> safe_call({:inject_fault, normalized_fault}, 5_000)
      :error -> {:error, :invalid_fault}
    end
  end

  @spec clear_faults() :: :ok | {:error, :not_found | :timeout}
  def clear_faults, do: safe_call(:clear_faults, 5_000)

  @spec set_topology(:linear | :redundant | {:redundant, keyword()}) ::
          :ok | {:error, :invalid_topology | :not_found | :timeout}
  def set_topology(topology), do: safe_call({:set_topology, topology}, 5_000)

  @spec signals(atom()) :: {:ok, [atom()]} | {:error, :not_found | :timeout}
  def signals(slave_name), do: safe_call({:signals, slave_name}, 5_000)

  @spec signal_definitions(atom()) ::
          {:ok, %{optional(atom()) => map()}} | {:error, :not_found | :timeout}
  def signal_definitions(slave_name),
    do: safe_call({:signal_definitions, slave_name}, 5_000)

  @spec get_value(atom(), atom()) ::
          {:ok, term()} | {:error, :not_found | :unknown_signal | :timeout}
  def get_value(slave_name, signal_name),
    do: safe_call({:get_value, slave_name, signal_name}, 5_000)

  @spec set_value(atom(), atom(), term()) ::
          :ok | {:error, :not_found | :unknown_signal | :invalid_value | :timeout}
  def set_value(slave_name, signal_name, value),
    do: safe_call({:set_value, slave_name, signal_name, value}, 5_000)

  @spec connections() :: {:ok, [connection()]} | {:error, :not_found | :timeout}
  def connections, do: safe_call(:connections, 5_000)

  @spec connect(signal_ref(), signal_ref()) ::
          :ok | {:error, :not_found | :unknown_signal | :invalid_value | :timeout}
  def connect(source, target), do: safe_call({:connect, source, target}, 5_000)

  @spec disconnect(signal_ref(), signal_ref()) :: :ok | {:error, :not_found | :timeout}
  def disconnect(source, target),
    do: safe_call({:disconnect, source, target}, 5_000)

  @spec subscribe(atom(), atom() | :all, pid()) :: :ok | {:error, :not_found | :timeout}
  def subscribe(slave_name, signal_name \\ :all, subscriber \\ self()) do
    safe_call({:subscribe, slave_name, signal_name, subscriber}, 5_000)
  end

  @spec unsubscribe(atom(), atom() | :all, pid()) :: :ok | {:error, :not_found | :timeout}
  def unsubscribe(slave_name, signal_name \\ :all, subscriber \\ self()) do
    safe_call({:unsubscribe, slave_name, signal_name, subscriber}, 5_000)
  end

  @spec output_image(atom()) :: {:ok, binary()} | {:error, :not_found | :timeout}
  def output_image(slave_name), do: safe_call({:output_image, slave_name}, 5_000)

  @impl true
  def init(opts) do
    devices = Keyword.get(opts, :devices, [])

    topology =
      opts
      |> Keyword.get(:topology)
      |> Topology.normalize(length(devices))

    with {:ok, topology} <- topology do
      slaves =
        devices
        |> Enum.with_index()
        |> Enum.map(fn {definition, position} -> Device.new(definition, position) end)

      {:ok, State.new(slaves, topology)}
    else
      {:error, :invalid_topology} ->
        {:stop, :invalid_topology}
    end
  end

  defp normalize_start_opts(opts) do
    cond do
      Keyword.has_key?(opts, :udp) ->
        {:ok, opts}

      Keyword.has_key?(opts, :raw) ->
        {:ok, opts}

      Keyword.has_key?(opts, :ip) or Keyword.has_key?(opts, :port) ->
        {:error,
         {:invalid_options, "use udp: [ip: ..., port: ...] when starting UDP simulator runtime"}}

      Keyword.has_key?(opts, :interface) ->
        {:error,
         {:invalid_options, "use raw: [interface: ...] when starting raw simulator runtime"}}

      true ->
        {:ok, opts}
    end
  end

  defp safe_call(message, timeout) do
    GenServer.call(@default_name, message, timeout)
  catch
    :exit, reason -> classify_call_exit(reason)
  end

  defp classify_call_exit({:timeout, _}), do: {:error, :timeout}
  defp classify_call_exit(_reason), do: {:error, :not_found}

  defp maybe_put_default_udp_info(info) do
    case EtherCAT.Simulator.Udp.info() do
      {:ok, udp_info} -> Map.put(info, :udp, udp_info)
      {:error, _reason} -> info
    end
  end

  defp maybe_put_default_raw_info(info) do
    case RawSocket.infos() do
      {:ok, raw_info} -> Map.put(info, :raw, raw_info)
      {:error, _reason} -> info
    end
  end

  defp stop_named_process(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      _pid ->
        try do
          GenServer.stop(name)
        catch
          :exit, _reason -> :ok
        end
    end
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply, {:ok, Snapshot.simulator(state)}, state}
  end

  @impl true
  def handle_call(
        {:process_datagrams, datagrams, opts},
        _from,
        %{slaves: slaves, faults: faults, topology: topology} = state
      ) do
    {planned_fault_entry, faults} = Faults.pop_pending(faults)
    effective_faults = Faults.apply_pending(faults, planned_fault_entry)
    state = %{state | faults: faults}
    ingress = Keyword.get(opts, :ingress)

    if effective_faults.drop_responses? do
      {:reply, {:error, :no_response}, maybe_resume_fault_script(state, planned_fault_entry)}
    else
      before_signals = Wiring.capture_signal_values(slaves)

      {responses, slaves} =
        Router.process_datagrams(
          datagrams,
          slaves,
          effective_faults.disconnected,
          effective_faults.wkc_offset,
          effective_faults.command_wkc_offsets,
          effective_faults.logical_wkc_offsets,
          topology,
          ingress
        )

      state =
        %{state | slaves: slaves}
        |> finalize_signal_changes(before_signals)
        |> maybe_trigger_milestone_faults(
          datagrams,
          responses,
          faults,
          fault_entry_fault(planned_fault_entry)
        )
        |> maybe_resume_fault_script(planned_fault_entry)

      {:reply, {:ok, responses}, state}
    end
  end

  def handle_call({:process_datagrams, datagrams}, from, state) do
    handle_call({:process_datagrams, datagrams, []}, from, state)
  end

  def handle_call({:inject_fault, fault}, _from, state) do
    case inject_fault_into_state(state, fault) do
      {:ok, state} ->
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:clear_faults, _from, state) do
    before_signals = Wiring.capture_signal_values(state.slaves)
    slaves = Enum.map(state.slaves, &Device.clear_faults/1)
    clear_scheduled_faults(state.scheduled_faults)

    state =
      %{state | slaves: slaves, faults: Faults.clear(state.faults), scheduled_faults: []}
      |> finalize_signal_changes(before_signals)

    {:reply, :ok, state}
  end

  def handle_call({:set_topology, topology}, _from, %{slaves: slaves} = state) do
    case Topology.normalize(topology, length(slaves)) do
      {:ok, normalized_topology} ->
        {:reply, :ok, %{state | topology: normalized_topology}}

      {:error, :invalid_topology} ->
        {:reply, {:error, :invalid_topology}, state}
    end
  end

  def handle_call({:signals, slave_name}, _from, %{slaves: slaves} = state) do
    reply =
      case fetch_named_slave(slaves, slave_name) do
        {:ok, slave} -> {:ok, slave |> Device.signals() |> Map.keys()}
        {:error, :not_found} -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:device_snapshot, slave_name}, _from, state) do
    {:reply, Snapshot.device(state, slave_name), state}
  end

  def handle_call({:signal_snapshot, slave_name, signal_name}, _from, state) do
    {:reply, Snapshot.signal(state, slave_name, signal_name), state}
  end

  def handle_call({:signal_definitions, slave_name}, _from, %{slaves: slaves} = state) do
    reply =
      case fetch_named_slave(slaves, slave_name) do
        {:ok, slave} -> {:ok, Device.signals(slave)}
        {:error, :not_found} -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:get_value, slave_name, signal_name}, _from, %{slaves: slaves} = state) do
    reply =
      case fetch_named_slave(slaves, slave_name) do
        {:ok, slave} -> Device.get_value(slave, signal_name)
        {:error, :not_found} -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:set_value, slave_name, signal_name, value}, _from, %{slaves: slaves} = state) do
    before_signals = Wiring.capture_signal_values(slaves)

    case update_named_slave(slaves, slave_name, &Device.set_value(&1, signal_name, value)) do
      {:ok, updated_slaves} ->
        state = %{state | slaves: updated_slaves} |> finalize_signal_changes(before_signals)

        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:connections, _from, state) do
    {:reply, {:ok, Snapshot.connections(state)}, state}
  end

  def handle_call(
        {:connect, {source_slave, source_signal}, {target_slave, target_signal}},
        _from,
        state
      ) do
    before_signals = Wiring.capture_signal_values(state.slaves)

    with {:ok, connections, slaves} <-
           Wiring.connect(
             state.slaves,
             state.connections,
             {source_slave, source_signal},
             {target_slave, target_signal}
           ) do
      state =
        %{state | connections: connections, slaves: slaves}
        |> finalize_signal_changes(before_signals)

      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:disconnect, source, target}, _from, state) do
    case Wiring.disconnect(state.connections, source, target) do
      {:ok, connections} ->
        {:reply, :ok, %{state | connections: connections}}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:subscribe, slave_name, signal_name, subscriber}, _from, state) do
    case Subscriptions.subscribe(
           state.subscriptions,
           state.slaves,
           slave_name,
           signal_name,
           subscriber
         ) do
      {:ok, subscriptions} ->
        {:reply, :ok, %{state | subscriptions: subscriptions}}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:unsubscribe, slave_name, signal_name, subscriber}, _from, state) do
    case Subscriptions.unsubscribe(
           state.subscriptions,
           state.slaves,
           slave_name,
           signal_name,
           subscriber
         ) do
      {:ok, subscriptions} ->
        {:reply, :ok, %{state | subscriptions: subscriptions}}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:output_image, slave_name}, _from, %{slaves: slaves} = state) do
    reply =
      case fetch_named_slave(slaves, slave_name) do
        {:ok, slave} -> {:ok, Device.output_image(slave)}
        {:error, :not_found} -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscriptions: Subscriptions.handle_down(state.subscriptions, ref, pid)}}
  end

  def handle_info({:apply_scheduled_fault, id, fault}, state) do
    case pop_scheduled_fault(state.scheduled_faults, id) do
      {:ok, _entry, scheduled_faults} ->
        state = %{state | scheduled_faults: scheduled_faults}

        case inject_fault_into_state(state, fault) do
          {:ok, state} -> {:noreply, state}
          {:error, _reason} -> {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  defp update_named_slave(slaves, slave_name, fun) do
    {entries, matched?} =
      Enum.map_reduce(slaves, false, fn slave, matched? ->
        cond do
          slave.name == slave_name ->
            case fun.(slave) do
              {:ok, updated_slave} -> {{:ok, updated_slave}, true}
              {:error, reason} -> {{:error, reason}, true}
              updated_slave -> {{:ok, updated_slave}, true}
            end

          true ->
            {{:ok, slave}, matched?}
        end
      end)

    if matched? do
      case Enum.find(entries, &match?({:error, _}, &1)) do
        {:error, reason} ->
          {:error, reason}

        nil ->
          {:ok, Enum.map(entries, fn {:ok, slave} -> slave end)}
      end
    else
      {:error, :not_found}
    end
  end

  defp fetch_named_slave(slaves, slave_name) do
    case Enum.find(slaves, &(&1.name == slave_name)) do
      nil -> {:error, :not_found}
      slave -> {:ok, slave}
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

  defp inject_fault_into_state(state, {:after_ms, delay_ms, fault})
       when is_integer(delay_ms) and delay_ms >= 0 do
    schedule_fault(state, delay_ms, fault)
  end

  defp inject_fault_into_state(state, {:after_milestone, milestone, fault}) do
    schedule_fault_after_milestone(state, milestone, fault)
  end

  defp inject_fault_into_state(state, fault) do
    apply_immediate_fault(state, fault)
  end

  defp apply_immediate_fault(state, :drop_responses) do
    {:ok, %{state | faults: Faults.inject(state.faults, :drop_responses)}}
  end

  defp apply_immediate_fault(state, {:wkc_offset, delta}) when is_integer(delta) do
    {:ok, %{state | faults: Faults.inject(state.faults, {:wkc_offset, delta})}}
  end

  defp apply_immediate_fault(state, {:command_wkc_offset, command_name, delta})
       when command_name in @exchange_commands and is_integer(delta) do
    {:ok,
     %{state | faults: Faults.inject(state.faults, {:command_wkc_offset, command_name, delta})}}
  end

  defp apply_immediate_fault(state, {:logical_wkc_offset, slave_name, delta})
       when is_atom(slave_name) and is_integer(delta) do
    {:ok,
     %{state | faults: Faults.inject(state.faults, {:logical_wkc_offset, slave_name, delta})}}
  end

  defp apply_immediate_fault(state, {:disconnect, slave_name}) when is_atom(slave_name) do
    {:ok, %{state | faults: Faults.inject(state.faults, {:disconnect, slave_name})}}
  end

  defp apply_immediate_fault(state, {:next_exchange, _fault} = planned_fault) do
    apply_planned_fault(state, planned_fault)
  end

  defp apply_immediate_fault(state, {:next_exchanges, _count, _fault} = planned_fault) do
    apply_planned_fault(state, planned_fault)
  end

  defp apply_immediate_fault(state, {:fault_script, steps}) do
    apply_fault_script(state, steps)
  end

  defp apply_immediate_fault(state, {:retreat_to_safeop, slave_name}) do
    apply_slave_update(state, slave_name, &Device.retreat_to_safeop/1)
  end

  defp apply_immediate_fault(state, {:latch_al_error, slave_name, code})
       when is_integer(code) and code >= 0 do
    apply_slave_update(state, slave_name, &Device.latch_al_error(&1, code))
  end

  defp apply_immediate_fault(state, {:mailbox_abort, slave_name, index, subindex, abort_code})
       when is_integer(index) and index >= 0 and is_integer(subindex) and subindex >= 0 and
              is_integer(abort_code) and abort_code >= 0 do
    apply_slave_update(
      state,
      slave_name,
      &Device.inject_mailbox_abort(&1, index, subindex, abort_code)
    )
  end

  defp apply_immediate_fault(
         state,
         {:mailbox_abort, slave_name, index, subindex, abort_code, stage}
       )
       when is_integer(index) and index >= 0 and is_integer(subindex) and subindex >= 0 and
              is_integer(abort_code) and abort_code >= 0 and
              stage in @mailbox_abort_stages do
    apply_slave_update(
      state,
      slave_name,
      &Device.inject_mailbox_abort(&1, index, subindex, abort_code, stage)
    )
  end

  defp apply_immediate_fault(
         state,
         {:mailbox_protocol_fault, slave_name, index, subindex, stage, fault_kind}
       )
       when is_integer(index) and index >= 0 and is_integer(subindex) and subindex >= 0 do
    if valid_mailbox_protocol_fault?(stage, fault_kind) do
      apply_slave_update(
        state,
        slave_name,
        &Device.inject_mailbox_protocol_fault(&1, index, subindex, stage, fault_kind)
      )
    else
      {:error, :invalid_fault}
    end
  end

  defp apply_immediate_fault(_state, _fault), do: {:error, :invalid_fault}

  defp apply_planned_fault(state, planned_fault) do
    case Faults.enqueue(state.faults, planned_fault) do
      {:ok, faults} -> {:ok, %{state | faults: faults}}
      :error -> {:error, :invalid_fault}
    end
  end

  defp apply_fault_script(state, steps) when is_list(steps) do
    if valid_fault_script_steps?(steps) do
      resume_fault_script(state, System.unique_integer([:positive, :monotonic]), steps)
    else
      {:error, :invalid_fault}
    end
  end

  defp apply_slave_update(state, slave_name, fun) do
    before_signals = Wiring.capture_signal_values(state.slaves)

    case update_named_slave(state.slaves, slave_name, fun) do
      {:ok, slaves} ->
        {:ok, %{state | slaves: slaves} |> finalize_signal_changes(before_signals)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resume_fault_script(state, _script_id, []), do: {:ok, state}

  defp resume_fault_script(state, script_id, steps) do
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
        advance_non_exchange_script_step(state, script_id, steps)
    end
  end

  defp advance_non_exchange_script_step(
         state,
         script_id,
         [{:wait_for_milestone, milestone} | rest_steps]
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

  defp advance_non_exchange_script_step(state, script_id, [step | rest_steps]) do
    case apply_script_step(state, step) do
      {:ok, next_state} -> resume_fault_script(next_state, script_id, rest_steps)
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_script_step(
         state,
         {:mailbox_protocol_fault, slave_name, index, subindex, stage, fault_kind}
       )
       when is_integer(index) and index >= 0 and is_integer(subindex) and subindex >= 0 do
    if valid_mailbox_protocol_fault?(stage, fault_kind) do
      apply_slave_update(
        state,
        slave_name,
        &Device.inject_mailbox_protocol_fault_once(&1, index, subindex, stage, fault_kind)
      )
    else
      {:error, :invalid_fault}
    end
  end

  defp apply_script_step(state, step), do: apply_immediate_fault(state, step)

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

  defp clear_scheduled_faults(scheduled_faults) do
    Enum.each(scheduled_faults, fn
      %{kind: :timer, timer_ref: timer_ref} ->
        Process.cancel_timer(timer_ref)

      _scheduled_fault ->
        :ok
    end)
  end

  defp pop_scheduled_fault(scheduled_faults, id) do
    {matches, scheduled_faults} = Enum.split_with(scheduled_faults, &(&1.id == id))

    case matches do
      [entry] -> {:ok, entry, scheduled_faults}
      [] -> :error
    end
  end

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

  defp maybe_trigger_milestone_faults(state, datagrams, responses, faults, planned_fault) do
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
        case inject_fault_into_state(current_state, fault) do
          {:ok, next_state} -> next_state
          {:error, _reason} -> current_state
        end

      {:script, script_id, steps}, current_state ->
        case resume_fault_script(current_state, script_id, steps) do
          {:ok, next_state} -> next_state
          {:error, _reason} -> current_state
        end
    end)
  end

  defp maybe_resume_fault_script(state, %{source: {:script, script_id}}) do
    case pop_script_resume(state.scheduled_faults, script_id) do
      {:ok, nil, scheduled_faults} ->
        %{state | scheduled_faults: scheduled_faults}

      {:ok, steps, scheduled_faults} ->
        case resume_fault_script(%{state | scheduled_faults: scheduled_faults}, script_id, steps) do
          {:ok, next_state} -> next_state
          {:error, _reason} -> %{state | scheduled_faults: scheduled_faults}
        end

      :error ->
        state
    end
  end

  defp maybe_resume_fault_script(state, _planned_fault_entry), do: state

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

  defp valid_fault_script_steps?(steps) when is_list(steps) do
    steps != [] and Enum.all?(steps, &valid_fault_script_step?/1)
  end

  defp valid_fault_script_step?({:wait_for_milestone, milestone}),
    do: Milestones.valid?(milestone)

  defp valid_fault_script_step?(step), do: valid_exchange_fault?(step) or valid_slave_fault?(step)

  defp fault_script_exchange_step?(step), do: valid_exchange_fault?(step)

  defp fault_entry_fault(nil), do: nil
  defp fault_entry_fault(%{fault: fault}), do: fault

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
       when stage in @mailbox_protocol_stages and
              is_integer(mailbox_type) and mailbox_type >= 0 and mailbox_type <= 15,
       do: true

  defp valid_mailbox_protocol_fault?(stage, {:coe_service, service})
       when stage in @mailbox_protocol_stages and
              is_integer(service) and service >= 0 and service <= 15,
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
