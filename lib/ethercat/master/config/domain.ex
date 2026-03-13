defmodule EtherCAT.Master.Config.Domain do
  @moduledoc false

  alias EtherCAT.Domain.Config, as: DomainConfig
  alias EtherCAT.Master.Config.DomainPlan

  @auto_logical_base_stride 2048
  @domain_option_keys [:id, :cycle_time_us, :miss_threshold]

  @spec normalize_configs(term()) :: {:ok, [DomainConfig.t()]} | {:error, term()}
  def normalize_configs(domain_config) when is_list(domain_config) do
    Enum.with_index(domain_config)
    |> Enum.reduce_while({:ok, []}, fn {entry, idx}, {:ok, acc} ->
      case normalize_config(entry) do
        {:ok, normalized} ->
          {:cont, {:ok, [normalized | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_domain_config, {:invalid_options, idx, reason}}}}
      end
    end)
    |> case do
      {:ok, domains} ->
        domains = Enum.reverse(domains)

        with :ok <- ensure_unique_ids(domains) do
          {:ok, domains}
        end

      {:error, _} = err ->
        err
    end
  end

  def normalize_configs(_domain_config), do: {:error, {:invalid_domain_config, :invalid_list}}

  @spec allocate_logical_bases([DomainConfig.t()]) :: {:ok, [DomainPlan.t()]}
  def allocate_logical_bases(domain_configs) when is_list(domain_configs) do
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

  @spec ids([DomainPlan.t()]) :: [atom()]
  def ids(domain_config), do: Enum.map(domain_config, & &1.id)

  @spec start_opts(DomainPlan.t()) :: keyword()
  def start_opts(%DomainPlan{logical_base: logical_base} = config) do
    [
      id: config.id,
      cycle_time_us: config.cycle_time_us,
      miss_threshold: config.miss_threshold,
      logical_base: logical_base
    ]
  end

  defp normalize_config(%DomainConfig{} = cfg) do
    with :ok <- validate_config(cfg) do
      {:ok, cfg}
    end
  end

  defp normalize_config(opts) when is_list(opts) do
    with :ok <- validate_option_keys(opts),
         {:ok, id} <- Keyword.fetch(opts, :id),
         {:ok, cycle_time_us} <- Keyword.fetch(opts, :cycle_time_us),
         :ok <-
           validate_config(%DomainConfig{
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

  defp normalize_config(_opts), do: {:error, :invalid_entry}

  defp validate_option_keys(opts) do
    case Enum.find(Keyword.keys(opts), &(&1 not in @domain_option_keys)) do
      nil -> :ok
      key -> {:error, {:unsupported_option, key}}
    end
  end

  defp validate_config(%DomainConfig{id: id, cycle_time_us: cycle_time_us} = cfg)
       when is_atom(id) and is_integer(cycle_time_us) and cycle_time_us >= 1_000 and
              rem(cycle_time_us, 1_000) == 0 and
              is_integer(cfg.miss_threshold) and cfg.miss_threshold > 0 do
    :ok
  end

  defp validate_config(_cfg), do: {:error, :invalid_fields}

  defp ensure_unique_ids(domain_configs) do
    domain_configs
    |> Enum.with_index()
    |> Enum.reduce_while(%{}, fn {%DomainConfig{id: id}, idx}, seen ->
      if Map.has_key?(seen, id) do
        {:halt, {:error, {:invalid_domain_config, {:duplicate_id, idx, id}}}}
      else
        {:cont, Map.put(seen, id, idx)}
      end
    end)
    |> case do
      %{} -> :ok
      {:error, _} = err -> err
    end
  end
end
