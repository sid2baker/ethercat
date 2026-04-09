defmodule EtherCAT.Simulator.Slave.Runtime.Device do
  @moduledoc false

  alias EtherCAT.Slave.ESC.Registers
  alias EtherCAT.Simulator.Slave.Behaviour
  alias EtherCAT.Simulator.Slave.Runtime.AL
  alias EtherCAT.Simulator.Slave.Runtime.CoE
  alias EtherCAT.Simulator.Slave.Runtime.DC
  alias EtherCAT.Simulator.Slave.Definition
  alias EtherCAT.Simulator.Slave.Runtime.ESCImage
  alias EtherCAT.Simulator.Slave.Runtime.Logical
  alias EtherCAT.Simulator.Slave.Runtime.Mailbox
  alias EtherCAT.Simulator.Slave.Object
  alias EtherCAT.Simulator.Slave.Runtime.Dictionary
  alias EtherCAT.Simulator.Slave.Runtime.Memory
  alias EtherCAT.Simulator.Slave.Runtime.ProcessImage
  alias EtherCAT.Simulator.Slave.Signals

  @station_address elem(Registers.station_address(), 0)
  @al_control elem(Registers.al_control(), 0)
  @eeprom_control elem(Registers.eeprom_control(), 0)
  @sm1_status elem(Registers.sm_status(1), 0)
  @sm1_status_length elem(Registers.sm_status(1), 1)

  @type t :: %__MODULE__{
          name: atom(),
          profile: atom(),
          position: non_neg_integer(),
          station: non_neg_integer(),
          state: :init | :preop | :safeop | :op | :bootstrap,
          al_error?: boolean(),
          al_status_code: non_neg_integer(),
          eeprom: binary(),
          memory: binary(),
          output_phys: non_neg_integer(),
          output_size: non_neg_integer(),
          input_phys: non_neg_integer(),
          input_size: non_neg_integer(),
          mirror_output_to_input?: boolean(),
          signals: %{optional(atom()) => Signals.definition()},
          input_overrides: %{optional(atom()) => term()},
          mailbox_config: Mailbox.mailbox_config(),
          objects: %{optional({non_neg_integer(), non_neg_integer()}) => Object.t()},
          mailbox_abort_rules: [map()],
          mailbox_protocol_fault_rules: [map()],
          mailbox_upload: map() | nil,
          mailbox_download: map() | nil,
          behavior: module(),
          behavior_state: term(),
          dc_capable?: boolean(),
          dc_state: DC.t() | nil
        }

  @enforce_keys [
    :name,
    :profile,
    :position,
    :station,
    :state,
    :al_error?,
    :al_status_code,
    :eeprom,
    :memory,
    :output_phys,
    :output_size,
    :input_phys,
    :input_size,
    :mirror_output_to_input?,
    :signals,
    :input_overrides,
    :mailbox_config,
    :objects,
    :mailbox_abort_rules,
    :mailbox_protocol_fault_rules,
    :behavior,
    :behavior_state,
    :dc_capable?,
    :dc_state
  ]
  defstruct [
    :name,
    :profile,
    :position,
    :station,
    :state,
    :al_error?,
    :al_status_code,
    :eeprom,
    :memory,
    :output_phys,
    :output_size,
    :input_phys,
    :input_size,
    :mirror_output_to_input?,
    :signals,
    :input_overrides,
    :mailbox_config,
    :objects,
    :mailbox_abort_rules,
    :mailbox_protocol_fault_rules,
    :behavior,
    :behavior_state,
    :dc_capable?,
    :dc_state,
    mailbox_upload: nil,
    mailbox_download: nil
  ]

  @spec new(Definition.t(), non_neg_integer()) :: t()
  def new(definition, position) do
    %{eeprom: eeprom, memory: memory} = ESCImage.hydrate(definition)

    behavior_state = Behaviour.init(definition.behavior, definition)

    %__MODULE__{
      name: definition.name,
      profile: definition.profile,
      position: position,
      station: 0,
      state: :init,
      al_error?: false,
      al_status_code: 0,
      eeprom: eeprom,
      memory: memory,
      output_phys: definition.output_phys,
      output_size: definition.output_size,
      input_phys: definition.input_phys,
      input_size: definition.input_size,
      mirror_output_to_input?: definition.mirror_output_to_input?,
      signals: definition.signals,
      input_overrides: %{},
      mailbox_config: definition.mailbox_config,
      objects: definition.objects,
      mailbox_abort_rules: [],
      mailbox_protocol_fault_rules: [],
      behavior: definition.behavior,
      behavior_state: behavior_state,
      dc_capable?: definition.dc_capable?,
      dc_state: if(definition.dc_capable?, do: DC.new(position), else: nil)
    }
    |> DC.refresh_memory()
    |> ProcessImage.refresh_inputs()
  end

  @spec prepare(t()) :: t()
  def prepare(%__MODULE__{} = slave) do
    with {:ok, behavior_state} <- Behaviour.tick(slave.behavior, slave, slave.behavior_state) do
      slave
      |> Map.put(:behavior_state, behavior_state)
      |> ProcessImage.refresh_inputs()
    else
      _ -> slave
    end
  end

  @spec info(t()) :: map()
  def info(%__MODULE__{} = slave) do
    %{
      name: slave.name,
      profile: slave.profile,
      state: slave.state,
      station: slave.station,
      al_error?: slave.al_error?,
      al_status_code: slave.al_status_code,
      dc_capable?: slave.dc_capable?,
      signals: slave.signals,
      values: ProcessImage.signal_values(slave)
    }
  end

  @spec signal_values(t()) :: %{optional(atom()) => term()}
  def signal_values(%__MODULE__{} = slave), do: ProcessImage.signal_values(slave)

  @spec retreat_to_safeop(t()) :: t()
  def retreat_to_safeop(%__MODULE__{} = slave), do: AL.retreat_to_safeop(slave)

  @spec power_cycle(t()) :: t()
  def power_cycle(%__MODULE__{} = slave) do
    slave
    |> clear_fixed_station_address()
    |> Map.put(:mailbox_upload, nil)
    |> Map.put(:mailbox_download, nil)
    |> Map.put(:mailbox_abort_rules, [])
    |> Map.put(:mailbox_protocol_fault_rules, [])
    |> reset_dc_runtime()
    |> AL.reset_to_init()
    |> clear_fmmu_configuration()
    |> clear_sm_configuration()
    |> ProcessImage.refresh_inputs()
  end

  @spec latch_al_error(t(), non_neg_integer()) :: t()
  def latch_al_error(%__MODULE__{} = slave, status_code)
      when is_integer(status_code) and status_code >= 0 do
    AL.latch_error(slave, status_code)
  end

  @spec inject_mailbox_abort(t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: t()
  def inject_mailbox_abort(%__MODULE__{} = slave, index, subindex, abort_code)
      when is_integer(index) and index >= 0 and is_integer(subindex) and subindex >= 0 and
             is_integer(abort_code) and abort_code >= 0 do
    Dictionary.inject_abort(slave, index, subindex, abort_code, :request)
  end

  @spec inject_mailbox_abort(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          :request | :upload_segment | :download_segment
        ) :: t()
  def inject_mailbox_abort(%__MODULE__{} = slave, index, subindex, abort_code, stage)
      when is_integer(index) and index >= 0 and is_integer(subindex) and subindex >= 0 and
             is_integer(abort_code) and abort_code >= 0 and
             stage in [:request, :upload_segment, :download_segment] do
    Dictionary.inject_abort(slave, index, subindex, abort_code, stage)
  end

  @spec inject_mailbox_protocol_fault(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          Mailbox.protocol_fault_stage(),
          Mailbox.protocol_fault_kind()
        ) :: t()
  def inject_mailbox_protocol_fault(%__MODULE__{} = slave, index, subindex, stage, fault_kind)
      when is_integer(index) and index >= 0 and is_integer(subindex) and subindex >= 0 do
    Mailbox.inject_protocol_fault(slave, index, subindex, stage, fault_kind)
  end

  @spec inject_mailbox_protocol_fault_once(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          Mailbox.protocol_fault_stage(),
          Mailbox.protocol_fault_kind()
        ) :: t()
  def inject_mailbox_protocol_fault_once(
        %__MODULE__{} = slave,
        index,
        subindex,
        stage,
        fault_kind
      )
      when is_integer(index) and index >= 0 and is_integer(subindex) and subindex >= 0 do
    Mailbox.inject_protocol_fault(slave, index, subindex, stage, fault_kind, once?: true)
  end

  @spec clear_faults(t()) :: t()
  def clear_faults(%__MODULE__{} = slave) do
    slave
    |> Dictionary.clear_aborts()
    |> Mailbox.clear_protocol_faults()
    |> Map.put(:mailbox_upload, nil)
    |> Map.put(:mailbox_download, nil)
    |> AL.clear_error()
    |> ProcessImage.refresh_inputs()
  end

  @spec output_image(t()) :: binary()
  def output_image(%__MODULE__{} = slave), do: ProcessImage.output_image(slave)

  @spec signals(t()) :: %{optional(atom()) => Signals.definition()}
  def signals(%__MODULE__{signals: signals}), do: signals

  @spec get_value(t(), atom()) :: {:ok, term()} | {:error, :unknown_signal}
  def get_value(%__MODULE__{} = slave, signal_name),
    do: ProcessImage.get_value(slave, signal_name)

  @spec set_value(t(), atom(), term()) :: {:ok, t()} | {:error, :unknown_signal | :invalid_value}
  def set_value(%__MODULE__{} = slave, signal_name, value),
    do: ProcessImage.set_value(slave, signal_name, value)

  @spec signal_definition(t(), atom()) :: {:ok, map()} | :error
  def signal_definition(%__MODULE__{signals: signals}, signal_name),
    do: Map.fetch(signals, signal_name)

  @spec read_register(t(), non_neg_integer(), non_neg_integer()) :: binary()
  def read_register(%__MODULE__{dc_capable?: true} = slave, offset, length) do
    if DC.handles_range?(offset, length) do
      DC.read_register(slave, offset, length)
    else
      binary_part(slave.memory, offset, length)
    end
  end

  def read_register(%__MODULE__{memory: memory}, offset, length) do
    binary_part(memory, offset, length)
  end

  @spec read_datagram(t(), non_neg_integer(), non_neg_integer()) :: {t(), binary()}
  def read_datagram(%__MODULE__{} = slave, offset, length) do
    data = read_register(slave, offset, length)

    if CoE.send_read?(slave, offset, length) do
      {CoE.clear_send_response(slave, @sm1_status, @sm1_status_length), data}
    else
      {slave, data}
    end
  end

  @spec write_register(t(), non_neg_integer(), binary()) :: t()
  def write_register(%__MODULE__{} = slave, @station_address, <<station::16-little>>) do
    slave
    |> Map.put(:station, station)
    |> write_memory(@station_address, <<station::16-little>>)
  end

  def write_register(%__MODULE__{} = slave, @al_control, <<control::16-little>>) do
    <<low::8, _high::8>> = <<control::16-little>>
    request = rem(low, 16)

    slave
    |> write_memory(@al_control, <<control::16-little>>)
    |> then(fn updated_slave ->
      case AL.apply_control(updated_slave, request) do
        {:ok, transitioned_slave} -> ProcessImage.refresh_inputs(transitioned_slave)
        {:error, transitioned_slave} -> transitioned_slave
      end
    end)
  end

  def write_register(%__MODULE__{} = slave, @eeprom_control, <<low::8, high::8>> = control) do
    slave =
      slave
      |> write_memory(@eeprom_control, control)
      |> load_eeprom_data(high)

    write_memory(slave, @eeprom_control, <<max(low, 1)::8, high::8>>)
  end

  def write_register(%__MODULE__{dc_capable?: true} = slave, offset, data) do
    if DC.handles_range?(offset, byte_size(data)) do
      DC.write_register(slave, offset, data)
    else
      ProcessImage.write_register(slave, offset, data)
    end
  end

  def write_register(%__MODULE__{} = slave, offset, data) do
    ProcessImage.write_register(slave, offset, data)
  end

  @spec write_datagram(t(), non_neg_integer(), binary()) :: t()
  def write_datagram(%__MODULE__{} = slave, offset, data) do
    slave = write_register(slave, offset, data)

    CoE.handle_write(slave, offset, data, @sm1_status)
  end

  @spec logical_read_write(t(), 10 | 11 | 12, non_neg_integer(), binary()) ::
          {t(), binary(), non_neg_integer()}
  def logical_read_write(%__MODULE__{} = slave, cmd, logical_start, request_data) do
    Logical.read_write(slave, cmd, logical_start, request_data)
  end

  # Maximum number of FMMU entries in a typical ESC (16 bytes each, starting at 0x0600)
  @max_fmmu_entries 8
  # Maximum number of SyncManager entries (8 bytes each, starting at 0x0800)
  @max_sm_entries 8

  defp clear_fmmu_configuration(%__MODULE__{} = slave) do
    Enum.reduce(0..(@max_fmmu_entries - 1), slave, fn index, acc ->
      {activate_offset, _} = Registers.fmmu_activate(index)

      if activate_offset + 1 <= byte_size(acc.memory) do
        write_memory(acc, activate_offset, <<0x00>>)
      else
        acc
      end
    end)
  end

  defp clear_sm_configuration(%__MODULE__{} = slave) do
    Enum.reduce(0..(@max_sm_entries - 1), slave, fn index, acc ->
      {activate_offset, _} = Registers.sm_activate(index)

      if activate_offset + 1 <= byte_size(acc.memory) do
        write_memory(acc, activate_offset, <<0x00>>)
      else
        acc
      end
    end)
  end

  defp clear_fixed_station_address(%__MODULE__{} = slave) do
    slave
    |> Map.put(:station, 0)
    |> write_memory(@station_address, <<0::16-little>>)
  end

  defp reset_dc_runtime(%__MODULE__{dc_capable?: true, position: position} = slave) do
    slave
    |> Map.put(:dc_state, DC.new(position))
    |> DC.refresh_memory()
  end

  defp reset_dc_runtime(%__MODULE__{} = slave), do: slave

  defp load_eeprom_data(%__MODULE__{memory: memory, eeprom: eeprom} = slave, cmd) do
    %{slave | memory: ESCImage.maybe_load_eeprom_data(memory, eeprom, cmd)}
  end

  defp write_memory(%__MODULE__{memory: memory} = slave, offset, data) do
    %{slave | memory: Memory.replace(memory, offset, data)}
  end
end
