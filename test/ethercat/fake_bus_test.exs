defmodule EtherCAT.TestSupport.FakeBusTest do
  use ExUnit.Case, async: true

  alias EtherCAT.TestSupport.FakeBus

  test "plain reply lists are treated as scripted responses rather than options" do
    {:ok, bus} = start_supervised({FakeBus, [{:ok, [%{wkc: 7}]}]})

    assert {:ok, [%{wkc: 7}]} = GenServer.call(bus, {:transact, :tx, nil, 0})
  end
end
