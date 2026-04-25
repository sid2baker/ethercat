defmodule EtherCAT.Slave.Runtime.Configuration do
  @moduledoc false

  require Logger

  alias EtherCAT.Slave
  alias EtherCAT.Slave.Runtime.DCSignals
  alias EtherCAT.Slave.Mailbox
  alias EtherCAT.Slave.ProcessData
  alias EtherCAT.Slave.Runtime.DeviceState

  @spec maybe_reconfigure_preop(%Slave{}, keyword()) ::
          {:ok, %Slave{}} | {:error, term(), %Slave{}}
  # A PREOP slave with registered signals can only hot-apply sync changes.
  # Driver/config/process-data changes would invalidate the open-domain plan.
  def maybe_reconfigure_preop(%{signal_registrations: registrations} = data, opts)
      when map_size(registrations) > 0,
      do: reconfigure_registered_preop(data, opts)

  # A PREOP slave without registered signals can still run the full PREOP setup.
  def maybe_reconfigure_preop(data, opts), do: reconfigure_unregistered_preop(data, opts)

  @spec retry_failed_preop(%Slave{}) :: {:ok, %Slave{}} | {:error, term(), %Slave{}}
  def retry_failed_preop(%{configuration_error: nil} = data), do: {:ok, data}

  def retry_failed_preop(data) do
    configured = configure_preop_process_data(data)

    case configured.configuration_error do
      nil -> {:ok, configured}
      reason -> {:error, reason, configured}
    end
  end

  @doc false
  @spec post_transition(atom(), %Slave{}) ::
          {:ok, %Slave{}} | {:error, term(), %Slave{}}
  def post_transition(:preop, data) do
    new_data = configure_preop_process_data(data)
    name = data.name

    Logger.debug(
      "[Slave #{name}] preop: ready (#{map_size(new_data.signal_registrations)} signal(s) registered)"
    )

    send(EtherCAT.Master, {:slave_ready, name, :preop})
    {:ok, new_data}
  end

  def post_transition(:safeop, data) do
    DCSignals.configure(data)
  end

  def post_transition(:op, data), do: {:ok, data}

  def post_transition(_target, data), do: {:ok, data}

  defp reconfigure_registered_preop(data, opts) do
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

  defp reconfigure_unregistered_preop(data, opts) do
    updated_data =
      %{
        data
        | driver: Keyword.get(opts, :driver, data.driver),
          config: Keyword.get(opts, :config, data.config),
          process_data_request: Keyword.get(opts, :process_data, data.process_data_request),
          sync_config: Keyword.get(opts, :sync, data.sync_config),
          health_poll_ms: Keyword.get(opts, :health_poll_ms, data.health_poll_ms)
      }
      |> DeviceState.initialize()

    configured = configure_preop_process_data(updated_data)

    case configured.configuration_error do
      nil -> {:ok, configured}
      reason -> {:error, reason, configured}
    end
  end

  defp configure_preop_process_data(%{driver: nil} = data) do
    ProcessData.configure_preop(data, run_mailbox_config: &Mailbox.run_preop_config/1)
  end

  defp configure_preop_process_data(data) do
    ProcessData.configure_preop(data, run_mailbox_config: &Mailbox.run_preop_config/1)
  end

  defp apply_sync_only_reconfigure(data, requested_sync)
       when requested_sync == data.sync_config do
    {:ok, data}
  end

  defp apply_sync_only_reconfigure(data, requested_sync) do
    updated_data = %{data | sync_config: requested_sync}

    case Mailbox.run_sync_config(updated_data) do
      {:ok, _mailbox_data} ->
        {:ok, updated_data}

      {:error, reason} ->
        ProcessData.log_configuration_error(updated_data, reason)
        {:error, reason}
    end
  end
end
