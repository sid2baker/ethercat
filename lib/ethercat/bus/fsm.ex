defmodule EtherCAT.Bus.FSM do
  @moduledoc false

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.Bus.{
    Assessment,
    Datagram,
    Frame,
    Observation,
    Transaction
  }

  alias EtherCAT.Bus.Circuit.{Exchange, Redundant, Single}
  alias EtherCAT.Bus.Transport.{RawSocket, UdpSocket}
  alias EtherCAT.Telemetry

  @max_datagram_bytes 1_400

  defmodule Submission do
    @moduledoc false

    alias EtherCAT.Bus.Transaction

    @type t :: %__MODULE__{
            from: :gen_statem.from(),
            tx: Transaction.t(),
            stale_after_us: pos_integer() | nil,
            enqueued_at_us: integer()
          }

    defstruct [:from, :tx, :stale_after_us, :enqueued_at_us]
  end

  defmodule RuntimeInfo do
    @moduledoc false

    alias EtherCAT.Bus.{Assessment, Observation}
    alias EtherCAT.Bus.Circuit.Exchange

    @spec render(atom(), map()) :: map()
    def render(state, data) do
      %{
        state: state,
        circuit: data.circuit_mod.name(data.circuit),
        topology: data.assessment.topology,
        fault: data.assessment.fault,
        assessment: assessment_info(data.assessment),
        last_observation: observation_info(data.last_observation),
        circuit_info: data.circuit_mod.info(data.circuit),
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

    defp assessment_info(%Assessment{} = assessment) do
      %{
        observed_at: assessment.observed_at,
        based_on: assessment.based_on,
        last_path_shape: assessment.last_path_shape,
        last_status: assessment.last_status,
        consecutive_redundant: assessment.consecutive_redundant
      }
    end

    defp observation_info(nil), do: nil

    defp observation_info(%Observation{} = observation) do
      %{
        status: observation.status,
        path_shape: observation.path_shape,
        completed_at: observation.completed_at,
        primary: port_observation_info(observation.primary),
        secondary: port_observation_info(observation.secondary)
      }
    end

    defp port_observation_info(port_observation) do
      %{
        sent?: port_observation.sent?,
        send_result: port_observation.send_result,
        rx_kind: port_observation.rx_kind,
        rx_at: port_observation.rx_at
      }
    end

    defp exchange_info(nil), do: nil

    defp exchange_info(%Exchange{} = exchange) do
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
  end

  @enforce_keys [:circuit, :circuit_mod, :idx]
  defstruct [
    :circuit,
    :circuit_mod,
    :idx,
    :exchange,
    :assessment,
    :last_observation,
    last_error_reason: nil,
    settle_callers: [],
    frame_timeout_ms: 25,
    timeout_count: 0,
    realtime: :queue.new(),
    reliable: :queue.new()
  ]

  @opaque t :: %__MODULE__{
            circuit: term(),
            circuit_mod: module(),
            idx: non_neg_integer(),
            exchange: Exchange.t() | nil,
            assessment: Assessment.t(),
            last_observation: Observation.t() | nil,
            last_error_reason: term() | nil,
            settle_callers: [term()],
            frame_timeout_ms: pos_integer(),
            timeout_count: non_neg_integer(),
            realtime: term(),
            reliable: term()
          }

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5000
    }
  end

  @doc false
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    opts = normalize_start_opts(opts)

    case opts[:name] do
      nil -> :gen_statem.start_link(__MODULE__, opts, [])
      name -> start_named(name, opts)
    end
  end

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(opts) do
    circuit_mod = Keyword.fetch!(opts, :circuit_mod)
    frame_timeout_ms = Keyword.get(opts, :frame_timeout_ms, 25)
    circuit_opts = Keyword.drop(opts, [:name, :circuit_mod])

    with {:ok, circuit} <- circuit_mod.open(circuit_opts) do
      Logger.metadata(component: :bus, circuit: circuit_name(circuit_mod, circuit))

      {:ok, :idle,
       %__MODULE__{
         circuit: circuit,
         circuit_mod: circuit_mod,
         idx: 0,
         assessment: Assessment.new(),
         last_observation: nil,
         frame_timeout_ms: frame_timeout_ms
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_event(:enter, _old, :idle, _data), do: :keep_state_and_data

  def handle_event(:enter, _old, :awaiting, _data), do: :keep_state_and_data

  def handle_event({:call, from}, {:transact, tx, stale_after_us, enqueued_at_us}, state, data)
      when state in [:idle, :awaiting] do
    submission = %Submission{
      from: from,
      tx: tx,
      stale_after_us: stale_after_us,
      enqueued_at_us: enqueued_at_us
    }

    new_data = enqueue_submission(data, submission)
    class = submission_class(submission)
    Telemetry.submission_enqueued(circuit_name(data), class, state, queue_depth(new_data, class))

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

  def handle_event({:call, from}, :settle, :idle, data) do
    {:keep_state, settle_idle(data), [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :settle, :awaiting, data) do
    {:keep_state, %{data | settle_callers: [from | data.settle_callers]}}
  end

  def handle_event({:call, from}, :info, state, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, RuntimeInfo.render(state, data)}}]}
  end

  def handle_event(:info, msg, :awaiting, data) do
    case data.circuit_mod.observe(data.circuit, msg, data.exchange) do
      {:complete, circuit, %Observation{} = observation} ->
        handle_observation(observation, put_circuit(data, circuit))

      {tag, circuit, exchange} when tag in [:continue, :ignore] ->
        {:keep_state, %{put_circuit(data, circuit) | exchange: exchange}}
    end
  end

  def handle_event(:state_timeout, :timeout, :awaiting, data) do
    case data.circuit_mod.timeout(data.circuit, data.exchange) do
      {:continue, circuit, exchange, timeout_ms} ->
        {:keep_state, %{put_circuit(data, circuit) | exchange: exchange},
         [{:state_timeout, timeout_ms, :timeout}]}

      {:complete, circuit, %Observation{} = observation} ->
        data = put_circuit(data, circuit)

        case observation.status do
          :timeout -> handle_timeout_observation(observation, data)
          _other -> handle_observation(observation, data)
        end
    end
  end

  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  @impl true
  def terminate(_reason, _state, %{circuit: circuit, circuit_mod: circuit_mod}) do
    _ = circuit_mod.close(circuit)
    :ok
  end

  defp enqueue_submission(
         %{realtime: realtime} = data,
         %Submission{stale_after_us: stale_after_us} = submission
       )
       when is_integer(stale_after_us) do
    %{data | realtime: :queue.in(submission, realtime)}
  end

  defp enqueue_submission(%{reliable: reliable} = data, %Submission{} = submission) do
    %{data | reliable: :queue.in(submission, reliable)}
  end

  @max_dispatch_errors 3

  defp dispatch_next(data), do: dispatch_next(data, 0)

  defp dispatch_next(data, errors) when errors >= @max_dispatch_errors do
    flush_all_queued(data, {:error, :transport_unavailable})
  end

  defp dispatch_next(data, errors) do
    data = expire_stale_realtime(data)

    case :queue.out(data.realtime) do
      {{:value, submission}, realtime} ->
        do_send_realtime(submission, %{data | realtime: realtime}, errors)

      {:empty, _} ->
        dispatch_reliable(data, errors)
    end
  end

  defp flush_all_queued(data, reply) do
    link = circuit_name(data)

    realtime_list = :queue.to_list(data.realtime)
    reliable_list = :queue.to_list(data.reliable)
    total = length(realtime_list) + length(reliable_list)

    if total > 0 do
      Logger.warning(
        "[Bus] dispatch guard: rejecting #{total} queued submission(s) after #{@max_dispatch_errors} consecutive send failures (transport=#{link})",
        component: :bus,
        event: :dispatch_guard,
        circuit: link,
        rejected_count: total
      )
    end

    reply_submissions(realtime_list, reply)
    reply_submissions(reliable_list, reply)

    idle_after_settle(%{data | realtime: :queue.new(), reliable: :queue.new()})
  end

  defp expire_stale_realtime(data) do
    now_us = System.monotonic_time(:microsecond)
    link = circuit_name(data)

    keep =
      data.realtime
      |> :queue.to_list()
      |> Enum.reduce([], fn %Submission{} = submission, acc ->
        if stale?(submission, now_us) do
          Telemetry.submission_expired(link, :realtime, submission_age_us(submission, now_us))
          :gen_statem.reply(submission.from, {:error, :expired})
          acc
        else
          [submission | acc]
        end
      end)

    %{data | realtime: keep |> Enum.reverse() |> :queue.from_list()}
  end

  defp stale?(%Submission{stale_after_us: stale_after_us, enqueued_at_us: enqueued_at_us}, now_us)
       when is_integer(stale_after_us) do
    now_us - enqueued_at_us > stale_after_us
  end

  defp dispatch_reliable(%{reliable: reliable} = data, errors) do
    case :queue.is_empty(reliable) do
      true ->
        idle_after_settle(data)

      false ->
        {batch, rest} = take_reliable_batch(reliable)
        send_reliable_batch(batch, %{data | reliable: rest}, errors)
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

  defp do_send_realtime(%Submission{} = submission, data, errors) do
    {stamped, next_idx} = stamp_indices(Transaction.datagrams(submission.tx), data.idx)
    awaiting = [{submission.from, Enum.map(stamped, & &1.idx)}]
    datagram_count = length(stamped)

    case send_frame(stamped, awaiting, data, next_idx, :realtime) do
      {:ok, state, new_data, actions} ->
        Telemetry.dispatch_sent(circuit_name(data), :realtime, 1, datagram_count)
        {:next_state, state, new_data, actions}

      {:error, :frame_too_large, new_data} ->
        :gen_statem.reply(submission.from, {:error, :frame_too_large})
        dispatch_next(new_data, errors)

      {:error, reason, new_data} ->
        reply_submissions([submission], {:error, reason})
        dispatch_next(new_data, errors + 1)
    end
  end

  defp send_reliable_batch(batch, data, errors) do
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

    case send_frame(all_datagrams, awaiting, data, next_idx, :reliable) do
      {:ok, state, new_data, actions} ->
        Telemetry.dispatch_sent(circuit_name(data), :reliable, length(batch), datagram_count)
        {:next_state, state, new_data, actions}

      {:error, :frame_too_large, new_data} ->
        reply_submissions(batch, {:error, :frame_too_large})
        dispatch_next(new_data, errors)

      {:error, reason, new_data} ->
        reply_submissions(batch, {:error, reason})
        dispatch_next(new_data, errors + 1)
    end
  end

  defp send_frame(datagrams, awaiting, data, next_idx, tx_class) do
    datagram_bytes = Enum.sum(Enum.map(datagrams, &Datagram.wire_size/1))

    cond do
      datagram_bytes > @max_datagram_bytes ->
        {:error, :frame_too_large, data}

      true ->
        case Frame.encode(datagrams) do
          {:error, :frame_too_large} ->
            {:error, :frame_too_large, data}

          {:ok, payload} ->
            exchange =
              Exchange.new(
                hd(datagrams).idx,
                payload,
                datagrams,
                awaiting,
                tx_class,
                System.monotonic_time()
              )

            case data.circuit_mod.begin_exchange(data.circuit, exchange) do
              {:ok, circuit, exchange} ->
                {:ok, :awaiting,
                 %{
                   data
                   | idx: next_idx,
                     exchange: exchange,
                     circuit: circuit
                 }, [{:state_timeout, data.frame_timeout_ms, :timeout}]}

              {:error, circuit, %Observation{} = observation, :emsgsize} ->
                {:error, :frame_too_large,
                 record_observation(%{data | circuit: circuit}, observation, :emsgsize)}

              {:error, circuit, %Observation{} = observation, :frame_too_large} ->
                {:error, :frame_too_large,
                 record_observation(%{data | circuit: circuit}, observation, :frame_too_large)}

              {:error, circuit, %Observation{} = observation, reason} ->
                {:error, reason,
                 record_observation(%{data | circuit: circuit}, observation, reason)}
            end
        end
    end
  end

  defp handle_observation(%Observation{status: :ok, datagrams: datagrams} = observation, data)
       when is_list(datagrams) do
    data = record_observation(data, observation)

    case match_and_reply(datagrams, exchange_awaiting(data.exchange)) do
      :ok ->
        dispatch_next(%{
          data
          | exchange: nil,
            timeout_count: 0
        })

      :mismatch ->
        reply_exchange(data.exchange, {:error, :mismatch})

        dispatch_next(%{
          data
          | exchange: nil
        })
    end
  end

  defp handle_observation(%Observation{status: :timeout} = observation, data) do
    handle_timeout_observation(observation, data)
  end

  defp handle_observation(%Observation{} = observation, data) do
    data = record_observation(data, observation)
    drained = data.circuit_mod.drain(data.circuit)
    reply_exchange(data.exchange, {:error, observation.status})

    dispatch_next(
      put_circuit(
        %{
          data
          | exchange: nil
        },
        drained
      )
    )
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

  defp reply_exchange(nil, _reply), do: :ok

  defp reply_exchange(%Exchange{awaiting: awaiting}, reply) do
    Enum.each(awaiting, fn {from, _idxs} -> :gen_statem.reply(from, reply) end)
  end

  defp reply_submissions(submissions, reply) do
    Enum.each(submissions, fn %Submission{from: from} -> :gen_statem.reply(from, reply) end)
  end

  defp reply_settle_callers(callers, reply) do
    Enum.each(callers, &:gen_statem.reply(&1, reply))
  end

  defp idle_after_settle(%{settle_callers: []} = data), do: {:next_state, :idle, data}

  defp idle_after_settle(%{settle_callers: callers} = data) do
    data = settle_idle(data)
    reply_settle_callers(callers, :ok)
    {:next_state, :idle, data}
  end

  defp settle_idle(data) do
    %{data | circuit: data.circuit_mod.drain(data.circuit), settle_callers: []}
  end

  defp stamp_indices(datagrams, start_idx) do
    Enum.map_reduce(datagrams, start_idx, fn dg, idx ->
      <<byte_idx>> = <<idx::8>>
      {%{dg | idx: byte_idx}, idx + 1}
    end)
  end

  defp exchange_tx_at(nil), do: System.monotonic_time()
  defp exchange_tx_at(%Exchange{tx_at: tx_at}), do: tx_at

  defp exchange_awaiting(nil), do: []
  defp exchange_awaiting(%Exchange{awaiting: awaiting}), do: awaiting

  defp submission_class(%Submission{stale_after_us: nil}), do: :reliable
  defp submission_class(%Submission{}), do: :realtime

  defp queue_depth(data, :realtime), do: :queue.len(data.realtime)
  defp queue_depth(data, :reliable), do: :queue.len(data.reliable)

  defp submission_age_us(%Submission{enqueued_at_us: enqueued_at_us}, now_us),
    do: now_us - enqueued_at_us

  defp circuit_name(%{circuit: circuit, circuit_mod: circuit_mod}), do: circuit_mod.name(circuit)
  defp circuit_name(circuit_mod, circuit), do: circuit_mod.name(circuit)

  defp put_circuit(data, circuit), do: %{data | circuit: circuit}

  defp record_observation(%{assessment: %Assessment{}} = data, %Observation{} = observation) do
    record_observation(data, observation, nil)
  end

  defp record_observation(
         %{assessment: %Assessment{} = assessment} = data,
         %Observation{} = observation,
         error_reason
       ) do
    {new_assessment, change} = Assessment.advance(assessment, observation)

    case change do
      {:changed, from, to} ->
        Telemetry.bus_topology_changed(circuit_name(data), from, to, observation)

      :unchanged ->
        :ok
    end

    %{
      data
      | assessment: new_assessment,
        last_observation: observation,
        last_error_reason: if(observation.status == :transport_error, do: error_reason, else: nil)
    }
  end

  defp handle_timeout_observation(%Observation{status: :timeout} = observation, data) do
    data = record_observation(data, observation)

    timeouts = data.timeout_count + 1

    if timeouts >= 3 and (timeouts == 3 or rem(timeouts, 100) == 0) do
      elapsed_ms =
        System.convert_time_unit(
          System.monotonic_time() - exchange_tx_at(data.exchange),
          :native,
          :millisecond
        )

      n = length(exchange_awaiting(data.exchange))

      Logger.warning(
        "[Bus] frame timeout after #{elapsed_ms}ms -- #{n} caller(s) lost (#{timeouts} consecutive, transport=#{circuit_name(data)})",
        component: :bus,
        event: :frame_timeout,
        circuit: circuit_name(data),
        elapsed_ms: elapsed_ms,
        lost_callers: n,
        consecutive_timeouts: timeouts
      )
    end

    drained = data.circuit_mod.drain(data.circuit)
    reply_exchange(data.exchange, {:error, :timeout})

    dispatch_next(
      put_circuit(
        %{data | exchange: nil, timeout_count: timeouts},
        drained
      )
    )
  end

  defp handle_timeout_observation(%Observation{} = observation, data) do
    data = record_observation(data, observation)
    drained = data.circuit_mod.drain(data.circuit)
    reply_exchange(data.exchange, {:error, observation.status})

    dispatch_next(
      put_circuit(
        %{
          data
          | exchange: nil
        },
        drained
      )
    )
  end

  defp start_named({:local, _name} = name, opts),
    do: :gen_statem.start_link(name, __MODULE__, opts, [])

  defp start_named({:global, _name} = name, opts),
    do: :gen_statem.start_link(name, __MODULE__, opts, [])

  defp start_named({:via, _mod, _name} = name, opts),
    do: :gen_statem.start_link(name, __MODULE__, opts, [])

  defp start_named(name, opts) when is_atom(name),
    do: :gen_statem.start_link({:local, name}, __MODULE__, opts, [])

  defp normalize_start_opts(opts) do
    transport_mod =
      opts[:transport_mod] ||
        case opts[:transport] do
          :udp -> UdpSocket
          _ -> RawSocket
        end

    circuit_mod =
      opts[:circuit_mod] ||
        if(opts[:backup_interface], do: Redundant, else: Single)

    opts
    |> Keyword.put(:transport_mod, transport_mod)
    |> Keyword.put(:circuit_mod, circuit_mod)
  end
end
