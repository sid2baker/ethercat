defmodule EtherCAT.Bus.Link do
  @moduledoc """
  Shared scheduling helpers for bus link gen_statem implementations.

  Both `Link.Single` and `Link.Redundant` store `:realtime` and `:reliable`
  queues in their gen_statem data and call these pure functions for queue
  management, batching, index stamping, and caller replies.

  This module is **not** a behaviour or process — just shared helpers.
  """

  alias EtherCAT.Bus.{Datagram, Transaction}
  alias EtherCAT.Telemetry

  @max_datagram_bytes 1_400

  defmodule Submission do
    @moduledoc """
    Internal queue item used by `EtherCAT.Bus.Link` scheduling helpers.

    This struct is shared between the single-link and redundant-link
    implementations. It is documented so generated docs can resolve public
    specs in `EtherCAT.Bus.Link`, but it is not intended as a user-facing API.
    """

    @type t :: %__MODULE__{
            from: :gen_statem.from(),
            tx: Transaction.t(),
            stale_after_us: pos_integer() | nil,
            enqueued_at_us: integer()
          }

    defstruct [:from, :tx, :stale_after_us, :enqueued_at_us]
  end

  # -- Queue management --

  @doc """
  Enqueue a submission into the appropriate queue based on its staleness budget.

  Realtime submissions (those with a `stale_after_us`) go into the realtime
  queue. All others go into the reliable queue.
  """
  @spec enqueue(map(), Submission.t()) :: map()
  def enqueue(data, %Submission{stale_after_us: stale_after_us} = submission)
      when is_integer(stale_after_us) do
    %{data | realtime: :queue.in(submission, data.realtime)}
  end

  def enqueue(data, %Submission{} = submission) do
    %{data | reliable: :queue.in(submission, data.reliable)}
  end

  @doc """
  Expire stale realtime submissions, replying `{:error, :expired}` to each.

  Returns the updated data with expired submissions removed from the queue.
  """
  @spec expire_stale_realtime(map(), String.t()) :: map()
  def expire_stale_realtime(data, link_name) do
    now_us = System.monotonic_time(:microsecond)

    keep =
      data.realtime
      |> :queue.to_list()
      |> Enum.reduce([], fn %Submission{} = submission, acc ->
        if stale?(submission, now_us) do
          Telemetry.submission_expired(
            link_name,
            :realtime,
            submission_age_us(submission, now_us)
          )

          :gen_statem.reply(submission.from, {:error, :expired})
          acc
        else
          [submission | acc]
        end
      end)

    %{data | realtime: keep |> Enum.reverse() |> :queue.from_list()}
  end

  @doc """
  Take the next dispatch unit from the queues.

  Realtime submissions have priority and are dispatched one at a time.
  Reliable submissions are batched into a single frame up to 1400 bytes.

  Returns:
  - `{:realtime, submission, updated_data}` — one realtime submission
  - `{:reliable, batch, updated_data}` — list of reliable submissions
  - `:empty` — nothing to dispatch
  """
  @spec next_dispatch(map()) ::
          {:realtime, Submission.t(), map()} | {:reliable, [Submission.t()], map()} | :empty
  def next_dispatch(data) do
    case :queue.out(data.realtime) do
      {{:value, submission}, realtime} ->
        {:realtime, submission, %{data | realtime: realtime}}

      {:empty, _} ->
        case :queue.is_empty(data.reliable) do
          true ->
            :empty

          false ->
            {batch, rest} = take_reliable_batch(data.reliable)
            {:reliable, batch, %{data | reliable: rest}}
        end
    end
  end

  @doc """
  Flush all queued submissions, replying with the given error to each caller.

  Returns the updated data with empty queues.
  """
  @spec flush_all(map(), term()) :: map()
  def flush_all(data, reply) do
    realtime_list = :queue.to_list(data.realtime)
    reliable_list = :queue.to_list(data.reliable)
    reply_submissions(realtime_list, reply)
    reply_submissions(reliable_list, reply)
    %{data | realtime: :queue.new(), reliable: :queue.new()}
  end

  # -- Frame building --

  @doc """
  Stamp datagrams with sequential byte-wrapping indices.
  """
  @spec stamp_indices([Datagram.t()], non_neg_integer()) :: {[Datagram.t()], non_neg_integer()}
  def stamp_indices(datagrams, start_idx) do
    Enum.map_reduce(datagrams, start_idx, fn dg, idx ->
      <<byte_idx>> = <<idx::8>>
      {%{dg | idx: byte_idx}, idx + 1}
    end)
  end

  @doc """
  Build the awaiting list and stamped datagrams for a realtime submission.
  """
  @spec prepare_realtime(Submission.t(), non_neg_integer()) ::
          {[Datagram.t()], [{:gen_statem.from(), [byte()]}], non_neg_integer()}
  def prepare_realtime(%Submission{} = submission, idx) do
    {stamped, next_idx} = stamp_indices(Transaction.datagrams(submission.tx), idx)
    awaiting = [{submission.from, Enum.map(stamped, & &1.idx)}]
    {stamped, awaiting, next_idx}
  end

  @doc false
  @spec prepare_realtime_dispatch(Submission.t(), non_neg_integer()) ::
          {[Datagram.t()], [{:gen_statem.from(), [byte()]}], non_neg_integer(), non_neg_integer()}
  def prepare_realtime_dispatch(%Submission{} = submission, idx) do
    {datagrams, awaiting, next_idx} = prepare_realtime(submission, idx)
    {datagrams, awaiting, next_idx, length(datagrams)}
  end

  @doc """
  Build the awaiting list and stamped datagrams for a reliable batch.
  """
  @spec prepare_reliable([Submission.t()], non_neg_integer()) ::
          {[Datagram.t()], [{:gen_statem.from(), [byte()]}], non_neg_integer()}
  def prepare_reliable(batch, idx) do
    {stamped_batch, next_idx} =
      Enum.map_reduce(batch, idx, fn %Submission{tx: tx}, acc_idx ->
        stamp_indices(Transaction.datagrams(tx), acc_idx)
      end)

    awaiting =
      Enum.zip(batch, stamped_batch)
      |> Enum.map(fn {%Submission{from: from}, stamped} ->
        {from, Enum.map(stamped, & &1.idx)}
      end)

    all_datagrams = Enum.flat_map(stamped_batch, & &1)
    {all_datagrams, awaiting, next_idx}
  end

  @doc false
  @spec prepare_reliable_dispatch([Submission.t()], non_neg_integer()) ::
          {[Datagram.t()], [{:gen_statem.from(), [byte()]}], non_neg_integer(), non_neg_integer()}
  def prepare_reliable_dispatch(batch, idx) when is_list(batch) do
    {datagrams, awaiting, next_idx} = prepare_reliable(batch, idx)
    {datagrams, awaiting, next_idx, length(datagrams)}
  end

  # -- Reply helpers --

  @doc """
  Match response datagrams against the awaiting list and reply to all callers.

  Returns `:ok` if all expected datagrams are present, `:mismatch` otherwise.
  """
  @spec match_and_reply([Datagram.t()], [{:gen_statem.from(), [byte()]}]) :: :ok | :mismatch
  def match_and_reply(response_datagrams, awaiting) do
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

  @doc "Reply to all awaiting callers in an exchange with the given result."
  @spec reply_awaiting([{:gen_statem.from(), [byte()]}], term()) :: :ok
  def reply_awaiting(awaiting, reply) do
    Enum.each(awaiting, fn {from, _idxs} -> :gen_statem.reply(from, reply) end)
  end

  @doc "Reply to a list of submissions with the given result."
  @spec reply_submissions([Submission.t()], term()) :: :ok
  def reply_submissions(submissions, reply) do
    Enum.each(submissions, fn %Submission{from: from} -> :gen_statem.reply(from, reply) end)
  end

  @doc false
  @spec dispatch_realtime(
          Submission.t(),
          map(),
          non_neg_integer(),
          (list(), list(), map(), non_neg_integer(), :realtime -> tuple()),
          (map(), non_neg_integer() -> tuple())
        ) :: tuple()
  def dispatch_realtime(%Submission{} = submission, data, errors, send_frame, dispatch_next)
      when is_function(send_frame, 5) and is_function(dispatch_next, 2) do
    {datagrams, awaiting, next_idx, datagram_count} =
      prepare_realtime_dispatch(submission, data.idx)

    handle_realtime_dispatch_result(
      send_frame.(datagrams, awaiting, data, next_idx, :realtime),
      submission,
      data.link_name,
      datagram_count,
      errors,
      dispatch_next
    )
  end

  @doc false
  @spec dispatch_reliable(
          [Submission.t()],
          map(),
          non_neg_integer(),
          (list(), list(), map(), non_neg_integer(), :reliable -> tuple()),
          (map(), non_neg_integer() -> tuple())
        ) :: tuple()
  def dispatch_reliable(batch, data, errors, send_frame, dispatch_next)
      when is_list(batch) and is_function(send_frame, 5) and is_function(dispatch_next, 2) do
    {datagrams, awaiting, next_idx, datagram_count} = prepare_reliable_dispatch(batch, data.idx)

    handle_reliable_dispatch_result(
      send_frame.(datagrams, awaiting, data, next_idx, :reliable),
      batch,
      data.link_name,
      datagram_count,
      errors,
      dispatch_next
    )
  end

  @doc false
  @spec handle_realtime_dispatch_result(
          tuple(),
          Submission.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          (map(), non_neg_integer() -> tuple())
        ) :: tuple()
  def handle_realtime_dispatch_result(
        result,
        %Submission{} = submission,
        link_name,
        datagram_count,
        errors,
        dispatch_next
      )
      when is_function(dispatch_next, 2) do
    case result do
      {:ok, new_data, actions} ->
        Telemetry.dispatch_sent(link_name, :realtime, 1, datagram_count)
        {:next_state, :awaiting, new_data, actions}

      {:error, :frame_too_large, new_data} ->
        :gen_statem.reply(submission.from, {:error, :frame_too_large})
        dispatch_next.(new_data, errors)

      {:error, reason, new_data} ->
        reply_submissions([submission], {:error, reason})
        dispatch_next.(new_data, errors + 1)
    end
  end

  @doc false
  @spec handle_reliable_dispatch_result(
          tuple(),
          [Submission.t()],
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          (map(), non_neg_integer() -> tuple())
        ) :: tuple()
  def handle_reliable_dispatch_result(
        result,
        batch,
        link_name,
        datagram_count,
        errors,
        dispatch_next
      )
      when is_list(batch) and is_function(dispatch_next, 2) do
    case result do
      {:ok, new_data, actions} ->
        Telemetry.dispatch_sent(link_name, :reliable, length(batch), datagram_count)
        {:next_state, :awaiting, new_data, actions}

      {:error, :frame_too_large, new_data} ->
        reply_submissions(batch, {:error, :frame_too_large})
        dispatch_next.(new_data, errors)

      {:error, reason, new_data} ->
        reply_submissions(batch, {:error, reason})
        dispatch_next.(new_data, errors + 1)
    end
  end

  @doc false
  @spec handle_set_frame_timeout(:gen_statem.from(), term(), map()) :: tuple()
  def handle_set_frame_timeout(from, timeout_ms, data)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    {:keep_state, %{data | frame_timeout_ms: timeout_ms}, [{:reply, from, :ok}]}
  end

  def handle_set_frame_timeout(from, _timeout_ms, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :invalid_timeout}}]}
  end

  @doc false
  @spec start_named(module(), term(), keyword()) :: :gen_statem.start_ret()
  def start_named(module, {:local, _name} = name, opts),
    do: :gen_statem.start_link(name, module, opts, [])

  def start_named(module, {:global, _name} = name, opts),
    do: :gen_statem.start_link(name, module, opts, [])

  def start_named(module, {:via, _mod, _name} = name, opts),
    do: :gen_statem.start_link(name, module, opts, [])

  def start_named(module, name, opts) when is_atom(name),
    do: :gen_statem.start_link({:local, name}, module, opts, [])

  @doc "Reply to settle callers."
  @spec reply_settle_callers([term()], term()) :: :ok
  def reply_settle_callers(callers, reply) do
    Enum.each(callers, &:gen_statem.reply(&1, reply))
  end

  @doc false
  @spec all_expected_present?(map(), [Datagram.t()]) :: boolean()
  def all_expected_present?(exchange, response_datagrams) do
    expected = exchange.datagrams
    response_by_idx = Map.new(response_datagrams, &{&1.idx, &1})

    length(expected) == length(response_datagrams) and
      Enum.all?(expected, fn dg ->
        case Map.fetch(response_by_idx, dg.idx) do
          {:ok, resp} -> dg.cmd == resp.cmd and byte_size(dg.data) == byte_size(resp.data)
          :error -> false
        end
      end)
  end

  # -- Query helpers --

  @doc "Classify a submission as `:realtime` or `:reliable`."
  @spec submission_class(Submission.t()) :: :realtime | :reliable
  def submission_class(%Submission{stale_after_us: nil}), do: :reliable
  def submission_class(%Submission{}), do: :realtime

  @doc "Queue depth for a given class."
  @spec queue_depth(map(), :realtime | :reliable) :: non_neg_integer()
  def queue_depth(data, :realtime), do: :queue.len(data.realtime)
  def queue_depth(data, :reliable), do: :queue.len(data.reliable)

  @doc "Maximum datagram payload per frame."
  @spec max_datagram_bytes() :: pos_integer()
  def max_datagram_bytes, do: @max_datagram_bytes

  # -- Private --

  defp take_reliable_batch(reliable) do
    reliable_list = :queue.to_list(reliable)

    {batch_rev, _} =
      Enum.reduce_while(reliable_list, {[], 0}, fn %Submission{} = submission, {acc, size} ->
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
    rest = reliable_list |> Enum.drop(length(batch)) |> :queue.from_list()
    {batch, rest}
  end

  defp stale?(%Submission{stale_after_us: stale_after_us, enqueued_at_us: enqueued_at_us}, now_us)
       when is_integer(stale_after_us) do
    now_us - enqueued_at_us > stale_after_us
  end

  defp submission_age_us(%Submission{enqueued_at_us: enqueued_at_us}, now_us),
    do: now_us - enqueued_at_us
end
