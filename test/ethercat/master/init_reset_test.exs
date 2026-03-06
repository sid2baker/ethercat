defmodule EtherCAT.Master.InitResetTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Bus.Transaction
  alias EtherCAT.Master.InitReset

  test "builds the default-reset broadcast transaction in SOEM-style order" do
    datagrams = InitReset.transaction() |> Transaction.datagrams()

    assert Enum.map(datagrams, & &1.cmd) == [8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8]

    assert Enum.map(datagrams, & &1.address) == [
             <<0::16-little, 0x0101::16-little>>,
             <<0::16-little, 0x0200::16-little>>,
             <<0::16-little, 0x0300::16-little>>,
             <<0::16-little, 0x0600::16-little>>,
             <<0::16-little, 0x0800::16-little>>,
             <<0::16-little, 0x0981::16-little>>,
             <<0::16-little, 0x0910::16-little>>,
             <<0::16-little, 0x0930::16-little>>,
             <<0::16-little, 0x0934::16-little>>,
             <<0::16-little, 0x0103::16-little>>,
             <<0::16-little, 0x0120::16-little>>,
             <<0::16-little, 0x0500::16-little>>,
             <<0::16-little, 0x0500::16-little>>
           ]

    assert Enum.map(datagrams, &byte_size(&1.data)) == [1, 2, 8, 48, 32, 1, 4, 2, 2, 1, 2, 1, 1]
  end

  test "accepts partial WKC replies for optional DC reset datagrams" do
    replies = [
      %{wkc: 4},
      %{wkc: 4},
      %{wkc: 4},
      %{wkc: 4},
      %{wkc: 4},
      %{wkc: 1},
      %{wkc: 1},
      %{wkc: 1},
      %{wkc: 1},
      %{wkc: 4},
      %{wkc: 4},
      %{wkc: 4},
      %{wkc: 4}
    ]

    assert :ok = InitReset.validate_results(replies, 4)
  end

  test "rejects required reset datagrams that do not hit all slaves" do
    replies = [
      %{wkc: 4},
      %{wkc: 4},
      %{wkc: 4},
      %{wkc: 3},
      %{wkc: 4},
      %{wkc: 1},
      %{wkc: 1},
      %{wkc: 1},
      %{wkc: 1},
      %{wkc: 4},
      %{wkc: 4},
      %{wkc: 4},
      %{wkc: 4}
    ]

    assert {:error, [4, 4, 4, 3, 4, 1, 1, 1, 1, 4, 4, 4, 4], 4} =
             InitReset.validate_results(replies, 4)
  end

  test "accepts partial init-ack broadcast replies for later per-station verification" do
    assert {:partial, 3, 4} = InitReset.validate_init_ack_reply([%{wkc: 3}], 4)
  end

  test "rejects invalid init-ack broadcast replies" do
    assert {:error, {:unexpected_wkc, 0, 4}} =
             InitReset.validate_init_ack_reply([%{wkc: 0}], 4)

    assert {:error, {:unexpected_wkc, 5, 4}} =
             InitReset.validate_init_ack_reply([%{wkc: 5}], 4)
  end
end
