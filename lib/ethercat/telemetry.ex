defmodule EtherCAT.Telemetry do
  @moduledoc """
  Telemetry integration for the EtherCAT stack.

  Emits events via `:telemetry` and provides lightweight atomic counters
  for IEx inspection.

  ## Introspection Strategy

  Telemetry is the machine-readable surface:

  - event names are stable and enumerable through `events/0`
  - measurements are numeric
  - metadata is intentionally low-cardinality and bounded
  - detailed failure terms stay in logs and API replies, not telemetry
  - the `[:ethercat, :bus, :transact, :exception]` span event is the one
    intentional exception and keeps the raw exception payload from
    `:telemetry.span/3`

  Logs are the human-readable narrative:

  - `info` for lifecycle transitions and successful recovery
  - `warning` for degraded but recoverable runtime conditions
  - `error` for crashes and session-stopping faults
  - `debug` for step-by-step progress and repeated retry chatter

  This split keeps dashboards and alerts predictable while preserving rich
  operator context in the logs.

  ## Events

  ### Transaction span (emitted by `Bus.transaction/2|3`)

      [:ethercat, :bus, :transact, :start]
        measurements: %{system_time: integer(), monotonic_time: integer()}
        metadata:     %{datagram_count: integer(), class: :realtime | :reliable}

      [:ethercat, :bus, :transact, :stop]
        measurements: %{duration: integer()}
        metadata:     %{datagram_count: integer(), total_wkc: integer(), class: :realtime | :reliable, status: :ok | :error, error_kind: atom() | nil}

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
        metadata:     %{link: String.t(), endpoint: String.t(), port: :primary | :secondary}

      [:ethercat, :bus, :frame, :received]
        measurements: %{size: integer(), rx_timestamp: integer() | nil}
        metadata:     %{link: String.t(), endpoint: String.t(), port: :primary | :secondary}

      [:ethercat, :bus, :frame, :dropped]
        measurements: %{size: integer()}
        metadata:     %{link: String.t(), reason: atom()}

  ### Link lifecycle events

      [:ethercat, :bus, :link, :down]
        measurements: %{}
        metadata:     %{link: String.t(), endpoint: String.t(), reason: atom()}

      [:ethercat, :bus, :link, :reconnected]
        measurements: %{}
        metadata:     %{link: String.t(), endpoint: String.t()}

      [:ethercat, :bus, :link, :health, :changed]
        measurements: %{}
        metadata:     %{link: String.t(), port: :primary | :secondary, from: term(), to: term()}

      [:ethercat, :bus, :link, :exchange, :timeout]
        measurements: %{arrival_count: non_neg_integer(), consecutive_timeouts: pos_integer()}
        metadata:     %{link: String.t(), detail: :no_arrivals | :partial_arrivals, arrival_classes: [atom()], pri_sent: boolean(), sec_sent: boolean()}

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

      [:ethercat, :dc, :runtime, :state, :changed]
        measurements: %{}
        metadata:     %{from: :healthy | :failing, to: :healthy | :failing, reason: atom() | nil, consecutive_failures: non_neg_integer()}

  ### Domain cycle events

      [:ethercat, :domain, :cycle, :done]
        measurements: %{duration_us: integer(), cycle_count: non_neg_integer(), completed_at_us: integer()}
        metadata:     %{domain: atom()}

      [:ethercat, :domain, :cycle, :invalid]
        measurements: %{total_invalid_count: pos_integer(), invalid_at_us: integer()}
        metadata:     %{domain: atom(), reason: atom(), expected_wkc: non_neg_integer() | nil, actual_wkc: non_neg_integer() | nil, reply_count: non_neg_integer() | nil}

      [:ethercat, :domain, :cycle, :transport_miss]
        measurements: %{consecutive_miss_count: pos_integer(), total_invalid_count: pos_integer(), invalid_at_us: integer()}
        metadata:     %{domain: atom(), reason: atom(), expected_wkc: non_neg_integer() | nil, actual_wkc: non_neg_integer() | nil, reply_count: non_neg_integer() | nil}

  ### Domain fault events

      [:ethercat, :domain, :stopped]
        measurements: %{}
        metadata:     %{domain: atom(), reason: atom()}

      [:ethercat, :domain, :crashed]
        measurements: %{}
        metadata:     %{domain: atom(), reason: atom()}

  ### Master lifecycle events

      [:ethercat, :master, :state, :changed]
        measurements: %{}
        metadata:     %{from: atom(), to: atom(), public_state: atom(), runtime_target: atom()}

      [:ethercat, :master, :startup, :bus_stable]
        measurements: %{slave_count: non_neg_integer()}
        metadata:     %{}

      [:ethercat, :master, :configuration, :result]
        measurements: %{duration_ms: non_neg_integer()}
        metadata:     %{status: :ok | :error, slave_count: non_neg_integer(), runtime_target: atom(), reason: atom() | nil}

      [:ethercat, :master, :activation, :result]
        measurements: %{duration_ms: non_neg_integer()}
        metadata:     %{status: :ok | :blocked | :error, runtime_target: atom(), blocked_count: non_neg_integer(), reason: atom() | nil}

      [:ethercat, :master, :dc_lock, :decision]
        measurements: %{}
        metadata:     %{transition: :lost | :regained, policy: atom(), outcome: atom(), lock_state: atom(), max_sync_diff_ns: non_neg_integer() | nil}

      [:ethercat, :master, :slave_fault, :changed]
        measurements: %{}
        metadata:     %{slave: atom(), from: atom() | nil, to: atom() | nil, from_detail: atom() | nil, to_detail: atom() | nil}

  ### Slave fault events

      [:ethercat, :slave, :crashed]
        measurements: %{}
        metadata:     %{slave: atom(), reason: atom()}

      [:ethercat, :slave, :health, :fault]
        measurements: %{al_state: 1 | 2 | 4 | 8, error_code: non_neg_integer()}
        metadata:     %{slave: atom(), station: non_neg_integer()}

      [:ethercat, :slave, :down]
        measurements: %{}
        metadata:     %{slave: atom(), station: non_neg_integer(), reason: atom()}

      [:ethercat, :slave, :startup, :retry]
        measurements: %{retry_count: pos_integer(), retry_delay_ms: pos_integer()}
        metadata:     %{slave: atom(), station: non_neg_integer(), phase: atom(), reason: atom()}

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

  alias EtherCAT.Utils

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
  def frame_sent(link, endpoint, port, size, tx_timestamp \\ nil) do
    execute(
      [:ethercat, :bus, :frame, :sent],
      %{size: size, tx_timestamp: tx_timestamp},
      %{link: link, endpoint: endpoint, port: port}
    )
  end

  @doc false
  def frame_received(link, endpoint, port, size, rx_timestamp \\ nil) do
    execute(
      [:ethercat, :bus, :frame, :received],
      %{size: size, rx_timestamp: rx_timestamp},
      %{link: link, endpoint: endpoint, port: port}
    )
  end

  @doc false
  def bus_topology_changed(circuit, from, to, observation) do
    execute(
      [:ethercat, :bus, :topology, :changed],
      %{observed_at: observation.completed_at},
      %{
        circuit: circuit,
        from: from,
        to: to,
        path_shape: observation.path_shape,
        status: observation.status
      }
    )
  end

  @doc false
  def frame_dropped(link, size, reason) do
    execute(
      [:ethercat, :bus, :frame, :dropped],
      %{size: size},
      %{link: link, reason: Utils.reason_kind(reason)}
    )
  end

  @doc false
  def link_down(link, endpoint, reason) do
    execute(
      [:ethercat, :bus, :link, :down],
      %{},
      %{link: link, endpoint: endpoint, reason: Utils.reason_kind(reason)}
    )
  end

  @doc false
  def link_reconnected(link, endpoint) do
    execute(
      [:ethercat, :bus, :link, :reconnected],
      %{},
      %{link: link, endpoint: endpoint}
    )
  end

  @doc false
  def link_health_changed(link, port, from, to) do
    execute(
      [:ethercat, :bus, :link, :health, :changed],
      %{},
      %{link: link, port: port, from: from, to: to}
    )
  end

  @doc false
  def redundant_exchange_timeout(
        link,
        detail,
        arrival_classes,
        pri_sent?,
        sec_sent?,
        consecutive_timeouts
      ) do
    execute(
      [:ethercat, :bus, :link, :exchange, :timeout],
      %{
        arrival_count: length(arrival_classes),
        consecutive_timeouts: consecutive_timeouts
      },
      %{
        link: link,
        detail: detail,
        arrival_classes: arrival_classes,
        pri_sent: pri_sent?,
        sec_sent: sec_sent?
      }
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
  def dc_runtime_state_changed(from_state, to_state, reason, consecutive_failures) do
    execute(
      [:ethercat, :dc, :runtime, :state, :changed],
      %{},
      %{
        from: from_state,
        to: to_state,
        reason: normalize_optional_reason(reason),
        consecutive_failures: consecutive_failures
      }
    )
  end

  @doc false
  def domain_cycle_done(domain_id, duration_us, cycle_count, completed_at_us) do
    execute(
      [:ethercat, :domain, :cycle, :done],
      %{duration_us: duration_us, cycle_count: cycle_count, completed_at_us: completed_at_us},
      %{domain: domain_id}
    )
  end

  @doc false
  def domain_cycle_invalid(domain_id, total_invalid_count, reason, invalid_at_us) do
    cycle_reason = Utils.cycle_reason_metadata(reason)

    execute(
      [:ethercat, :domain, :cycle, :invalid],
      %{total_invalid_count: total_invalid_count, invalid_at_us: invalid_at_us},
      Map.put(cycle_reason, :domain, domain_id)
    )
  end

  @doc false
  def domain_cycle_transport_miss(
        domain_id,
        consecutive_miss_count,
        total_invalid_count,
        reason,
        invalid_at_us
      ) do
    cycle_reason = Utils.cycle_reason_metadata(reason)

    execute(
      [:ethercat, :domain, :cycle, :transport_miss],
      %{
        consecutive_miss_count: consecutive_miss_count,
        total_invalid_count: total_invalid_count,
        invalid_at_us: invalid_at_us
      },
      Map.put(cycle_reason, :domain, domain_id)
    )
  end

  @doc false
  def domain_stopped(domain_id, reason) do
    execute(
      [:ethercat, :domain, :stopped],
      %{},
      %{domain: domain_id, reason: Utils.reason_kind(reason)}
    )
  end

  @doc false
  def domain_crashed(domain_id, reason) do
    execute(
      [:ethercat, :domain, :crashed],
      %{},
      %{domain: domain_id, reason: Utils.reason_kind(reason)}
    )
  end

  @doc false
  def master_state_changed(from_state, to_state, public_state, runtime_target) do
    execute(
      [:ethercat, :master, :state, :changed],
      %{},
      %{
        from: from_state,
        to: to_state,
        public_state: public_state,
        runtime_target: runtime_target
      }
    )
  end

  @doc false
  def master_startup_bus_stable(slave_count) do
    execute([:ethercat, :master, :startup, :bus_stable], %{slave_count: slave_count}, %{})
  end

  @doc false
  def master_configuration_result(status, duration_ms, slave_count, runtime_target, reason) do
    execute(
      [:ethercat, :master, :configuration, :result],
      %{duration_ms: duration_ms},
      %{
        status: status,
        slave_count: slave_count,
        runtime_target: runtime_target,
        reason: normalize_optional_reason(reason)
      }
    )
  end

  @doc false
  def master_activation_result(status, duration_ms, runtime_target, blocked_count, reason) do
    execute(
      [:ethercat, :master, :activation, :result],
      %{duration_ms: duration_ms},
      %{
        status: status,
        runtime_target: runtime_target,
        blocked_count: blocked_count,
        reason: normalize_optional_reason(reason)
      }
    )
  end

  @doc false
  def master_dc_lock_decision(transition, policy, outcome, lock_state, max_sync_diff_ns) do
    execute(
      [:ethercat, :master, :dc_lock, :decision],
      %{},
      %{
        transition: transition,
        policy: policy,
        outcome: outcome,
        lock_state: lock_state,
        max_sync_diff_ns: max_sync_diff_ns
      }
    )
  end

  @doc false
  def master_slave_fault_changed(slave_name, from_fault, to_fault) do
    execute(
      [:ethercat, :master, :slave_fault, :changed],
      %{},
      %{
        slave: slave_name,
        from: Utils.fault_kind(from_fault),
        to: Utils.fault_kind(to_fault),
        from_detail: Utils.fault_detail(from_fault),
        to_detail: Utils.fault_detail(to_fault)
      }
    )
  end

  @doc false
  def slave_crashed(slave_name, reason) do
    execute(
      [:ethercat, :slave, :crashed],
      %{},
      %{slave: slave_name, reason: Utils.reason_kind(reason)}
    )
  end

  @doc false
  def slave_health_fault(slave_name, station, al_state, error_code) do
    execute(
      [:ethercat, :slave, :health, :fault],
      %{al_state: al_state, error_code: error_code},
      %{slave: slave_name, station: station}
    )
  end

  @doc false
  def slave_down(slave_name, station, reason) do
    execute(
      [:ethercat, :slave, :down],
      %{},
      %{slave: slave_name, station: station, reason: Utils.reason_kind(reason)}
    )
  end

  @doc false
  def slave_startup_retry(slave_name, station, phase, reason, retry_count, retry_delay_ms) do
    execute(
      [:ethercat, :slave, :startup, :retry],
      %{retry_count: retry_count, retry_delay_ms: retry_delay_ms},
      %{slave: slave_name, station: station, phase: phase, reason: Utils.reason_kind(reason)}
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
    [:ethercat, :bus, :link, :down],
    [:ethercat, :bus, :link, :reconnected],
    [:ethercat, :bus, :link, :health, :changed],
    [:ethercat, :bus, :link, :exchange, :timeout],
    [:ethercat, :dc, :tick],
    [:ethercat, :dc, :sync_diff, :observed],
    [:ethercat, :dc, :lock, :changed],
    [:ethercat, :dc, :runtime, :state, :changed],
    [:ethercat, :domain, :cycle, :done],
    [:ethercat, :domain, :cycle, :invalid],
    [:ethercat, :domain, :cycle, :transport_miss],
    [:ethercat, :domain, :stopped],
    [:ethercat, :domain, :crashed],
    [:ethercat, :master, :state, :changed],
    [:ethercat, :master, :startup, :bus_stable],
    [:ethercat, :master, :configuration, :result],
    [:ethercat, :master, :activation, :result],
    [:ethercat, :master, :dc_lock, :decision],
    [:ethercat, :master, :slave_fault, :changed],
    [:ethercat, :slave, :crashed],
    [:ethercat, :slave, :health, :fault],
    [:ethercat, :slave, :down],
    [:ethercat, :slave, :startup, :retry]
  ]

  @event_index @all_events |> Enum.with_index() |> Map.new()

  @doc """
  Return the canonical list of public EtherCAT telemetry events.

  This is the supported source of truth for external consumers that want to
  subscribe via `:telemetry.attach_many/4` without duplicating event names.

  ## Example

      :ok =
        :telemetry.attach_many(
          "ethercat-dashboard",
          EtherCAT.Telemetry.events(),
          &MyDashboard.handle_event/4,
          nil
        )
  """
  @spec events() :: [[atom()]]
  def events, do: @all_events

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
      events(),
      &__MODULE__.count_event/4,
      ref
    )

    :ok
  end

  @doc false
  def count_event(event, _measurements, _metadata, ref) do
    case @event_index do
      %{^event => idx} -> :counters.add(ref, idx + 1, 1)
      _ -> :ok
    end
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
        Enum.map(events(), fn event ->
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
      for idx <- 0..(length(events()) - 1) do
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

  defp normalize_optional_reason(nil), do: nil
  defp normalize_optional_reason(reason), do: Utils.reason_kind(reason)
end
