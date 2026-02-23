defmodule EthercatTest do
  use ExUnit.Case

  defmodule TestDriver do
    use Ethercat.Driver

    identity(0x00000002, 0x00000000, 0x00000000)
    input(:channel_1, :bool, default: false)
    output(:channel_2, :uint16, default: 0)
  end

  test "start/stop and read default values" do
    config = %{
      interface: "dummy0",
      devices: [
        %{name: :dev, position: 0, driver: TestDriver}
      ]
    }

    assert {:ok, bus} = Ethercat.start(config)
    assert {:ok, %{state: :operational}} = Ethercat.status(bus)
    assert {:ok, false} = Ethercat.read(bus, :dev, :channel_1)
    assert {:ok, 0} = Ethercat.read(bus, :dev, :channel_2)
    assert :ok = Ethercat.stop(bus)
  end
end
