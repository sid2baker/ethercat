defmodule EtherCAT.BackendTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Backend

  test "udp backends conflict only when host and port match" do
    left = %Backend.Udp{host: {127, 0, 0, 2}, port: 0x88A4}
    same = %Backend.Udp{host: {127, 0, 0, 2}, bind_ip: {127, 0, 0, 1}, port: 0x88A4}
    other_port = %Backend.Udp{host: {127, 0, 0, 2}, port: 0x88A5}

    assert Backend.conflicts?(left, same)
    refute Backend.conflicts?(left, other_port)
  end

  test "raw and redundant backends conflict when they share an interface" do
    raw = %Backend.Raw{interface: "eth0"}

    redundant =
      %Backend.Redundant{
        primary: %Backend.Raw{interface: "eth0"},
        secondary: %Backend.Raw{interface: "eth1"}
      }

    refute Backend.conflicts?(raw, %Backend.Raw{interface: "eth1"})
    assert Backend.conflicts?(raw, redundant)
  end

  test "redundant backends conflict when any leg overlaps" do
    left =
      %Backend.Redundant{
        primary: %Backend.Raw{interface: "eth0"},
        secondary: %Backend.Raw{interface: "eth1"}
      }

    overlapping =
      %Backend.Redundant{
        primary: %Backend.Raw{interface: "eth1"},
        secondary: %Backend.Raw{interface: "eth2"}
      }

    separate =
      %Backend.Redundant{
        primary: %Backend.Raw{interface: "eth2"},
        secondary: %Backend.Raw{interface: "eth3"}
      }

    assert Backend.conflicts?(left, overlapping)
    refute Backend.conflicts?(left, separate)
  end
end
