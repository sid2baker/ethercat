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

  defp stale?(%Submission{stale_after_us: stale_after_us, enqueued_at_us: enqueued_at_us}, now_us)
       when is_integer(stale_after_us) do
    now_us - enqueued_at_us > stale_after_us
  end

  defp submission_age_us(%Submission{enqueued_at_us: enqueued_at_us}, now_us),
    do: now_us - enqueued_at_us
end
