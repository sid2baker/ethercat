defmodule EtherCAT.Simulator do
  @moduledoc File.read!(Path.join(__DIR__, "simulator.md"))

  use GenServer

  alias EtherCAT.Bus.Datagram
  alias EtherCAT.Simulator.Fault
  alias EtherCAT.Simulator.RawSocket
  alias EtherCAT.Simulator.Runtime.FaultEngine
  alias EtherCAT.Simulator.Runtime.Faults
  alias EtherCAT.Simulator.Runtime.Router
  alias EtherCAT.Simulator.Runtime.Snapshot
  alias EtherCAT.Simulator.Runtime.Topology
  alias EtherCAT.Simulator.State
  alias EtherCAT.Simulator.Slave.Runtime.Device
  alias EtherCAT.Simulator.Runtime.Subscriptions
  alias EtherCAT.Simulator.Runtime.Wiring
  alias EtherCAT.Utils

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
  @type call_error_reason :: :not_found | :timeout | {:server_exit, term()}

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
          {:ok, [Datagram.t()]} | {:error, :no_response | call_error_reason()}
  def process_datagrams(datagrams),
    do: process_datagrams(datagrams, [])

  @doc false
  @spec process_datagrams([Datagram.t()], keyword()) ::
          {:ok, [Datagram.t()]} | {:error, :no_response | call_error_reason()}
  def process_datagrams(datagrams, opts) when is_list(opts),
    do: safe_call({:process_datagrams, datagrams, opts}, 5_000)

  @spec info() :: {:ok, map()} | {:error, call_error_reason()}
  def info do
    with {:ok, info} <- safe_call(:info, 5_000) do
      {:ok, info |> maybe_put_default_udp_info() |> maybe_put_default_raw_info()}
    end
  end

  @spec device_snapshot(atom()) :: {:ok, map()} | {:error, call_error_reason()}
  def device_snapshot(slave_name), do: safe_call({:device_snapshot, slave_name}, 5_000)

  @spec signal_snapshot(atom(), atom()) ::
          {:ok, map()} | {:error, :unknown_signal | call_error_reason()}
  def signal_snapshot(slave_name, signal_name),
    do: safe_call({:signal_snapshot, slave_name, signal_name}, 5_000)

  @spec inject_fault(Fault.t() | fault()) ::
          :ok | {:error, :invalid_fault | call_error_reason()}
  def inject_fault(fault) do
    case Fault.normalize(fault) do
      {:ok, normalized_fault} -> safe_call({:inject_fault, normalized_fault}, 5_000)
      :error -> {:error, :invalid_fault}
    end
  end

  @spec clear_faults() :: :ok | {:error, call_error_reason()}
  def clear_faults, do: safe_call(:clear_faults, 5_000)

  @spec set_topology(:linear | :redundant | {:redundant, keyword()}) ::
          :ok | {:error, :invalid_topology | call_error_reason()}
  def set_topology(topology), do: safe_call({:set_topology, topology}, 5_000)

  @spec signals(atom()) :: {:ok, [atom()]} | {:error, call_error_reason()}
  def signals(slave_name), do: safe_call({:signals, slave_name}, 5_000)

  @spec signal_definitions(atom()) ::
          {:ok, %{optional(atom()) => map()}} | {:error, call_error_reason()}
  def signal_definitions(slave_name),
    do: safe_call({:signal_definitions, slave_name}, 5_000)

  @spec get_value(atom(), atom()) ::
          {:ok, term()} | {:error, :unknown_signal | call_error_reason()}
  def get_value(slave_name, signal_name),
    do: safe_call({:get_value, slave_name, signal_name}, 5_000)

  @spec set_value(atom(), atom(), term()) ::
          :ok | {:error, :unknown_signal | :invalid_value | call_error_reason()}
  def set_value(slave_name, signal_name, value),
    do: safe_call({:set_value, slave_name, signal_name, value}, 5_000)

  @spec connections() :: {:ok, [connection()]} | {:error, call_error_reason()}
  def connections, do: safe_call(:connections, 5_000)

  @spec connect(signal_ref(), signal_ref()) ::
          :ok | {:error, :unknown_signal | :invalid_value | call_error_reason()}
  def connect(source, target), do: safe_call({:connect, source, target}, 5_000)

  @spec disconnect(signal_ref(), signal_ref()) :: :ok | {:error, call_error_reason()}
  def disconnect(source, target),
    do: safe_call({:disconnect, source, target}, 5_000)

  @spec subscribe(atom(), atom() | :all, pid()) :: :ok | {:error, call_error_reason()}
  def subscribe(slave_name, signal_name \\ :all, subscriber \\ self()) do
    safe_call({:subscribe, slave_name, signal_name, subscriber}, 5_000)
  end

  @spec unsubscribe(atom(), atom() | :all, pid()) :: :ok | {:error, call_error_reason()}
  def unsubscribe(slave_name, signal_name \\ :all, subscriber \\ self()) do
    safe_call({:unsubscribe, slave_name, signal_name, subscriber}, 5_000)
  end

  @spec output_image(atom()) :: {:ok, binary()} | {:error, call_error_reason()}
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
    :exit, reason -> Utils.classify_call_exit(reason, :not_found)
  end

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
      {:reply, {:error, :no_response},
       FaultEngine.resume_after_planned_fault(state, planned_fault_entry, fault_callbacks())}
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
        |> FaultEngine.after_exchange(
          datagrams,
          responses,
          faults,
          planned_fault_entry,
          fault_callbacks()
        )

      {:reply, {:ok, responses}, state}
    end
  end

  def handle_call({:process_datagrams, datagrams}, from, state) do
    handle_call({:process_datagrams, datagrams, []}, from, state)
  end

  def handle_call({:inject_fault, fault}, _from, state) do
    case FaultEngine.inject(state, fault, fault_callbacks()) do
      {:ok, state} ->
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:clear_faults, _from, state) do
    before_signals = Wiring.capture_signal_values(state.slaves)
    slaves = Enum.map(state.slaves, &Device.clear_faults/1)
    FaultEngine.clear_scheduled_faults(state.scheduled_faults)

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

  def handle_info({:apply_scheduled_fault, id, _fault}, state) do
    {:noreply, FaultEngine.handle_timer(state, id, fault_callbacks())}
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

  defp apply_immediate_fault(state, :drop_responses) do
    {:ok, %{state | faults: Faults.inject(state.faults, :drop_responses)}}
  end

  defp apply_immediate_fault(state, {:wkc_offset, delta}) when is_integer(delta) do
    {:ok, %{state | faults: Faults.inject(state.faults, {:wkc_offset, delta})}}
  end

  defp apply_immediate_fault(state, {:command_wkc_offset, command_name, delta})
       when is_atom(command_name) and is_integer(delta) do
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
              is_integer(abort_code) and abort_code >= 0 do
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
    apply_slave_update(
      state,
      slave_name,
      &Device.inject_mailbox_protocol_fault(&1, index, subindex, stage, fault_kind)
    )
  end

  defp apply_immediate_fault(_state, _fault), do: {:error, :invalid_fault}

  defp apply_script_step(
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

  defp apply_script_step(state, step), do: apply_immediate_fault(state, step)

  defp apply_slave_update(state, slave_name, fun) do
    before_signals = Wiring.capture_signal_values(state.slaves)

    case update_named_slave(state.slaves, slave_name, fun) do
      {:ok, slaves} ->
        {:ok, %{state | slaves: slaves} |> finalize_signal_changes(before_signals)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fault_callbacks do
    %{
      apply_immediate_fault: &apply_immediate_fault/2,
      apply_script_step: &apply_script_step/2
    }
  end
end
