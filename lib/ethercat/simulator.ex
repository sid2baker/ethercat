defmodule EtherCAT.Simulator do
  @moduledoc File.read!(Path.join(__DIR__, "simulator.md"))

  use GenServer

  alias EtherCAT.Bus.Datagram
  alias EtherCAT.Simulator.Runtime.Faults
  alias EtherCAT.Simulator.Runtime.Router
  alias EtherCAT.Simulator.Runtime.Snapshot
  alias EtherCAT.Simulator.Slave.Runtime.Device
  alias EtherCAT.Simulator.Runtime.Subscriptions
  alias EtherCAT.Simulator.Udp
  alias EtherCAT.Simulator.Runtime.Wiring

  @type server :: pid() | atom()
  @type fault ::
          :drop_responses
          | {:wkc_offset, integer()}
          | {:disconnect, atom()}
          | {:retreat_to_safeop, atom()}
          | {:latch_al_error, atom(), non_neg_integer()}
          | {:mailbox_abort, atom(), non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @type signal_ref :: {atom(), atom()}
  @type connection :: %{
          source: signal_ref(),
          target: signal_ref()
        }

  @type state :: %{
          slaves: [map()],
          faults: map(),
          connections: [connection()],
          subscriptions: map()
        }

  @type udp_link :: %{
          link: pid(),
          simulator: pid(),
          endpoint: pid(),
          ip: :inet.ip_address(),
          port: :inet.port_number()
        }

  @spec start(keyword()) :: {:ok, server() | udp_link()} | {:error, term()}
  def start(opts) do
    case Keyword.has_key?(opts, :ip) do
      true -> start_udp_runtime(opts)
      false -> start_link(opts)
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @spec stop(server() | pid() | udp_link()) :: :ok
  def stop(%{link: link}), do: stop(link)

  def stop(server) when is_pid(server) or is_atom(server) do
    case server_pid(server) do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          GenServer.stop(server)
        else
          :ok
        end

      nil ->
        :ok
    end
  end

  defp start_udp_runtime(opts) do
    ip = Keyword.fetch!(opts, :ip)
    port = Keyword.get(opts, :port, 0)
    simulator_opts = Keyword.drop(opts, [:ip, :port, :udp_name])
    udp_name = Keyword.get(opts, :udp_name)

    case DynamicSupervisor.start_link(strategy: :one_for_one) do
      {:ok, link} ->
        with {:ok, simulator} <-
               DynamicSupervisor.start_child(link, {__MODULE__, simulator_opts}),
             {:ok, endpoint} <-
               DynamicSupervisor.start_child(
                 link,
                 {Udp,
                  Keyword.merge([simulator: simulator, ip: ip, port: port], name_opts(udp_name))}
               ),
             {:ok, %{port: actual_port}} <- Udp.info(endpoint) do
          {:ok,
           %{
             link: link,
             simulator: simulator,
             endpoint: endpoint,
             ip: ip,
             port: actual_port
           }}
        else
          {:error, _reason} = error ->
            Supervisor.stop(link)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp name_opts(nil), do: []
  defp name_opts(name), do: [name: name]

  defp server_ref(%{simulator: simulator}), do: simulator
  defp server_ref(server), do: server

  defp server_pid(server) when is_pid(server), do: server
  defp server_pid(server) when is_atom(server), do: Process.whereis(server)

  @spec process_datagrams(server() | udp_link(), [Datagram.t()]) :: {:ok, [Datagram.t()]}
  def process_datagrams(server, datagrams) do
    GenServer.call(server_ref(server), {:process_datagrams, datagrams})
  end

  @spec info(server() | udp_link()) :: {:ok, map()} | {:error, :not_found | :timeout}
  def info(server) do
    GenServer.call(server_ref(server), :info, 5_000)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @spec slave_info(server() | udp_link(), atom()) ::
          {:ok, map()} | {:error, :not_found | :timeout}
  def slave_info(server, slave_name) do
    GenServer.call(server_ref(server), {:slave_info, slave_name}, 5_000)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @spec device_snapshot(server() | udp_link(), atom()) ::
          {:ok, map()} | {:error, :not_found | :timeout}
  def device_snapshot(server, slave_name) do
    GenServer.call(server_ref(server), {:device_snapshot, slave_name}, 5_000)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @spec signal_snapshot(server() | udp_link(), atom(), atom()) ::
          {:ok, map()} | {:error, :not_found | :unknown_signal | :timeout}
  def signal_snapshot(server, slave_name, signal_name) do
    GenServer.call(server_ref(server), {:signal_snapshot, slave_name, signal_name}, 5_000)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @spec connection_snapshot(server() | udp_link()) ::
          {:ok, [connection()]} | {:error, :not_found | :timeout}
  def connection_snapshot(server) do
    GenServer.call(server_ref(server), :connection_snapshot, 5_000)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @spec inject_fault(server() | udp_link(), fault()) :: :ok | {:error, :not_found}
  def inject_fault(server, fault) do
    GenServer.call(server_ref(server), {:inject_fault, fault})
  end

  @spec clear_faults(server() | udp_link()) :: :ok
  def clear_faults(server) do
    GenServer.call(server_ref(server), :clear_faults)
  end

  @spec output_value(server() | udp_link(), atom()) ::
          {:ok, non_neg_integer()} | {:error, :not_found}
  def output_value(server, slave_name) do
    GenServer.call(server_ref(server), {:output_value, slave_name})
  end

  @spec signals(server() | udp_link(), atom()) :: {:ok, [atom()]} | {:error, :not_found}
  def signals(server, slave_name) do
    GenServer.call(server_ref(server), {:signals, slave_name})
  end

  @spec signal_definitions(server() | udp_link(), atom()) ::
          {:ok, %{optional(atom()) => map()}} | {:error, :not_found}
  def signal_definitions(server, slave_name) do
    GenServer.call(server_ref(server), {:signal_definitions, slave_name})
  end

  @spec get_value(server() | udp_link(), atom(), atom()) ::
          {:ok, term()} | {:error, :not_found | :unknown_signal}
  def get_value(server, slave_name, signal_name) do
    GenServer.call(server_ref(server), {:get_value, slave_name, signal_name})
  end

  @spec set_value(server() | udp_link(), atom(), atom(), term()) ::
          :ok | {:error, :not_found | :unknown_signal | :invalid_value}
  def set_value(server, slave_name, signal_name, value) do
    GenServer.call(server_ref(server), {:set_value, slave_name, signal_name, value})
  end

  @spec connections(server() | udp_link()) ::
          {:ok, [connection()]} | {:error, :not_found | :timeout}
  def connections(server) do
    GenServer.call(server_ref(server), :connections, 5_000)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @spec connect(server() | udp_link(), signal_ref(), signal_ref()) ::
          :ok | {:error, :not_found | :unknown_signal | :invalid_value}
  def connect(server, source, target) do
    GenServer.call(server_ref(server), {:connect, source, target})
  end

  @spec disconnect(server() | udp_link(), signal_ref(), signal_ref()) ::
          :ok | {:error, :not_found}
  def disconnect(server, source, target) do
    GenServer.call(server_ref(server), {:disconnect, source, target})
  end

  @spec subscribe(server() | udp_link(), atom(), atom() | :all, pid()) ::
          :ok | {:error, :not_found}
  def subscribe(server, slave_name, signal_name, subscriber) do
    GenServer.call(server_ref(server), {:subscribe, slave_name, signal_name, subscriber})
  end

  @spec unsubscribe(server() | udp_link(), atom(), atom() | :all, pid()) ::
          :ok | {:error, :not_found}
  def unsubscribe(server, slave_name, signal_name, subscriber) do
    GenServer.call(server_ref(server), {:unsubscribe, slave_name, signal_name, subscriber})
  end

  @spec output_image(server() | udp_link(), atom()) :: {:ok, binary()} | {:error, :not_found}
  def output_image(server, slave_name) do
    GenServer.call(server_ref(server), {:output_image, slave_name})
  end

  @impl true
  def init(opts) do
    devices = Keyword.get(opts, :devices, [])

    slaves =
      devices
      |> Enum.with_index()
      |> Enum.map(fn {definition, position} -> Device.new(definition, position) end)

    {:ok,
     %{
       slaves: slaves,
       faults: Faults.new(),
       connections: [],
       subscriptions: Subscriptions.new()
     }}
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply, {:ok, Snapshot.simulator(%{state | faults: Faults.info(state.faults)})}, state}
  end

  def handle_call(
        {:process_datagrams, _datagrams},
        _from,
        %{faults: %{drop_responses?: true}} = state
      ) do
    {:reply, {:error, :no_response}, state}
  end

  @impl true
  def handle_call(
        {:process_datagrams, datagrams},
        _from,
        %{slaves: slaves, faults: faults} = state
      ) do
    before_signals = Wiring.capture_signal_values(slaves)

    {responses, slaves} =
      Router.process_datagrams(datagrams, slaves, faults.disconnected, faults.wkc_offset)

    state = finalize_signal_changes(%{state | slaves: slaves}, before_signals)

    {:reply, {:ok, responses}, state}
  end

  def handle_call({:inject_fault, :drop_responses}, _from, state) do
    {:reply, :ok, %{state | faults: Faults.inject(state.faults, :drop_responses)}}
  end

  def handle_call({:inject_fault, {:wkc_offset, delta}}, _from, state)
      when is_integer(delta) do
    {:reply, :ok, %{state | faults: Faults.inject(state.faults, {:wkc_offset, delta})}}
  end

  def handle_call({:inject_fault, {:disconnect, slave_name}}, _from, state) do
    {:reply, :ok, %{state | faults: Faults.inject(state.faults, {:disconnect, slave_name})}}
  end

  def handle_call({:inject_fault, {:retreat_to_safeop, slave_name}}, _from, state) do
    reply_with_slave_update(state, slave_name, &Device.retreat_to_safeop/1)
  end

  def handle_call({:inject_fault, {:latch_al_error, slave_name, code}}, _from, state)
      when is_integer(code) and code >= 0 do
    reply_with_slave_update(state, slave_name, &Device.latch_al_error(&1, code))
  end

  def handle_call(
        {:inject_fault, {:mailbox_abort, slave_name, index, subindex, abort_code}},
        _from,
        state
      )
      when is_integer(index) and index >= 0 and is_integer(subindex) and subindex >= 0 and
             is_integer(abort_code) and abort_code >= 0 do
    reply_with_slave_update(
      state,
      slave_name,
      &Device.inject_mailbox_abort(&1, index, subindex, abort_code)
    )
  end

  def handle_call(:clear_faults, _from, state) do
    before_signals = Wiring.capture_signal_values(state.slaves)
    slaves = Enum.map(state.slaves, &Device.clear_faults/1)

    state =
      state
      |> Map.put(:slaves, slaves)
      |> Map.put(:faults, Faults.clear(state.faults))
      |> finalize_signal_changes(before_signals)

    {:reply, :ok, state}
  end

  def handle_call({:output_value, slave_name}, _from, %{slaves: slaves} = state) do
    reply =
      case Enum.find(slaves, &(&1.name == slave_name)) do
        nil ->
          {:error, :not_found}

        slave ->
          <<value::8, _rest::binary>> = Device.output_image(slave) <> <<0>>
          {:ok, value}
      end

    {:reply, reply, state}
  end

  def handle_call({:signals, slave_name}, _from, %{slaves: slaves} = state) do
    reply =
      case Enum.find(slaves, &(&1.name == slave_name)) do
        nil -> {:error, :not_found}
        slave -> {:ok, slave |> Device.signals() |> Map.keys()}
      end

    {:reply, reply, state}
  end

  def handle_call({:slave_info, slave_name}, _from, %{slaves: slaves} = state) do
    {:reply, Snapshot.device(%{state | slaves: slaves}, slave_name), state}
  end

  def handle_call({:device_snapshot, slave_name}, _from, state) do
    {:reply, Snapshot.device(state, slave_name), state}
  end

  def handle_call({:signal_snapshot, slave_name, signal_name}, _from, state) do
    {:reply, Snapshot.signal(state, slave_name, signal_name), state}
  end

  def handle_call({:signal_definitions, slave_name}, _from, %{slaves: slaves} = state) do
    reply =
      case Enum.find(slaves, &(&1.name == slave_name)) do
        nil -> {:error, :not_found}
        slave -> {:ok, Device.signals(slave)}
      end

    {:reply, reply, state}
  end

  def handle_call({:get_value, slave_name, signal_name}, _from, %{slaves: slaves} = state) do
    reply =
      case Enum.find(slaves, &(&1.name == slave_name)) do
        nil -> {:error, :not_found}
        slave -> Device.get_value(slave, signal_name)
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

  def handle_call(:connection_snapshot, _from, state) do
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
      case Enum.find(slaves, &(&1.name == slave_name)) do
        nil -> {:error, :not_found}
        slave -> {:ok, Device.output_image(slave)}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscriptions: Subscriptions.handle_down(state.subscriptions, ref, pid)}}
  end

  defp reply_with_slave_update(state, slave_name, fun) do
    before_signals = Wiring.capture_signal_values(state.slaves)

    case update_named_slave(state.slaves, slave_name, fun) do
      {:ok, slaves} ->
        state = %{state | slaves: slaves} |> finalize_signal_changes(before_signals)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
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

  defp finalize_signal_changes(
         %{slaves: slaves, connections: connections, subscriptions: subscriptions} = state,
         before_signals
       ) do
    {slaves, changes} = Wiring.settle(slaves, connections, before_signals)
    :ok = Subscriptions.notify(subscriptions, self(), changes)
    %{state | slaves: slaves}
  end
end
