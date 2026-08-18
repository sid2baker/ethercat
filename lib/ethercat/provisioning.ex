defmodule EtherCAT.Provisioning do
  @moduledoc """
  Session-bound provisioning and low-level configuration API.

  Use this module for PREOP-first workflows, direct SDO traffic, and runtime
  activation control. Every operation requires the `%EtherCAT.Session{}` that
  owns the target runtime.
  """

  alias EtherCAT.DC
  alias EtherCAT.Session
  alias EtherCAT.Slave

  @spec await_dc_locked(Session.t(), pos_integer()) :: :ok | {:error, term()}
  def await_dc_locked(session, timeout_ms \\ 5_000) do
    case Session.call(session, :dc_runtime) do
      {:ok, dc_server} -> DC.await_locked(dc_server, timeout_ms)
      {:error, _reason} = error -> error
    end
  end

  @spec configure_slave(Session.t(), atom(), keyword() | EtherCAT.Slave.Config.t()) ::
          :ok | {:error, term()}
  def configure_slave(session, slave_name, opts) when is_atom(slave_name) do
    Session.call(session, {:configure_slave, slave_name, opts})
  end

  @spec activate(Session.t()) :: :ok | {:error, term()}
  def activate(session), do: Session.call(session, :activate)

  @spec deactivate(Session.t(), :safeop | :preop) :: :ok | {:error, term()}
  def deactivate(session, target \\ :safeop)

  def deactivate(session, target) when target in [:safeop, :preop] do
    Session.call(session, {:deactivate, target})
  end

  def deactivate(_session, _target), do: {:error, :invalid_deactivate_target}

  @spec update_domain_cycle_time(Session.t(), atom(), pos_integer()) :: :ok | {:error, term()}
  def update_domain_cycle_time(session, domain_id, cycle_time_us)
      when is_atom(domain_id) and is_integer(cycle_time_us) and cycle_time_us > 0 do
    Session.call(session, {:update_domain_cycle_time, domain_id, cycle_time_us})
  end

  @spec download_sdo(
          Session.t(),
          atom(),
          non_neg_integer(),
          non_neg_integer(),
          binary()
        ) :: :ok | {:error, term()}
  def download_sdo(session, slave_name, index, subindex, data)
      when is_atom(slave_name) and is_integer(index) and index >= 0 and is_integer(subindex) and
             subindex >= 0 and is_binary(data) and byte_size(data) > 0 do
    with {:ok, slave} <- Session.slave(session, slave_name) do
      Slave.download_sdo(slave, index, subindex, data)
    end
  end

  @spec upload_sdo(Session.t(), atom(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  def upload_sdo(session, slave_name, index, subindex)
      when is_atom(slave_name) and is_integer(index) and index >= 0 and is_integer(subindex) and
             subindex >= 0 do
    with {:ok, slave} <- Session.slave(session, slave_name) do
      Slave.upload_sdo(slave, index, subindex)
    end
  end
end
