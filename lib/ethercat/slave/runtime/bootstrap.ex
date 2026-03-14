defmodule EtherCAT.Slave.Runtime.Bootstrap do
  @moduledoc false

  require Logger

  alias EtherCAT.Bus
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.Slave.ESC.Registers
  alias EtherCAT.Slave.ESC.SII
  alias EtherCAT.Telemetry
  alias EtherCAT.Utils

  # ETG.1000 §6.7 SyncManager control byte: mailbox/handshake + PDI IRQ.
  # `0x26` = ECAT writes (master->slave mailbox receive), `0x22` = ECAT reads
  # (slave->master mailbox send).
  @mailbox_receive_sm_control 0x26
  @mailbox_send_sm_control 0x22

  @type transition_fun ::
          (%EtherCAT.Slave{}, atom() ->
             {:ok, %EtherCAT.Slave{}} | {:error, term(), %EtherCAT.Slave{}})

  @type opts :: [auto_advance_retry_ms: pos_integer(), transition: transition_fun()]

  @type init_result :: {:ok, atom(), %EtherCAT.Slave{}, list()}

  @spec initialize_to_preop(%EtherCAT.Slave{}, opts()) ::
          init_result()
  def initialize_to_preop(data, opts) do
    retry_ms = Keyword.fetch!(opts, :auto_advance_retry_ms)
    transition = Keyword.fetch!(opts, :transition)

    case transition.(data, :init) do
      {:ok, init_data} ->
        read_sii_and_enter_preop(init_data, transition, retry_ms)

      {:error, reason, init_data} ->
        schedule_startup_retry(init_data, :init_transition, reason, retry_ms)
    end
  end

  defp read_sii_and_enter_preop(data, transition, retry_ms) do
    t0 = System.monotonic_time(:millisecond)

    Logger.debug(
      "[Slave #{data.name}] init: reading SII (station=0x#{Integer.to_string(data.station, 16)})",
      event: :sii_read_started
    )

    with {:ok, sii_data} <- read_sii_data(data, t0),
         {:ok, mailbox_data} <- configure_mailbox_sync_managers(sii_data),
         {:ok, preop_data} <- transition_to_preop(mailbox_data, transition, t0) do
      {:ok, :preop, reset_startup_retry(preop_data), []}
    else
      {:error, reason} ->
        schedule_startup_retry(data, :sii_read, reason, retry_ms)

      {:error, {:mailbox_sync_manager_setup_failed, reason}, failed_data} ->
        schedule_startup_retry(failed_data, :mailbox_setup, reason, retry_ms)

      {:error, {:preop_transition_failed, reason}, failed_data} ->
        schedule_startup_retry(failed_data, :preop_transition, reason, retry_ms)
    end
  end

  defp read_sii_data(data, t0) do
    case read_sii(data.bus, data.station) do
      {:ok, esc_info, identity, mailbox_config, sm_configs, pdo_configs} ->
        sii_ms = System.monotonic_time(:millisecond) - t0

        Logger.debug(
          "[Slave #{data.name}] SII ok in #{sii_ms}ms — " <>
            "vendor=0x#{Integer.to_string(identity.vendor_id, 16)} " <>
            "product=0x#{Integer.to_string(identity.product_code, 16)} " <>
            "fmmus=#{esc_info.fmmu_count} " <>
            "mbx_recv=#{mailbox_config.recv_size} pdos=#{length(pdo_configs)}",
          event: :sii_read_completed,
          duration_ms: sii_ms,
          vendor_id: identity.vendor_id,
          product_code: identity.product_code,
          fmmu_count: esc_info.fmmu_count,
          mailbox_recv_size: mailbox_config.recv_size,
          pdo_count: length(pdo_configs)
        )

        {:ok,
         %{
           data
           | identity: identity,
             esc_info: esc_info,
             mailbox_config: mailbox_config,
             sii_sm_configs: sm_configs,
             sii_pdo_configs: pdo_configs
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

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
        case Utils.ensure_expected_wkcs(replies, 1, :esc_info_read_failed) do
          :ok -> {:error, {:esc_info_read_failed, :unexpected_reply}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:esc_info_read_failed, reason}}
    end
  end

  defp transition_to_preop(data, transition, t0) do
    Logger.debug(
      "[Slave #{data.name}] init: transitioning to PREOP",
      event: :preop_transition_started,
      target_state: :preop
    )

    case transition.(data, :preop) do
      {:ok, preop_data} ->
        preop_ms = System.monotonic_time(:millisecond) - t0

        Logger.debug(
          "[Slave #{data.name}] init: PREOP reached in #{preop_ms}ms total",
          event: :preop_transition_completed,
          target_state: :preop,
          duration_ms: preop_ms
        )

        {:ok, preop_data}

      {:error, reason, failed_data} ->
        {:error, {:preop_transition_failed, reason}, failed_data}
    end
  end

  defp configure_mailbox_sync_managers(%{mailbox_config: %{recv_size: 0}} = data),
    do: {:ok, data}

  defp configure_mailbox_sync_managers(data) do
    %{recv_offset: ro, recv_size: rs, send_offset: so, send_size: ss} = data.mailbox_config

    Logger.debug(
      "[Slave #{data.name}] init: setting up mailbox SMs",
      event: :mailbox_sync_manager_setup_started
    )

    sm0 = <<ro::16-little, rs::16-little, @mailbox_receive_sm_control::8, 0::8, 0x00::8, 0::8>>
    sm1 = <<so::16-little, ss::16-little, @mailbox_send_sm_control::8, 0::8, 0x00::8, 0::8>>

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
        case Utils.ensure_expected_wkcs(replies, 1, :mailbox_sync_manager_setup_failed) do
          :ok -> {:ok, data}
          {:error, reason} -> {:error, reason, data}
        end

      {:error, reason} ->
        {:error, {:mailbox_sync_manager_setup_failed, reason}, data}
    end
  end

  defp schedule_startup_retry(data, phase, reason, retry_ms) do
    retry_count =
      if data.startup_retry_phase == phase do
        data.startup_retry_count + 1
      else
        1
      end

    updated = %{
      data
      | startup_retry_phase: phase,
        startup_retry_count: retry_count
    }

    Telemetry.slave_startup_retry(data.name, data.station, phase, reason, retry_count, retry_ms)
    log_startup_retry(updated.name, phase, reason, retry_ms, retry_count)

    {:ok, :init, updated, [{{:timeout, :auto_advance}, retry_ms, nil}]}
  end

  defp reset_startup_retry(data) do
    %{data | startup_retry_phase: nil, startup_retry_count: 0}
  end

  defp log_startup_retry(name, phase, reason, retry_ms, retry_count) do
    message =
      "[Slave #{name}] startup retry #{retry_count} phase=#{phase} reason=#{inspect(reason)} " <>
        "— retrying in #{retry_ms} ms"

    metadata = [
      component: :slave,
      slave: name,
      event: :startup_retry,
      phase: phase,
      reason_kind: Utils.reason_kind(reason),
      retry_count: retry_count,
      retry_delay_ms: retry_ms
    ]

    case Utils.retry_log_level(retry_count) do
      :warning -> Logger.warning(message, metadata)
      :debug -> Logger.debug(message, metadata)
    end
  end
end
