defmodule EtherCAT.Provisioning do
  @moduledoc """
  Session-bound provisioning and low-level configuration API.

  Use this module for PREOP-first workflows, direct SDO traffic, and runtime
  activation control. Every operation requires the `%EtherCAT.Session{}` that
  owns the target runtime.

  ## PREOP-first workflow

  1. Supervise `EtherCAT.Runtime` and start a session with a `:backend` and the
     domains you will need, but no `:slaves` list.
  2. Call `EtherCAT.await_ready/2`. Discovery holds devices in PREOP under positional
     names (`:coupler`, `:slave_1`, …); inspect `EtherCAT.Diagnostics.slaves/1`
     before choosing a driver.
  3. Use `configure_slave/3` to supply a driver, driver config, process-data
     assignments, and `target_state: :op` for each device that should activate.
     Refer only to domain IDs declared at session startup.
  4. Call `activate/1`, then `EtherCAT.await_operational/2`. Slaves intentionally
     left with `target_state: :preop` are not promoted to OP.
  5. Inspect status and samples. If activation fails, inspect
     `EtherCAT.Diagnostics.master_status/1` and `EtherCAT.Diagnostics.last_failure/1`
     rather than assuming the ring is operational.

  To change configuration after activation, first use
  `deactivate(session, :preop)`. The default `deactivate(session)` holds at SAFEOP,
  which is not the configuration state. Neither operation ends the session;
  `EtherCAT.stop/1` does.

  ## Mailbox traffic

  SDO uploads return raw binaries. Downloads accept raw binaries; choose the
  object width, signedness, and byte order from the device's object dictionary.
  For example, given a live session and a mailbox-capable slave named `:drive`:

      {:ok, device_name} = EtherCAT.Provisioning.upload_sdo(session, :drive, 0x1008, 0x00)

  Mailbox support and allowed AL states are device-specific. An SDO failure is
  returned explicitly, including protocol and device abort errors. A failed or
  timed-out write may already have reached the device; do not blindly retry
  non-idempotent operations. Provisioning and output writes are not a safety stop.
  """

  alias EtherCAT.DC
  alias EtherCAT.Session
  alias EtherCAT.Slave

  @doc "Wait for the session's active DC monitor to report lock; does not enable DC."
  @spec await_dc_locked(Session.t(), pos_integer()) :: :ok | {:error, term()}
  def await_dc_locked(session, timeout_ms \\ 5_000) do
    with {:ok, dc_server} <- Session.call(session, :dc_runtime) do
      result = DC.await_locked(dc_server, timeout_ms)

      case Session.call(session, :state) do
        {:error, _reason} = error -> error
        _state -> result
      end
    end
  end

  @doc """
  Update one slave while the session and the slave are in PREOP.

  Keyword options update the existing configuration; a `EtherCAT.Slave.Config`
  struct supplies a replacement. The name cannot change. Supported fields are
  `:driver`, `:config`, `:process_data`, `:target_state`, `:sync`, and `:health_poll_ms`.
  Domains must already exist. Layout changes remain subject to PREOP and domain
  registration checks; an error is not a request to silently discard mappings.
  """
  @spec configure_slave(Session.t(), atom(), keyword() | EtherCAT.Slave.Config.t()) ::
          :ok | {:error, term()}
  def configure_slave(session, slave_name, opts) when is_atom(slave_name) do
    Session.call(session, {:configure_slave, slave_name, opts})
  end

  @doc "Attempt cyclic activation for slaves configured with `target_state: :op`."
  @spec activate(Session.t()) :: :ok | {:error, term()}
  def activate(session), do: Session.call(session, :activate)

  @doc """
  Stop cyclic runtime and retreat activatable slaves to SAFEOP (default) or PREOP.

  The session remains live. Check the result and runtime status for incomplete
  transitions; this API does not replace hardware safety mechanisms.
  """
  @spec deactivate(Session.t(), :safeop | :preop) :: :ok | {:error, term()}
  def deactivate(session, target \\ :safeop)

  def deactivate(session, target) when target in [:safeop, :preop] do
    Session.call(session, {:deactivate, target})
  end

  def deactivate(_session, _target), do: {:error, :invalid_deactivate_target}

  @doc """
  Update a domain period in microseconds, using a whole-millisecond value.

  The runtime validates the affected slave synchronization configuration too;
  callers must handle rejection rather than assuming the new period was applied.
  """
  @spec update_domain_cycle_time(Session.t(), atom(), pos_integer()) :: :ok | {:error, term()}
  def update_domain_cycle_time(session, domain_id, cycle_time_us)
      when is_atom(domain_id) and is_integer(cycle_time_us) and cycle_time_us > 0 do
    Session.call(session, {:update_domain_cycle_time, domain_id, cycle_time_us})
  end

  @doc "Download one non-empty raw binary to a CoE object on a named slave."
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

  @doc "Upload one CoE object from a named slave as a raw binary."
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
