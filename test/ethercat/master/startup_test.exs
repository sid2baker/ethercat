defmodule EtherCAT.Master.StartupTest do
  use ExUnit.Case, async: true

  alias EtherCAT.DC.Config, as: DCConfig
  alias EtherCAT.Master
  alias EtherCAT.Master.Config.DomainPlan
  alias EtherCAT.Master.Startup

  test "recommended frame timeout uses the UDP transport floor for short simulator cycles" do
    data = %Master{
      frame_timeout_floor_ms: 5,
      domain_configs: [
        %DomainPlan{
          id: :main,
          cycle_time_us: 10_000,
          miss_threshold: 1000,
          recovery_threshold: 3,
          logical_base: 0
        }
      ]
    }

    assert Startup.recommended_frame_timeout_ms(data, 4) == 5
  end

  test "recommended frame timeout grows with topology once it exceeds the default transport floor" do
    data = %Master{
      frame_timeout_floor_ms: 5,
      domain_configs: [
        %DomainPlan{
          id: :fast,
          cycle_time_us: 1_000,
          miss_threshold: 1000,
          recovery_threshold: 3,
          logical_base: 0
        }
      ]
    }

    assert Startup.recommended_frame_timeout_ms(data, 160) == 7
  end

  test "recommended frame timeout falls back to the configured floor when no slaves are present" do
    data = %Master{dc_config: %DCConfig{cycle_ns: 10_000_000}, frame_timeout_floor_ms: 5}

    assert Startup.recommended_frame_timeout_ms(data, 0) == 5
  end

  test "recommended frame timeout honors explicit override" do
    data = %Master{frame_timeout_override_ms: 7, frame_timeout_floor_ms: 5}

    assert Startup.recommended_frame_timeout_ms(data, 4) == 7
  end

  test "validate_topology_addressing allows the signed auto-increment boundary" do
    data = %Master{base_station: 0}

    assert :ok = Startup.validate_topology_addressing(data, 32_769)
  end

  test "validate_topology_addressing rejects rings larger than auto-increment addressing" do
    data = %Master{base_station: 0}

    assert {:error,
            {:unsupported_topology, {:too_many_slaves_for_auto_increment, 32_770, 32_769}}} =
             Startup.validate_topology_addressing(data, 32_770)
  end

  test "validate_topology_addressing rejects configured station address overflow" do
    data = %Master{base_station: 0xFFFF}

    assert {:error, {:unsupported_topology, {:station_address_overflow, 0xFFFF, 2, 0xFFFF}}} =
             Startup.validate_topology_addressing(data, 2)
  end

  test "classify_dc_init_result preserves a successful init" do
    assert {:ok, 0x1001, [0x1001, 0x1002]} =
             Startup.classify_dc_init_result({:ok, 0x1001, [0x1001, 0x1002]})
  end

  test "classify_dc_init_result allows no DC-capable slave as a DC-disabled startup" do
    assert {:ok, nil, []} =
             Startup.classify_dc_init_result({:error, :no_dc_capable_slave})
  end

  test "classify_dc_init_result fails startup for real DC initialization errors" do
    assert {:error, {:dc_init_failed, {:dc_snapshot_failed, 0x1000, :timeout}}} =
             Startup.classify_dc_init_result({:error, {:dc_snapshot_failed, 0x1000, :timeout}})
  end
end
