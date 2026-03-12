defmodule EtherCAT.CaptureTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Capture
  alias EtherCAT.IntegrationSupport.SegmentedMailboxRing
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Slave.Definition

  @master_ip {127, 0, 0, 1}
  @simulator_ip {127, 0, 0, 2}

  setup do
    _ = EtherCAT.stop()
    _ = Simulator.stop()

    on_exit(fn ->
      _ = EtherCAT.stop()
      _ = Simulator.stop()
    end)

    :ok
  end

  test "captures a dynamically discovered mailbox slave and selected sdos" do
    boot_dynamic_capture_ring!()

    assert EtherCAT.state() == :preop_ready

    assert {:ok, slaves} = Capture.list_slaves()
    assert Enum.any?(slaves, &(&1.name == :slave_3 and &1.coe))

    assert {:ok, capture} =
             Capture.capture(:slave_3, sdos: [{0x2000, 0x01}, {0x2001, 0x01}])

    assert capture.format == 1
    assert capture.slave.identity.product_code == 0x0000_1602
    assert capture.sii.mailbox_config.recv_size > 0
    assert capture.sii.pdo_configs == []

    assert [
             %{index: 0x2000, subindex: 0x01, data: <<0x34, 0x12>>},
             %{index: 0x2001, subindex: 0x01, data: <<"hello-sim", 0, 0, 0>>}
           ] = capture.sdos

    opts = Capture.definition_options(capture)
    assert Keyword.fetch!(opts, :profile) == :mailbox_device
    assert Keyword.fetch!(opts, :pdo_entries) == []
    assert Map.has_key?(Keyword.fetch!(opts, :objects), {0x2000, 0x01})
  end

  test "writes a capture file and loads it back" do
    boot_dynamic_capture_ring!()
    tmp_dir = tmp_dir!()
    path = Path.join(tmp_dir, "mailbox_capture.exs")

    assert {:ok, written_path} =
             Capture.write_capture(
               :slave_3,
               path: path,
               sdos: [{0x2000, 0x02}],
               force: true
             )

    assert written_path == Path.expand(path)
    assert File.exists?(written_path)

    assert {:ok, capture} = Capture.load_capture(written_path)
    assert capture.sdos == [%{index: 0x2000, subindex: 0x02, data: <<0>>}]
  end

  test "generates a simulator scaffold module from an io slave capture" do
    boot_dynamic_capture_ring!()
    tmp_dir = tmp_dir!()
    capture_path = Path.join([tmp_dir, "captures", "captured_inputs.exs"])
    module_path = Path.join([tmp_dir, "scaffolds", "generated_inputs_simulator.ex"])

    module =
      Module.concat([
        EtherCAT,
        CaptureGenerated,
        "Inputs#{System.unique_integer([:positive])}",
        Simulator
      ])

    assert {:ok, %{capture_path: written_capture, module_path: written_module}} =
             Capture.gen_simulator(
               :slave_1,
               module: module,
               capture_path: capture_path,
               module_path: module_path,
               force: true
             )

    assert written_capture == Path.expand(capture_path)
    assert written_module == Path.expand(module_path)
    assert File.exists?(written_capture)
    assert File.exists?(written_module)
    refute File.read!(written_module) =~ written_capture

    assert [{^module, _bytecode}] = Code.compile_file(written_module)

    opts = module.definition_options(%{})
    assert Keyword.fetch!(opts, :profile) == :coupler
    assert Keyword.fetch!(opts, :vendor_id) == 0x0000_0002

    assert Enum.any?(
             Keyword.fetch!(opts, :pdo_entries),
             &(&1.index == 0x1A00 and &1.sm_index == 3)
           )

    assert Keyword.fetch!(opts, :objects) == %{}

    definition =
      opts
      |> Keyword.delete(:profile)
      |> then(&Definition.build(:coupler, &1))

    assert definition.mailbox_config.recv_size == 0
    assert Map.has_key?(definition.signals, :pdo_0x1a00)
  end

  test "generates a best-effort integration driver scaffold for a digital input slave" do
    boot_dynamic_capture_ring!()
    tmp_dir = tmp_dir!()
    capture_path = Path.join([tmp_dir, "captures", "captured_driver_inputs.exs"])
    driver_path = Path.join(tmp_dir, "generated_inputs_driver.ex")

    module =
      Module.concat([
        EtherCAT,
        IntegrationSupport,
        Drivers,
        "GeneratedEL1809#{System.unique_integer([:positive])}"
      ])

    simulator_module = Module.concat(module, "Simulator")

    assert {:ok, %{capture_path: written_capture, driver_path: written_driver}} =
             Capture.gen_driver(
               :slave_1,
               module: module,
               capture_path: capture_path,
               driver_path: driver_path,
               force: true
             )

    assert written_capture == Path.expand(capture_path)
    assert written_driver == Path.expand(driver_path)
    assert File.exists?(written_capture)
    assert File.exists?(written_driver)

    compiled_modules =
      written_driver
      |> Code.compile_file()
      |> Enum.map(&elem(&1, 0))

    assert module in compiled_modules
    assert simulator_module in compiled_modules
    assert %{vendor_id: 0x0000_0002, product_code: 0x0711_3052} = module.identity()
    assert signal_model = module.signal_model(%{})
    assert length(signal_model) == 16
    assert hd(signal_model) == {:ch1, 0x1A00}
    assert module.encode_signal(:ch1, %{}, :ignored) == <<>>
    assert module.decode_signal(:ch1, %{}, <<1>>) == 1

    opts = simulator_module.definition_options(%{})
    assert Keyword.fetch!(opts, :profile) == :digital_io
    assert Keyword.fetch!(opts, :direction) == :input
    assert Keyword.fetch!(opts, :channels) == 16
    assert Keyword.fetch!(opts, :input_names) |> hd() == :ch1
  end

  test "generates a capture-backed integration driver scaffold for a mailbox slave" do
    boot_dynamic_capture_ring!()
    tmp_dir = tmp_dir!()
    capture_path = Path.join([tmp_dir, "captures", "captured_driver_mailbox.exs"])
    driver_path = Path.join([tmp_dir, "drivers", "generated_mailbox_driver.ex"])

    module =
      Module.concat([
        EtherCAT,
        IntegrationSupport,
        Drivers,
        "GeneratedMailbox#{System.unique_integer([:positive])}"
      ])

    simulator_module = Module.concat(module, "Simulator")

    assert {:ok, %{capture_path: written_capture, driver_path: written_driver}} =
             Capture.gen_driver(
               :slave_3,
               module: module,
               capture_path: capture_path,
               driver_path: driver_path,
               force: true
             )

    assert written_capture == Path.expand(capture_path)
    assert written_driver == Path.expand(driver_path)
    assert File.exists?(written_capture)
    assert File.exists?(written_driver)
    refute File.read!(written_driver) =~ written_capture

    compiled_modules =
      written_driver
      |> Code.compile_file()
      |> Enum.map(&elem(&1, 0))

    assert module in compiled_modules
    assert simulator_module in compiled_modules
    assert %{vendor_id: 0x0000_0ACE, product_code: 0x0000_1602} = module.identity()
    assert module.signal_model(%{}) == []
    assert module.encode_signal(:blob, %{}, :ignored) == <<>>
    assert module.decode_signal(:blob, %{}, <<1, 2>>) == nil

    opts = simulator_module.definition_options(%{})
    assert Keyword.fetch!(opts, :profile) == :mailbox_device
    assert Keyword.fetch!(opts, :mailbox_config).recv_size > 0
  end

  defp boot_dynamic_capture_ring! do
    {:ok, _supervisor} =
      Simulator.start(devices: SegmentedMailboxRing.devices(), udp: [ip: @simulator_ip, port: 0])

    {:ok, %{udp: %{port: port}}} = Simulator.info()
    Process.sleep(20)

    assert :ok =
             EtherCAT.start(
               transport: :udp,
               bind_ip: @master_ip,
               host: @simulator_ip,
               port: port,
               dc: nil,
               domains: [],
               slaves: [],
               scan_stable_ms: 20,
               scan_poll_ms: 10,
               frame_timeout_ms: 20
             )

    assert :ok = EtherCAT.await_running(2_000)
    :ok
  end

  defp tmp_dir! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ethercat_capture_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end
end
