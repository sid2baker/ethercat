defmodule EtherCAT.Master do
  @moduledoc """
  Master orchestrates startup, activation, deactivation, and runtime recovery
  for the local EtherCAT session.

  `EtherCAT.Master` is the specialist boundary for the master lifecycle. It owns
  the singleton session exposed through `EtherCAT.state/0`, while internal
  helpers own bus discovery, slave bring-up, activation, deactivation,
  recovery, and status projection. Normal application-facing runtime usage
  should stay on `EtherCAT`, `EtherCAT.Provisioning`, or
  `EtherCAT.Diagnostics`.

  Before the master reports `:preop_ready` or starts OP activation, it
  quiesces the bus. That extra drain window keeps late startup traffic from
  leaking into the first public mailbox/configuration exchange or the first OP
  transition datagrams.

  ## Lifecycle states

  - `:idle` - no active session
  - `:discovering` - scanning the bus, counting slaves, assigning stations, and preparing startup
  - `:awaiting_preop` - waiting for configured slaves to reach PREOP
  - `:preop_ready` - all configured slaves reached PREOP and the session is ready for activation or dynamic configuration
  - `:deactivated` - the session stays live below OP on purpose
  - `:operational` - cyclic runtime is active; non-critical slave-local faults may still be tracked
  - `:activation_blocked` - the desired runtime target was not fully reached
  - `:recovering` - critical runtime faults are being healed

  ## Startup sequencing

  ```mermaid
  sequenceDiagram
      autonumber
      participant App
      participant Master
      participant Bus
      participant DC
      participant Domain
      participant Slave

      App->>Master: start/1
      Master->>Bus: count slaves, assign stations, verify link
      opt DC is configured
          Master->>DC: initialize clocks
      end
      Master->>Domain: start domains in open state
      Master->>Slave: start slave processes
      Slave->>Bus: reach PREOP through INIT, SII, and mailbox setup
      Slave->>Domain: register PDO layout
      Slave-->>Master: report ready at PREOP
      opt activation is requested and possible
          opt DC runtime is available
              Master->>DC: start runtime maintenance
          end
          Master->>Domain: start cyclic exchange
          opt DC lock is required
              Master->>DC: wait for lock
          end
          Master->>Slave: request SAFEOP
          Master->>Slave: request OP
      end
      Master-->>App: state becomes preop_ready, activation_blocked, or operational
  ```

  ## Recovery model

  Domains, slaves, and DC report runtime faults back to the master. Critical
  faults move the session into `:recovering`; slave-local non-critical faults
  can remain visible while the master stays `:operational`.

  ```mermaid
  stateDiagram-v2
      [*] --> idle
      idle --> discovering: start/1
      discovering --> awaiting_preop: configured slaves are still pending
      discovering --> idle: startup fails or stop/0
      awaiting_preop --> preop_ready: all slaves reached PREOP, no activation requested
      awaiting_preop --> operational: all slaves reached PREOP and activation succeeds
      awaiting_preop --> activation_blocked: activation is incomplete
      awaiting_preop --> idle: timeout, fatal startup failure, or stop/0
      preop_ready --> operational: activate/0 succeeds
      preop_ready --> activation_blocked: activate/0 is incomplete
      preop_ready --> recovering: critical runtime fault
      preop_ready --> idle: stop/0 or fatal subsystem exit
      deactivated --> operational: activate/0 succeeds
      deactivated --> preop_ready: deactivate to PREOP
      deactivated --> activation_blocked: target transition remains incomplete
      deactivated --> recovering: critical runtime fault
      deactivated --> idle: stop/0 or fatal subsystem exit
      operational --> recovering: critical runtime fault
      operational --> deactivated: deactivate/0 settles in SAFEOP
      operational --> preop_ready: deactivate to PREOP
      operational --> idle: stop/0 or fatal subsystem exit
      activation_blocked --> operational: activation failures clear and target is OP
      activation_blocked --> deactivated: transition failures clear and target is SAFEOP
      activation_blocked --> preop_ready: transition failures clear and target is PREOP
      activation_blocked --> recovering: runtime faults remain after activation retry
      activation_blocked --> idle: stop/0 or fatal subsystem exit
      recovering --> operational: critical runtime faults are cleared and target is OP
      recovering --> deactivated: critical runtime faults are cleared and target is SAFEOP
      recovering --> preop_ready: critical runtime faults are cleared and target is PREOP
      recovering --> idle: stop/0 or recovery fails
  ```
  """

  alias EtherCAT.Bus
  alias EtherCAT.DC
  alias EtherCAT.Master.FSM
  alias EtherCAT.Utils

  @call_timeout_ms 5_000
  @wait_call_grace_floor_ms 10
  @wait_call_grace_cap_ms 100
  @base_station 0x1000

  @type server :: :gen_statem.server_ref()

  @type t :: %__MODULE__{
          bus_ref: reference() | nil,
          dc_ref: reference() | nil,
          dc_ref_station: non_neg_integer() | nil,
          dc_stations: [non_neg_integer()],
          domain_configs: [EtherCAT.Domain.Config.t()] | nil,
          slave_configs: [EtherCAT.Slave.Config.t()] | nil,
          dc_config: EtherCAT.DC.Config.t() | nil,
          frame_timeout_floor_ms: pos_integer(),
          frame_timeout_override_ms: pos_integer() | nil,
          scan_poll_ms: pos_integer() | nil,
          scan_stable_ms: pos_integer() | nil,
          base_station: non_neg_integer(),
          desired_runtime_target: :preop | :safeop | :op,
          activatable_slaves: [atom()],
          slaves: [map()],
          scan_window: [{integer(), non_neg_integer()}],
          slave_count: non_neg_integer() | nil,
          pending_preop: MapSet.t(atom()),
          activation_failures: %{optional(atom()) => term()},
          runtime_faults: %{optional(term()) => term()},
          slave_faults: %{optional(atom()) => term()},
          last_failure: map() | nil,
          await_callers: [term()],
          await_operational_callers: [term()],
          domain_refs: %{optional(reference()) => atom()},
          slave_refs: %{optional(reference()) => atom()}
        }

  defstruct [
    :bus_ref,
    :dc_ref,
    :dc_ref_station,
    :dc_stations,
    :domain_configs,
    :slave_configs,
    :dc_config,
    :frame_timeout_override_ms,
    :scan_poll_ms,
    :scan_stable_ms,
    frame_timeout_floor_ms: 5,
    base_station: @base_station,
    desired_runtime_target: :op,
    activatable_slaves: [],
    slaves: [],
    scan_window: [],
    slave_count: nil,
    pending_preop: MapSet.new(),
    activation_failures: %{},
    runtime_faults: %{},
    slave_faults: %{},
    last_failure: nil,
    await_callers: [],
    await_operational_callers: [],
    domain_refs: %{},
    slave_refs: %{}
  ]

  @doc false
  def child_spec(arg) do
    %{
      id: __MODULE__,
      start: {FSM, :start_link, [arg]},
      restart: :permanent,
      shutdown: 5000
    }
  end

  @doc false
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(arg), do: FSM.start_link(arg)

  @doc """
  Start the singleton master session with the given startup options.

  This is the direct module-level entry point behind `EtherCAT.start/1`.
  """
  @spec start(keyword()) :: :ok | {:error, term()}
  def start(opts \\ []), do: safe_call({:start, opts})

  @doc """
  Stop the current master session and tear down its runtime.

  Returns `:already_stopped` when no local master process is running.
  """
  @spec stop() :: :ok | :already_stopped | {:error, :timeout | {:server_exit, term()}}
  def stop do
    try do
      :gen_statem.call(__MODULE__, :stop)
    catch
      :exit, reason ->
        case Utils.classify_call_exit(reason, :already_stopped) do
          {:error, :already_stopped} -> :already_stopped
          {:error, _} = err -> err
        end
    end
  end

  @doc """
  Return compact runtime snapshots for all tracked slaves.

  Each entry includes the configured name, station, server reference, live pid,
  and any currently tracked slave-local fault.
  """
  @spec slaves() :: list() | {:error, :not_started | :timeout | {:server_exit, term()}}
  def slaves, do: safe_call(:slaves)

  @doc """
  Return compact runtime snapshots for configured domains.

  Each entry contains `{domain_id, live_cycle_time_us, pid}`.
  """
  @spec domains() :: list() | {:error, :not_started | :timeout | {:server_exit, term()}}
  def domains, do: safe_call(:domains)

  @doc """
  Return the stable local bus server reference, or `nil` if the session exists
  but the bus subsystem is not currently running.
  """
  @spec bus() :: Bus.server() | nil | {:error, :not_started | :timeout | {:server_exit, term()}}
  def bus, do: safe_call(:bus)

  @doc """
  Return the last retained terminal failure snapshot, if any.
  """
  @spec last_failure() :: map() | nil | {:error, :not_started | :timeout | {:server_exit, term()}}
  def last_failure, do: safe_call(:last_failure)

  @doc """
  Return the current public master lifecycle state.
  """
  @spec state() :: atom() | {:error, :not_started | :timeout | {:server_exit, term()}}
  def state, do: safe_call(:state)

  @doc """
  Apply or replace runtime configuration for one named slave.

  This is primarily used for dynamic PREOP-first workflows.
  """
  @spec configure_slave(atom(), keyword() | EtherCAT.Slave.Config.t()) :: :ok | {:error, term()}
  def configure_slave(slave_name, spec) do
    safe_call({:configure_slave, slave_name, spec})
  end

  @doc """
  Drive the current session toward its operational target.
  """
  @spec activate() :: :ok | {:error, term()}
  def activate, do: safe_call(:activate)

  @doc """
  Retreat the current session to `:safeop` or `:preop` while keeping the master
  and bus runtime alive.
  """
  @spec deactivate(:safeop | :preop) :: :ok | {:error, term()}
  def deactivate(target \\ :safeop)

  def deactivate(target) when target in [:safeop, :preop] do
    safe_call({:deactivate, target})
  end

  def deactivate(_target), do: {:error, :invalid_deactivate_target}

  @doc """
  Update the live cycle time for one configured domain.

  This does not mutate the stored startup config; it updates the running domain
  process only.
  """
  @spec update_domain_cycle_time(atom(), pos_integer()) :: :ok | {:error, term()}
  def update_domain_cycle_time(domain_id, cycle_time_us)
      when is_atom(domain_id) and is_integer(cycle_time_us) and cycle_time_us > 0 do
    safe_call({:update_domain_cycle_time, domain_id, cycle_time_us})
  end

  @doc """
  Wait until the master reaches a usable running state.
  """
  @spec await_running(pos_integer()) :: :ok | {:error, term()}
  def await_running(timeout_ms \\ 10_000), do: safe_wait_call(:await_running, timeout_ms)

  @doc """
  Wait until the master reaches full operational cyclic runtime.
  """
  @spec await_operational(pos_integer()) :: :ok | {:error, term()}
  def await_operational(timeout_ms \\ 10_000),
    do: safe_wait_call(:await_operational, timeout_ms)

  @doc """
  Return the current Distributed Clocks runtime status snapshot.
  """
  @spec dc_status() ::
          EtherCAT.DC.Status.t() | {:error, :not_started | :timeout | {:server_exit, term()}}
  def dc_status, do: safe_call(:dc_status)

  @doc """
  Return the currently selected DC reference clock as `%{name, station}`.
  """
  @spec reference_clock() ::
          {:ok, %{name: atom() | nil, station: non_neg_integer()}} | {:error, term()}
  def reference_clock, do: safe_call(:reference_clock)

  @doc """
  Wait until the active DC runtime reports a locked status.

  Returns a local master-call error if no DC runtime is currently available.
  """
  @spec await_dc_locked(pos_integer()) :: :ok | {:error, term()}
  def await_dc_locked(timeout_ms \\ 5_000) do
    case safe_call(:dc_runtime) do
      {:ok, dc_server} -> DC.await_locked(dc_server, timeout_ms)
      {:error, _} = err -> err
    end
  end

  defp safe_call(msg) do
    try do
      :gen_statem.call(__MODULE__, msg, @call_timeout_ms)
    catch
      :exit, reason -> Utils.classify_call_exit(reason, :not_started)
    end
  end

  defp safe_call(msg, timeout) do
    try do
      :gen_statem.call(__MODULE__, msg, timeout)
    catch
      :exit, reason -> Utils.classify_call_exit(reason, :not_started)
    end
  end

  defp safe_wait_call(msg, timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    safe_call(msg, timeout_ms + wait_call_grace_ms(timeout_ms))
  end

  defp wait_call_grace_ms(timeout_ms) do
    timeout_ms
    |> div(20)
    |> max(@wait_call_grace_floor_ms)
    |> min(@wait_call_grace_cap_ms)
  end
end
