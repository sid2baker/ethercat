defmodule EtherCAT.Slave.Mailbox do
  @moduledoc false

  alias EtherCAT.Slave
  alias EtherCAT.Slave.Mailbox.CoE

  @spec run_preop_config(%Slave{}) :: {:ok, %Slave{}} | {:error, term()}
  def run_preop_config(%{driver: nil} = data), do: {:ok, data}

  def run_preop_config(data) do
    data
    |> mailbox_steps()
    |> Enum.reduce_while({:ok, data}, fn step, {:ok, current_data} ->
      case run_step(current_data, step) do
        {:ok, next_data} -> {:cont, {:ok, next_data}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @spec run_sync_config(%Slave{}) :: {:ok, %Slave{}} | {:error, term()}
  def run_sync_config(%{driver: nil} = data), do: {:ok, data}

  def run_sync_config(data) do
    data
    |> sync_mailbox_steps()
    |> Enum.reduce_while({:ok, data}, fn step, {:ok, current_data} ->
      case run_step(current_data, step) do
        {:ok, next_data} -> {:cont, {:ok, next_data}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @spec download_sdo(%Slave{}, non_neg_integer(), non_neg_integer(), binary()) ::
          {:ok, %Slave{}} | {:error, term()}
  def download_sdo(%{mailbox_config: nil}, _index, _subindex, _sdo_data) do
    {:error, :mailbox_not_ready}
  end

  def download_sdo(data, index, subindex, sdo_data) do
    case CoE.download_sdo(
           data.bus,
           data.station,
           data.mailbox_config,
           data.mailbox_counter,
           index,
           subindex,
           sdo_data
         ) do
      {:ok, mailbox_counter} ->
        {:ok, %{data | mailbox_counter: mailbox_counter}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec upload_sdo(%Slave{}, non_neg_integer(), non_neg_integer()) ::
          {:ok, binary(), %Slave{}} | {:error, term()}
  def upload_sdo(%{mailbox_config: nil}, _index, _subindex) do
    {:error, :mailbox_not_ready}
  end

  def upload_sdo(data, index, subindex) do
    case CoE.upload_sdo(
           data.bus,
           data.station,
           data.mailbox_config,
           data.mailbox_counter,
           index,
           subindex
         ) do
      {:ok, value, mailbox_counter} ->
        {:ok, value, %{data | mailbox_counter: mailbox_counter}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mailbox_steps(data) do
    base_steps =
      if function_exported?(data.driver, :mailbox_config, 1) do
        data.driver.mailbox_config(data.config)
      else
        []
      end

    base_steps ++ sync_mailbox_steps(data)
  end

  defp sync_mailbox_steps(data) do
    if not is_nil(data.sync_config) and function_exported?(data.driver, :sync_mode, 2) do
      data.driver.sync_mode(data.config, data.sync_config)
    else
      []
    end
  end

  defp run_step(
         data,
         {:sdo_download, index, subindex, sdo_data}
       )
       when is_integer(index) and index >= 0 and is_integer(subindex) and subindex >= 0 and
              is_binary(sdo_data) and byte_size(sdo_data) > 0 do
    case download_sdo(data, index, subindex, sdo_data) do
      {:ok, new_data} ->
        {:ok, new_data}

      {:error, reason} ->
        {:error, {:mailbox_config_failed, index, subindex, reason}}
    end
  end

  defp run_step(_data, step), do: {:error, {:invalid_mailbox_step, step}}
end
