defmodule EtherCAT.Integration.Simulator.SingleRawDelayFaultClearTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Integration.Expect
  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator.Transport.Raw
  alias EtherCAT.Simulator.Transport.Raw.Fault, as: RawFault

  @configured_delay_ms 5
  @transient_delay_ms 15

  setup do
    _endpoint =
      SimulatorRing.start_simulator!(
        transport: :raw,
        raw_endpoint_opts: [
          response_delay_ms: @configured_delay_ms,
          response_delay_from_ingress: :primary
        ]
      )

    on_exit(fn ->
      SimulatorRing.stop_all!()
    end)

    :ok
  end

  @tag :raw_socket
  test "single raw helper preserves configured delay when transient raw delay faults clear" do
    assert_raw_delay(@configured_delay_ms, :primary, nil)

    assert :ok =
             Raw.inject_fault(
               RawFault.delay_response(@transient_delay_ms, from_ingress: :primary)
             )

    assert_raw_delay(
      @transient_delay_ms,
      :primary,
      %{delay_ms: @transient_delay_ms, from_ingress: :primary}
    )

    assert :ok = Raw.clear_faults()

    assert_raw_delay(@configured_delay_ms, :primary, nil)
    Expect.simulator_queue_empty()
  end

  defp assert_raw_delay(expected_delay_ms, expected_from_ingress, expected_fault) do
    assert {:ok,
            %{
              mode: :single,
              primary: %{
                configured_response_delay_ms: @configured_delay_ms,
                configured_response_delay_from_ingress: :primary,
                response_delay_ms: ^expected_delay_ms,
                response_delay_from_ingress: ^expected_from_ingress,
                delay_fault: ^expected_fault
              }
            }} = Raw.info()
  end
end
