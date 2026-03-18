defmodule EtherCAT.Master.Preop do
  @moduledoc false

  alias EtherCAT.Master.Config
  alias EtherCAT.Slave

  @spec configure_discovered_slave(
          %EtherCAT.Master{},
          atom(),
          keyword() | EtherCAT.Slave.Config.t()
        ) :: {:ok, %EtherCAT.Master{}} | {:error, term()}
  def configure_discovered_slave(data, slave_name, spec) do
    with {:ok, current_config, config_idx} <-
           Config.fetch_slave_config(data.slave_configs, slave_name),
         {:ok, updated_config} <-
           Config.normalize_runtime_slave_config(slave_name, spec, current_config),
         :ok <- ensure_known_domains(data, updated_config),
         :ok <- ensure_slave_in_preop(slave_name),
         :ok <- maybe_apply_slave_configuration(slave_name, current_config, updated_config) do
      updated_slave_configs = List.replace_at(data.slave_configs, config_idx, updated_config)

      {:ok,
       %{
         data
         | slave_configs: updated_slave_configs,
           activatable_slaves: Config.activatable_slave_names(updated_slave_configs)
       }}
    end
  end

  defp ensure_known_domains(data, slave_config) do
    case Config.unknown_domain_ids(data.domain_configs || [], slave_config) do
      [] ->
        :ok

      domains ->
        {:error, {:unknown_domains, domains}}
    end
  end

  defp ensure_slave_in_preop(slave_name) do
    case Slave.state(slave_name) do
      :preop -> :ok
      {:error, _} = err -> err
      other -> {:error, {:slave_not_preop, other}}
    end
  end

  defp maybe_apply_slave_configuration(slave_name, current_config, updated_config) do
    if Config.local_config_changed?(current_config, updated_config) do
      Slave.configure(
        slave_name,
        driver: updated_config.driver,
        config: updated_config.config,
        process_data: updated_config.process_data,
        sync: updated_config.sync,
        health_poll_ms: updated_config.health_poll_ms
      )
    else
      :ok
    end
  end
end
