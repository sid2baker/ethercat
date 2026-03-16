defmodule EtherCAT.Integration.Hardware.RingTest do
  use ExUnit.Case, async: false

  alias EtherCAT.IntegrationSupport.Hardware

  @moduletag :hardware
  @single_link_profiles Hardware.single_link_profiles()

  setup do
    _ = EtherCAT.stop()

    on_exit(fn ->
      case EtherCAT.stop() do
        :ok -> :ok
        {:error, :already_stopped} -> :ok
      end
    end)

    :ok
  end

  if @single_link_profiles == [] do
    test "hardware ring transport is configured" do
      flunk(Hardware.single_link_configuration_message())
    end
  end

  if @single_link_profiles != [] do
    for profile <- @single_link_profiles do
      test "boots the EK1100 -> EL1809 -> EL2809 ring to operational over #{profile.label}" do
        profile = unquote(Macro.escape(profile))

        assert :ok = start_ring(profile)
        assert :ok = EtherCAT.await_operational(5_000)
        assert {:ok, :operational} = EtherCAT.state()

        assert {:ok, %{circuit: expected_link}} = EtherCAT.Bus.info(EtherCAT.Bus)

        assert expected_link == Hardware.expected_bus_link(profile)
        assert {:ok, %{station: 0x1000, al_state: :op}} = EtherCAT.slave_info(:coupler)
        assert {:ok, %{station: 0x1001, al_state: :op}} = EtherCAT.slave_info(:inputs)
        assert {:ok, %{station: 0x1002, al_state: :op}} = EtherCAT.slave_info(:outputs)
      end

      test "reads EL1809 inputs and stages EL2809 outputs over #{profile.label}" do
        profile = unquote(Macro.escape(profile))

        assert :ok = start_ring(profile)
        assert :ok = EtherCAT.await_operational(5_000)

        assert {:ok, %{circuit: expected_link}} = EtherCAT.Bus.info(EtherCAT.Bus)

        assert expected_link == Hardware.expected_bus_link(profile)

        EtherCAT.Integration.Assertions.assert_eventually(fn ->
          assert {:ok, {value, updated_at_us}} = EtherCAT.read_input(:inputs, :ch1)
          assert is_integer(value)
          assert is_integer(updated_at_us)
        end)

        assert :ok = EtherCAT.write_output(:outputs, :ch1, 1)
        assert :ok = EtherCAT.write_output(:outputs, :ch16, 0)
      end
    end

    defp start_ring(profile) do
      assert Keyword.get(Hardware.start_opts(profile), :backup_interface) == nil

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
end
