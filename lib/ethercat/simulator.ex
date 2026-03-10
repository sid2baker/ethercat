defmodule EtherCAT.Simulator do
  @moduledoc """
  Simulated EtherCAT segment for deep integration tests and virtual hardware.

  It hosts one or more simulated slaves and executes EtherCAT datagrams against
  them with protocol-faithful register, AL-state, mailbox, and logical process
  data behavior.
  """

  use GenServer

  alias EtherCAT.Bus.Datagram
  alias EtherCAT.Simulator.Slave.Device

  @aprd 1
  @apwr 2
  @aprw 3
  @fprd 4
  @fpwr 5
  @fprw 6
  @brd 7
  @bwr 8
  @brw 9
  @lrd 10
  @lwr 11
  @lrw 12
  @armw 13
  @frmw 14

  @type fault ::
          :drop_responses
          | {:wkc_offset, integer()}
          | {:disconnect, atom()}
          | {:retreat_to_safeop, atom()}
          | {:latch_al_error, atom(), non_neg_integer()}
          | {:mailbox_abort, atom(), non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @type state :: %{
          slaves: [map()],
          drop_responses?: boolean(),
          wkc_offset: integer(),
          disconnected: MapSet.t(atom()),
          subscriptions: [subscription()],
          monitors: %{optional(pid()) => reference()}
        }

  @type subscription :: %{
          slave: atom(),
          signal: atom() | :all,
          pid: pid()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec process_datagrams(pid(), [Datagram.t()]) :: {:ok, [Datagram.t()]}
  def process_datagrams(server, datagrams) do
    GenServer.call(server, {:process_datagrams, datagrams})
  end

  @spec info(pid()) :: {:ok, map()} | {:error, :not_found | :timeout}
  def info(server) do
    GenServer.call(server, :info, 5_000)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @spec slave_info(pid(), atom()) :: {:ok, map()} | {:error, :not_found | :timeout}
  def slave_info(server, slave_name) do
    GenServer.call(server, {:slave_info, slave_name}, 5_000)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @spec inject_fault(pid(), fault()) :: :ok | {:error, :not_found}
  def inject_fault(server, fault) do
    GenServer.call(server, {:inject_fault, fault})
  end

  @spec clear_faults(pid()) :: :ok
  def clear_faults(server) do
    GenServer.call(server, :clear_faults)
  end

  @spec output_value(pid(), atom()) :: {:ok, non_neg_integer()} | {:error, :not_found}
  def output_value(server, slave_name) do
    GenServer.call(server, {:output_value, slave_name})
  end

  @spec signals(pid(), atom()) :: {:ok, [atom()]} | {:error, :not_found}
  def signals(server, slave_name) do
    GenServer.call(server, {:signals, slave_name})
  end

  @spec signal_definitions(pid(), atom()) ::
          {:ok, %{optional(atom()) => map()}} | {:error, :not_found}
  def signal_definitions(server, slave_name) do
    GenServer.call(server, {:signal_definitions, slave_name})
  end

  @spec get_value(pid(), atom(), atom()) ::
          {:ok, term()} | {:error, :not_found | :unknown_signal}
  def get_value(server, slave_name, signal_name) do
    GenServer.call(server, {:get_value, slave_name, signal_name})
  end

  @spec set_value(pid(), atom(), atom(), term()) ::
          :ok | {:error, :not_found | :unknown_signal | :invalid_value}
  def set_value(server, slave_name, signal_name, value) do
    GenServer.call(server, {:set_value, slave_name, signal_name, value})
  end

  @spec subscribe(pid(), atom(), atom() | :all, pid()) :: :ok | {:error, :not_found}
  def subscribe(server, slave_name, signal_name, subscriber) do
    GenServer.call(server, {:subscribe, slave_name, signal_name, subscriber})
  end

  @spec unsubscribe(pid(), atom(), atom() | :all, pid()) :: :ok | {:error, :not_found}
  def unsubscribe(server, slave_name, signal_name, subscriber) do
    GenServer.call(server, {:unsubscribe, slave_name, signal_name, subscriber})
  end

  @spec output_image(pid(), atom()) :: {:ok, binary()} | {:error, :not_found}
  def output_image(server, slave_name) do
    GenServer.call(server, {:output_image, slave_name})
  end

  @impl true
  def init(opts) do
    fixtures = Keyword.get(opts, :slaves, [])

    slaves =
      fixtures
      |> Enum.with_index()
      |> Enum.map(fn {fixture, position} -> Device.new(fixture, position) end)

    {:ok,
     %{
       slaves: slaves,
       drop_responses?: false,
       wkc_offset: 0,
       disconnected: MapSet.new(),
       subscriptions: [],
       monitors: %{}
     }}
  end

  @impl true
  def handle_call(:info, _from, state) do
    disconnected = MapSet.to_list(state.disconnected)

    reply =
      %{
        slaves: Enum.map(state.slaves, &Device.info/1),
        disconnected: disconnected,
        drop_responses?: state.drop_responses?,
        wkc_offset: state.wkc_offset,
        subscriptions:
          Enum.map(state.subscriptions, fn subscription ->
            %{slave: subscription.slave, signal: subscription.signal, pid: subscription.pid}
          end)
      }

    {:reply, {:ok, reply}, state}
  end

  def handle_call({:process_datagrams, _datagrams}, _from, %{drop_responses?: true} = state) do
    {:reply, {:error, :no_response}, state}
  end

  @impl true
  def handle_call(
        {:process_datagrams, datagrams},
        _from,
        %{slaves: slaves, wkc_offset: wkc_offset, disconnected: disconnected} = state
      ) do
    before_signals = capture_signal_values(slaves)

    {responses, slaves} =
      Enum.map_reduce(datagrams, slaves, fn datagram, current_slaves ->
        process_datagram(datagram, current_slaves, disconnected)
      end)

    responses = maybe_adjust_wkc(responses, wkc_offset)
    state = %{state | slaves: slaves}
    notify_signal_changes(state, before_signals, slaves)

    {:reply, {:ok, responses}, state}
  end

  def handle_call({:inject_fault, :drop_responses}, _from, state) do
    {:reply, :ok, %{state | drop_responses?: true}}
  end

  def handle_call({:inject_fault, {:wkc_offset, delta}}, _from, state)
      when is_integer(delta) do
    {:reply, :ok, %{state | wkc_offset: delta}}
  end

  def handle_call({:inject_fault, {:disconnect, slave_name}}, _from, state) do
    {:reply, :ok, %{state | disconnected: MapSet.put(state.disconnected, slave_name)}}
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
    slaves = Enum.map(state.slaves, &Device.clear_faults/1)

    {:reply, :ok,
     %{state | slaves: slaves, drop_responses?: false, wkc_offset: 0, disconnected: MapSet.new()}}
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
    reply =
      case Enum.find(slaves, &(&1.name == slave_name)) do
        nil -> {:error, :not_found}
        slave -> {:ok, Device.info(slave)}
      end

    {:reply, reply, state}
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
    before_signals = capture_signal_values(slaves)

    case update_named_slave(slaves, slave_name, &Device.set_value(&1, signal_name, value)) do
      {:ok, updated_slaves} ->
        state = %{state | slaves: updated_slaves}
        notify_signal_changes(state, before_signals, updated_slaves)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:subscribe, slave_name, signal_name, subscriber}, _from, state) do
    if Enum.any?(state.slaves, &(&1.name == slave_name)) do
      subscriptions =
        Enum.uniq_by(
          [%{slave: slave_name, signal: signal_name, pid: subscriber} | state.subscriptions],
          &{&1.slave, &1.signal, &1.pid}
        )

      monitors = ensure_monitor(state.monitors, subscriptions, subscriber)
      {:reply, :ok, %{state | subscriptions: subscriptions, monitors: monitors}}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:unsubscribe, slave_name, signal_name, subscriber}, _from, state) do
    if Enum.any?(state.slaves, &(&1.name == slave_name)) do
      subscriptions =
        Enum.reject(state.subscriptions, fn subscription ->
          subscription.slave == slave_name and subscription.signal == signal_name and
            subscription.pid == subscriber
        end)

      monitors = maybe_demonitor(state.monitors, subscriptions, subscriber)
      {:reply, :ok, %{state | subscriptions: subscriptions, monitors: monitors}}
    else
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
    case Map.fetch(state.monitors, pid) do
      {:ok, ^ref} ->
        subscriptions = Enum.reject(state.subscriptions, &(&1.pid == pid))
        monitors = Map.delete(state.monitors, pid)
        {:noreply, %{state | subscriptions: subscriptions, monitors: monitors}}

      _ ->
        {:noreply, state}
    end
  end

  defp process_datagram(%Datagram{cmd: cmd} = datagram, slaves, disconnected)
       when cmd in [@aprd, @apwr, @aprw, @armw] do
    <<position::little-signed-16, offset::little-unsigned-16>> = datagram.address
    target_position = -position

    {response_data, wkc, slaves} =
      update_single(slaves, disconnected, target_position, fn slave ->
        process_register_command(slave, datagram, offset)
      end)

    {%{datagram | data: response_data, wkc: wkc}, slaves}
  end

  defp process_datagram(%Datagram{cmd: cmd} = datagram, slaves, disconnected)
       when cmd in [@fprd, @fpwr, @fprw, @frmw] do
    <<station::little-unsigned-16, offset::little-unsigned-16>> = datagram.address

    {response_data, wkc, slaves} =
      update_first(
        slaves,
        disconnected,
        fn slave ->
          slave.station == station
        end,
        fn slave ->
          process_register_command(slave, datagram, offset)
        end
      )

    {%{datagram | data: response_data, wkc: wkc}, slaves}
  end

  defp process_datagram(%Datagram{cmd: cmd} = datagram, slaves, disconnected)
       when cmd in [@brd, @bwr, @brw] do
    <<_zero::little-signed-16, offset::little-unsigned-16>> = datagram.address

    {slaves, response_data, wkc} =
      Enum.reduce(slaves, {[], datagram.data, 0}, fn slave, {acc, _response_data, wkc} ->
        if MapSet.member?(disconnected, slave.name) do
          {[slave | acc], datagram.data, wkc}
        else
          {updated_slave, new_response_data, increment} =
            process_register_command(slave, datagram, offset)

          {[updated_slave | acc], new_response_data, wkc + increment}
        end
      end)

    {%{datagram | data: response_data, wkc: wkc}, Enum.reverse(slaves)}
  end

  defp process_datagram(%Datagram{cmd: cmd} = datagram, slaves, disconnected)
       when cmd in [@lrd, @lwr, @lrw] do
    <<logical_start::little-unsigned-32>> = datagram.address

    {slaves, response_data, wkc} =
      Enum.reduce(slaves, {[], datagram.data, 0}, fn slave, {acc, response_data, wkc} ->
        if MapSet.member?(disconnected, slave.name) do
          {[slave | acc], response_data, wkc}
        else
          {updated_slave, new_response_data, increment} =
            Device.logical_read_write(slave, cmd, logical_start, response_data)

          {[updated_slave | acc], new_response_data, wkc + increment}
        end
      end)

    {%{datagram | data: response_data, wkc: wkc}, Enum.reverse(slaves)}
  end

  defp process_datagram(%Datagram{} = datagram, slaves, _disconnected),
    do: {%{datagram | wkc: 0}, slaves}

  defp maybe_adjust_wkc(datagrams, 0), do: datagrams

  defp maybe_adjust_wkc(datagrams, offset) do
    Enum.map(datagrams, fn datagram ->
      %{datagram | wkc: max(datagram.wkc + offset, 0)}
    end)
  end

  defp process_register_command(slave, %Datagram{cmd: cmd, data: data}, offset)
       when cmd in [@aprd, @fprd, @brd] do
    {updated_slave, response_data} = Device.read_datagram(slave, offset, byte_size(data))
    {updated_slave, response_data, 1}
  end

  defp process_register_command(slave, %Datagram{cmd: cmd, data: data}, offset)
       when cmd in [@apwr, @fpwr, @bwr] do
    {Device.write_datagram(slave, offset, data), data, 1}
  end

  defp process_register_command(slave, %Datagram{cmd: cmd, data: data}, offset)
       when cmd in [@aprw, @fprw, @brw, @armw, @frmw] do
    {read_slave, response_data} = Device.read_datagram(slave, offset, byte_size(data))
    updated_slave = Device.write_datagram(read_slave, offset, data)
    {updated_slave, response_data, 1}
  end

  defp update_single(slaves, disconnected, target_position, fun) do
    {slaves, response_data, wkc, matched?} =
      Enum.reduce(slaves, {[], nil, 0, false}, fn slave, {acc, response_data, wkc, matched?} ->
        if slave.position == target_position and not MapSet.member?(disconnected, slave.name) do
          {updated_slave, current_response_data, current_wkc} = fun.(slave)
          {[updated_slave | acc], current_response_data, current_wkc, true}
        else
          {[slave | acc], response_data, wkc, matched?}
        end
      end)

    if matched? do
      {response_data || <<>>, wkc, Enum.reverse(slaves)}
    else
      {<<>>, 0, Enum.reverse(slaves)}
    end
  end

  defp update_first(slaves, disconnected, matcher, fun) do
    {updated_entries, matched?} =
      Enum.map_reduce(slaves, false, fn slave, matched? ->
        cond do
          matched? ->
            {{slave, nil, 0}, true}

          MapSet.member?(disconnected, slave.name) ->
            {{slave, nil, 0}, false}

          matcher.(slave) ->
            {updated_slave, response_data, wkc} = fun.(slave)
            {{updated_slave, response_data, wkc}, true}

          true ->
            {{slave, nil, 0}, false}
        end
      end)

    {slaves, response_data, wkc} =
      Enum.reduce(updated_entries, {[], nil, 0}, fn {slave, response_data, wkc},
                                                    {acc, found_data, found_wkc} ->
        data =
          if is_nil(found_data) and not is_nil(response_data), do: response_data, else: found_data

        current_wkc = if found_wkc == 0 and wkc > 0, do: wkc, else: found_wkc
        {[slave | acc], data, current_wkc}
      end)

    slaves = Enum.reverse(slaves)

    if matched? do
      {response_data || <<>>, wkc, slaves}
    else
      {<<>>, 0, slaves}
    end
  end

  defp reply_with_slave_update(state, slave_name, fun) do
    before_signals = capture_signal_values(state.slaves)

    case update_named_slave(state.slaves, slave_name, fun) do
      {:ok, slaves} ->
        state = %{state | slaves: slaves}
        notify_signal_changes(state, before_signals, slaves)
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

  defp capture_signal_values(slaves) do
    Map.new(slaves, fn slave -> {slave.name, Device.signal_values(slave)} end)
  end

  defp notify_signal_changes(%{subscriptions: []}, _before, _after), do: :ok

  defp notify_signal_changes(%{subscriptions: subscriptions}, before, slaves) do
    Enum.each(slaves, fn slave ->
      old_values = Map.get(before, slave.name, %{})
      new_values = Device.signal_values(slave)

      Enum.each(new_values, fn {signal_name, value} ->
        if Map.get(old_values, signal_name) != value do
          notify_subscribers(subscriptions, slave.name, signal_name, value)
        end
      end)
    end)
  end

  defp notify_subscribers(subscriptions, slave_name, signal_name, value) do
    Enum.each(subscriptions, fn subscription ->
      if subscription.slave == slave_name and
           (subscription.signal == :all or subscription.signal == signal_name) do
        send(
          subscription.pid,
          {:ethercat_simulator, self(), :signal_changed, slave_name, signal_name, value}
        )
      end
    end)

    :ok
  end

  defp ensure_monitor(monitors, subscriptions, pid) do
    if Map.has_key?(monitors, pid) or not Enum.any?(subscriptions, &(&1.pid == pid)) do
      monitors
    else
      Map.put(monitors, pid, Process.monitor(pid))
    end
  end

  defp maybe_demonitor(monitors, subscriptions, pid) do
    if Enum.any?(subscriptions, &(&1.pid == pid)) do
      monitors
    else
      case Map.pop(monitors, pid) do
        {nil, monitors} ->
          monitors

        {ref, monitors} ->
          Process.demonitor(ref, [:flush])
          monitors
      end
    end
  end
end
