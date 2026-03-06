defmodule EtherCAT.Master.ConfigTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Domain.Config, as: DomainConfig
  alias EtherCAT.Master.Config
  alias EtherCAT.Slave.Config, as: SlaveConfig

  test "normalize_start_options stores internal config as structs" do
    assert {:ok, config} =
             Config.normalize_start_options(
               interface: "eth0",
               domains: [[id: :main, period_ms: 10]],
               slaves: [[name: :sensor, process_data: {:all, :main}]],
               backup_interface: "eth1"
             )

    assert [%DomainConfig{id: :main, period_ms: 10}] = config.domain_config

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
    current = %SlaveConfig{name: :sensor, config: %{gain: 1}, process_data: :none}

    assert {:ok, %SlaveConfig{} = updated} =
             Config.normalize_runtime_slave_config(
               :sensor,
               [config: %{gain: 2}, target_state: :preop],
               current
             )

    assert updated.name == :sensor
    assert updated.config == %{gain: 2}
    assert updated.process_data == :none
    assert updated.target_state == :preop
  end

  test "effective_slave_config synthesizes dynamic slaves when none are configured" do
    assert {:ok, [%SlaveConfig{name: :coupler}, %SlaveConfig{name: :slave_1}]} =
             Config.effective_slave_config([], 2)
  end

  test "normalize_start_options validates scalar master options" do
    assert {:error, {:invalid_start_options, :invalid_base_station}} =
             Config.normalize_start_options(interface: "eth0", base_station: -1)

    assert {:error, {:invalid_start_options, :invalid_dc_cycle_ns}} =
             Config.normalize_start_options(interface: "eth0", dc_cycle_ns: 0)

    assert {:error, {:invalid_start_options, :invalid_frame_timeout_ms}} =
             Config.normalize_start_options(interface: "eth0", frame_timeout_ms: 0)
  end
end
