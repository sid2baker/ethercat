defmodule EtherCAT.SubscribeTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Event
  alias EtherCAT.Slave.Runtime.DeviceState

  setup do
    case Process.whereis(EtherCAT.SubscriptionRegistry) do
      nil -> start_supervised!({Registry, keys: :duplicate, name: EtherCAT.SubscriptionRegistry})
      pid when is_pid(pid) -> pid
    end

    :ok
  end

  test "subscribe(:all) receives runtime-wide public slave events" do
    assert :ok = EtherCAT.subscribe(:all, self())

    event = Event.signal_changed(:future_slave, :ready?, true, 11, 123)

    assert :ok = DeviceState.dispatch_public_event(event)
    assert_receive ^event
  end

  test "subscribe(slave) receives driver/runtime notice events for one slave" do
    assert :ok = EtherCAT.subscribe(:future_slave, self())

    event = Event.internal(:future_slave, {:command_completed, make_ref()}, 12, 456)

    assert :ok = DeviceState.dispatch_public_event(event)
    assert_receive ^event
  end

  test "subscribe(:all, pid) delivers public events to the requested process" do
    parent = self()

    subscriber =
      spawn(fn ->
        receive do
          %Event{} = event -> send(parent, {:subscriber_received, event})
        end
      end)

    assert :ok = EtherCAT.subscribe(:all, subscriber)

    event = Event.signal_changed(:future_slave, :ready?, true, 11, 123)

    assert :ok = DeviceState.dispatch_public_event(event)
    assert_receive {:subscriber_received, ^event}
    refute_receive ^event
  end
end
