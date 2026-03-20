defmodule EtherCAT.Provisioning do
  @moduledoc """
  Advanced provisioning and low-level configuration API.

  Use this module for PREOP-first workflows, direct SDO traffic, and runtime
  activation control. Normal machine-facing runtime control should stay on
  `EtherCAT`.
  """

  alias EtherCAT.Master
  alias EtherCAT.Slave

  @spec await_dc_locked(timeout_ms :: pos_integer()) :: :ok | {:error, term()}
  def await_dc_locked(timeout_ms \\ 5_000), do: Master.await_dc_locked(timeout_ms)

  @spec configure_slave(atom(), keyword() | EtherCAT.Slave.Config.t()) :: :ok | {:error, term()}
  def configure_slave(slave_name, opts), do: Master.configure_slave(slave_name, opts)

  @spec activate() :: :ok | {:error, term()}
  def activate, do: Master.activate()

  @spec deactivate(:safeop | :preop) :: :ok | {:error, term()}
  def deactivate(target \\ :safeop), do: Master.deactivate(target)

  @spec update_domain_cycle_time(atom(), pos_integer()) :: :ok | {:error, term()}
  def update_domain_cycle_time(domain_id, cycle_time_us),
    do: Master.update_domain_cycle_time(domain_id, cycle_time_us)

  @spec download_sdo(atom(), non_neg_integer(), non_neg_integer(), binary()) ::
          :ok | {:error, term()}
  def download_sdo(slave_name, index, subindex, data),
    do: Slave.download_sdo(slave_name, index, subindex, data)

  @spec upload_sdo(atom(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  def upload_sdo(slave_name, index, subindex),
    do: Slave.upload_sdo(slave_name, index, subindex)
end
