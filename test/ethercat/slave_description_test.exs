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
        al_state: :op
      )

    assert description.name == :inputs
    assert description.driver == EtherCAT.Driver.EL1809
    assert description.al_state == :op

    assert {:ok, :ch1} = SlaveDescription.signal_for_name(description, :part_at_stop?)
    assert {:ok, :ch2} = SlaveDescription.signal_for_name(description, :clamp_closed?)

    assert %{ch1: :part_at_stop?, ch2: :clamp_closed?} =
             description
             |> SlaveDescription.effective_name_by_signal()
             |> Map.take([:ch1, :ch2])
  end
end
