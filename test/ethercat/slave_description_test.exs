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
             name: :ch1,
             direction: :input,
             type: :boolean
           } = hd(description.endpoints)
  end

  test "effective applies slave-local aliases while keeping backing signals visible" do
    description =
      SlaveDescription.effective(
        :inputs,
        EtherCAT.Driver.EL1809,
        %{},
        %{ch1: :part_at_stop?, ch2: :clamp_closed?},
        station: 0x1001,
        target_state: :op,
        fault: {:down, :link_lost}
      )

    assert description.name == :inputs
    assert description.driver == EtherCAT.Driver.EL1809
    assert description.station == 0x1001
    assert description.target_state == :op
    assert description.fault == {:down, :link_lost}

    assert {:ok, :ch1} = SlaveDescription.signal_for_name(description, :part_at_stop?)
    assert {:ok, :ch2} = SlaveDescription.signal_for_name(description, :clamp_closed?)

    assert %{ch1: :part_at_stop?, ch2: :clamp_closed?} =
             description
             |> SlaveDescription.effective_name_by_signal()
             |> Map.take([:ch1, :ch2])
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
        aliases: %{ch1: :lamp},
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

    assert {:ok, :ch1} = SlaveDescription.signal_for_name(description, :lamp)
  end
end
