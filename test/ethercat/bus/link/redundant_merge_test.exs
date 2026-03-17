defmodule EtherCAT.Bus.Link.RedundantMergeTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Bus.{Frame, Transaction}
  alias EtherCAT.Bus.Link.RedundantMerge

  test "interprets healthy redundant replies as passthrough plus processed" do
    sent = stamped_datagrams(Transaction.fprd(0x1000, {0x0130, 2}), 1)
    primary = sent
    secondary = Enum.map(sent, &%{&1 | data: <<0x34, 0x12>>, wkc: 1})

    assert %{
             status: :ok,
             redundancy: :full,
             path_shape: :full_redundancy,
             primary_rx_kind: :passthrough,
             secondary_rx_kind: :processed,
             datagrams: ^secondary
           } = RedundantMerge.interpret(sent, primary, secondary)
  end

  test "interprets complementary partial logical replies and merges them" do
    sent = stamped_datagrams(Transaction.lrw({0x0000, <<0xF0, 0xF1, 0xF2, 0xF3>>}), 3)
    primary = Enum.map(sent, &%{&1 | data: <<0x10, 0x11, 0xF2, 0xF3>>, wkc: 2})
    secondary = Enum.map(sent, &%{&1 | data: <<0xF0, 0xF1, 0x12, 0x13>>, wkc: 2})

    assert %{
             status: :ok,
             redundancy: :degraded,
             path_shape: :complementary_partials,
             primary_rx_kind: :partial,
             secondary_rx_kind: :partial,
             datagrams: [%{data: <<0x10, 0x11, 0x12, 0x13>>, wkc: 4}]
           } = RedundantMerge.interpret(sent, primary, secondary)
  end

  test "interprets one-sided passthrough as partial degraded" do
    sent = stamped_datagrams(Transaction.fprd(0x1000, {0x0130, 2}), 5)

    assert %{
             status: :partial,
             redundancy: :degraded,
             path_shape: :primary_only,
             primary_rx_kind: :passthrough,
             secondary_rx_kind: :none,
             datagrams: ^sent
           } = RedundantMerge.interpret(sent, sent, nil)
  end

  defp stamped_datagrams(tx, idx) do
    tx
    |> Transaction.datagrams()
    |> Enum.map(&%{&1 | idx: idx})
    |> then(fn datagrams ->
      {:ok, payload} = Frame.encode(datagrams)
      assert {:ok, ^datagrams} = Frame.decode(payload)
      datagrams
    end)
  end
end
