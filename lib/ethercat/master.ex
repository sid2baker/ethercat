defmodule EtherCAT.Master do
  @moduledoc """
  Master orchestrates startup, activation, deactivation, and runtime recovery
  for the local EtherCAT session.

  `EtherCAT.Master` is the internal master-lifecycle process. It owns the
  singleton session exposed through the opaque `EtherCAT.Session`, while
  helpers own bus discovery, slave bring-up, activation, deactivation,
  recovery, and status projection. Application-facing runtime usage stays on
  `EtherCAT`, `EtherCAT.Provisioning`, or `EtherCAT.Diagnostics` and always
  carries the owning session.

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
      discovering --> idle: startup fails or EtherCAT.stop/1
      awaiting_preop --> preop_ready: all slaves reached PREOP, no activation requested
      awaiting_preop --> operational: all slaves reached PREOP and activation succeeds
      awaiting_preop --> activation_blocked: activation is incomplete
      awaiting_preop --> idle: timeout, fatal startup failure, or EtherCAT.stop/1
      preop_ready --> operational: Provisioning.activate/1 succeeds
      preop_ready --> activation_blocked: Provisioning.activate/1 is incomplete
      preop_ready --> recovering: critical runtime fault
      preop_ready --> idle: EtherCAT.stop/1 or fatal subsystem exit
      deactivated --> operational: Provisioning.activate/1 succeeds
      deactivated --> preop_ready: deactivate to PREOP
      deactivated --> activation_blocked: target transition remains incomplete
      deactivated --> recovering: critical runtime fault
      deactivated --> idle: EtherCAT.stop/1 or fatal subsystem exit
      operational --> recovering: critical runtime fault
      operational --> deactivated: Provisioning.deactivate/1 settles in SAFEOP
      operational --> preop_ready: deactivate to PREOP
      operational --> idle: EtherCAT.stop/1 or fatal subsystem exit
      activation_blocked --> operational: activation failures clear and target is OP
      activation_blocked --> deactivated: transition failures clear and target is SAFEOP
      activation_blocked --> preop_ready: transition failures clear and target is PREOP
      activation_blocked --> recovering: runtime faults remain after activation retry
      activation_blocked --> idle: EtherCAT.stop/1 or fatal subsystem exit
      recovering --> operational: critical runtime faults are cleared and target is OP
      recovering --> deactivated: critical runtime faults are cleared and target is SAFEOP
      recovering --> preop_ready: critical runtime faults are cleared and target is PREOP
      recovering --> idle: EtherCAT.stop/1 or recovery fails
  ```
  """

  alias EtherCAT.Master.FSM
  alias EtherCAT.Master.Status
  alias EtherCAT.Utils

  @call_timeout_ms 5_000
  @base_station 0x1000

  @type server :: :gen_statem.server_ref()

  @typedoc false
  @type t :: %__MODULE__{
          generation: reference() | nil,
          bus_ref: reference() | nil,
          dc_ref: reference() | nil,
          dc_ref_station: non_neg_integer() | nil,
          dc_stations: [non_neg_integer()],
          backend: EtherCAT.Backend.t() | nil,
          domain_configs: [EtherCAT.Master.Config.Domain.plan()],
          slave_configs: [EtherCAT.Slave.Config.t()],
          dc_config: EtherCAT.DC.Config.t() | nil,
          frame_timeout_floor_ms: pos_integer(),
          frame_timeout_override_ms: pos_integer() | nil,
          scan_poll_ms: pos_integer() | nil,
          scan_stable_ms: pos_integer() | nil,
          base_station: non_neg_integer(),
          desired_runtime_target: :preop | :safeop | :op | nil,
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
    :generation,
    :bus_ref,
    :dc_ref,
    :dc_ref_station,
    :dc_stations,
    :backend,
    :dc_config,
    :frame_timeout_override_ms,
    :scan_poll_ms,
    :scan_stable_ms,
    frame_timeout_floor_ms: 5,
    base_station: @base_station,
    desired_runtime_target: nil,
    domain_configs: [],
    slave_configs: [],
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
    Supervisor.child_spec(
      %{
        id: __MODULE__,
        start: {FSM, :start_link, [arg]}
      },
      restart: :permanent,
      shutdown: 5000
    )
  end

  @doc false
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(arg), do: FSM.start_link(arg)

  @doc false
  @spec start_session(keyword()) :: {:ok, reference(), pid()} | {:error, term()}
  def start_session(opts \\ []), do: safe_call({:start, opts})

  @doc false
  @spec current_status() :: Status.t() | {:error, term()}
  def current_status do
    with {:ok, session} <- EtherCAT.Session.current(),
         {:ok, status} <- EtherCAT.Diagnostics.master_status(session) do
      status
    else
      {:error, :not_started} -> Status.stopped()
      {:error, _reason} = error -> error
    end
  end

  defp safe_call(message) do
    Utils.statem_call(__MODULE__, message, :not_started, @call_timeout_ms)
  end
end
