defmodule EtherCAT.Slave do
  @moduledoc """
  EtherCAT State Machine (ESM) lifecycle for one physical slave device.

  One Slave process per named slave, registered under `{:slave, name}`.
  Manages INIT → PREOP → SAFEOP → OP transitions, mailbox configuration,
  process-data SM/FMMU setup, and DC signal programming.

  Typically driven by the master — use `EtherCAT.read_input/2`,
  `EtherCAT.write_output/3`, and `EtherCAT.subscribe/2` from the top-level API.
  Direct slave access via `request/2`, `info/1`, and `download_sdo/4` is also supported.
  """

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.{DC, Domain, Bus, Slave.ALTransition, Slave.CoE, Slave.SII}
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.Slave.ProcessDataPlan
  alias EtherCAT.Slave.ProcessDataPlan.DomainAttachment
  alias EtherCAT.Slave.ProcessDataPlan.SmGroup
  alias EtherCAT.Slave.Registers
  alias EtherCAT.Slave.Sync.Plan

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

  defstruct [
    :bus,
    :station,
    :name,
    :driver,
    :config,
    :error_code,
    :configuration_error,
    :identity,
    :esc_info,
    :mailbox_config,
    :mailbox_counter,
    # SYNC0 cycle time in ns — set from start_link opts; nil = no DC
    :dc_cycle_ns,
    # %EtherCAT.Slave.Sync.Config{} from slave config; nil = no slave-local sync intent
    :sync_config,
    # [{sm_index, phys_start, length, ctrl}] from SII category 0x0029
    :sii_sm_configs,
    # [%{index, direction, sm_index, bit_size, bit_offset}] from SII categories 0x0032/0x0033
    :sii_pdo_configs,
    # one of :none | {:all, domain_id} | [{signal_name, domain_id}]
    :process_data_request,
    # %{0|1, edge} => name for named latch delivery; empty map = latch polling disabled
    :latch_names,
    # [{latch_id, edge}] from sync_config.latches; nil = latch polling disabled
    :active_latches,
    # poll period for hardware latch event registers while in :op
    :latch_poll_ms,
    # poll period for AL Status background health check while in :op; nil = disabled
    :health_poll_ms,
    # %{signal_name => %{domain_id, sm_key, bit_offset, bit_size, direction, logical_address, sm_size}}
    :signal_registrations,
    # %{{domain_id, {:sm, idx}} => [{signal_name, %{bit_offset, bit_size}}]}
    :signal_registrations_by_sm,
    # %{{:sm, idx} => [domain_id]} for output attachments that must be kept coherent
    :output_domain_ids_by_sm,
    # %{{:sm, idx} => full_sm_bytes} canonical output image shared across attached domains
    :output_sm_images,
    # %{signal_name_or_latch_name => MapSet.t(pid)}
    :subscriptions,
    # %{pid => reference()}
    subscriber_refs: %{},
    # true once a disconnected slave responds again and is waiting for master-owned reconnect authorization
    reconnect_ready?: false
  ]

  # -- child_spec / start_link -----------------------------------------------

  @doc false
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary,
      shutdown: 5000
    }
  end

  @doc "Start a Slave gen_statem."
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    # Register by name (atom) for lib user API
    reg_name = {:via, Registry, {EtherCAT.Registry, {:slave, name}}}
    :gen_statem.start_link(reg_name, __MODULE__, opts, [])
  end

  # -- Public API ------------------------------------------------------------

  @doc """
  Subscribe `pid` to receive named signal or latch notifications.

  Messages arrive as:

    - `{:ethercat, :signal, slave_name, signal_name, decoded_value}`
    - `{:ethercat, :latch, slave_name, latch_name, timestamp_ns}`
  """
  @spec subscribe(atom(), atom(), pid()) :: :ok | {:error, :not_found}
  def subscribe(slave_name, signal_name, pid) do
    safe_call(slave_name, {:subscribe, signal_name, pid})
  end

  @doc """
  Encode `value`, stage it into the domain ETS output slot, and verify the
  staged bytes were written.

  This confirms the next process-image value held by the master. It does not
  prove the slave has already applied the value on hardware.
  """
  @spec write_output(atom(), atom(), term()) :: :ok | {:error, term()}
  def write_output(slave_name, signal_name, value) do
    safe_call(slave_name, {:write_output, signal_name, value})
  end

  @doc "Request an ESM state transition. Walks multi-step paths automatically."
  @spec request(atom(), atom()) :: :ok | {:error, term()}
  def request(slave_name, target) do
    safe_call(slave_name, {:request, target})
  end

  @doc false
  @spec authorize_reconnect(atom()) :: :ok | {:error, term()}
  def authorize_reconnect(slave_name), do: safe_call(slave_name, :authorize_reconnect)

  @doc """
  Apply PREOP-local configuration to an already discovered slave.

  Only valid while the slave is in `:preop`. This updates driver/config/process-data
  intent and reruns the local PREOP configuration sequence.
  """
  @spec configure(atom(), keyword()) :: :ok | {:error, term()}
  def configure(slave_name, opts) when is_list(opts) do
    safe_call(slave_name, {:configure, opts})
  end

  @doc false
  @spec cached_domain_offset(map(), SmGroup.t(), DomainAttachment.t()) ::
          {:ok, non_neg_integer()} | :error
  def cached_domain_offset(registrations, %SmGroup{} = sm_group, %DomainAttachment{} = attachment)
      when is_map(registrations) do
    attachment.registrations
    |> Enum.reduce_while({:ok, nil}, fn registration, {:ok, current_offset} ->
      case Map.get(registrations, registration.signal_name) do
        %{
          domain_id: domain_id,
          sm_key: sm_key,
          direction: direction,
          bit_offset: bit_offset,
          bit_size: bit_size,
          logical_address: logical_address,
          sm_size: sm_size
        }
        when domain_id == attachment.domain_id and sm_key == sm_group.sm_key and
               direction == sm_group.direction and bit_offset == registration.bit_offset and
               bit_size == registration.bit_size and is_integer(logical_address) and
               logical_address >= 0 and sm_size == sm_group.total_sm_size ->
          next_offset = current_offset || logical_address

          if next_offset == logical_address do
            {:cont, {:ok, next_offset}}
          else
            {:halt, :error}
          end

        _ ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, logical_address} when is_integer(logical_address) -> {:ok, logical_address}
      _ -> :error
    end
  end

  @doc "Return the current ESM state atom."
  @spec state(atom()) :: atom() | {:error, :not_found}
  def state(slave_name), do: safe_call(slave_name, :state)

  @doc "Return the identity map from SII EEPROM, or nil if not yet read."
  @spec identity(atom()) :: map() | nil | {:error, :not_found}
  def identity(slave_name), do: safe_call(slave_name, :identity)

  @doc "Return the last AL status code, or nil."
  @spec error(atom()) :: non_neg_integer() | nil | {:error, :not_found}
  def error(slave_name), do: safe_call(slave_name, :error)

  @doc """
  Return a diagnostic snapshot for the slave.

  Keys:
    - `:name` — slave atom name
    - `:station` — assigned bus station address
    - `:al_state` — current ESM state: `:init | :preop | :safeop | :op`
    - `:identity` — `%{vendor_id, product_code, revision, serial_number}` from SII, or `nil`
    - `:esc` — `%{fmmu_count, sm_count}` from ESC base registers, or `nil`
    - `:driver` — driver module in use
    - `:coe` — `true` if the slave has a mailbox (CoE-capable)
    - `:available_fmmus` — FMMUs supported by the ESC, or `nil`
    - `:used_fmmus` — count of active `{domain, SyncManager}` attachments
    - `:attachments` — list of `%{domain, sm_index, direction, logical_address, sm_size, signal_count, signals}`
    - `:signals` — list of `%{name, domain, direction, bit_offset, bit_size}` for registered signals
    - `:configuration_error` — last configuration failure atom, or `nil`
  """
  @spec info(atom()) :: {:ok, map()} | {:error, :not_found}
  def info(slave_name), do: safe_call(slave_name, :info)

  @doc """
  Read the decoded input value for an input signal together with its last update
  time. Equivalent to the value delivered via `subscribe/3` for normal
  process-data signals, but with freshness metadata.

  Returns `{:error, :not_ready}` until the first domain cycle completes.
  """
  @spec read_input(atom(), atom()) ::
          {:ok, %{value: term(), updated_at_us: integer() | nil}} | {:error, term()}
  def read_input(slave_name, signal_name) do
    safe_call(slave_name, {:read_input, signal_name})
  end

  @doc """
  Download a CoE SDO value via the mailbox SyncManagers.

  This is a blocking mailbox transaction. It requires the slave mailbox to be
  configured, so it is only valid from PREOP onward.
  """
  @spec download_sdo(atom(), non_neg_integer(), non_neg_integer(), binary()) ::
          :ok | {:error, term()}
  def download_sdo(slave_name, index, subindex, data)
      when is_binary(data) and byte_size(data) > 0 do
    safe_call(slave_name, {:download_sdo, index, subindex, data})
  end

  @doc """
  Upload a CoE SDO value via the mailbox SyncManagers.

  This is a blocking mailbox transaction. It requires the slave mailbox to be
  configured, so it is only valid from PREOP onward.
  """
  @spec upload_sdo(atom(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  def upload_sdo(slave_name, index, subindex) do
    safe_call(slave_name, {:upload_sdo, index, subindex})
  end

  # -- :gen_statem callbacks -------------------------------------------------

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(opts) do
    bus = Keyword.fetch!(opts, :bus)
    station = Keyword.fetch!(opts, :station)
    name = Keyword.fetch!(opts, :name)
    driver = Keyword.get(opts, :driver, EtherCAT.Slave.Driver.Default)
    config = Keyword.get(opts, :config, %{})
    dc_cycle_ns = Keyword.get(opts, :dc_cycle_ns)
    process_data_request = Keyword.get(opts, :process_data, :none)
    sync_config = Keyword.get(opts, :sync)
    health_poll_ms = Keyword.get(opts, :health_poll_ms)

    data = %__MODULE__{
      bus: bus,
      station: station,
      name: name,
      driver: driver,
      config: config,
      configuration_error: nil,
      esc_info: nil,
      dc_cycle_ns: dc_cycle_ns,
      sync_config: sync_config,
      mailbox_counter: 0,
      sii_sm_configs: [],
      sii_pdo_configs: [],
      process_data_request: process_data_request,
      latch_names: %{},
      active_latches: nil,
      latch_poll_ms: nil,
      health_poll_ms: health_poll_ms,
      reconnect_ready?: false,
      signal_registrations: %{},
      signal_registrations_by_sm: %{},
      output_domain_ids_by_sm: %{},
      output_sm_images: %{},
      subscriptions: %{},
      subscriber_refs: %{}
    }

    initialize_to_preop(data)
  end

  # -- State enter -----------------------------------------------------------

  @impl true
  def handle_event(:enter, _old, :init, _data), do: :keep_state_and_data

  def handle_event(:enter, _old, :preop, _data), do: :keep_state_and_data

  def handle_event(:enter, _old, :safeop, _data), do: :keep_state_and_data

  def handle_event(:enter, _old, :op, data) do
    actions = []

    actions =
      if data.latch_poll_ms do
        [{:state_timeout, data.latch_poll_ms, :latch_poll} | actions]
      else
        actions
      end

    actions =
      case data.health_poll_ms do
        ms when is_integer(ms) and ms > 0 ->
          [{{:timeout, :health_poll}, ms, nil} | actions]

        _ ->
          actions
      end

    {:keep_state_and_data, actions}
  end

  def handle_event(:enter, _old, :bootstrap, _data), do: :keep_state_and_data

  # -- Spec init → preop sequence -------------------------------------------

  @auto_advance_retry_ms 200

  def handle_event({:timeout, :auto_advance}, nil, :init, data) do
    case initialize_to_preop(data) do
      {:ok, :preop, new_data} -> {:next_state, :preop, new_data}
      {:ok, :init, new_data, actions} -> {:keep_state, new_data, actions}
    end
  end

  # -- ESM API calls ---------------------------------------------------------

  def handle_event({:call, from}, :state, state, _data) do
    {:keep_state_and_data, [{:reply, from, state}]}
  end

  def handle_event({:call, from}, :identity, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.identity}]}
  end

  def handle_event({:call, from}, :error, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.error_code}]}
  end

  def handle_event({:call, from}, :info, state, data) do
    signals =
      case data.signal_registrations do
        nil ->
          []

        regs ->
          regs
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

    attachments = attachment_summaries(data.signal_registrations)

    info = %{
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
      signals: signals,
      configuration_error: data.configuration_error
    }

    {:keep_state_and_data, [{:reply, from, {:ok, info}}]}
  end

  def handle_event({:call, from}, {:request, target}, state, _data) when state == target do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :authorize_reconnect, :down, %{reconnect_ready?: true} = data) do
    reconnect_data = %{data | reconnect_ready?: false}

    case initialize_to_preop(reconnect_data) do
      {:ok, next_state, new_data} ->
        {:next_state, next_state, %{new_data | reconnect_ready?: false}, [{:reply, from, :ok}]}

      {:ok, next_state, new_data, actions} ->
        {:next_state, next_state, %{new_data | reconnect_ready?: false},
         [{:reply, from, :ok} | actions]}
    end
  end

  def handle_event({:call, from}, :authorize_reconnect, :down, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_reconnected}}]}
  end

  def handle_event({:call, from}, :authorize_reconnect, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_down}}]}
  end

  def handle_event({:call, from}, {:request, target}, :preop, %{configuration_error: reason})
      when target in [:safeop, :op] and not is_nil(reason) do
    {:keep_state_and_data, [{:reply, from, {:error, {:preop_configuration_failed, reason}}}]}
  end

  def handle_event({:call, from}, {:request, target}, state, data) do
    case Map.get(@paths, {state, target}) do
      nil ->
        {:keep_state_and_data, [{:reply, from, {:error, :invalid_transition}}]}

      steps ->
        case walk_path(data, steps) do
          {:ok, new_data} ->
            {:next_state, target, new_data, [{:reply, from, :ok}]}

          {:error, reason, new_data} ->
            {:keep_state, new_data, [{:reply, from, {:error, reason}}]}
        end
    end
  end

  def handle_event({:call, from}, {:configure, opts}, :preop, data) do
    case maybe_reconfigure_preop(data, opts) do
      {:ok, new_data} ->
        {:keep_state, new_data, [{:reply, from, :ok}]}

      {:error, reason, new_data} ->
        {:keep_state, new_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_event({:call, from}, {:configure, _opts}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_preop}}]}
  end

  # -- Subscribe -------------------------------------------------------------

  def handle_event({:call, from}, {:subscribe, signal_name, pid}, _state, data) do
    {:keep_state, subscribe_pid(data, signal_name, pid), [{:reply, from, :ok}]}
  end

  # -- Set output ------------------------------------------------------------

  def handle_event({:call, from}, {:write_output, signal_name, value}, _state, data) do
    case Map.get(data.signal_registrations, signal_name) do
      nil ->
        {:keep_state_and_data, [{:reply, from, {:error, {:not_registered, signal_name}}}]}

      %{direction: :input} ->
        {:keep_state_and_data, [{:reply, from, {:error, {:not_output, signal_name}}}]}

      %{
        domain_id: domain_id,
        sm_key: sm_key,
        bit_offset: bit_offset,
        bit_size: bit_size,
        sm_size: sm_size,
        direction: :output
      } ->
        encoded = data.driver.encode_signal(signal_name, data.config, value)
        domain_ids = Map.get(data.output_domain_ids_by_sm || %{}, sm_key, [domain_id])

        result =
          with {:ok, current} <- current_output_sm_image(data, domain_id, sm_key, sm_size) do
            next_value = set_sm_bits(current, bit_offset, bit_size, encoded)

            case stage_output_sm_image(data, sm_key, domain_ids, next_value) do
              :ok ->
                {:ok, Map.put(data.output_sm_images, sm_key, next_value)}

              {:error, _} = err ->
                err
            end
          end

        case result do
          {:ok, next_output_sm_images} ->
            {:keep_state, %{data | output_sm_images: next_output_sm_images},
             [{:reply, from, :ok}]}

          {:error, reason} ->
            {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
        end
    end
  end

  # -- Read input ------------------------------------------------------------

  def handle_event({:call, from}, {:read_input, signal_name}, _state, data) do
    result =
      case Map.get(data.signal_registrations, signal_name) do
        nil ->
          {:error, {:not_registered, signal_name}}

        %{direction: :output} ->
          {:error, {:not_input, signal_name}}

        %{
          domain_id: domain_id,
          sm_key: sm_key,
          bit_offset: bit_offset,
          bit_size: bit_size,
          direction: :input
        } ->
          case Domain.sample(domain_id, {data.name, sm_key}) do
            {:ok, %{value: sm_bytes, updated_at_us: updated_at_us}} ->
              raw = extract_sm_bits(sm_bytes, bit_offset, bit_size)

              {:ok,
               %{
                 value: data.driver.decode_signal(signal_name, data.config, raw),
                 updated_at_us: updated_at_us
               }}

            {:error, _} = err ->
              err
          end
      end

    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def handle_event({:call, from}, {:download_sdo, index, subindex, sdo_data}, state, data)
      when state in [:preop, :safeop, :op] do
    case mailbox_download(data, index, subindex, sdo_data) do
      {:ok, new_data} ->
        {:keep_state, new_data, [{:reply, from, :ok}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_event({:call, from}, {:download_sdo, _index, _subindex, _sdo_data}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :mailbox_not_ready}}]}
  end

  def handle_event({:call, from}, {:upload_sdo, index, subindex}, state, data)
      when state in [:preop, :safeop, :op] do
    case mailbox_upload(data, index, subindex) do
      {:ok, value, new_data} ->
        {:keep_state, new_data, [{:reply, from, {:ok, value}}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_event({:call, from}, {:upload_sdo, _index, _subindex}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :mailbox_not_ready}}]}
  end

  # -- Domain input change notification (sent by Domain on cycle) ------------

  # SM-grouped key: {domain_id, {:sm, idx}} — unpack per-signal bits and dispatch.
  def handle_event(
        :info,
        {:domain_input, domain_id, {_slave_name, {:sm, _} = sm_key}, old_sm_bytes, new_sm_bytes},
        _state,
        data
      ) do
    notifications =
      data.signal_registrations_by_sm
      |> Map.get({domain_id, sm_key}, [])
      |> Enum.reduce([], fn {signal_name, %{bit_offset: bit_offset, bit_size: bit_size}}, acc ->
        if signal_changed?(old_sm_bytes, new_sm_bytes, bit_offset, bit_size) do
          raw = extract_sm_bits(new_sm_bytes, bit_offset, bit_size)

          decoded =
            if data.driver != nil do
              data.driver.decode_signal(signal_name, data.config, raw)
            else
              raw
            end

          data.subscriptions
          |> Map.get(signal_name, MapSet.new())
          |> Enum.reduce(acc, fn pid, pid_acc ->
            [{pid, signal_name, decoded} | pid_acc]
          end)
        else
          acc
        end
      end)

    Enum.each(Enum.reverse(notifications), fn {pid, signal_name, decoded} ->
      send(pid, {:ethercat, :signal, data.name, signal_name, decoded})
    end)

    :keep_state_and_data
  end

  def handle_event(:info, {:DOWN, ref, :process, pid, _reason}, _state, data) do
    case Map.get(data.subscriber_refs, pid) do
      ^ref ->
        {:keep_state, drop_subscriber(data, pid)}

      _ ->
        :keep_state_and_data
    end
  end

  def handle_event(:state_timeout, :latch_poll, :op, data) do
    if data.active_latches do
      case Bus.transaction(
             data.bus,
             Transaction.fprd(data.station, Registers.dc_latch_event_status()),
             latch_poll_timeout_us(data)
           ) do
        {:ok, [%{data: <<latch0_status::8, latch1_status::8>>, wkc: wkc}]} when wkc > 0 ->
          dispatch_latch_events(data, latch0_status, latch1_status)

        _ ->
          :ok
      end
    end

    actions =
      if data.latch_poll_ms do
        [{:state_timeout, data.latch_poll_ms, :latch_poll}]
      else
        []
      end

    {:keep_state_and_data, actions}
  end

  # -- AL Status health poll (background check per spec §20.4) ---------------

  def handle_event({:timeout, :health_poll}, nil, :op, data) do
    # Use a realtime transaction so the health poll is not starved behind DC realtime queue.
    # The deadline (half of health_poll_ms) bounds the wait; {:error, :expired} is treated as a fault.
    deadline_us = data.health_poll_ms * 500

    case Bus.transaction(
           data.bus,
           Transaction.fprd(data.station, Registers.al_status()),
           deadline_us
         ) do
      {:ok, [%{data: al_bytes, wkc: wkc}]} when wkc > 0 ->
        {al_state, error_ind} = Registers.decode_al_status(al_bytes)

        if al_state != @al_codes.op or error_ind do
          error_code =
            case Bus.transaction(
                   data.bus,
                   Transaction.fprd(data.station, Registers.al_status_code()),
                   deadline_us
                 ) do
              {:ok, [%{data: <<code::16-little>>}]} -> code
              _ -> 0
            end

          EtherCAT.Telemetry.slave_health_fault(data.name, data.station, al_state, error_code)

          Logger.warning(
            "[Slave #{data.name}] AL fault detected: state=0x#{Integer.to_string(al_state, 16)} code=0x#{Integer.to_string(error_code, 16)} — retreating to safeop"
          )

          # Acknowledge error and request SafeOp — reuses existing transition_to/2 which
          # calls ack_error/2 internally if the error indication bit is set.
          case transition_to(data, :safeop) do
            {:ok, new_data} ->
              send(EtherCAT.Master, {:slave_retreated, data.name, :safeop})
              {:next_state, :safeop, new_data}

            {:error, reason, new_data} ->
              Logger.error("[Slave #{data.name}] SafeOp retreat failed: #{inspect(reason)}")
              {:keep_state, new_data, [{{:timeout, :health_poll}, data.health_poll_ms, nil}]}
          end
        else
          {:keep_state_and_data, [{{:timeout, :health_poll}, data.health_poll_ms, nil}]}
        end

      {:ok, [%{wkc: 0}]} ->
        # Slave not responding to addressed read — physically disconnected
        EtherCAT.Telemetry.slave_down(data.name, data.station)
        Logger.warning("[Slave #{data.name}] health poll: wkc=0 — disconnected, entering :down")
        send(EtherCAT.Master, {:slave_down, data.name})
        {:next_state, :down, data}

      {:error, reason} ->
        # Bus-level failure — entire segment unreachable
        EtherCAT.Telemetry.slave_down(data.name, data.station)

        Logger.warning(
          "[Slave #{data.name}] health poll: bus error #{inspect(reason)} — entering :down"
        )

        send(EtherCAT.Master, {:slave_down, data.name})
        {:next_state, :down, data}
    end
  end

  # -- :down state (slave physically disconnected, polling for reconnect) -----

  def handle_event(:enter, _old, :down, data) do
    Logger.info(
      "[Slave #{data.name}] entering :down — reconnect poll every #{data.health_poll_ms}ms"
    )

    {:keep_state, %{data | reconnect_ready?: false},
     [{{:timeout, :health_poll}, data.health_poll_ms, nil}]}
  end

  def handle_event({:timeout, :health_poll}, nil, :down, %{reconnect_ready?: false} = data) do
    deadline_us = data.health_poll_ms * 500

    case Bus.transaction(
           data.bus,
           Transaction.fprd(data.station, Registers.al_status()),
           deadline_us
         ) do
      {:ok, [%{wkc: wkc}]} when wkc > 0 ->
        Logger.info("[Slave #{data.name}] reconnected — waiting for master authorization")
        send(EtherCAT.Master, {:slave_reconnected, data.name})

        {:keep_state, %{data | reconnect_ready?: true},
         [{{:timeout, :health_poll}, data.health_poll_ms, nil}]}

      _ ->
        {:keep_state_and_data, [{{:timeout, :health_poll}, data.health_poll_ms, nil}]}
    end
  end

  def handle_event({:timeout, :health_poll}, nil, :down, %{reconnect_ready?: true} = data) do
    deadline_us = data.health_poll_ms * 500

    case Bus.transaction(
           data.bus,
           Transaction.fprd(data.station, Registers.al_status()),
           deadline_us
         ) do
      {:ok, [%{wkc: wkc}]} when wkc > 0 ->
        {:keep_state_and_data, [{{:timeout, :health_poll}, data.health_poll_ms, nil}]}

      _ ->
        {:keep_state, %{data | reconnect_ready?: false},
         [{{:timeout, :health_poll}, data.health_poll_ms, nil}]}
    end
  end

  # -- Catch-all -------------------------------------------------------------

  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  # -- Auto-advance helper (called from gen_statem init/1 and retry handler) -

  # Returns a gen_statem init tuple: {:ok, state, data} or {:ok, state, data, actions}.
  # Reads SII EEPROM, arms mailbox SMs, and requests PREOP from the ESC.
  # Full PREOP setup (SDO config, FMMU registration, :slave_ready) runs
  # explicitly after the PREOP transition succeeds.
  defp initialize_to_preop(data) do
    case transition_to(data, :init) do
      {:ok, init_data} ->
        read_sii_and_enter_preop(init_data)

      {:error, reason, init_data} ->
        Logger.warning(
          "[Slave #{data.name}] init transition failed: #{inspect(reason)} — retrying in #{@auto_advance_retry_ms} ms"
        )

        {:ok, :init, init_data, [{{:timeout, :auto_advance}, @auto_advance_retry_ms, nil}]}
    end
  end

  defp read_sii_and_enter_preop(data) do
    t0 = System.monotonic_time(:millisecond)

    Logger.debug(
      "[Slave #{data.name}] init: reading SII (station=0x#{Integer.to_string(data.station, 16)})"
    )

    case read_sii(data.bus, data.station) do
      {:ok, esc_info, identity, mailbox_config, sm_configs, pdo_configs} ->
        sii_ms = System.monotonic_time(:millisecond) - t0

        Logger.debug(
          "[Slave #{data.name}] SII ok in #{sii_ms}ms — " <>
            "vendor=0x#{Integer.to_string(identity.vendor_id, 16)} " <>
            "product=0x#{Integer.to_string(identity.product_code, 16)} " <>
            "fmmus=#{esc_info.fmmu_count} " <>
            "mbx_recv=#{mailbox_config.recv_size} pdos=#{length(pdo_configs)}"
        )

        new_data = %{
          data
          | identity: identity,
            esc_info: esc_info,
            mailbox_config: mailbox_config,
            sii_sm_configs: sm_configs,
            sii_pdo_configs: pdo_configs
        }

        # Configure mailbox SMs (SM0 recv + SM1 send) while still in INIT so that
        # the slave's PDI finds them armed when it enters PREOP.
        Logger.debug("[Slave #{data.name}] init: setting up mailbox SMs")

        case configure_mailbox_sync_managers(new_data) do
          :ok ->
            Logger.debug("[Slave #{data.name}] init: transitioning to PREOP")

            case transition_to(new_data, :preop) do
              {:ok, new_data2} ->
                preop_ms = System.monotonic_time(:millisecond) - t0
                Logger.debug("[Slave #{data.name}] init: PREOP reached in #{preop_ms}ms total")
                {:ok, :preop, new_data2}

              {:error, reason, new_data2} ->
                Logger.warning(
                  "[Slave #{data.name}] preop failed: #{inspect(reason)} — retrying in #{@auto_advance_retry_ms} ms"
                )

                {:ok, :init, new_data2,
                 [{{:timeout, :auto_advance}, @auto_advance_retry_ms, nil}]}
            end

          {:error, reason} ->
            Logger.warning(
              "[Slave #{data.name}] mailbox SM setup failed: #{inspect(reason)} — retrying in #{@auto_advance_retry_ms} ms"
            )

            {:ok, :init, new_data, [{{:timeout, :auto_advance}, @auto_advance_retry_ms, nil}]}
        end

      {:error, reason} ->
        Logger.warning(
          "[Slave #{data.name}] SII read failed: #{inspect(reason)} — retrying in #{@auto_advance_retry_ms} ms"
        )

        {:ok, :init, data, [{{:timeout, :auto_advance}, @auto_advance_retry_ms, nil}]}
    end
  end

  # -- PREOP configuration (called from :preop enter) -----------------------

  defp configure_preop_process_data(%{driver: nil} = data) do
    clear_configuration_error(data)
  end

  defp configure_preop_process_data(data) do
    invoke_driver(data, :on_preop)
    Logger.debug("[Slave #{data.name}] preop: running mailbox configuration")
    Logger.debug("[Slave #{data.name}] preop: configuring process-data SyncManagers/FMMUs")

    with {:ok, mailbox_data} <- run_mailbox_config(data),
         {:ok, requested_signals} <-
           ProcessDataPlan.normalize_request(
             data.process_data_request,
             mailbox_data.driver,
             mailbox_data.config
           ),
         :ok <- validate_subscription_names(requested_signals, mailbox_data.sync_config),
         {:ok, sm_groups} <-
           ProcessDataPlan.build(
             requested_signals,
             call_process_data_model(mailbox_data),
             mailbox_data.sii_pdo_configs,
             mailbox_data.sii_sm_configs
           ),
         :ok <- validate_fmmu_capacity(mailbox_data, sm_groups),
         {:ok, registrations} <- apply_process_data_groups(mailbox_data, sm_groups) do
      output_domain_ids_by_sm = build_output_domain_index(registrations)

      %{
        clear_configuration_error(mailbox_data)
        | signal_registrations: registrations,
          signal_registrations_by_sm: build_signal_registration_index(registrations),
          output_domain_ids_by_sm: output_domain_ids_by_sm,
          output_sm_images:
            build_output_image_index(mailbox_data, registrations, output_domain_ids_by_sm)
      }
    else
      {:error, reason} ->
        log_process_data_error(data, reason)
        %{data | configuration_error: reason}
    end
  end

  defp clear_configuration_error(data) do
    %{data | configuration_error: nil}
  end

  defp validate_subscription_names(_requested_signals, nil), do: :ok

  defp validate_subscription_names(requested_signals, %{latches: latches}) do
    latch_names = Map.keys(latches)

    case Enum.find(requested_signals, fn {signal_name, _domain_id} ->
           signal_name in latch_names
         end) do
      {signal_name, _domain_id} -> {:error, {:signal_name_conflicts_with_latch, signal_name}}
      nil -> :ok
    end
  end

  defp build_signal_registration_index(registrations) when is_map(registrations) do
    Enum.reduce(registrations, %{}, fn {signal_name, registration}, acc ->
      entry =
        {signal_name, %{bit_offset: registration.bit_offset, bit_size: registration.bit_size}}

      Map.update(acc, {registration.domain_id, registration.sm_key}, [entry], &[entry | &1])
    end)
  end

  defp attachment_summaries(nil), do: []

  defp attachment_summaries(registrations) when is_map(registrations) do
    registrations
    |> Enum.reduce(%{}, fn {signal_name, registration}, acc ->
      key = {registration.domain_id, registration.sm_key}

      Map.update(
        acc,
        key,
        %{
          domain: registration.domain_id,
          sm_index: elem(registration.sm_key, 1),
          direction: registration.direction,
          logical_address: Map.get(registration, :logical_address),
          sm_size: Map.get(registration, :sm_size),
          signals: [signal_name]
        },
        fn summary ->
          %{summary | signals: [signal_name | summary.signals]}
        end
      )
    end)
    |> Enum.map(fn {_key, summary} ->
      signals = summary.signals |> Enum.uniq() |> Enum.sort()
      Map.merge(summary, %{signal_count: length(signals), signals: signals})
    end)
    |> Enum.sort_by(&{&1.sm_index, &1.domain})
  end

  defp validate_fmmu_capacity(%{esc_info: %{fmmu_count: available_fmmus}}, sm_groups)
       when is_integer(available_fmmus) and available_fmmus >= 0 do
    required_fmmus =
      Enum.reduce(sm_groups, 0, fn %SmGroup{attachments: attachments}, acc ->
        acc + length(attachments)
      end)

    if required_fmmus <= available_fmmus do
      :ok
    else
      {:error, {:fmmu_limit_reached, required_fmmus, available_fmmus}}
    end
  end

  defp validate_fmmu_capacity(_data, _sm_groups), do: :ok

  defp build_output_domain_index(registrations) when is_map(registrations) do
    registrations
    |> Enum.reduce(%{}, fn
      {_signal_name, %{direction: :output, sm_key: sm_key, domain_id: domain_id}}, acc ->
        Map.update(acc, sm_key, MapSet.new([domain_id]), &MapSet.put(&1, domain_id))

      _, acc ->
        acc
    end)
    |> Enum.into(%{}, fn {sm_key, domain_ids} ->
      {sm_key, domain_ids |> Enum.sort() |> Enum.to_list()}
    end)
  end

  defp build_output_image_index(data, registrations, output_domain_ids_by_sm)
       when is_map(registrations) and is_map(output_domain_ids_by_sm) do
    Enum.reduce(output_domain_ids_by_sm, %{}, fn {sm_key, domain_ids}, acc ->
      sm_size =
        registrations
        |> Enum.find_value(fn
          {_signal_name, %{direction: :output, sm_key: ^sm_key, sm_size: sm_size}} -> sm_size
          _ -> nil
        end)

      image = read_existing_output_image(data, domain_ids, sm_key, sm_size)
      Map.put(acc, sm_key, image)
    end)
  end

  defp read_existing_output_image(_data, _domain_ids, _sm_key, nil), do: <<>>

  defp read_existing_output_image(data, domain_ids, sm_key, sm_size) do
    key = {data.name, sm_key}

    Enum.find_value(domain_ids, :binary.copy(<<0>>, sm_size), fn domain_id ->
      case Domain.read(domain_id, key) do
        {:ok, image} -> binary_pad(image, sm_size)
        {:error, _} -> nil
      end
    end)
  end

  defp current_output_sm_image(data, domain_id, sm_key, sm_size) do
    case Map.fetch(data.output_sm_images || %{}, sm_key) do
      {:ok, image} when byte_size(image) == sm_size -> {:ok, image}
      {:ok, image} -> {:ok, binary_pad(image, sm_size)}
      :error -> read_output_sm_image_from_domain(data, domain_id, sm_key, sm_size)
    end
  end

  defp read_output_sm_image_from_domain(data, domain_id, sm_key, sm_size) do
    case Domain.read(domain_id, {data.name, sm_key}) do
      {:ok, image} -> {:ok, binary_pad(image, sm_size)}
      {:error, _} = err -> err
    end
  end

  defp stage_output_sm_image(data, sm_key, domain_ids, next_value) do
    key = {data.name, sm_key}

    Enum.reduce_while(domain_ids, :ok, fn attached_domain_id, :ok ->
      with :ok <- Domain.write(attached_domain_id, key, next_value),
           {:ok, ^next_value} <- Domain.read(attached_domain_id, key) do
        {:cont, :ok}
      else
        {:ok, _other} -> {:halt, {:error, {:staging_verification_failed, attached_domain_id}}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp maybe_reconfigure_preop(%{signal_registrations: registrations} = data, opts)
       when map_size(registrations) > 0 do
    requested_driver = Keyword.get(opts, :driver, data.driver)
    requested_config = Keyword.get(opts, :config, data.config)
    requested_process_data = Keyword.get(opts, :process_data, data.process_data_request)
    requested_sync = Keyword.get(opts, :sync, data.sync_config)
    requested_health_poll_ms = Keyword.get(opts, :health_poll_ms, data.health_poll_ms)

    if requested_driver == data.driver and requested_config == data.config and
         requested_process_data == data.process_data_request do
      case apply_sync_only_reconfigure(data, requested_sync) do
        {:ok, new_data} ->
          {:ok, %{new_data | health_poll_ms: requested_health_poll_ms}}

        {:error, reason} ->
          {:error, reason, data}
      end
    else
      {:error, :already_configured, data}
    end
  end

  defp maybe_reconfigure_preop(data, opts) do
    updated_data = %{
      data
      | driver: Keyword.get(opts, :driver, data.driver),
        config: Keyword.get(opts, :config, data.config),
        process_data_request: Keyword.get(opts, :process_data, data.process_data_request),
        sync_config: Keyword.get(opts, :sync, data.sync_config),
        health_poll_ms: Keyword.get(opts, :health_poll_ms, data.health_poll_ms)
    }

    configured = configure_preop_process_data(updated_data)

    case configured.configuration_error do
      nil -> {:ok, configured}
      reason -> {:error, reason, configured}
    end
  end

  defp apply_sync_only_reconfigure(data, requested_sync)
       when requested_sync == data.sync_config do
    {:ok, data}
  end

  defp apply_sync_only_reconfigure(data, requested_sync) do
    updated_data = %{data | sync_config: requested_sync}

    case run_sync_mailbox_config(updated_data) do
      {:ok, _mailbox_data} ->
        {:ok, updated_data}

      {:error, reason} ->
        log_process_data_error(updated_data, reason)
        {:error, reason}
    end
  end

  defp subscribe_pid(data, signal_name, pid) do
    {subscriber_refs, pid_set} =
      ensure_subscriber_monitor(
        data.subscriber_refs,
        Map.get(data.subscriptions, signal_name, MapSet.new()),
        pid
      )

    %{
      data
      | subscriber_refs: subscriber_refs,
        subscriptions: Map.put(data.subscriptions, signal_name, pid_set)
    }
  end

  defp ensure_subscriber_monitor(subscriber_refs, current_set, pid) do
    refs =
      if Map.has_key?(subscriber_refs, pid) do
        subscriber_refs
      else
        Map.put(subscriber_refs, pid, Process.monitor(pid))
      end

    {refs, MapSet.put(current_set, pid)}
  end

  defp drop_subscriber(data, pid) do
    subscriptions =
      prune_subscription_pid(data.subscriptions, pid)

    %{
      data
      | subscriptions: subscriptions,
        subscriber_refs: Map.delete(data.subscriber_refs, pid)
    }
  end

  defp prune_subscription_pid(subscriptions, pid) do
    Enum.reduce(subscriptions, %{}, fn {key, pid_set}, acc ->
      next_set = MapSet.delete(pid_set, pid)

      if MapSet.size(next_set) == 0 do
        acc
      else
        Map.put(acc, key, next_set)
      end
    end)
  end

  defp apply_process_data_groups(data, sm_groups) do
    sm_groups
    |> Enum.reduce_while({:ok, data.signal_registrations, 0}, fn sm_group,
                                                                 {:ok, regs, fmmu_idx} ->
      case apply_process_data_group(data, sm_group, regs, fmmu_idx) do
        {:ok, new_regs, next_fmmu_idx} -> {:cont, {:ok, new_regs, next_fmmu_idx}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, registrations, _fmmu_idx} -> {:ok, registrations}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_process_data_group(data, %SmGroup{} = sm_group, regs, fmmu_idx) do
    with {:ok, attachment_offsets} <-
           register_process_data_domains(data, sm_group),
         :ok <- write_process_data_sync_manager(data, sm_group),
         :ok <- write_process_data_fmmus(data, sm_group, attachment_offsets, fmmu_idx),
         :ok <- activate_process_data_sync_manager(data, sm_group) do
      next_regs =
        Enum.reduce(attachment_offsets, regs, fn {attachment, offset}, acc ->
          register_domain_attachment(sm_group, attachment, acc, offset)
        end)

      {:ok, next_regs, fmmu_idx + length(attachment_offsets)}
    end
  end

  defp register_process_data_domains(data, %SmGroup{} = sm_group) do
    sm_group.attachments
    |> Enum.reduce_while({:ok, []}, fn attachment, {:ok, acc} ->
      case register_process_data_domain(data, sm_group, attachment) do
        {:ok, offset} -> {:cont, {:ok, [{attachment, offset} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, attachment_offsets} -> {:ok, Enum.reverse(attachment_offsets)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp register_process_data_domain(
         %{signal_registrations: registrations},
         %SmGroup{} = sm_group,
         %DomainAttachment{} = attachment
       )
       when map_size(registrations) > 0 do
    case cached_domain_offset(registrations, sm_group, attachment) do
      {:ok, offset} -> {:ok, offset}
      :error -> {:error, {:domain_reregister_required, sm_group.sm_index, attachment.domain_id}}
    end
  end

  defp register_process_data_domain(data, %SmGroup{} = sm_group, %DomainAttachment{} = attachment) do
    case Domain.register_pdo(
           attachment.domain_id,
           {data.name, sm_group.sm_key},
           sm_group.total_sm_size,
           sm_group.direction
         ) do
      {:ok, offset} -> {:ok, offset}
      {:error, reason} -> {:error, {:domain_register_failed, sm_group.sm_index, reason}}
    end
  end

  defp register_domain_attachment(
         %SmGroup{} = sm_group,
         %DomainAttachment{} = attachment,
         regs,
         logical_address
       ) do
    Enum.reduce(attachment.registrations, regs, fn registration, acc ->
      Map.put(acc, registration.signal_name, %{
        domain_id: attachment.domain_id,
        sm_key: sm_group.sm_key,
        direction: sm_group.direction,
        bit_offset: registration.bit_offset,
        bit_size: registration.bit_size,
        logical_address: logical_address,
        sm_size: sm_group.total_sm_size
      })
    end)
  end

  defp write_process_data_fmmus(data, %SmGroup{} = sm_group, attachment_offsets, fmmu_idx) do
    attachment_offsets
    |> Enum.with_index(fmmu_idx)
    |> Enum.reduce_while(:ok, fn {{_attachment, offset}, idx}, :ok ->
      case write_process_data_fmmu(data, sm_group, idx, offset) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp write_process_data_sync_manager(data, %SmGroup{} = sm_group) do
    sm_reg =
      <<sm_group.phys::16-little, sm_group.total_sm_size::16-little, sm_group.ctrl::8, 0::8,
        0x00::8, 0::8>>

    case Bus.transaction(
           data.bus,
           Transaction.new()
           |> Transaction.fpwr(data.station, Registers.sm_activate(sm_group.sm_index, 0))
           |> Transaction.fpwr(data.station, Registers.sm(sm_group.sm_index, sm_reg))
         ) do
      {:ok, replies} ->
        ensure_expected_wkcs(replies, 1, {:sync_manager_write_failed, sm_group.sm_index})

      {:error, reason} ->
        {:error, {:sync_manager_write_failed, sm_group.sm_index, reason}}
    end
  end

  defp write_process_data_fmmu(data, %SmGroup{} = sm_group, fmmu_idx, offset) do
    fmmu_reg =
      <<offset::32-little, sm_group.total_sm_size::16-little, 0::8, 7::8,
        sm_group.phys::16-little, 0::8, sm_group.fmmu_type::8, 0x01::8, 0::24>>

    case Bus.transaction(
           data.bus,
           Transaction.fpwr(data.station, Registers.fmmu(fmmu_idx, fmmu_reg))
         ) do
      {:ok, replies} ->
        ensure_expected_wkcs(replies, 1, {:fmmu_write_failed, sm_group.sm_index})

      {:error, reason} ->
        {:error, {:fmmu_write_failed, sm_group.sm_index, reason}}
    end
  end

  defp activate_process_data_sync_manager(data, %SmGroup{} = sm_group) do
    case Bus.transaction(
           data.bus,
           Transaction.fpwr(data.station, Registers.sm_activate(sm_group.sm_index, 1))
         ) do
      {:ok, replies} ->
        ensure_expected_wkcs(replies, 1, {:sync_manager_activate_failed, sm_group.sm_index})

      {:error, reason} ->
        {:error, {:sync_manager_activate_failed, sm_group.sm_index, reason}}
    end
  end

  defp ensure_expected_wkcs(replies, expected_wkc, error_tag)
       when is_list(replies) and replies != [] and is_integer(expected_wkc) and expected_wkc >= 0 do
    if all_wkc_equal?(replies, expected_wkc) do
      :ok
    else
      {:error, error_tag}
    end
  end

  defp ensure_expected_wkcs(_replies, _expected_wkc, error_tag), do: {:error, error_tag}

  defp log_process_data_error(data, :invalid_process_data_request) do
    Logger.warning("[Slave #{data.name}] invalid process_data request")
  end

  defp log_process_data_error(data, {:signal_not_in_driver_model, signal_name}) do
    Logger.warning("[Slave #{data.name}] #{inspect(signal_name)} not in driver model")
  end

  defp log_process_data_error(data, {:invalid_signal_model, signal_name}) do
    Logger.warning(
      "[Slave #{data.name}] #{inspect(signal_name)} has an invalid signal declaration"
    )
  end

  defp log_process_data_error(data, {:pdo_not_in_sii, pdo_index}) do
    Logger.warning("[Slave #{data.name}] PDO 0x#{Integer.to_string(pdo_index, 16)} not in SII")
  end

  defp log_process_data_error(data, {:signal_range_out_of_bounds, signal_name, pdo_index}) do
    Logger.warning(
      "[Slave #{data.name}] #{inspect(signal_name)} exceeds PDO 0x#{Integer.to_string(pdo_index, 16)} bounds"
    )
  end

  defp log_process_data_error(data, {:sm_not_in_sii, sm_index}) do
    Logger.warning("[Slave #{data.name}] SM#{sm_index} not found in SII")
  end

  defp log_process_data_error(data, {:signal_name_conflicts_with_latch, signal_name}) do
    Logger.warning(
      "[Slave #{data.name}] #{inspect(signal_name)} conflicts with a configured latch name"
    )
  end

  defp log_process_data_error(data, {:mailbox_config_failed, index, subindex, reason}) do
    Logger.warning(
      "[Slave #{data.name}] mailbox step 0x#{Integer.to_string(index, 16)}:0x#{Integer.to_string(subindex, 16)} failed: #{inspect(reason)}"
    )
  end

  defp log_process_data_error(data, {:invalid_mailbox_step, step}) do
    Logger.warning("[Slave #{data.name}] invalid mailbox step: #{inspect(step)}")
  end

  defp log_process_data_error(data, {:domain_register_failed, sm_index, reason}) do
    Logger.warning(
      "[Slave #{data.name}] domain registration for SM#{sm_index} failed: #{inspect(reason)}"
    )
  end

  defp log_process_data_error(data, {:domain_reregister_required, sm_index, domain_id}) do
    Logger.warning(
      "[Slave #{data.name}] SM#{sm_index} in domain #{inspect(domain_id)} needs domain re-registration; reconnect self-heal cannot reuse the cached logical address"
    )
  end

  defp log_process_data_error(data, {:fmmu_limit_reached, required_fmmus, available_fmmus}) do
    Logger.warning(
      "[Slave #{data.name}] process-data layout needs #{required_fmmus} FMMUs but hardware supports #{available_fmmus}"
    )
  end

  defp log_process_data_error(data, {:sync_manager_write_failed, sm_index, reason}) do
    Logger.warning("[Slave #{data.name}] SM#{sm_index} write failed: #{inspect(reason)}")
  end

  defp log_process_data_error(data, {:sync_manager_activate_failed, sm_index, reason}) do
    Logger.warning("[Slave #{data.name}] SM#{sm_index} activation failed: #{inspect(reason)}")
  end

  defp log_process_data_error(data, {:fmmu_write_failed, sm_index, reason}) do
    Logger.warning("[Slave #{data.name}] FMMU write for SM#{sm_index} failed: #{inspect(reason)}")
  end

  defp log_process_data_error(data, {:sync_manager_write_failed, sm_index}) do
    Logger.warning("[Slave #{data.name}] SM#{sm_index} write failed")
  end

  defp log_process_data_error(data, {:sync_manager_activate_failed, sm_index}) do
    Logger.warning("[Slave #{data.name}] SM#{sm_index} activation failed")
  end

  defp log_process_data_error(data, {:fmmu_write_failed, sm_index}) do
    Logger.warning("[Slave #{data.name}] FMMU write for SM#{sm_index} failed")
  end

  defp log_process_data_error(data, {:error, reason}) do
    Logger.warning("[Slave #{data.name}] process-data configuration failed: #{inspect(reason)}")
  end

  defp log_process_data_error(data, reason) do
    Logger.warning("[Slave #{data.name}] process-data configuration failed: #{inspect(reason)}")
  end

  # -- Transition helpers ----------------------------------------------------

  defp walk_path(data, []), do: {:ok, data}

  defp walk_path(data, [next | rest]) do
    case transition_to(data, next) do
      {:ok, new_data} -> walk_path(new_data, rest)
      error -> error
    end
  end

  defp transition_to(data, target) do
    with {:ok, transitioned_data} <- do_transition(data, target) do
      post_transition(target, transitioned_data)
    end
  end

  defp do_transition(data, target) do
    code = Map.fetch!(@al_codes, target)
    Logger.debug("[Slave #{data.name}] AL → #{target} (code=0x#{Integer.to_string(code, 16)})")

    with {:ok, [%{wkc: 1}]} <-
           Bus.transaction(data.bus, Transaction.fpwr(data.station, Registers.al_control(code))) do
      poll_al(data, code, @poll_limit)
    else
      {:ok, [%{wkc: 0}]} ->
        Logger.warning("[Slave #{data.name}] AL → #{target}: no response (wkc=0)")
        {:error, :no_response, data}

      {:ok, [%{wkc: wkc}]} ->
        Logger.warning("[Slave #{data.name}] AL → #{target}: unexpected wkc=#{inspect(wkc)}")
        {:error, {:unexpected_wkc, wkc}, data}

      {:error, reason} ->
        Logger.warning("[Slave #{data.name}] AL → #{target} failed: #{inspect(reason)}")
        {:error, reason, data}
    end
  end

  defp post_transition(:preop, data) do
    new_data = configure_preop_process_data(data)

    Logger.debug(
      "[Slave #{data.name}] preop: ready (#{map_size(new_data.signal_registrations)} signal(s) registered)"
    )

    send(EtherCAT.Master, {:slave_ready, data.name, :preop})
    {:ok, new_data}
  end

  defp post_transition(:safeop, data) do
    invoke_driver(data, :on_safeop)
    configure_dc_signals(data)
  end

  defp post_transition(:op, data) do
    invoke_driver(data, :on_op)
    {:ok, data}
  end

  defp post_transition(_target, data), do: {:ok, data}

  defp poll_al(data, _code, 0), do: {:error, :transition_timeout, data}

  defp poll_al(data, code, n) do
    case Bus.transaction(data.bus, Transaction.fprd(data.station, Registers.al_status())) do
      {:ok, [%{data: status, wkc: wkc}]} when wkc > 0 ->
        cond do
          ALTransition.error_latched?(status) ->
            case ack_error(data, status) do
              {:ok, err_code, new_data} -> {:error, {:al_error, err_code}, new_data}
              {:error, reason, new_data} -> {:error, reason, new_data}
            end

          ALTransition.target_reached?(status, code) ->
            {:ok, data}

          true ->
            Process.sleep(@poll_interval_ms)
            poll_al(data, code, n - 1)
        end

      {:ok, [%{wkc: 0}]} ->
        {:error, :no_response, data}

      {:error, reason} ->
        {:error, reason, data}
    end
  end

  defp ack_error(data, status) do
    err_code =
      case Bus.transaction(data.bus, Transaction.fprd(data.station, Registers.al_status_code())) do
        {:ok, [%{data: <<c::16-little>>, wkc: wkc}]} when wkc > 0 -> c
        _ -> nil
      end

    new_data = %{data | error_code: err_code}
    ack_value = ALTransition.ack_value(status)

    case ALTransition.classify_ack_write(
           err_code,
           Bus.transaction(
             data.bus,
             Transaction.fpwr(data.station, Registers.al_control(ack_value))
           )
         ) do
      {:ok, acked_err_code} -> {:ok, acked_err_code, new_data}
      {:error, reason} -> {:error, reason, new_data}
    end
  end

  # -- SII -------------------------------------------------------------------

  defp read_sii(bus, station) do
    with {:ok, esc_info} <- read_esc_info(bus, station),
         {:ok, identity} <- SII.read_identity(bus, station),
         {:ok, mailbox_config} <- SII.read_mailbox_config(bus, station),
         {:ok, sm_configs} <- SII.read_sm_configs(bus, station),
         {:ok, pdo_configs} <- SII.read_pdo_configs(bus, station) do
      {:ok, esc_info, identity, mailbox_config, sm_configs, pdo_configs}
    end
  end

  defp read_esc_info(bus, station) do
    case Bus.transaction(
           bus,
           Transaction.new()
           |> Transaction.fprd(station, Registers.fmmu_count())
           |> Transaction.fprd(station, Registers.sm_count())
         ) do
      {:ok, [%{data: <<fmmu_count::8>>, wkc: 1}, %{data: <<sm_count::8>>, wkc: 1}]} ->
        {:ok, %{fmmu_count: fmmu_count, sm_count: sm_count}}

      {:ok, replies} ->
        case ensure_expected_wkcs(replies, 1, :esc_info_read_failed) do
          :ok -> {:error, {:esc_info_read_failed, :unexpected_reply}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:esc_info_read_failed, reason}}
    end
  end

  # -- Driver invocation -----------------------------------------------------

  defp call_process_data_model(data) do
    if function_exported?(data.driver, :process_data_model, 2) do
      data.driver.process_data_model(data.config, data.sii_pdo_configs)
    else
      data.driver.process_data_model(data.config)
    end
  end

  defp invoke_driver(data, cb), do: invoke_driver(data, cb, [])

  defp invoke_driver(%{driver: nil}, _cb, _args), do: :ok

  defp invoke_driver(data, cb, args) do
    arity = 2 + length(args)

    if function_exported?(data.driver, cb, arity) do
      apply(data.driver, cb, [data.name, data.config | args])
    end

    :ok
  end

  # -- PREOP mailbox configuration (called from :preop enter) ----------------

  defp run_mailbox_config(data) do
    mailbox_steps(data)
    |> Enum.reduce_while({:ok, data}, fn step, {:ok, current_data} ->
      case run_mailbox_step(current_data, step) do
        {:ok, next_data} -> {:cont, {:ok, next_data}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp run_sync_mailbox_config(data) do
    sync_mailbox_steps(data)
    |> Enum.reduce_while({:ok, data}, fn step, {:ok, current_data} ->
      case run_mailbox_step(current_data, step) do
        {:ok, next_data} -> {:cont, {:ok, next_data}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp mailbox_steps(%{driver: nil}), do: []

  defp mailbox_steps(data) do
    base_steps =
      if function_exported?(data.driver, :mailbox_config, 1) do
        data.driver.mailbox_config(data.config)
      else
        []
      end

    base_steps ++ sync_mailbox_steps(data)
  end

  defp sync_mailbox_steps(%{driver: nil}), do: []

  defp sync_mailbox_steps(data) do
    if not is_nil(data.sync_config) and function_exported?(data.driver, :sync_mode, 2) do
      data.driver.sync_mode(data.config, data.sync_config)
    else
      []
    end
  end

  defp run_mailbox_step(
         data,
         {:sdo_download, index, subindex, sdo_data}
       )
       when is_integer(index) and index >= 0 and is_integer(subindex) and subindex >= 0 and
              is_binary(sdo_data) and byte_size(sdo_data) > 0 do
    case write_mailbox_sdo(data, index, subindex, sdo_data) do
      {:ok, new_data} ->
        {:ok, new_data}

      {:error, reason} ->
        {:error, {:mailbox_config_failed, index, subindex, reason}}
    end
  end

  defp run_mailbox_step(_data, step), do: {:error, {:invalid_mailbox_step, step}}

  defp write_mailbox_sdo(data, index, subindex, sdo_data) do
    mailbox_download(data, index, subindex, sdo_data)
  end

  defp mailbox_download(%{mailbox_config: nil}, _index, _subindex, _sdo_data) do
    {:error, :mailbox_not_ready}
  end

  defp mailbox_download(data, index, subindex, sdo_data) do
    case CoE.download_sdo(
           data.bus,
           data.station,
           data.mailbox_config,
           data.mailbox_counter,
           index,
           subindex,
           sdo_data
         ) do
      {:ok, mailbox_counter} ->
        {:ok, %{data | mailbox_counter: mailbox_counter}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mailbox_upload(%{mailbox_config: nil}, _index, _subindex) do
    {:error, :mailbox_not_ready}
  end

  defp mailbox_upload(data, index, subindex) do
    case CoE.upload_sdo(
           data.bus,
           data.station,
           data.mailbox_config,
           data.mailbox_counter,
           index,
           subindex
         ) do
      {:ok, value, mailbox_counter} ->
        {:ok, value, %{data | mailbox_counter: mailbox_counter}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- DC signal configuration -----------------------------------------------

  defp configure_dc_signals(%{dc_cycle_ns: nil} = data), do: {:ok, clear_latch_config(data)}

  defp configure_dc_signals(data) do
    case data.sync_config do
      nil ->
        {:ok, clear_latch_config(data)}

      sync_config ->
        with {:ok, local_time_ns, sync_diff_ns} <- read_dc_sync_snapshot(data, sync_config),
             {:ok, plan} <-
               Plan.build(sync_config, data.dc_cycle_ns, local_time_ns, sync_diff_ns),
             {:ok, replies} <- send_dc_sync_plan(data, plan),
             :ok <- ensure_expected_wkcs(replies, 1, :dc_configuration_failed) do
          next_data = apply_dc_sync_plan(data, plan)

          Logger.debug(
            "[Slave #{data.name}] DC configured: mode=#{inspect(plan.mode)} cycle=#{inspect(plan.sync0_cycle_ns)}ns sync1_offset=#{plan.sync1_cycle_ns}ns start=#{inspect(plan.start_time_ns)} sync_diff=#{inspect(plan.sync_diff_ns)}ns latches=#{inspect(next_data.active_latches)}"
          )

          {:ok, next_data}
        else
          {:error, reason} ->
            {:error, reason, clear_latch_config(data)}
        end
    end
  end

  defp clear_latch_config(data) do
    %{data | active_latches: nil, latch_names: %{}, latch_poll_ms: nil}
  end

  defp dispatch_latch_events(data, latch0_status, latch1_status) do
    Enum.each(data.active_latches, fn {latch_id, edge} = key ->
      status = if latch_id == 0, do: latch0_status, else: latch1_status

      if latch_event_captured?(status, edge) do
        case read_latch_timestamp(data, latch_id, edge) do
          {:ok, timestamp_ns} ->
            case Map.get(data.latch_names, key) do
              nil ->
                :ok

              latch_name ->
                msg = {:ethercat, :latch, data.name, latch_name, timestamp_ns}

                data.subscriptions
                |> Map.get(latch_name, MapSet.new())
                |> Enum.each(&send(&1, msg))
            end

            invoke_driver(data, :on_latch, [latch_id, edge, timestamp_ns])

          :error ->
            :ok
        end
      end
    end)
  end

  defp latch_event_captured?(status, :pos) do
    <<_::6, _neg::1, pos::1>> = <<status>>
    pos == 1
  end

  defp latch_event_captured?(status, :neg) do
    <<_::6, neg::1, _pos::1>> = <<status>>
    neg == 1
  end

  defp read_latch_timestamp(data, latch_id, edge) do
    reg = latch_time_register(latch_id, edge)

    case Bus.transaction(
           data.bus,
           Transaction.fprd(data.station, reg),
           latch_poll_timeout_us(data)
         ) do
      {:ok, [%{data: <<timestamp_ns::64-little>>, wkc: wkc}]} when wkc > 0 ->
        {:ok, timestamp_ns}

      _ ->
        :error
    end
  end

  defp latch_time_register(0, :pos), do: Registers.dc_latch0_pos_time()
  defp latch_time_register(0, :neg), do: Registers.dc_latch0_neg_time()
  defp latch_time_register(1, :pos), do: Registers.dc_latch1_pos_time()
  defp latch_time_register(1, :neg), do: Registers.dc_latch1_neg_time()

  defp read_dc_sync_snapshot(_data, %{mode: mode}) when mode in [nil, :free_run],
    do: {:ok, nil, nil}

  defp read_dc_sync_snapshot(data, _sync_config) do
    snapshot_tx =
      Transaction.new()
      |> Transaction.fprd(data.station, Registers.dc_system_time())
      |> Transaction.fprd(data.station, Registers.dc_system_time_diff())

    case Bus.transaction(data.bus, snapshot_tx) do
      {:ok,
       [%{data: <<local_time_ns::64-little>>, wkc: 1}, %{data: <<raw_diff::32-little>>, wkc: 1}]} ->
        {:ok, local_time_ns, DC.decode_abs_sync_diff(raw_diff)}

      {:ok, [%{wkc: wkc}, _]} ->
        {:error,
         {:dc_configuration_failed, {:dc_snapshot_failed, :system_time, {:unexpected_wkc, wkc}}}}

      {:ok, [_, %{wkc: wkc}]} ->
        {:error,
         {:dc_configuration_failed, {:dc_snapshot_failed, :sync_diff, {:unexpected_wkc, wkc}}}}

      {:ok, replies} ->
        {:error,
         {:dc_configuration_failed, {:dc_snapshot_failed, {:unexpected_replies, replies}}}}

      {:error, reason} ->
        {:error, {:dc_configuration_failed, {:dc_snapshot_failed, reason}}}
    end
  end

  defp send_dc_sync_plan(data, %Plan{} = plan) do
    tx =
      Transaction.new()
      |> Transaction.fpwr(data.station, Registers.dc_activation(0x00))
      |> append_dc_sync_timing(data.station, plan)
      |> Transaction.fpwr(data.station, Registers.dc_latch0_control(plan.latch0_control))
      |> Transaction.fpwr(data.station, Registers.dc_latch1_control(plan.latch1_control))
      |> Transaction.fpwr(
        data.station,
        Registers.dc_cyclic_unit_control(plan.cyclic_unit_control)
      )
      |> Transaction.fpwr(data.station, Registers.dc_activation(plan.activation))

    case Bus.transaction(data.bus, tx) do
      {:ok, replies} -> {:ok, replies}
      {:error, reason} -> {:error, {:dc_configuration_failed, reason}}
    end
  end

  defp append_dc_sync_timing(tx, _station, %Plan{start_time_ns: nil}), do: tx

  defp append_dc_sync_timing(tx, station, %Plan{} = plan) do
    tx
    |> Transaction.fpwr(station, Registers.dc_sync0_cycle_time(plan.sync0_cycle_ns))
    |> Transaction.fpwr(station, Registers.dc_sync1_cycle_time(plan.sync1_cycle_ns))
    |> Transaction.fpwr(station, Registers.dc_pulse_length(plan.pulse_ns))
    |> Transaction.fpwr(station, Registers.dc_sync0_start_time(plan.start_time_ns))
  end

  defp apply_dc_sync_plan(data, %Plan{} = plan) do
    active_latches =
      case plan.active_latches do
        [] -> nil
        latches -> latches
      end

    latch_poll_ms =
      if active_latches do
        1
      else
        nil
      end

    %{
      data
      | active_latches: active_latches,
        latch_names: plan.latch_names,
        latch_poll_ms: latch_poll_ms
    }
  end

  defp ceil_div(value, divisor) when value <= 0 and divisor > 0, do: 0

  defp ceil_div(value, divisor) when is_integer(value) and is_integer(divisor) and divisor > 0 do
    div(value + divisor - 1, divisor)
  end

  defp latch_poll_timeout_us(%{latch_poll_ms: poll_ms, dc_cycle_ns: dc_cycle_ns})
       when is_integer(poll_ms) and poll_ms > 0 do
    poll_budget_us = div(poll_ms * 1_000 * 9, 10)

    cycle_budget_us =
      case dc_cycle_ns do
        cycle_ns when is_integer(cycle_ns) and cycle_ns > 0 ->
          div(cycle_ns * 9, 10)

        _ ->
          poll_budget_us
      end

    max(min(poll_budget_us, cycle_budget_us), 200)
  end

  defp latch_poll_timeout_us(_data), do: 900

  # -- Mailbox SM setup -------------------------------------------------------

  # Configure SM0 (recv, master→slave) and SM1 (send, slave→master) for
  # mailbox communication using addresses from SII EEPROM. Called while still
  # in INIT so the slave's PDI firmware finds them armed on PREOP entry.
  # No-op for slaves without a mailbox (recv_size == 0).
  defp configure_mailbox_sync_managers(%{mailbox_config: %{recv_size: 0}}), do: :ok

  defp configure_mailbox_sync_managers(data) do
    %{recv_offset: ro, recv_size: rs, send_offset: so, send_size: ss} = data.mailbox_config

    sm0 = <<ro::16-little, rs::16-little, 0x26::8, 0::8, 0x00::8, 0::8>>
    sm1 = <<so::16-little, ss::16-little, 0x22::8, 0::8, 0x00::8, 0::8>>

    case Bus.transaction(
           data.bus,
           Transaction.new()
           |> Transaction.fpwr(data.station, Registers.sm_activate(0, 0))
           |> Transaction.fpwr(data.station, Registers.sm_activate(1, 0))
           |> Transaction.fpwr(data.station, Registers.sm(0, sm0))
           |> Transaction.fpwr(data.station, Registers.sm(1, sm1))
           |> Transaction.fpwr(data.station, Registers.sm_activate(0, 1))
           |> Transaction.fpwr(data.station, Registers.sm_activate(1, 1))
         ) do
      {:ok, replies} ->
        ensure_expected_wkcs(replies, 1, :mailbox_sync_manager_setup_failed)

      {:error, reason} ->
        {:error, {:mailbox_sync_manager_setup_failed, reason}}
    end
  end

  # -- Bit-level SM packing helpers ------------------------------------------

  # Extract `bit_size` bits starting at `bit_offset` from `sm_bytes`.
  # Returns a binary of ceil(bit_size / 8) bytes with the value in the LSB.
  # Bit numbering is little-endian: bit 0 is the LSB of byte 0.
  defp extract_sm_bits(sm_bytes, bit_offset, bit_size) do
    if rem(bit_offset, 8) == 0 and rem(bit_size, 8) == 0 do
      # Byte-aligned fast path
      binary_part(sm_bytes, div(bit_offset, 8), div(bit_size, 8))
    else
      total_bits = byte_size(sm_bytes) * 8
      <<sm_value::unsigned-little-size(total_bits)>> = sm_bytes
      high_bits = total_bits - bit_offset - bit_size

      <<_::size(high_bits), raw::size(bit_size), _::size(bit_offset)>> =
        <<sm_value::size(total_bits)>>

      encoded_bits = ceil_div(bit_size, 8) * 8

      <<encoded_value::size(encoded_bits)>> =
        <<0::size(encoded_bits - bit_size), raw::size(bit_size)>>

      <<encoded_value::unsigned-little-size(encoded_bits)>>
    end
  end

  defp signal_changed?(:unset, _new_sm_bytes, _bit_offset, _bit_size), do: true

  defp signal_changed?(old_sm_bytes, new_sm_bytes, bit_offset, bit_size) do
    extract_sm_bits(old_sm_bytes, bit_offset, bit_size) !=
      extract_sm_bits(new_sm_bytes, bit_offset, bit_size)
  end

  defp binary_pad(data, size) when byte_size(data) >= size, do: binary_part(data, 0, size)
  defp binary_pad(data, size), do: data <> :binary.copy(<<0>>, size - byte_size(data))

  # Write `bit_size` bits from `encoded` into `sm_bytes` at `bit_offset`.
  # `encoded` is the driver's output binary; its LSB-aligned value is packed in.
  defp set_sm_bits(sm_bytes, _bit_offset, _bit_size, <<>>), do: sm_bytes

  defp set_sm_bits(sm_bytes, bit_offset, bit_size, encoded) do
    if rem(bit_offset, 8) == 0 and rem(bit_size, 8) == 0 do
      # Byte-aligned fast path
      byte_off = div(bit_offset, 8)
      byte_sz = div(bit_size, 8)
      total = byte_size(sm_bytes)
      padded = encoded <> :binary.copy(<<0>>, max(0, byte_sz - byte_size(encoded)))

      binary_part(sm_bytes, 0, byte_off) <>
        binary_part(padded, 0, byte_sz) <>
        binary_part(sm_bytes, byte_off + byte_sz, total - byte_off - byte_sz)
    else
      total_bits = byte_size(sm_bytes) * 8
      <<sm_value::unsigned-little-size(total_bits)>> = sm_bytes

      encoded_bits = byte_size(encoded) * 8
      <<encoded_value::unsigned-little-size(encoded_bits)>> = encoded

      field_value =
        if encoded_bits >= bit_size do
          <<_::size(encoded_bits - bit_size), field::size(bit_size)>> =
            <<encoded_value::size(encoded_bits)>>

          field
        else
          <<field::size(bit_size)>> =
            <<0::size(bit_size - encoded_bits), encoded_value::size(encoded_bits)>>

          field
        end

      high_bits = total_bits - bit_offset - bit_size

      <<high::size(high_bits), _::size(bit_size), low::size(bit_offset)>> =
        <<sm_value::size(total_bits)>>

      <<patched_value::size(total_bits)>> =
        <<high::size(high_bits), field_value::size(bit_size), low::size(bit_offset)>>

      <<patched_value::unsigned-little-size(total_bits)>>
    end
  end

  defp all_wkc_equal?(replies, expected_wkc) when is_list(replies) and is_integer(expected_wkc) do
    Enum.all?(replies, fn
      %{wkc: ^expected_wkc} -> true
      _ -> false
    end)
  end

  # -- Registry helpers -------------------------------------------------------

  defp safe_call(slave_name, msg) do
    try do
      :gen_statem.call(via(slave_name), msg)
    catch
      :exit, {:noproc, _} -> {:error, :not_found}
    end
  end

  defp via(slave_name), do: {:via, Registry, {EtherCAT.Registry, {:slave, slave_name}}}
end
