defmodule EtherCAT.Slave.Status do
  @moduledoc """
  Current protocol/runtime status for one configured EtherCAT slave.

  `:down` is a runtime connectivity state used when the configured slave no
  longer responds. The other states correspond to EtherCAT AL states.
  `last_al_error_code` is diagnostic history; it may remain populated after a
  later successful transition.
  """

  alias EtherCAT.Domain.Status, as: DomainStatus

  @type state :: :init | :preop | :safeop | :op | :bootstrap | :down

  @enforce_keys [:name, :state, :domains]
  defstruct [:name, :state, :reason, :last_al_error_code, :configuration_error, :domains]

  @type t :: %__MODULE__{
          name: atom(),
          state: state(),
          reason: term() | nil,
          last_al_error_code: non_neg_integer() | nil,
          configuration_error: term() | nil,
          domains: %{optional(atom()) => DomainStatus.t()}
        }

  @doc false
  @spec from_runtime(state(), EtherCAT.Slave.t()) :: t()
  def from_runtime(state, data) do
    %__MODULE__{
      name: data.name,
      state: state,
      reason: data.state_reason,
      last_al_error_code: data.error_code,
      configuration_error: data.configuration_error,
      domains: domain_statuses(data)
    }
  end

  defp domain_statuses(data) do
    observed_at = System.monotonic_time(:microsecond)
    registrations = data.signal_registrations || %{}

    Enum.reduce(registrations, data.domain_statuses || %{}, fn {_signal_name, registration},
                                                               acc ->
      Map.put_new_lazy(acc, registration.domain_id, fn ->
        DomainStatus.protocol_status(
          registration.domain_id,
          :open,
          :not_ready,
          nil,
          observed_at
        )
      end)
    end)
  end
end
