defmodule EtherCAT.Master.Config do
  @moduledoc false

  alias EtherCAT.Domain.Config, as: DomainConfig
  alias EtherCAT.Slave.Config, as: SlaveConfig
  alias EtherCAT.Slave.Driver.Default, as: DefaultSlaveDriver

  @default_base_station 0x1000
  @default_dc_cycle_ns 1_000_000
  @master_option_keys [:slaves, :domains, :base_station, :dc_cycle_ns, :frame_timeout_ms]

  @type t :: %__MODULE__{
          base_station: non_neg_integer(),
          bus_opts: keyword(),
          dc_cycle_ns: pos_integer() | nil,
          domain_config: [DomainConfig.t()],
          slave_config: [SlaveConfig.t()],
          frame_timeout_override_ms: pos_integer() | nil
        }

  defstruct base_station: @default_base_station,
            bus_opts: [],
            dc_cycle_ns: @default_dc_cycle_ns,
            domain_config: [],
            slave_config: [],
            frame_timeout_override_ms: nil

  @spec normalize_start_options(term()) :: {:ok, t()} | {:error, term()}
  def normalize_start_options(opts) when is_list(opts) do
    slave_config = Keyword.get(opts, :slaves, [])
    domain_config = Keyword.get(opts, :domains, [])
    base_station = Keyword.get(opts, :base_station, @default_base_station)
    dc_cycle_ns = Keyword.get(opts, :dc_cycle_ns, @default_dc_cycle_ns)
    frame_timeout_override_ms = Keyword.get(opts, :frame_timeout_ms)

    with {:ok, _interface} <- Keyword.fetch(opts, :interface),
         :ok <- validate_base_station(base_station),
         :ok <- validate_dc_cycle_ns(dc_cycle_ns),
         :ok <- validate_frame_timeout_override_ms(frame_timeout_override_ms),
         {:ok, normalized_domains} <- normalize_domain_configs(domain_config),
         {:ok, normalized_slaves} <- normalize_slave_configs(slave_config) do
      {:ok,
       %__MODULE__{
         base_station: base_station,
         bus_opts: build_bus_start_opts(opts, frame_timeout_override_ms),
         dc_cycle_ns: dc_cycle_ns,
         domain_config: normalized_domains,
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
        target_state: Keyword.get(opts, :target_state, current_config.target_state)
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

  @spec domain_ids([DomainConfig.t()]) :: [atom()]
  def domain_ids(domain_config) do
    Enum.map(domain_config, & &1.id)
  end

  @spec unknown_domain_ids([DomainConfig.t()], SlaveConfig.t()) :: [atom()]
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
      current_config.process_data != updated_config.process_data
  end

  @spec domain_start_opts(DomainConfig.t()) :: keyword()
  def domain_start_opts(%DomainConfig{} = config) do
    [
      id: config.id,
      period_ms: config.period_ms,
      miss_threshold: config.miss_threshold,
      logical_base: config.logical_base
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

  defp validate_dc_cycle_ns(nil), do: :ok

  defp validate_dc_cycle_ns(dc_cycle_ns) when is_integer(dc_cycle_ns) and dc_cycle_ns > 0, do: :ok

  defp validate_dc_cycle_ns(_dc_cycle_ns),
    do: {:error, {:invalid_start_options, :invalid_dc_cycle_ns}}

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

  defp normalize_domain_configs(domain_config) when is_list(domain_config) do
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
      {:ok, domains} -> {:ok, Enum.reverse(domains)}
      {:error, _} = err -> err
    end
  end

  defp normalize_domain_configs(_domain_config),
    do: {:error, {:invalid_domain_config, :invalid_list}}

  defp normalize_domain_config(%DomainConfig{} = cfg), do: validate_domain_config(cfg)

  defp normalize_domain_config(opts) when is_list(opts) do
    with {:ok, id} <- Keyword.fetch(opts, :id),
         {:ok, period_ms} <- Keyword.fetch(opts, :period_ms) do
      validate_domain_config(%DomainConfig{
        id: id,
        period_ms: period_ms,
        miss_threshold: Keyword.get(opts, :miss_threshold, 1000),
        logical_base: Keyword.get(opts, :logical_base, 0)
      })
    else
      :error -> {:error, :missing_required_field}
    end
  end

  defp normalize_domain_config(_opts), do: {:error, :invalid_entry}

  defp validate_domain_config(%DomainConfig{id: id, period_ms: period_ms} = cfg)
       when is_atom(id) and is_integer(period_ms) and period_ms > 0 and
              is_integer(cfg.miss_threshold) and cfg.miss_threshold > 0 and
              is_integer(cfg.logical_base) and cfg.logical_base >= 0 do
    {:ok, cfg}
  end

  defp validate_domain_config(_cfg), do: {:error, :invalid_fields}

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
        target_state: Keyword.get(opts, :target_state, :op)
      })
    else
      :error -> {:error, :missing_name}
    end
  end

  defp normalize_slave_config(_opts), do: {:error, :invalid_entry}

  defp validate_normalized_slave(%SlaveConfig{name: name} = cfg)
       when is_atom(name) and is_map(cfg.config) do
    with :ok <- validate_process_data_request(cfg.process_data),
         :ok <- validate_target_state(cfg.target_state) do
      {:ok, %{cfg | driver: normalize_slave_driver(cfg.driver)}}
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
        target_state: :preop
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
