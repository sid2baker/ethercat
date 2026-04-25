defmodule EtherCAT.Bus.Link.Redundant do
  @moduledoc """
  Dual-port bus link implemented as a gen_statem.

  Owns two transports (primary and secondary), scheduling (queues, batching,
  stale expiry), in-flight exchange tracking, and caller replies.

  In production this link is raw-only: both ports are expected to be
  `EtherCAT.Bus.Transport.RawSocket` interfaces. The `transport_mod` option
  remains available for tests and transport fakes.

  ## Ring topology

  In a healthy EtherCAT redundant ring, frames cross between ports:

    * Primary TX → slaves (forward) → Secondary RX
    * Secondary TX → slaves (reverse) → Primary RX

  Each received frame is classified by comparing its Ethernet source MAC
  against the MAC addresses of both NICs.

  ## Exchange flow

  Every exchange attempts to send on **both** ports, starts a timeout if at
  least one send succeeds, and saves the caller. Frames are classified on
  arrival:

    * **Cross-delivery** — frame arrived on the opposite port (src MAC
      belongs to the other NIC). Ring path is healthy.
    * **Bounce-back** — frame arrived on the same port it was sent from
      (src MAC matches own NIC). Ring is broken; the frame reflected at
      the break point.

  The forward cross (primary's frame on secondary) is authoritative and
  completes immediately. A single reverse cross or bounce keeps the merge
  window open while the link waits for a forward cross or second frame. A
  single `:unknown` arrival with processed datagrams (`wkc > 0`) can also
  complete immediately when MAC classification is not trustworthy. On
  timeout, partial arrivals are converted into a best-effort reply when they
  still match the awaiting datagrams; pure reverse-path copies are not used
  as authoritative data, so only processed or merged bounce data can rescue
  a timed-out exchange. Reliable non-logical one-sided bounces may also
  complete immediately when only a tiny remainder of the original frame-time
  budget is left, avoiding a spurious extra millisecond timer hop near the
  deadline.

  ```mermaid
  flowchart TD
      IDLE -->|transact| SEND
      SEND[Attempt primary and secondary send] -->|any leg sent| WAIT
      SEND -->|both sends fail| ERR_SEND

      WAIT{Arrival or timeout}
      WAIT -->|forward cross| REPLY_OK
      WAIT -->|single authoritative reply on one live leg| REPLY_OK
      WAIT -->|single unknown with wkc>0| REPLY_OK
      WAIT -->|reverse cross / bounce / other unknown| MERGE_WAIT
      WAIT -->|timeout with no arrivals| ERR_TIMEOUT

      MERGE_WAIT{Merge window}
      MERGE_WAIT -->|forward cross arrives| REPLY_OK
      MERGE_WAIT -->|pri bounce + sec bounce| MERGE_OK
      MERGE_WAIT -->|timeout with partial arrivals| BEST_EFFORT

      REPLY_OK([Reply awaiting callers]) --> IDLE
      MERGE_OK([Merge complementary bounces]) --> IDLE
      BEST_EFFORT([Reply with best available datagrams]) --> IDLE
      ERR_TIMEOUT([Reply timeout]) --> IDLE
      ERR_SEND([Reply transport unavailable]) --> IDLE
  ```

  ## gen_statem states

    * `:idle` — no exchange in flight, ready to dispatch
    * `:awaiting` — exchange sent, waiting for reply(ies)

  The link tracks per-port transport health from open/send failures and
  surfaces degraded topology and fault info through `info/1`. Health is
  observational only: a leg marked `:down` is still attempted on the next
  exchange, so reconnects do not wait on a separate health promotion path.
  Timeout observations are logged and emitted as telemetry, but receive-side
  timeout patterns do not directly mark a port down unless send/open state
  also fails.
  """

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.Bus.Frame
  alias EtherCAT.Bus.Link
  alias EtherCAT.Bus.Link.{RedundantMerge, Submission}
  alias EtherCAT.Bus.Transport.RawSocket
  alias EtherCAT.Telemetry

  @max_dispatch_errors 3
  @merge_window_ms 25
  @realtime_bounce_merge_wait_ms 1
  @late_bounce_complete_threshold_ms 3

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
    settle_callers: [],
    timeout_pattern: nil,
    timeout_pattern_count: 0
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
      name -> Link.start_named(__MODULE__, name, opts)
    end
  end

  # -- gen_statem callbacks --

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(opts) do
    with :ok <- validate_supported_transport(opts) do
      do_init(opts)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp do_init(opts) do
    transport_mod = resolve_transport_mod(opts)
    frame_timeout_ms = Keyword.get(opts, :frame_timeout_ms, 25)

    sec_opts =
      opts
      |> Keyword.put(:interface, Keyword.fetch!(opts, :backup_interface))
      |> Keyword.delete(:backup_interface)

    case transport_mod.open(opts) do
      {:ok, pri_transport} ->
        case transport_mod.open(sec_opts) do
          {:ok, sec_transport} ->
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

          {:error, reason} ->
            transport_mod.close(pri_transport)
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
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

  def handle_event({:call, from}, {:set_frame_timeout, timeout_ms}, _state, data) do
    Link.handle_set_frame_timeout(from, timeout_ms, data)
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

      {:error, port_id, reason} ->
        handle_rx_error(data, port_id, reason)

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
    Link.dispatch_realtime(submission, data, errors, &send_frame/5, &dispatch_next/2)
  end

  defp do_send_reliable(batch, data, errors) do
    Link.dispatch_reliable(batch, data, errors, &send_frame/5, &dispatch_next/2)
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
          # A byte-for-byte unchanged `wkc=0` frame is only passthrough data.
          # It proves a leg reflected the frame, but it is not authoritative
          # enough to complete the exchange on its own.
          if passthrough_copy?(data.exchange, datagrams) do
            Telemetry.frame_dropped(data.link_name, byte_size(ecat_payload), :passthrough_copy)
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

  defp handle_rx_error(data, port_id, reason) do
    endpoint = data.transport_mod.name(port_transport(data, port_id))
    drain_port(data, port_id)
    {:keep_state, mark_port_down(data, port_id, endpoint, normalize_rx_error_reason(reason))}
  end

  # -- Completion logic --

  defp maybe_complete(data) do
    case resolve_arrivals(data.exchange, data.frame_timeout_ms) do
      {:done, datagrams} ->
        complete_exchange(data, datagrams)

      :waiting ->
        {:keep_state, data}

      :waiting_merge ->
        # First reply arrived; wait only within the remaining frame-time budget.
        {:keep_state, data,
         [{:state_timeout, merge_timeout_ms(data.exchange, data.frame_timeout_ms), :timeout}]}

      :waiting_realtime_bounce_merge ->
        {:keep_state, data,
         [
           {:state_timeout,
            realtime_bounce_merge_timeout_ms(data.exchange, data.frame_timeout_ms), :timeout}
         ]}
    end
  end

  defp resolve_arrivals(%{arrivals: arrivals} = exchange, frame_timeout_ms) do
    # Forward cross is authoritative — instant completion
    case find_class(arrivals, :forward_cross) do
      %{datagrams: datagrams} ->
        {:done, datagrams}

      nil ->
        resolve_non_forward(arrivals, exchange, frame_timeout_ms)
    end
  end

  defp resolve_non_forward(arrivals, exchange, frame_timeout_ms) do
    expected_count = expected_reply_count(exchange)

    case arrivals do
      [] ->
        :waiting

      [single] ->
        cond do
          wait_for_complementary_realtime_bounce?(single, expected_count, exchange) ->
            :waiting_realtime_bounce_merge

          complete_late_processed_bounce?(
            single,
            expected_count,
            exchange,
            frame_timeout_ms
          ) ->
            # Reliable non-logical bounces do not carry complementary merge
            # data. If only a tiny remainder of the frame budget is left,
            # complete now instead of depending on a coarse millisecond timer
            # to fire before the original timeout has effectively expired.
            {:done, single.datagrams}

          authoritative_single_arrival?(single, expected_count, exchange) ->
            # Only one port sent — this single reply completes the exchange
            {:done, single.datagrams}

          expected_count <= 1 ->
            # Only one leg actually sent, but a lone reverse-path copy still
            # does not prove slave processing. Keep the full timeout instead of
            # completing with non-authoritative data.
            :waiting

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

  defp authoritative_single_arrival?(
         %{class: :unknown, datagrams: datagrams},
         _expected_count,
         _exchange
       ),
       do: frame_processed?(datagrams)

  defp authoritative_single_arrival?(%{class: class}, expected_count, _exchange)
       when expected_count <= 1 and class in [:forward_cross, :pri_bounce, :sec_bounce],
       do: true

  defp authoritative_single_arrival?(
         %{class: class, datagrams: datagrams},
         expected_count,
         %{tx_class: :realtime}
       )
       when expected_count > 1 and class in [:pri_bounce, :sec_bounce] do
    frame_processed?(datagrams)
  end

  defp authoritative_single_arrival?(_arrival, _expected_count, _exchange), do: false

  defp wait_for_complementary_realtime_bounce?(
         %{class: class, datagrams: datagrams},
         expected_count,
         exchange
       )
       when expected_count > 1 and class in [:pri_bounce, :sec_bounce] do
    exchange.tx_class == :realtime and logical_exchange?(exchange) and frame_processed?(datagrams)
  end

  defp wait_for_complementary_realtime_bounce?(_arrival, _expected_count, _exchange), do: false

  defp complete_late_processed_bounce?(
         %{class: class, datagrams: datagrams},
         expected_count,
         exchange,
         frame_timeout_ms
       )
       when expected_count > 1 and class in [:pri_bounce, :sec_bounce] do
    exchange.tx_class == :reliable and
      not logical_exchange?(exchange) and
      frame_processed?(datagrams) and
      merge_timeout_ms(exchange, frame_timeout_ms) <= @late_bounce_complete_threshold_ms
  end

  defp complete_late_processed_bounce?(_arrival, _expected_count, _exchange, _frame_timeout_ms),
    do: false

  defp resolve_two_arrivals(a, b, exchange) do
    classes = MapSet.new([a.class, b.class])

    cond do
      # Both bounces → merge complementary data
      :pri_bounce in classes and :sec_bounce in classes ->
        {pri, sec} = if a.class == :pri_bounce, do: {a, b}, else: {b, a}
        merged = RedundantMerge.merge_bounces(exchange.datagrams, pri.datagrams, sec.datagrams)

        if frame_processed?(merged) do
          # Legitimate ring break: slaves on both sides processed the frame.
          {:done, merged}
        else
          # Both legs only reflected the frame so far. Keep the merge window
          # open instead of completing with unchanged `wkc=0` data.
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
              # Unknown-MAC arrivals can still be pure passthrough data. Wait
              # for a processed reply within the merge window.
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

  defp resolve_best_effort(arrivals, exchange) do
    datagrams = best_effort_datagrams(arrivals, exchange)

    case datagrams do
      nil ->
        :waiting

      dg ->
        if frame_processed?(dg) do
          {:done, dg}
        else
          :waiting
        end
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

    data =
      data
      |> clear_timeout_pattern()
      |> drain_transports()

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

    data =
      data
      |> drain_transports()
      |> Map.put(:timeout_count, timeouts)
      |> record_timeout_observation(exchange, timeout_detail(exchange))

    # Reply with best-effort data from partial arrivals, or error
    case exchange.arrivals do
      [] ->
        Link.reply_awaiting(exchange.awaiting, {:error, :timeout})

      arrivals ->
        best_datagrams = best_effort_datagrams(arrivals, exchange)

        case best_datagrams do
          nil ->
            Link.reply_awaiting(exchange.awaiting, {:error, :timeout})

          _ ->
            case Link.match_and_reply(best_datagrams, exchange.awaiting) do
              :ok -> :ok
              :mismatch -> Link.reply_awaiting(exchange.awaiting, {:error, :timeout})
            end
        end
    end

    dispatch_next(%{data | exchange: nil})
  end

  defp best_effort_datagrams(arrivals, exchange) do
    # Prefer authoritative forward-cross data over bounce data. Reverse-path
    # copies are not authoritative in the healthy ring and should never win a
    # timeout fallback by themselves.
    cross = Enum.find(arrivals, &(&1.class == :forward_cross))

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
          case Enum.find(arrivals, &(&1.class != :reverse_cross)) do
            %{datagrams: datagrams} -> datagrams
            nil -> nil
          end
      end
    end
  end

  defp merge_timeout_ms(%{tx_at: tx_at}, frame_timeout_ms)
       when is_integer(tx_at) and is_integer(frame_timeout_ms) and frame_timeout_ms > 0 do
    elapsed_us =
      System.monotonic_time()
      |> Kernel.-(tx_at)
      |> System.convert_time_unit(:native, :microsecond)

    remaining_us = max(frame_timeout_ms * 1_000 - elapsed_us, 0)
    remaining_ms = ceil_div(remaining_us, 1_000)
    min(@merge_window_ms, remaining_ms)
  end

  defp realtime_bounce_merge_timeout_ms(exchange, frame_timeout_ms) do
    min(@realtime_bounce_merge_wait_ms, merge_timeout_ms(exchange, frame_timeout_ms))
  end

  defp timeout_detail(%{arrivals: []}), do: :no_arrivals
  defp timeout_detail(_exchange), do: :partial_arrivals

  defp record_timeout_observation(data, exchange, detail) do
    arrival_classes = Enum.map(exchange.arrivals, & &1.class)

    Telemetry.redundant_exchange_timeout(
      data.link_name,
      detail,
      arrival_classes,
      exchange.pri_sent?,
      exchange.sec_sent?,
      data.timeout_count
    )

    observation = %{
      detail: detail,
      arrival_classes: arrival_classes,
      pri_sent?: exchange.pri_sent?,
      sec_sent?: exchange.sec_sent?
    }

    case data.timeout_pattern do
      ^observation ->
        %{data | timeout_pattern_count: data.timeout_pattern_count + 1}

      _ ->
        maybe_log_timeout_observation(data.link_name, observation)
        %{data | timeout_pattern: observation, timeout_pattern_count: 1}
    end
  end

  defp maybe_log_timeout_observation(link_name, %{detail: :partial_arrivals} = observation) do
    Logger.warning(
      "[Link.Redundant] exchange timeout detail=#{observation.detail} " <>
        "arrivals=#{inspect(observation.arrival_classes)} " <>
        "pri_sent=#{observation.pri_sent?} sec_sent=#{observation.sec_sent?}",
      component: :bus,
      event: :redundant_exchange_timeout,
      link: link_name,
      detail: observation.detail,
      arrival_classes: observation.arrival_classes
    )
  end

  defp maybe_log_timeout_observation(_link_name, _observation), do: :ok

  defp clear_timeout_pattern(%{timeout_pattern: nil} = data), do: data

  defp clear_timeout_pattern(data) do
    observation = data.timeout_pattern

    maybe_log_timeout_pattern_cleared(data.link_name, observation, data.timeout_pattern_count)

    %{data | timeout_pattern: nil, timeout_pattern_count: 0}
  end

  defp maybe_log_timeout_pattern_cleared(
         link_name,
         %{detail: :partial_arrivals} = observation,
         occurrence_count
       ) do
    Logger.info(
      "[Link.Redundant] exchange timeout pattern cleared detail=#{observation.detail} " <>
        "arrivals=#{inspect(observation.arrival_classes)} " <>
        "pri_sent=#{observation.pri_sent?} sec_sent=#{observation.sec_sent?} " <>
        "after=#{occurrence_count}",
      component: :bus,
      event: :redundant_exchange_timeout_cleared,
      link: link_name,
      detail: observation.detail,
      arrival_classes: observation.arrival_classes,
      occurrence_count: occurrence_count
    )
  end

  defp maybe_log_timeout_pattern_cleared(_link_name, _observation, _occurrence_count), do: :ok

  # -- Port matching --

  defp match_port(data, msg) do
    case try_match(data, :primary, msg) do
      {:ok, _, _, _, _} = result -> result
      {:error, _, _} = result -> result
      :ignore -> try_match(data, :secondary, msg)
    end
  end

  defp try_match(data, port_id, msg) do
    transport = port_transport(data, port_id)

    case data.transport_mod.match(transport, msg) do
      {:ok, ecat_payload, rx_at, frame_src_mac} ->
        {:ok, port_id, ecat_payload, rx_at, frame_src_mac}

      {:error, reason} ->
        {:error, port_id, reason}

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

  # A passthrough copy is byte-for-byte identical to what was sent: all
  # `wkc == 0` and datagram data unchanged. It proves the frame reflected back
  # through the redundant path, but it does not prove any slave processed it.
  #
  # Discarding such arrivals keeps the exchange fail-closed: pure passthrough
  # traffic cannot complete the call, and an empty or unprocessed ring times
  # out instead of returning misleading all-zero success.
  defp passthrough_copy?(exchange, response_datagrams) do
    sent = exchange.datagrams

    length(sent) == length(response_datagrams) and
      Enum.all?(Enum.zip(sent, response_datagrams), fn {s, r} ->
        r.wkc == 0 and s.data == r.data
      end)
  end

  defp logical_exchange?(exchange) do
    Enum.any?(exchange.datagrams, &(&1.cmd in [10, 11, 12]))
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

  defp normalize_rx_error_reason(reason) when is_atom(reason), do: reason
  defp normalize_rx_error_reason(_reason), do: :rx_error

  defp earliest_timestamp(nil, other), do: other
  defp earliest_timestamp(other, nil), do: other
  defp earliest_timestamp(left, right), do: min(left, right)

  defp ceil_div(value, divisor) when is_integer(value) and is_integer(divisor) and divisor > 0 do
    div(value + divisor - 1, divisor)
  end

  defp validate_supported_transport(opts) do
    if opts[:transport_mod] == EtherCAT.Bus.Transport.UdpSocket or opts[:transport] == :udp do
      {:error, :redundant_requires_raw_transport}
    else
      :ok
    end
  end

  defp resolve_transport_mod(opts) do
    opts[:transport_mod] || RawSocket
  end
end
