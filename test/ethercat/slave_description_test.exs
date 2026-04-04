defmodule EtherCAT.SlaveDescriptionTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Endpoint
  alias EtherCAT.SlaveDescription

  test "native_description returns driver-native endpoints" do
    description = SlaveDescription.native_description(EtherCAT.Driver.EL1809, %{})

    assert description.device_type == :digital_input
    assert description.commands == []
    assert length(description.endpoints) == 16

    assert %Endpoint{
             signal: :ch1,
             direction: :input,
             type: :boolean
           } = hd(description.endpoints)
  end

  test "configured keeps canonical endpoint names" do
    description =
      SlaveDescription.configured(
        :inputs,
        EtherCAT.Driver.EL1809,
        %{},
        station: 0x1001,
        target_state: :op,
        fault: {:down, :link_lost}
      )

    assert description.name == :inputs
    assert description.driver == EtherCAT.Driver.EL1809
    assert description.station == 0x1001
    assert description.target_state == :op
    assert description.fault == {:down, :link_lost}

    assert Enum.take(description.endpoints, 2) == [
             %Endpoint{signal: :ch1, direction: :input, type: :boolean},
             %Endpoint{signal: :ch2, direction: :input, type: :boolean}
           ]
  end

  test "from_configured_slave builds descriptions from retained config plus runtime summary" do
    description =
      SlaveDescription.from_configured_slave(%{
        name: :outputs,
        station: 0x1002,
        server: {:via, Registry, {EtherCAT.Registry, {:slave, :outputs}}},
        pid: self(),
        driver: EtherCAT.Driver.EL2809,
        config: %{},
        target_state: :op,
        process_data: {:all, :io},
        health_poll_ms: 250,
        fault: nil
      })

    assert description.name == :outputs
    assert description.station == 0x1002
    assert description.pid == self()
    assert description.target_state == :op
    assert description.commands == []

    assert Enum.at(description.endpoints, 0) ==
             %Endpoint{signal: :ch1, direction: :output, type: :boolean}
  end
end
