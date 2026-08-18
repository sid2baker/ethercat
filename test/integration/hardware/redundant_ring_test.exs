defmodule EtherCAT.Integration.Hardware.RedundantRingTest do
  use ExUnit.Case, async: false

  alias EtherCAT.IntegrationSupport.Hardware

  @moduletag :hardware
  @redundant_profiles Hardware.redundant_profiles()

  setup do
    stop_current_session()
    on_exit(fn -> stop_current_session() end)
    :ok
  end

  if @redundant_profiles != [] do
    for profile <- @redundant_profiles do
      test "boots the EK1100 -> EL1809 -> EL2809 ring to operational over #{profile.label}" do
        profile = unquote(Macro.escape(profile))

        assert {:ok, session} = start_ring(profile)
        assert :ok = EtherCAT.await_operational(session, 5_000)
        assert {:ok, :operational} = EtherCAT.state(session)

        assert {:ok, %{link: expected_link}} = EtherCAT.Bus.info(EtherCAT.Bus)

        assert expected_link == Hardware.expected_bus_link(profile)

        assert {:ok, %{station: 0x1000, al_state: :op}} =
                 EtherCAT.Diagnostics.slave_info(session, :coupler)

        assert {:ok, %{station: 0x1001, al_state: :op}} =
                 EtherCAT.Diagnostics.slave_info(session, :inputs)

        assert {:ok, %{station: 0x1002, al_state: :op}} =
                 EtherCAT.Diagnostics.slave_info(session, :outputs)
      end

      test "reads EL1809 inputs and stages EL2809 outputs over #{profile.label}" do
        profile = unquote(Macro.escape(profile))

        assert {:ok, session} = start_ring(profile)
        assert :ok = EtherCAT.await_operational(session, 5_000)

        assert {:ok, %{link: expected_link}} = EtherCAT.Bus.info(EtherCAT.Bus)

        assert expected_link == Hardware.expected_bus_link(profile)

        EtherCAT.Integration.Assertions.assert_eventually(fn ->
          assert {:ok, {value, updated_at_us}} = EtherCAT.Raw.read_input(session, :inputs, :ch1)
          assert is_integer(value)
          assert is_integer(updated_at_us)
        end)

        assert :ok = EtherCAT.Raw.write_output(session, :outputs, :ch1, 1)
        assert :ok = EtherCAT.Raw.write_output(session, :outputs, :ch16, 0)
      end
    end

    defp start_ring(profile) do
      assert {:redundant, _backend} = Keyword.fetch!(Hardware.start_opts(profile), :backend)

      EtherCAT.start(
        Hardware.start_opts(profile) ++
          [
            dc: nil,
            scan_stable_ms: 50,
            scan_poll_ms: 20,
            frame_timeout_ms: 2,
            domains: [Hardware.main_domain()],
            slaves: ring_slave_configs()
          ]
      )
    end

    defp ring_slave_configs do
      Hardware.full_ring(include_rtd: false)
    end
  end

  defp stop_current_session do
    case EtherCAT.Session.current() do
      {:ok, session} -> EtherCAT.stop(session)
      {:error, :not_started} -> :ok
    end
  end
end
