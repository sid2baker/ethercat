defmodule EtherCAT.Slave do
  @moduledoc File.read!(Path.join(__DIR__, "slave.md"))

  alias EtherCAT.Slave.FSM
  alias EtherCAT.Utils

  @type server :: :gen_statem.server_ref()

  @type t :: %__MODULE__{
          bus: EtherCAT.Bus.server() | nil,
          station: non_neg_integer() | nil,
          name: atom() | nil,
          driver: module() | nil,
          config: EtherCAT.Slave.Config.t() | nil,
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
          startup_retry_count: non_neg_integer(),
          reconnect_ready?: boolean()
        }

  defstruct [
    :bus,
    :station,
    :name,
    :driver,
    :config,
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
    subscriber_refs: %{},
    startup_retry_phase: nil,
    startup_retry_count: 0,
    reconnect_ready?: false
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

  @spec subscribe(atom(), atom(), pid()) ::
          :ok | {:error, :not_found | :timeout | {:server_exit, term()}}
  def subscribe(slave_name, signal_name, pid) do
    safe_call(slave_name, {:subscribe, signal_name, pid})
  end

  @spec write_output(atom(), atom(), term()) :: :ok | {:error, term()}
  def write_output(slave_name, signal_name, value) do
    safe_call(slave_name, {:write_output, signal_name, value})
  end

  @spec request(atom(), atom()) :: :ok | {:error, term()}
  def request(slave_name, target) do
    safe_call(slave_name, {:request, target})
  end

  @spec authorize_reconnect(atom()) :: :ok | {:error, term()}
  def authorize_reconnect(slave_name), do: safe_call(slave_name, :authorize_reconnect)

  @spec configure(atom(), keyword()) :: :ok | {:error, term()}
  def configure(slave_name, opts) when is_list(opts) do
    safe_call(slave_name, {:configure, opts})
  end

  @spec retry_preop_configuration(atom()) :: :ok | {:error, term()}
  def retry_preop_configuration(slave_name) do
    safe_call(slave_name, :retry_preop_configuration)
  end

  @spec state(atom()) :: atom() | {:error, :not_found | :timeout | {:server_exit, term()}}
  def state(slave_name), do: safe_call(slave_name, :state)

  @spec identity(atom()) :: map() | nil | {:error, :not_found | :timeout | {:server_exit, term()}}
  def identity(slave_name), do: safe_call(slave_name, :identity)

  @spec error(atom()) ::
          non_neg_integer() | nil | {:error, :not_found | :timeout | {:server_exit, term()}}
  def error(slave_name), do: safe_call(slave_name, :error)

  @spec info(atom()) :: {:ok, map()} | {:error, :not_found | :timeout | {:server_exit, term()}}
  def info(slave_name), do: safe_call(slave_name, :info)

  @spec read_input(atom(), atom()) :: {:ok, {term(), integer()}} | {:error, term()}
  def read_input(slave_name, signal_name) do
    safe_call(slave_name, {:read_input, signal_name})
  end

  @spec download_sdo(atom(), non_neg_integer(), non_neg_integer(), binary()) ::
          :ok | {:error, term()}
  def download_sdo(slave_name, index, subindex, data)
      when is_binary(data) and byte_size(data) > 0 do
    safe_call(slave_name, {:download_sdo, index, subindex, data})
  end

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
