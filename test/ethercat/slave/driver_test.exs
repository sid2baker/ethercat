defmodule EtherCAT.DriverTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Driver
  alias EtherCAT.Driver.{EL1809, EL2809}
  alias EtherCAT.Driver.Runtime, as: DriverRuntime
  alias EtherCAT.Simulator.Driver, as: SimulatorDriver
  alias EtherCAT.Simulator.Slave

  defmodule IdentityDriver do
    @behaviour EtherCAT.Driver
    @behaviour EtherCAT.Simulator.Driver

    @impl true
    def identity do
      %{vendor_id: 0x0000_00AA, product_code: 0x0000_1601}
    end

    @impl true
    def signal_model(_config, _sii_pdo_configs), do: [out: 0x1600, in: 0x1A00]

    @impl true
    def encode_signal(_signal, _config, value), do: <<value::8>>

    @impl true
    def decode_signal(_signal, _config, <<value::8>>), do: value

    @impl true
    def project_state(decoded_inputs, _prev_state, driver_state, _config) do
      {:ok, decoded_inputs, driver_state, [], []}
    end

    @impl true
    def command(command, _state, _driver_state, _config), do: Driver.unsupported_command(command)
  end

  defmodule NoSimulationDriver do
    @behaviour EtherCAT.Driver

    @impl true
    def signal_model(_config, _sii_pdo_configs), do: [out: 0x1600]

    @impl true
    def encode_signal(_signal, _config, value), do: <<value::8>>

    @impl true
    def decode_signal(_signal, _config, <<value::8>>), do: value

    @impl true
    def project_state(decoded_inputs, _prev_state, driver_state, _config) do
      {:ok, decoded_inputs, driver_state, [], []}
    end

    @impl true
    def command(command, _state, _driver_state, _config), do: Driver.unsupported_command(command)
  end

  defmodule RevisionIdentityDriver do
    @behaviour EtherCAT.Driver
    @behaviour EtherCAT.Simulator.Driver

    @impl true
    def identity do
      %{vendor_id: 0x0000_00BB, product_code: 0x0000_2601, revision: 0x0000_0007}
    end

    @impl true
    def signal_model(_config, _sii_pdo_configs), do: [out: 0x1600]

    @impl true
    def encode_signal(_signal, _config, value), do: <<value::8>>

    @impl true
    def decode_signal(_signal, _config, <<value::8>>), do: value

    @impl true
    def project_state(decoded_inputs, _prev_state, driver_state, _config) do
      {:ok, decoded_inputs, driver_state, [], []}
    end

    @impl true
    def command(command, _state, _driver_state, _config), do: Driver.unsupported_command(command)
  end

  defmodule IdentityDriver.Simulator do
    @behaviour EtherCAT.Simulator.DriverAdapter

    @impl true
    def definition_options(_config) do
      [profile: :digital_io, name: :driver_default]
    end
  end

  defmodule RevisionIdentityDriver.Simulator do
    @behaviour EtherCAT.Simulator.DriverAdapter

    @impl true
    def definition_options(_config) do
      [profile: :digital_io, name: :revision_default]
    end
  end

  test "identity/1 returns normalized driver identity" do
    assert %{vendor_id: 0x0000_00AA, product_code: 0x0000_1601, revision: :any} =
             SimulatorDriver.identity(IdentityDriver)
  end

  test "identity/1 returns nil when the driver does not declare identity" do
    assert nil == SimulatorDriver.identity(NoSimulationDriver)
  end

  test "signal_model/2 returns the driver's logical signals" do
    assert [out: 0x1600, in: 0x1A00] == DriverRuntime.signal_model(IdentityDriver, %{})
  end

  test "from_driver/2 defaults simulator identity from the driver" do
    definition = Slave.from_driver(IdentityDriver)
    assert definition.vendor_id == 0x0000_00AA
    assert definition.product_code == 0x0000_1601
    assert definition.revision == 0x0000_0001
  end

  test "from_driver/2 carries integer revision from driver identity" do
    definition = Slave.from_driver(RevisionIdentityDriver)
    assert definition.vendor_id == 0x0000_00BB
    assert definition.product_code == 0x0000_2601
    assert definition.revision == 0x0000_0007
  end

  test "simulator slave can hydrate a device from a driver companion module" do
    definition = Slave.from_driver(IdentityDriver, name: :hydrated, config: %{})

    assert definition.name == :hydrated
    assert definition.profile == :digital_io
    assert definition.vendor_id == 0x0000_00AA
    assert definition.product_code == 0x0000_1601
    assert Map.has_key?(definition.signals, :out)
    assert Map.has_key?(definition.signals, :in)
  end

  test "from_driver/2 raises when the driver does not expose simulator support" do
    assert_raise ArgumentError, ~r/does not expose a simulator companion/, fn ->
      Slave.from_driver(NoSimulationDriver)
    end
  end

  test "EL1809 example driver hydrates a 16-channel input simulator device" do
    definition = Slave.from_driver(EL1809, name: :inputs)

    assert definition.name == :inputs
    assert definition.profile == :digital_io
    assert definition.vendor_id == 0x0000_0002
    assert definition.product_code == 0x0711_3052

    assert SimulatorDriver.identity(EL1809) == %{
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

    assert SimulatorDriver.identity(EL2809) == %{
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
