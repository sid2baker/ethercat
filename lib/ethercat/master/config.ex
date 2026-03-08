defmodule EtherCAT.Master.Config do
  @moduledoc false

  alias EtherCAT.DC.Config, as: DCConfig
  alias EtherCAT.Domain.Config, as: DomainConfig
  alias EtherCAT.Master.DomainPlan
  alias EtherCAT.Slave.Config, as: SlaveConfig
  alias EtherCAT.Slave.Driver.Default, as: DefaultSlaveDriver
  alias EtherCAT.Slave.Sync.Config, as: SyncConfig

  @default_base_station 0x1000
  @auto_logical_base_stride 2048
  @master_option_keys [:slaves, :domains, :base_station, :dc, :dc_cycle_ns, :frame_timeout_ms]
  @domain_option_keys [:id, :cycle_time_us, :miss_threshold]

  @type t :: %__MODULE__{
          base_station: non_neg_integer(),
          bus_opts: keyword(),
          dc_config: DCConfig.t() | nil,
          domain_config: [DomainPlan.t()],
          slave_config: [SlaveConfig.t()],
          frame_timeout_override_ms: pos_integer() | nil
        }

  defstruct base_station: @default_base_station,
            bus_opts: [],
            dc_config: %DCConfig{},
            domain_config: [],
            slave_config: [],
            frame_timeout_override_ms: nil

  @spec normalize_start_options(term()) :: {:ok, t()} | {:error, term()}
  def normalize_start_options(opts) when is_list(opts) do
    slave_config = Keyword.get(opts, :slaves, [])
    domain_config = Keyword.get(opts, :domains, [])
    base_station = Keyword.get(opts, :base_station, @default_base_station)
    dc = Keyword.get(opts, :dc, %DCConfig{})
    frame_timeout_override_ms = Keyword.get(opts, :frame_timeout_ms)

    with {:ok, _interface} <- Keyword.fetch(opts, :interface),
         :ok <- reject_legacy_start_options(opts),
         :ok <- validate_base_station(base_station),
         {:ok, dc_config} <- normalize_dc_config(dc),
         :ok <- validate_frame_timeout_override_ms(frame_timeout_override_ms),
         {:ok, normalized_domains} <- normalize_domain_configs(domain_config, dc_config),
         {:ok, allocated_domains} <- allocate_domain_logical_bases(normalized_domains),
         {:ok, normalized_slaves} <- normalize_slave_configs(slave_config) do
      {:ok,
       %__MODULE__{
         base_station: base_station,
         bus_opts: build_bus_start_opts(opts, frame_timeout_override_ms),
         dc_config: dc_config,
         domain_config: allocated_domains,
         slave_config: normalized_slaves,
         frame_timeout_override_ms: frame_timeout_override_ms
       }}
    else
      :error -> {:error, :missing_interface}
      {:error, _} = err -> err
    end
  end

  def normalize_start_options(_opts), do: {:error, :invalid_start_options}

  @spec normalize_runtime_slave_config(atom(), term(), SlaveConfig.t()) ::
          {:ok, SlaveConfig.t()} | {:error, term()}
  def normalize_runtime_slave_config(slave_name, %SlaveConfig{} = cfg, _current_config) do
    if cfg.name not in [nil, slave_name] do
      {:error, :name_mismatch}
    else
      validate_normalized_slave(%{cfg | name: slave_name})
    end
  end

  def normalize_runtime_slave_config(slave_name, opts, %SlaveConfig{} = current_config)
      when is_list(opts) do
    normalized =
      %SlaveConfig{
        name: slave_name,
        driver: normalize_slave_driver(Keyword.get(opts, :driver, current_config.driver)),
        config: Keyword.get(opts, :config, current_config.config),
        process_data: Keyword.get(opts, :process_data, current_config.process_data),
        target_state: Keyword.get(opts, :target_state, current_config.target_state),
        sync: Keyword.get(opts, :sync, current_config.sync),
        health_poll_ms: Keyword.get(opts, :health_poll_ms, current_config.health_poll_ms)
      }

    validate_normalized_slave(normalized)
  end

  def normalize_runtime_slave_config(_slave_name, _spec, _current_config) do
    {:error, :invalid_slave_config_update}
  end

  @spec effective_slave_config([SlaveConfig.t()], non_neg_integer()) ::
          {:ok, [SlaveConfig.t()]} | {:error, term()}
  def effective_slave_config([], bus_count), do: {:ok, dynamic_slave_configs(bus_count)}

  def effective_slave_config(slave_config, bus_count) when length(slave_config) <= bus_count do
    {:ok, Enum.take(slave_config, bus_count)}
  end

  def effective_slave_config(slave_config, bus_count) do
    {:error, {:configured_slaves_exceed_bus, length(slave_config), bus_count}}
  end

  @spec domain_ids([DomainPlan.t()]) :: [atom()]
  def domain_ids(domain_config) do
    Enum.map(domain_config, & &1.id)
  end

  @spec unknown_domain_ids([DomainPlan.t()], SlaveConfig.t()) :: [atom()]
  def unknown_domain_ids(domain_config, %SlaveConfig{} = slave_config) do
    known_domains = MapSet.new(domain_ids(domain_config))

    slave_config
    |> requested_domain_ids()
    |> Enum.reject(&MapSet.member?(known_domains, &1))
  end

  @spec activatable_slave_names([SlaveConfig.t()]) :: [atom()]
  def activatable_slave_names(slave_config) do
    slave_config
    |> Enum.filter(&(&1.target_state == :op))
    |> Enum.map(& &1.name)
  end

  @spec fetch_slave_config([SlaveConfig.t()], atom()) ::
          {:ok, SlaveConfig.t(), non_neg_integer()} | {:error, term()}
  def fetch_slave_config(slave_config, slave_name) do
    case Enum.find_index(slave_config, &(&1.name == slave_name)) do
      nil -> {:error, {:unknown_slave, slave_name}}
      idx -> {:ok, Enum.at(slave_config, idx), idx}
    end
  end

  @spec local_config_changed?(SlaveConfig.t(), SlaveConfig.t()) :: boolean()
  def local_config_changed?(%SlaveConfig{} = current_config, %SlaveConfig{} = updated_config) do
    current_config.driver != updated_config.driver or
      current_config.config != updated_config.config or
      current_config.process_data != updated_config.process_data or
      current_config.sync != updated_config.sync or
      current_config.health_poll_ms != updated_config.health_poll_ms
  end

  @spec domain_start_opts(DomainPlan.t()) :: keyword()
  def domain_start_opts(%DomainPlan{logical_base: logical_base} = config) do
    [
      id: config.id,
      cycle_time_us: config.cycle_time_us,
      miss_threshold: config.miss_threshold,
      logical_base: logical_base
    ]
  end

  defp build_bus_start_opts(opts, frame_timeout_override_ms) do
    opts
    |> Keyword.drop(@master_option_keys)
    |> Keyword.put_new(:name, EtherCAT.Bus)
    |> maybe_put_frame_timeout(frame_timeout_override_ms)
  end

  defp validate_base_station(base_station) when is_integer(base_station) and base_station >= 0,
    do: :ok

  defp validate_base_station(_base_station),
    do: {:error, {:invalid_start_options, :invalid_base_station}}

  defp reject_legacy_start_options(opts) do
    if Keyword.has_key?(opts, :dc_cycle_ns) do
      {:error, {:invalid_start_options, :legacy_dc_cycle_ns}}
    else
      :ok
    end
  end

  defp normalize_dc_config(nil), do: {:ok, nil}

  defp normalize_dc_config(%DCConfig{} = dc_config), do: validate_dc_config(dc_config)

  defp normalize_dc_config(opts) when is_list(opts) do
    validate_dc_config(%DCConfig{
      cycle_ns: Keyword.get(opts, :cycle_ns, 1_000_000),
      await_lock?: Keyword.get(opts, :await_lock?, false),
      lock_threshold_ns: Keyword.get(opts, :lock_threshold_ns, 100),
      lock_timeout_ms: Keyword.get(opts, :lock_timeout_ms, 5_000),
      warmup_cycles: Keyword.get(opts, :warmup_cycles, 0)
    })
  end

  defp normalize_dc_config(_dc_config), do: {:error, {:invalid_start_options, :invalid_dc}}

  defp validate_dc_config(%DCConfig{} = dc_config)
       when is_integer(dc_config.cycle_ns) and dc_config.cycle_ns >= 1_000_000 and
              rem(dc_config.cycle_ns, 1_000_000) == 0 and
              is_boolean(dc_config.await_lock?) and
              is_integer(dc_config.lock_threshold_ns) and dc_config.lock_threshold_ns > 0 and
              is_integer(dc_config.lock_timeout_ms) and dc_config.lock_timeout_ms > 0 and
              is_integer(dc_config.warmup_cycles) and dc_config.warmup_cycles >= 0 do
    {:ok, dc_config}
  end

  defp validate_dc_config(_dc_config), do: {:error, {:invalid_start_options, :invalid_dc}}

  defp validate_frame_timeout_override_ms(nil), do: :ok

  defp validate_frame_timeout_override_ms(timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > 0,
       do: :ok

  defp validate_frame_timeout_override_ms(_timeout_ms),
    do: {:error, {:invalid_start_options, :invalid_frame_timeout_ms}}

  defp maybe_put_frame_timeout(opts, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    Keyword.put(opts, :frame_timeout_ms, timeout_ms)
  end

  defp maybe_put_frame_timeout(opts, _timeout_ms), do: opts

  defp normalize_domain_configs(domain_config, _dc_config) when is_list(domain_config) do
    Enum.with_index(domain_config)
    |> Enum.reduce_while({:ok, []}, fn {entry, idx}, {:ok, acc} ->
      case normalize_domain_config(entry) do
        {:ok, normalized} ->
          {:cont, {:ok, [normalized | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_domain_config, {:invalid_options, idx, reason}}}}
      end
    end)
    |> case do
      {:ok, domains} ->
        {:ok, Enum.reverse(domains)}

      {:error, _} = err ->
        err
    end
  end

  defp normalize_domain_configs(_domain_config, _dc_config),
    do: {:error, {:invalid_domain_config, :invalid_list}}

  defp normalize_domain_config(%DomainConfig{} = cfg) do
    with :ok <- validate_domain_config(cfg) do
      {:ok, cfg}
    end
  end

  defp normalize_domain_config(opts) when is_list(opts) do
    with :ok <- validate_domain_option_keys(opts),
         {:ok, id} <- Keyword.fetch(opts, :id),
         {:ok, cycle_time_us} <- Keyword.fetch(opts, :cycle_time_us),
         :ok <-
           validate_domain_config(%DomainConfig{
             id: id,
             cycle_time_us: cycle_time_us,
             miss_threshold: Keyword.get(opts, :miss_threshold, 1000)
           }) do
      {:ok,
       %DomainConfig{
         id: id,
         cycle_time_us: cycle_time_us,
         miss_threshold: Keyword.get(opts, :miss_threshold, 1000)
       }}
    else
      :error -> {:error, :missing_required_field}
      {:error, _} = err -> err
    end
  end

  defp normalize_domain_config(_opts), do: {:error, :invalid_entry}

  defp validate_domain_option_keys(opts) do
    case Enum.find(Keyword.keys(opts), &(&1 not in @domain_option_keys)) do
      nil -> :ok
      key -> {:error, {:unsupported_option, key}}
    end
  end

  defp validate_domain_config(%DomainConfig{id: id, cycle_time_us: cycle_time_us} = cfg)
       when is_atom(id) and is_integer(cycle_time_us) and cycle_time_us >= 1_000 and
              rem(cycle_time_us, 1_000) == 0 and
              is_integer(cfg.miss_threshold) and cfg.miss_threshold > 0 do
    :ok
  end

  defp validate_domain_config(_cfg), do: {:error, :invalid_fields}

  defp allocate_domain_logical_bases(domain_configs) when is_list(domain_configs) do
    {:ok,
     Enum.with_index(domain_configs)
     |> Enum.map(fn {%DomainConfig{} = cfg, idx} ->
       %DomainPlan{
         id: cfg.id,
         cycle_time_us: cfg.cycle_time_us,
         miss_threshold: cfg.miss_threshold,
         logical_base: idx * @auto_logical_base_stride
       }
     end)}
  end

  defp normalize_slave_configs(slave_config) when is_list(slave_config) do
    case Enum.find_index(slave_config, &is_nil/1) do
      idx when is_integer(idx) ->
        {:error, {:invalid_slave_config, {:nil_entry, idx}}}

      nil ->
        Enum.with_index(slave_config)
        |> Enum.reduce_while({:ok, []}, fn {entry, idx}, {:ok, acc} ->
          case normalize_slave_config(entry) do
            {:ok, normalized} ->
              {:cont, {:ok, [normalized | acc]}}

            {:error, :invalid_entry} ->
              {:halt, {:error, {:invalid_slave_config, {:invalid_entry, idx}}}}

            {:error, reason} ->
              {:halt, {:error, {:invalid_slave_config, {:invalid_options, idx, reason}}}}
          end
        end)
        |> case do
          {:ok, slaves} -> {:ok, Enum.reverse(slaves)}
          {:error, _} = err -> err
        end
    end
  end

  defp normalize_slave_configs(_slave_config),
    do: {:error, {:invalid_slave_config, :invalid_list}}

  defp normalize_slave_config(%SlaveConfig{} = cfg), do: validate_normalized_slave(cfg)

  defp normalize_slave_config(opts) when is_list(opts) do
    with {:ok, name} <- Keyword.fetch(opts, :name) do
      validate_normalized_slave(%SlaveConfig{
        name: name,
        driver: normalize_slave_driver(Keyword.get(opts, :driver)),
        config: Keyword.get(opts, :config, %{}),
        process_data: Keyword.get(opts, :process_data, :none),
        target_state: Keyword.get(opts, :target_state, :op),
        sync: Keyword.get(opts, :sync),
        health_poll_ms: Keyword.get(opts, :health_poll_ms)
      })
    else
      :error -> {:error, :missing_name}
    end
  end

  defp normalize_slave_config(_opts), do: {:error, :invalid_entry}

  defp validate_normalized_slave(%SlaveConfig{name: name} = cfg)
       when is_atom(name) and is_map(cfg.config) do
    with :ok <- validate_process_data_request(cfg.process_data),
         :ok <- validate_target_state(cfg.target_state),
         {:ok, sync_config} <- normalize_sync_config(cfg.sync),
         :ok <- validate_health_poll_ms(cfg.health_poll_ms) do
      {:ok, %{cfg | driver: normalize_slave_driver(cfg.driver), sync: sync_config}}
    end
  end

  defp validate_normalized_slave(_cfg), do: {:error, :invalid_fields}

  defp validate_process_data_request(:none), do: :ok

  defp validate_process_data_request({:all, domain_id}) when is_atom(domain_id), do: :ok

  defp validate_process_data_request(requested_signals) when is_list(requested_signals) do
    if Enum.all?(requested_signals, &valid_requested_signal?/1) do
      :ok
    else
      {:error, :invalid_process_data}
    end
  end

  defp validate_process_data_request(_process_data), do: {:error, :invalid_process_data}

  defp validate_target_state(:op), do: :ok
  defp validate_target_state(:preop), do: :ok
  defp validate_target_state(_target_state), do: {:error, :invalid_target_state}

  defp validate_health_poll_ms(nil), do: :ok
  defp validate_health_poll_ms(ms) when is_integer(ms) and ms > 0, do: :ok
  defp validate_health_poll_ms(_ms), do: {:error, :invalid_health_poll_ms}

  defp normalize_sync_config(nil), do: {:ok, nil}

  defp normalize_sync_config(%SyncConfig{} = sync_config), do: validate_sync_config(sync_config)

  defp normalize_sync_config(opts) when is_list(opts) do
    validate_sync_config(%SyncConfig{
      mode: Keyword.get(opts, :mode),
      sync0: Keyword.get(opts, :sync0),
      sync1: Keyword.get(opts, :sync1),
      latches: Keyword.get(opts, :latches, %{})
    })
  end

  defp normalize_sync_config(_sync_config), do: {:error, :invalid_sync}

  defp validate_sync_config(
         %SyncConfig{mode: nil, sync0: nil, sync1: nil, latches: latches} = cfg
       ) do
    with :ok <- validate_latches(latches) do
      {:ok, %{cfg | latches: latches}}
    end
  end

  defp validate_sync_config(
         %SyncConfig{mode: :free_run, sync0: nil, sync1: nil, latches: latches} = cfg
       ) do
    with :ok <- validate_latches(latches) do
      {:ok, %{cfg | latches: latches}}
    end
  end

  defp validate_sync_config(
         %SyncConfig{mode: :sync0, sync0: sync0, sync1: nil, latches: latches} = cfg
       ) do
    with :ok <- validate_sync0(sync0),
         :ok <- validate_latches(latches) do
      {:ok, %{cfg | latches: latches}}
    end
  end

  defp validate_sync_config(
         %SyncConfig{mode: :sync1, sync0: sync0, sync1: sync1, latches: latches} = cfg
       ) do
    with :ok <- validate_sync0(sync0),
         :ok <- validate_sync1(sync1),
         :ok <- validate_latches(latches) do
      {:ok, %{cfg | latches: latches}}
    end
  end

  defp validate_sync_config(_sync_config), do: {:error, :invalid_sync}

  defp validate_sync0(%{pulse_ns: pulse_ns, shift_ns: shift_ns})
       when is_integer(pulse_ns) and pulse_ns > 0 and is_integer(shift_ns),
       do: :ok

  defp validate_sync0(%{pulse_ns: 0, shift_ns: shift_ns}) when is_integer(shift_ns),
    do: {:error, :unsupported_sync_ack_mode}

  defp validate_sync0(_sync0), do: {:error, :invalid_sync}

  defp validate_sync1(%{offset_ns: offset_ns})
       when is_integer(offset_ns) and offset_ns >= 0,
       do: :ok

  defp validate_sync1(_sync1), do: {:error, :invalid_sync}

  defp validate_latches(latches) when is_map(latches) do
    values = Map.values(latches)

    if Enum.all?(latches, &valid_latch_entry?/1) and length(values) == length(Enum.uniq(values)) do
      :ok
    else
      {:error, :invalid_sync}
    end
  end

  defp validate_latches(_latches), do: {:error, :invalid_sync}

  defp valid_latch_entry?({name, {latch_id, edge}})
       when is_atom(name) and latch_id in [0, 1] and edge in [:pos, :neg],
       do: true

  defp valid_latch_entry?(_entry), do: false

  defp valid_requested_signal?({signal_name, domain_id})
       when is_atom(signal_name) and is_atom(domain_id),
       do: true

  defp valid_requested_signal?(_entry), do: false

  defp normalize_slave_driver(nil), do: DefaultSlaveDriver
  defp normalize_slave_driver(driver), do: driver

  defp dynamic_slave_configs(0), do: []

  defp dynamic_slave_configs(bus_count) do
    Enum.map(0..(bus_count - 1), fn pos ->
      %SlaveConfig{
        name: dynamic_slave_name(pos),
        driver: DefaultSlaveDriver,
        config: %{},
        process_data: :none,
        target_state: :preop,
        sync: nil
      }
    end)
  end

  defp dynamic_slave_name(0), do: :coupler
  defp dynamic_slave_name(pos), do: :"slave_#{pos}"

  defp requested_domain_ids(%SlaveConfig{process_data: :none}), do: []
  defp requested_domain_ids(%SlaveConfig{process_data: {:all, domain_id}}), do: [domain_id]

  defp requested_domain_ids(%SlaveConfig{process_data: requested_signals}) do
    requested_signals
    |> Enum.map(fn {_signal_name, domain_id} -> domain_id end)
    |> Enum.uniq()
  end
end
