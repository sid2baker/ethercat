defmodule EtherCAT.Master.Config.Slave do
  @moduledoc false

  alias EtherCAT.Slave.Config, as: SlaveConfig
  alias EtherCAT.Slave.Driver.Default, as: DefaultSlaveDriver
  alias EtherCAT.Slave.Sync.Config, as: SyncConfig

  @spec normalize_configs(term()) :: {:ok, [SlaveConfig.t()]} | {:error, term()}
  def normalize_configs(slave_config) when is_list(slave_config) do
    case Enum.find_index(slave_config, &is_nil/1) do
      idx when is_integer(idx) ->
        {:error, {:invalid_slave_config, {:nil_entry, idx}}}

      nil ->
        Enum.with_index(slave_config)
        |> Enum.reduce_while({:ok, []}, fn {entry, idx}, {:ok, acc} ->
          case normalize_config(entry) do
            {:ok, normalized} ->
              {:cont, {:ok, [normalized | acc]}}

            {:error, :invalid_entry} ->
              {:halt, {:error, {:invalid_slave_config, {:invalid_entry, idx}}}}

            {:error, reason} ->
              {:halt, {:error, {:invalid_slave_config, {:invalid_options, idx, reason}}}}
          end
        end)
        |> case do
          {:ok, slaves} ->
            slaves = Enum.reverse(slaves)

            with :ok <- ensure_unique_names(slaves) do
              {:ok, slaves}
            end

          {:error, _} = err ->
            err
        end
    end
  end

  def normalize_configs(_slave_config), do: {:error, {:invalid_slave_config, :invalid_list}}

  @spec normalize_runtime_config(atom(), term(), SlaveConfig.t()) ::
          {:ok, SlaveConfig.t()} | {:error, term()}
  def normalize_runtime_config(slave_name, %SlaveConfig{} = cfg, _current_config) do
    if cfg.name not in [nil, slave_name] do
      {:error, :name_mismatch}
    else
      validate_normalized(%{cfg | name: slave_name})
    end
  end

  def normalize_runtime_config(slave_name, opts, %SlaveConfig{} = current_config)
      when is_list(opts) do
    normalized =
      %SlaveConfig{
        name: slave_name,
        driver: normalize_driver(Keyword.get(opts, :driver, current_config.driver)),
        config: Keyword.get(opts, :config, current_config.config),
        process_data: Keyword.get(opts, :process_data, current_config.process_data),
        target_state: Keyword.get(opts, :target_state, current_config.target_state),
        sync: Keyword.get(opts, :sync, current_config.sync),
        health_poll_ms: Keyword.get(opts, :health_poll_ms, current_config.health_poll_ms)
      }

    validate_normalized(normalized)
  end

  def normalize_runtime_config(_slave_name, _spec, _current_config) do
    {:error, :invalid_slave_config_update}
  end

  @spec effective_config([SlaveConfig.t()], non_neg_integer()) ::
          {:ok, [SlaveConfig.t()]} | {:error, term()}
  def effective_config([], bus_count), do: {:ok, dynamic_configs(bus_count)}

  def effective_config(slave_config, bus_count) when length(slave_config) <= bus_count do
    {:ok, Enum.take(slave_config, bus_count)}
  end

  def effective_config(slave_config, bus_count) do
    {:error, {:configured_slaves_exceed_bus, length(slave_config), bus_count}}
  end

  @spec activatable_names([SlaveConfig.t()]) :: [atom()]
  def activatable_names(slave_config) do
    slave_config
    |> Enum.filter(&(&1.target_state == :op))
    |> Enum.map(& &1.name)
  end

  @spec fetch_config([SlaveConfig.t()], atom()) ::
          {:ok, SlaveConfig.t(), non_neg_integer()} | {:error, term()}
  def fetch_config(slave_config, slave_name) do
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

  @spec requested_domain_ids(SlaveConfig.t()) :: [atom()]
  def requested_domain_ids(%SlaveConfig{process_data: :none}), do: []
  def requested_domain_ids(%SlaveConfig{process_data: {:all, domain_id}}), do: [domain_id]

  def requested_domain_ids(%SlaveConfig{process_data: requested_signals}) do
    requested_signals
    |> Enum.map(fn {_signal_name, domain_id} -> domain_id end)
    |> Enum.uniq()
  end

  defp normalize_config(%SlaveConfig{} = cfg), do: validate_normalized(cfg)

  defp normalize_config(opts) when is_list(opts) do
    with {:ok, name} <- Keyword.fetch(opts, :name) do
      validate_normalized(%SlaveConfig{
        name: name,
        driver: normalize_driver(Keyword.get(opts, :driver)),
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

  defp normalize_config(_opts), do: {:error, :invalid_entry}

  defp validate_normalized(%SlaveConfig{name: name} = cfg)
       when is_atom(name) and is_map(cfg.config) do
    with :ok <- validate_process_data_request(cfg.process_data),
         :ok <- validate_target_state(cfg.target_state),
         {:ok, sync_config} <- normalize_sync_config(cfg.sync),
         :ok <- validate_health_poll_ms(cfg.health_poll_ms) do
      {:ok, %{cfg | driver: normalize_driver(cfg.driver), sync: sync_config}}
    end
  end

  defp validate_normalized(_cfg), do: {:error, :invalid_fields}

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

  defp validate_sync1(%{offset_ns: offset_ns}) when is_integer(offset_ns) and offset_ns >= 0,
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

  defp normalize_driver(nil), do: DefaultSlaveDriver
  defp normalize_driver(driver), do: driver

  defp dynamic_configs(0), do: []

  defp dynamic_configs(bus_count) do
    Enum.map(0..(bus_count - 1), fn pos ->
      %SlaveConfig{
        name: dynamic_name(pos),
        driver: DefaultSlaveDriver,
        config: %{},
        process_data: :none,
        target_state: :preop,
        sync: nil
      }
    end)
  end

  defp dynamic_name(0), do: :coupler
  defp dynamic_name(pos), do: :"slave_#{pos}"

  defp ensure_unique_names(slave_configs) do
    slave_configs
    |> Enum.with_index()
    |> Enum.reduce_while(%{}, fn {%SlaveConfig{name: name}, idx}, seen ->
      if Map.has_key?(seen, name) do
        {:halt, {:error, {:invalid_slave_config, {:duplicate_name, idx, name}}}}
      else
        {:cont, Map.put(seen, name, idx)}
      end
    end)
    |> case do
      %{} -> :ok
      {:error, _} = err -> err
    end
  end
end
