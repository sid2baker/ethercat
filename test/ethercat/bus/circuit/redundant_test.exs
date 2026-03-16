defmodule EtherCAT.Bus.Circuit.RedundantTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias EtherCAT.Bus.{Frame, Transaction}
  alias EtherCAT.Bus.Circuit.{Exchange, Redundant}

  defmodule FakeTransport do
    @behaviour EtherCAT.Bus.Transport

    import Kernel, except: [send: 2]

    defstruct [:fail_open, :fail_send, :interface, :raw, :test_pid]

    @impl true
    def open(opts) do
      interface = Keyword.fetch!(opts, :interface)
      fail_open = Keyword.get(opts, :fail_open, %{})

      case Map.get(fail_open, interface) do
        nil ->
          {:ok,
           %__MODULE__{
             fail_open: fail_open,
             fail_send: Keyword.get(opts, :fail_send, %{}),
             interface: interface,
             raw: make_ref(),
             test_pid: Keyword.fetch!(opts, :test_pid)
           }}

        reason ->
          {:error, reason}
      end
    end

    @impl true
    def send(%__MODULE__{fail_send: fail_send, interface: interface} = transport, payload) do
      case Map.get(fail_send, interface) do
        nil ->
          tx_at = System.monotonic_time()

          Kernel.send(
            transport.test_pid,
            {:transport_sent, interface, transport.raw, payload, tx_at}
          )

          {:ok, tx_at}

        reason ->
          {:error, reason}
      end
    end

    @impl true
    def set_active_once(%__MODULE__{interface: interface, raw: raw, test_pid: test_pid}) do
      Kernel.send(test_pid, {:transport_armed, interface, raw})
      :ok
    end

    @impl true
    def rearm(%__MODULE__{interface: interface, raw: raw, test_pid: test_pid}) do
      Kernel.send(test_pid, {:transport_rearmed, interface, raw})
      :ok
    end

    @impl true
    def match(%__MODULE__{raw: raw}, {:fake_transport_payload, raw, payload, rx_at}),
      do: {:ok, payload, rx_at, nil}

    def match(%__MODULE__{}, _msg), do: :ignore

    @impl true
    def src_mac(%__MODULE__{interface: interface}), do: fake_mac(interface)

    defp fake_mac("eth0"), do: <<0xAA, 0xBB, 0xCC, 0x00, 0x00, 0x01>>
    defp fake_mac("eth1"), do: <<0xAA, 0xBB, 0xCC, 0x00, 0x00, 0x02>>
    defp fake_mac(_), do: nil

    @impl true
    def drain(%__MODULE__{}), do: :ok

    @impl true
    def close(%__MODULE__{raw: nil} = transport), do: transport

    def close(%__MODULE__{interface: interface, raw: raw, test_pid: test_pid} = transport) do
      Kernel.send(test_pid, {:transport_closed, interface, raw})
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

  test "begin_exchange sends on both ports" do
    {:ok, circuit} = start_circuit()
    exchange = exchange_for(Transaction.fprd(0x1000, {0x0130, 2}), 1)

    assert {:ok, %Redundant{} = circuit, %Exchange{} = returned_exchange} =
             Redundant.begin_exchange(circuit, exchange)

    assert_receive {:transport_armed, "pri", primary_raw}
    assert_receive {:transport_sent, "pri", ^primary_raw, payload, _tx_at}
    assert_receive {:transport_armed, "sec", secondary_raw}
    assert_receive {:transport_sent, "sec", ^secondary_raw, ^payload, _tx_at}
    assert returned_exchange.tx_at >= exchange.tx_at
    assert returned_exchange.pending != nil
    assert Redundant.info(circuit).primary.usable?
    assert Redundant.info(circuit).secondary.usable?
  end

  test "healthy redundant exchange completes after passthrough and processed returns" do
    {:ok, circuit} = start_circuit()
    exchange = exchange_for(Transaction.fprd(0x1000, {0x0130, 2}), 3)
    {:ok, circuit, exchange} = Redundant.begin_exchange(circuit, exchange)

    assert_receive {:transport_armed, "pri", primary_raw}
    assert_receive {:transport_sent, "pri", ^primary_raw, payload, _tx_at}
    assert_receive {:transport_armed, "sec", secondary_raw}
    assert_receive {:transport_sent, "sec", ^secondary_raw, ^payload, _tx_at}

    assert {:continue, %Redundant{} = circuit, %Exchange{} = exchange} =
             Redundant.observe(
               circuit,
               {:fake_transport_payload, primary_raw, payload, System.monotonic_time()},
               exchange
             )

    processed =
      Enum.map(exchange.datagrams, fn dg ->
        %{dg | data: <<0x34, 0x12>>, wkc: 1}
      end)

    {:ok, processed_payload} = Frame.encode(processed)
    rx_at = System.monotonic_time()

    assert {:complete, %Redundant{}, observation} =
             Redundant.observe(
               circuit,
               {:fake_transport_payload, secondary_raw, processed_payload, rx_at},
               exchange
             )

    assert observation.status == :ok
    assert observation.path_shape == :full_redundancy
    assert observation.primary.rx_kind == :passthrough
    assert observation.secondary.rx_kind == :processed
    assert observation.datagrams == processed
    assert observation.completed_at == rx_at
  end

  test "redundant observe rearms when a reply reuses the idx but not the datagram shape" do
    {:ok, circuit} = start_circuit()
    exchange = exchange_for(Transaction.fprd(0x1000, {0x0130, 2}), 4)
    {:ok, circuit, exchange} = Redundant.begin_exchange(circuit, exchange)

    assert_receive {:transport_armed, "pri", primary_raw}
    assert_receive {:transport_sent, "pri", ^primary_raw, _payload, _tx_at}
    assert_receive {:transport_armed, "sec", _secondary_raw}
    assert_receive {:transport_sent, "sec", _, _payload, _tx_at}

    # Change cmd (FPRD=4 → BRD=7) — same idx but different command shape
    wrong_shape =
      Enum.map(exchange.datagrams, fn dg ->
        %{dg | cmd: 7, data: <<0x44, 0x22>>, wkc: 1}
      end)

    {:ok, wrong_shape_payload} = Frame.encode(wrong_shape)

    assert {:continue, %Redundant{}, %Exchange{}} =
             Redundant.observe(
               circuit,
               {:fake_transport_payload, primary_raw, wrong_shape_payload,
                System.monotonic_time()},
               exchange
             )

    assert_receive {:transport_rearmed, "pri", ^primary_raw}
  end

  test "complementary partial replies merge into one observation" do
    {:ok, circuit} = start_circuit()
    exchange = exchange_for(Transaction.lrw({0x0000, <<0xF0, 0xF1, 0xF2, 0xF3>>}), 5)
    {:ok, circuit, exchange} = Redundant.begin_exchange(circuit, exchange)

    assert_receive {:transport_armed, "pri", primary_raw}
    assert_receive {:transport_sent, "pri", ^primary_raw, _payload, _tx_at}
    assert_receive {:transport_armed, "sec", secondary_raw}
    assert_receive {:transport_sent, "sec", ^secondary_raw, _payload, _tx_at}

    primary_reply =
      Enum.map(exchange.datagrams, &%{&1 | data: <<0x10, 0x11, 0xF2, 0xF3>>, wkc: 2})

    secondary_reply =
      Enum.map(exchange.datagrams, &%{&1 | data: <<0xF0, 0xF1, 0x12, 0x13>>, wkc: 2})

    {:ok, primary_payload} = Frame.encode(primary_reply)
    {:ok, secondary_payload} = Frame.encode(secondary_reply)

    assert {:continue, %Redundant{} = circuit, %Exchange{} = exchange} =
             Redundant.observe(
               circuit,
               {:fake_transport_payload, primary_raw, primary_payload, System.monotonic_time()},
               exchange
             )

    assert {:complete, %Redundant{}, observation} =
             Redundant.observe(
               circuit,
               {:fake_transport_payload, secondary_raw, secondary_payload,
                System.monotonic_time()},
               exchange
             )

    assert observation.status == :ok
    assert observation.path_shape == :complementary_partials
    assert observation.primary.rx_kind == :partial
    assert observation.secondary.rx_kind == :partial

    assert observation.datagrams == [
             %{hd(exchange.datagrams) | data: <<0x10, 0x11, 0x12, 0x13>>, wkc: 4}
           ]
  end

  test "one successful send completes as a one-sided observation" do
    {:ok, circuit} = start_circuit(fail_send: %{"sec" => :enetdown})
    exchange = exchange_for(Transaction.fprd(0x1000, {0x0130, 2}), 7)

    assert {:ok, %Redundant{} = circuit, %Exchange{} = exchange} =
             Redundant.begin_exchange(circuit, exchange)

    assert_receive {:transport_armed, "pri", primary_raw}
    assert_receive {:transport_sent, "pri", ^primary_raw, _payload, _tx_at}
    refute_receive {:transport_sent, "sec", _, _, _}, 20

    reply = Enum.map(exchange.datagrams, &%{&1 | data: <<0x55, 0x55>>, wkc: 1})
    {:ok, reply_payload} = Frame.encode(reply)

    assert {:complete, %Redundant{}, observation} =
             Redundant.observe(
               circuit,
               {:fake_transport_payload, primary_raw, reply_payload, System.monotonic_time()},
               exchange
             )

    assert observation.status == :ok
    assert observation.path_shape == :primary_only
    assert observation.primary.rx_kind == :processed
    assert observation.secondary.send_result == {:error, :enetdown}
  end

  test "one-sided passthrough reply stays partial" do
    {:ok, circuit} = start_circuit(fail_send: %{"sec" => :enetdown})
    exchange = exchange_for(Transaction.fprd(0x1000, {0x0130, 2}), 8)

    assert {:ok, %Redundant{} = circuit, %Exchange{} = exchange} =
             Redundant.begin_exchange(circuit, exchange)

    assert_receive {:transport_armed, "pri", primary_raw}
    assert_receive {:transport_sent, "pri", ^primary_raw, payload, _tx_at}
    refute_receive {:transport_sent, "sec", _, _, _}, 20

    log =
      capture_log(fn ->
        assert {:complete, %Redundant{}, observation} =
                 Redundant.observe(
                   circuit,
                   {:fake_transport_payload, primary_raw, payload, System.monotonic_time()},
                   exchange
                 )

        assert observation.status == :partial
        assert observation.path_shape == :primary_only
        assert observation.primary.rx_kind == :passthrough
        assert observation.secondary.send_result == {:error, :enetdown}
      end)

    assert log =~ "status=:partial"
    assert log =~ "path_shape=:primary_only"
    assert log =~ "primary.rx=:passthrough"
    assert log =~ "secondary.send={:error, :enetdown}"
  end

  test "single processed reply on a targeted exchange completes immediately" do
    {:ok, circuit} = start_circuit()
    exchange = exchange_for(Transaction.fprd(0x1000, {0x0130, 2}), 9)
    {:ok, circuit, exchange} = Redundant.begin_exchange(circuit, exchange)

    assert_receive {:transport_armed, "pri", primary_raw}
    assert_receive {:transport_sent, "pri", ^primary_raw, _payload, _tx_at}
    assert_receive {:transport_armed, "sec", _secondary_raw}
    assert_receive {:transport_sent, "sec", _, _payload, _tx_at}

    reply = Enum.map(exchange.datagrams, &%{&1 | data: <<0x66, 0x66>>, wkc: 1})
    {:ok, reply_payload} = Frame.encode(reply)
    rx_at = System.monotonic_time()

    assert {:complete, %Redundant{}, observation} =
             Redundant.observe(
               circuit,
               {:fake_transport_payload, primary_raw, reply_payload, rx_at},
               exchange
             )

    assert observation.status == :ok
    assert observation.path_shape == :primary_only
    assert observation.primary.rx_kind == :processed
    assert observation.secondary.rx_kind == :none
    assert observation.completed_at == rx_at
  end

  test "processed reply completes immediately even if the redundant copy is still missing" do
    {:ok, circuit} = start_circuit()
    exchange = exchange_for(Transaction.fprd(0x1000, {0x0130, 2}), 15)
    {:ok, circuit, exchange} = Redundant.begin_exchange(circuit, exchange)

    assert_receive {:transport_armed, "pri", _primary_raw}
    assert_receive {:transport_sent, "pri", _, _payload, _tx_at}
    assert_receive {:transport_armed, "sec", secondary_raw}
    assert_receive {:transport_sent, "sec", _, _payload, _tx_at}

    reply = Enum.map(exchange.datagrams, &%{&1 | data: <<0x77, 0x77>>, wkc: 1})
    {:ok, reply_payload} = Frame.encode(reply)
    rx_at = System.monotonic_time()

    assert {:complete, %Redundant{}, observation} =
             Redundant.observe(
               circuit,
               {:fake_transport_payload, secondary_raw, reply_payload, rx_at},
               exchange
             )

    assert observation.status == :ok
    assert observation.path_shape == :secondary_only
    assert observation.primary.rx_kind == :none
    assert observation.secondary.rx_kind == :processed
    assert observation.completed_at == rx_at
  end

  test "logical partial reply keeps waiting for the second side" do
    {:ok, circuit} = start_circuit()
    exchange = exchange_for(Transaction.lrw({0x0000, <<0xF0, 0xF1, 0xF2, 0xF3>>}), 16)
    {:ok, circuit, exchange} = Redundant.begin_exchange(circuit, exchange)

    assert_receive {:transport_armed, "pri", primary_raw}
    assert_receive {:transport_sent, "pri", ^primary_raw, _payload, _tx_at}
    assert_receive {:transport_armed, "sec", _secondary_raw}
    assert_receive {:transport_sent, "sec", _, _payload, _tx_at}

    partial_reply =
      Enum.map(exchange.datagrams, &%{&1 | data: <<0x10, 0x11, 0xF2, 0xF3>>, wkc: 2})

    {:ok, partial_payload} = Frame.encode(partial_reply)

    assert {:continue, %Redundant{}, %Exchange{}} =
             Redundant.observe(
               circuit,
               {:fake_transport_payload, primary_raw, partial_payload, System.monotonic_time()},
               exchange
             )
  end

  test "timeout after only a passthrough copy stays partial" do
    {:ok, circuit} = start_circuit()
    exchange = exchange_for(Transaction.fprd(0x1000, {0x0130, 2}), 10)
    {:ok, circuit, exchange} = Redundant.begin_exchange(circuit, exchange)

    assert_receive {:transport_armed, "pri", primary_raw}
    assert_receive {:transport_sent, "pri", ^primary_raw, payload, _tx_at}
    assert_receive {:transport_armed, "sec", _secondary_raw}
    assert_receive {:transport_sent, "sec", _, ^payload, _tx_at}

    assert {:continue, %Redundant{}, %Exchange{} = exchange} =
             Redundant.observe(
               circuit,
               {:fake_transport_payload, primary_raw, payload, System.monotonic_time()},
               exchange
             )

    assert {:continue, %Redundant{}, %Exchange{pending: %{grace_waiting?: true}} = exchange,
            timeout_ms} =
             Redundant.timeout(circuit, exchange)

    assert timeout_ms == 25

    assert {:complete, %Redundant{}, observation} = Redundant.timeout(circuit, exchange)

    assert observation.status == :partial
    assert observation.path_shape == :primary_only
    assert observation.primary.rx_kind == :passthrough
    assert observation.secondary.rx_kind == :none
  end

  test "processed return arriving during the grace window completes successfully" do
    {:ok, circuit} = start_circuit(reply_grace_ms: 20)
    exchange = exchange_for(Transaction.fprd(0x1000, {0x0130, 2}), 12)
    {:ok, circuit, exchange} = Redundant.begin_exchange(circuit, exchange)

    assert_receive {:transport_armed, "pri", primary_raw}
    assert_receive {:transport_sent, "pri", ^primary_raw, payload, _tx_at}
    assert_receive {:transport_armed, "sec", secondary_raw}
    assert_receive {:transport_sent, "sec", ^secondary_raw, ^payload, _tx_at}

    assert {:continue, %Redundant{} = circuit, %Exchange{} = exchange} =
             Redundant.observe(
               circuit,
               {:fake_transport_payload, primary_raw, payload, System.monotonic_time()},
               exchange
             )

    assert {:continue, %Redundant{} = circuit,
            %Exchange{pending: %{grace_waiting?: true}} = exchange, 20} =
             Redundant.timeout(circuit, exchange)

    processed =
      Enum.map(exchange.datagrams, fn dg ->
        %{dg | data: <<0x44, 0x22>>, wkc: 1}
      end)

    {:ok, processed_payload} = Frame.encode(processed)
    rx_at = System.monotonic_time()

    assert {:complete, %Redundant{}, observation} =
             Redundant.observe(
               circuit,
               {:fake_transport_payload, secondary_raw, processed_payload, rx_at},
               exchange
             )

    assert observation.status == :ok
    assert observation.path_shape == :full_redundancy
    assert observation.primary.rx_kind == :passthrough
    assert observation.secondary.rx_kind == :processed
    assert observation.completed_at == rx_at
  end

  test "timeout with no replies yields no valid return" do
    {:ok, circuit} = start_circuit()
    exchange = exchange_for(Transaction.fprd(0x1000, {0x0130, 2}), 11)
    {:ok, circuit, exchange} = Redundant.begin_exchange(circuit, exchange)

    assert_receive {:transport_armed, "pri", _primary_raw}
    assert_receive {:transport_sent, "pri", _, _payload, _tx_at}
    assert_receive {:transport_armed, "sec", _secondary_raw}
    assert_receive {:transport_sent, "sec", _, _payload, _tx_at}

    assert {:continue, %Redundant{}, %Exchange{pending: %{grace_waiting?: true}} = exchange, 25} =
             Redundant.timeout(circuit, exchange)

    assert {:complete, %Redundant{}, observation} = Redundant.timeout(circuit, exchange)

    assert observation.status == :timeout
    assert observation.path_shape == :no_valid_return
    assert observation.primary.rx_kind == :none
    assert observation.secondary.rx_kind == :none
  end

  test "send backoff skips immediate reopen attempts on a failed port" do
    {:ok, circuit} = start_circuit(fail_send: %{"sec" => :enetdown}, send_backoff_ms: 100)
    exchange = exchange_for(Transaction.fprd(0x1000, {0x0130, 2}), 13)

    assert {:ok, %Redundant{} = circuit, %Exchange{}} =
             Redundant.begin_exchange(circuit, exchange)

    assert_receive {:transport_armed, "pri", _primary_raw}
    assert_receive {:transport_sent, "pri", _, _payload, _tx_at}
    assert_receive {:transport_armed, "sec", secondary_raw}
    refute_receive {:transport_sent, "sec", _, _, _}, 20

    exchange = exchange_for(Transaction.fprd(0x1000, {0x0130, 2}), 14)

    assert {:ok, %Redundant{}, %Exchange{pending: pending} = _exchange} =
             Redundant.begin_exchange(circuit, exchange)

    assert_receive {:transport_armed, "pri", _primary_raw}
    assert_receive {:transport_sent, "pri", _, _payload, _tx_at}
    refute_receive {:transport_armed, "sec", ^secondary_raw}, 20
    assert pending.secondary.send_result == :skipped
  end

  test "open closes the primary port when secondary open fails" do
    assert {:error, :enetdown} =
             start_circuit(fail_open: %{"sec" => :enetdown})

    assert_receive {:transport_closed, "pri", _raw}
  end

  defp start_circuit(opts \\ []) do
    Redundant.open(
      Keyword.merge(
        [
          backup_interface: "sec",
          interface: "pri",
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
