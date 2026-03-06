defmodule EtherCAT.Slave.ALTransitionTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Slave.ALTransition

  test "only treats target state as reached when the error bit is clear" do
    assert ALTransition.target_reached?(<<0::3, 0::1, 0x02::4, 0::8>>, 0x02)
    refute ALTransition.target_reached?(<<0::3, 1::1, 0x02::4, 0::8>>, 0x02)
  end

  test "detects latched AL errors and derives the acknowledge value from the current state" do
    status = <<0::3, 1::1, 0x04::4, 0::8>>

    assert ALTransition.error_latched?(status)
    assert ALTransition.ack_value(status) == 0x14
  end

  test "preserves ack write failures in the returned transition reason" do
    assert {:error, {:al_error, 0x001D, {:ack_failed, :no_response}}} =
             ALTransition.classify_ack_write(0x001D, {:ok, [%{wkc: 0}]})

    assert {:error, {:al_error, 0x001D, {:ack_failed, {:unexpected_wkc, 2}}}} =
             ALTransition.classify_ack_write(0x001D, {:ok, [%{wkc: 2}]})

    assert {:error, {:al_error, 0x001D, {:ack_failed, :timeout}}} =
             ALTransition.classify_ack_write(0x001D, {:error, :timeout})
  end
end
