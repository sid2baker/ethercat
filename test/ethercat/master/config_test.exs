defmodule EtherCAT.Master.ConfigTest do
  use ExUnit.Case, async: true

  alias EtherCAT.DC.Config, as: DCConfig
  alias EtherCAT.Master.Config
  alias EtherCAT.Master.Config.DomainPlan
  alias EtherCAT.Slave.Config, as: SlaveConfig
  alias EtherCAT.Slave.Sync.Config, as: SyncConfig

  test "normalize_start_options stores internal config as structs" do
    assert {:ok, config} =
             Config.normalize_start_options(
               interface: "eth0",
               domains: [[id: :main, cycle_time_us: 1_000]],
               slaves: [[name: :sensor, process_data: {:all, :main}]],
               dc: [cycle_ns: 1_000_000],
               backup_interface: "eth1"
             )

    assert [%DomainPlan{id: :main, cycle_time_us: 1_000, logical_base: 0}] =
             config.domain_config

    assert %DCConfig{cycle_ns: 1_000_000, lock_policy: :advisory} = config.dc_config

    assert [
             %SlaveConfig{
               name: :sensor,
               driver: EtherCAT.Slave.Driver.Default,
               process_data: {:all, :main},
               target_state: :op
             }
           ] = config.slave_config

    assert config.bus_opts[:interface] == "eth0"
    assert config.bus_opts[:backup_interface] == "eth1"
    assert config.bus_opts[:name] == EtherCAT.Bus
    refute Keyword.has_key?(config.bus_opts, :slaves)
    refute Keyword.has_key?(config.bus_opts, :domains)
  end

  test "normalize_runtime_slave_config merges updates into the current struct" do
    current = %SlaveConfig{
      name: :sensor,
      config: %{gain: 1},
      process_data: :none,
      health_poll_ms: 100
    }

    assert {:ok, %SlaveConfig{} = updated} =
             Config.normalize_runtime_slave_config(
               :sensor,
               [config: %{gain: 2}, target_state: :preop, health_poll_ms: 250],
               current
             )

    assert updated.name == :sensor
    assert updated.config == %{gain: 2}
    assert updated.process_data == :none
    assert updated.target_state == :preop
    assert updated.health_poll_ms == 250
  end

  test "normalize_start_options validates sync config and stores it on slave config" do
    assert {:ok, config} =
             Config.normalize_start_options(
               interface: "eth0",
               slaves: [
                 [
                   name: :sensor,
                   sync: [
                     mode: :sync1,
                     sync0: %{pulse_ns: 5_000, shift_ns: 0},
                     sync1: %{offset_ns: 25_000},
                     latches: %{product_edge: {0, :pos}}
                   ]
                 ]
               ]
             )

    assert [%SlaveConfig{sync: %SyncConfig{} = sync}] = config.slave_config
    assert sync.mode == :sync1
    assert sync.sync0 == %{pulse_ns: 5_000, shift_ns: 0}
    assert sync.sync1 == %{offset_ns: 25_000}
    assert sync.latches == %{product_edge: {0, :pos}}
  end

  test "normalize_start_options preserves and validates health_poll_ms" do
    assert {:ok, config} =
             Config.normalize_start_options(
               interface: "eth0",
               slaves: [[name: :sensor, health_poll_ms: 250]]
             )

    assert [%SlaveConfig{health_poll_ms: 250}] = config.slave_config

    assert {:error, {:invalid_slave_config, {:invalid_options, 0, :invalid_health_poll_ms}}} =
             Config.normalize_start_options(
               interface: "eth0",
               slaves: [[name: :sensor, health_poll_ms: 0]]
             )
  end

  test "effective_slave_config synthesizes dynamic slaves when none are configured" do
    assert {:ok, [%SlaveConfig{name: :coupler}, %SlaveConfig{name: :slave_1}]} =
             Config.effective_slave_config([], 2)
  end

  test "normalize_start_options validates scalar master options" do
    assert {:error, {:invalid_start_options, :invalid_base_station}} =
             Config.normalize_start_options(interface: "eth0", base_station: -1)

    assert {:error, {:invalid_start_options, :legacy_dc_cycle_ns}} =
             Config.normalize_start_options(interface: "eth0", dc_cycle_ns: 1_000_000)

    assert {:error, {:invalid_start_options, :invalid_dc}} =
             Config.normalize_start_options(interface: "eth0", dc: [cycle_ns: 0])

    assert {:error, {:invalid_start_options, :invalid_dc}} =
             Config.normalize_start_options(interface: "eth0", dc: [cycle_ns: 500_000])

    assert {:error, {:invalid_start_options, :invalid_dc}} =
             Config.normalize_start_options(interface: "eth0", dc: [cycle_ns: 1_500_000])

    assert {:error, {:invalid_start_options, :invalid_dc}} =
             Config.normalize_start_options(interface: "eth0", dc: [lock_policy: :auto])

    assert {:ok, config} =
             Config.normalize_start_options(
               interface: "eth0",
               dc: [cycle_ns: 1_000_000, lock_policy: :fatal]
             )

    assert %DCConfig{lock_policy: :fatal} = config.dc_config

    assert {:error, {:invalid_start_options, :invalid_frame_timeout_ms}} =
             Config.normalize_start_options(interface: "eth0", frame_timeout_ms: 0)

    assert {:error, {:invalid_domain_config, {:invalid_options, 0, :invalid_fields}}} =
             Config.normalize_start_options(
               interface: "eth0",
               domains: [[id: :main, cycle_time_us: 1_500]]
             )

    assert {:error, {:invalid_slave_config, {:invalid_options, 0, :invalid_sync}}} =
             Config.normalize_start_options(
               interface: "eth0",
               slaves: [[name: :sensor, sync: [mode: :sync0, sync1: %{offset_ns: 10_000}]]]
             )

    assert {:error, {:invalid_slave_config, {:invalid_options, 0, :unsupported_sync_ack_mode}}} =
             Config.normalize_start_options(
               interface: "eth0",
               slaves: [[name: :sensor, sync: [mode: :sync0, sync0: %{pulse_ns: 0, shift_ns: 0}]]]
             )
  end

  test "normalize_start_options does not synthesize domains for DC runtime" do
    assert {:ok, config} = Config.normalize_start_options(interface: "eth0")

    assert [] == config.domain_config
  end

  test "normalize_start_options allows multiple independent domains under DC" do
    assert {:ok, config} =
             Config.normalize_start_options(
               interface: "eth0",
               dc: [cycle_ns: 1_000_000],
               domains: [[id: :fast, cycle_time_us: 1_000], [id: :slow, cycle_time_us: 10_000]]
             )

    assert [%DomainPlan{id: :fast, logical_base: 0}, %DomainPlan{id: :slow, logical_base: 2048}] =
             config.domain_config
  end

  test "normalize_start_options rejects logical_base in master-facing domain config" do
    assert {:error,
            {:invalid_domain_config, {:invalid_options, 0, {:unsupported_option, :logical_base}}}} =
             Config.normalize_start_options(
               interface: "eth0",
               domains: [[id: :fast, cycle_time_us: 1_000, logical_base: 4096]]
             )
  end
end
