defmodule EtherCAT.Telemetry do
  @moduledoc """
  Telemetry integration for the EtherCAT stack.

  Emits events via `:telemetry` and provides lightweight atomic counters
  for IEx inspection.

  ## Events

  ### Transaction span (emitted by `Link.transact/3`)

      [:ethercat, :link, :transact, :start]
        measurements: %{system_time: integer(), monotonic_time: integer()}
        metadata:     %{datagram_count: integer()}

      [:ethercat, :link, :transact, :stop]
        measurements: %{duration: integer()}
        metadata:     %{datagram_count: integer(), total_wkc: integer()}

      [:ethercat, :link, :transact, :exception]
        measurements: %{duration: integer()}
        metadata:     %{kind: atom(), reason: term(), stacktrace: list()}

  ### Frame-level events

      [:ethercat, :link, :frame, :sent]
        measurements: %{size: integer(), tx_timestamp: integer() | nil}
        metadata:     %{interface: String.t(), port: :primary | :secondary}

      [:ethercat, :link, :frame, :received]
        measurements: %{size: integer(), rx_timestamp: integer() | nil}
        metadata:     %{interface: String.t(), port: :primary | :secondary}

      [:ethercat, :link, :frame, :dropped]
        measurements: %{size: integer()}
        metadata:     %{interface: String.t(), reason: atom()}

  ### Transaction queueing

      [:ethercat, :link, :transact, :postponed]
        measurements: %{}
        metadata:     %{interface: String.t()}

  ### Socket lifecycle events

      [:ethercat, :link, :socket, :down]
        measurements: %{}
        metadata:     %{interface: String.t(), reason: term()}

      [:ethercat, :link, :socket, :reconnected]
        measurements: %{}
        metadata:     %{interface: String.t()}

  ## Timestamps

  `tx_timestamp` and `rx_timestamp` are `System.monotonic_time/0` values.
  When Linux `SO_TIMESTAMPING` is available, `rx_timestamp` is derived from
  the kernel's software RX timestamp for nanosecond accuracy. Their difference
  gives wire-level round-trip time.

  ## Example

      :telemetry.attach_many("ethercat-log", [
        [:ethercat, :link, :transact, :stop],
        [:ethercat, :link, :socket, :down]
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
  # Convenience emitters — called from Link.Normal and Link.Redundant
  # ---------------------------------------------------------------------------

  @doc false
  def frame_sent(interface, port, size, tx_timestamp \\ nil) do
    execute(
      [:ethercat, :link, :frame, :sent],
      %{size: size, tx_timestamp: tx_timestamp},
      %{interface: interface, port: port}
    )
  end

  @doc false
  def frame_received(interface, port, size, rx_timestamp \\ nil) do
    execute(
      [:ethercat, :link, :frame, :received],
      %{size: size, rx_timestamp: rx_timestamp},
      %{interface: interface, port: port}
    )
  end

  @doc false
  def frame_dropped(interface, size, reason) do
    execute(
      [:ethercat, :link, :frame, :dropped],
      %{size: size},
      %{interface: interface, reason: reason}
    )
  end

  @doc false
  def transact_postponed(interface) do
    execute(
      [:ethercat, :link, :transact, :postponed],
      %{},
      %{interface: interface}
    )
  end

  @doc false
  def socket_down(interface, reason) do
    execute(
      [:ethercat, :link, :socket, :down],
      %{},
      %{interface: interface, reason: reason}
    )
  end

  @doc false
  def socket_reconnected(interface) do
    execute(
      [:ethercat, :link, :socket, :reconnected],
      %{},
      %{interface: interface}
    )
  end

  # ---------------------------------------------------------------------------
  # Lightweight event counters for IEx inspection
  # ---------------------------------------------------------------------------

  @handler_id "ethercat-counters"

  @all_events [
    [:ethercat, :link, :transact, :start],
    [:ethercat, :link, :transact, :stop],
    [:ethercat, :link, :transact, :exception],
    [:ethercat, :link, :transact, :postponed],
    [:ethercat, :link, :frame, :sent],
    [:ethercat, :link, :frame, :received],
    [:ethercat, :link, :frame, :dropped],
    [:ethercat, :link, :socket, :down],
    [:ethercat, :link, :socket, :reconnected]
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
