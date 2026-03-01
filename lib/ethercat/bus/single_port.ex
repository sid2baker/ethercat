defmodule EtherCAT.Bus.SinglePort do
  @moduledoc """
  Single-port EtherCAT bus implementation.

  ## States

    - `:idle`     — transport open, ready for transactions
    - `:awaiting` — frame sent, waiting for response
    - `:down`     — transport lost, waiting for carrier

  ## Queue batching

  Two transaction kinds with different behaviour when the bus is busy:

    - `Bus.transaction/3` — *postponed* in the gen_statem event queue.
      Re-delivered when the bus returns to `:idle`. A deadline check then
      discards stale calls with `{:error, :expired}`. Correct for cyclic
      process data (LRW) and DC sync (ARMW).
    - `Bus.transaction_queue/2` — always added to `pending` and merged into
      the next combined frame. Never discarded. For mailbox, CoE SDO, and
      configuration commands.
    - Each original caller receives only their own datagram results, in order.

  Subscribes to VintageNet `lower_up` for proactive carrier detection
  (raw socket transports only).
  """

  @behaviour :gen_statem

  alias EtherCAT.Bus.{Datagram, Frame}
  alias EtherCAT.Telemetry

  # Maximum EtherCAT datagram bytes per combined frame.
  # Conservative: raw Ethernet = 1500−14−2 = 1484; UDP = 1500−20−8−2 = 1470.
  @max_datagram_bytes 1_400

  @debounce_interval 200

  defstruct [
    :transport,
    :transport_mod,
    :idx,
    :awaiting_callers,
    :tx_at,
    pending: []
  ]

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(opts) do
    transport_mod = Keyword.fetch!(opts, :transport_mod)

    with {:ok, transport} <- transport_mod.open(opts),
         :ok <- transport_mod.warmup(transport) do
      iface = transport_mod.interface(transport)
      if iface, do: VintageNet.subscribe(["interface", iface, "lower_up"])

      {:ok, :idle, %__MODULE__{transport: transport, transport_mod: transport_mod, idx: 0}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # -- VintageNet carrier detection (any state) --------------------------------

  @impl true
  def handle_event(
        :info,
        {VintageNet, ["interface", _, "lower_up"], _old, false, _meta},
        state,
        data
      )
      when state != :down do
    Telemetry.socket_down(data.transport_mod.name(data.transport), :carrier_lost)

    # Reply error to in-flight callers and any queued pending
    flight_replies =
      (data.awaiting_callers || [])
      |> Enum.map(fn {from, _} -> {:reply, from, {:error, :down}} end)

    pending_replies =
      data.pending
      |> Enum.map(fn {from, _} -> {:reply, from, {:error, :down}} end)

    {:next_state, :down, %{data | awaiting_callers: nil, pending: []},
     flight_replies ++ pending_replies}
  end

  # Carrier restored — debounce before reconnecting
  def handle_event(
        :info,
        {VintageNet, ["interface", _, "lower_up"], _old, true, _meta},
        :down,
        _data
      ) do
    {:keep_state_and_data, [{:state_timeout, @debounce_interval, :reconnect}]}
  end

  # Ignore other VintageNet messages
  def handle_event(:info, {VintageNet, _, _, _, _}, _state, _data) do
    :keep_state_and_data
  end

  # -- idle -------------------------------------------------------------------

  def handle_event(:enter, _old, :idle, _data), do: :keep_state_and_data

  # Timed transaction — check deadline before sending
  def handle_event({:call, from}, {:transact, datagrams, enqueued_at, timeout_us}, :idle, data) do
    if System.monotonic_time(:microsecond) - enqueued_at > timeout_us do
      {:keep_state_and_data, [{:reply, from, {:error, :expired}}]}
    else
      Telemetry.transact_direct(data.transport_mod.name(data.transport))
      do_send(datagrams, from, data)
    end
  end

  # Queued transaction — always send immediately when idle
  def handle_event({:call, from}, {:transact_queue, datagrams}, :idle, data) do
    Telemetry.transact_direct(data.transport_mod.name(data.transport))
    do_send(datagrams, from, data)
  end

  # -- awaiting ---------------------------------------------------------------

  def handle_event(:enter, _old, :awaiting, _data), do: :keep_state_and_data

  # Timed transaction while awaiting — postpone for re-delivery on :idle
  def handle_event({:call, _from}, {:transact, _, _, _}, :awaiting, data) do
    Telemetry.transact_postponed(data.transport_mod.name(data.transport))
    {:keep_state_and_data, [:postpone]}
  end

  # Queued transaction while awaiting — add to pending batch
  def handle_event({:call, from}, {:transact_queue, datagrams}, :awaiting, data) do
    Telemetry.transact_queued(data.transport_mod.name(data.transport))
    {:keep_state, %{data | pending: data.pending ++ [{from, datagrams}]}}
  end

  # Transport message received
  def handle_event(:info, msg, :awaiting, data) do
    case data.transport_mod.match(data.transport, msg) do
      {:ok, ecat_payload, rx_at} ->
        Telemetry.frame_received(
          data.transport_mod.name(data.transport),
          :primary,
          byte_size(ecat_payload),
          rx_at
        )

        handle_response(ecat_payload, data)

      :ignore ->
        :keep_state_and_data
    end
  end

  def handle_event(:state_timeout, :timeout, :awaiting, data) do
    data.transport_mod.drain(data.transport)

    Enum.each(data.awaiting_callers, fn {from, _} ->
      :gen_statem.reply(from, {:error, :timeout})
    end)

    flush_pending(%{data | awaiting_callers: nil, tx_at: nil})
  end

  # -- down -------------------------------------------------------------------

  def handle_event(:enter, _old, :down, data) do
    transport = data.transport_mod.close(data.transport)

    iface = data.transport_mod.interface(transport)

    actions =
      if iface && carrier_up?(iface),
        do: [{:state_timeout, @debounce_interval, :reconnect}],
        else: []

    {:keep_state, %{data | transport: transport}, actions}
  end

  def handle_event(:state_timeout, :reconnect, :down, data) do
    iface = data.transport_mod.interface(data.transport)

    if iface && carrier_up?(iface) do
      case data.transport_mod.open(transport_opts(data)) do
        {:ok, transport} ->
          case data.transport_mod.warmup(transport) do
            :ok ->
              Telemetry.socket_reconnected(data.transport_mod.name(transport))
              {:next_state, :idle, %{data | transport: transport}}

            {:error, _} ->
              data.transport_mod.close(transport)
              {:keep_state_and_data, [{:state_timeout, @debounce_interval, :reconnect}]}
          end

        {:error, _} ->
          {:keep_state_and_data, [{:state_timeout, @debounce_interval, :reconnect}]}
      end
    else
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

  # -- response handling ------------------------------------------------------

  defp handle_response(ecat_payload, data) do
    case Frame.decode(ecat_payload) do
      {:ok, datagrams} ->
        case match_and_reply(datagrams, data.awaiting_callers) do
          :ok ->
            flush_pending(%{data | awaiting_callers: nil, tx_at: nil})

          :mismatch ->
            Telemetry.frame_dropped(
              data.transport_mod.name(data.transport),
              byte_size(ecat_payload),
              :idx_mismatch
            )

            data.transport_mod.set_active_once(data.transport)
            :keep_state_and_data
        end

      {:error, _} ->
        Telemetry.frame_dropped(
          data.transport_mod.name(data.transport),
          byte_size(ecat_payload),
          :decode_error
        )

        data.transport_mod.set_active_once(data.transport)
        :keep_state_and_data
    end
  end

  defp match_and_reply(response_datagrams, awaiting_callers) do
    idx_map = Map.new(response_datagrams, &{&1.idx, &1})

    all_present =
      Enum.all?(awaiting_callers, fn {_from, idxs} ->
        Enum.all?(idxs, &Map.has_key?(idx_map, &1))
      end)

    if all_present do
      Enum.each(awaiting_callers, fn {from, idxs} ->
        results = Enum.map(idxs, &Map.fetch!(idx_map, &1))
        :gen_statem.reply(from, {:ok, results})
      end)

      :ok
    else
      :mismatch
    end
  end

  # -- pending queue flush ----------------------------------------------------

  defp flush_pending(%{pending: []} = data) do
    {:next_state, :idle, data}
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
        case data.transport_mod.send(data.transport, payload) do
          {:ok, tx_at} ->
            Telemetry.frame_sent(
              data.transport_mod.name(data.transport),
              :primary,
              byte_size(payload),
              tx_at
            )

            Telemetry.batch_sent(data.transport_mod.name(data.transport), length(batch))
            data.transport_mod.set_active_once(data.transport)

            {:next_state, :awaiting,
             %{
               data
               | idx: new_idx,
                 awaiting_callers: awaiting_callers,
                 pending: overflow,
                 tx_at: tx_at
             }, [{:state_timeout, 25, :timeout}]}

          {:error, reason} ->
            Telemetry.socket_down(data.transport_mod.name(data.transport), reason)

            all_pending = batch ++ overflow

            actions =
              Enum.map(all_pending, fn {from, _} -> {:reply, from, {:error, :down}} end)

            {:next_state, :down, %{data | pending: []}, actions}
        end

      {:error, :frame_too_large} ->
        # MTU check in take_within_mtu should prevent this, but handle gracefully
        actions = Enum.map(batch, fn {from, _} -> {:reply, from, {:error, :frame_too_large}} end)

        flush_pending(
          %{data | pending: overflow, awaiting_callers: nil}
          |> then(fn d ->
            Enum.each(actions, fn {:reply, from, val} -> :gen_statem.reply(from, val) end)
            d
          end)
        )
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp do_send(datagrams, from, data) do
    {stamped, new_idx} = stamp_indices(datagrams, data.idx)
    awaiting_callers = [{from, Enum.map(stamped, & &1.idx)}]

    with {:ok, payload} <- Frame.encode(stamped),
         {:ok, tx_at} <- data.transport_mod.send(data.transport, payload) do
      Telemetry.frame_sent(
        data.transport_mod.name(data.transport),
        :primary,
        byte_size(payload),
        tx_at
      )

      data.transport_mod.set_active_once(data.transport)

      new_data = %{data | idx: new_idx, awaiting_callers: awaiting_callers, tx_at: tx_at}
      {:next_state, :awaiting, new_data, [{:state_timeout, 25, :timeout}]}
    else
      {:error, :frame_too_large} = err ->
        {:keep_state_and_data, [{:reply, from, err}]}

      {:error, reason} ->
        Telemetry.socket_down(data.transport_mod.name(data.transport), reason)
        {:next_state, :down, data, [{:reply, from, {:error, :down}}]}
    end
  end

  defp stamp_indices(datagrams, start_idx) do
    Enum.map_reduce(datagrams, start_idx, fn dg, idx ->
      <<byte_idx>> = <<idx::8>>
      {%{dg | idx: byte_idx}, idx + 1}
    end)
  end

  # Takes entries from pending until adding the next would exceed @max_datagram_bytes.
  # Always takes at least one entry to avoid starvation.
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

  defp transport_opts(data) do
    iface = data.transport_mod.interface(data.transport)
    if iface, do: [interface: iface], else: []
  end

  defp carrier_up?(interface) do
    VintageNet.get(["interface", interface, "lower_up"]) == true
  end
end
