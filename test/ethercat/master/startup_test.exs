defmodule EtherCAT.Master.StartupTest do
  use ExUnit.Case, async: true

  alias EtherCAT.DC.Config, as: DCConfig
  alias EtherCAT.Master
  alias EtherCAT.Master.Config.DomainPlan
  alias EtherCAT.Master.Startup

  test "recommended frame timeout uses a host-jitter floor on slower cycles" do
    data = %Master{
      domain_configs: [
        %DomainPlan{id: :main, cycle_time_us: 10_000, miss_threshold: 1000, logical_base: 0}
      ]
    }

    assert Startup.recommended_frame_timeout_ms(data, 4) == 2
  end

  test "recommended frame timeout never exceeds half of the smallest domain cycle" do
    data = %Master{
      domain_configs: [
        %DomainPlan{id: :fast, cycle_time_us: 1_000, miss_threshold: 1000, logical_base: 0}
      ]
    }

    assert Startup.recommended_frame_timeout_ms(data, 4) == 1
  end

  test "recommended frame timeout falls back to DC cycle when no domains are configured" do
    data = %Master{dc_config: %DCConfig{cycle_ns: 10_000_000}}

    assert Startup.recommended_frame_timeout_ms(data, 4) == 2
  end

  test "recommended frame timeout honors explicit override" do
    data = %Master{frame_timeout_override_ms: 7}

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
end
