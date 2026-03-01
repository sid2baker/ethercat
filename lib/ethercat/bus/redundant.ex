defmodule EtherCAT.Bus.Redundant do
  @moduledoc """
  Dual-port redundant EtherCAT bus implementation.

  Sends each frame on both transports. Per-datagram merge picks the higher WKC.

  Subscribes to VintageNet `lower_up` for proactive carrier detection
  on both interfaces.

  ## States

    - `:idle`     — both transports open
    - `{:awaiting, mode}` — frame(s) sent, collecting responses
    - `:degraded` — one transport lost, operates single-port while reconnecting
    - `:down`     — both transports lost, reconnecting

  ## Queue batching

  Same as `Bus.SinglePort`: `Bus.transaction/3` calls are postponed when busy
  and expire if stale; `Bus.transaction_queue/2` calls always queue to pending.
  """

  @behaviour :gen_statem

  alias EtherCAT.Bus.{Datagram, Frame}
  alias EtherCAT.Telemetry

  @max_datagram_bytes 1_400
  @debounce_interval 200

  defstruct [
    :primary,
    :secondary,
    :transport_mod,
    :idx,
    :awaiting_callers,
    primary_result: nil,
    secondary_result: nil,
    frame_timeout_ms: 25,
    pending: []
  ]

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(opts) do
    transport_mod = Keyword.fetch!(opts, :transport_mod)
    pri_opts = Keyword.put(opts, :interface, Keyword.fetch!(opts, :interface))
    sec_opts = Keyword.put(opts, :interface, Keyword.fetch!(opts, :backup_interface))

    frame_timeout_ms = Keyword.get(opts, :frame_timeout_ms, 25)

    with {:ok, pri} <- transport_mod.open(pri_opts),
         {:ok, sec} <- transport_mod.open(sec_opts) do
      if iface = transport_mod.interface(pri),
        do: VintageNet.subscribe(["interface", iface, "lower_up"])

      if iface = transport_mod.interface(sec),
        do: VintageNet.subscribe(["interface", iface, "lower_up"])

      {:ok, :idle,
       %__MODULE__{
         primary: pri,
         secondary: sec,
         transport_mod: transport_mod,
         idx: 0,
         frame_timeout_ms: frame_timeout_ms
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # -- VintageNet carrier detection (any state) --------------------------------

  @impl true
  def handle_event(
        :info,
        {VintageNet, ["interface", ifname, "lower_up"], _old, false, _meta},
        state,
        data
      ) do
    Telemetry.socket_down(ifname, :carrier_lost)
    handle_carrier_lost(ifname, state, data)
  end

  def handle_event(
        :info,
        {VintageNet, ["interface", _ifname, "lower_up"], _old, true, _meta},
        state,
        _data
      )
      when state in [:down, :degraded] do
    {:keep_state_and_data, [{:state_timeout, @debounce_interval, :reconnect}]}
  end

  def handle_event(:info, {VintageNet, _, _, _, _}, _state, _data) do
    :keep_state_and_data
  end

  # -- idle -------------------------------------------------------------------

  def handle_event(:enter, _old, :idle, _data), do: :keep_state_and_data

  def handle_event({:call, from}, {:transact, datagrams, enqueued_at, timeout_us}, :idle, data) do
    if System.monotonic_time(:microsecond) - enqueued_at > timeout_us do
      {:keep_state_and_data, [{:reply, from, {:error, :expired}}]}
    else
      Telemetry.transact_direct(data.transport_mod.name(data.primary))
      send_to_both(datagrams, from, data)
    end
  end

  def handle_event({:call, from}, {:transact_queue, datagrams}, :idle, data) do
    Telemetry.transact_direct(data.transport_mod.name(data.primary))
    send_to_both(datagrams, from, data)
  end

  # -- awaiting ---------------------------------------------------------------

  def handle_event(:enter, _old, {:awaiting, _}, _data), do: :keep_state_and_data

  def handle_event({:call, _from}, {:transact, _, _, _}, {:awaiting, _}, data) do
    Telemetry.transact_postponed(data.transport_mod.name(data.primary))
    {:keep_state_and_data, [:postpone]}
  end

  def handle_event({:call, from}, {:transact_queue, datagrams}, {:awaiting, _}, data) do
    Telemetry.transact_queued(data.transport_mod.name(data.primary))
    {:keep_state, %{data | pending: data.pending ++ [{from, datagrams}]}}
  end

  def handle_event(:info, msg, {:awaiting, mode}, data) do
    pri_match =
      if mode in [:both, :primary_only],
        do: data.transport_mod.match(data.primary, msg),
        else: :ignore

    sec_match =
      if mode in [:both, :secondary_only],
        do: data.transport_mod.match(data.secondary, msg),
        else: :ignore

    cond do
      match?({:ok, _, _}, pri_match) ->
        {:ok, payload, rx_at} = pri_match

        Telemetry.frame_received(
          data.transport_mod.name(data.primary),
          :primary,
          byte_size(payload),
          rx_at
        )

        handle_recv(:primary, payload, mode, data)

      match?({:ok, _, _}, sec_match) ->
        {:ok, payload, rx_at} = sec_match

        Telemetry.frame_received(
          data.transport_mod.name(data.secondary),
          :secondary,
          byte_size(payload),
          rx_at
        )

        handle_recv(:secondary, payload, mode, data)

      true ->
        :keep_state_and_data
    end
  end

  def handle_event(:state_timeout, :timeout, {:awaiting, _}, data) do
    case {data.primary_result, data.secondary_result} do
      {nil, nil} ->
        Enum.each(data.awaiting_callers, fn {from, _} ->
          :gen_statem.reply(from, {:error, :timeout})
        end)

        flush_pending(%{data | awaiting_callers: nil, primary_result: nil, secondary_result: nil})

      _ ->
        merged = merge(data.primary_result, data.secondary_result)
        dispatch_results(merged, data.awaiting_callers)
        flush_pending(%{data | awaiting_callers: nil, primary_result: nil, secondary_result: nil})
    end
  end

  # -- degraded ---------------------------------------------------------------

  def handle_event(:enter, _old, :degraded, _data), do: :keep_state_and_data

  def handle_event(:state_timeout, :reconnect, :degraded, data) do
    data = try_reconnect(data)

    if data.transport_mod.open?(data.primary) and data.transport_mod.open?(data.secondary) do
      {:next_state, :idle, data}
    else
      {:keep_state, data}
    end
  end

  def handle_event(
        {:call, from},
        {:transact, datagrams, enqueued_at, timeout_us},
        :degraded,
        data
      ) do
    if System.monotonic_time(:microsecond) - enqueued_at > timeout_us do
      {:keep_state_and_data, [{:reply, from, {:error, :expired}}]}
    else
      Telemetry.transact_direct(data.transport_mod.name(data.primary))
      send_single(datagrams, from, data)
    end
  end

  def handle_event({:call, from}, {:transact_queue, datagrams}, :degraded, data) do
    Telemetry.transact_direct(data.transport_mod.name(data.primary))
    send_single(datagrams, from, data)
  end

  # -- down -------------------------------------------------------------------

  def handle_event(:enter, _old, :down, data) do
    {:keep_state, close_sockets(data)}
  end

  def handle_event(:state_timeout, :reconnect, :down, data) do
    data = try_reconnect(data)

    cond do
      data.transport_mod.open?(data.primary) and data.transport_mod.open?(data.secondary) ->
        {:next_state, :idle, data}

      data.transport_mod.open?(data.primary) or data.transport_mod.open?(data.secondary) ->
        {:next_state, :degraded, data}

      true ->
        :keep_state_and_data
    end
  end

  def handle_event({:call, from}, {:transact, _, _, _}, :down, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :down}}]}
  end

  def handle_event({:call, from}, {:transact_queue, _}, :down, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :down}}]}
  end

  # -- catch-all --------------------------------------------------------------

  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  # -- carrier helpers ---------------------------------------------------------

  defp handle_carrier_lost(ifname, state, data) do
    {data, which} =
      cond do
        data.transport_mod.open?(data.primary) and
            data.transport_mod.interface(data.primary) == ifname ->
          {%{data | primary: data.transport_mod.close(data.primary)}, :primary}

        data.transport_mod.open?(data.secondary) and
            data.transport_mod.interface(data.secondary) == ifname ->
          {%{data | secondary: data.transport_mod.close(data.secondary)}, :secondary}

        true ->
          {data, nil}
      end

    pri_up = data.transport_mod.open?(data.primary)
    sec_up = data.transport_mod.open?(data.secondary)

    flight_replies =
      (data.awaiting_callers || [])
      |> Enum.map(fn {from, _} -> {:reply, from, {:error, :down}} end)

    pending_replies =
      data.pending |> Enum.map(fn {from, _} -> {:reply, from, {:error, :down}} end)

    case {state, pri_up, sec_up, which} do
      {_, _, _, nil} ->
        :keep_state_and_data

      {{:awaiting, _}, false, false, _} ->
        {:next_state, :down, %{data | awaiting_callers: nil, pending: []},
         flight_replies ++ pending_replies}

      {{:awaiting, _}, _, _, _} ->
        # Still have one socket — let timeout or remaining recv complete
        :keep_state_and_data

      {_, false, false, _} ->
        {:next_state, :down, %{data | pending: []}, pending_replies}

      _ ->
        {:next_state, :degraded, %{data | pending: []}, pending_replies}
    end
  end

  # -- sending ----------------------------------------------------------------

  defp send_to_both(datagrams, from, data) do
    <<idx>> = <<data.idx::8>>
    stamped = Enum.map(datagrams, &%{&1 | idx: idx})
    awaiting_callers = [{from, [idx]}]

    case Frame.encode(stamped) do
      {:error, :frame_too_large} = err ->
        {:keep_state_and_data, [{:reply, from, err}]}

      {:ok, payload} ->
        size = byte_size(payload)
        data.transport_mod.set_active_once(data.primary)
        data.transport_mod.set_active_once(data.secondary)
        pri_res = data.transport_mod.send(data.primary, payload)
        sec_res = data.transport_mod.send(data.secondary, payload)

        case {pri_res, sec_res} do
          {{:ok, tx}, {:ok, tx2}} ->
            Telemetry.frame_sent(data.transport_mod.name(data.primary), :primary, size, tx)
            Telemetry.frame_sent(data.transport_mod.name(data.secondary), :secondary, size, tx2)
            await(data, awaiting_callers, idx, :both)

          {{:ok, tx}, {:error, reason}} ->
            Telemetry.frame_sent(data.transport_mod.name(data.primary), :primary, size, tx)
            Telemetry.socket_down(data.transport_mod.name(data.secondary), reason)

            await(
              %{data | secondary: data.transport_mod.close(data.secondary)},
              awaiting_callers,
              idx,
              :primary_only
            )

          {{:error, reason}, {:ok, tx}} ->
            Telemetry.frame_sent(data.transport_mod.name(data.secondary), :secondary, size, tx)
            Telemetry.socket_down(data.transport_mod.name(data.primary), reason)

            await(
              %{data | primary: data.transport_mod.close(data.primary)},
              awaiting_callers,
              idx,
              :secondary_only
            )

          {{:error, r1}, {:error, r2}} ->
            Telemetry.socket_down(data.transport_mod.name(data.primary), r1)
            Telemetry.socket_down(data.transport_mod.name(data.secondary), r2)
            {:next_state, :down, close_sockets(data), [{:reply, from, {:error, :down}}]}
        end
    end
  end

  defp send_single(datagrams, from, data) do
    <<idx>> = <<data.idx::8>>
    stamped = Enum.map(datagrams, &%{&1 | idx: idx})
    awaiting_callers = [{from, [idx]}]

    {transport, port} =
      if data.transport_mod.open?(data.primary),
        do: {data.primary, :primary},
        else: {data.secondary, :secondary}

    case Frame.encode(stamped) do
      {:error, :frame_too_large} = err ->
        {:keep_state_and_data, [{:reply, from, err}]}

      {:ok, payload} ->
        data.transport_mod.set_active_once(transport)

        case data.transport_mod.send(transport, payload) do
          {:ok, tx} ->
            Telemetry.frame_sent(data.transport_mod.name(transport), port, byte_size(payload), tx)
            mode = if port == :primary, do: :primary_only, else: :secondary_only
            await(data, awaiting_callers, idx, mode)

          {:error, reason} ->
            Telemetry.socket_down(data.transport_mod.name(transport), reason)
            {:next_state, :down, close_sockets(data), [{:reply, from, {:error, :down}}]}
        end
    end
  end

  defp await(data, awaiting_callers, _idx, mode) do
    new_data = %{
      data
      | idx: data.idx + 1,
        awaiting_callers: awaiting_callers,
        primary_result: if(mode == :secondary_only, do: [], else: nil),
        secondary_result: if(mode == :primary_only, do: [], else: nil)
    }

    {:next_state, {:awaiting, mode}, new_data,
     [{:state_timeout, data.frame_timeout_ms, :timeout}]}
  end

  # -- receiving --------------------------------------------------------------

  defp handle_recv(which, payload, mode, data) do
    expected_idx = get_expected_idx(data.awaiting_callers)

    case decode_matching(payload, expected_idx) do
      {:ok, dgs} ->
        data = store(data, which, dgs)
        maybe_complete(data, mode)

      :skip ->
        Telemetry.frame_dropped(
          data.transport_mod.name(get_transport(data, which)),
          byte_size(payload),
          :idx_mismatch
        )

        sock = get_transport(data, which)
        data.transport_mod.set_active_once(sock)
        :keep_state_and_data
    end
  end

  defp decode_matching(payload, expected_idx) do
    with {:ok, datagrams} <- Frame.decode(payload),
         [_ | _] = matching <- Enum.filter(datagrams, &(&1.idx == expected_idx)) do
      {:ok, matching}
    else
      _ -> :skip
    end
  end

  defp store(data, :primary, result), do: %{data | primary_result: result}
  defp store(data, :secondary, result), do: %{data | secondary_result: result}

  defp maybe_complete(%{primary_result: p, secondary_result: s} = data, _mode)
       when not is_nil(p) and not is_nil(s) do
    merged = merge(p, s)
    dispatch_results(merged, data.awaiting_callers)
    flush_pending(%{data | awaiting_callers: nil, primary_result: nil, secondary_result: nil})
  end

  defp maybe_complete(data, _mode), do: {:keep_state, data}

  defp dispatch_results(datagrams, awaiting_callers) do
    idx_map = Map.new(datagrams, &{&1.idx, &1})

    Enum.each(awaiting_callers, fn {from, idxs} ->
      results = Enum.map(idxs, &Map.get(idx_map, &1))
      :gen_statem.reply(from, {:ok, results})
    end)
  end

  # -- merge ------------------------------------------------------------------

  @doc false
  def merge([], dgs), do: dgs
  def merge(dgs, []), do: dgs

  def merge(a, b) do
    Enum.zip(a, b)
    |> Enum.map(fn {p, s} -> if p.wkc >= s.wkc, do: p, else: s end)
  end

  # -- pending queue flush ----------------------------------------------------

  defp flush_pending(%{pending: []} = data) do
    next =
      cond do
        data.transport_mod.open?(data.primary) and data.transport_mod.open?(data.secondary) ->
          :idle

        data.transport_mod.open?(data.primary) or data.transport_mod.open?(data.secondary) ->
          :degraded

        true ->
          :down
      end

    {:next_state, next, data}
  end

  defp flush_pending(data) do
    {batch, overflow} = take_within_mtu(data.pending)

    {stamped_batch, new_idx} =
      Enum.map_reduce(batch, data.idx, fn {from, dgs}, idx ->
        {stamped, next_idx} = stamp_indices(dgs, idx)
        {{from, stamped}, next_idx}
      end)

    awaiting_callers =
      Enum.map(stamped_batch, fn {from, dgs} ->
        {from, Enum.map(dgs, & &1.idx)}
      end)

    all_dgs = Enum.flat_map(stamped_batch, fn {_, dgs} -> dgs end)

    case Frame.encode(all_dgs) do
      {:ok, payload} ->
        do_flush_send(data, payload, awaiting_callers, new_idx, overflow)

      {:error, :frame_too_large} ->
        Enum.each(batch, fn {from, _} -> :gen_statem.reply(from, {:error, :frame_too_large}) end)
        flush_pending(%{data | pending: overflow, awaiting_callers: nil})
    end
  end

  defp do_flush_send(data, payload, awaiting_callers, new_idx, overflow) do
    size = byte_size(payload)
    pri_up = data.transport_mod.open?(data.primary)
    sec_up = data.transport_mod.open?(data.secondary)

    expected_idx = get_expected_idx(awaiting_callers)

    cond do
      pri_up and sec_up ->
        data.transport_mod.set_active_once(data.primary)
        data.transport_mod.set_active_once(data.secondary)
        pri_res = data.transport_mod.send(data.primary, payload)
        sec_res = data.transport_mod.send(data.secondary, payload)

        handle_both_flush_send(
          data,
          pri_res,
          sec_res,
          size,
          awaiting_callers,
          new_idx,
          expected_idx,
          overflow
        )

      pri_up ->
        data.transport_mod.set_active_once(data.primary)

        case data.transport_mod.send(data.primary, payload) do
          {:ok, tx} ->
            Telemetry.frame_sent(data.transport_mod.name(data.primary), :primary, size, tx)
            Telemetry.batch_sent(data.transport_mod.name(data.primary), length(awaiting_callers))

            new_data = %{
              data
              | idx: new_idx,
                awaiting_callers: awaiting_callers,
                pending: overflow,
                primary_result: nil,
                secondary_result: []
            }

            {:next_state, {:awaiting, :primary_only}, new_data,
             [{:state_timeout, data.frame_timeout_ms, :timeout}]}

          {:error, reason} ->
            Telemetry.socket_down(data.transport_mod.name(data.primary), reason)
            all_pending = awaiting_callers ++ Enum.map(overflow, fn {f, _} -> {f, []} end)
            actions = Enum.map(all_pending, fn {from, _} -> {:reply, from, {:error, :down}} end)
            {:next_state, :down, %{data | pending: []}, actions}
        end

      sec_up ->
        data.transport_mod.set_active_once(data.secondary)

        case data.transport_mod.send(data.secondary, payload) do
          {:ok, tx} ->
            Telemetry.frame_sent(data.transport_mod.name(data.secondary), :secondary, size, tx)

            Telemetry.batch_sent(
              data.transport_mod.name(data.secondary),
              length(awaiting_callers)
            )

            new_data = %{
              data
              | idx: new_idx,
                awaiting_callers: awaiting_callers,
                pending: overflow,
                primary_result: [],
                secondary_result: nil
            }

            {:next_state, {:awaiting, :secondary_only}, new_data,
             [{:state_timeout, data.frame_timeout_ms, :timeout}]}

          {:error, reason} ->
            Telemetry.socket_down(data.transport_mod.name(data.secondary), reason)
            all_pending = awaiting_callers ++ Enum.map(overflow, fn {f, _} -> {f, []} end)
            actions = Enum.map(all_pending, fn {from, _} -> {:reply, from, {:error, :down}} end)
            {:next_state, :down, %{data | pending: []}, actions}
        end

      true ->
        all_pending = awaiting_callers ++ overflow
        actions = Enum.map(all_pending, fn {from, _} -> {:reply, from, {:error, :down}} end)
        {:next_state, :down, %{data | pending: []}, actions}
    end
  end

  defp handle_both_flush_send(
         data,
         pri_res,
         sec_res,
         size,
         awaiting_callers,
         new_idx,
         _expected_idx,
         overflow
       ) do
    case {pri_res, sec_res} do
      {{:ok, tx}, {:ok, tx2}} ->
        Telemetry.frame_sent(data.transport_mod.name(data.primary), :primary, size, tx)
        Telemetry.frame_sent(data.transport_mod.name(data.secondary), :secondary, size, tx2)
        Telemetry.batch_sent(data.transport_mod.name(data.primary), length(awaiting_callers))

        new_data = %{
          data
          | idx: new_idx,
            awaiting_callers: awaiting_callers,
            pending: overflow,
            primary_result: nil,
            secondary_result: nil
        }

        {:next_state, {:awaiting, :both}, new_data,
         [{:state_timeout, data.frame_timeout_ms, :timeout}]}

      {{:ok, tx}, {:error, reason}} ->
        Telemetry.frame_sent(data.transport_mod.name(data.primary), :primary, size, tx)
        Telemetry.socket_down(data.transport_mod.name(data.secondary), reason)

        new_data = %{
          data
          | idx: new_idx,
            awaiting_callers: awaiting_callers,
            pending: overflow,
            primary_result: nil,
            secondary: data.transport_mod.close(data.secondary),
            secondary_result: []
        }

        {:next_state, {:awaiting, :primary_only}, new_data,
         [{:state_timeout, data.frame_timeout_ms, :timeout}]}

      {{:error, reason}, {:ok, tx}} ->
        Telemetry.frame_sent(data.transport_mod.name(data.secondary), :secondary, size, tx)
        Telemetry.socket_down(data.transport_mod.name(data.primary), reason)

        new_data = %{
          data
          | idx: new_idx,
            awaiting_callers: awaiting_callers,
            pending: overflow,
            secondary_result: nil,
            primary: data.transport_mod.close(data.primary),
            primary_result: []
        }

        {:next_state, {:awaiting, :secondary_only}, new_data,
         [{:state_timeout, data.frame_timeout_ms, :timeout}]}

      {{:error, r1}, {:error, r2}} ->
        Telemetry.socket_down(data.transport_mod.name(data.primary), r1)
        Telemetry.socket_down(data.transport_mod.name(data.secondary), r2)
        all_pending = awaiting_callers ++ overflow
        actions = Enum.map(all_pending, fn {from, _} -> {:reply, from, {:error, :down}} end)
        {:next_state, :down, close_sockets(%{data | pending: []}), actions}
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp stamp_indices(datagrams, start_idx) do
    Enum.map_reduce(datagrams, start_idx, fn dg, idx ->
      <<byte_idx>> = <<idx::8>>
      {%{dg | idx: byte_idx}, idx + 1}
    end)
  end

  defp take_within_mtu(pending) do
    {batch_rev, _} =
      Enum.reduce_while(pending, {[], 0}, fn {_from, dgs} = entry, {acc_rev, size} ->
        entry_size = Enum.sum(Enum.map(dgs, &Datagram.wire_size/1))
        new_size = size + entry_size

        if acc_rev == [] or new_size <= @max_datagram_bytes do
          {:cont, {[entry | acc_rev], new_size}}
        else
          {:halt, {acc_rev, size}}
        end
      end)

    batch = Enum.reverse(batch_rev)
    overflow = Enum.drop(pending, length(batch))
    {batch, overflow}
  end

  defp get_expected_idx(awaiting_callers) do
    # In redundant mode, all datagrams share the same idx byte range.
    # The first idx in the first caller is representative for frame matching.
    case awaiting_callers do
      [{_, [idx | _]} | _] -> idx
      _ -> nil
    end
  end

  defp get_transport(data, :primary), do: data.primary
  defp get_transport(data, :secondary), do: data.secondary

  defp close_sockets(data) do
    %{
      data
      | primary: data.transport_mod.close(data.primary),
        secondary: data.transport_mod.close(data.secondary)
    }
  end

  defp try_reconnect(data) do
    data =
      if not data.transport_mod.open?(data.primary) do
        iface = data.transport_mod.interface(data.primary)

        if iface && carrier_up?(iface) do
          opts = [interface: iface, transport_mod: data.transport_mod]

          case data.transport_mod.open(opts) do
            {:ok, transport} ->
              Telemetry.socket_reconnected(data.transport_mod.name(transport))
              %{data | primary: transport}

            {:error, _} ->
              data
          end
        else
          data
        end
      else
        data
      end

    if not data.transport_mod.open?(data.secondary) do
      iface = data.transport_mod.interface(data.secondary)

      if iface && carrier_up?(iface) do
        opts = [interface: iface, transport_mod: data.transport_mod]

        case data.transport_mod.open(opts) do
          {:ok, transport} ->
            Telemetry.socket_reconnected(data.transport_mod.name(transport))
            %{data | secondary: transport}

          {:error, _} ->
            data
        end
      else
        data
      end
    else
      data
    end
  end

  defp carrier_up?(interface) do
    VintageNet.get(["interface", interface, "lower_up"]) == true
  end
end
