defmodule EtherCAT.Bus.Circuit.SingleTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Bus.{Frame, Transaction}
  alias EtherCAT.Bus.Circuit.{Exchange, Single}

  defmodule FakeTransport do
    @behaviour EtherCAT.Bus.Transport

    import Kernel, except: [send: 2]

    defstruct [:fail_send, :interface, :raw, :test_pid]

    @impl true
    def open(opts) do
      {:ok,
       %__MODULE__{
         fail_send: Keyword.get(opts, :fail_send),
         interface: Keyword.fetch!(opts, :interface),
         raw: make_ref(),
         test_pid: Keyword.fetch!(opts, :test_pid)
       }}
    end

    @impl true
    def send(%__MODULE__{fail_send: reason}, _payload) when not is_nil(reason),
      do: {:error, reason}

    def send(%__MODULE__{raw: raw, test_pid: test_pid}, payload) do
      tx_at = System.monotonic_time()
      Kernel.send(test_pid, {:transport_sent, raw, payload, tx_at})
      {:ok, tx_at}
    end

    @impl true
    def set_active_once(%__MODULE__{raw: raw, test_pid: test_pid}) do
      Kernel.send(test_pid, {:transport_armed, raw})
      :ok
    end

    @impl true
    def rearm(%__MODULE__{raw: raw, test_pid: test_pid}) do
      Kernel.send(test_pid, {:transport_rearmed, raw})
      :ok
    end

    @impl true
    def match(%__MODULE__{raw: raw}, {:fake_transport_payload, raw, payload, rx_at}),
      do: {:ok, payload, rx_at, nil}

    def match(%__MODULE__{}, _msg), do: :ignore

    @impl true
    def src_mac(%__MODULE__{}), do: nil

    @impl true
    def drain(%__MODULE__{raw: raw, test_pid: test_pid}) do
      Kernel.send(test_pid, {:transport_drained, raw})
      :ok
    end

    @impl true
    def close(%__MODULE__{raw: nil} = transport), do: transport

    def close(%__MODULE__{raw: raw, test_pid: test_pid} = transport) do
      Kernel.send(test_pid, {:transport_closed, raw})
      %{transport | raw: nil}
    end

    @impl true
    def open?(%__MODULE__{raw: nil}), do: false
    def open?(%__MODULE__{}), do: true

    @impl true
    def name(%__MODULE__{interface: interface}), do: interface

    @impl true
    def interface(%__MODULE__{interface: interface}), do: interface
  end

  test "begin_exchange arms the transport and sends the encoded payload" do
    {:ok, circuit} = start_circuit()
    exchange = exchange_for(Transaction.fprd(0x1000, {0x0130, 2}), 7)

    assert {:ok, %Single{} = circuit, %Exchange{} = returned_exchange} =
             Single.begin_exchange(circuit, exchange)

    assert_receive {:transport_armed, raw}
    assert_receive {:transport_sent, ^raw, payload, tx_at}

    assert payload == exchange.payload
    assert returned_exchange.payload == payload
    assert returned_exchange.tx_at == tx_at
    assert returned_exchange.pending != nil
    assert Single.info(circuit).port.usable?
  end

  test "observe completes with a single-port observation on matching datagrams" do
    {:ok, circuit} = start_circuit()
    exchange = exchange_for(Transaction.fprd(0x1000, {0x0130, 2}), 9)
    {:ok, circuit, exchange} = Single.begin_exchange(circuit, exchange)

    assert_receive {:transport_armed, raw}
    assert_receive {:transport_sent, ^raw, _payload, _tx_at}

    [response] =
      Enum.map(exchange.datagrams, fn dg ->
        %{dg | data: <<0x34, 0x12>>, wkc: 1}
      end)

    {:ok, payload} = Frame.encode([response])
    rx_at = System.monotonic_time()

    assert {:complete, %Single{} = circuit, observation} =
             Single.observe(circuit, {:fake_transport_payload, raw, payload, rx_at}, exchange)

    assert observation.status == :ok
    assert observation.path_shape == :single
    assert observation.payload == payload
    assert observation.datagrams == [response]
    assert observation.completed_at == rx_at
    assert observation.primary.sent? == true
    assert observation.primary.send_result == :ok
    assert observation.primary.rx_kind == :processed
    assert observation.primary.rx_payload == payload
    assert observation.primary.rx_at == rx_at
    assert Single.info(circuit).port.usable?
  end

  test "observe rearms on idx mismatch and keeps waiting" do
    {:ok, circuit} = start_circuit()
    exchange = exchange_for(Transaction.fprd(0x1000, {0x0130, 2}), 11)
    {:ok, circuit, exchange} = Single.begin_exchange(circuit, exchange)

    assert_receive {:transport_armed, raw}
    assert_receive {:transport_sent, ^raw, _payload, _tx_at}

    mismatched =
      Enum.map(exchange.datagrams, fn dg ->
        %{dg | idx: dg.idx + 1, data: <<0x78, 0x56>>, wkc: 1}
      end)

    {:ok, payload} = Frame.encode(mismatched)

    assert {:continue, %Single{} = circuit, %Exchange{} = updated_exchange} =
             Single.observe(
               circuit,
               {:fake_transport_payload, raw, payload, System.monotonic_time()},
               exchange
             )

    assert_receive {:transport_rearmed, ^raw}
    assert updated_exchange.idx == exchange.idx
    assert updated_exchange.payload == exchange.payload
    assert updated_exchange.datagrams == exchange.datagrams
    assert updated_exchange.awaiting == exchange.awaiting
    assert updated_exchange.tx_class == exchange.tx_class
    assert updated_exchange.tx_at >= exchange.tx_at
    assert Single.info(circuit).port.usable?
  end

  test "observe rearms when a response reuses the idx but not the datagram shape" do
    {:ok, circuit} = start_circuit()
    exchange = exchange_for(Transaction.fprd(0x1000, {0x0130, 2}), 12)
    {:ok, circuit, exchange} = Single.begin_exchange(circuit, exchange)

    assert_receive {:transport_armed, raw}
    assert_receive {:transport_sent, ^raw, _payload, _tx_at}

    # Change cmd (FPRD=4 → BRD=7) — same idx but different command shape
    mismatched =
      Enum.map(exchange.datagrams, fn dg ->
        %{dg | cmd: 7, data: <<0x78, 0x56>>, wkc: 1}
      end)

    {:ok, payload} = Frame.encode(mismatched)

    assert {:continue, %Single{}, %Exchange{}} =
             Single.observe(
               circuit,
               {:fake_transport_payload, raw, payload, System.monotonic_time()},
               exchange
             )

    assert_receive {:transport_rearmed, ^raw}
  end

  test "observe rearms on undecodable payloads and keeps waiting" do
    {:ok, circuit} = start_circuit()
    exchange = exchange_for(Transaction.fprd(0x1000, {0x0130, 2}), 13)
    {:ok, circuit, exchange} = Single.begin_exchange(circuit, exchange)

    assert_receive {:transport_armed, raw}
    assert_receive {:transport_sent, ^raw, _payload, _tx_at}

    assert {:continue, %Single{}, %Exchange{}} =
             Single.observe(
               circuit,
               {:fake_transport_payload, raw, <<1, 2, 3>>, System.monotonic_time()},
               exchange
             )

    assert_receive {:transport_rearmed, ^raw}
  end

  test "timeout completes with no valid return" do
    {:ok, circuit} = start_circuit()
    exchange = exchange_for(Transaction.fprd(0x1000, {0x0130, 2}), 15)
    {:ok, circuit, exchange} = Single.begin_exchange(circuit, exchange)

    assert_receive {:transport_armed, _raw}
    assert_receive {:transport_sent, _, _, _}

    assert {:complete, %Single{}, observation} = Single.timeout(circuit, exchange)

    assert observation.status == :timeout
    assert observation.path_shape == :no_valid_return
    assert observation.datagrams == nil
    assert observation.primary.sent? == true
    assert observation.primary.rx_kind == :none
  end

  test "begin_exchange closes the port on transport send error" do
    {:ok, circuit} = start_circuit(fail_send: :enetdown)
    exchange = exchange_for(Transaction.fprd(0x1000, {0x0130, 2}), 17)

    assert {:error, %Single{} = circuit, observation, :enetdown} =
             Single.begin_exchange(circuit, exchange)

    assert_receive {:transport_armed, raw}
    assert_receive {:transport_closed, ^raw}
    assert observation.status == :transport_error
    assert observation.primary.send_result == {:error, :enetdown}
    refute Single.info(circuit).port.usable?
  end

  defp start_circuit(opts \\ []) do
    Single.open(
      Keyword.merge(
        [
          interface: "eth0",
          test_pid: self(),
          transport_mod: FakeTransport
        ],
        opts
      )
    )
  end

  defp exchange_for(tx, idx) do
    datagrams =
      tx
      |> Transaction.datagrams()
      |> Enum.map(&%{&1 | idx: idx})

    {:ok, payload} = Frame.encode(datagrams)
    Exchange.new(idx, payload, datagrams, [], :reliable, System.monotonic_time())
  end
end
