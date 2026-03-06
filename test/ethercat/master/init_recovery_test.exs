defmodule EtherCAT.Master.InitRecoveryTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Master.InitRecovery

  test "returns no actions for clean init slaves" do
    statuses = [
      %{station: 0x1000, state: 0x01, error: 0},
      %{station: 0x1001, state: 0x01, error: 0}
    ]

    assert InitRecovery.actions(statuses) == []
  end

  test "does not try to recover slaves that are already in init" do
    statuses = [
      %{station: 0x1000, state: 0x01, error: 1}
    ]

    assert InitRecovery.actions(statuses) == []
  end

  test "acknowledges non-init errors and then re-requests init" do
    statuses = [
      %{station: 0x1000, state: 0x02, error: 1},
      %{station: 0x1001, state: 0x04, error: 0}
    ]

    assert InitRecovery.actions(statuses) == [
             {:ack_error, 0x1000, 0x12},
             {:request_init, 0x1000, 0x01},
             {:request_init, 0x1001, 0x01}
           ]
  end

  test "ignores unreadable states" do
    statuses = [
      %{station: 0x1000, state: nil, error: nil},
      %{station: 0x1001, state: nil, error: 1}
    ]

    assert InitRecovery.actions(statuses) == []
  end
end
