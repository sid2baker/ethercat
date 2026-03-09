defmodule EtherCAT.Master.Startup.Verification do
  @moduledoc false

  @type status :: %{
          required(:station) => non_neg_integer(),
          optional(:state) => non_neg_integer() | nil,
          optional(:error) => 0 | 1 | nil,
          optional(:error_code) => non_neg_integer() | nil
        }

  @spec blocking_statuses([status()]) :: [status()]
  def blocking_statuses(statuses) when is_list(statuses) do
    Enum.reject(statuses, &ready_for_configuration?/1)
  end

  @spec lingering_error_statuses([status()]) :: [status()]
  def lingering_error_statuses(statuses) when is_list(statuses) do
    Enum.filter(statuses, &lingering_error?/1)
  end

  @spec ready_for_configuration?(status()) :: boolean()
  def ready_for_configuration?(%{state: 0x01}), do: true
  def ready_for_configuration?(_status), do: false

  @spec lingering_error?(status()) :: boolean()
  def lingering_error?(%{state: 0x01, error: 1}), do: true
  def lingering_error?(_status), do: false
end
