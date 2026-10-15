defmodule EtherCAT.Bus.Transport.BpfLifecycleTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Bus.Transport.Bpf

  test "a helper that exits is no longer open, before explicit close" do
    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :exit_status,
        args: ["-c", "exit 7"]
      ])

    transport = %Bpf{port: port, interface: "test", src_mac: <<2, 0, 0, 0, 0, 1>>}

    assert_receive {^port, {:exit_status, 7}} = message, 2_000
    assert Bpf.match(transport, message) == {:error, {:bpf_port_exited, 7}}
    refute Bpf.open?(transport)
    assert Bpf.send(transport, <<1>>) == {:error, :closed}
    assert %Bpf{port: nil} = Bpf.close(transport)
  end
end
