defmodule EtherCAT.SlaveDescriptionTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Endpoint
  alias EtherCAT.SlaveDescription

  test "native_description returns driver-native endpoints" do
    description = SlaveDescription.native_description(EtherCAT.Driver.EL1809, %{})

    assert description.device_type == :digital_input
    assert length(description.endpoints) == 16

    assert %Endpoint{
             signal: :ch1,
             direction: :input,
             type: :boolean
           } = hd(description.endpoints)
  end

  test "configured keeps canonical endpoint names" do
    description =
      SlaveDescription.from_config(%EtherCAT.Slave.Config{
        name: :inputs,
        driver: EtherCAT.Driver.EL1809,
        config: %{},
        target_state: :op
      })

    assert description.name == :inputs
    assert description.driver == EtherCAT.Driver.EL1809
    assert description.target_state == :op

    assert Enum.take(description.endpoints, 2) == [
             %Endpoint{signal: :ch1, direction: :input, type: :boolean},
             %Endpoint{signal: :ch2, direction: :input, type: :boolean}
           ]
  end

  test "from_config builds descriptions from retained configuration" do
    description =
      SlaveDescription.from_config(%EtherCAT.Slave.Config{
        name: :outputs,
        driver: EtherCAT.Driver.EL2809,
        config: %{},
        target_state: :op,
        process_data: {:all, :io},
        health_poll_ms: 250
      })

    assert description.name == :outputs
    assert description.target_state == :op

    assert Enum.at(description.endpoints, 0) ==
             %Endpoint{signal: :ch1, direction: :output, type: :boolean}
  end
end
