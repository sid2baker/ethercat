defmodule EtherCAT.Master.Status do
  @moduledoc """
  Stable machine-readable master runtime status.
  """

  alias EtherCAT.Backend
  alias EtherCAT.DC.Status, as: DCStatus

  @type lifecycle ::
          :stopped
          | :idle
          | :discovering
          | :awaiting_preop
          | :preop_ready
          | :deactivated
          | :operational
          | :activation_blocked
          | :recovering

  @type configured_domain :: %{
          id: atom(),
          configured_cycle_time_us: pos_integer(),
          logical_base: non_neg_integer(),
          pid: pid() | nil,
          live_cycle_time_us: pos_integer() | nil
        }

  @type configured_slave :: %{
          name: atom(),
          station: non_neg_integer() | nil,
          server: :gen_statem.server_ref(),
          pid: pid() | nil,
          driver: module(),
          config: map(),
          target_state: :preop | :op,
          process_data: term(),
          health_poll_ms: pos_integer() | nil,
          fault: term() | nil
        }

  @type t :: %__MODULE__{
          lifecycle: lifecycle(),
          desired_target: :preop | :safeop | :op | nil,
          backend: Backend.t() | nil,
          configured_domains: [configured_domain()],
          configured_slaves: [configured_slave()],
          runtime_faults: %{optional(term()) => term()},
          activation_failures: %{optional(term()) => term()},
          slave_faults: %{optional(term()) => term()},
          bus_status: map() | nil,
          dc_status: DCStatus.t(),
          reference_clock: %{name: atom() | nil, station: non_neg_integer()} | nil,
          last_failure: map() | nil
        }

  defstruct lifecycle: :stopped,
            desired_target: nil,
            backend: nil,
            configured_domains: [],
            configured_slaves: [],
            runtime_faults: %{},
            activation_failures: %{},
            slave_faults: %{},
            bus_status: nil,
            dc_status: %DCStatus{lock_state: :disabled},
            reference_clock: nil,
            last_failure: nil

  @spec stopped() :: t()
  def stopped, do: %__MODULE__{}

  @spec from_runtime(lifecycle(), %EtherCAT.Master{}, map()) :: t()
  def from_runtime(lifecycle, data, observations) do
    %__MODULE__{
      lifecycle: lifecycle,
      desired_target: data.desired_runtime_target,
      backend: data.backend,
      configured_domains: observations.configured_domains,
      configured_slaves: observations.configured_slaves,
      runtime_faults: data.runtime_faults,
      activation_failures: data.activation_failures,
      slave_faults: data.slave_faults,
      bus_status: observations.bus_status,
      dc_status: observations.dc_status,
      reference_clock: reference_clock(observations.dc_status),
      last_failure: data.last_failure
    }
  end

  @spec reference_clock_reply(DCStatus.t()) ::
          {:ok, %{name: atom() | nil, station: non_neg_integer()}}
          | {:error, :dc_disabled | :no_reference_clock}
  def reference_clock_reply(%DCStatus{reference_station: station, reference_clock: name})
      when is_integer(station) do
    {:ok, %{name: name, station: station}}
  end

  def reference_clock_reply(%DCStatus{configured?: false}), do: {:error, :dc_disabled}
  def reference_clock_reply(_status), do: {:error, :no_reference_clock}

  defp reference_clock(%DCStatus{} = dc_status) do
    case reference_clock_reply(dc_status) do
      {:ok, reference_clock} -> reference_clock
      {:error, _reason} -> nil
    end
  end
end
