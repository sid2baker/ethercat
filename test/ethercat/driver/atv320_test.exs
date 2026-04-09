defmodule EtherCAT.Driver.ATV320Test do
  use ExUnit.Case, async: true

  alias EtherCAT.Driver.ATV320
  alias EtherCAT.Simulator.Slave
  alias EtherCAT.Simulator.Slave.Runtime.Device
  alias EtherCAT.Slave.ProcessData.Signal

  test "signal_model/2 exposes the default six-word scanner layout without SII PDOs" do
    model = Map.new(ATV320.signal_model(%{}, []))

    assert map_size(model) == 12
    assert model.controlword == Signal.slice(0x1600, 0, 16)
    assert model.target_velocity == Signal.slice(0x1600, 16, 16)
    assert model.output_word_6 == Signal.slice(0x1600, 80, 16)
    assert model.statusword == Signal.slice(0x1A00, 0, 16)
    assert model.actual_velocity == Signal.slice(0x1A00, 16, 16)
    assert model.input_word_6 == Signal.slice(0x1A00, 80, 16)
  end

  test "signal_model/2 maps 16-bit scanner slots across split PDOs in SII order" do
    pdo_configs = [
      %{index: 0x1A00, direction: :input, sm_index: 3, bit_size: 32, bit_offset: 0},
      %{index: 0x1A01, direction: :input, sm_index: 3, bit_size: 64, bit_offset: 32},
      %{index: 0x1600, direction: :output, sm_index: 2, bit_size: 32, bit_offset: 0},
      %{index: 0x1601, direction: :output, sm_index: 2, bit_size: 16, bit_offset: 32},
      %{index: 0x1602, direction: :output, sm_index: 2, bit_size: 48, bit_offset: 48}
    ]

    model = Map.new(ATV320.signal_model(%{}, pdo_configs))

    assert model.controlword == Signal.slice(0x1600, 0, 16)
    assert model.target_velocity == Signal.slice(0x1600, 16, 16)
    assert model.output_word_3 == Signal.slice(0x1601, 0, 16)
    assert model.output_word_4 == Signal.slice(0x1602, 0, 16)
    assert model.output_word_6 == Signal.slice(0x1602, 32, 16)

    assert model.statusword == Signal.slice(0x1A00, 0, 16)
    assert model.actual_velocity == Signal.slice(0x1A00, 16, 16)
    assert model.input_word_3 == Signal.slice(0x1A01, 0, 16)
    assert model.input_word_6 == Signal.slice(0x1A01, 48, 16)
  end

  test "shutdown command waits for the expected CiA402 state and then completes" do
    {:ok, driver_state} = ATV320.init(%{})
    ref = make_ref()

    assert {:ok, [{:write, :controlword, 0x0006}], driver_state, []} =
             ATV320.command(%{ref: ref, name: :shutdown, args: %{}}, %{}, driver_state, %{})

    assert {:ok, next_state, %{pending_command: nil}, [{:command_completed, ^ref}], []} =
             ATV320.project_state(
               %{statusword: 0x0021, actual_velocity: 0},
               %{},
               driver_state,
               %{}
             )

    assert next_state.cia402_state == :ready_to_switch_on
    assert next_state.ready_to_switch_on?
    refute next_state.fault?
  end

  test "set_target_velocity completes immediately and preserves signed 16-bit encoding" do
    {:ok, driver_state} = ATV320.init(%{})
    ref = make_ref()

    assert {:ok, [{:write, :target_velocity, -1200}], %{pending_command: nil},
            [{:command_completed, ^ref}]} =
             ATV320.command(
               %{ref: ref, name: :set_target_velocity, args: %{value: -1200}},
               %{},
               driver_state,
               %{}
             )

    assert <<80, 251>> == ATV320.encode_signal(:target_velocity, %{}, -1200)
    assert -1200 == ATV320.decode_signal(:actual_velocity, %{}, <<80, 251>>)
  end

  test "project_state derives visible statusword flags and drive fault faults" do
    {:ok, next_state, %{pending_command: nil}, [], [{:drive_fault, :fault}]} =
      ATV320.project_state(
        %{statusword: 0x0008, actual_velocity: 0},
        %{},
        %{pending_command: nil},
        %{}
      )

    assert next_state.cia402_state == :fault
    assert next_state.fault?
    assert next_state.quick_stop_active?
  end

  test "simulator companion hydrates a six-word mailbox-backed scanner device" do
    definition = Slave.from_driver(ATV320, name: :drive)

    assert definition.name == :drive
    assert definition.profile == :mailbox_device
    assert definition.output_size == 12
    assert definition.input_size == 12

    assert %{
             direction: :output,
             pdo_index: 0x1600,
             bit_offset: 0,
             bit_size: 16,
             type: :u16
           } = Map.fetch!(definition.signals, :controlword)

    assert %{
             direction: :output,
             pdo_index: 0x1600,
             bit_offset: 16,
             bit_size: 16,
             type: :i16
           } = Map.fetch!(definition.signals, :target_velocity)

    assert %{
             direction: :input,
             pdo_index: 0x1A00,
             bit_offset: 16,
             bit_size: 16,
             type: :i16
           } = Map.fetch!(definition.signals, :actual_velocity)
  end

  test "simulator companion initializes statusword from a separate behavior module" do
    definition = Slave.from_driver(ATV320, name: :drive)
    device = Device.new(definition, 0)

    assert {:ok, 0x0040} = Device.get_value(device, :statusword)
    assert {:ok, 0} = Device.get_value(device, :actual_velocity)
  end
end
