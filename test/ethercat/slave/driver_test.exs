defmodule EtherCAT.Slave.DriverTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Slave.Driver
  alias EtherCAT.Simulator.Slave

  defmodule IdentityDriver do
    @behaviour EtherCAT.Slave.Driver

    @impl true
    def identity do
      %{vendor_id: 0x0000_00AA, product_code: 0x0000_1601}
    end

    @impl true
    def simulator_definition(_config) do
      EtherCAT.Simulator.Slave.Definition.digital_io(name: :driver_default)
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
end
