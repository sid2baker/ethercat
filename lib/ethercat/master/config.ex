defmodule EtherCAT.Master.Config do
  @moduledoc false

  alias EtherCAT.Backend
  alias EtherCAT.DC.Config, as: DCConfig
  alias EtherCAT.Master.Config.Domain
  alias EtherCAT.Master.Config.DomainPlan
  alias EtherCAT.Master.Config.Slave
  alias EtherCAT.Slave.Config, as: SlaveConfig

  @default_base_station 0x1000
  @default_frame_timeout_floor_ms 5
  @max_station_address 0xFFFF
  @type t :: %__MODULE__{
          base_station: non_neg_integer(),
          backend: Backend.t(),
          bus_opts: keyword(),
          dc_config: DCConfig.t() | nil,
          domain_config: [DomainPlan.t()],
          slave_config: [SlaveConfig.t()],
          frame_timeout_floor_ms: pos_integer(),
          frame_timeout_override_ms: pos_integer() | nil,
          scan_stable_ms: pos_integer(),
          scan_poll_ms: pos_integer()
        }

  defstruct base_station: @default_base_station,
            backend: nil,
            bus_opts: [],
            dc_config: %DCConfig{},
            domain_config: [],
            slave_config: [],
            frame_timeout_floor_ms: @default_frame_timeout_floor_ms,
            frame_timeout_override_ms: nil,
            scan_stable_ms: 1_000,
            scan_poll_ms: 100

  @spec normalize_start_options(term()) :: {:ok, t()} | {:error, term()}
  def normalize_start_options(opts) when is_list(opts) do
    backend_spec = Keyword.get(opts, :backend)
    slave_config = Keyword.get(opts, :slaves, [])
    domain_config = Keyword.get(opts, :domains, [])
    base_station = Keyword.get(opts, :base_station, @default_base_station)
    dc = Keyword.get(opts, :dc, %DCConfig{})
    frame_timeout_override_ms = Keyword.get(opts, :frame_timeout_ms)
    frame_timeout_floor_ms = @default_frame_timeout_floor_ms
    scan_stable_ms = Keyword.get(opts, :scan_stable_ms, 1_000)
    scan_poll_ms = Keyword.get(opts, :scan_poll_ms, 100)

    with :ok <- reject_legacy_start_options(opts),
         :ok <- validate_bus_source(opts),
         {:ok, backend} <- normalize_backend(backend_spec),
         :ok <- validate_base_station(base_station),
         {:ok, dc_config} <- normalize_dc_config(dc),
         :ok <- validate_frame_timeout_override_ms(frame_timeout_override_ms),
         {:ok, normalized_domains} <- Domain.normalize_configs(domain_config),
         {:ok, allocated_domains} <- Domain.allocate_logical_bases(normalized_domains),
         {:ok, normalized_slaves} <- Slave.normalize_configs(slave_config),
         :ok <- validate_scan_opts(scan_stable_ms, scan_poll_ms) do
      {:ok,
       %__MODULE__{
         base_station: base_station,
         backend: backend,
         bus_opts: build_bus_start_opts(backend, frame_timeout_override_ms),
         dc_config: dc_config,
         domain_config: allocated_domains,
         slave_config: normalized_slaves,
         frame_timeout_floor_ms: frame_timeout_floor_ms,
         frame_timeout_override_ms: frame_timeout_override_ms,
         scan_stable_ms: scan_stable_ms,
         scan_poll_ms: scan_poll_ms
       }}
    else
      {:error, _} = err -> err
    end
  end

  def normalize_start_options(_opts), do: {:error, :invalid_start_options}

  @spec normalize_runtime_slave_config(atom(), term(), SlaveConfig.t()) ::
          {:ok, SlaveConfig.t()} | {:error, term()}
  def normalize_runtime_slave_config(slave_name, spec, current_config),
    do: Slave.normalize_runtime_config(slave_name, spec, current_config)

  @spec effective_slave_config([SlaveConfig.t()], non_neg_integer()) ::
          {:ok, [SlaveConfig.t()]} | {:error, term()}
  def effective_slave_config(slave_config, bus_count),
    do: Slave.effective_config(slave_config, bus_count)

  @spec domain_ids([DomainPlan.t()]) :: [atom()]
  def domain_ids(domain_config), do: Domain.ids(domain_config)

  @spec unknown_domain_ids([DomainPlan.t()], SlaveConfig.t()) :: [atom()]
  def unknown_domain_ids(domain_config, %SlaveConfig{} = slave_config) do
    known_domains = MapSet.new(Domain.ids(domain_config))

    slave_config
    |> Slave.requested_domain_ids()
    |> Enum.reject(&MapSet.member?(known_domains, &1))
  end

  @spec activatable_slave_names([SlaveConfig.t()]) :: [atom()]
  def activatable_slave_names(slave_config), do: Slave.activatable_names(slave_config)

  @spec requested_domain_ids(SlaveConfig.t()) :: [atom()]
  def requested_domain_ids(%SlaveConfig{} = slave_config),
    do: Slave.requested_domain_ids(slave_config)

  @spec fetch_slave_config([SlaveConfig.t()], atom()) ::
          {:ok, SlaveConfig.t(), non_neg_integer()} | {:error, term()}
  def fetch_slave_config(slave_config, slave_name),
    do: Slave.fetch_config(slave_config, slave_name)

  @spec local_config_changed?(SlaveConfig.t(), SlaveConfig.t()) :: boolean()
  def local_config_changed?(%SlaveConfig{} = current_config, %SlaveConfig{} = updated_config),
    do: Slave.local_config_changed?(current_config, updated_config)

  @spec domain_start_opts(DomainPlan.t()) :: keyword()
  def domain_start_opts(%DomainPlan{} = config), do: Domain.start_opts(config)

  defp build_bus_start_opts(backend, frame_timeout_override_ms) do
    backend
    |> Backend.to_bus_opts()
    |> Keyword.put_new(:name, EtherCAT.Bus)
    |> maybe_put_frame_timeout(frame_timeout_override_ms)
  end

  defp validate_bus_source(opts) do
    if Keyword.has_key?(opts, :backend) do
      :ok
    else
      {:error, {:invalid_start_options, :missing_backend}}
    end
  end

  defp normalize_backend(nil), do: {:error, {:invalid_start_options, :missing_backend}}

  defp normalize_backend(backend_spec) do
    case Backend.normalize(backend_spec) do
      {:ok, backend} -> {:ok, backend}
      {:error, reason} -> {:error, {:invalid_start_options, reason}}
    end
  end

  defp validate_base_station(base_station)
       when is_integer(base_station) and base_station >= 0 and
              base_station <= @max_station_address,
       do: :ok

  defp validate_base_station(_base_station),
    do: {:error, {:invalid_start_options, :invalid_base_station}}

  defp reject_legacy_start_options(opts) do
    legacy_backend_keys =
      Enum.filter(
        [:transport, :transport_mod, :interface, :host, :bind_ip, :backup_interface],
        fn key ->
          Keyword.has_key?(opts, key)
        end
      )

    cond do
      legacy_backend_keys != [] ->
        {:error, {:invalid_start_options, {:use_backend, legacy_backend_keys}}}

      Keyword.has_key?(opts, :dc_cycle_ns) ->
        {:error, {:invalid_start_options, :legacy_dc_cycle_ns}}

      true ->
        :ok
    end
  end

  defp normalize_dc_config(nil), do: {:ok, nil}

  defp normalize_dc_config(%DCConfig{} = dc_config), do: validate_dc_config(dc_config)

  defp normalize_dc_config(opts) when is_list(opts) do
    validate_dc_config(%DCConfig{
      cycle_ns: Keyword.get(opts, :cycle_ns, 1_000_000),
      await_lock?: Keyword.get(opts, :await_lock?, false),
      lock_policy: Keyword.get(opts, :lock_policy, :advisory),
      lock_threshold_ns: Keyword.get(opts, :lock_threshold_ns, 100),
      lock_timeout_ms: Keyword.get(opts, :lock_timeout_ms, 5_000),
      warmup_cycles: Keyword.get(opts, :warmup_cycles, 0)
    })
  end

  defp normalize_dc_config(_dc_config), do: {:error, {:invalid_start_options, :invalid_dc}}

  defp validate_dc_config(%DCConfig{} = dc_config) do
    cycle_ns = dc_config.cycle_ns

    if is_integer(cycle_ns) and cycle_ns >= 1_000_000 and rem(cycle_ns, 1_000_000) == 0 and
         is_boolean(dc_config.await_lock?) and
         dc_config.lock_policy in [:advisory, :recovering, :fatal] and
         is_integer(dc_config.lock_threshold_ns) and dc_config.lock_threshold_ns > 0 and
         is_integer(dc_config.lock_timeout_ms) and dc_config.lock_timeout_ms > 0 and
         is_integer(dc_config.warmup_cycles) and dc_config.warmup_cycles >= 0 do
      {:ok, dc_config}
    else
      {:error, {:invalid_start_options, :invalid_dc}}
    end
  end

  defp validate_dc_config(_dc_config), do: {:error, {:invalid_start_options, :invalid_dc}}

  defp validate_frame_timeout_override_ms(nil), do: :ok

  defp validate_frame_timeout_override_ms(timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > 0,
       do: :ok

  defp validate_frame_timeout_override_ms(_timeout_ms),
    do: {:error, {:invalid_start_options, :invalid_frame_timeout_ms}}

  defp validate_scan_opts(scan_stable_ms, scan_poll_ms)
       when is_integer(scan_stable_ms) and scan_stable_ms >= 0 and
              is_integer(scan_poll_ms) and scan_poll_ms > 0,
       do: :ok

  defp validate_scan_opts(_scan_stable_ms, _scan_poll_ms),
    do: {:error, {:invalid_start_options, :invalid_scan_options}}

  defp maybe_put_frame_timeout(opts, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    Keyword.put(opts, :frame_timeout_ms, timeout_ms)
  end

  defp maybe_put_frame_timeout(opts, _timeout_ms), do: opts
end
