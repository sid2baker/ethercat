defmodule EtherCAT.Master.Startup.Reset do
  @moduledoc false

  alias EtherCAT.Bus.Transaction
  alias EtherCAT.Slave.ESC.Registers

  @reset_fmmu_count 3
  @reset_sm_count 4

  @type step_class :: :required | :optional
  @type step :: {step_class(), EtherCAT.Slave.ESC.Registers.reg_write()}

  @spec transaction() :: Transaction.t()
  def transaction do
    Enum.reduce(steps(), Transaction.new(), fn {_class, reg_write}, tx ->
      Transaction.bwr(tx, reg_write)
    end)
  end

  @spec validate_results([map()], pos_integer()) ::
          :ok | {:error, [non_neg_integer()], pos_integer()}
  def validate_results(replies, slave_count)
      when is_list(replies) and is_integer(slave_count) and slave_count > 0 do
    wkcs = Enum.map(replies, & &1.wkc)

    if length(replies) == length(steps()) and valid_replies?(replies, slave_count) do
      :ok
    else
      {:error, wkcs, slave_count}
    end
  end

  @spec validate_init_ack_reply([map()], pos_integer()) ::
          :ok
          | {:partial, non_neg_integer(), pos_integer()}
          | {:error, {:unexpected_wkc, integer(), pos_integer()}}
  def validate_init_ack_reply([%{wkc: wkc}], slave_count)
      when is_integer(wkc) and is_integer(slave_count) and slave_count > 0 do
    cond do
      wkc == slave_count ->
        :ok

      wkc > 0 and wkc < slave_count ->
        {:partial, wkc, slave_count}

      true ->
        {:error, {:unexpected_wkc, wkc, slave_count}}
    end
  end

  def validate_init_ack_reply(_replies, slave_count)
      when is_integer(slave_count) and slave_count > 0 do
    {:error, {:unexpected_wkc, -1, slave_count}}
  end

  @spec steps() :: [step()]
  defp steps do
    [
      {:required, Registers.dl_port_control(0x00)},
      {:required, Registers.ecat_event_mask(0x0004)},
      {:required, Registers.rx_error_counter_clear()},
      {:required, Registers.fmmu_reset(@reset_fmmu_count)},
      {:required, Registers.sm_reset(@reset_sm_count)},
      {:optional, Registers.dc_activation(0x00)},
      {:optional, Registers.dc_system_time_reset()},
      {:optional, Registers.dc_speed_counter_start(0x1000)},
      {:optional, Registers.dc_time_filter(0x0C00)},
      {:required, Registers.dl_alias_control(0x00)},
      {:required, Registers.al_control(0x11)},
      {:required, Registers.eeprom_ecat_access(0x02)},
      {:required, Registers.eeprom_ecat_access(0x00)}
    ]
  end

  defp valid_replies?(replies, slave_count) do
    steps()
    |> Enum.zip(replies)
    |> Enum.all?(fn
      {{:required, _}, %{wkc: ^slave_count}} ->
        true

      {{:optional, _}, %{wkc: wkc}}
      when is_integer(wkc) and wkc >= 0 and wkc <= slave_count ->
        true

      _ ->
        false
    end)
  end
end
