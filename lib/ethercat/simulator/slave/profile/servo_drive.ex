defmodule EtherCAT.Simulator.Slave.Profile.ServoDrive do
  @moduledoc false

  alias EtherCAT.Simulator.Slave.Object

  @switch_on_disabled 0x0040
  @ready_to_switch_on 0x0021
  @switched_on 0x0023
  @operation_enabled 0x0027
  @fault 0x0008

  def spec(_opts) do
    %{
      profile: :servo_drive,
      vendor_id: 0x0000_0ACE,
      product_code: 0x0000_2402,
      revision: 0x0000_0001,
      serial_number: 0x0000_2001,
      esc_type: 0x11,
      fmmu_count: 8,
      sm_count: 4,
      output_phys: 0x1100,
      output_size: 7,
      input_phys: 0x1180,
      input_size: 7,
      mirror_output_to_input?: false,
      mailbox_config: %{recv_offset: 0x1000, recv_size: 64, send_offset: 0x1040, send_size: 64},
      pdo_entries: [
        %{index: 0x1600, direction: :output, sm_index: 2, bit_size: 56},
        %{index: 0x1A00, direction: :input, sm_index: 3, bit_size: 56}
      ],
      objects: %{
        {0x6040, 0x00} =>
          Object.new(
            index: 0x6040,
            subindex: 0x00,
            name: :controlword,
            type: :u16,
            value: 0,
            access: :rw,
            group: :command
          ),
        {0x6041, 0x00} =>
          Object.new(
            index: 0x6041,
            subindex: 0x00,
            name: :statusword,
            type: :u16,
            value: @switch_on_disabled,
            access: :ro,
            group: :status
          ),
        {0x6060, 0x00} =>
          Object.new(
            index: 0x6060,
            subindex: 0x00,
            name: :mode_of_operation,
            type: :i8,
            value: 1,
            access: :rw,
            group: :command
          ),
        {0x6061, 0x00} =>
          Object.new(
            index: 0x6061,
            subindex: 0x00,
            name: :mode_display,
            type: :i8,
            value: 1,
            access: :ro,
            group: :status
          ),
        {0x607A, 0x00} =>
          Object.new(
            index: 0x607A,
            subindex: 0x00,
            name: :target_position,
            type: :i32,
            value: 0,
            access: :rw,
            group: :command
          ),
        {0x6064, 0x00} =>
          Object.new(
            index: 0x6064,
            subindex: 0x00,
            name: :position_actual,
            type: :i32,
            value: 0,
            access: :ro,
            group: :status
          )
      },
      dc_capable?: true,
      signals: signal_specs(),
      behavior: __MODULE__
    }
  end

  def signal_specs do
    %{
      controlword: %{
        direction: :output,
        pdo_index: 0x1600,
        bit_offset: 0,
        bit_size: 16,
        type: :u16,
        label: "Controlword",
        group: :command
      },
      target_position: %{
        direction: :output,
        pdo_index: 0x1600,
        bit_offset: 16,
        bit_size: 32,
        type: :i32,
        label: "Target Position",
        group: :command
      },
      mode_of_operation: %{
        direction: :output,
        pdo_index: 0x1600,
        bit_offset: 48,
        bit_size: 8,
        type: :i8,
        label: "Mode Of Operation",
        group: :command
      },
      statusword: %{
        direction: :input,
        pdo_index: 0x1A00,
        bit_offset: 0,
        bit_size: 16,
        type: :u16,
        label: "Statusword",
        group: :status
      },
      position_actual: %{
        direction: :input,
        pdo_index: 0x1A00,
        bit_offset: 16,
        bit_size: 32,
        type: :i32,
        label: "Position Actual",
        group: :status
      },
      mode_display: %{
        direction: :input,
        pdo_index: 0x1A00,
        bit_offset: 48,
        bit_size: 8,
        type: :i8,
        label: "Mode Display",
        group: :status
      }
    }
  end

  def init(_fixture) do
    %{
      cia402_state: :switch_on_disabled,
      controlword: 0,
      mode_of_operation: 1,
      target_position: 0,
      position_actual: 0,
      fault?: false
    }
  end

  def handle_output_change(:controlword, controlword, _device, state) do
    {:ok, apply_controlword(state, controlword)}
  end

  def handle_output_change(:target_position, target_position, _device, state) do
    next_state = %{state | target_position: target_position}
    {:ok, maybe_update_position(next_state)}
  end

  def handle_output_change(:mode_of_operation, mode, _device, state) do
    {:ok, %{state | mode_of_operation: mode}}
  end

  def handle_output_change(_signal, _value, _device, state), do: {:ok, state}

  def refresh_inputs(_device, state) do
    {:ok,
     %{
       statusword: statusword(state),
       position_actual: state.position_actual,
       mode_display: state.mode_of_operation
     }, state}
  end

  def read_object(0x6041, 0x00, entry, _device, state) do
    {:ok, %{entry | value: statusword(state)}, state}
  end

  def read_object(0x6061, 0x00, entry, _device, state) do
    {:ok, %{entry | value: state.mode_of_operation}, state}
  end

  def read_object(0x6064, 0x00, entry, _device, state) do
    {:ok, %{entry | value: state.position_actual}, state}
  end

  def read_object(_index, _subindex, entry, _device, state), do: {:ok, entry, state}

  def write_object(0x6040, 0x00, entry, binary, _device, state) do
    <<controlword::16-little>> = binary
    next_state = apply_controlword(%{state | controlword: controlword}, controlword)
    {:ok, %{entry | value: controlword}, next_state}
  end

  def write_object(0x6060, 0x00, entry, <<mode::8-signed>>, _device, state) do
    {:ok, %{entry | value: mode}, %{state | mode_of_operation: mode}}
  end

  def write_object(0x607A, 0x00, entry, <<target_position::32-signed-little>>, _device, state) do
    next_state =
      state
      |> Map.put(:target_position, target_position)
      |> maybe_update_position()

    {:ok, %{entry | value: target_position}, next_state}
  end

  def write_object(_index, _subindex, entry, _binary, _device, state), do: {:ok, entry, state}

  defp apply_controlword(state, 0x0080) do
    %{state | fault?: false, cia402_state: :switch_on_disabled}
  end

  defp apply_controlword(state, controlword) do
    case {state.cia402_state, controlword} do
      {:switch_on_disabled, 0x0006} ->
        %{state | controlword: controlword, cia402_state: :ready_to_switch_on}

      {:ready_to_switch_on, 0x0007} ->
        %{state | controlword: controlword, cia402_state: :switched_on}

      {:switched_on, 0x000F} ->
        %{state | controlword: controlword, cia402_state: :operation_enabled}
        |> maybe_update_position()

      {:operation_enabled, 0x0007} ->
        %{state | controlword: controlword, cia402_state: :switched_on}

      _ ->
        %{state | controlword: controlword}
    end
  end

  defp maybe_update_position(%{cia402_state: :operation_enabled} = state) do
    %{state | position_actual: state.target_position}
  end

  defp maybe_update_position(state), do: state

  defp statusword(%{fault?: true}), do: @fault
  defp statusword(%{cia402_state: :switch_on_disabled}), do: @switch_on_disabled
  defp statusword(%{cia402_state: :ready_to_switch_on}), do: @ready_to_switch_on
  defp statusword(%{cia402_state: :switched_on}), do: @switched_on
  defp statusword(%{cia402_state: :operation_enabled}), do: @operation_enabled
end
