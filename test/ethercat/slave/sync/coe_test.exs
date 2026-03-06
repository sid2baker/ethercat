defmodule EtherCAT.Slave.Sync.CoETest do
  use ExUnit.Case, async: true

  alias EtherCAT.Slave.Sync.CoE

  test "steps!/1 builds output and input mailbox writes for sync0 timing" do
    assert [
             {:sdo_download, 0x1C32, 0x01, <<2::16-little>>},
             {:sdo_download, 0x1C32, 0x02, <<1_000_000::32-little>>},
             {:sdo_download, 0x1C33, 0x01, <<2::16-little>>},
             {:sdo_download, 0x1C33, 0x02, <<1_000_000::32-little>>}
           ] =
             CoE.steps!(
               cycle_ns: 1_000_000,
               output: :sync0,
               input: :sync0
             )
  end

  test "input_steps/2 supports SM2 and SM3 event codes distinctly" do
    assert [
             {:sdo_download, 0x1C33, 0x01, <<0x0022::16-little>>},
             {:sdo_download, 0x1C33, 0x02, <<500_000::32-little>>}
           ] = CoE.input_steps({:sm_event, :sm2}, 500_000)

    assert [
             {:sdo_download, 0x1C33, 0x01, <<0x0001::16-little>>},
             {:sdo_download, 0x1C33, 0x02, <<500_000::32-little>>}
           ] = CoE.input_steps({:sm_event, :sm3}, 500_000)
  end

  test "invalid cycle or mode raises argument error" do
    assert_raise ArgumentError, fn ->
      CoE.steps!(cycle_ns: 0, output: :sync0)
    end

    assert_raise ArgumentError, fn ->
      CoE.output_steps(:bad_mode, 1_000_000)
    end

    assert_raise ArgumentError, fn ->
      CoE.input_steps({:sm_event, :sm1}, 1_000_000)
    end
  end
end
