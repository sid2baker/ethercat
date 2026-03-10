defmodule EtherCAT.BusTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Bus
  alias EtherCAT.Bus.{Datagram, Frame, Transaction}
  alias EtherCAT.Bus.Link.Redundant

  defmodule FakeLink do
    @behaviour EtherCAT.Bus.Link

    import Kernel, except: [send: 2]

    defstruct [:owner, :test_pid]

    @impl true
    def open(opts) do
      {:ok, %__MODULE__{owner: self(), test_pid: Keyword.fetch!(opts, :test_pid)}}
    end

    @impl true
    def send(%__MODULE__{test_pid: test_pid} = link, payload) do
      tx_at = System.monotonic_time()
      Kernel.send(test_pid, {:fake_link_sent, payload, tx_at})
      {:ok, link}
    end

    @impl true
    def match(%__MODULE__{} = link, {:fake_link_payload, payload, rx_at}),
      do: {:ok, link, payload, rx_at}

    def match(%__MODULE__{} = link, _msg), do: {:ignore, link}

    @impl true
    def timeout(%__MODULE__{} = link), do: {:error, link, :timeout}

    @impl true
    def rearm(%__MODULE__{} = link), do: link

    @impl true
    def clear_awaiting(%__MODULE__{} = link), do: link

    @impl true
    def drain(%__MODULE__{} = link), do: link

    @impl true
    def close(%__MODULE__{} = link), do: link

    @impl true
    def carrier(%__MODULE__{} = link, _ifname, false), do: {:down, link, :carrier_lost}
    def carrier(%__MODULE__{} = link, _ifname, true), do: {:ok, link}

    @impl true
    def reconnect(%__MODULE__{} = link), do: link

    @impl true
    def usable?(%__MODULE__{}), do: true

    @impl true
    def needs_reconnect?(%__MODULE__{}), do: false

    @impl true
    def name(%__MODULE__{}), do: "fake"

    @impl true
    def interfaces(%__MODULE__{}), do: []
  end

  defmodule FakeTransport do
    @behaviour EtherCAT.Bus.Transport

    import Kernel, except: [send: 2]

    defstruct [:fail_send, :interface, :raw, :test_pid]

    @impl true
    def open(opts) do
      {:ok,
       %__MODULE__{
         fail_send: Keyword.get(opts, :fail_send, %{}),
         interface: Keyword.fetch!(opts, :interface),
         raw: make_ref(),
         test_pid: Keyword.fetch!(opts, :test_pid)
       }}
    end

    @impl true
    def send(%__MODULE__{fail_send: fail_send, interface: interface} = transport, payload) do
      case Map.get(fail_send, interface) do
        nil ->
          tx_at = System.monotonic_time()

          Kernel.send(
            transport.test_pid,
            {:fake_transport_sent, interface, transport.raw, payload, tx_at}
          )

          {:ok, tx_at}

        reason ->
          {:error, reason}
      end
    end

    @impl true
    def set_active_once(%__MODULE__{}), do: :ok

    @impl true
    def match(%__MODULE__{raw: raw}, {:fake_transport_payload, raw, payload, rx_at}) do
      {:ok, payload, rx_at}
    end

    def match(%__MODULE__{}, _msg), do: :ignore

    @impl true
    def drain(%__MODULE__{}), do: :ok

    @impl true
    def close(%__MODULE__{raw: nil} = transport), do: transport
    def close(%__MODULE__{} = transport), do: %{transport | raw: nil}

    @impl true
    def open?(%__MODULE__{raw: nil}), do: false
    def open?(%__MODULE__{}), do: true

    @impl true
    def name(%__MODULE__{interface: interface}), do: interface

    @impl true
    def interface(%__MODULE__{interface: interface}), do: interface
  end

  test "init returns an explicit bus runtime struct" do
    test_pid = self()

    assert {:ok, :idle,
            %Bus{
              link: %FakeLink{test_pid: ^test_pid},
              link_mod: FakeLink,
              idx: 0,
              in_flight: nil,
              frame_timeout_ms: 10,
              timeout_count: 0
            }} = Bus.init(link_mod: FakeLink, test_pid: test_pid, frame_timeout_ms: 10)
  end

  test "realtime work expires while waiting for an earlier frame" do
    {:ok, bus} = start_bus()

    first = Task.async(fn -> Bus.transaction(bus, Transaction.brd({0x0000, 1})) end)
    first_frame = assert_sent_frame()

    expired =
      Task.async(fn ->
        Bus.transaction(bus, Transaction.fprd(0x1000, {0x0130, 2}), 1_000)
      end)

    Process.sleep(5)
    reply_ok(bus, first_frame)

    assert {:error, :expired} = Task.await(expired)
    assert {:ok, [%{wkc: 1}]} = Task.await(first)
    refute_receive {:fake_link_sent, _, _}
  end

  test "realtime dispatches ahead of reliable backlog and is never mixed into the same frame" do
    {:ok, bus} = start_bus()

    first = Task.async(fn -> Bus.transaction(bus, Transaction.brd({0x0000, 1})) end)
    first_frame = assert_sent_frame()

    reliable =
      Task.async(fn ->
        Bus.transaction(bus, Transaction.fpwr(0x1000, {0x0120, <<0x02, 0x00>>}))
      end)

    realtime =
      Task.async(fn ->
        Bus.transaction(bus, Transaction.fprd(0x1000, {0x0130, 2}), 50_000)
      end)

    Process.sleep(10)
    reply_ok(bus, first_frame)

    realtime_frame = assert_sent_frame()
    assert [%Datagram{cmd: 4}] = realtime_frame
    reply_with(bus, realtime_frame, fn dg -> %{dg | data: <<0x34, 0x12>>, wkc: 1} end)

    reliable_frame = assert_sent_frame()
    assert [%Datagram{cmd: 5}] = reliable_frame
    reply_ok(bus, reliable_frame)

    assert {:ok, [%{data: <<0x34, 0x12>>, wkc: 1}]} = Task.await(realtime)
    assert {:ok, [%{wkc: 1}]} = Task.await(reliable)
    assert {:ok, [%{wkc: 1}]} = Task.await(first)
  end

  test "reliable backlog batches into one frame and replies are sliced back to original callers" do
    {:ok, bus} = start_bus()

    first = Task.async(fn -> Bus.transaction(bus, Transaction.brd({0x0000, 1})) end)
    first_frame = assert_sent_frame()

    read_a = Task.async(fn -> Bus.transaction(bus, Transaction.fprd(0x1000, {0x0130, 2})) end)
    read_b = Task.async(fn -> Bus.transaction(bus, Transaction.fprd(0x1001, {0x0130, 2})) end)

    Process.sleep(10)
    reply_ok(bus, first_frame)

    batch_frame = assert_sent_frame()
    assert length(batch_frame) == 2

    reply_with(bus, batch_frame, fn dg ->
      %{dg | data: reply_data_for_station(dg), wkc: 1}
    end)

    assert {:ok, [%{data: <<0xAA, 0x00>>, wkc: 1}]} = Task.await(read_a)
    assert {:ok, [%{data: <<0xBB, 0x00>>, wkc: 1}]} = Task.await(read_b)
    assert {:ok, [%{wkc: 1}]} = Task.await(first)
  end

  test "oversized reliable transaction returns frame_too_large without dropping the bus" do
    {:ok, bus} = start_bus()

    oversized =
      Task.async(fn ->
        Bus.transaction(bus, Transaction.lrw({0x0000, :binary.copy(<<0>>, 1_500)}))
      end)

    assert {:error, :frame_too_large} = Task.await(oversized)
    refute_receive {:fake_link_sent, _, _}

    small = Task.async(fn -> Bus.transaction(bus, Transaction.brd({0x0000, 1})) end)
    small_frame = assert_sent_frame()
    reply_ok(bus, small_frame)

    assert {:ok, [%{wkc: 1}]} = Task.await(small)
  end

  test "redundant link merges duplicate responses by higher WKC" do
    {:ok, bus} = start_redundant_bus()

    read = Task.async(fn -> Bus.transaction(bus, Transaction.fprd(0x1000, {0x0130, 2})) end)

    primary = assert_sent_transport("pri")
    secondary = assert_sent_transport("sec")

    reply_transport(bus, primary, fn dg -> %{dg | data: <<0x11, 0x11>>, wkc: 1} end)
    refute_receive {:fake_transport_sent, _, _, _, _}, 20

    reply_transport(bus, secondary, fn dg -> %{dg | data: <<0x22, 0x22>>, wkc: 2} end)

    assert {:ok, [%{data: <<0x22, 0x22>>, wkc: 2}]} = Task.await(read)
  end

  test "redundant link degrades to the surviving port after carrier loss" do
    {:ok, bus} = start_redundant_bus()

    read = Task.async(fn -> Bus.transaction(bus, Transaction.fprd(0x1000, {0x0130, 2})) end)

    assert_sent_transport("pri")
    secondary = assert_sent_transport("sec")

    send(bus, {:ethercat_link, "pri", true, false})
    reply_transport(bus, secondary, fn dg -> %{dg | data: <<0x33, 0x33>>, wkc: 1} end)

    assert {:ok, [%{data: <<0x33, 0x33>>, wkc: 1}]} = Task.await(read)

    next = Task.async(fn -> Bus.transaction(bus, Transaction.fprd(0x1001, {0x0130, 2})) end)

    next_secondary = assert_sent_transport("sec")
    refute_receive {:fake_transport_sent, "pri", _, _, _}, 20

    reply_transport(bus, next_secondary, fn dg -> %{dg | data: <<0x44, 0x44>>, wkc: 1} end)

    assert {:ok, [%{data: <<0x44, 0x44>>, wkc: 1}]} = Task.await(next)
  end

  test "named buses are reachable through their registered server ref" do
    name = :"bus_test_#{System.unique_integer([:positive, :monotonic])}"

    {:ok, bus} =
      Bus.start_link(
        name: name,
        link_mod: FakeLink,
        transport: :udp,
        test_pid: self(),
        frame_timeout_ms: 50
      )

    assert Process.whereis(name) == bus

    read = Task.async(fn -> Bus.transaction(name, Transaction.fprd(0x1000, {0x0130, 2})) end)

    [datagram] = assert_sent_frame(500)
    reply_with(bus, [datagram], fn dg -> %{dg | data: <<0x12, 0x34>>, wkc: 1} end)

    assert {:ok, [%{data: <<0x12, 0x34>>, wkc: 1}]} = Task.await(read)
  end

  test "single-port bus reports link monitor mode and recovers after carrier restore" do
    {:ok, bus} = start_bus()

    assert {:ok,
            %{
              state: :idle,
              link: "fake",
              carrier_up: false,
              frame_timeout_ms: 50,
              link_monitor_mode: :disabled
            }} = Bus.info(bus)

    read = Task.async(fn -> Bus.transaction(bus, Transaction.fprd(0x1000, {0x0130, 2})) end)
    assert_sent_frame()

    send(bus, {:ethercat_link, "eth0", true, false})
    assert {:error, :down} = Task.await(read)

    assert {:ok, %{state: :down, carrier_up: false}} = Bus.info(bus)

    while_down = Task.async(fn -> Bus.transaction(bus, Transaction.fprd(0x1000, {0x0130, 2})) end)
    assert {:error, :down} = Task.await(while_down)

    send(bus, {:ethercat_link, "eth0", false, true})
    Process.sleep(250)

    assert {:ok, %{state: :idle, carrier_up: false}} = Bus.info(bus)

    after_restore =
      Task.async(fn -> Bus.transaction(bus, Transaction.fprd(0x1000, {0x0130, 2})) end)

    restored_frame = assert_sent_frame()
    reply_with(bus, restored_frame, fn dg -> %{dg | data: <<0x12, 0x34>>, wkc: 1} end)

    assert {:ok, [%{data: <<0x12, 0x34>>, wkc: 1}]} = Task.await(after_restore)
  end

  defp start_bus do
    Bus.start_link(link_mod: FakeLink, transport: :udp, test_pid: self(), frame_timeout_ms: 50)
  end

  defp start_redundant_bus do
    Bus.start_link(
      backup_interface: "sec",
      frame_timeout_ms: 50,
      interface: "pri",
      link_mod: Redundant,
      test_pid: self(),
      transport_mod: FakeTransport
    )
  end

  defp assert_sent_frame(timeout \\ 200) do
    assert_receive {:fake_link_sent, payload, _tx_at}, timeout
    assert {:ok, datagrams} = Frame.decode(payload)
    datagrams
  end

  defp assert_sent_transport(interface) do
    assert_receive {:fake_transport_sent, ^interface, raw, payload, _tx_at}, 200
    assert {:ok, datagrams} = Frame.decode(payload)
    %{datagrams: datagrams, interface: interface, raw: raw}
  end

  defp reply_ok(bus, sent_datagrams) do
    reply_with(bus, sent_datagrams, fn dg -> %{dg | wkc: 1} end)
  end

  defp reply_with(bus, sent_datagrams, fun) do
    response_datagrams = Enum.map(sent_datagrams, fun)
    {:ok, payload} = Frame.encode(response_datagrams)
    send(bus, {:fake_link_payload, payload, System.monotonic_time()})
  end

  defp reply_transport(bus, %{datagrams: datagrams, raw: raw}, fun) do
    response_datagrams = Enum.map(datagrams, fun)
    {:ok, payload} = Frame.encode(response_datagrams)
    send(bus, {:fake_transport_payload, raw, payload, System.monotonic_time()})
  end

  defp reply_data_for_station(%Datagram{
         address: <<0x1000::little-unsigned-16, _::little-unsigned-16>>
       }),
       do: <<0xAA, 0x00>>

  defp reply_data_for_station(%Datagram{
         address: <<0x1001::little-unsigned-16, _::little-unsigned-16>>
       }),
       do: <<0xBB, 0x00>>
end
