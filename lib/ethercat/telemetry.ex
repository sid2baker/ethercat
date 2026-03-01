defmodule EtherCAT.Telemetry do
  @moduledoc """
  Telemetry integration for the EtherCAT stack.

  Emits events via `:telemetry` and provides lightweight atomic counters
  for IEx inspection.

  ## Events

  ### Transaction span (emitted by `Bus.transaction/2`)

      [:ethercat, :bus, :transact, :start]
        measurements: %{system_time: integer(), monotonic_time: integer()}
        metadata:     %{datagram_count: integer()}

      [:ethercat, :bus, :transact, :stop]
        measurements: %{duration: integer()}
        metadata:     %{datagram_count: integer(), total_wkc: integer()}

      [:ethercat, :bus, :transact, :exception]
        measurements: %{duration: integer()}
        metadata:     %{kind: atom(), reason: term(), stacktrace: list()}

  ### Frame-level events

      [:ethercat, :bus, :frame, :sent]
        measurements: %{size: integer(), tx_timestamp: integer() | nil}
        metadata:     %{transport: String.t(), port: :primary | :secondary}

      [:ethercat, :bus, :frame, :received]
        measurements: %{size: integer(), rx_timestamp: integer() | nil}
        metadata:     %{transport: String.t(), port: :primary | :secondary}

      [:ethercat, :bus, :frame, :dropped]
        measurements: %{size: integer()}
        metadata:     %{transport: String.t(), reason: atom()}

      [:ethercat, :bus, :frame, :ignored]
        measurements: %{}
        metadata:     %{transport: String.t()}

  ### Transaction queueing

      [:ethercat, :bus, :transact, :discarded]
        measurements: %{}
        metadata:     %{transport: String.t()}

      [:ethercat, :bus, :transact, :batch_sent]
        measurements: %{transaction_count: integer()}
        metadata:     %{transport: String.t()}

  ### Transport lifecycle events

      [:ethercat, :bus, :transport, :down]
        measurements: %{}
        metadata:     %{transport: String.t(), reason: term()}

      [:ethercat, :bus, :transport, :reconnected]
        measurements: %{}
        metadata:     %{transport: String.t()}

  ## Timestamps

  `tx_timestamp` and `rx_timestamp` are `System.monotonic_time/0` values.
  When Linux `SO_TIMESTAMPING` is available, `rx_timestamp` is derived from
  the kernel's software RX timestamp for nanosecond accuracy. Their difference
  gives wire-level round-trip time.

  ## Example

      :telemetry.attach_many("ethercat-log", [
        [:ethercat, :bus, :transact, :stop],
        [:ethercat, :bus, :transport, :down]
      ], &MyHandler.handle_event/4, nil)
  """

  @doc false
  def execute(event, measurements, metadata \\ %{}) do
    :telemetry.execute(event, measurements, metadata)
  end

  @doc false
  def span(event_prefix, start_metadata, fun) when is_function(fun, 0) do
    :telemetry.span(event_prefix, start_metadata, fun)
  end

  # ---------------------------------------------------------------------------
  # Convenience emitters — called from Bus.SinglePort and Bus.Redundant
  # ---------------------------------------------------------------------------

  @doc false
  def frame_sent(transport, port, size, tx_timestamp \\ nil) do
    execute(
      [:ethercat, :bus, :frame, :sent],
      %{size: size, tx_timestamp: tx_timestamp},
      %{transport: transport, port: port}
    )
  end

  @doc false
  def frame_received(transport, port, size, rx_timestamp \\ nil) do
    execute(
      [:ethercat, :bus, :frame, :received],
      %{size: size, rx_timestamp: rx_timestamp},
      %{transport: transport, port: port}
    )
  end

  @doc false
  def frame_dropped(transport, size, reason) do
    execute(
      [:ethercat, :bus, :frame, :dropped],
      %{size: size},
      %{transport: transport, reason: reason}
    )
  end

  @doc false
  def frame_ignored(transport) do
    execute([:ethercat, :bus, :frame, :ignored], %{}, %{transport: transport})
  end

  @doc false
  def transact_discarded(transport) do
    execute(
      [:ethercat, :bus, :transact, :discarded],
      %{},
      %{transport: transport}
    )
  end

  @doc false
  def batch_sent(transport, transaction_count) do
    execute(
      [:ethercat, :bus, :transact, :batch_sent],
      %{transaction_count: transaction_count},
      %{transport: transport}
    )
  end

  @doc false
  def transact_direct(transport) do
    execute([:ethercat, :bus, :transact, :direct], %{}, %{transport: transport})
  end

  @doc false
  def transact_postponed(transport) do
    execute([:ethercat, :bus, :transact, :postponed], %{}, %{transport: transport})
  end

  @doc false
  def transact_queued(transport) do
    execute([:ethercat, :bus, :transact, :queued], %{}, %{transport: transport})
  end

  @doc false
  def socket_down(transport, reason) do
    execute(
      [:ethercat, :bus, :transport, :down],
      %{},
      %{transport: transport, reason: reason}
    )
  end

  @doc false
  def socket_reconnected(transport) do
    execute(
      [:ethercat, :bus, :transport, :reconnected],
      %{},
      %{transport: transport}
    )
  end

  # ---------------------------------------------------------------------------
  # Lightweight event counters for IEx inspection
  # ---------------------------------------------------------------------------

  @handler_id "ethercat-counters"

  @all_events [
    [:ethercat, :bus, :transact, :start],
    [:ethercat, :bus, :transact, :stop],
    [:ethercat, :bus, :transact, :exception],
    [:ethercat, :bus, :transact, :discarded],
    [:ethercat, :bus, :transact, :batch_sent],
    [:ethercat, :bus, :transact, :direct],
    [:ethercat, :bus, :transact, :postponed],
    [:ethercat, :bus, :transact, :queued],
    [:ethercat, :bus, :frame, :sent],
    [:ethercat, :bus, :frame, :received],
    [:ethercat, :bus, :frame, :dropped],
    [:ethercat, :bus, :frame, :ignored],
    [:ethercat, :bus, :transport, :down],
    [:ethercat, :bus, :transport, :reconnected]
  ]

  @event_index @all_events |> Enum.with_index() |> Map.new()

  @doc """
  Attach counters to all EtherCAT telemetry events.

  Use `stats/0` to print current counts and `reset/0` to zero them.

  ## Example

      EtherCAT.Telemetry.attach()
      # ... do some work ...
      EtherCAT.Telemetry.stats()
      EtherCAT.Telemetry.reset()
  """
  def attach do
    ref = :counters.new(length(@all_events), [:write_concurrency])
    :persistent_term.put({__MODULE__, :counters}, ref)

    :telemetry.attach_many(
      @handler_id,
      @all_events,
      fn event, _measurements, _metadata, _config ->
        case @event_index do
          %{^event => idx} -> :counters.add(ref, idx + 1, 1)
          _ -> :ok
        end
      end,
      nil
    )

    :ok
  end

  @doc """
  Print event counts.
  """
  def stats do
    ref = :persistent_term.get({__MODULE__, :counters}, nil)

    if ref do
      @all_events
      |> Enum.with_index()
      |> Enum.each(fn {event, idx} ->
        count = :counters.get(ref, idx + 1)
        name = event |> Enum.drop(1) |> Enum.join(".")
        IO.puts("  #{String.pad_trailing(name, 30)} #{count}")
      end)

      :ok
    else
      IO.puts("  Not attached. Call EtherCAT.Telemetry.attach() first.")
      :ok
    end
  end

  @doc """
  Reset all counters to zero.
  """
  def reset do
    ref = :persistent_term.get({__MODULE__, :counters}, nil)

    if ref do
      for idx <- 0..(length(@all_events) - 1) do
        :counters.put(ref, idx + 1, 0)
      end
    end

    :ok
  end

  @doc """
  Detach counters.
  """
  def detach do
    :telemetry.detach(@handler_id)
    :persistent_term.erase({__MODULE__, :counters})
    :ok
  end
end
