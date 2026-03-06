defmodule EtherCAT.Master.InitRecovery do
  @moduledoc false

  @type status :: %{
          required(:station) => non_neg_integer(),
          optional(:state) => non_neg_integer() | nil,
          optional(:error) => 0 | 1 | nil
        }

  @type action ::
          {:ack_error, non_neg_integer(), non_neg_integer()}
          | {:request_init, non_neg_integer(), 0x01}

  @spec actions([status()]) :: [action()]
  def actions(statuses) when is_list(statuses) do
    Enum.flat_map(statuses, &actions_for_status/1)
  end

  defp actions_for_status(%{station: station, state: state, error: 1})
       when is_integer(state) and state >= 0 and state <= 0x0F and state != 0x01 do
    [
      {:ack_error, station, state + 0x10},
      {:request_init, station, 0x01}
    ]
  end

  defp actions_for_status(%{station: station, state: state, error: 0})
       when is_integer(state) and state != 0x01 do
    [{:request_init, station, 0x01}]
  end

  defp actions_for_status(_status), do: []
end
