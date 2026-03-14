defmodule EtherCAT.Slave.ProcessData do
  @moduledoc false

  require Logger

  alias EtherCAT.Bus
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.Domain.API, as: DomainAPI
  alias EtherCAT.Slave
  alias EtherCAT.Slave.Driver
  alias EtherCAT.Slave.ProcessData.Plan
  alias EtherCAT.Slave.ProcessData.Plan.DomainAttachment
  alias EtherCAT.Slave.ProcessData.Plan.SmGroup
  alias EtherCAT.Slave.ESC.Registers
  alias EtherCAT.Utils

  @type opts :: [
          run_mailbox_config: (%Slave{} -> {:ok, %Slave{}} | {:error, term()})
        ]

  @spec configure_preop(%Slave{}, opts()) :: %Slave{}
  def configure_preop(%{driver: nil} = data, _opts) do
    clear_configuration_error(data)
  end

  def configure_preop(data, opts) do
    run_mailbox_config = Keyword.fetch!(opts, :run_mailbox_config)

    Logger.debug("[Slave #{data.name}] preop: running mailbox configuration")
    Logger.debug("[Slave #{data.name}] preop: configuring process-data SyncManagers/FMMUs")

    with {:ok, mailbox_data} <- run_mailbox_config.(data),
         {:ok, requested_signals} <-
           Plan.normalize_request(
             mailbox_data.process_data_request,
             mailbox_data.driver,
             mailbox_data.config,
             mailbox_data.sii_pdo_configs
           ),
         :ok <- validate_subscription_names(requested_signals, mailbox_data.sync_config),
         {:ok, sm_groups} <-
           Plan.build(
             requested_signals,
             call_signal_model(mailbox_data),
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
        log_configuration_error(data, reason)
        %{data | configuration_error: reason}
    end
  end

  @spec current_output_sm_image(%Slave{}, atom(), tuple(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  def current_output_sm_image(data, domain_id, sm_key, sm_size) do
    case Map.fetch(data.output_sm_images || %{}, sm_key) do
      {:ok, image} when byte_size(image) == sm_size -> {:ok, image}
      {:ok, image} -> {:ok, binary_pad(image, sm_size)}
      :error -> read_output_sm_image_from_domain(data, domain_id, sm_key, sm_size)
    end
  end

  @spec stage_output_sm_image(%Slave{}, tuple(), [atom()], binary()) ::
          :ok | {:error, term()}
  def stage_output_sm_image(data, sm_key, domain_ids, next_value) do
    key = {data.name, sm_key}

    Enum.reduce_while(domain_ids, :ok, fn attached_domain_id, :ok ->
      with :ok <- DomainAPI.write(attached_domain_id, key, next_value),
           {:ok, ^next_value} <- DomainAPI.read(attached_domain_id, key) do
        {:cont, :ok}
      else
        {:ok, _other} -> {:halt, {:error, {:staging_verification_failed, attached_domain_id}}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @spec log_configuration_error(%Slave{}, term()) :: :ok
  def log_configuration_error(data, :invalid_process_data_request) do
    Logger.warning("[Slave #{data.name}] invalid process_data request")
  end

  def log_configuration_error(data, {:signal_not_in_driver_model, signal_name}) do
    Logger.warning("[Slave #{data.name}] #{inspect(signal_name)} not in driver model")
  end

  def log_configuration_error(data, {:invalid_signal_model, signal_name}) do
    Logger.warning(
      "[Slave #{data.name}] #{inspect(signal_name)} has an invalid signal declaration"
    )
  end

  def log_configuration_error(data, {:pdo_not_in_sii, pdo_index}) do
    Logger.warning("[Slave #{data.name}] PDO 0x#{Integer.to_string(pdo_index, 16)} not in SII")
  end

  def log_configuration_error(data, {:signal_range_out_of_bounds, signal_name, pdo_index}) do
    Logger.warning(
      "[Slave #{data.name}] #{inspect(signal_name)} exceeds PDO 0x#{Integer.to_string(pdo_index, 16)} bounds"
    )
  end

  def log_configuration_error(data, {:sm_not_in_sii, sm_index}) do
    Logger.warning("[Slave #{data.name}] SM#{sm_index} not found in SII")
  end

  def log_configuration_error(data, {:signal_name_conflicts_with_latch, signal_name}) do
    Logger.warning(
      "[Slave #{data.name}] #{inspect(signal_name)} conflicts with a configured latch name"
    )
  end

  def log_configuration_error(data, {:mailbox_config_failed, index, subindex, reason}) do
    Logger.warning(
      "[Slave #{data.name}] mailbox step 0x#{Integer.to_string(index, 16)}:0x#{Integer.to_string(subindex, 16)} failed: #{inspect(reason)}"
    )
  end

  def log_configuration_error(data, {:invalid_mailbox_step, step}) do
    Logger.warning("[Slave #{data.name}] invalid mailbox step: #{inspect(step)}")
  end

  def log_configuration_error(data, {:domain_register_failed, sm_index, reason}) do
    Logger.warning(
      "[Slave #{data.name}] domain registration for SM#{sm_index} failed: #{inspect(reason)}"
    )
  end

  def log_configuration_error(data, {:domain_reregister_required, sm_index, domain_id}) do
    Logger.warning(
      "[Slave #{data.name}] SM#{sm_index} in domain #{inspect(domain_id)} needs domain re-registration; reconnect self-heal cannot reuse the cached logical address"
    )
  end

  def log_configuration_error(data, {:fmmu_limit_reached, required_fmmus, available_fmmus}) do
    Logger.warning(
      "[Slave #{data.name}] process-data layout needs #{required_fmmus} FMMUs but hardware supports #{available_fmmus}"
    )
  end

  def log_configuration_error(data, {:sync_manager_write_failed, sm_index, reason}) do
    Logger.warning("[Slave #{data.name}] SM#{sm_index} write failed: #{inspect(reason)}")
  end

  def log_configuration_error(data, {:sync_manager_activate_failed, sm_index, reason}) do
    Logger.warning("[Slave #{data.name}] SM#{sm_index} activation failed: #{inspect(reason)}")
  end

  def log_configuration_error(data, {:fmmu_write_failed, sm_index, reason}) do
    Logger.warning("[Slave #{data.name}] FMMU write for SM#{sm_index} failed: #{inspect(reason)}")
  end

  def log_configuration_error(data, {:sync_manager_write_failed, sm_index}) do
    Logger.warning("[Slave #{data.name}] SM#{sm_index} write failed")
  end

  def log_configuration_error(data, {:sync_manager_activate_failed, sm_index}) do
    Logger.warning("[Slave #{data.name}] SM#{sm_index} activation failed")
  end

  def log_configuration_error(data, {:fmmu_write_failed, sm_index}) do
    Logger.warning("[Slave #{data.name}] FMMU write for SM#{sm_index} failed")
  end

  def log_configuration_error(data, {:error, reason}) do
    Logger.warning("[Slave #{data.name}] process-data configuration failed: #{inspect(reason)}")
  end

  def log_configuration_error(data, reason) do
    Logger.warning("[Slave #{data.name}] process-data configuration failed: #{inspect(reason)}")
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
      case DomainAPI.read(domain_id, key) do
        {:ok, image} -> binary_pad(image, sm_size)
        {:error, _} -> nil
      end
    end)
  end

  defp read_output_sm_image_from_domain(data, domain_id, sm_key, sm_size) do
    case DomainAPI.read(domain_id, {data.name, sm_key}) do
      {:ok, image} -> {:ok, binary_pad(image, sm_size)}
      {:error, _} = err -> err
    end
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
       when is_map(registrations) and map_size(registrations) > 0 do
    case cached_domain_offset(registrations, sm_group, attachment) do
      {:ok, offset} -> {:ok, offset}
      :error -> {:error, {:domain_reregister_required, sm_group.sm_index, attachment.domain_id}}
    end
  end

  defp register_process_data_domain(data, %SmGroup{} = sm_group, %DomainAttachment{} = attachment) do
    case DomainAPI.register_pdo(
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

  @doc false
  @spec cached_domain_offset(map(), SmGroup.t(), DomainAttachment.t()) ::
          {:ok, non_neg_integer()} | :error
  def cached_domain_offset(
        registrations,
        %SmGroup{} = sm_group,
        %DomainAttachment{} = attachment
      )
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
        Utils.ensure_expected_wkcs(replies, 1, {:sync_manager_write_failed, sm_group.sm_index})

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
        Utils.ensure_expected_wkcs(replies, 1, {:fmmu_write_failed, sm_group.sm_index})

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
        Utils.ensure_expected_wkcs(replies, 1, {:sync_manager_activate_failed, sm_group.sm_index})

      {:error, reason} ->
        {:error, {:sync_manager_activate_failed, sm_group.sm_index, reason}}
    end
  end

  defp call_signal_model(data) do
    Driver.signal_model(data.driver, data.config, data.sii_pdo_configs)
  end

  defp binary_pad(data, size) when byte_size(data) >= size, do: binary_part(data, 0, size)
  defp binary_pad(data, size), do: data <> :binary.copy(<<0>>, size - byte_size(data))
end
