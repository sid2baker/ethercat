defmodule EtherCAT.Slave.DriverTest do
  use ExUnit.Case, async: true

  alias EtherCAT.IntegrationSupport.Drivers.{EL1809, EL2809}
  alias EtherCAT.Slave.Driver
  alias EtherCAT.Simulator.Slave
  alias EtherCAT.Simulator.Slave.Definition

  defmodule IdentityDriver do
    @behaviour EtherCAT.Slave.Driver

    @impl true
    def identity do
      %{vendor_id: 0x0000_00AA, product_code: 0x0000_1601}
    end

    @impl true
    def simulator_definition(_config) do
      Definition.build(:digital_io, name: :driver_default)
    end

    @impl true
    def process_data_model(_config), do: [out: 0x1600, in: 0x1A00]

    @impl true
    def encode_signal(_signal, _config, value), do: <<value::8>>

    @impl true
    def decode_signal(_signal, _config, <<value::8>>), do: value
  end

  defmodule NoSimulationDriver do
    @behaviour EtherCAT.Slave.Driver

    @impl true
    def identity, do: nil

    @impl true
    def simulator_definition(_config), do: nil

    @impl true
    def process_data_model(_config), do: [out: 0x1600]

    @impl true
    def encode_signal(_signal, _config, value), do: <<value::8>>

    @impl true
    def decode_signal(_signal, _config, <<value::8>>), do: value
  end

  test "identity/1 returns normalized driver identity" do
    assert %{vendor_id: 0x0000_00AA, product_code: 0x0000_1601, revision: :any} =
             Driver.identity(IdentityDriver)
  end

  test "identity/1 returns nil when the driver does not declare identity" do
    assert nil == Driver.identity(NoSimulationDriver)
  end

  test "simulator_definition/2 returns nil when the driver does not expose one" do
    assert nil == Driver.simulator_definition(NoSimulationDriver, %{})
  end

  test "simulator slave can hydrate a device from a driver callback" do
    definition = Slave.from_driver(IdentityDriver, name: :hydrated, config: %{})

    assert definition.name == :hydrated
    assert definition.profile == :digital_io
    assert definition.vendor_id == 0x0000_0ACE
    assert definition.product_code == 0x0000_1601
    assert Map.has_key?(definition.signals, :out)
    assert Map.has_key?(definition.signals, :in)
  end

  test "from_driver/2 raises when the driver does not expose simulator hydration" do
    assert_raise ArgumentError, ~r/does not implement simulator_definition\/1/, fn ->
      Slave.from_driver(NoSimulationDriver)
    end
  end

  test "EL1809 example driver hydrates a 16-channel input simulator device" do
    definition = Slave.from_driver(EL1809, name: :inputs)

    assert definition.name == :inputs
    assert definition.profile == :digital_io
    assert definition.vendor_id == 0x0000_0002
    assert definition.product_code == 0x0711_3052

    assert Driver.identity(EL1809) == %{
             vendor_id: 0x0000_0002,
             product_code: 0x0711_3052,
             revision: :any
           }

    assert Enum.count(Map.keys(definition.signals)) == 16

    assert match?(
             %{direction: :input, type: :bool, bit_size: 1},
             Map.fetch!(definition.signals, :ch1)
           )
  end

  test "EL2809 example driver hydrates a 16-channel output simulator device" do
    definition = Slave.from_driver(EL2809, name: :outputs)

    assert definition.name == :outputs
    assert definition.profile == :digital_io
    assert definition.vendor_id == 0x0000_0002
    assert definition.product_code == 0x0AF9_3052

    assert Driver.identity(EL2809) == %{
             vendor_id: 0x0000_0002,
             product_code: 0x0AF9_3052,
             revision: :any
           }

    assert Enum.count(Map.keys(definition.signals)) == 16

    assert match?(
             %{direction: :output, type: :bool, bit_size: 1},
             Map.fetch!(definition.signals, :ch16)
           )
  end
end
