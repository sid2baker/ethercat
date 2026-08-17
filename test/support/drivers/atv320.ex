defmodule EtherCAT.Driver.ATV320 do
  @moduledoc false

  @behaviour EtherCAT.Driver

  alias EtherCAT.Endpoint
  alias EtherCAT.Slave.ProcessData.Signal

  @scanner_word_count 6
  @word_bits 16

  @output_pdo_index 0x1600
  @input_pdo_index 0x1A00

  @controlword_signal :controlword
  @target_velocity_signal :target_velocity
  @statusword_signal :statusword
  @actual_velocity_signal :actual_velocity

  @default_output_extra_names [:output_word_3, :output_word_4, :output_word_5, :output_word_6]
  @default_input_extra_names [:input_word_3, :input_word_4, :input_word_5, :input_word_6]

  @doc false
  @spec output_signal_names(map()) :: [atom()]
  def output_signal_names(config) when is_map(config) do
    [
      @controlword_signal,
      @target_velocity_signal | configured_extra_names(config, :output_word_names)
    ]
  end

  @doc false
  @spec input_signal_names(map()) :: [atom()]
  def input_signal_names(config) when is_map(config) do
    [
      @statusword_signal,
      @actual_velocity_signal | configured_extra_names(config, :input_word_names)
    ]
  end

  @impl true
  def signal_model(config, sii_pdo_configs) when is_map(config) and is_list(sii_pdo_configs) do
    output_slots = direction_slots(sii_pdo_configs, :output, @output_pdo_index)
    input_slots = direction_slots(sii_pdo_configs, :input, @input_pdo_index)

    output_signal_names(config)
    |> Enum.zip(output_slots)
    |> Kernel.++(Enum.zip(input_signal_names(config), input_slots))
  end

  @impl true
  def encode_signal(@controlword_signal, _config, value), do: encode_u16(value)
  def encode_signal(@target_velocity_signal, _config, value), do: encode_i16(value)
  def encode_signal(_signal_name, _config, value), do: encode_u16(value)

  @impl true
  def decode_signal(@statusword_signal, _config, raw), do: decode_u16(raw)
  def decode_signal(@actual_velocity_signal, _config, raw), do: decode_i16(raw)
  def decode_signal(_signal_name, _config, raw), do: decode_u16(raw)

  @impl true
  def describe(config) when is_map(config) do
    %{
      device_type: :variable_speed_drive,
      endpoints: build_endpoints(config)
    }
  end

  defp configured_extra_names(config, key) do
    defaults =
      case key do
        :output_word_names -> @default_output_extra_names
        :input_word_names -> @default_input_extra_names
      end

    case Map.get(config, key) do
      names when is_list(names) ->
        candidate =
          names
          |> Enum.filter(&is_atom/1)
          |> Enum.take(length(defaults))
          |> fill_default_names(defaults)

        if valid_extra_names?(candidate) do
          candidate
        else
          defaults
        end

      _other ->
        defaults
    end
  end

  defp fill_default_names(names, defaults) do
    names ++ Enum.drop(defaults, length(names))
  end

  defp build_endpoints(config) do
    output_endpoints = [
      %Endpoint{
        signal: @controlword_signal,
        direction: :output,
        type: :u16,
        label: "Controlword",
        description: "CiA402 controlword on communication scanner output word 1."
      },
      %Endpoint{
        signal: @target_velocity_signal,
        direction: :output,
        type: :i16,
        label: "Target Velocity",
        description: "Velocity reference on communication scanner output word 2."
      }
    ]

    input_endpoints = [
      %Endpoint{
        signal: @statusword_signal,
        direction: :input,
        type: :u16,
        label: "Statusword",
        description: "CiA402 statusword on communication scanner input word 1."
      },
      %Endpoint{
        signal: @actual_velocity_signal,
        direction: :input,
        type: :i16,
        label: "Actual Velocity",
        description: "Velocity feedback on communication scanner input word 2."
      }
    ]

    output_extras =
      config
      |> configured_extra_names(:output_word_names)
      |> Enum.with_index(3)
      |> Enum.map(fn {signal_name, slot} ->
        %Endpoint{
          signal: signal_name,
          direction: :output,
          type: :u16,
          label: "Output Word #{slot}",
          description: "Generic communication scanner output word #{slot}."
        }
      end)

    input_extras =
      config
      |> configured_extra_names(:input_word_names)
      |> Enum.with_index(3)
      |> Enum.map(fn {signal_name, slot} ->
        %Endpoint{
          signal: signal_name,
          direction: :input,
          type: :u16,
          label: "Input Word #{slot}",
          description: "Generic communication scanner input word #{slot}."
        }
      end)

    output_endpoints ++ output_extras ++ input_endpoints ++ input_extras
  end

  defp direction_slots(sii_pdo_configs, direction, default_pdo_index) do
    slots =
      sii_pdo_configs
      |> Enum.filter(&(&1.direction == direction))
      |> Enum.sort_by(fn pdo -> {pdo.bit_offset, pdo.index} end)
      |> Enum.flat_map(&pdo_word_slots/1)
      |> Enum.take(@scanner_word_count)

    if slots == [] do
      default_word_slots(default_pdo_index)
    else
      slots
    end
  end

  defp pdo_word_slots(%{index: index, bit_size: bit_size})
       when is_integer(index) and index >= 0 and is_integer(bit_size) and bit_size >= @word_bits do
    word_count = div(bit_size, @word_bits)

    for word_offset <- 0..(word_count - 1) do
      Signal.slice(index, word_offset * @word_bits, @word_bits)
    end
  end

  defp pdo_word_slots(_pdo), do: []

  defp default_word_slots(pdo_index) do
    for word_offset <- 0..(@scanner_word_count - 1) do
      Signal.slice(pdo_index, word_offset * @word_bits, @word_bits)
    end
  end

  defp encode_u16(value) when is_integer(value) and value >= 0 and value <= 0xFFFF,
    do: <<value::16-little>>

  defp encode_u16(value) when is_binary(value) and byte_size(value) == 2, do: value
  defp encode_u16(_value), do: <<>>

  defp encode_i16(value) when is_integer(value) and value >= -32_768 and value <= 32_767,
    do: <<value::16-signed-little>>

  defp encode_i16(value) when is_binary(value) and byte_size(value) == 2, do: value
  defp encode_i16(_value), do: <<>>

  defp decode_u16(<<value::16-little>>), do: value
  defp decode_u16(_raw), do: 0

  defp decode_i16(<<value::16-signed-little>>), do: value
  defp decode_i16(_raw), do: 0

  defp valid_extra_names?(names) when is_list(names) do
    reserved = [
      @controlword_signal,
      @target_velocity_signal,
      @statusword_signal,
      @actual_velocity_signal
    ]

    length(names) == length(Enum.uniq(names)) and Enum.all?(names, &(&1 not in reserved))
  end
end

defmodule EtherCAT.Driver.ATV320.Simulator do
  @moduledoc false

  @behaviour EtherCAT.Simulator.Adapter

  alias EtherCAT.Driver.ATV320
  alias EtherCAT.Simulator.Slave.Definition
  alias EtherCAT.Slave.Mailbox

  @output_pdo_index 0x1600
  @input_pdo_index 0x1A00
  @output_phys 0x1100
  @input_phys 0x1180
  @scanner_word_count 6
  @word_bits 16

  @impl true
  def definition_options(config) when is_map(config) do
    identity = Map.get(config, :simulator_identity, %{})

    [
      profile: :mailbox_device,
      behavior: EtherCAT.Driver.ATV320.SimulatorBehavior,
      vendor_id: Map.get(identity, :vendor_id, 0),
      product_code: Map.get(identity, :product_code, 0),
      revision: Map.get(identity, :revision, 0),
      serial_number: Map.get(identity, :serial_number, 0),
      output_phys: @output_phys,
      output_size: div(@scanner_word_count * @word_bits, 8),
      input_phys: @input_phys,
      input_size: div(@scanner_word_count * @word_bits, 8),
      mirror_output_to_input?: false,
      mailbox_config: Mailbox.config(0x1000, 64, 0x1040, 64),
      pdo_entries: [
        Definition.pdo_entry(@output_pdo_index, :output, 2, 96),
        Definition.pdo_entry(@input_pdo_index, :input, 3, 96)
      ],
      objects: %{},
      dc_capable?: false,
      signals: build_signal_definitions(config)
    ]
  end

  defp build_signal_definitions(config) do
    output_definitions =
      config
      |> ATV320.output_signal_names()
      |> Enum.with_index()
      |> Enum.map(fn {signal_name, slot_index} ->
        {signal_name,
         Definition.signal(
           direction: :output,
           pdo_index: @output_pdo_index,
           bit_offset: slot_index * @word_bits,
           bit_size: @word_bits,
           type: signal_type(signal_name),
           label: simulator_label(signal_name),
           group: simulator_group(signal_name)
         )}
      end)

    input_definitions =
      config
      |> ATV320.input_signal_names()
      |> Enum.with_index()
      |> Enum.map(fn {signal_name, slot_index} ->
        {signal_name,
         Definition.signal(
           direction: :input,
           pdo_index: @input_pdo_index,
           bit_offset: slot_index * @word_bits,
           bit_size: @word_bits,
           type: signal_type(signal_name),
           label: simulator_label(signal_name),
           group: simulator_group(signal_name)
         )}
      end)

    Map.new(output_definitions ++ input_definitions)
  end

  defp signal_type(:target_velocity), do: :i16
  defp signal_type(:actual_velocity), do: :i16
  defp signal_type(_signal_name), do: :u16

  defp simulator_label(signal_name) do
    signal_name
    |> Atom.to_string()
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp simulator_group(signal_name)
       when signal_name in [:controlword, :target_velocity],
       do: :command

  defp simulator_group(signal_name) when signal_name in [:statusword, :actual_velocity],
    do: :status

  defp simulator_group(_signal_name), do: :scanner
end

defmodule EtherCAT.Driver.ATV320.SimulatorBehavior do
  @moduledoc false

  use EtherCAT.Simulator.Slave.Behaviour

  @switch_on_disabled 0x0040
  @ready_to_switch_on 0x0021
  @switched_on 0x0023
  @operation_enabled 0x0027
  @quick_stop_active 0x0007
  @fault 0x0008

  def init(definition) do
    extra_inputs =
      definition.signals
      |> Enum.filter(fn
        {:statusword, _definition} -> false
        {:actual_velocity, _definition} -> false
        {_signal_name, %{direction: :input}} -> true
        _other -> false
      end)
      |> Enum.map(fn {signal_name, _definition} -> {signal_name, 0} end)
      |> Map.new()

    %{
      cia402_state: :switch_on_disabled,
      controlword: 0,
      target_velocity: 0,
      actual_velocity: 0,
      extra_inputs: extra_inputs
    }
  end

  def handle_output_change(:controlword, value, _device, state) when is_integer(value) do
    {:ok, apply_controlword(%{state | controlword: value}, value)}
  end

  def handle_output_change(:target_velocity, value, _device, state) when is_integer(value) do
    {:ok, maybe_update_velocity(%{state | target_velocity: value})}
  end

  def handle_output_change(_signal_name, _value, _device, state), do: {:ok, state}

  def refresh_inputs(_device, state) do
    inputs =
      state.extra_inputs
      |> Map.put(:statusword, statusword(state))
      |> Map.put(:actual_velocity, state.actual_velocity)

    {:ok, inputs, state}
  end

  defp apply_controlword(state, 0x0080) do
    %{state | cia402_state: :switch_on_disabled}
    |> maybe_update_velocity()
  end

  defp apply_controlword(state, 0x0006) do
    %{state | cia402_state: :ready_to_switch_on}
    |> maybe_update_velocity()
  end

  defp apply_controlword(state, 0x0007) do
    %{state | cia402_state: :switched_on}
    |> maybe_update_velocity()
  end

  defp apply_controlword(state, 0x000F) do
    %{state | cia402_state: :operation_enabled}
    |> maybe_update_velocity()
  end

  defp apply_controlword(state, 0x0000) do
    %{state | cia402_state: :switch_on_disabled}
    |> maybe_update_velocity()
  end

  defp apply_controlword(state, 0x0002) do
    %{state | cia402_state: :quick_stop_active}
    |> maybe_update_velocity()
  end

  defp apply_controlword(state, _controlword), do: state

  defp maybe_update_velocity(%{cia402_state: :operation_enabled} = state) do
    %{state | actual_velocity: state.target_velocity}
  end

  defp maybe_update_velocity(state) do
    %{state | actual_velocity: 0}
  end

  defp statusword(%{cia402_state: :switch_on_disabled}), do: @switch_on_disabled
  defp statusword(%{cia402_state: :ready_to_switch_on}), do: @ready_to_switch_on
  defp statusword(%{cia402_state: :switched_on}), do: @switched_on
  defp statusword(%{cia402_state: :operation_enabled}), do: @operation_enabled
  defp statusword(%{cia402_state: :quick_stop_active}), do: @quick_stop_active
  defp statusword(%{cia402_state: :fault}), do: @fault
  defp statusword(_state), do: 0
end
