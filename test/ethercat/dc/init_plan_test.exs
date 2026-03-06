defmodule EtherCAT.DC.InitPlanTest do
  use ExUnit.Case, async: true

  alias EtherCAT.DC.InitPlan
  alias EtherCAT.DC.InitStep
  alias EtherCAT.DC.Snapshot

  test "snapshot derives active ports and receive span from DL status" do
    snapshot =
      Snapshot.new(
        0x1000,
        dl_status([0, 3]),
        %{0 => 100, 1 => nil, 2 => nil, 3 => 180},
        50_000,
        0x1000
      )

    assert snapshot.active_ports == [0, 3]
    assert snapshot.entry_port == 0
    assert snapshot.return_port == 3
    assert snapshot.span_ns == 80
  end

  test "snapshot handles 32-bit receive time wraparound" do
    snapshot =
      Snapshot.new(
        0x1000,
        dl_status([0, 1]),
        %{0 => 0xFFFF_FFF0, 1 => 20, 2 => nil, 3 => nil},
        75_000,
        0x1000
      )

    assert snapshot.entry_port == 0
    assert snapshot.return_port == 1
    assert snapshot.span_ns == 36
  end

  test "build selects the first dc-capable slave and computes chain delays" do
    snapshots = [
      Snapshot.new(
        0x1000,
        dl_status([0, 1]),
        %{0 => 100, 1 => 220, 2 => nil, 3 => nil},
        1_000,
        0x1000
      ),
      Snapshot.new(
        0x1001,
        dl_status([0, 1]),
        %{0 => 260, 1 => 300, 2 => nil, 3 => nil},
        1_150,
        0x1001
      ),
      Snapshot.new(
        0x1002,
        dl_status([0]),
        %{0 => 320, 1 => nil, 2 => nil, 3 => nil},
        1_360,
        0x1002
      )
    ]

    assert {:ok,
            %InitPlan{
              ref_station: 0x1000,
              master_time_ns: 10_000,
              steps: [
                %InitStep{
                  station: 0x1000,
                  delay_ns: 0,
                  offset_ns: 9_000,
                  speed_counter_start: 0x1000
                },
                %InitStep{
                  station: 0x1001,
                  delay_ns: 40,
                  offset_ns: 8_850,
                  speed_counter_start: 0x1001
                },
                %InitStep{
                  station: 0x1002,
                  delay_ns: 60,
                  offset_ns: 8_640,
                  speed_counter_start: 0x1002
                }
              ]
            }} = InitPlan.build(snapshots, 10_000)
  end

  test "build skips non-dc snapshots before choosing the reference slave" do
    snapshots = [
      Snapshot.new(
        0x1000,
        dl_status([0, 1]),
        %{0 => 0, 1 => 0, 2 => nil, 3 => nil},
        0,
        0x1000
      ),
      Snapshot.new(
        0x1001,
        dl_status([0, 1]),
        %{0 => 100, 1 => 180, 2 => nil, 3 => nil},
        500,
        0x1001
      )
    ]

    assert {:ok,
            %InitPlan{
              ref_station: 0x1001,
              steps: [
                %InitStep{
                  station: 0x1001,
                  delay_ns: 0,
                  offset_ns: 1_000,
                  speed_counter_start: 0x1001
                }
              ]
            }} = InitPlan.build(snapshots, 1_500)
  end

  test "build fails when no dc-capable snapshot exists" do
    snapshots = [
      Snapshot.new(
        0x1000,
        dl_status([0, 1]),
        %{0 => 0, 1 => 0, 2 => nil, 3 => nil},
        0,
        0x1000
      )
    ]

    assert {:error, :no_dc_capable_slave} = InitPlan.build(snapshots, 1_500)
  end

  defp dl_status(active_ports) do
    {phy0, loop0, comm0} = port_bits(0, active_ports)
    {phy1, loop1, comm1} = port_bits(1, active_ports)
    {phy2, loop2, comm2} = port_bits(2, active_ports)
    {phy3, loop3, comm3} = port_bits(3, active_ports)

    <<phy3::1, phy2::1, phy1::1, phy0::1, 0::3, 1::1, comm3::1, loop3::1, comm2::1, loop2::1,
      comm1::1, loop1::1, comm0::1, loop0::1>>
  end

  defp port_bits(port, active_ports) do
    if port in active_ports do
      {1, 0, 1}
    else
      {0, 1, 0}
    end
  end
end
