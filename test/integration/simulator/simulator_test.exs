defmodule EtherCAT.Integration.SimulatorTest do
  use ExUnit.Case, async: false

  alias EtherCAT.DC.Config, as: DCConfig
  alias EtherCAT.Domain.Config, as: DomainConfig
  alias EtherCAT.Slave.Config, as: SlaveConfig
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Slave
  alias EtherCAT.Simulator.Slave.Driver
  alias EtherCAT.Simulator.Udp
  import EtherCAT.Integration.Assertions

  @master_ip {127, 0, 0, 1}
  @simulator_ip {127, 0, 0, 2}

  setup tags do
    _ = EtherCAT.stop()

    devices = Map.get(tags, :devices, [Slave.digital_io(name: :sim)])

    {:ok, simulator} = Simulator.start_link(devices: devices)
    {:ok, endpoint} = Udp.start_link(simulator: simulator, ip: @simulator_ip, port: 0)
    {:ok, %{port: port}} = Udp.info(endpoint)

    on_exit(fn ->
      :ok = EtherCAT.stop()

      if Process.alive?(endpoint) do
        GenServer.stop(endpoint)
      end

      if Process.alive?(simulator) do
        GenServer.stop(simulator)
      end
    end)

    {:ok, endpoint: endpoint, simulator: simulator, port: port, devices: devices}
  end

  test "boots the real master against a loopback UDP simulated slave and exchanges cyclic I/O",
       %{simulator: simulator, port: port} do
    assert :ok =
             EtherCAT.start(
               transport: :udp,
               bind_ip: @master_ip,
               host: @simulator_ip,
               port: port,
               dc: nil,
               scan_stable_ms: 20,
               scan_poll_ms: 10,
               frame_timeout_ms: 2,
               domains: [%DomainConfig{id: :main, cycle_time_us: 10_000}],
               slaves: [
                 %SlaveConfig{
                   name: :sim,
                   driver: Driver,
                   process_data: [out: :main, in: :main],
                   target_state: :op
                 }
               ]
             )

    assert :ok = EtherCAT.await_operational(2_000)
    assert :operational = EtherCAT.state()

    assert :ok = EtherCAT.write_output(:sim, :out, 1)

    assert_eventually(fn ->
      assert {:ok, {1, updated_at_us}} = EtherCAT.read_input(:sim, :in)
      assert is_integer(updated_at_us)
    end)

    assert {:ok, 1} = Simulator.output_value(simulator, :sim)
  end

  @tag devices: [Slave.digital_io(name: :sim_a), Slave.digital_io(name: :sim_b)]
  test "boots a multi-slave simulated ring and exchanges cyclic I/O with both slaves",
       %{simulator: simulator, port: port, devices: devices} do
    assert :ok =
             EtherCAT.start(
               transport: :udp,
               bind_ip: @master_ip,
               host: @simulator_ip,
               port: port,
               dc: nil,
               scan_stable_ms: 20,
               scan_poll_ms: 10,
               frame_timeout_ms: 2,
               domains: [%DomainConfig{id: :main, cycle_time_us: 10_000}],
               slaves: slave_configs(devices)
             )

    assert :ok = EtherCAT.await_operational(2_000)
    assert :operational = EtherCAT.state()

    assert :ok = EtherCAT.write_output(:sim_a, :out, 1)
    assert :ok = EtherCAT.write_output(:sim_b, :out, 2)

    assert_eventually(fn ->
      assert {:ok, {1, updated_a}} = EtherCAT.read_input(:sim_a, :in)
      assert {:ok, {2, updated_b}} = EtherCAT.read_input(:sim_b, :in)
      assert is_integer(updated_a)
      assert is_integer(updated_b)
    end)

    assert {:ok, 1} = Simulator.output_value(simulator, :sim_a)
    assert {:ok, 2} = Simulator.output_value(simulator, :sim_b)
  end

  @tag devices: [Slave.coupler(name: :coupler), Slave.lan9252_demo(name: :io)]
  test "boots a heterogeneous ring with a coupler device and a LAN9252-style IO slave",
       %{simulator: simulator, port: port} do
    assert :ok =
             EtherCAT.start(
               transport: :udp,
               bind_ip: @master_ip,
               host: @simulator_ip,
               port: port,
               dc: nil,
               scan_stable_ms: 20,
               scan_poll_ms: 10,
               frame_timeout_ms: 2,
               domains: [%DomainConfig{id: :main, cycle_time_us: 10_000}],
               slaves: [
                 %SlaveConfig{name: :coupler, process_data: :none, target_state: :op},
                 %SlaveConfig{
                   name: :io,
                   driver: Driver,
                   config: %{profile: :lan9252_demo},
                   process_data: {:all, :main},
                   target_state: :op
                 }
               ]
             )

    assert :ok = EtherCAT.await_operational(2_000)
    assert :operational = EtherCAT.state()

    assert {:ok, %{station: 0x1000}} = EtherCAT.slave_info(:coupler)
    assert {:ok, %{station: 0x1001}} = EtherCAT.slave_info(:io)

    assert :ok = EtherCAT.write_output(:io, :led0, 1)
    assert :ok = EtherCAT.write_output(:io, :led1, 2)

    assert_eventually(fn ->
      assert {:ok, {1, updated_at_us}} = EtherCAT.read_input(:io, :button1)
      assert is_integer(updated_at_us)
    end)

    assert {:ok, <<1, 2>>} = Simulator.output_image(simulator, :io)
  end

  @tag devices: [Slave.lan9252_demo(name: :mailbox)]
  test "supports expedited CoE uploads and downloads in PREOP over the real UDP transport",
       %{port: port} do
    assert :ok =
             EtherCAT.start(
               transport: :udp,
               bind_ip: @master_ip,
               host: @simulator_ip,
               port: port,
               dc: nil,
               scan_stable_ms: 20,
               scan_poll_ms: 10,
               frame_timeout_ms: 2,
               domains: [%DomainConfig{id: :main, cycle_time_us: 10_000}],
               slaves: [
                 %SlaveConfig{
                   name: :mailbox,
                   driver: Driver,
                   config: %{profile: :lan9252_demo},
                   process_data: :none,
                   target_state: :preop
                 }
               ]
             )

    assert :ok = EtherCAT.await_running(2_000)
    assert :preop_ready = EtherCAT.state()

    assert_eventually(fn ->
      assert {:ok, <<0x34, 0x12>>} = EtherCAT.upload_sdo(:mailbox, 0x2000, 0x01)
    end)

    assert_eventually(fn ->
      assert :ok = EtherCAT.download_sdo(:mailbox, 0x2000, 0x01, <<0x78, 0x56>>)
    end)

    assert_eventually(fn ->
      assert {:ok, <<0x78, 0x56>>} = EtherCAT.upload_sdo(:mailbox, 0x2000, 0x01)
    end)
  end

  @tag devices: [Slave.lan9252_demo(name: :io)]
  test "support slave value API drives simulator inputs and inspects outputs",
       %{simulator: simulator, port: port} do
    assert :ok =
             EtherCAT.start(
               transport: :udp,
               bind_ip: @master_ip,
               host: @simulator_ip,
               port: port,
               dc: nil,
               scan_stable_ms: 20,
               scan_poll_ms: 10,
               frame_timeout_ms: 2,
               domains: [%DomainConfig{id: :main, cycle_time_us: 10_000}],
               slaves: [
                 %SlaveConfig{
                   name: :io,
                   driver: Driver,
                   config: %{profile: :lan9252_demo},
                   process_data: [led0: :main, led1: :main, button1: :main],
                   target_state: :op
                 }
               ]
             )

    assert :ok = EtherCAT.await_operational(2_000)

    assert {:ok, [:button1, :led0, :led1]} =
             simulator
             |> Slave.signals(:io)
             |> then(fn {:ok, names} -> {:ok, Enum.sort(names)} end)

    assert :ok = Slave.set_value(simulator, :io, :button1, 7)

    assert_eventually(fn ->
      assert {:ok, {7, updated_at_us}} = EtherCAT.read_input(:io, :button1)
      assert is_integer(updated_at_us)
    end)

    assert :ok = EtherCAT.write_output(:io, :led0, 1)
    assert :ok = EtherCAT.write_output(:io, :led1, 2)

    assert_eventually(fn ->
      assert {:ok, 1} = Slave.get_value(simulator, :io, :led0)
      assert {:ok, 2} = Slave.get_value(simulator, :io, :led1)
    end)
  end

  @tag devices: [Slave.lan9252_demo(name: :mailbox)]
  test "supports segmented CoE uploads and downloads over the real UDP transport",
       %{port: port} do
    assert :ok =
             EtherCAT.start(
               transport: :udp,
               bind_ip: @master_ip,
               host: @simulator_ip,
               port: port,
               dc: nil,
               scan_stable_ms: 20,
               scan_poll_ms: 10,
               frame_timeout_ms: 2,
               domains: [%DomainConfig{id: :main, cycle_time_us: 10_000}],
               slaves: [
                 %SlaveConfig{
                   name: :mailbox,
                   driver: Driver,
                   config: %{profile: :lan9252_demo},
                   process_data: :none,
                   target_state: :preop
                 }
               ]
             )

    assert :ok = EtherCAT.await_running(2_000)
    assert :preop_ready = EtherCAT.state()

    initial_blob = "hello-sim\0\0\0"
    updated_blob = "segmented!!?"

    assert_eventually(fn ->
      assert {:ok, ^initial_blob} = EtherCAT.upload_sdo(:mailbox, 0x2001, 0x01)
    end)

    assert_eventually(fn ->
      assert :ok = EtherCAT.download_sdo(:mailbox, 0x2001, 0x01, updated_blob)
    end)

    assert_eventually(fn ->
      assert {:ok, ^updated_blob} = EtherCAT.upload_sdo(:mailbox, 0x2001, 0x01)
    end)
  end

  @tag devices: [Slave.lan9252_demo(name: :io)]
  test "signal subscriptions emit widget-friendly change notifications",
       %{simulator: simulator, port: port} do
    assert :ok =
             EtherCAT.start(
               transport: :udp,
               bind_ip: @master_ip,
               host: @simulator_ip,
               port: port,
               dc: nil,
               scan_stable_ms: 20,
               scan_poll_ms: 10,
               frame_timeout_ms: 2,
               domains: [%DomainConfig{id: :main, cycle_time_us: 10_000}],
               slaves: [
                 %SlaveConfig{
                   name: :io,
                   driver: Driver,
                   config: %{profile: :lan9252_demo},
                   process_data: {:all, :main},
                   target_state: :op
                 }
               ]
             )

    assert :ok = EtherCAT.await_operational(2_000)
    assert :ok = Slave.subscribe(simulator, :io)

    assert :ok = Slave.set_value(simulator, :io, :button1, 9)

    assert_receive {:ethercat_simulator, ^simulator, :signal_changed, :io, :button1, 9}, 500

    assert :ok = EtherCAT.write_output(:io, :led0, 1)

    assert_receive {:ethercat_simulator, ^simulator, :signal_changed, :io, :led0, 1}, 500

    assert :ok = Slave.unsubscribe(simulator, :io)
  end

  @tag devices: [Slave.analog_io(name: :analog)]
  test "typed analog profile exchanges scaled values over cyclic PDOs",
       %{simulator: simulator, port: port} do
    assert :ok =
             EtherCAT.start(
               transport: :udp,
               bind_ip: @master_ip,
               host: @simulator_ip,
               port: port,
               dc: nil,
               scan_stable_ms: 20,
               scan_poll_ms: 10,
               frame_timeout_ms: 2,
               domains: [%DomainConfig{id: :main, cycle_time_us: 10_000}],
               slaves: [
                 %SlaveConfig{
                   name: :analog,
                   driver: Driver,
                   config: %{profile: :analog_io},
                   process_data: {:all, :main},
                   target_state: :op
                 }
               ]
             )

    assert :ok = EtherCAT.await_operational(2_000)

    assert :ok = EtherCAT.write_output(:analog, :ao0, 12.3)

    assert_eventually(fn ->
      assert {:ok, {value, updated_at_us}} = EtherCAT.read_input(:analog, :ai0)
      assert_in_delta value, 12.3, 0.05
      assert is_integer(updated_at_us)
    end)

    assert {:ok, 12.3} = Slave.get_value(simulator, :analog, :ao0)
    assert {:ok, 12.3} = Slave.get_value(simulator, :analog, :ai0)
  end

  @tag devices: [Slave.temperature_input(name: :temp)]
  test "temperature profile exposes typed inputs and enforces read-only object access",
       %{simulator: simulator, port: port} do
    assert :ok =
             EtherCAT.start(
               transport: :udp,
               bind_ip: @master_ip,
               host: @simulator_ip,
               port: port,
               dc: nil,
               scan_stable_ms: 20,
               scan_poll_ms: 10,
               frame_timeout_ms: 2,
               domains: [%DomainConfig{id: :main, cycle_time_us: 10_000}],
               slaves: [
                 %SlaveConfig{
                   name: :temp,
                   driver: Driver,
                   config: %{profile: :temperature_input},
                   process_data: {:all, :main},
                   target_state: :op
                 }
               ]
             )

    assert :ok = EtherCAT.await_operational(2_000)
    assert :ok = Slave.set_value(simulator, :temp, :temp0, 37.5)
    assert :ok = Slave.set_value(simulator, :temp, :status, 3)

    assert_eventually(fn ->
      assert {:ok, {temperature, updated_at_us}} = EtherCAT.read_input(:temp, :temp0)
      assert {:ok, {3, status_updated_at_us}} = EtherCAT.read_input(:temp, :status)
      assert_in_delta temperature, 37.5, 0.05
      assert is_integer(updated_at_us)
      assert is_integer(status_updated_at_us)
    end)

    assert_eventually(fn ->
      assert {:error, {:sdo_abort, 0x6000, 0x01, 0x0601_0002}} =
               EtherCAT.download_sdo(:temp, 0x6000, 0x01, <<0x00, 0x00>>)
    end)
  end

  @tag devices: [Slave.servo_drive(name: :axis)]
  test "servo drive profile supports CiA402-style enable sequence and DC runtime",
       %{port: port} do
    assert :ok =
             EtherCAT.start(
               transport: :udp,
               bind_ip: @master_ip,
               host: @simulator_ip,
               port: port,
               dc: %DCConfig{
                 cycle_ns: 10_000_000,
                 await_lock?: false,
                 lock_threshold_ns: 100,
                 lock_timeout_ms: 1_000,
                 warmup_cycles: 0
               },
               scan_stable_ms: 20,
               scan_poll_ms: 10,
               frame_timeout_ms: 2,
               domains: [%DomainConfig{id: :main, cycle_time_us: 10_000}],
               slaves: [
                 %SlaveConfig{
                   name: :axis,
                   driver: Driver,
                   config: %{profile: :servo_drive},
                   process_data: {:all, :main},
                   target_state: :op
                 }
               ]
             )

    assert :ok = EtherCAT.await_operational(2_000)

    assert %EtherCAT.DC.Status{
             active?: true,
             reference_station: 0x1000,
             lock_state: lock_state
           } = EtherCAT.dc_status()

    assert lock_state in [:locking, :locked]
    assert {:ok, %{name: :axis, station: 0x1000}} = EtherCAT.reference_clock()

    assert_eventually(fn ->
      assert {:ok, {0x0040, _}} = EtherCAT.read_input(:axis, :statusword)
    end)

    assert :ok = EtherCAT.write_output(:axis, :controlword, 0x0006)

    assert_eventually(fn ->
      assert {:ok, {0x0021, _}} = EtherCAT.read_input(:axis, :statusword)
    end)

    assert :ok = EtherCAT.write_output(:axis, :controlword, 0x0007)

    assert_eventually(fn ->
      assert {:ok, {0x0023, _}} = EtherCAT.read_input(:axis, :statusword)
    end)

    assert :ok = EtherCAT.write_output(:axis, :target_position, 12_345)
    assert :ok = EtherCAT.write_output(:axis, :mode_of_operation, 1)
    assert :ok = EtherCAT.write_output(:axis, :controlword, 0x000F)

    assert_eventually(fn ->
      assert {:ok, {0x0027, _}} = EtherCAT.read_input(:axis, :statusword)
      assert {:ok, {12_345, _}} = EtherCAT.read_input(:axis, :position_actual)
      assert {:ok, {1, _}} = EtherCAT.read_input(:axis, :mode_display)
    end)

    assert_eventually(fn ->
      assert {:ok, <<0x27, 0x00>>} = EtherCAT.upload_sdo(:axis, 0x6041, 0x00)
      assert {:ok, <<57, 48, 0, 0>>} = EtherCAT.upload_sdo(:axis, 0x6064, 0x00)
    end)
  end

  test "persistent wrong WKC drives the master into recovering and clears cleanly",
       %{simulator: simulator, port: port} do
    assert :ok =
             EtherCAT.start(
               transport: :udp,
               bind_ip: @master_ip,
               host: @simulator_ip,
               port: port,
               dc: nil,
               scan_stable_ms: 20,
               scan_poll_ms: 10,
               frame_timeout_ms: 2,
               domains: [%DomainConfig{id: :main, cycle_time_us: 10_000}],
               slaves: [
                 %SlaveConfig{
                   name: :sim,
                   driver: Driver,
                   process_data: [out: :main, in: :main],
                   target_state: :op
                 }
               ]
             )

    assert :ok = EtherCAT.await_operational(2_000)
    assert :ok = Simulator.inject_fault(simulator, {:wkc_offset, -1})

    assert_eventually(fn ->
      assert :recovering = EtherCAT.state()
    end)

    assert :ok = Simulator.clear_faults(simulator)

    assert_eventually(
      fn ->
        assert :operational = EtherCAT.state()
      end,
      100
    )
  end

  test "dropping responses drives the master into recovering and clears cleanly",
       %{simulator: simulator, port: port} do
    assert :ok =
             EtherCAT.start(
               transport: :udp,
               bind_ip: @master_ip,
               host: @simulator_ip,
               port: port,
               dc: nil,
               scan_stable_ms: 20,
               scan_poll_ms: 10,
               frame_timeout_ms: 2,
               domains: [%DomainConfig{id: :main, cycle_time_us: 10_000, miss_threshold: 1}],
               slaves: [
                 %SlaveConfig{
                   name: :sim,
                   driver: Driver,
                   process_data: [out: :main, in: :main],
                   target_state: :op
                 }
               ]
             )

    assert :ok = EtherCAT.await_operational(2_000)
    assert :ok = Simulator.inject_fault(simulator, :drop_responses)

    assert_eventually(fn ->
      assert :recovering = EtherCAT.state()
    end)

    assert :ok = Simulator.clear_faults(simulator)

    assert_eventually(
      fn ->
        assert :operational = EtherCAT.state()
      end,
      100
    )
  end

  @tag devices: [Slave.lan9252_demo(name: :mailbox)]
  test "mailbox abort injection is surfaced through the public SDO API",
       %{simulator: simulator, port: port} do
    assert :ok =
             EtherCAT.start(
               transport: :udp,
               bind_ip: @master_ip,
               host: @simulator_ip,
               port: port,
               dc: nil,
               scan_stable_ms: 20,
               scan_poll_ms: 10,
               frame_timeout_ms: 2,
               domains: [%DomainConfig{id: :main, cycle_time_us: 10_000}],
               slaves: [
                 %SlaveConfig{
                   name: :mailbox,
                   driver: Driver,
                   config: %{profile: :lan9252_demo},
                   process_data: :none,
                   target_state: :preop,
                   health_poll_ms: 20
                 }
               ]
             )

    assert :ok = EtherCAT.await_running(2_000)
    assert :preop_ready = EtherCAT.state()

    assert :ok =
             Simulator.inject_fault(
               simulator,
               {:mailbox_abort, :mailbox, 0x2000, 0x01, 0x0601_0002}
             )

    assert_eventually(fn ->
      assert {:error, {:sdo_abort, 0x2000, 0x01, 0x0601_0002}} =
               EtherCAT.upload_sdo(:mailbox, 0x2000, 0x01)
    end)
  end

  test "retreating a slave to SAFEOP is reported through slave faults without breaking cyclic runtime",
       %{simulator: simulator, port: port} do
    assert :ok =
             EtherCAT.start(
               transport: :udp,
               bind_ip: @master_ip,
               host: @simulator_ip,
               port: port,
               dc: nil,
               scan_stable_ms: 20,
               scan_poll_ms: 10,
               frame_timeout_ms: 2,
               domains: [%DomainConfig{id: :main, cycle_time_us: 10_000}],
               slaves: [
                 %SlaveConfig{
                   name: :sim,
                   driver: Driver,
                   process_data: [out: :main, in: :main],
                   target_state: :op,
                   health_poll_ms: 20
                 }
               ]
             )

    assert :ok = EtherCAT.await_operational(2_000)
    assert :ok = Simulator.inject_fault(simulator, {:retreat_to_safeop, :sim})

    assert_eventually(fn ->
      assert :operational = EtherCAT.state()

      assert [%{name: :sim, fault: {:retreated, :safeop}}] =
               EtherCAT.slaves()

      assert {:ok, %{al_state: :safeop}} = EtherCAT.slave_info(:sim)
    end)
  end

  test "disconnecting and reconnecting a PDO-participating slave returns recovering to operational",
       %{simulator: simulator, port: port} do
    assert :ok =
             EtherCAT.start(
               transport: :udp,
               bind_ip: @master_ip,
               host: @simulator_ip,
               port: port,
               dc: nil,
               scan_stable_ms: 20,
               scan_poll_ms: 10,
               frame_timeout_ms: 2,
               domains: [%DomainConfig{id: :main, cycle_time_us: 10_000, miss_threshold: 1}],
               slaves: [
                 %SlaveConfig{
                   name: :sim,
                   driver: Driver,
                   process_data: [out: :main, in: :main],
                   target_state: :op,
                   health_poll_ms: 20
                 }
               ]
             )

    assert :ok = EtherCAT.await_operational(2_000)
    assert :ok = Simulator.inject_fault(simulator, {:disconnect, :sim})

    assert_eventually(fn ->
      assert :recovering = EtherCAT.state()
    end)

    assert :ok = Simulator.clear_faults(simulator)

    assert_eventually(
      fn ->
        assert :operational = EtherCAT.state()
        assert [%{name: :sim, fault: nil}] = EtherCAT.slaves()
      end,
      150
    )

    Process.sleep(100)
    assert :operational = EtherCAT.state()
  end

  @tag devices: [Slave.digital_io(name: :sim_a), Slave.digital_io(name: :sim_b)]
  test "disconnecting one slave in a shared domain recovers cleanly after reconnect",
       %{simulator: simulator, port: port, devices: devices} do
    assert :ok =
             EtherCAT.start(
               transport: :udp,
               bind_ip: @master_ip,
               host: @simulator_ip,
               port: port,
               dc: nil,
               scan_stable_ms: 20,
               scan_poll_ms: 10,
               frame_timeout_ms: 2,
               domains: [%DomainConfig{id: :main, cycle_time_us: 10_000, miss_threshold: 1}],
               slaves:
                 Enum.map(devices, fn device ->
                   %SlaveConfig{
                     name: device.name,
                     driver: Driver,
                     process_data: [out: :main, in: :main],
                     target_state: :op,
                     health_poll_ms: 20
                   }
                 end)
             )

    assert :ok = EtherCAT.await_operational(2_000)

    assert :ok = EtherCAT.write_output(:sim_a, :out, 1)
    assert :ok = EtherCAT.write_output(:sim_b, :out, 2)

    assert_eventually(fn ->
      assert {:ok, {1, updated_a}} = EtherCAT.read_input(:sim_a, :in)
      assert {:ok, {2, updated_b}} = EtherCAT.read_input(:sim_b, :in)
      assert is_integer(updated_a)
      assert is_integer(updated_b)
    end)

    assert :ok = Simulator.inject_fault(simulator, {:disconnect, :sim_b})

    assert_eventually(fn ->
      assert :recovering = EtherCAT.state()
    end)

    assert :ok = Simulator.clear_faults(simulator)

    assert_eventually(
      fn ->
        assert :operational = EtherCAT.state()

        assert [
                 %{name: :sim_a, fault: nil},
                 %{name: :sim_b, fault: nil}
               ] = EtherCAT.slaves()

        assert {:ok, {1, updated_a}} = EtherCAT.read_input(:sim_a, :in)
        assert {:ok, {2, updated_b}} = EtherCAT.read_input(:sim_b, :in)
        assert is_integer(updated_a)
        assert is_integer(updated_b)
      end,
      150
    )

    Process.sleep(100)
    assert :operational = EtherCAT.state()
  end

  @tag devices: [Slave.digital_io(name: :out_card), Slave.digital_io(name: :in_card)]
  test "connects one slave output to another slave input through the simulator wiring API",
       %{simulator: simulator, port: port} do
    assert :ok =
             EtherCAT.start(
               transport: :udp,
               bind_ip: @master_ip,
               host: @simulator_ip,
               port: port,
               dc: nil,
               scan_stable_ms: 20,
               scan_poll_ms: 10,
               frame_timeout_ms: 2,
               domains: [%DomainConfig{id: :main, cycle_time_us: 10_000}],
               slaves: [
                 %SlaveConfig{
                   name: :out_card,
                   driver: Driver,
                   process_data: [out: :main, in: :main],
                   target_state: :op
                 },
                 %SlaveConfig{
                   name: :in_card,
                   driver: Driver,
                   process_data: [out: :main, in: :main],
                   target_state: :op
                 }
               ]
             )

    assert :ok = EtherCAT.await_operational(2_000)
    assert :ok = Slave.connect(simulator, {:out_card, :out}, {:in_card, :in})

    assert {:ok, [%{source: {:out_card, :out}, target: {:in_card, :in}}]} =
             Slave.connections(simulator)

    assert :ok = EtherCAT.write_output(:out_card, :out, 1)

    assert_eventually(fn ->
      assert {:ok, {1, _}} = EtherCAT.read_input(:in_card, :in)
      assert {:ok, 1} = Slave.get_value(simulator, :in_card, :in)
    end)

    assert :ok = Slave.disconnect(simulator, {:out_card, :out}, {:in_card, :in})
    assert {:ok, []} = Slave.connections(simulator)
    assert :ok = EtherCAT.write_output(:out_card, :out, 0)

    assert_eventually(fn ->
      assert {:ok, 1} = Slave.get_value(simulator, :in_card, :in)
    end)
  end

  defp slave_configs(devices) do
    Enum.map(devices, fn device ->
      %SlaveConfig{
        name: device.name,
        driver: Driver,
        process_data: [out: :main, in: :main],
        target_state: :op
      }
    end)
  end
end
