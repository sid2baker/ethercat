defmodule EtherCAT.Integration.Simulator.SplitDomainEL3202ReconnectPreopTimeoutTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Integration.Expect
  alias EtherCAT.Integration.Scenario
  alias EtherCAT.IntegrationSupport.{Hardware, SimulatorRing}
  alias EtherCAT.Simulator.Fault
  alias EtherCAT.Simulator.Slave, as: SimSlave

  @disconnect_steps 30
  @rtd_failure {:mailbox_config_failed, 0x8010, 0x19, :response_timeout}
  @channel1_reading %{
    ohms: 119.375,
    overrange: false,
    underrange: false,
    error: false,
    invalid: false,
    toggle: 0
  }
  @channel2_reading %{
    ohms: 99.3125,
    overrange: false,
    underrange: false,
    error: false,
    invalid: false,
    toggle: 1
  }

  setup do
    on_exit(fn -> SimulatorRing.stop_all!() end)

    SimulatorRing.boot_operational!(
      ring: :hardware,
      start_opts: [domains: split_domains(), slaves: split_domain_slaves()]
    )

    :ok
  end

  test "split-domain EL3202 reconnect PREOP timeout keeps the digital loopback domain healthy" do
    Scenario.new()
    |> Scenario.trace()
    |> Scenario.act("seed EL3202 RTD samples", fn _ctx ->
      assert :ok = SimSlave.set_value(:rtd, :channel1, rtd_sample(@channel1_reading))
      assert :ok = SimSlave.set_value(:rtd, :channel2, rtd_sample(@channel2_reading))
    end)
    |> Scenario.act(
      "baseline split-domain RTD decode and digital loopback are healthy",
      fn _ctx ->
        Expect.eventually(
          fn ->
            Expect.master_state(:operational)
            Expect.domain(:main, cycle_health: :healthy)
            Expect.domain(:rtd, cycle_health: :healthy)
            assert {:ok, <<8, 0>>} = EtherCAT.upload_sdo(:rtd, 0x8000, 0x19)
            assert {:ok, <<8, 0>>} = EtherCAT.upload_sdo(:rtd, 0x8010, 0x19)
            assert_rtd_reading(:channel1, @channel1_reading)
            assert_rtd_reading(:channel2, @channel2_reading)
          end,
          attempts: 160,
          label: "baseline split-domain RTD decode and digital loopback are healthy"
        )
      end
    )
    |> Scenario.inject_fault(
      Fault.script(List.duplicate(Fault.disconnect(:rtd), @disconnect_steps))
    )
    |> Scenario.inject_fault(
      Fault.script([
        Fault.wait_for(Fault.mailbox_step(:rtd, :download_init, 1)),
        Fault.mailbox_protocol_fault(:rtd, 0x8010, 0x19, :download_init, :drop_response)
      ])
    )
    |> Scenario.act(
      "RTD reconnect PREOP timeout is retained without degrading the digital loopback domain",
      fn _ctx ->
        Expect.eventually(
          fn ->
            Expect.slave_fault(:rtd, {:preop, {:preop_configuration_failed, @rtd_failure}})
            Expect.slave(:rtd, al_state: :preop, configuration_error: @rtd_failure)
            Expect.domain(:main, cycle_health: :healthy)

            assert :ok = EtherCAT.write_output(:outputs, :ch1, 1)
            assert {:ok, {1, updated_at_us}} = EtherCAT.read_input(:inputs, :ch1)
            assert is_integer(updated_at_us)
            Expect.signal(:outputs, :ch1, value: true)
          end,
          attempts: 260,
          label:
            "RTD reconnect PREOP timeout is retained without degrading the digital loopback domain"
        )

        Expect.stays(fn ->
          Expect.domain(:main, cycle_health: :healthy)
          assert {:ok, {1, updated_at_us}} = EtherCAT.read_input(:inputs, :ch1)
          assert is_integer(updated_at_us)
        end)
      end
    )
    |> Scenario.act("the split RTD domain eventually self-heals too", fn _ctx ->
      Expect.eventually(
        fn ->
          Expect.master_state(:operational)
          Expect.domain(:main, cycle_health: :healthy)
          Expect.domain(:rtd, cycle_health: :healthy)
          Expect.slave_fault(:rtd, nil)
          Expect.slave(:rtd, al_state: :op, configuration_error: nil)
          assert {:ok, <<8, 0>>} = EtherCAT.upload_sdo(:rtd, 0x8000, 0x19)
          assert {:ok, <<8, 0>>} = EtherCAT.upload_sdo(:rtd, 0x8010, 0x19)
          assert_rtd_reading(:channel1, @channel1_reading)
          assert_rtd_reading(:channel2, @channel2_reading)
          Expect.simulator_queue_empty()
        end,
        attempts: 420,
        label: "the split RTD domain eventually self-heals too"
      )
    end)
    |> Scenario.run()
  end

  defp split_domains do
    [
      Hardware.main_domain(id: :main, cycle_time_us: 10_000),
      Hardware.main_domain(id: :rtd, cycle_time_us: 10_000)
    ]
  end

  defp split_domain_slaves do
    [
      Hardware.coupler(),
      Hardware.inputs(),
      Hardware.outputs(health_poll_ms: 20),
      Hardware.rtd(process_data: {:all, :rtd}, health_poll_ms: 20)
    ]
  end

  defp assert_rtd_reading(signal_name, expected_reading) do
    assert {:ok, {reading, updated_at_us}} = EtherCAT.read_input(:rtd, signal_name)
    assert reading == expected_reading
    assert is_integer(updated_at_us)
  end

  defp rtd_sample(%{ohms: ohms} = reading) do
    value = trunc(ohms * 16)
    error = truthy_bit(reading[:error])
    overrange = truthy_bit(reading[:overrange])
    underrange = truthy_bit(reading[:underrange])
    toggle = reading[:toggle] || 0
    invalid = truthy_bit(reading[:invalid])

    <<
      0::1,
      error::1,
      0::2,
      0::2,
      overrange::1,
      underrange::1,
      toggle::1,
      invalid::1,
      0::6,
      value::16-little
    >>
  end

  defp truthy_bit(true), do: 1
  defp truthy_bit(_other), do: 0
end
