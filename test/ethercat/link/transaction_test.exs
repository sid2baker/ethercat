defmodule EtherCAT.Link.TransactionTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Link.Transaction
  alias EtherCAT.Link.Datagram

  describe "new/0" do
    test "returns empty transaction" do
      tx = Transaction.new()
      assert %Transaction{datagrams: []} = tx
    end
  end

  describe "builder functions" do
    test "fprd appends one datagram with correct cmd" do
      tx = Transaction.new() |> Transaction.fprd(0x1001, 0x0130, 2)
      assert [%Datagram{cmd: 4, data: <<0, 0>>}] = tx.datagrams
    end

    test "fpwr appends one datagram with correct cmd" do
      tx = Transaction.new() |> Transaction.fpwr(0x1001, 0x0130, <<0x08, 0x00>>)
      assert [%Datagram{cmd: 5, data: <<0x08, 0x00>>}] = tx.datagrams
    end

    test "fprw appends one datagram with correct cmd" do
      tx = Transaction.new() |> Transaction.fprw(0x1001, 0x0130, <<0x01, 0x02>>)
      assert [%Datagram{cmd: 6, data: <<0x01, 0x02>>}] = tx.datagrams
    end

    test "frmw appends one datagram with correct cmd" do
      tx = Transaction.new() |> Transaction.frmw(0x1001, 0x0130, <<0, 0>>)
      assert [%Datagram{cmd: 14, data: <<0, 0>>}] = tx.datagrams
    end

    test "aprd appends one datagram with correct cmd" do
      tx = Transaction.new() |> Transaction.aprd(0, 0x0130, 2)
      assert [%Datagram{cmd: 1, data: <<0, 0>>}] = tx.datagrams
    end

    test "apwr appends one datagram with correct cmd" do
      tx = Transaction.new() |> Transaction.apwr(0, 0x0010, <<0x00, 0x10>>)
      assert [%Datagram{cmd: 2, data: <<0x00, 0x10>>}] = tx.datagrams
    end

    test "aprw appends one datagram with correct cmd" do
      tx = Transaction.new() |> Transaction.aprw(0, 0x0130, <<0, 0>>)
      assert [%Datagram{cmd: 3, data: <<0, 0>>}] = tx.datagrams
    end

    test "armw appends one datagram with correct cmd" do
      tx = Transaction.new() |> Transaction.armw(0, 0x0900, <<0, 0, 0, 0, 0, 0, 0, 0>>)
      assert [%Datagram{cmd: 13}] = tx.datagrams
    end

    test "brd appends one datagram with correct cmd" do
      tx = Transaction.new() |> Transaction.brd(0x0000, 1)
      assert [%Datagram{cmd: 7, data: <<0>>}] = tx.datagrams
    end

    test "bwr appends one datagram with correct cmd" do
      tx = Transaction.new() |> Transaction.bwr(0x0000, <<0xFF>>)
      assert [%Datagram{cmd: 8, data: <<0xFF>>}] = tx.datagrams
    end

    test "brw appends one datagram with correct cmd" do
      tx = Transaction.new() |> Transaction.brw(0x0000, <<0, 0>>)
      assert [%Datagram{cmd: 9, data: <<0, 0>>}] = tx.datagrams
    end

    test "lrd appends one datagram with correct cmd" do
      tx = Transaction.new() |> Transaction.lrd(0x0000, 4)
      assert [%Datagram{cmd: 10, data: <<0, 0, 0, 0>>}] = tx.datagrams
    end

    test "lwr appends one datagram with correct cmd" do
      tx = Transaction.new() |> Transaction.lwr(0x0000, <<0xFF, 0xFF>>)
      assert [%Datagram{cmd: 11, data: <<0xFF, 0xFF>>}] = tx.datagrams
    end

    test "lrw appends one datagram with correct cmd" do
      tx = Transaction.new() |> Transaction.lrw(0x0000, <<0, 0, 0, 0>>)
      assert [%Datagram{cmd: 12, data: <<0, 0, 0, 0>>}] = tx.datagrams
    end
  end

  describe "ordering" do
    test "preserves insertion order" do
      tx =
        Transaction.new()
        |> Transaction.fprd(0x1001, 0x0130, 2)
        |> Transaction.brd(0x0000, 1)
        |> Transaction.lrw(0x0000, <<0, 0, 0, 0>>)

      assert [%Datagram{cmd: 4}, %Datagram{cmd: 7}, %Datagram{cmd: 12}] = tx.datagrams
    end

    test "multiple commands of the same type are distinct" do
      tx =
        Transaction.new()
        |> Transaction.fprd(0x1000, 0x0130, 2)
        |> Transaction.fprd(0x1001, 0x0130, 2)

      assert [%Datagram{cmd: 4} = d1, %Datagram{cmd: 4} = d2] = tx.datagrams
      # Different station addresses produce different address fields
      assert d1.address != d2.address
    end
  end
end
