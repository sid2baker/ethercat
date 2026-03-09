defmodule EtherCAT.Slave.Configuration do
  @moduledoc false

  require Logger

  alias EtherCAT.Slave
  alias EtherCAT.Slave.DCSignals
  alias EtherCAT.Slave.Mailbox
  alias EtherCAT.Slave.ProcessData

  @type transition_opts :: [
          al_codes: %{required(atom()) => non_neg_integer()},
          poll_limit: pos_integer(),
          poll_interval_ms: non_neg_integer(),
          post_transition: (atom(), %Slave{} ->
                              {:ok, %Slave{}} | {:error, term(), %Slave{}})
        ]

  @spec maybe_reconfigure_preop(%Slave{}, keyword()) ::
          {:ok, %Slave{}} | {:error, term(), %Slave{}}
  def maybe_reconfigure_preop(%{signal_registrations: registrations} = data, opts)
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

  def maybe_reconfigure_preop(data, opts) do
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

  @spec transition_opts(
          %{required(atom()) => non_neg_integer()},
          pos_integer(),
          non_neg_integer()
        ) ::
          transition_opts()
  def transition_opts(al_codes, poll_limit, poll_interval_ms) do
    [
      al_codes: al_codes,
      poll_limit: poll_limit,
      poll_interval_ms: poll_interval_ms,
      post_transition: &post_transition/2
    ]
  end

  defp configure_preop_process_data(%{driver: nil} = data) do
    ProcessData.configure_preop(data, run_mailbox_config: &Mailbox.run_preop_config/1)
  end

  defp configure_preop_process_data(data) do
    invoke_driver(data, :on_preop)
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
    DCSignals.configure(data)
  end

  defp post_transition(:op, data) do
    invoke_driver(data, :on_op)
    {:ok, data}
  end

  defp post_transition(_target, data), do: {:ok, data}

  defp invoke_driver(data, cb), do: invoke_driver(data, cb, [])

  defp invoke_driver(%{driver: nil}, _cb, _args), do: :ok

  defp invoke_driver(data, cb, args) do
    arity = 2 + length(args)

    if function_exported?(data.driver, cb, arity) do
      apply(data.driver, cb, [data.name, data.config | args])
    end

    :ok
  end
end
