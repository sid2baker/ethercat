defmodule EtherCAT.Slave.Sync.PlanTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Slave.Sync.Plan
  alias EtherCAT.Slave.Sync.Config

  test "build aligns sync0 start time from local DC time" do
    config = %Config{
      mode: :sync0,
      sync0: %{pulse_ns: 5_000, shift_ns: 25_000},
      latches: %{}
    }

    assert {:ok, plan} = Plan.build(config, 1_000_000, 1_234_000_000, 42)

    assert plan.activation == 0x03
    assert plan.cyclic_unit_control == 0x0000
    assert plan.sync0_cycle_ns == 1_000_000
    assert plan.sync1_cycle_ns == 0
    assert plan.pulse_ns == 5_000
    assert plan.start_time_ns == 1_335_025_000
    assert plan.sync_diff_ns == 42
  end

  test "build uses true alignment cycle when sync1 offset exceeds one cycle" do
    config = %Config{
      mode: :sync1,
      sync0: %{pulse_ns: 10_000, shift_ns: 0},
      sync1: %{offset_ns: 1_250_000},
      latches: %{}
    }

    assert {:ok, plan} = Plan.build(config, 1_000_000, 900_000_000, 0)

    assert plan.activation == 0x07
    assert plan.sync0_cycle_ns == 1_000_000
    assert plan.sync1_cycle_ns == 1_250_000
    assert plan.start_time_ns == 1_002_000_000
  end

  test "build supports latch-only sync config without timing registers" do
    config = %Config{
      mode: nil,
      latches: %{
        product_edge: {0, :pos},
        home_marker: {1, :neg}
      }
    }

    assert {:ok, plan} = Plan.build(config, 1_000_000, nil, nil)

    assert plan.activation == 0x00
    assert plan.sync0_cycle_ns == nil
    assert plan.pulse_ns == nil
    assert plan.start_time_ns == nil
    assert plan.latch_names == %{{0, :pos} => :product_edge, {1, :neg} => :home_marker}
    assert plan.active_latches == [{0, :pos}, {1, :neg}]
    assert plan.latch0_control == 0x01
    assert plan.latch1_control == 0x02
  end

  test "build rejects timed sync modes without a DC-time snapshot" do
    config = %Config{
      mode: :sync0,
      sync0: %{pulse_ns: 5_000, shift_ns: 0},
      latches: %{}
    }

    assert {:error, :missing_dc_time} = Plan.build(config, 1_000_000, nil, nil)
  end
end
