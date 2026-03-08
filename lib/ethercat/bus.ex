defmodule EtherCAT.Bus do
  @moduledoc """
  EtherCAT bus scheduler and frame transport coordinator.

  `EtherCAT.Bus` is the single serialization point for all EtherCAT frame I/O.
  Callers build `EtherCAT.Bus.Transaction` values and submit them as either:

  - `transaction/2` — reliable work, eligible for batching with other reliable transactions
  - `transaction/3` — realtime work with a staleness deadline; stale work is discarded

  Realtime and reliable transactions are strictly separated:
  realtime always has priority, and realtime transactions never share a frame with
  reliable transactions.
  """

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.Bus.{Datagram, Frame, InFlight, Result, Submission, Transaction}
  alias EtherCAT.Bus.Link.{Redundant, SinglePort}
  alias EtherCAT.Telemetry

  @type server :: :gen_statem.server_ref()

  @max_datagram_bytes 1_400
  @debounce_interval 200
  @call_timeout_ms 5_000

  defstruct [
    :link,
    :link_mod,
    :idx,
    :in_flight,
    frame_timeout_ms: 25,
    timeout_count: 0,
    realtime: :queue.new(),
    reliable: :queue.new()
  ]

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
    transport_mod =
      opts[:transport_mod] ||
        case opts[:transport] do
          :udp -> EtherCAT.Bus.Transport.UdpSocket
          _ -> EtherCAT.Bus.Transport.RawSocket
        end

    link_mod =
      opts[:link_mod] ||
        if(opts[:backup_interface], do: Redundant, else: SinglePort)

    opts =
      opts
      |> Keyword.put(:transport_mod, transport_mod)
      |> Keyword.put(:link_mod, link_mod)

    case opts[:name] do
      nil -> :gen_statem.start_link(__MODULE__, opts, [])
      name -> start_named(name, opts)
    end
  end

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(opts) do
    link_mod = Keyword.fetch!(opts, :link_mod)
    frame_timeout_ms = Keyword.get(opts, :frame_timeout_ms, 25)
    link_opts = Keyword.drop(opts, [:name, :link_mod])

    with {:ok, link} <- link_mod.open(link_opts) do
      subscribe_interfaces(link_mod.interfaces(link))

      {:ok, :idle,
       %__MODULE__{
         link: link,
         link_mod: link_mod,
         idx: 0,
         frame_timeout_ms: frame_timeout_ms
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @doc """
  Execute a reliable transaction.

  Reliable work may be batched with other reliable transactions when the bus is
  already busy, but an idle bus sends immediately.
  """
  @spec transaction(server(), Transaction.t()) :: {:ok, [Result.t()]} | {:error, term()}
  def transaction(bus, %Transaction{} = tx) do
    do_call(bus, {:transact, tx, nil, System.monotonic_time(:microsecond)}, tx)
  end

  @doc """
  Execute a realtime transaction with a staleness deadline in microseconds.

  Realtime work is discarded if it has become stale by the time the bus is ready
  to dispatch it. Realtime transactions are never mixed with reliable traffic.
  """
  @spec transaction(server(), Transaction.t(), pos_integer()) ::
          {:ok, [Result.t()]} | {:error, term()}
  def transaction(bus, %Transaction{} = tx, deadline_us)
      when is_integer(deadline_us) and deadline_us > 0 do
    do_call(bus, {:transact, tx, deadline_us, System.monotonic_time(:microsecond)}, tx)
  end

  @doc """
  Update the frame response timeout in milliseconds.
  """
  @spec set_frame_timeout(server(), pos_integer()) :: :ok | {:error, term()}
  def set_frame_timeout(bus, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    try do
      :gen_statem.call(bus, {:set_frame_timeout, timeout_ms}, @call_timeout_ms)
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
      :exit, reason -> {:error, reason}
    end
  end

  @impl true
  def handle_event(:enter, _old, :idle, _data), do: :keep_state_and_data

  def handle_event(:enter, _old, :awaiting, _data), do: :keep_state_and_data

  def handle_event(:enter, _old, :down, data) do
    link = data.link_mod.close(data.link)
    new_data = %{data | link: link}

    actions =
      if data.link_mod.needs_reconnect?(link),
        do: [{:state_timeout, @debounce_interval, :reconnect}],
        else: []

    {:keep_state, new_data, actions}
  end

  def handle_event(
        :info,
        {VintageNet, ["interface", ifname, "lower_up"], _old, false, _meta},
        state,
        data
      )
      when state != :down do
    case data.link_mod.carrier(data.link, ifname, false) do
      {:ok, link} ->
        {:keep_state, %{data | link: link}}

      {:down, link, reason} ->
        transition_down(%{data | link: link}, :down, reason)
    end
  end

  def handle_event(
        :info,
        {VintageNet, ["interface", ifname, "lower_up"], _old, true, _meta},
        :down,
        data
      ) do
    case data.link_mod.carrier(data.link, ifname, true) do
      {:ok, link} ->
        {:keep_state, %{data | link: link}, [{:state_timeout, @debounce_interval, :reconnect}]}

      {:down, link, _reason} ->
        {:keep_state, %{data | link: link}, [{:state_timeout, @debounce_interval, :reconnect}]}
    end
  end

  def handle_event(
        :info,
        {VintageNet, ["interface", ifname, "lower_up"], _old, true, _meta},
        state,
        data
      )
      when state in [:idle, :awaiting] do
    case data.link_mod.carrier(data.link, ifname, true) do
      {:ok, link} -> {:keep_state, %{data | link: link}}
      {:down, link, reason} -> transition_down(%{data | link: link}, :down, reason)
    end
  end

  def handle_event(:info, {VintageNet, _, _, _, _}, _state, _data) do
    :keep_state_and_data
  end

  def handle_event({:call, from}, {:transact, tx, deadline_us, enqueued_at_us}, :down, _data) do
    submission = %Submission{
      from: from,
      tx: tx,
      deadline_us: deadline_us,
      enqueued_at_us: enqueued_at_us
    }

    reply_submissions([submission], {:error, :down})
    :keep_state_and_data
  end

  def handle_event({:call, from}, {:transact, tx, deadline_us, enqueued_at_us}, state, data)
      when state in [:idle, :awaiting] do
    submission = %Submission{
      from: from,
      tx: tx,
      deadline_us: deadline_us,
      enqueued_at_us: enqueued_at_us
    }

    new_data = enqueue_submission(data, submission)
    class = submission_class(submission)
    Telemetry.submission_enqueued(link_name(data), class, state, queue_depth(new_data, class))

    case state do
      :idle -> dispatch_next(new_data)
      :awaiting -> {:keep_state, new_data}
    end
  end

  def handle_event({:call, from}, {:set_frame_timeout, timeout_ms}, _state, data)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    {:keep_state, %{data | frame_timeout_ms: timeout_ms}, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, {:set_frame_timeout, _timeout_ms}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :invalid_timeout}}]}
  end

  def handle_event(:info, msg, :awaiting, data) do
    case data.link_mod.match(data.link, msg) do
      {:ok, link, ecat_payload, _rx_at} ->
        handle_response(ecat_payload, %{data | link: link})

      {:pending, link} ->
        {:keep_state, %{data | link: link}}

      {:ignore, link} ->
        {:keep_state, %{data | link: link}}
    end
  end

  def handle_event(:state_timeout, :timeout, :awaiting, data) do
    case data.link_mod.timeout(data.link) do
      {:ok, link, ecat_payload, _rx_at} ->
        handle_timeout_response(ecat_payload, %{data | link: link})

      {:error, link, :timeout} ->
        timeouts = data.timeout_count + 1

        if timeouts >= 3 and (timeouts == 3 or rem(timeouts, 100) == 0) do
          elapsed_ms =
            System.convert_time_unit(
              System.monotonic_time() - in_flight_tx_at(data.in_flight),
              :native,
              :millisecond
            )

          n = length(awaiting_from_in_flight(data.in_flight))

          Logger.warning(
            "[Bus] frame timeout after #{elapsed_ms}ms -- #{n} caller(s) lost (#{timeouts} consecutive, transport=#{link_name(data)})"
          )
        end

        drained = data.link_mod.drain(link)
        reply_in_flight(data.in_flight, {:error, :timeout})
        dispatch_next(%{data | link: drained, in_flight: nil, timeout_count: timeouts})
    end
  end

  def handle_event(:state_timeout, :reconnect, :down, data) do
    link = data.link_mod.reconnect(data.link)

    if data.link_mod.usable?(link) do
      dispatch_next(%{data | link: link})
    else
      {:keep_state, %{data | link: link}, [{:state_timeout, @debounce_interval, :reconnect}]}
    end
  end

  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  defp do_call(bus, msg, tx) do
    meta = %{datagram_count: tx |> Transaction.datagrams() |> length(), class: call_class(msg)}

    Telemetry.span([:ethercat, :bus, :transact], meta, fn ->
      result =
        try do
          :gen_statem.call(bus, msg, @call_timeout_ms)
        catch
          :exit, {:timeout, _} -> {:error, :timeout}
          :exit, reason -> {:error, reason}
        end

      case result do
        {:ok, response_datagrams} ->
          results = Enum.map(response_datagrams, &result_from_datagram/1)

          stop_meta = %{
            datagram_count: length(results),
            total_wkc: Enum.sum(Enum.map(results, & &1.wkc)),
            class: call_class(msg)
          }

          {{:ok, results}, stop_meta}

        {:error, _} = err ->
          {err, meta}
      end
    end)
  end

  defp result_from_datagram(dg) do
    %Result{
      data: dg.data,
      wkc: dg.wkc,
      circular: dg.circular,
      irq: <<dg.irq::little-unsigned-16>>
    }
  end

  defp enqueue_submission(
         %{realtime: realtime} = data,
         %Submission{deadline_us: deadline_us} = submission
       )
       when is_integer(deadline_us) do
    %{data | realtime: :queue.in(submission, realtime)}
  end

  defp enqueue_submission(%{reliable: reliable} = data, %Submission{} = submission) do
    %{data | reliable: :queue.in(submission, reliable)}
  end

  defp dispatch_next(data) do
    data = expire_stale_realtime(data)

    case :queue.out(data.realtime) do
      {{:value, submission}, realtime} ->
        do_send_realtime(submission, %{data | realtime: realtime})

      {:empty, _} ->
        dispatch_reliable(data)
    end
  end

  defp expire_stale_realtime(data) do
    now_us = System.monotonic_time(:microsecond)
    link = link_name(data)

    {keep, _discarded} =
      data.realtime
      |> :queue.to_list()
      |> Enum.reduce({[], 0}, fn %Submission{} = submission, {acc, discarded} ->
        if stale?(submission, now_us) do
          Telemetry.submission_expired(link, :realtime, submission_age_us(submission, now_us))
          :gen_statem.reply(submission.from, {:error, :expired})
          {acc, discarded + 1}
        else
          {[submission | acc], discarded}
        end
      end)

    %{data | realtime: keep |> Enum.reverse() |> :queue.from_list()}
  end

  defp stale?(%Submission{deadline_us: deadline_us, enqueued_at_us: enqueued_at_us}, now_us)
       when is_integer(deadline_us) do
    now_us - enqueued_at_us > deadline_us
  end

  defp dispatch_reliable(%{reliable: reliable} = data) do
    case :queue.is_empty(reliable) do
      true ->
        {:next_state, :idle, data}

      false ->
        {batch, rest} = take_reliable_batch(reliable)
        send_reliable_batch(batch, %{data | reliable: rest})
    end
  end

  defp take_reliable_batch(reliable) do
    {batch_rev, _} =
      Enum.reduce_while(:queue.to_list(reliable), {[], 0}, fn %Submission{} = submission,
                                                              {acc, size} ->
        tx_size =
          submission.tx
          |> Transaction.datagrams()
          |> Enum.map(&Datagram.wire_size/1)
          |> Enum.sum()

        new_size = size + tx_size

        if acc == [] or new_size <= @max_datagram_bytes do
          {:cont, {[submission | acc], new_size}}
        else
          {:halt, {acc, size}}
        end
      end)

    batch = Enum.reverse(batch_rev)
    rest = reliable |> :queue.to_list() |> Enum.drop(length(batch)) |> :queue.from_list()
    {batch, rest}
  end

  defp do_send_realtime(%Submission{} = submission, data) do
    {stamped, next_idx} = stamp_indices(Transaction.datagrams(submission.tx), data.idx)
    awaiting = [{submission.from, Enum.map(stamped, & &1.idx)}]
    datagram_count = length(stamped)

    case send_frame(stamped, awaiting, data, next_idx) do
      {:ok, state, new_data, actions} ->
        Telemetry.dispatch_sent(link_name(data), :realtime, 1, datagram_count)
        {:next_state, state, new_data, actions}

      {:error, :frame_too_large, new_data} ->
        :gen_statem.reply(submission.from, {:error, :frame_too_large})
        dispatch_next(new_data)

      {:error, reason, new_data} ->
        transition_down(new_data, :down, reason, [submission])
    end
  end

  defp send_reliable_batch(batch, data) do
    {stamped_batch, next_idx} =
      Enum.map_reduce(batch, data.idx, fn %Submission{tx: tx}, idx ->
        stamp_indices(Transaction.datagrams(tx), idx)
      end)

    awaiting =
      Enum.zip(batch, stamped_batch)
      |> Enum.map(fn {%Submission{from: from}, stamped} ->
        {from, Enum.map(stamped, & &1.idx)}
      end)

    all_datagrams = Enum.flat_map(stamped_batch, & &1)
    datagram_count = length(all_datagrams)

    case send_frame(all_datagrams, awaiting, data, next_idx) do
      {:ok, state, new_data, actions} ->
        Telemetry.dispatch_sent(link_name(data), :reliable, length(batch), datagram_count)
        {:next_state, state, new_data, actions}

      {:error, :frame_too_large, new_data} ->
        reply_submissions(batch, {:error, :frame_too_large})
        dispatch_next(new_data)

      {:error, reason, new_data} ->
        transition_down(new_data, :down, reason, batch)
    end
  end

  defp send_frame(datagrams, awaiting, data, next_idx) do
    datagram_bytes = Enum.sum(Enum.map(datagrams, &Datagram.wire_size/1))

    cond do
      datagram_bytes > @max_datagram_bytes ->
        {:error, :frame_too_large, data}

      true ->
        case Frame.encode(datagrams) do
          {:error, :frame_too_large} ->
            {:error, :frame_too_large, data}

          {:ok, payload} ->
            case data.link_mod.send(data.link, payload) do
              {:ok, link} ->
                in_flight = %InFlight{
                  awaiting: awaiting,
                  tx_at: System.monotonic_time(),
                  payload_size: byte_size(payload),
                  datagram_count: length(datagrams)
                }

                {:ok, :awaiting, %{data | idx: next_idx, in_flight: in_flight, link: link},
                 [{:state_timeout, data.frame_timeout_ms, :timeout}]}

              {:error, link, :emsgsize} ->
                {:error, :frame_too_large, %{data | link: link}}

              {:error, link, :frame_too_large} ->
                {:error, :frame_too_large, %{data | link: link}}

              {:error, link, reason} ->
                {:error, reason, %{data | link: link}}
            end
        end
    end
  end

  defp handle_response(ecat_payload, data) do
    case Frame.decode(ecat_payload) do
      {:ok, datagrams} ->
        case match_and_reply(datagrams, awaiting_from_in_flight(data.in_flight)) do
          :ok ->
            dispatch_next(%{
              data
              | in_flight: nil,
                timeout_count: 0,
                link: data.link_mod.clear_awaiting(data.link)
            })

          :mismatch ->
            Telemetry.frame_dropped(link_name(data), byte_size(ecat_payload), :idx_mismatch)
            {:keep_state, %{data | link: data.link_mod.rearm(data.link)}}
        end

      {:error, _} ->
        Telemetry.frame_dropped(link_name(data), byte_size(ecat_payload), :decode_error)
        {:keep_state, %{data | link: data.link_mod.rearm(data.link)}}
    end
  end

  defp handle_timeout_response(ecat_payload, data) do
    case Frame.decode(ecat_payload) do
      {:ok, datagrams} ->
        case match_and_reply(datagrams, awaiting_from_in_flight(data.in_flight)) do
          :ok ->
            dispatch_next(%{
              data
              | in_flight: nil,
                link: data.link_mod.clear_awaiting(data.link)
            })

          :mismatch ->
            Telemetry.frame_dropped(link_name(data), byte_size(ecat_payload), :idx_mismatch)
            reply_in_flight(data.in_flight, {:error, :timeout})

            dispatch_next(%{
              data
              | in_flight: nil,
                link: data.link_mod.clear_awaiting(data.link)
            })
        end

      {:error, _} ->
        Telemetry.frame_dropped(link_name(data), byte_size(ecat_payload), :decode_error)
        reply_in_flight(data.in_flight, {:error, :timeout})

        dispatch_next(%{
          data
          | in_flight: nil,
            link: data.link_mod.clear_awaiting(data.link)
        })
    end
  end

  defp match_and_reply(response_datagrams, awaiting) do
    idx_map = Map.new(response_datagrams, &{&1.idx, &1})

    all_present =
      Enum.all?(awaiting, fn {_from, idxs} ->
        Enum.all?(idxs, &Map.has_key?(idx_map, &1))
      end)

    if all_present do
      Enum.each(awaiting, fn {from, idxs} ->
        :gen_statem.reply(from, {:ok, Enum.map(idxs, &Map.fetch!(idx_map, &1))})
      end)

      :ok
    else
      :mismatch
    end
  end

  defp transition_down(data, state, _reason, extra_submissions \\ []) do
    reply_in_flight(data.in_flight, {:error, :down})
    reply_submissions(extra_submissions, {:error, :down})
    reply_queue(data.realtime, {:error, :down})
    reply_queue(data.reliable, {:error, :down})

    {:next_state, state,
     %{
       data
       | in_flight: nil,
         link: data.link_mod.clear_awaiting(data.link),
         realtime: :queue.new(),
         reliable: :queue.new()
     }}
  end

  defp reply_in_flight(nil, _reply), do: :ok

  defp reply_in_flight(%InFlight{awaiting: awaiting}, reply) do
    Enum.each(awaiting, fn {from, _idxs} -> :gen_statem.reply(from, reply) end)
  end

  defp reply_submissions(submissions, reply) do
    Enum.each(submissions, fn %Submission{from: from} -> :gen_statem.reply(from, reply) end)
  end

  defp reply_queue(queue, reply) do
    queue
    |> :queue.to_list()
    |> reply_submissions(reply)
  end

  defp stamp_indices(datagrams, start_idx) do
    Enum.map_reduce(datagrams, start_idx, fn dg, idx ->
      <<byte_idx>> = <<idx::8>>
      {%{dg | idx: byte_idx}, idx + 1}
    end)
  end

  defp in_flight_tx_at(nil), do: 0
  defp in_flight_tx_at(%InFlight{tx_at: tx_at}), do: tx_at

  defp awaiting_from_in_flight(nil), do: []
  defp awaiting_from_in_flight(%InFlight{awaiting: awaiting}), do: awaiting

  defp submission_class(%Submission{deadline_us: nil}), do: :reliable
  defp submission_class(%Submission{}), do: :realtime

  defp call_class({:transact, _tx, nil, _enqueued_at_us}), do: :reliable
  defp call_class({:transact, _tx, _deadline_us, _enqueued_at_us}), do: :realtime

  defp queue_depth(data, :realtime), do: :queue.len(data.realtime)
  defp queue_depth(data, :reliable), do: :queue.len(data.reliable)

  defp submission_age_us(%Submission{enqueued_at_us: enqueued_at_us}, now_us),
    do: now_us - enqueued_at_us

  defp subscribe_interfaces(interfaces) do
    interfaces
    |> Enum.uniq()
    |> Enum.each(&VintageNet.subscribe(["interface", &1, "lower_up"]))
  end

  defp link_name(%{link: link, link_mod: link_mod}), do: link_mod.name(link)

  defp start_named({:local, _name} = name, opts),
    do: :gen_statem.start_link(name, __MODULE__, opts, [])

  defp start_named({:global, _name} = name, opts),
    do: :gen_statem.start_link(name, __MODULE__, opts, [])

  defp start_named({:via, _mod, _name} = name, opts),
    do: :gen_statem.start_link(name, __MODULE__, opts, [])

  defp start_named(name, opts) when is_atom(name),
    do: :gen_statem.start_link({:local, name}, __MODULE__, opts, [])
end
