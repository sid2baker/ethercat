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
               backend: redundant_backend("eth0", "eth1"),
               domains: [[id: :main, cycle_time_us: 1_000]],
               slaves: [[name: :sensor, process_data: {:all, :main}]],
               dc: [cycle_ns: 1_000_000]
             )

    assert [%DomainPlan{id: :main, cycle_time_us: 1_000, logical_base: 0}] =
             config.domain_config

    assert %DCConfig{cycle_ns: 1_000_000, lock_policy: :advisory} = config.dc_config

    assert [
             %SlaveConfig{
               name: :sensor,
               driver: EtherCAT.Driver.Default,
               process_data: {:all, :main},
               target_state: :op
             }
           ] = config.slave_config

    assert %EtherCAT.Backend.Redundant{
             primary: %EtherCAT.Backend.Raw{interface: "eth0"},
             secondary: %EtherCAT.Backend.Raw{interface: "eth1"}
           } = config.backend

    assert config.bus_opts[:interface] == "eth0"
    assert config.bus_opts[:backup_interface] == "eth1"
    assert config.bus_opts[:name] == EtherCAT.Bus
    assert config.frame_timeout_floor_ms == 5
    refute Keyword.has_key?(config.bus_opts, :slaves)
    refute Keyword.has_key?(config.bus_opts, :domains)
    refute Keyword.has_key?(config.bus_opts, :scan_poll_ms)
    refute Keyword.has_key?(config.bus_opts, :scan_stable_ms)
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

  test "local_config_changed? treats target-state updates as local preop reconfigure work" do
    current = %SlaveConfig{
      name: :sensor,
      driver: EtherCAT.Driver.Default,
      config: %{},
      process_data: :none,
      target_state: :preop,
      health_poll_ms: 250
    }

    updated = %SlaveConfig{current | target_state: :op}

    assert Config.local_config_changed?(current, updated)
  end

  test "normalize_start_options validates sync config and stores it on slave config" do
    assert {:ok, config} =
             Config.normalize_start_options(
               backend: raw_backend("eth0"),
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
               backend: raw_backend("eth0"),
               slaves: [[name: :sensor, health_poll_ms: 250]]
             )

    assert [%SlaveConfig{health_poll_ms: 250}] = config.slave_config

    assert {:error, {:invalid_slave_config, {:invalid_options, 0, :invalid_health_poll_ms}}} =
             Config.normalize_start_options(
               backend: raw_backend("eth0"),
               slaves: [[name: :sensor, health_poll_ms: 0]]
             )
  end

  test "normalize_start_options defaults health_poll_ms and still allows explicit disable" do
    assert {:ok, defaulted} =
             Config.normalize_start_options(
               backend: raw_backend("eth0"),
               slaves: [[name: :sensor]]
             )

    assert [%SlaveConfig{health_poll_ms: 250}] = defaulted.slave_config

    assert {:ok, disabled} =
             Config.normalize_start_options(
               backend: raw_backend("eth0"),
               slaves: [[name: :sensor, health_poll_ms: nil]]
             )

    assert [%SlaveConfig{health_poll_ms: nil}] = disabled.slave_config
  end

  test "effective_slave_config synthesizes dynamic slaves when none are configured" do
    assert {:ok, [%SlaveConfig{name: :coupler}, %SlaveConfig{name: :slave_1}]} =
             Config.effective_slave_config([], 2)
  end

  test "normalize_start_options rejects duplicate slave names" do
    assert {:error, {:invalid_slave_config, {:duplicate_name, 1, :sensor}}} =
             Config.normalize_start_options(
               backend: raw_backend("eth0"),
               slaves: [[name: :sensor], [name: :sensor]]
             )
  end

  test "normalize_start_options rejects duplicate domain ids" do
    assert {:error, {:invalid_domain_config, {:duplicate_id, 1, :main}}} =
             Config.normalize_start_options(
               backend: raw_backend("eth0"),
               domains: [[id: :main, cycle_time_us: 1_000], [id: :main, cycle_time_us: 1_000]]
             )
  end

  test "normalize_start_options validates scalar master options" do
    assert {:error, {:invalid_start_options, :invalid_base_station}} =
             Config.normalize_start_options(backend: raw_backend("eth0"), base_station: -1)

    assert {:error, {:invalid_start_options, :invalid_base_station}} =
             Config.normalize_start_options(backend: raw_backend("eth0"), base_station: 0x1_0000)

    assert {:error, {:invalid_start_options, :missing_backend}} =
             Config.normalize_start_options([])

    assert {:error, {:invalid_start_options, {:use_backend, [:transport]}}} =
             Config.normalize_start_options(transport: :udp)

    assert {:ok, udp_config} =
             Config.normalize_start_options(
               backend: udp_backend(host: {127, 0, 0, 2}, bind_ip: {127, 0, 0, 1})
             )

    assert %EtherCAT.Backend.Udp{
             host: {127, 0, 0, 2},
             bind_ip: {127, 0, 0, 1},
             port: 0x88A4
           } = udp_config.backend

    assert udp_config.bus_opts[:host] == {127, 0, 0, 2}
    assert udp_config.bus_opts[:bind_ip] == {127, 0, 0, 1}
    assert udp_config.frame_timeout_floor_ms == 5

    assert {:error,
            {:invalid_start_options,
             {:use_backend, [:transport, :host, :bind_ip, :backup_interface]}}} =
             Config.normalize_start_options(
               transport: :udp,
               host: {127, 0, 0, 2},
               bind_ip: {127, 0, 0, 1},
               backup_interface: "eth1"
             )

    assert {:error, {:invalid_start_options, :legacy_dc_cycle_ns}} =
             Config.normalize_start_options(backend: raw_backend("eth0"), dc_cycle_ns: 1_000_000)

    assert {:error, {:invalid_start_options, :invalid_dc}} =
             Config.normalize_start_options(backend: raw_backend("eth0"), dc: [cycle_ns: 0])

    assert {:error, {:invalid_start_options, :invalid_dc}} =
             Config.normalize_start_options(backend: raw_backend("eth0"), dc: [cycle_ns: 500_000])

    assert {:error, {:invalid_start_options, :invalid_dc}} =
             Config.normalize_start_options(
               backend: raw_backend("eth0"),
               dc: [cycle_ns: 1_500_000]
             )

    assert {:error, {:invalid_start_options, :invalid_dc}} =
             Config.normalize_start_options(
               backend: raw_backend("eth0"),
               dc: [lock_policy: :auto]
             )

    assert {:ok, config} =
             Config.normalize_start_options(
               backend: raw_backend("eth0"),
               dc: [cycle_ns: 1_000_000, lock_policy: :fatal]
             )

    assert %DCConfig{lock_policy: :fatal} = config.dc_config

    assert {:error, {:invalid_start_options, :invalid_frame_timeout_ms}} =
             Config.normalize_start_options(backend: raw_backend("eth0"), frame_timeout_ms: 0)

    assert {:error, {:invalid_start_options, :invalid_scan_options}} =
             Config.normalize_start_options(backend: raw_backend("eth0"), scan_poll_ms: 0)

    assert {:error, {:invalid_start_options, :invalid_scan_options}} =
             Config.normalize_start_options(backend: raw_backend("eth0"), scan_stable_ms: -1)

    assert {:error, {:invalid_domain_config, {:invalid_options, 0, :invalid_fields}}} =
             Config.normalize_start_options(
               backend: raw_backend("eth0"),
               domains: [[id: :main, cycle_time_us: 1_500]]
             )

    assert {:error, {:invalid_slave_config, {:invalid_options, 0, :invalid_sync}}} =
             Config.normalize_start_options(
               backend: raw_backend("eth0"),
               slaves: [[name: :sensor, sync: [mode: :sync0, sync1: %{offset_ns: 10_000}]]]
             )

    assert {:error, {:invalid_slave_config, {:invalid_options, 0, :unsupported_sync_ack_mode}}} =
             Config.normalize_start_options(
               backend: raw_backend("eth0"),
               slaves: [[name: :sensor, sync: [mode: :sync0, sync0: %{pulse_ns: 0, shift_ns: 0}]]]
             )
  end

  test "normalize_start_options does not synthesize domains for DC runtime" do
    assert {:ok, config} = Config.normalize_start_options(backend: raw_backend("eth0"))

    assert [] == config.domain_config
  end

  test "normalize_start_options allows multiple independent domains under DC" do
    assert {:ok, config} =
             Config.normalize_start_options(
               backend: raw_backend("eth0"),
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
               backend: raw_backend("eth0"),
               domains: [[id: :fast, cycle_time_us: 1_000, logical_base: 4096]]
             )
  end

  defp raw_backend(interface), do: {:raw, %{interface: interface}}

  defp redundant_backend(primary, secondary) do
    {:redundant,
     %{
       primary: raw_backend(primary),
       secondary: raw_backend(secondary)
     }}
  end

  defp udp_backend(opts) when is_list(opts) do
    {:udp, Map.new(opts)}
  end
end
