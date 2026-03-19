defmodule EtherCAT.Slave.Runtime.Polling do
  @moduledoc false

  alias EtherCAT.Slave.Runtime.Health

  @spec op_enter_actions(%{
          optional(:latch_poll_ms) => integer() | nil,
          optional(:health_poll_ms) => integer() | nil
        }) ::
          list()
  def op_enter_actions(data) do
    latch_poll_actions(data) ++ health_poll_actions(data)
  end

  @spec preop_enter_actions(%{optional(:health_poll_ms) => integer() | nil}) :: list()
  def preop_enter_actions(data) do
    health_poll_actions(data)
  end

  @spec safeop_enter_actions(%{optional(:health_poll_ms) => integer() | nil}) :: list()
  def safeop_enter_actions(data) do
    health_poll_actions(data)
  end

  @spec down_enter_actions(%{health_poll_ms: pos_integer()}) :: list()
  def down_enter_actions(%{health_poll_ms: poll_ms}) do
    [Health.health_poll_action(poll_ms)]
  end

  @spec reschedule_latch_poll(pos_integer()) :: [{:state_timeout, pos_integer(), :latch_poll}]
  def reschedule_latch_poll(poll_ms), do: [{:state_timeout, poll_ms, :latch_poll}]

  defp latch_poll_actions(%{latch_poll_ms: poll_ms}) when is_integer(poll_ms) and poll_ms > 0 do
    reschedule_latch_poll(poll_ms)
  end

  defp latch_poll_actions(_data), do: []

  defp health_poll_actions(%{health_poll_ms: poll_ms})
       when is_integer(poll_ms) and poll_ms > 0 do
    [Health.health_poll_action(poll_ms)]
  end

  defp health_poll_actions(_data), do: []
end
