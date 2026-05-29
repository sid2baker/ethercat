defmodule EtherCAT.Master.StartupVerificationTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Master.Startup

  test "treats init state as ready even when the AL error latch remains set" do
    statuses = [
      %{station: 0x1000, state: 0x01, error: 1, error_code: 0},
      %{station: 0x1001, state: 0x01, error: 0, error_code: nil}
    ]

    assert Startup.blocking_init_statuses(statuses) == []

    assert Startup.lingering_init_error_statuses(statuses) == [
             %{station: 0x1000, state: 0x01, error: 1, error_code: 0}
           ]
  end

  test "keeps non-init states as blockers" do
    statuses = [
      %{station: 0x1000, state: 0x02, error: 1, error_code: 0x0011},
      %{station: 0x1001, state: nil, error: nil, error_code: nil},
      %{station: 0x1002, state: 0x01, error: 0, error_code: nil}
    ]

    assert Startup.blocking_init_statuses(statuses) == [
             %{station: 0x1000, state: 0x02, error: 1, error_code: 0x0011},
             %{station: 0x1001, state: nil, error: nil, error_code: nil}
           ]
  end
end
