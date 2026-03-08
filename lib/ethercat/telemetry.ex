defmodule EtherCAT.Telemetry do
  @moduledoc """
  Telemetry integration for the EtherCAT stack.

  Emits events via `:telemetry` and provides lightweight atomic counters
  for IEx inspection.

  ## Events

  ### Transaction span (emitted by `Bus.transaction/2|3`)

      [:ethercat, :bus, :transact, :start]
        measurements: %{system_time: integer(), monotonic_time: integer()}
        metadata:     %{datagram_count: integer(), class: :realtime | :reliable}

      [:ethercat, :bus, :transact, :stop]
        measurements: %{duration: integer()}
        metadata:     %{datagram_count: integer(), total_wkc: integer(), class: :realtime | :reliable}

      [:ethercat, :bus, :transact, :exception]
        measurements: %{duration: integer()}
        metadata:     %{kind: atom(), reason: term(), stacktrace: list()}

  ### Submission events

      [:ethercat, :bus, :submission, :enqueued]
        measurements: %{queue_depth: non_neg_integer()}
        metadata:     %{link: String.t(), class: :realtime | :reliable, state: :idle | :awaiting}

  `queue_depth` is the depth of that submission class immediately after
  admission and before any immediate dispatch on an idle bus.

      [:ethercat, :bus, :submission, :expired]
        measurements: %{age_us: non_neg_integer()}
        metadata:     %{link: String.t(), class: :realtime}

  ### Dispatch events

      [:ethercat, :bus, :dispatch, :sent]
        measurements: %{transaction_count: pos_integer(), datagram_count: pos_integer()}
        metadata:     %{link: String.t(), class: :realtime | :reliable}

  ### Frame events

      [:ethercat, :bus, :frame, :sent]
        measurements: %{size: integer(), tx_timestamp: integer() | nil}
        metadata:     %{link: String.t(), port: :primary | :secondary}

      [:ethercat, :bus, :frame, :received]
        measurements: %{size: integer(), rx_timestamp: integer() | nil}
        metadata:     %{link: String.t(), port: :primary | :secondary}

      [:ethercat, :bus, :frame, :dropped]
        measurements: %{size: integer()}
        metadata:     %{link: String.t(), reason: atom()}

      [:ethercat, :bus, :frame, :ignored]
        measurements: %{}
        metadata:     %{link: String.t()}

  ### Link lifecycle events

      [:ethercat, :bus, :link, :down]
        measurements: %{}
        metadata:     %{link: String.t(), reason: term()}

      [:ethercat, :bus, :link, :reconnected]
        measurements: %{}
        metadata:     %{link: String.t()}

  ### DC maintenance and lock monitoring

      [:ethercat, :dc, :tick]
        measurements: %{wkc: integer()}
        metadata:     %{ref_station: non_neg_integer()}

      [:ethercat, :dc, :sync_diff, :observed]
        measurements: %{max_sync_diff_ns: non_neg_integer()}
        metadata:     %{ref_station: non_neg_integer(), station_count: pos_integer()}

      [:ethercat, :dc, :lock, :changed]
        measurements: %{}
        metadata:     %{ref_station: non_neg_integer(), from: atom(), to: atom(), max_sync_diff_ns: non_neg_integer() | nil}

  ### Domain cycle events

      [:ethercat, :domain, :cycle, :done]
        measurements: %{duration_us: integer(), cycle_count: non_neg_integer()}
        metadata:     %{domain: atom()}

      [:ethercat, :domain, :cycle, :missed]
        measurements: %{miss_count: pos_integer()}
        metadata:     %{domain: atom(), reason: term()}

  ### Domain fault events

      [:ethercat, :domain, :stopped]
        measurements: %{}
        metadata:     %{domain: atom(), reason: term()}

      [:ethercat, :domain, :crashed]
        measurements: %{}
        metadata:     %{domain: atom(), reason: term()}

  ### Slave fault events

      [:ethercat, :slave, :crashed]
        measurements: %{}
        metadata:     %{slave: atom(), reason: term()}

      [:ethercat, :slave, :health, :fault]
        measurements: %{al_state: 1 | 2 | 4 | 8, error_code: non_neg_integer()}
        metadata:     %{slave: atom(), station: non_neg_integer()}

  ## Timestamps

  `tx_timestamp` and `rx_timestamp` are `System.monotonic_time/0` values.
  When Linux `SO_TIMESTAMPING` is available, `rx_timestamp` is derived from
  the kernel's software RX timestamp for nanosecond accuracy. Their difference
  gives wire-level round-trip time.

  ## Example

      :telemetry.attach_many("ethercat-log", [
        [:ethercat, :bus, :transact, :stop],
        [:ethercat, :bus, :link, :down]
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
  # Convenience emitters — called from Bus, link adapters, and runtime workers.
  # ---------------------------------------------------------------------------

  @doc false
  def submission_enqueued(link, class, state, queue_depth) do
    execute(
      [:ethercat, :bus, :submission, :enqueued],
      %{queue_depth: queue_depth},
      %{link: link, class: class, state: state}
    )
  end

  @doc false
  def submission_expired(link, class, age_us) do
    execute(
      [:ethercat, :bus, :submission, :expired],
      %{age_us: age_us},
      %{link: link, class: class}
    )
  end

  @doc false
  def dispatch_sent(link, class, transaction_count, datagram_count) do
    execute(
      [:ethercat, :bus, :dispatch, :sent],
      %{transaction_count: transaction_count, datagram_count: datagram_count},
      %{link: link, class: class}
    )
  end

  @doc false
  def frame_sent(link, port, size, tx_timestamp \\ nil) do
    execute(
      [:ethercat, :bus, :frame, :sent],
      %{size: size, tx_timestamp: tx_timestamp},
      %{link: link, port: port}
    )
  end

  @doc false
  def frame_received(link, port, size, rx_timestamp \\ nil) do
    execute(
      [:ethercat, :bus, :frame, :received],
      %{size: size, rx_timestamp: rx_timestamp},
      %{link: link, port: port}
    )
  end

  @doc false
  def frame_dropped(link, size, reason) do
    execute(
      [:ethercat, :bus, :frame, :dropped],
      %{size: size},
      %{link: link, reason: reason}
    )
  end

  @doc false
  def frame_ignored(link) do
    execute([:ethercat, :bus, :frame, :ignored], %{}, %{link: link})
  end

  @doc false
  def link_down(link, reason) do
    execute(
      [:ethercat, :bus, :link, :down],
      %{},
      %{link: link, reason: reason}
    )
  end

  @doc false
  def link_reconnected(link) do
    execute(
      [:ethercat, :bus, :link, :reconnected],
      %{},
      %{link: link}
    )
  end

  @doc false
  def dc_tick(ref_station, wkc) do
    execute(
      [:ethercat, :dc, :tick],
      %{wkc: wkc},
      %{ref_station: ref_station}
    )
  end

  @doc false
  def dc_sync_diff_observed(ref_station, max_sync_diff_ns, station_count) do
    execute(
      [:ethercat, :dc, :sync_diff, :observed],
      %{max_sync_diff_ns: max_sync_diff_ns},
      %{ref_station: ref_station, station_count: station_count}
    )
  end

  @doc false
  def dc_lock_changed(ref_station, from_state, to_state, max_sync_diff_ns) do
    execute(
      [:ethercat, :dc, :lock, :changed],
      %{},
      %{
        ref_station: ref_station,
        from: from_state,
        to: to_state,
        max_sync_diff_ns: max_sync_diff_ns
      }
    )
  end

  @doc false
  def domain_cycle_done(domain_id, duration_us, cycle_count) do
    execute(
      [:ethercat, :domain, :cycle, :done],
      %{duration_us: duration_us, cycle_count: cycle_count},
      %{domain: domain_id}
    )
  end

  @doc false
  def domain_cycle_missed(domain_id, miss_count, reason) do
    execute(
      [:ethercat, :domain, :cycle, :missed],
      %{miss_count: miss_count},
      %{domain: domain_id, reason: reason}
    )
  end

  @doc false
  def domain_stopped(domain_id, reason) do
    execute([:ethercat, :domain, :stopped], %{}, %{domain: domain_id, reason: reason})
  end

  @doc false
  def domain_crashed(domain_id, reason) do
    execute([:ethercat, :domain, :crashed], %{}, %{domain: domain_id, reason: reason})
  end

  @doc false
  def slave_crashed(slave_name, reason) do
    execute([:ethercat, :slave, :crashed], %{}, %{slave: slave_name, reason: reason})
  end

  @doc false
  def slave_health_fault(slave_name, station, al_state, error_code) do
    execute(
      [:ethercat, :slave, :health, :fault],
      %{al_state: al_state, error_code: error_code},
      %{slave: slave_name, station: station}
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
    [:ethercat, :bus, :submission, :enqueued],
    [:ethercat, :bus, :submission, :expired],
    [:ethercat, :bus, :dispatch, :sent],
    [:ethercat, :bus, :frame, :sent],
    [:ethercat, :bus, :frame, :received],
    [:ethercat, :bus, :frame, :dropped],
    [:ethercat, :bus, :frame, :ignored],
    [:ethercat, :bus, :link, :down],
    [:ethercat, :bus, :link, :reconnected],
    [:ethercat, :dc, :tick],
    [:ethercat, :dc, :sync_diff, :observed],
    [:ethercat, :dc, :lock, :changed],
    [:ethercat, :domain, :cycle, :done],
    [:ethercat, :domain, :cycle, :missed],
    [:ethercat, :domain, :stopped],
    [:ethercat, :domain, :crashed],
    [:ethercat, :slave, :crashed],
    [:ethercat, :slave, :health, :fault]
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
    detach()
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
  Return current counters as `{event, count}` tuples.
  """
  @spec snapshot() :: [{[atom()], non_neg_integer()}]
  def snapshot do
    case :persistent_term.get({__MODULE__, :counters}, nil) do
      nil ->
        []

      ref ->
        Enum.map(@all_events, fn event ->
          idx = Map.fetch!(@event_index, event)
          {event, :counters.get(ref, idx + 1)}
        end)
    end
  end

  @doc """
  Print event counts.
  """
  def stats do
    snapshot = snapshot()

    if snapshot != [] do
      Enum.each(snapshot, fn {event, count} ->
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
