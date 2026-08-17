defmodule EtherCAT.Slave.FSM do
  @moduledoc false

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.Domain
  alias EtherCAT.Slave
  alias EtherCAT.Slave.Mailbox
  alias EtherCAT.Slave.Runtime.Bootstrap
  alias EtherCAT.Slave.Runtime.Configuration
  alias EtherCAT.Slave.Runtime.DCSignals
  alias EtherCAT.Slave.Runtime.Health
  alias EtherCAT.Slave.Runtime.Notifications
  alias EtherCAT.Slave.Runtime.Outputs
  alias EtherCAT.Slave.Runtime.Samples
  alias EtherCAT.Slave.Runtime.Signals
  alias EtherCAT.Slave.Runtime.Transition

  @al_codes %{init: 0x01, preop: 0x02, bootstrap: 0x03, safeop: 0x04, op: 0x08}

  @paths %{
    {:init, :preop} => [:preop],
    {:init, :bootstrap} => [:bootstrap],
    {:init, :safeop} => [:preop, :safeop],
    {:init, :op} => [:preop, :safeop, :op],
    {:bootstrap, :init} => [:init],
    {:preop, :safeop} => [:safeop],
    {:preop, :op} => [:safeop, :op],
    {:preop, :init} => [:init],
    {:safeop, :op} => [:op],
    {:safeop, :preop} => [:preop],
    {:safeop, :init} => [:init],
    {:op, :safeop} => [:safeop],
    {:op, :preop} => [:safeop, :preop],
    {:op, :init} => [:safeop, :preop, :init]
  }

  @poll_limit 200
  @poll_interval_ms 1
  @transition_opts [
    al_codes: @al_codes,
    poll_limit: @poll_limit,
    poll_interval_ms: @poll_interval_ms,
    post_transition: &Configuration.post_transition/2
  ]

  @doc "Start a Slave gen_statem."
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    # Register by name (atom) for lib user API
    reg_name = {:via, Registry, {EtherCAT.Registry, {:slave, name}}}
    :gen_statem.start_link(reg_name, __MODULE__, opts, [])
  end

  # -- :gen_statem callbacks -------------------------------------------------

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(opts) do
    Logger.metadata(
      component: :slave,
      slave: Keyword.fetch!(opts, :name),
      station: Keyword.fetch!(opts, :station)
    )

    opts
    |> new_slave_state()
    |> initialize_to_preop()
  end

  # -- State enter -----------------------------------------------------------

  @impl true
  def handle_event(:enter, old, :init, data) do
    Notifications.state_changed(data, old, :init)
    :keep_state_and_data
  end

  def handle_event(:enter, old, :preop, data) do
    Notifications.state_changed(data, old, :preop)
    {:keep_state_and_data, health_poll_actions(data)}
  end

  def handle_event(:enter, old, :safeop, data) do
    Notifications.state_changed(data, old, :safeop)
    {:keep_state_and_data, health_poll_actions(data)}
  end

  def handle_event(:enter, old, :op, data) do
    Notifications.state_changed(data, old, :op)
    {:keep_state_and_data, latch_poll_actions(data) ++ health_poll_actions(data)}
  end

  def handle_event(:enter, old, :bootstrap, data) do
    Notifications.state_changed(data, old, :bootstrap)
    :keep_state_and_data
  end

  # -- Spec init → preop sequence -------------------------------------------

  @auto_advance_retry_ms 200

  def handle_event({:timeout, :auto_advance}, nil, :init, data) do
    case initialize_to_preop(data) do
      {:ok, :init, new_data, actions} -> {:keep_state, new_data, actions}
      {:ok, :preop, new_data, []} -> {:next_state, :preop, new_data}
    end
  end

  # -- ESM API calls ---------------------------------------------------------

  def handle_event({:call, from}, event, state, data) do
    handle_call(from, event, state, data)
  end

  # -- Domain input change notification (sent by Domain on cycle) ------------

  # SM-grouped key: {domain_id, {:sm, idx}} — unpack per-signal bits and dispatch.
  def handle_event(
        :info,
        {:domain_inputs, domain_id, cycle_index, changes, sm_inputs, observed_at},
        _state,
        data
      ) do
    changed_signal_names =
      Enum.flat_map(changes, fn {{_slave_name, {:sm, _} = sm_key}, old_sm_bytes, new_sm_bytes} ->
        Signals.changed_input_names(data, domain_id, sm_key, old_sm_bytes, new_sm_bytes)
      end)

    {:keep_state,
     Samples.refresh(
       data,
       domain_id,
       cycle_index,
       sm_inputs,
       observed_at,
       changed_signal_names
     )}
  end

  def handle_event(:info, {:domain_status, status}, _state, data) do
    {:keep_state, Notifications.domain_status(data, status)}
  end

  def handle_event(:info, {:DOWN, ref, :process, pid, _reason}, _state, data) do
    case Map.get(data.subscriber_refs, pid) do
      ^ref ->
        {:keep_state, Signals.drop_subscriber(data, pid)}

      _ ->
        :keep_state_and_data
    end
  end

  def handle_event(:state_timeout, :latch_poll, :op, %{latch_poll_ms: poll_ms} = data)
      when is_integer(poll_ms) and poll_ms > 0 do
    DCSignals.poll_latches(data)
    {:keep_state_and_data, reschedule_latch_poll(poll_ms)}
  end

  # -- AL Status health poll (background check per spec §20.4) ---------------

  def handle_event({:timeout, :health_poll}, nil, :op, data) do
    Health.poll_op(data, transition_to: &transition_to/2, op_code: @al_codes.op)
  end

  def handle_event({:timeout, :health_poll}, nil, :preop, data) do
    Health.poll_preop(data)
  end

  def handle_event({:timeout, :health_poll}, nil, :safeop, data) do
    Health.poll_safeop(data)
  end

  # -- :down state (slave physically disconnected, polling for reconnect) -----

  def handle_event(:enter, old, :down, data) do
    Notifications.state_changed(data, old, :down)
    name = data.name
    station = data.station
    health_poll_ms = data.health_poll_ms

    Logger.info(
      "[Slave #{name}] entering :down — reconnect poll every #{health_poll_ms}ms",
      component: :slave,
      slave: name,
      station: station,
      event: :down_entered,
      health_poll_ms: health_poll_ms
    )

    {:keep_state_and_data, down_enter_actions(data)}
  end

  def handle_event({:timeout, :health_poll}, nil, :down, data) do
    Health.probe_reconnect(data, initialize_to_preop: &initialize_to_preop/1)
  end

  # -- Catch-all -------------------------------------------------------------

  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  # -- Call handling ---------------------------------------------------------

  defp handle_call(from, :state, state, _data) do
    {:keep_state_and_data, [{:reply, from, state}]}
  end

  defp handle_call(from, :identity, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.identity}]}
  end

  defp handle_call(from, :error, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.error_code}]}
  end

  defp handle_call(from, :info, state, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, info_snapshot(state, data)}}]}
  end

  defp handle_call(from, :samples, _state, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, Samples.all(data)}}]}
  end

  defp handle_call(from, :status, state, data) do
    status = EtherCAT.Slave.Status.from_runtime(state, data)
    {:keep_state_and_data, [{:reply, from, {:ok, status}}]}
  end

  defp handle_call(from, {:request, target}, state, _data) when state == target do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  defp handle_call(
         from,
         {:request, target},
         :preop,
         %{configuration_error: reason}
       )
       when target in [:safeop, :op] and not is_nil(reason) do
    {:keep_state_and_data, [{:reply, from, {:error, {:preop_configuration_failed, reason}}}]}
  end

  defp handle_call(from, {:request, target}, state, data) do
    case Map.get(@paths, {state, target}) do
      nil ->
        {:keep_state_and_data, [{:reply, from, {:error, :invalid_transition}}]}

      steps ->
        case walk_path(data, steps) do
          {:ok, new_data} ->
            {:next_state, target, %{new_data | state_reason: nil}, [{:reply, from, :ok}]}

          {:error, reason, new_data} ->
            {:keep_state, new_data, [{:reply, from, {:error, reason}}]}
        end
    end
  end

  defp handle_call(from, {:configure, opts}, :preop, data) do
    case Configuration.maybe_reconfigure_preop(data, opts) do
      {:ok, new_data} ->
        {:keep_state, new_data, [{:reply, from, :ok} | health_poll_reset_actions(new_data)]}

      {:error, reason, new_data} ->
        {:keep_state, new_data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp handle_call(from, {:configure, _opts}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_preop}}]}
  end

  defp handle_call(from, :retry_preop_configuration, :preop, %{configuration_error: nil}) do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  defp handle_call(from, :retry_preop_configuration, :preop, data) do
    case Configuration.retry_failed_preop(data) do
      {:ok, new_data} ->
        {:keep_state, new_data, [{:reply, from, :ok}]}

      {:error, reason, new_data} ->
        {:keep_state, new_data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp handle_call(from, :retry_preop_configuration, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_preop}}]}
  end

  defp handle_call(from, {:subscribe, signal_name, pid}, _state, data) do
    case Signals.subscribe_pid(data, signal_name, pid) do
      {:ok, new_data} ->
        {:keep_state, new_data, [{:reply, from, :ok}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp handle_call(from, {:subscribe_protocol, pid}, state, data) do
    new_data = Notifications.subscribe(data, pid)
    status = EtherCAT.Slave.Status.from_runtime(state, new_data)
    {:keep_state, new_data, [{:reply, from, {:ok, status, Samples.all(new_data)}}]}
  end

  defp handle_call(from, {:write_output, _signal_name, _value}, :down, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :slave_down}}]}
  end

  defp handle_call(from, {:write_output, signal_name, value}, _state, data) do
    case Outputs.write_signal(data, signal_name, value) do
      {:ok, new_data} ->
        {:keep_state, new_data, [{:reply, from, :ok}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp handle_call(from, {:read_input, signal_name}, _state, data) do
    {:keep_state_and_data, [{:reply, from, Signals.read_input(data, signal_name)}]}
  end

  defp handle_call(from, {:download_sdo, index, subindex, sdo_data}, state, data)
       when state in [:preop, :safeop, :op] do
    case Mailbox.download_sdo(data, index, subindex, sdo_data) do
      {:ok, new_data} ->
        {:keep_state, new_data, [{:reply, from, :ok}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp handle_call(from, {:download_sdo, _index, _subindex, _sdo_data}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :mailbox_not_ready}}]}
  end

  defp handle_call(from, {:upload_sdo, index, subindex}, state, data)
       when state in [:preop, :safeop, :op] do
    case Mailbox.upload_sdo(data, index, subindex) do
      {:ok, value, new_data} ->
        {:keep_state, new_data, [{:reply, from, {:ok, value}}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp handle_call(from, {:upload_sdo, _index, _subindex}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :mailbox_not_ready}}]}
  end

  # -- State data and snapshots ---------------------------------------------

  defp new_slave_state(opts) do
    %Slave{
      bus: Keyword.fetch!(opts, :bus),
      position: Keyword.get(opts, :position, 0),
      station: Keyword.fetch!(opts, :station),
      name: Keyword.fetch!(opts, :name),
      driver: Keyword.get(opts, :driver, EtherCAT.Driver.Default),
      config: Keyword.get(opts, :config, %{}),
      configuration_error: nil,
      esc_info: nil,
      dc_cycle_ns: Keyword.get(opts, :dc_cycle_ns),
      sync_config: Keyword.get(opts, :sync),
      mailbox_counter: 0,
      sii_sm_configs: [],
      sii_pdo_configs: [],
      process_data_request: Keyword.get(opts, :process_data, :none),
      latch_names: %{},
      active_latches: nil,
      latch_poll_ms: nil,
      health_poll_ms:
        Keyword.get(opts, :health_poll_ms, EtherCAT.Slave.Config.default_health_poll_ms()),
      startup_retry_phase: nil,
      startup_retry_count: 0,
      signal_registrations: %{},
      signal_registrations_by_sm: %{},
      output_domain_ids_by_sm: %{},
      output_sm_images: %{},
      subscriptions: %{},
      samples: %{},
      protocol_subscriptions: MapSet.new(),
      domain_statuses: %{},
      state_reason: nil,
      subscriber_refs: %{}
    }
    |> Samples.initialize()
  end

  defp info_snapshot(state, data) do
    attachments = Signals.attachment_summaries(data.signal_registrations)
    description = EtherCAT.Driver.Runtime.describe(data.driver, data.config || %{})

    %{
      name: data.name,
      station: data.station,
      al_state: state,
      identity: data.identity,
      esc: data.esc_info,
      driver: data.driver,
      coe: match?(%{recv_size: n} when n > 0, data.mailbox_config),
      available_fmmus: data.esc_info && data.esc_info.fmmu_count,
      used_fmmus: length(attachments),
      attachments: attachments,
      pdo_health: pdo_health_snapshot(data.signal_registrations),
      signals: signal_summaries(data.signal_registrations),
      configuration_error: data.configuration_error,
      protocol_status: EtherCAT.Slave.Status.from_runtime(state, data),
      device_type: description.device_type,
      endpoints: description.endpoints,
      samples: Samples.all(data)
    }
  end

  defp signal_summaries(nil), do: []

  defp signal_summaries(registrations) do
    registrations
    |> Enum.map(fn {name, reg} ->
      %{
        name: name,
        domain: reg.domain_id,
        direction: reg.direction,
        sm_index: elem(reg.sm_key, 1),
        bit_offset: reg.bit_offset,
        bit_size: reg.bit_size
      }
    end)
    |> Enum.sort_by(&{&1.sm_index, &1.bit_offset})
  end

  defp pdo_health_snapshot(nil), do: %{state: :unattached, domains: []}

  defp pdo_health_snapshot(registrations) when is_map(registrations) do
    domains =
      registrations
      |> Enum.map(fn {_name, registration} -> registration.domain_id end)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&domain_health_snapshot/1)

    %{state: aggregate_pdo_health(domains), domains: domains}
  end

  defp domain_health_snapshot(domain_id) do
    case Domain.info(domain_id) do
      {:ok, %{freshness: freshness}} ->
        Map.put(freshness, :id, domain_id)

      {:error, _reason} ->
        %{
          id: domain_id,
          state: :not_ready,
          refreshed_at_us: nil,
          age_us: nil,
          stale_after_us: nil
        }
    end
  end

  defp aggregate_pdo_health([]), do: :unattached

  defp aggregate_pdo_health(domains) do
    cond do
      Enum.any?(domains, &(&1.state == :stale)) -> :stale
      Enum.any?(domains, &(&1.state == :not_ready)) -> :not_ready
      true -> :fresh
    end
  end

  # -- Poll scheduling -------------------------------------------------------

  defp down_enter_actions(%{health_poll_ms: poll_ms}) do
    [Health.health_poll_action(poll_ms)]
  end

  defp reschedule_latch_poll(poll_ms), do: [{:state_timeout, poll_ms, :latch_poll}]

  defp latch_poll_actions(%{latch_poll_ms: poll_ms}) when is_integer(poll_ms) and poll_ms > 0 do
    reschedule_latch_poll(poll_ms)
  end

  defp latch_poll_actions(_data), do: []

  defp health_poll_actions(%{health_poll_ms: poll_ms})
       when is_integer(poll_ms) and poll_ms > 0 do
    [Health.health_poll_action(poll_ms)]
  end

  defp health_poll_actions(_data), do: []

  defp health_poll_reset_actions(%{health_poll_ms: poll_ms})
       when is_integer(poll_ms) and poll_ms > 0 do
    [Health.health_poll_action(poll_ms)]
  end

  defp health_poll_reset_actions(_data), do: [{{:timeout, :health_poll}, :cancel}]

  # -- Auto-advance helper (called from gen_statem init/1 and retry handler) -

  # Returns a normalized init result tuple: {:ok, state, data, actions}.
  # Reads SII EEPROM, arms mailbox SMs, and requests PREOP from the ESC.
  # Full PREOP setup (SDO config, FMMU registration, :slave_ready) runs
  # explicitly after the PREOP transition succeeds.
  defp initialize_to_preop(data) do
    Bootstrap.initialize_to_preop(
      data,
      auto_advance_retry_ms: @auto_advance_retry_ms,
      transition: &transition_to/2
    )
  end

  # -- Transition helpers ----------------------------------------------------

  defp walk_path(data, steps), do: Transition.walk_path(data, steps, @transition_opts)

  defp transition_to(data, target), do: Transition.transition_to(data, target, @transition_opts)
end
