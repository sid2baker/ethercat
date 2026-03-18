defmodule EtherCAT.Bus.Link.Single do
  @moduledoc """
  Single-port bus link implemented as a gen_statem.

  Owns one transport, scheduling (queues, batching, stale expiry),
  in-flight exchange tracking, and caller replies.

  ## States

    * `:idle` — no exchange in flight, ready to dispatch
    * `:awaiting` — exchange sent, waiting for reply
    * `:unhealthy` — transport dead, periodically attempts reopen
  """

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.Bus.{Datagram, Frame}
  alias EtherCAT.Bus.Link
  alias EtherCAT.Bus.Link.Submission
  alias EtherCAT.Bus.Transport.{RawSocket, UdpSocket}
  alias EtherCAT.Telemetry

  @max_dispatch_errors 3
  @reopen_interval_ms 1_000

  defstruct [
    # Transport
    :transport,
    :transport_mod,
    :open_opts,
    :link_name,

    # Scheduling
    idx: 0,
    realtime: :queue.new(),
    reliable: :queue.new(),

    # In-flight exchange
    # %{idx, payload, datagrams, awaiting, tx_class, tx_at, payload_size, datagram_count}
    exchange: nil,

    # Config
    frame_timeout_ms: 25,

    # Stats
    timeout_count: 0,
    last_error_reason: nil,
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

    case transport_mod.open(opts) do
      {:ok, transport} ->
        link_name = transport_mod.name(transport)
        Logger.metadata(component: :bus, link: link_name)

        {:ok, :idle,
         %__MODULE__{
           transport: transport,
           transport_mod: transport_mod,
           open_opts: opts,
           link_name: link_name,
           frame_timeout_ms: frame_timeout_ms
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # -- State enter --

  @impl true
  def handle_event(:enter, _old, :idle, _data), do: :keep_state_and_data
  def handle_event(:enter, _old, :awaiting, _data), do: :keep_state_and_data

  def handle_event(:enter, _old, :unhealthy, data) do
    {:keep_state, data, [{:state_timeout, @reopen_interval_ms, :reopen}]}
  end

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
      :unhealthy -> {:keep_state, new_data}
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
    {:keep_state, drain_transport(data), [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :settle, :awaiting, data) do
    {:keep_state, %{data | settle_callers: [from | data.settle_callers]}}
  end

  def handle_event({:call, from}, :settle, :unhealthy, _data) do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  # -- Info --

  def handle_event({:call, from}, :info, state, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, render_info(state, data)}}]}
  end

  # -- Receive reply (awaiting only) --

  def handle_event(:info, msg, :awaiting, data) do
    case data.transport_mod.match(data.transport, msg) do
      {:ok, ecat_payload, rx_at, _src_mac} ->
        handle_rx(data, ecat_payload, rx_at)

      :ignore ->
        :keep_state_and_data
    end
  end

  # -- Frame timeout --

  def handle_event(:state_timeout, :timeout, :awaiting, data) do
    handle_timeout(data)
  end

  # -- Reopen (unhealthy) --

  def handle_event(:state_timeout, :reopen, :unhealthy, data) do
    case data.transport_mod.open(data.open_opts) do
      {:ok, transport} ->
        link_name = data.transport_mod.name(transport)
        Telemetry.link_reconnected(link_name, link_name)

        new_data = %{data | transport: transport, link_name: link_name}
        dispatch_next(new_data)

      {:error, _reason} ->
        {:keep_state, data, [{:state_timeout, @reopen_interval_ms, :reopen}]}
    end
  end

  # -- Catch-all --

  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  @impl true
  def terminate(_reason, _state, %__MODULE__{transport: transport, transport_mod: transport_mod}) do
    if transport_mod.open?(transport), do: transport_mod.close(transport)
    :ok
  end

  # -- Dispatch loop --

  defp dispatch_next(data), do: dispatch_next(data, 0)

  defp dispatch_next(data, errors) when errors >= @max_dispatch_errors do
    if queue_total(data) > 0 do
      Logger.warning(
        "[Link.Single] dispatch guard: rejecting #{queue_total(data)} queued submission(s) after #{@max_dispatch_errors} consecutive send failures",
        component: :bus,
        event: :dispatch_guard,
        link: data.link_name
      )
    end

    new_data = Link.flush_all(data, {:error, :transport_unavailable})
    idle_or_unhealthy(new_data)
  end

  defp dispatch_next(data, errors) do
    data = Link.expire_stale_realtime(data, data.link_name)

    case Link.next_dispatch(data) do
      {:realtime, submission, data} ->
        do_send_realtime(submission, data, errors)

      {:reliable, batch, data} ->
        do_send_reliable(batch, data, errors)

      :empty ->
        idle_or_unhealthy(data)
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
    datagram_bytes = Enum.sum(Enum.map(datagrams, &Datagram.wire_size/1))

    cond do
      datagram_bytes > Link.max_datagram_bytes() ->
        {:error, :frame_too_large, data}

      not data.transport_mod.open?(data.transport) ->
        Telemetry.link_down(data.link_name, data.link_name, :transport_closed)
        {:error, :transport_unavailable, go_unhealthy(data)}

      true ->
        do_encode_and_send(datagrams, awaiting, data, next_idx, tx_class)
    end
  end

  defp do_encode_and_send(datagrams, awaiting, data, next_idx, tx_class) do
    case Frame.encode(datagrams) do
      {:error, :frame_too_large} ->
        {:error, :frame_too_large, data}

      {:ok, payload} ->
        data.transport_mod.set_active_once(data.transport)

        case data.transport_mod.send(data.transport, payload) do
          {:ok, tx_at} ->
            Telemetry.frame_sent(
              data.link_name,
              data.link_name,
              :primary,
              byte_size(payload),
              tx_at
            )

            exchange = %{
              idx: hd(datagrams).idx,
              payload: payload,
              datagrams: datagrams,
              awaiting: awaiting,
              tx_class: tx_class,
              tx_at: tx_at,
              payload_size: byte_size(payload),
              datagram_count: length(datagrams)
            }

            {:ok, %{data | idx: next_idx, exchange: exchange},
             [{:state_timeout, data.frame_timeout_ms, :timeout}]}

          {:error, reason} ->
            new_transport = data.transport_mod.close(data.transport)
            Telemetry.link_down(data.link_name, data.link_name, reason)
            {:error, reason, go_unhealthy(%{data | transport: new_transport})}
        end
    end
  end

  # -- Receive handling --

  defp handle_rx(data, ecat_payload, rx_at) do
    case Frame.decode(ecat_payload) do
      {:ok, datagrams} ->
        if Link.all_expected_present?(data.exchange, datagrams) do
          Telemetry.frame_received(
            data.link_name,
            data.link_name,
            :primary,
            byte_size(ecat_payload),
            rx_at
          )

          complete_exchange(data, datagrams)
        else
          Telemetry.frame_dropped(data.link_name, byte_size(ecat_payload), :idx_mismatch)
          rearm(data)
          :keep_state_and_data
        end

      {:error, _reason} ->
        Telemetry.frame_dropped(data.link_name, byte_size(ecat_payload), :decode_error)
        rearm(data)
        :keep_state_and_data
    end
  end

  defp complete_exchange(data, datagrams) do
    case Link.match_and_reply(datagrams, data.exchange.awaiting) do
      :ok ->
        dispatch_next(%{data | exchange: nil, timeout_count: 0})

      :mismatch ->
        Link.reply_awaiting(data.exchange.awaiting, {:error, :mismatch})
        dispatch_next(%{data | exchange: nil})
    end
  end

  # -- Timeout handling --

  defp handle_timeout(data) do
    timeouts = data.timeout_count + 1

    if timeouts >= 3 and (timeouts == 3 or rem(timeouts, 100) == 0) do
      elapsed_ms =
        System.convert_time_unit(
          System.monotonic_time() -
            ((data.exchange && data.exchange.tx_at) || System.monotonic_time()),
          :native,
          :millisecond
        )

      n = length((data.exchange && data.exchange.awaiting) || [])

      Logger.warning(
        "[Link.Single] frame timeout after #{elapsed_ms}ms -- #{n} caller(s) lost (#{timeouts} consecutive)",
        component: :bus,
        event: :frame_timeout,
        link: data.link_name,
        elapsed_ms: elapsed_ms,
        lost_callers: n,
        consecutive_timeouts: timeouts
      )
    end

    data = drain_transport(data)
    Link.reply_awaiting((data.exchange && data.exchange.awaiting) || [], {:error, :timeout})

    dispatch_next(%{data | exchange: nil, timeout_count: timeouts})
  end

  # -- Helpers --

  defp idle_or_unhealthy(data) do
    if not data.transport_mod.open?(data.transport) do
      reply_settle_callers(data)
      {:next_state, :unhealthy, go_unhealthy(data)}
    else
      idle_after_settle(data)
    end
  end

  defp idle_after_settle(%{settle_callers: []} = data), do: {:next_state, :idle, data}

  defp idle_after_settle(%{settle_callers: callers} = data) do
    data = drain_transport(%{data | settle_callers: []})
    Link.reply_settle_callers(callers, :ok)
    {:next_state, :idle, data}
  end

  defp reply_settle_callers(%{settle_callers: []}), do: :ok

  defp reply_settle_callers(%{settle_callers: callers}) do
    Link.reply_settle_callers(callers, :ok)
  end

  defp drain_transport(data) do
    if data.transport_mod.open?(data.transport) do
      data.transport_mod.drain(data.transport)
    end

    data
  end

  defp rearm(data) do
    if data.transport_mod.open?(data.transport) do
      data.transport_mod.rearm(data.transport)
    end
  end

  defp go_unhealthy(data) do
    %{data | last_error_reason: :transport_unavailable}
  end

  defp queue_total(data), do: :queue.len(data.realtime) + :queue.len(data.reliable)

  defp render_info(state, data) do
    %{
      state: state,
      link: data.link_name,
      type: :single,
      topology: if(state == :unhealthy, do: :offline, else: :single),
      fault: if(state == :unhealthy, do: %{kind: :transport_fault}, else: nil),
      frame_timeout_ms: data.frame_timeout_ms,
      timeout_count: data.timeout_count,
      last_error_reason: data.last_error_reason,
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
      age_ms:
        System.convert_time_unit(
          System.monotonic_time() - exchange.tx_at,
          :native,
          :millisecond
        )
    }
  end

  defp resolve_transport_mod(opts) do
    opts[:transport_mod] ||
      case opts[:transport] do
        :udp -> UdpSocket
        _ -> RawSocket
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
