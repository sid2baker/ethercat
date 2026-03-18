defmodule EtherCAT.Bus.Link.Redundant do
  @moduledoc """
  Dual-port bus link implemented as a gen_statem.

  Owns two transports (primary and secondary), scheduling (queues, batching,
  stale expiry), in-flight exchange tracking, and caller replies.

  ## Ring topology

  In a healthy EtherCAT redundant ring, frames cross between ports:

    * Primary TX → slaves (forward) → Secondary RX
    * Secondary TX → slaves (reverse) → Primary RX

  Each received frame is classified by comparing its Ethernet source MAC
  against the MAC addresses of both NICs.

  ## Exchange flow

  Every exchange sends on **both** ports simultaneously, starts a timeout,
  and saves the caller. Frames are classified on arrival:

    * **Cross-delivery** — frame arrived on the opposite port (src MAC
      belongs to the other NIC). Ring path is healthy.
    * **Bounce-back** — frame arrived on the same port it was sent from
      (src MAC matches own NIC). Ring is broken; the frame reflected at
      the break point.

  The forward cross (primary's frame on secondary) is authoritative and
  triggers an immediate reply to the caller. The reverse cross (secondary's
  frame on primary) is confirmation only.

  ```
  flowchart TD
      IDLE -->|transact| SEND
      SEND[Send on BOTH ports, start timeout] --> WAIT

      WAIT{First frame?}

      WAIT -->|pri MAC on sec| REPLY_OK
      WAIT -->|sec MAC on pri| GOT_REV
      WAIT -->|pri MAC on pri| GOT_PRI_B
      WAIT -->|sec MAC on sec| GOT_SEC_B
      WAIT -->|timeout| ERR_TIMEOUT

      GOT_REV{Reverse cross saved} -->|pri MAC on sec| REPLY_OK
      GOT_REV -->|pri MAC on pri| MERGE
      GOT_REV -->|timeout| ERR_PARTIAL

      GOT_PRI_B{Pri bounced} -->|sec MAC on sec| MERGE
      GOT_PRI_B -->|sec MAC on pri| REPLY_OK
      GOT_PRI_B -->|timeout| ERR_PARTIAL

      GOT_SEC_B{Sec bounced} -->|pri MAC on pri| MERGE
      GOT_SEC_B -->|pri MAC on sec| REPLY_OK
      GOT_SEC_B -->|timeout| ERR_PARTIAL

      REPLY_OK([Reply OK]) --> IDLE
      MERGE([Merge bounced frames / degraded]) --> IDLE
      ERR_TIMEOUT([Error timeout / both ports down]) --> IDLE
      ERR_PARTIAL([Error partial / mark port down]) --> IDLE
  ```

  ## gen_statem states

    * `:idle` — no exchange in flight, ready to dispatch
    * `:awaiting` — exchange sent, waiting for reply(ies)

  The bus does not track per-port health. It always sends on both ports
  if the transport is open. The caller decides what to do with timeouts.
  """

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.Bus.Frame
  alias EtherCAT.Bus.Link
  alias EtherCAT.Bus.Link.{RedundantMerge, Submission}
  alias EtherCAT.Bus.Transport.{RawSocket, UdpSocket}
  alias EtherCAT.Telemetry

  @max_dispatch_errors 3
  @merge_window_ms 25

  defstruct [
    # Transport (required)
    :pri_transport,
    :pri_mac,
    :sec_transport,
    :sec_mac,
    :transport_mod,
    :link_name,

    # Scheduling
    idx: 0,
    realtime: :queue.new(),
    reliable: :queue.new(),

    # In-flight exchange
    exchange: nil,

    # Config
    frame_timeout_ms: 25,

    # Stats
    pri_health: :up,
    pri_last_error_reason: nil,
    sec_health: :up,
    sec_last_error_reason: nil,
    timeout_count: 0,
    settle_callers: []
  ]

  # -- Public API --

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5000
    }
  end

  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    case opts[:name] do
      nil -> :gen_statem.start_link(__MODULE__, opts, [])
      name -> start_named(name, opts)
    end
  end

  # -- gen_statem callbacks --

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(opts) do
    transport_mod = resolve_transport_mod(opts)
    frame_timeout_ms = Keyword.get(opts, :frame_timeout_ms, 25)

    # Drop outgoing echoes — AF_PACKET delivers copies of our own TX frames which
    # race with real cross-delivery responses and would return wkc=0 data.
    pri_opts = Keyword.put_new(opts, :drop_outgoing_echo?, true)

    sec_opts =
      opts
      |> Keyword.put(:interface, Keyword.fetch!(opts, :backup_interface))
      |> Keyword.put_new(:drop_outgoing_echo?, true)

    with {:ok, pri_transport} <- transport_mod.open(pri_opts),
         {:ok, sec_transport} <- open_secondary(transport_mod, sec_opts, pri_transport) do
      pri_name = transport_mod.name(pri_transport)
      sec_name = transport_mod.name(sec_transport)
      link_name = "#{pri_name}|#{sec_name}"
      Logger.metadata(component: :bus, link: link_name)

      {:ok, :idle,
       %__MODULE__{
         pri_transport: pri_transport,
         pri_mac: transport_mod.src_mac(pri_transport),
         sec_transport: sec_transport,
         sec_mac: transport_mod.src_mac(sec_transport),
         transport_mod: transport_mod,
         link_name: link_name,
         frame_timeout_ms: frame_timeout_ms
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # -- State enter --

  @impl true
  def handle_event(:enter, _old, :idle, _data), do: :keep_state_and_data
  def handle_event(:enter, _old, :awaiting, _data), do: :keep_state_and_data

  # -- Transact (all states accept submissions) --

  def handle_event({:call, from}, {:transact, tx, stale_after_us, enqueued_at_us}, state, data) do
    submission = %Submission{
      from: from,
      tx: tx,
      stale_after_us: stale_after_us,
      enqueued_at_us: enqueued_at_us
    }

    new_data = Link.enqueue(data, submission)
    class = Link.submission_class(submission)
    Telemetry.submission_enqueued(data.link_name, class, state, Link.queue_depth(new_data, class))

    case state do
      :idle -> dispatch_next(new_data)
      :awaiting -> {:keep_state, new_data}
    end
  end

  # -- Set frame timeout --

  def handle_event({:call, from}, {:set_frame_timeout, timeout_ms}, _state, data)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    {:keep_state, %{data | frame_timeout_ms: timeout_ms}, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, {:set_frame_timeout, _timeout_ms}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :invalid_timeout}}]}
  end

  # -- Settle --

  def handle_event({:call, from}, :settle, :idle, data) do
    {:keep_state, drain_transports(data), [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :settle, :awaiting, data) do
    {:keep_state, %{data | settle_callers: [from | data.settle_callers]}}
  end

  # -- Info --

  def handle_event({:call, from}, :info, state, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, render_info(state, data)}}]}
  end

  # -- Receive reply (awaiting only) --

  def handle_event(:info, msg, :awaiting, data) do
    case match_port(data, msg) do
      {:ok, port_id, ecat_payload, rx_at, frame_src_mac} ->
        handle_rx(data, port_id, ecat_payload, rx_at, frame_src_mac)

      :ignore ->
        :keep_state_and_data
    end
  end

  # -- Frame timeout --

  def handle_event(:state_timeout, :timeout, :awaiting, data) do
    handle_timeout(data)
  end

  # -- Catch-all --

  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  @impl true
  def terminate(_reason, _state, %__MODULE__{} = data) do
    data.transport_mod.close(data.pri_transport)
    data.transport_mod.close(data.sec_transport)
    :ok
  end

  # -- Dispatch loop --

  defp dispatch_next(data), do: dispatch_next(data, 0)

  defp dispatch_next(data, errors) when errors >= @max_dispatch_errors do
    if queue_total(data) > 0 do
      Logger.warning(
        "[Link.Redundant] dispatch guard: rejecting #{queue_total(data)} queued submission(s) after #{@max_dispatch_errors} consecutive send failures",
        component: :bus,
        event: :dispatch_guard,
        link: data.link_name
      )
    end

    new_data = Link.flush_all(data, {:error, :transport_unavailable})
    idle_after_settle(new_data)
  end

  defp dispatch_next(data, errors) do
    data = Link.expire_stale_realtime(data, data.link_name)

    case Link.next_dispatch(data) do
      {:realtime, submission, data} ->
        do_send_realtime(submission, data, errors)

      {:reliable, batch, data} ->
        do_send_reliable(batch, data, errors)

      :empty ->
        idle_after_settle(data)
    end
  end

  defp do_send_realtime(%Submission{} = submission, data, errors) do
    {datagrams, awaiting, next_idx} = Link.prepare_realtime(submission, data.idx)
    datagram_count = length(datagrams)

    case send_frame(datagrams, awaiting, data, next_idx, :realtime) do
      {:ok, new_data, actions} ->
        Telemetry.dispatch_sent(data.link_name, :realtime, 1, datagram_count)
        {:next_state, :awaiting, new_data, actions}

      {:error, :frame_too_large, new_data} ->
        :gen_statem.reply(submission.from, {:error, :frame_too_large})
        dispatch_next(new_data, errors)

      {:error, reason, new_data} ->
        Link.reply_submissions([submission], {:error, reason})
        dispatch_next(new_data, errors + 1)
    end
  end

  defp do_send_reliable(batch, data, errors) do
    {datagrams, awaiting, next_idx} = Link.prepare_reliable(batch, data.idx)
    datagram_count = length(datagrams)

    case send_frame(datagrams, awaiting, data, next_idx, :reliable) do
      {:ok, new_data, actions} ->
        Telemetry.dispatch_sent(data.link_name, :reliable, length(batch), datagram_count)
        {:next_state, :awaiting, new_data, actions}

      {:error, :frame_too_large, new_data} ->
        Link.reply_submissions(batch, {:error, :frame_too_large})
        dispatch_next(new_data, errors)

      {:error, reason, new_data} ->
        Link.reply_submissions(batch, {:error, reason})
        dispatch_next(new_data, errors + 1)
    end
  end

  defp send_frame(datagrams, awaiting, data, next_idx, tx_class) do
    case Frame.encode(datagrams) do
      {:error, :frame_too_large} ->
        {:error, :frame_too_large, data}

      {:ok, payload} ->
        {data, pri_sent?, pri_tx_at} = send_on_port(data, :primary, payload)
        {data, sec_sent?, sec_tx_at} = send_on_port(data, :secondary, payload)

        if pri_sent? or sec_sent? do
          tx_at = earliest_timestamp(pri_tx_at, sec_tx_at) || System.monotonic_time()

          exchange = %{
            idx: hd(datagrams).idx,
            payload: payload,
            datagrams: datagrams,
            awaiting: awaiting,
            tx_class: tx_class,
            tx_at: tx_at,
            payload_size: byte_size(payload),
            datagram_count: length(datagrams),
            pri_sent?: pri_sent?,
            sec_sent?: sec_sent?,
            arrivals: []
          }

          {:ok, %{data | idx: next_idx, exchange: exchange},
           [{:state_timeout, data.frame_timeout_ms, :timeout}]}
        else
          {:error, :transport_unavailable, data}
        end
    end
  end

  # -- Port send --

  defp send_on_port(data, port_id, payload) do
    transport = port_transport(data, port_id)
    endpoint = data.transport_mod.name(transport)

    cond do
      not data.transport_mod.open?(transport) ->
        {mark_port_down(data, port_id, endpoint, :transport_closed), false, nil}

      true ->
        data.transport_mod.set_active_once(transport)

        case data.transport_mod.send(transport, payload) do
          {:ok, tx_at} ->
            data = mark_port_up(data, port_id, endpoint)
            Telemetry.frame_sent(data.link_name, endpoint, port_id, byte_size(payload), tx_at)
            {data, true, tx_at}

          {:error, reason} ->
            {mark_port_down(data, port_id, endpoint, reason), false, nil}
        end
    end
  end

  # -- Frame classification --

  # Cross-deliveries: frame arrived on the OPPOSITE port
  defp classify_frame(%{pri_mac: pm}, :secondary, src) when is_binary(pm) and src == pm,
    do: :forward_cross

  defp classify_frame(%{sec_mac: sm}, :primary, src) when is_binary(sm) and src == sm,
    do: :reverse_cross

  # Bounce-backs: frame arrived on the SAME port
  defp classify_frame(%{pri_mac: pm}, :primary, src) when is_binary(pm) and src == pm,
    do: :pri_bounce

  defp classify_frame(%{sec_mac: sm}, :secondary, src) when is_binary(sm) and src == sm,
    do: :sec_bounce

  # No MAC info (UDP) or unexpected MAC
  defp classify_frame(_, _, _), do: :unknown

  # -- Receive handling --

  defp handle_rx(data, port_id, ecat_payload, rx_at, frame_src_mac) do
    case Frame.decode(ecat_payload) do
      {:ok, datagrams} ->
        if Link.all_expected_present?(data.exchange, datagrams) do
          # Content-based echo filter: if the received frame is byte-for-byte
          # identical to the sent frame (all wkc=0, data unchanged), it's an
          # outgoing echo that slipped through the transport-level pkttype
          # filter. Discard it and wait for the real cross-delivery response.
          if echo_copy?(data.exchange, datagrams) do
            Telemetry.frame_dropped(data.link_name, byte_size(ecat_payload), :echo_copy)
            rearm_port(data, port_id)
            {:keep_state, data}
          else
            endpoint = data.transport_mod.name(port_transport(data, port_id))

            Telemetry.frame_received(
              data.link_name,
              endpoint,
              port_id,
              byte_size(ecat_payload),
              rx_at
            )

            class = classify_frame(data, port_id, frame_src_mac)

            arrival = %{class: class, port: port_id, datagrams: datagrams, rx_at: rx_at}
            exchange = %{data.exchange | arrivals: data.exchange.arrivals ++ [arrival]}
            data = %{data | exchange: exchange}

            case maybe_complete(data) do
              {:keep_state, new_data} ->
                # Exchange still waiting — re-arm so we can read more frames on
                # this port (e.g. the real cross-delivery after an echo).
                rearm_port(new_data, port_id)
                {:keep_state, new_data}

              {:keep_state, new_data, actions} ->
                rearm_port(new_data, port_id)
                {:keep_state, new_data, actions}

              completed ->
                completed
            end
          end
        else
          Telemetry.frame_dropped(data.link_name, byte_size(ecat_payload), :idx_mismatch)
          rearm_port(data, port_id)
          :keep_state_and_data
        end

      {:error, _reason} ->
        Telemetry.frame_dropped(data.link_name, byte_size(ecat_payload), :decode_error)
        rearm_port(data, port_id)
        :keep_state_and_data
    end
  end

  # -- Completion logic --

  defp maybe_complete(data) do
    case resolve_arrivals(data.exchange) do
      {:done, datagrams} ->
        complete_exchange(data, datagrams)

      :waiting ->
        {:keep_state, data}

      :waiting_merge ->
        # First reply arrived; shorten timeout to a merge window for the second
        {:keep_state, data, [{:state_timeout, @merge_window_ms, :timeout}]}
    end
  end

  defp resolve_arrivals(%{arrivals: arrivals} = exchange) do
    # Forward cross is authoritative — instant completion
    case find_class(arrivals, :forward_cross) do
      %{datagrams: datagrams} ->
        {:done, datagrams}

      nil ->
        resolve_non_forward(arrivals, exchange)
    end
  end

  defp resolve_non_forward(arrivals, exchange) do
    expected_count = expected_reply_count(exchange)

    case arrivals do
      [] ->
        :waiting

      [single] ->
        cond do
          expected_count <= 1 ->
            # Only one port sent — this single reply completes the exchange
            {:done, single.datagrams}

          single.class == :unknown and frame_processed?(single.datagrams) ->
            # Unknown MAC classification but frame was processed (wkc > 0).
            # On real hardware where MAC comparison may not match (e.g. slave
            # ASICs, NIC offload), treat a processed reply as authoritative.
            {:done, single.datagrams}

          true ->
            # Both ports sent — shorten timeout to merge window for the second frame
            :waiting_merge
        end

      [a, b] ->
        resolve_two_arrivals(a, b, exchange)

      _more ->
        # Shouldn't happen, but resolve with what we have
        resolve_best_effort(arrivals, exchange)
    end
  end

  defp expected_reply_count(exchange) do
    Enum.count([exchange.pri_sent?, exchange.sec_sent?], & &1)
  end

  defp frame_processed?(datagrams) do
    Enum.any?(datagrams, fn dg -> dg.wkc > 0 end)
  end

  defp resolve_two_arrivals(a, b, exchange) do
    classes = MapSet.new([a.class, b.class])

    cond do
      # Any cross present → use the cross data (forward already handled above)
      :reverse_cross in classes ->
        cross = if a.class == :reverse_cross, do: a, else: b
        {:done, cross.datagrams}

      # Both bounces → merge complementary data
      :pri_bounce in classes and :sec_bounce in classes ->
        {pri, sec} = if a.class == :pri_bounce, do: {a, b}, else: {b, a}
        merged = RedundantMerge.merge_bounces(exchange.datagrams, pri.datagrams, sec.datagrams)

        if frame_processed?(merged) do
          # Legitimate ring break: slaves on both sides processed the frame.
          {:done, merged}
        else
          # All wkc=0 — could be outgoing echoes (AF_PACKET kernel loopback)
          # masquerading as bounces. Wait for potential cross-delivery within
          # the merge window before committing to the wkc=0 result.
          :waiting_merge
        end

      # Two unknowns (UDP, or MAC not matching either NIC) → fall back to interpret/3
      classes == MapSet.new([:unknown]) ->
        {pri_dg, sec_dg} = port_datagrams_from_arrivals([a, b])
        interpretation = RedundantMerge.interpret(exchange.datagrams, pri_dg, sec_dg)

        case interpretation do
          %{status: s, datagrams: dg} when s in [:ok, :partial] and not is_nil(dg) ->
            if frame_processed?(dg) do
              {:done, dg}
            else
              # All wkc=0 — could be outgoing echoes whose source MAC doesn't
              # match either NIC (e.g. slave ASIC rewrites src MAC). Wait for
              # a real cross-delivery within the merge window.
              :waiting_merge
            end

          _ ->
            if frame_processed?(a.datagrams) or frame_processed?(b.datagrams) do
              {:done, a.datagrams}
            else
              :waiting_merge
            end
        end

      # Mixed unknown + bounce, or other unexpected combo
      true ->
        resolve_best_effort([a, b], exchange)
    end
  end

  defp resolve_best_effort(arrivals, _exchange) do
    # Prefer a cross-delivery or any arrival with processed data (wkc > 0)
    cross = Enum.find(arrivals, &(&1.class in [:reverse_cross, :forward_cross]))
    processed = Enum.find(arrivals, &frame_processed?(&1.datagrams))
    any = Enum.find(arrivals, &(&1.datagrams != nil))

    case cross || processed || any do
      %{datagrams: dg} -> {:done, dg}
      nil -> :waiting
    end
  end

  defp find_class(arrivals, class) do
    Enum.find(arrivals, &(&1.class == class))
  end

  defp port_datagrams_from_arrivals(arrivals) do
    pri = Enum.find(arrivals, &(&1.port == :primary))
    sec = Enum.find(arrivals, &(&1.port == :secondary))
    {pri && pri.datagrams, sec && sec.datagrams}
  end

  defp complete_exchange(data, reply_datagrams) do
    exchange = data.exchange

    case Link.match_and_reply(reply_datagrams, exchange.awaiting) do
      :ok -> :ok
      :mismatch -> Link.reply_awaiting(exchange.awaiting, {:error, :mismatch})
    end

    dispatch_next(%{data | exchange: nil, timeout_count: 0})
  end

  # -- Timeout handling --

  defp handle_timeout(data) do
    timeouts = data.timeout_count + 1
    exchange = data.exchange

    if timeouts >= 3 and (timeouts == 3 or rem(timeouts, 100) == 0) do
      n = length(exchange.awaiting)

      Logger.warning(
        "[Link.Redundant] frame timeout -- #{n} caller(s) lost (#{timeouts} consecutive)",
        component: :bus,
        event: :frame_timeout,
        link: data.link_name,
        consecutive_timeouts: timeouts
      )
    end

    data = drain_transports(data)

    # Reply with best-effort data from partial arrivals, or error
    case exchange.arrivals do
      [] ->
        log_timeout(data, :no_arrivals)
        Link.reply_awaiting(exchange.awaiting, {:error, :timeout})

      arrivals ->
        log_timeout(data, :partial_arrivals)
        best_datagrams = best_effort_datagrams(arrivals, exchange)

        case Link.match_and_reply(best_datagrams, exchange.awaiting) do
          :ok -> :ok
          :mismatch -> Link.reply_awaiting(exchange.awaiting, {:error, :timeout})
        end
    end

    dispatch_next(%{data | exchange: nil, timeout_count: timeouts})
  end

  defp best_effort_datagrams(arrivals, exchange) do
    # Prefer cross-delivery data over bounce data
    cross = Enum.find(arrivals, &(&1.class in [:forward_cross, :reverse_cross]))

    if cross do
      cross.datagrams
    else
      # Two bounces? Merge. Otherwise use first arrival.
      pri_bounce = Enum.find(arrivals, &(&1.class == :pri_bounce))
      sec_bounce = Enum.find(arrivals, &(&1.class == :sec_bounce))

      cond do
        pri_bounce && sec_bounce ->
          RedundantMerge.merge_bounces(
            exchange.datagrams,
            pri_bounce.datagrams,
            sec_bounce.datagrams
          )

        true ->
          hd(arrivals).datagrams
      end
    end
  end

  defp log_timeout(data, detail) do
    exchange = data.exchange
    arrival_classes = Enum.map(exchange.arrivals, & &1.class)

    Logger.warning(
      "[Link.Redundant] exchange timeout detail=#{detail} arrivals=#{inspect(arrival_classes)} " <>
        "pri_sent=#{exchange.pri_sent?} sec_sent=#{exchange.sec_sent?}",
      component: :bus,
      event: :redundant_exchange_timeout,
      link: data.link_name,
      detail: detail,
      arrival_classes: arrival_classes
    )
  end

  # -- Port matching --

  defp match_port(data, msg) do
    case try_match(data, :primary, msg) do
      {:ok, _, _, _, _} = result -> result
      :ignore -> try_match(data, :secondary, msg)
    end
  end

  defp try_match(data, port_id, msg) do
    transport = port_transport(data, port_id)

    case data.transport_mod.match(transport, msg) do
      {:ok, ecat_payload, rx_at, frame_src_mac} ->
        {:ok, port_id, ecat_payload, rx_at, frame_src_mac}

      :ignore ->
        :ignore
    end
  end

  # -- Helpers --

  defp idle_after_settle(%{settle_callers: []} = data), do: {:next_state, :idle, data}

  defp idle_after_settle(%{settle_callers: callers} = data) do
    data = drain_transports(%{data | settle_callers: []})
    Link.reply_settle_callers(callers, :ok)
    {:next_state, :idle, data}
  end

  defp drain_transports(data) do
    drain_port(data, :primary)
    drain_port(data, :secondary)
    data
  end

  defp drain_port(data, port_id) do
    transport = port_transport(data, port_id)
    data.transport_mod.drain(transport)
  end

  defp rearm_port(data, port_id) do
    transport = port_transport(data, port_id)
    data.transport_mod.rearm(transport)
  end

  # An echo copy is a frame that is byte-for-byte identical to what was sent:
  # all wkc == 0 and datagram data unchanged. This catches AF_PACKET outgoing
  # echoes that slip through the transport-level pkttype filter (e.g. when the
  # NIC driver doesn't set PACKET_OUTGOING, or OTP doesn't decode it).
  #
  # On an empty bus (no slaves), legitimate bounces also match this pattern.
  # Discarding them causes a timeout instead of returning wkc=0 — which is
  # the correct outcome when no slaves are present.
  defp echo_copy?(exchange, response_datagrams) do
    sent = exchange.datagrams

    length(sent) == length(response_datagrams) and
      Enum.all?(Enum.zip(sent, response_datagrams), fn {s, r} ->
        r.wkc == 0 and s.data == r.data
      end)
  end

  defp queue_total(data), do: :queue.len(data.realtime) + :queue.len(data.reliable)

  # -- Port accessors --

  defp port_transport(data, :primary), do: data.pri_transport
  defp port_transport(data, :secondary), do: data.sec_transport

  # -- Info rendering --

  defp render_info(state, data) do
    %{
      state: state,
      link: data.link_name,
      type: :redundant,
      topology: current_topology(data),
      fault: current_fault(data),
      frame_timeout_ms: data.frame_timeout_ms,
      timeout_count: data.timeout_count,
      last_error_reason: last_error_reason(data),
      primary: %{
        interface: data.transport_mod.name(data.pri_transport),
        health: data.pri_health,
        last_error_reason: data.pri_last_error_reason
      },
      secondary: %{
        interface: data.transport_mod.name(data.sec_transport),
        health: data.sec_health,
        last_error_reason: data.sec_last_error_reason
      },
      queue_depths: %{
        realtime: :queue.len(data.realtime),
        reliable: :queue.len(data.reliable)
      },
      in_flight: exchange_info(data.exchange)
    }
  end

  defp exchange_info(nil), do: nil

  defp exchange_info(exchange) do
    %{
      caller_count: length(exchange.awaiting),
      payload_size: exchange.payload_size,
      datagram_count: exchange.datagram_count,
      pri_sent?: exchange.pri_sent?,
      sec_sent?: exchange.sec_sent?,
      pri_replied?: Enum.any?(exchange.arrivals, &(&1.port == :primary)),
      sec_replied?: Enum.any?(exchange.arrivals, &(&1.port == :secondary)),
      age_ms:
        System.convert_time_unit(
          System.monotonic_time() - exchange.tx_at,
          :native,
          :millisecond
        )
    }
  end

  # -- Config helpers --

  defp current_topology(%{pri_health: :up, sec_health: :up}), do: :redundant
  defp current_topology(%{pri_health: :down, sec_health: :up}), do: :degraded_primary_leg
  defp current_topology(%{pri_health: :up, sec_health: :down}), do: :degraded_secondary_leg
  defp current_topology(%{pri_health: :down, sec_health: :down}), do: :offline

  defp current_fault(%{pri_health: :up, sec_health: :up}), do: nil

  defp current_fault(data) do
    %{
      kind: :transport_fault,
      degraded_ports:
        []
        |> maybe_add_degraded_port(:primary, data.pri_health)
        |> maybe_add_degraded_port(:secondary, data.sec_health),
      reasons:
        %{}
        |> maybe_put_reason(:primary, data.pri_last_error_reason)
        |> maybe_put_reason(:secondary, data.sec_last_error_reason)
    }
  end

  defp last_error_reason(%{pri_last_error_reason: nil, sec_last_error_reason: nil}), do: nil

  defp last_error_reason(data) do
    %{}
    |> maybe_put_reason(:primary, data.pri_last_error_reason)
    |> maybe_put_reason(:secondary, data.sec_last_error_reason)
  end

  defp mark_port_down(data, port_id, endpoint, reason) do
    previous = port_health(data, port_id)
    data = put_port_status(data, port_id, :down, reason)

    if previous != :down do
      Telemetry.link_down(data.link_name, endpoint, reason)
      Telemetry.link_health_changed(data.link_name, port_id, previous, :down)
    end

    data
  end

  defp mark_port_up(data, port_id, endpoint) do
    previous = port_health(data, port_id)
    data = put_port_status(data, port_id, :up, nil)

    if previous != :up do
      Telemetry.link_reconnected(data.link_name, endpoint)
      Telemetry.link_health_changed(data.link_name, port_id, previous, :up)
    end

    data
  end

  defp port_health(data, :primary), do: data.pri_health
  defp port_health(data, :secondary), do: data.sec_health

  defp put_port_status(data, :primary, health, reason) do
    %{data | pri_health: health, pri_last_error_reason: reason}
  end

  defp put_port_status(data, :secondary, health, reason) do
    %{data | sec_health: health, sec_last_error_reason: reason}
  end

  defp maybe_add_degraded_port(acc, _port_id, :up), do: acc
  defp maybe_add_degraded_port(acc, port_id, :down), do: acc ++ [port_id]

  defp maybe_put_reason(map, _port_id, nil), do: map
  defp maybe_put_reason(map, port_id, reason), do: Map.put(map, port_id, reason)

  defp earliest_timestamp(nil, other), do: other
  defp earliest_timestamp(other, nil), do: other
  defp earliest_timestamp(left, right), do: min(left, right)

  defp resolve_transport_mod(opts) do
    opts[:transport_mod] ||
      case opts[:transport] do
        :udp -> UdpSocket
        _ -> RawSocket
      end
  end

  defp open_secondary(transport_mod, sec_opts, pri_transport) do
    case transport_mod.open(sec_opts) do
      {:ok, sec_transport} ->
        {:ok, sec_transport}

      {:error, reason} ->
        transport_mod.close(pri_transport)
        {:error, reason}
    end
  end

  defp start_named({:local, _name} = name, opts),
    do: :gen_statem.start_link(name, __MODULE__, opts, [])

  defp start_named({:global, _name} = name, opts),
    do: :gen_statem.start_link(name, __MODULE__, opts, [])

  defp start_named({:via, _mod, _name} = name, opts),
    do: :gen_statem.start_link(name, __MODULE__, opts, [])

  defp start_named(name, opts) when is_atom(name),
    do: :gen_statem.start_link({:local, name}, __MODULE__, opts, [])
end
