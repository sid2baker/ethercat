defmodule EtherCAT.BusTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Bus
  alias EtherCAT.Bus.{Datagram, Frame, Transaction}

  @submission_enqueued_event [:ethercat, :bus, :submission, :enqueued]
  @transaction_stop_event [:ethercat, :bus, :transact, :stop]

  setup do
    handler_id = "bus-test-#{System.unique_integer([:positive, :monotonic])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [@submission_enqueued_event, @transaction_stop_event],
        &__MODULE__.handle_telemetry_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  defmodule FakeTransport do
    @behaviour EtherCAT.Bus.Transport

    import Kernel, except: [send: 2]

    defstruct [:fail_send, :interface, :raw, :test_pid, :src_mac]

    @impl true
    def open(opts) do
      interface = Keyword.fetch!(opts, :interface)

      {:ok,
       %__MODULE__{
         fail_send: Keyword.get(opts, :fail_send, %{}),
         interface: interface,
         raw: make_ref(),
         test_pid: Keyword.fetch!(opts, :test_pid),
         src_mac: Keyword.get(opts, :src_mac, generate_mac(interface))
       }}
    end

    defp generate_mac(interface) do
      hash = :erlang.phash2(interface, 0xFFFFFF)
      <<0x02, 0x00, hash::24>>
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
    def rearm(%__MODULE__{}), do: :ok

    @impl true
    def match(%__MODULE__{raw: raw}, {:fake_transport_payload, raw, payload, rx_at}) do
      {:ok, payload, rx_at, nil}
    end

    def match(
          %__MODULE__{raw: raw},
          {:fake_transport_payload, raw, payload, rx_at, frame_src_mac}
        ) do
      {:ok, payload, rx_at, frame_src_mac}
    end

    def match(%__MODULE__{}, _msg), do: :ignore

    @impl true
    def src_mac(%__MODULE__{src_mac: mac}), do: mac

    @impl true
    def drain(%__MODULE__{test_pid: test_pid}) do
      Kernel.send(test_pid, :fake_transport_drained)
      :ok
    end

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

  test "start_link boots an idle single-circuit bus" do
    {:ok, bus} =
      Bus.start_link(
        interface: "eth-test",
        test_pid: self(),
        frame_timeout_ms: 10,
        transport_mod: FakeTransport
      )

    assert {:ok,
            %{
              state: :idle,
              type: :single,
              topology: :single,
              fault: nil,
              frame_timeout_ms: 10,
              timeout_count: 0,
              in_flight: nil
            }} = Bus.info(bus)
  end

  test "realtime work expires while waiting for an earlier frame" do
    {:ok, bus, link_name} = start_bus()

    first = Task.async(fn -> Bus.transaction(bus, Transaction.brd({0x0000, 1})) end)
    first_frame = assert_sent_frame()

    expired =
      Task.async(fn ->
        Bus.transaction(bus, Transaction.fprd(0x1000, {0x0130, 2}), 1_000)
      end)

    enqueued_at_us = assert_submission_enqueued([{:realtime, 1}], link_name)
    wait_until_elapsed_us(enqueued_at_us, 1_001)
    reply_ok(bus, first_frame)

    assert {:error, :expired} = Task.await(expired)
    assert {:ok, [%{wkc: 1}]} = Task.await(first)
    refute_receive {:fake_transport_sent, _, _, _, _}
  end

  test "transaction stop telemetry reports stable metadata on success" do
    {:ok, bus, _link_name} = start_bus()

    read = Task.async(fn -> Bus.transaction(bus, Transaction.fprd(0x1000, {0x0130, 2})) end)

    sent_datagrams = assert_sent_frame()
    reply_ok(bus, sent_datagrams)

    assert {:ok, [%{wkc: 1}]} = Task.await(read)

    assert_receive {:telemetry_event, @transaction_stop_event, %{duration: duration},
                    %{
                      class: :reliable,
                      datagram_count: 1,
                      total_wkc: 1,
                      status: :ok,
                      error_kind: nil
                    }}

    assert duration >= 0
  end

  test "transaction stop telemetry reports stable metadata on timeout" do
    {:ok, bus, _link_name} = start_bus(frame_timeout_ms: 10)

    assert {:error, :timeout} = Bus.transaction(bus, Transaction.brd({0x0000, 1}))

    assert_receive {:telemetry_event, @transaction_stop_event, %{duration: duration},
                    %{
                      class: :reliable,
                      datagram_count: 1,
                      total_wkc: 0,
                      status: :error,
                      error_kind: :timeout
                    }}

    assert duration >= 0
  end

  test "realtime dispatches ahead of reliable backlog and is never mixed into the same frame" do
    {:ok, bus, link_name} = start_bus()

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

    assert_submission_enqueued([{:reliable, 1}, {:realtime, 1}], link_name)
    reply_ok(bus, first_frame)

    realtime_frame = assert_sent_frame()
    assert %{datagrams: [%Datagram{cmd: 4}]} = realtime_frame
    reply_with(bus, realtime_frame, fn dg -> %{dg | data: <<0x34, 0x12>>, wkc: 1} end)

    reliable_frame = assert_sent_frame()
    assert %{datagrams: [%Datagram{cmd: 5}]} = reliable_frame
    reply_ok(bus, reliable_frame)

    assert {:ok, [%{data: <<0x34, 0x12>>, wkc: 1}]} = Task.await(realtime)
    assert {:ok, [%{wkc: 1}]} = Task.await(reliable)
    assert {:ok, [%{wkc: 1}]} = Task.await(first)
  end

  test "realtime keeps preempting reliable backlog under sustained load" do
    {:ok, bus, link_name} = start_bus()

    first = Task.async(fn -> Bus.transaction(bus, Transaction.brd({0x0000, 1})) end)
    first_frame = assert_sent_frame()

    reliable_stations = Enum.to_list(0x2000..0x2007)
    realtime_stations = [0x3000, 0x3001, 0x3002]

    reliable_tasks =
      reliable_stations
      |> Enum.with_index(1)
      |> Enum.map(fn {station, depth} ->
        task = Task.async(fn -> Bus.transaction(bus, Transaction.fprd(station, {0x0130, 2})) end)
        assert_submission_enqueued([{:reliable, depth}], link_name)
        task
      end)

    realtime_tasks =
      realtime_stations
      |> Enum.with_index(1)
      |> Enum.map(fn {station, depth} ->
        task =
          Task.async(fn ->
            Bus.transaction(bus, Transaction.fprd(station, {0x0130, 2}), 100_000)
          end)

        assert_submission_enqueued([{:realtime, depth}], link_name)
        task
      end)

    reply_ok(bus, first_frame)

    first_realtime_frame = assert_sent_frame()
    assert_single_station_read(first_realtime_frame, 0x3000)
    reply_with(bus, first_realtime_frame, fn dg -> %{dg | data: <<0x00, 0x00>>, wkc: 1} end)

    second_realtime_frame = assert_sent_frame()
    assert_single_station_read(second_realtime_frame, 0x3001)
    reply_with(bus, second_realtime_frame, fn dg -> %{dg | data: <<0x01, 0x00>>, wkc: 1} end)

    third_realtime_frame = assert_sent_frame()
    assert_single_station_read(third_realtime_frame, 0x3002)
    reply_with(bus, third_realtime_frame, fn dg -> %{dg | data: <<0x02, 0x00>>, wkc: 1} end)

    reliable_batch_frame = assert_sent_frame()
    assert length(reliable_batch_frame.datagrams) == length(reliable_stations)
    assert Enum.all?(reliable_batch_frame.datagrams, &match?(%Datagram{cmd: 4}, &1))

    reply_with(bus, reliable_batch_frame, fn dg ->
      <<station::little-unsigned-16, _offset::little-unsigned-16>> = dg.address
      %{dg | data: <<station - 0x2000, 0x00>>, wkc: 1}
    end)

    assert {:ok, [%{wkc: 1}]} = Task.await(first)

    assert [
             {:ok, [%{data: <<0x00, 0x00>>, wkc: 1}]},
             {:ok, [%{data: <<0x01, 0x00>>, wkc: 1}]},
             {:ok, [%{data: <<0x02, 0x00>>, wkc: 1}]}
           ] = Enum.map(realtime_tasks, &Task.await/1)

    reliable_results = Enum.map(reliable_tasks, &Task.await/1)

    assert Enum.zip(reliable_results, 0..7)
           |> Enum.all?(fn
             {{:ok, [%{data: <<value, 0x00>>, wkc: 1}]}, value} -> true
             _ -> false
           end)
  end

  test "reliable backlog batches into one frame and replies are sliced back to original callers" do
    {:ok, bus, link_name} = start_bus()

    first = Task.async(fn -> Bus.transaction(bus, Transaction.brd({0x0000, 1})) end)
    first_frame = assert_sent_frame()

    read_a = Task.async(fn -> Bus.transaction(bus, Transaction.fprd(0x1000, {0x0130, 2})) end)
    read_b = Task.async(fn -> Bus.transaction(bus, Transaction.fprd(0x1001, {0x0130, 2})) end)

    assert_submission_enqueued([{:reliable, 1}, {:reliable, 2}], link_name)
    reply_ok(bus, first_frame)

    batch_frame = assert_sent_frame()
    assert length(batch_frame.datagrams) == 2

    reply_with(bus, batch_frame, fn dg ->
      %{dg | data: reply_data_for_station(dg), wkc: 1}
    end)

    assert {:ok, [%{data: <<0xAA, 0x00>>, wkc: 1}]} = Task.await(read_a)
    assert {:ok, [%{data: <<0xBB, 0x00>>, wkc: 1}]} = Task.await(read_b)
    assert {:ok, [%{wkc: 1}]} = Task.await(first)
  end

  test "oversized reliable transaction returns frame_too_large without dropping the bus" do
    {:ok, bus, _link_name} = start_bus()

    oversized =
      Task.async(fn ->
        Bus.transaction(bus, Transaction.lrw({0x0000, :binary.copy(<<0>>, 1_500)}))
      end)

    assert {:error, :frame_too_large} = Task.await(oversized)
    refute_receive {:fake_transport_sent, _, _, _, _}

    small = Task.async(fn -> Bus.transaction(bus, Transaction.brd({0x0000, 1})) end)
    small_frame = assert_sent_frame()
    reply_ok(bus, small_frame)

    assert {:ok, [%{wkc: 1}]} = Task.await(small)
  end

  test "redundant link keeps the processed forward-path reply over the reverse passthrough copy" do
    {:ok, bus} = start_redundant_circuit_bus()
    pri_mac = fake_mac("pri")
    sec_mac = fake_mac("sec")

    read = Task.async(fn -> Bus.transaction(bus, Transaction.fprd(0x1000, {0x0130, 2})) end)

    primary = assert_sent_transport("pri")
    secondary = assert_sent_transport("sec")

    # Healthy ring: secondary's frame arrives on primary (reverse cross),
    # primary's frame arrives on secondary (forward cross = authoritative).
    reply_transport(bus, primary, fn dg -> %{dg | wkc: 0} end, src_mac: sec_mac)
    refute_receive {:fake_transport_sent, _, _, _, _}, 20

    reply_transport(bus, secondary, fn dg -> %{dg | data: <<0x22, 0x22>>, wkc: 1} end,
      src_mac: pri_mac
    )

    assert {:ok, [%{data: <<0x22, 0x22>>, wkc: 1}]} = Task.await(read)
  end

  test "redundant link merges complementary logical data from both sides of a break" do
    {:ok, bus} = start_redundant_circuit_bus()
    pri_mac = fake_mac("pri")
    sec_mac = fake_mac("sec")

    original = <<0xF0, 0xF1, 0xF2, 0xF3>>

    read =
      Task.async(fn ->
        Bus.transaction(bus, Transaction.lrw({0x0000, original}))
      end)

    primary = assert_sent_transport("pri")
    secondary = assert_sent_transport("sec")

    # Ring break: primary's frame bounces back to primary (pri_bounce),
    # secondary's frame bounces back to secondary (sec_bounce).
    # Each side processed a different half of the slaves.
    reply_transport(bus, primary, fn dg -> %{dg | data: <<0x10, 0x11, 0xF2, 0xF3>>, wkc: 2} end,
      src_mac: pri_mac
    )

    refute_receive {:fake_transport_sent, _, _, _, _}, 20

    reply_transport(bus, secondary, fn dg -> %{dg | data: <<0xF0, 0xF1, 0x12, 0x13>>, wkc: 2} end,
      src_mac: sec_mac
    )

    assert {:ok, [%{data: <<0x10, 0x11, 0x12, 0x13>>, wkc: 4}]} = Task.await(read)
  end

  test "redundant multi-datagram BWR returns cross-delivery data when echoes arrive first (bounce MAC)" do
    # Echoes classified as bounces (own MAC on own port) — link layer must not
    # complete on merged wkc=0 bounces before real cross-deliveries arrive.
    {:ok, bus} = start_redundant_circuit_bus(frame_timeout_ms: 100)
    pri_mac = fake_mac("pri")
    sec_mac = fake_mac("sec")

    tx =
      Enum.reduce(1..13, Transaction.new(), fn i, tx ->
        Transaction.bwr(tx, {0x0100 + i, <<0::8>>})
      end)

    read = Task.async(fn -> Bus.transaction(bus, tx) end)

    primary = assert_sent_transport("pri")
    secondary = assert_sent_transport("sec")
    assert length(primary.datagrams) == 13

    # Echoes arrive first as bounces (own MAC, wkc=0)
    reply_transport(bus, primary, fn dg -> dg end, src_mac: pri_mac)
    reply_transport(bus, secondary, fn dg -> dg end, src_mac: sec_mac)

    # Real forward cross arrives later with wkc=3
    Process.sleep(5)
    reply_transport(bus, secondary, fn dg -> %{dg | wkc: 3} end, src_mac: pri_mac)

    assert {:ok, results} = Task.await(read)
    assert length(results) == 13
    assert Enum.all?(results, fn r -> r.wkc == 3 end)
  end

  test "redundant multi-datagram BWR returns cross-delivery data when echoes arrive first (unknown MAC)" do
    # Reproduces the actual hardware bug: AF_PACKET outgoing echoes arrive with
    # a source MAC that matches neither NIC (e.g. slave ASIC rewrites src MAC,
    # or pkttype detection unavailable). Both echoes are classified as :unknown
    # with wkc=0. Without the wkc=0 guard, interpret/3 completes the exchange
    # immediately with wkc=0 data before the real cross-delivery arrives.
    {:ok, bus} = start_redundant_circuit_bus(frame_timeout_ms: 100)
    slave_mac = <<0xEA, 0x0C, 0xE6, 0xE4, 0xB2, 0xB0>>

    tx =
      Enum.reduce(1..13, Transaction.new(), fn i, tx ->
        Transaction.bwr(tx, {0x0100 + i, <<0::8>>})
      end)

    read = Task.async(fn -> Bus.transaction(bus, tx) end)

    primary = assert_sent_transport("pri")
    secondary = assert_sent_transport("sec")
    assert length(primary.datagrams) == 13

    # Echoes arrive with unknown MAC (doesn't match pri or sec NIC) and wkc=0
    reply_transport(bus, primary, fn dg -> dg end, src_mac: slave_mac)
    reply_transport(bus, secondary, fn dg -> dg end, src_mac: slave_mac)

    # Real cross-delivery arrives later with wkc=3
    Process.sleep(5)
    reply_transport(bus, secondary, fn dg -> %{dg | wkc: 3} end, src_mac: slave_mac)

    assert {:ok, results} = Task.await(read)
    assert length(results) == 13
    assert Enum.all?(results, fn r -> r.wkc == 3 end)
  end

  test "redundant single-datagram BRD returns cross-delivery data when echoes arrive first" do
    # Same echo race with single BRD — unknown MAC variant.
    {:ok, bus} = start_redundant_circuit_bus(frame_timeout_ms: 100)
    slave_mac = <<0xEA, 0x0C, 0xE6, 0xE4, 0xB2, 0xB0>>

    read = Task.async(fn -> Bus.transaction(bus, Transaction.brd({0x0000, 1})) end)

    primary = assert_sent_transport("pri")
    secondary = assert_sent_transport("sec")

    # Echoes with unknown MAC, wkc=0
    reply_transport(bus, primary, fn dg -> dg end, src_mac: slave_mac)
    reply_transport(bus, secondary, fn dg -> dg end, src_mac: slave_mac)

    # Real cross-delivery
    Process.sleep(5)
    reply_transport(bus, secondary, fn dg -> %{dg | wkc: 3} end, src_mac: slave_mac)

    assert {:ok, [%{wkc: 3}]} = Task.await(read)
  end

  test "named buses are reachable through their registered server ref" do
    name = :"bus_test_#{System.unique_integer([:positive, :monotonic])}"

    {:ok, bus} =
      Bus.start_link(
        name: name,
        interface: "named0",
        test_pid: self(),
        frame_timeout_ms: 50,
        transport_mod: FakeTransport
      )

    assert Process.whereis(name) == bus

    read = Task.async(fn -> Bus.transaction(name, Transaction.fprd(0x1000, {0x0130, 2})) end)

    %{datagrams: [_datagram]} = sent = assert_sent_frame(500)
    reply_with(bus, sent, fn dg -> %{dg | data: <<0x12, 0x34>>, wkc: 1} end)

    assert {:ok, [%{data: <<0x12, 0x34>>, wkc: 1}]} = Task.await(read)
  end

  test "built-in single circuit executes transactions through the transport layer" do
    {:ok, bus} = start_single_circuit_bus()

    read = Task.async(fn -> Bus.transaction(bus, Transaction.fprd(0x1000, {0x0130, 2})) end)

    sent = assert_sent_transport("eth0")
    reply_transport(bus, sent, fn dg -> %{dg | data: <<0x12, 0x34>>, wkc: 1} end)

    assert {:ok, [%{data: <<0x12, 0x34>>, wkc: 1}]} = Task.await(read)

    assert {:ok,
            %{
              state: :idle,
              topology: :single,
              fault: nil,
              in_flight: nil
            }} = Bus.info(bus)
  end

  test "built-in single circuit reports transport failure" do
    {:ok, bus} = start_single_circuit_bus(fail_send: %{"eth0" => :enetdown})

    assert {:error, :enetdown} =
             Bus.transaction(bus, Transaction.fprd(0x1000, {0x0130, 2}))

    assert {:ok,
            %{
              state: :unhealthy,
              fault: %{kind: :transport_fault},
              last_error_reason: :transport_unavailable
            }} = Bus.info(bus)
  end

  test "built-in redundant circuit executes a healthy redundant exchange" do
    {:ok, bus} = start_redundant_circuit_bus()
    pri_mac = fake_mac("pri")
    sec_mac = fake_mac("sec")

    read = Task.async(fn -> Bus.transaction(bus, Transaction.fprd(0x1000, {0x0130, 2})) end)

    primary = assert_sent_transport("pri")
    secondary = assert_sent_transport("sec")

    # Healthy ring: reverse cross on primary, forward cross on secondary
    reply_transport(bus, primary, fn dg -> %{dg | wkc: 0} end, src_mac: sec_mac)

    reply_transport(bus, secondary, fn dg -> %{dg | data: <<0x21, 0x43>>, wkc: 1} end,
      src_mac: pri_mac
    )

    assert {:ok, [%{data: <<0x21, 0x43>>, wkc: 1}]} = Task.await(read)

    assert {:ok,
            %{
              state: :idle,
              type: :redundant,
              topology: :redundant,
              fault: nil,
              in_flight: nil
            }} =
             Bus.info(bus)
  end

  test "built-in redundant circuit degrades from observed primary transport failure" do
    {:ok, bus} = start_redundant_circuit_bus(fail_send: %{"pri" => :enetdown})

    degraded = Task.async(fn -> Bus.transaction(bus, Transaction.fprd(0x1001, {0x0130, 2})) end)

    secondary_only = assert_sent_transport("sec")
    refute_receive {:fake_transport_sent, "pri", _, _, _}, 20

    reply_transport(bus, secondary_only, fn dg -> %{dg | data: <<0x32, 0x32>>, wkc: 1} end)

    assert {:ok, [%{data: <<0x32, 0x32>>, wkc: 1}]} = Task.await(degraded)

    assert {:ok,
            %{
              type: :redundant,
              topology: :degraded_primary_leg,
              fault: %{
                kind: :transport_fault,
                degraded_ports: [:primary],
                reasons: %{primary: :enetdown}
              }
            }} = Bus.info(bus)
  end

  test "built-in redundant circuit accepts a processed one-sided timeout as degraded success" do
    pri_mac = fake_mac("pri")
    {:ok, bus} = start_redundant_circuit_bus(frame_timeout_ms: 10)

    read = Task.async(fn -> Bus.transaction(bus, Transaction.brd({0x0000, 1})) end)

    _primary = assert_sent_transport("pri")
    secondary = assert_sent_transport("sec")

    # Forward cross on secondary (primary's frame crossed) — authoritative reply
    reply_transport(bus, secondary, fn dg -> %{dg | wkc: 3} end, src_mac: pri_mac)

    # Forward cross completes immediately — primary's path is proven healthy,
    # secondary's reply status is inconclusive (completed early)
    assert {:ok, [%{wkc: 3}]} = Task.await(read)

    assert {:ok, %{type: :redundant}} = Bus.info(bus)
  end

  test "single-port bus reports runtime info" do
    {:ok, bus, link_name} = start_bus()

    assert {:ok,
            %{
              state: :idle,
              link: ^link_name,
              type: :single,
              topology: :single,
              fault: nil,
              frame_timeout_ms: 50,
              timeout_count: 0,
              last_error_reason: nil,
              queue_depths: %{realtime: 0, reliable: 0},
              in_flight: nil
            }} = Bus.info(bus)
  end

  test "info reports queue depth and in-flight frame details while awaiting" do
    {:ok, bus, link_name} = start_bus()

    first = Task.async(fn -> Bus.transaction(bus, Transaction.brd({0x0000, 1})) end)
    first_frame = assert_sent_frame()
    assert_submission_enqueued([{:reliable, 1}], link_name)

    queued =
      Task.async(fn ->
        Bus.transaction(bus, Transaction.fprd(0x1000, {0x0130, 2}))
      end)

    assert_submission_enqueued([{:reliable, 1}], link_name)

    assert {:ok,
            %{
              state: :awaiting,
              queue_depths: %{realtime: 0, reliable: 1},
              in_flight: %{
                caller_count: 1,
                datagram_count: 1,
                payload_size: payload_size,
                age_ms: age_ms
              }
            }} = Bus.info(bus)

    assert is_integer(payload_size) and payload_size > 0
    assert is_integer(age_ms) and age_ms >= 0

    reply_ok(bus, first_frame)

    queued_frame = assert_sent_frame()
    reply_with(bus, queued_frame, fn dg -> %{dg | data: <<0x12, 0x34>>, wkc: 1} end)

    assert {:ok, [%{wkc: 1}]} = Task.await(first)
    assert {:ok, [%{data: <<0x12, 0x34>>, wkc: 1}]} = Task.await(queued)
  end

  test "settle drains buffered receive traffic while idle" do
    {:ok, bus, _link_name} = start_bus()

    assert :ok = Bus.settle(bus)
    assert_receive :fake_transport_drained
  end

  test "settle waits for the current in-flight transaction before draining" do
    {:ok, bus, _link_name} = start_bus()

    read = Task.async(fn -> Bus.transaction(bus, Transaction.fprd(0x1000, {0x0130, 2})) end)
    sent = assert_sent_frame()

    settle = Task.async(fn -> Bus.settle(bus) end)

    refute Task.yield(settle, 10)
    refute_receive :fake_transport_drained, 10

    reply_with(bus, sent, fn dg -> %{dg | data: <<0x12, 0x34>>, wkc: 1} end)

    assert {:ok, [%{data: <<0x12, 0x34>>, wkc: 1}]} = Task.await(read)
    assert :ok = Task.await(settle)
    assert_receive :fake_transport_drained
  end

  test "quiesce drains before and after the quiet window" do
    {:ok, bus, _link_name} = start_bus()

    assert :ok = Bus.quiesce(bus, 1)
    assert_receive :fake_transport_drained
    assert_receive :fake_transport_drained
  end

  test "redundant passthrough-only reply is discarded as echo copy and times out" do
    pri_mac = fake_mac("pri")
    {:ok, bus} = start_redundant_circuit_bus(frame_timeout_ms: 10)

    txn = Task.async(fn -> Bus.transaction(bus, Transaction.brd({0x0000, 1})) end)

    primary = assert_sent_frame()
    secondary = assert_sent_frame()

    assert primary.interface == "pri"
    assert secondary.interface == "sec"

    # A frame with wkc=0 and unchanged data is indistinguishable from an
    # outgoing echo — the content-based filter discards it. No slave
    # processed the frame, so timeout is the correct outcome.
    send(
      bus,
      {:fake_transport_payload, primary.raw, primary_payload(primary), System.monotonic_time(),
       pri_mac}
    )

    assert {:error, :timeout} = Task.await(txn)
    assert_receive :fake_transport_drained
    assert_receive :fake_transport_drained
  end

  defp start_bus(opts \\ []) do
    interface = "eth#{System.unique_integer([:positive, :monotonic])}"

    case Bus.start_link(
           Keyword.merge(
             [
               interface: interface,
               test_pid: self(),
               frame_timeout_ms: 50,
               transport_mod: FakeTransport
             ],
             opts
           )
         ) do
      {:ok, bus} -> {:ok, bus, interface}
      error -> error
    end
  end

  defp start_redundant_circuit_bus(opts \\ []) do
    Bus.start_link(
      Keyword.merge(
        [
          backup_interface: "sec",
          frame_timeout_ms: 50,
          interface: "pri",
          test_pid: self(),
          transport_mod: FakeTransport
        ],
        opts
      )
    )
  end

  defp start_single_circuit_bus(opts \\ []) do
    Bus.start_link(
      Keyword.merge(
        [
          frame_timeout_ms: 50,
          interface: "eth0",
          test_pid: self(),
          transport_mod: FakeTransport
        ],
        opts
      )
    )
  end

  defp assert_sent_frame(timeout \\ 200) do
    assert_receive {:fake_transport_sent, interface, raw, payload, _tx_at}, timeout
    assert {:ok, datagrams} = Frame.decode(payload)
    %{datagrams: datagrams, interface: interface, raw: raw}
  end

  defp single_station_read_station(%{
         datagrams: [%Datagram{cmd: 4, address: <<station::little-unsigned-16, 0x30, 0x01>>}]
       }),
       do: station

  defp single_station_read_station(frame) do
    flunk("expected single-station FPRD frame, got: #{inspect(frame)}")
  end

  defp assert_single_station_read(frame, station) do
    assert single_station_read_station(frame) == station
  end

  defp assert_sent_transport(interface) do
    assert_receive {:fake_transport_sent, ^interface, raw, payload, _tx_at}, 200
    assert {:ok, datagrams} = Frame.decode(payload)
    %{datagrams: datagrams, interface: interface, raw: raw}
  end

  defp fake_mac(interface) do
    hash = :erlang.phash2(interface, 0xFFFFFF)
    <<0x02, 0x00, hash::24>>
  end

  defp primary_payload(%{datagrams: datagrams}) do
    {:ok, payload} = Frame.encode(datagrams)
    payload
  end

  defp reply_ok(bus, sent_datagrams) do
    reply_with(bus, sent_datagrams, fn dg -> %{dg | wkc: 1} end)
  end

  defp reply_with(bus, %{datagrams: sent_datagrams, raw: raw}, fun) do
    response_datagrams = Enum.map(sent_datagrams, fun)
    {:ok, payload} = Frame.encode(response_datagrams)
    send(bus, {:fake_transport_payload, raw, payload, System.monotonic_time()})
  end

  defp reply_transport(bus, sent, fun, opts \\ [])

  defp reply_transport(bus, %{datagrams: datagrams, raw: raw}, fun, opts) do
    response_datagrams = Enum.map(datagrams, fun)
    {:ok, payload} = Frame.encode(response_datagrams)

    case Keyword.get(opts, :src_mac) do
      nil -> send(bus, {:fake_transport_payload, raw, payload, System.monotonic_time()})
      mac -> send(bus, {:fake_transport_payload, raw, payload, System.monotonic_time(), mac})
    end
  end

  defp reply_data_for_station(%Datagram{
         address: <<0x1000::little-unsigned-16, _::little-unsigned-16>>
       }),
       do: <<0xAA, 0x00>>

  defp reply_data_for_station(%Datagram{
         address: <<0x1001::little-unsigned-16, _::little-unsigned-16>>
       }),
       do: <<0xBB, 0x00>>

  def handle_telemetry_event(event, measurements, metadata, pid) do
    send(pid, {:telemetry_event, event, measurements, metadata})
  end

  defp assert_submission_enqueued(expected, link_name, timeout \\ 500)

  defp assert_submission_enqueued(expected, link_name, timeout)
       when is_list(expected) and is_binary(link_name) do
    do_assert_submission_enqueued(
      Enum.map(expected, &normalize_submission(&1, link_name)),
      timeout,
      nil
    )
  end

  defp do_assert_submission_enqueued([], _timeout, matched_at_us),
    do: matched_at_us || System.monotonic_time(:microsecond)

  defp do_assert_submission_enqueued(expected, timeout, matched_at_us) do
    receive do
      {:telemetry_event, @submission_enqueued_event, %{queue_depth: queue_depth}, metadata} ->
        case pop_expected_submission(expected, {metadata.class, queue_depth, metadata.link}) do
          {:ok, remaining_expected} ->
            do_assert_submission_enqueued(
              remaining_expected,
              timeout,
              System.monotonic_time(:microsecond)
            )

          :error ->
            do_assert_submission_enqueued(expected, timeout, matched_at_us)
        end
    after
      timeout ->
        flunk("expected submission telemetry #{inspect(expected)}")
    end
  end

  defp pop_expected_submission(expected, actual) do
    case Enum.split_while(expected, &(&1 != trim_submission(actual))) do
      {_, []} -> :error
      {prefix, [_match | suffix]} -> {:ok, prefix ++ suffix}
    end
  end

  defp normalize_submission({class, queue_depth, link}, _default_link),
    do: {class, queue_depth, link}

  defp normalize_submission({class, queue_depth}, default_link),
    do: {class, queue_depth, default_link}

  defp trim_submission({class, queue_depth, link}), do: {class, queue_depth, link}

  defp wait_until_elapsed_us(start_us, target_elapsed_us) do
    remaining_us = target_elapsed_us - (System.monotonic_time(:microsecond) - start_us)

    if remaining_us > 0 do
      receive do
      after
        max(div(remaining_us, 1_000), 0) -> wait_until_elapsed_us(start_us, target_elapsed_us)
      end
    else
      :ok
    end
  end
end
