defmodule EtherCAT.Slave do
  @moduledoc """
  Runtime boundary for one physical slave.

  `EtherCAT.Slave` owns AL-state transitions, mailbox setup, process-data
  registration, health polling, reconnect handling, and signal delivery for one
  named slave runtime.

  One slave process is started per configured name and registered under
  `{:slave, name}`.

  Normal protocol-level runtime usage should go through `EtherCAT`.

  This module remains the runtime/process boundary beneath that public API.

  ## State transitions

  ```mermaid
  stateDiagram-v2
      state "INIT" as init
      state "BOOTSTRAP" as bootstrap
      state "PREOP" as preop
      state "SAFEOP" as safeop
      state "OP" as op
      state "DOWN" as down
      [*] --> init
      init --> preop: auto-advance succeeds
      init --> init: auto-advance retries
      init --> bootstrap: bootstrap is requested
      init --> safeop: SAFEOP request path succeeds
      init --> op: OP request path succeeds
      bootstrap --> init: INIT is requested
      preop --> safeop: SAFEOP is requested
      preop --> op: OP is requested
      preop --> init: INIT is requested or AL health regresses to INIT
      preop --> bootstrap: AL health regresses to BOOTSTRAP
      preop --> down: health poll sees bus loss or zero WKC
      safeop --> op: OP is requested
      safeop --> preop: PREOP is requested or AL health regresses to PREOP
      safeop --> init: INIT is requested or AL health regresses to INIT
      safeop --> bootstrap: AL health regresses to BOOTSTRAP
      safeop --> down: health poll sees bus loss or zero WKC
      op --> safeop: SAFEOP is requested or AL health retreats
      op --> preop: PREOP is requested
      op --> init: INIT is requested
      op --> down: health poll sees bus loss or zero WKC
      down --> preop: link/position probe succeeds and PREOP rebuild succeeds
      down --> init: reconnect rebuild retries from INIT
  ```
  """

  alias EtherCAT.Slave.FSM
  alias EtherCAT.Utils

  @type server :: :gen_statem.server_ref()

  @type t :: %__MODULE__{
          bus: EtherCAT.Bus.server() | nil,
          position: non_neg_integer() | nil,
          station: non_neg_integer() | nil,
          name: atom() | nil,
          driver: module() | nil,
          config: map(),
          samples: %{optional(atom()) => EtherCAT.Sample.t()},
          protocol_subscriptions: MapSet.t(pid()),
          domain_statuses: %{optional(atom()) => EtherCAT.Domain.Status.t()},
          state_reason: term() | nil,
          error_code: non_neg_integer() | nil,
          configuration_error: term() | nil,
          identity: map() | nil,
          esc_info: map() | nil,
          mailbox_config: map() | nil,
          mailbox_counter: non_neg_integer() | nil,
          dc_cycle_ns: non_neg_integer() | nil,
          sync_config: EtherCAT.Slave.Sync.Config.t() | nil,
          sii_sm_configs: list() | nil,
          sii_pdo_configs: list() | nil,
          process_data_request: :none | {:all, atom()} | [{atom(), atom()}] | nil,
          latch_names: map(),
          active_latches: list() | nil,
          latch_poll_ms: pos_integer() | nil,
          health_poll_ms: pos_integer() | nil,
          signal_registrations: map() | nil,
          signal_registrations_by_sm: map() | nil,
          output_domain_ids_by_sm: map() | nil,
          output_sm_images: map() | nil,
          subscriptions: map() | nil,
          subscriber_refs: %{optional(pid()) => reference()},
          startup_retry_phase: atom() | nil,
          startup_retry_count: non_neg_integer()
        }

  defstruct [
    :bus,
    :position,
    :station,
    :name,
    :driver,
    :config,
    :state_reason,
    :error_code,
    :configuration_error,
    :identity,
    :esc_info,
    :mailbox_config,
    :mailbox_counter,
    :dc_cycle_ns,
    :sync_config,
    :sii_sm_configs,
    :sii_pdo_configs,
    :process_data_request,
    :latch_names,
    :active_latches,
    :latch_poll_ms,
    :health_poll_ms,
    :signal_registrations,
    :signal_registrations_by_sm,
    :output_domain_ids_by_sm,
    :output_sm_images,
    :subscriptions,
    samples: %{},
    protocol_subscriptions: MapSet.new(),
    domain_statuses: %{},
    subscriber_refs: %{},
    startup_retry_phase: nil,
    startup_retry_count: 0
  ]

  @doc false
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: {__MODULE__, name},
      start: {FSM, :start_link, [opts]},
      type: :worker,
      restart: :temporary,
      shutdown: 5000
    }
  end

  @doc false
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts), do: FSM.start_link(opts)

  @doc false
  @spec subscribe_protocol(atom(), pid()) ::
          {:ok, EtherCAT.Slave.Status.t(), %{optional(atom()) => EtherCAT.Sample.t()}}
          | {:error, :not_found | :timeout | {:server_exit, term()}}
  def subscribe_protocol(slave_name, pid \\ self()) do
    safe_call(slave_name, {:subscribe_protocol, pid})
  end

  @doc """
  Subscribe `pid` to a registered process-data signal or configured latch name.

  Signal updates arrive as `{:ethercat, :signal, slave_name, signal_name, value}`.
  Latch edges arrive as `{:ethercat, :latch, slave_name, latch_name, timestamp_ns}`.
  """
  @spec subscribe(atom(), atom(), pid()) ::
          :ok
          | {:error, {:not_registered, atom()} | :not_found | :timeout | {:server_exit, term()}}
  def subscribe(slave_name, signal_name, pid) do
    safe_call(slave_name, {:subscribe, signal_name, pid})
  end

  @doc """
  Stage an output value into the slave's process image for the next domain
  cycle.
  """
  @spec write_output(atom(), atom(), term()) :: :ok | {:error, term()}
  def write_output(slave_name, signal_name, value) do
    safe_call(slave_name, {:write_output, signal_name, value})
  end

  @doc """
  Request a target AL state for the named slave.

  The runtime may walk the required intermediate path internally before the
  request completes.
  """
  @spec request(atom(), atom()) :: :ok | {:error, term()}
  def request(slave_name, target) do
    safe_call(slave_name, {:request, target})
  end

  @doc """
  Apply runtime configuration updates for one slave.
  """
  @spec configure(atom(), keyword()) :: :ok | {:error, term()}
  def configure(slave_name, opts) when is_list(opts) do
    safe_call(slave_name, {:configure, opts})
  end

  @doc """
  Retry a retained PREOP configuration failure for one slave.
  """
  @spec retry_preop_configuration(atom()) :: :ok | {:error, term()}
  def retry_preop_configuration(slave_name) do
    safe_call(slave_name, :retry_preop_configuration)
  end

  @doc """
  Return the current slave AL state.
  """
  @spec state(atom()) :: atom() | {:error, :not_found | :timeout | {:server_exit, term()}}
  def state(slave_name), do: safe_call(slave_name, :state)

  @doc """
  Return the cached identity information for the slave, if available.
  """
  @spec identity(atom()) :: map() | nil | {:error, :not_found | :timeout | {:server_exit, term()}}
  def identity(slave_name), do: safe_call(slave_name, :identity)

  @doc """
  Return the current AL error code, if the slave has reported one.
  """
  @spec error(atom()) ::
          non_neg_integer() | nil | {:error, :not_found | :timeout | {:server_exit, term()}}
  def error(slave_name), do: safe_call(slave_name, :error)

  @doc false
  @spec samples(atom()) ::
          {:ok, %{optional(atom()) => EtherCAT.Sample.t()}}
          | {:error, :not_found | :timeout | {:server_exit, term()}}
  def samples(slave_name), do: safe_call(slave_name, :samples)

  @doc false
  @spec status(atom()) ::
          {:ok, EtherCAT.Slave.Status.t()}
          | {:error, :not_found | :timeout | {:server_exit, term()}}
  def status(slave_name), do: safe_call(slave_name, :status)

  @doc """
  Return a detailed runtime snapshot for the slave.
  """
  @spec info(atom()) :: {:ok, map()} | {:error, :not_found | :timeout | {:server_exit, term()}}
  def info(slave_name), do: safe_call(slave_name, :info)

  @doc """
  Read the latest decoded value for one registered input signal.

  Returns `{:error, :not_ready}` before the first valid domain refresh and
  `{:error, {:stale, details}}` once the cached sample is older than the
  domain freshness window.
  """
  @spec read_input(atom(), atom()) :: {:ok, {term(), integer()}} | {:error, term()}
  def read_input(slave_name, signal_name) do
    safe_call(slave_name, {:read_input, signal_name})
  end

  @doc """
  Download one CoE SDO value to the slave mailbox.
  """
  @spec download_sdo(atom(), non_neg_integer(), non_neg_integer(), binary()) ::
          :ok | {:error, term()}
  def download_sdo(slave_name, index, subindex, data)
      when is_binary(data) and byte_size(data) > 0 do
    safe_call(slave_name, {:download_sdo, index, subindex, data})
  end

  @doc """
  Upload one CoE SDO value from the slave mailbox.
  """
  @spec upload_sdo(atom(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  def upload_sdo(slave_name, index, subindex) do
    safe_call(slave_name, {:upload_sdo, index, subindex})
  end

  defp safe_call(slave_name, msg) do
    try do
      :gen_statem.call(via(slave_name), msg)
    catch
      :exit, reason -> Utils.classify_call_exit(reason, :not_found)
    end
  end

  defp via(slave_name), do: {:via, Registry, {EtherCAT.Registry, {:slave, slave_name}}}
end
