defmodule EtherCAT.BusTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Bus
  alias EtherCAT.Bus.{Datagram, Frame, Transaction}
  alias EtherCAT.Bus.Link.Redundant
  import EtherCAT.Integration.Assertions

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

  defmodule FakeLink do
    @behaviour EtherCAT.Bus.Link

    import Kernel, except: [send: 2]

    defstruct [:name, :owner, :test_pid]

    @impl true
    def open(opts) do
      {:ok,
       %__MODULE__{
         name: Keyword.get(opts, :link_name, "fake"),
         owner: self(),
         test_pid: Keyword.fetch!(opts, :test_pid)
       }}
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
    def drain(%__MODULE__{test_pid: test_pid} = link) do
      Kernel.send(test_pid, :fake_link_drained)
      link
    end

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
    def name(%__MODULE__{name: name}), do: name

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
    def rearm(%__MODULE__{}), do: :ok

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
    refute_receive {:fake_link_sent, _, _}
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
    assert [%Datagram{cmd: 4}] = realtime_frame
    reply_with(bus, realtime_frame, fn dg -> %{dg | data: <<0x34, 0x12>>, wkc: 1} end)

    reliable_frame = assert_sent_frame()
    assert [%Datagram{cmd: 5}] = reliable_frame
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
      for station <- reliable_stations do
        Task.async(fn -> Bus.transaction(bus, Transaction.fprd(station, {0x0130, 2})) end)
      end

    realtime_tasks =
      for station <- realtime_stations do
        Task.async(fn ->
          Bus.transaction(bus, Transaction.fprd(station, {0x0130, 2}), 100_000)
        end)
      end

    assert_submission_enqueued(
      Enum.map(1..length(reliable_tasks), &{:reliable, &1}) ++
        Enum.map(1..length(realtime_tasks), &{:realtime, &1}),
      link_name
    )

    reply_ok(bus, first_frame)

    first_realtime_frame = assert_sent_frame()
    assert_single_station_read(first_realtime_frame, 0x3000)

    late_realtime =
      Task.async(fn ->
        Bus.transaction(bus, Transaction.fprd(0x3003, {0x0130, 2}), 100_000)
      end)

    assert_submission_enqueued([{:realtime, 3}], link_name)

    reply_with(bus, first_realtime_frame, fn dg -> %{dg | data: <<0xA0, 0x00>>, wkc: 1} end)

    second_realtime_frame = assert_sent_frame()
    assert_single_station_read(second_realtime_frame, 0x3001)
    reply_with(bus, second_realtime_frame, fn dg -> %{dg | data: <<0xA1, 0x00>>, wkc: 1} end)

    third_realtime_frame = assert_sent_frame()
    assert_single_station_read(third_realtime_frame, 0x3002)
    reply_with(bus, third_realtime_frame, fn dg -> %{dg | data: <<0xA2, 0x00>>, wkc: 1} end)

    fourth_realtime_frame = assert_sent_frame()
    assert_single_station_read(fourth_realtime_frame, 0x3003)
    reply_with(bus, fourth_realtime_frame, fn dg -> %{dg | data: <<0xA3, 0x00>>, wkc: 1} end)

    reliable_batch_frame = assert_sent_frame()
    assert length(reliable_batch_frame) == length(reliable_stations)
    assert Enum.all?(reliable_batch_frame, &match?(%Datagram{cmd: 4}, &1))

    reply_with(bus, reliable_batch_frame, fn dg ->
      <<station::little-unsigned-16, _offset::little-unsigned-16>> = dg.address
      %{dg | data: <<station - 0x2000, 0x00>>, wkc: 1}
    end)

    assert {:ok, [%{wkc: 1}]} = Task.await(first)

    assert [
             {:ok, [%{data: <<0xA0, 0x00>>, wkc: 1}]},
             {:ok, [%{data: <<0xA1, 0x00>>, wkc: 1}]},
             {:ok, [%{data: <<0xA2, 0x00>>, wkc: 1}]}
           ] = Enum.map(realtime_tasks, &Task.await/1)

    assert {:ok, [%{data: <<0xA3, 0x00>>, wkc: 1}]} = Task.await(late_realtime)

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
    assert length(batch_frame) == 2

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
    refute_receive {:fake_link_sent, _, _}

    small = Task.async(fn -> Bus.transaction(bus, Transaction.brd({0x0000, 1})) end)
    small_frame = assert_sent_frame()
    reply_ok(bus, small_frame)

    assert {:ok, [%{wkc: 1}]} = Task.await(small)
  end

  test "redundant link keeps the processed forward-path reply over the reverse passthrough copy" do
    {:ok, bus} = start_redundant_bus()

    read = Task.async(fn -> Bus.transaction(bus, Transaction.fprd(0x1000, {0x0130, 2})) end)

    primary = assert_sent_transport("pri")
    secondary = assert_sent_transport("sec")

    # In a healthy ring, the primary port receives the secondary-originated
    # reverse-path copy unchanged, while the secondary port receives the
    # processed forward-path reply.
    reply_transport(bus, primary, fn dg -> %{dg | wkc: 0} end)
    refute_receive {:fake_transport_sent, _, _, _, _}, 20

    reply_transport(bus, secondary, fn dg -> %{dg | data: <<0x22, 0x22>>, wkc: 1} end)

    assert {:ok, [%{data: <<0x22, 0x22>>, wkc: 1}]} = Task.await(read)
  end

  test "redundant link merges complementary logical data from both sides of a break" do
    {:ok, bus} = start_redundant_bus()

    original = <<0xF0, 0xF1, 0xF2, 0xF3>>

    read =
      Task.async(fn ->
        Bus.transaction(bus, Transaction.lrw({0x0000, original}))
      end)

    primary = assert_sent_transport("pri")
    secondary = assert_sent_transport("sec")

    # Primary-originated frame processes the left half and bounces back to
    # primary. Secondary-originated frame reaches the break in reverse, then
    # processes the right half on the way back to secondary.
    reply_transport(bus, primary, fn dg -> %{dg | data: <<0x10, 0x11, 0xF2, 0xF3>>, wkc: 2} end)
    refute_receive {:fake_transport_sent, _, _, _, _}, 20
    reply_transport(bus, secondary, fn dg -> %{dg | data: <<0xF0, 0xF1, 0x12, 0x13>>, wkc: 2} end)

    assert {:ok, [%{data: <<0x10, 0x11, 0x12, 0x13>>, wkc: 4}]} = Task.await(read)
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
    {:ok, bus, link_name} = start_bus()

    assert {:ok,
            %{
              state: :idle,
              link: ^link_name,
              carrier_up: false,
              frame_timeout_ms: 50,
              link_monitor_mode: :disabled,
              timeout_count: 0,
              last_down_reason: nil,
              queue_depths: %{realtime: 0, reliable: 0},
              in_flight: nil
            }} = Bus.info(bus)

    read = Task.async(fn -> Bus.transaction(bus, Transaction.fprd(0x1000, {0x0130, 2})) end)
    assert_sent_frame()

    send(bus, {:ethercat_link, "eth0", true, false})
    assert {:error, :down} = Task.await(read)

    assert {:ok, %{state: :down, carrier_up: false}} = Bus.info(bus)
    assert {:ok, %{state: :down, last_down_reason: :carrier_lost}} = Bus.info(bus)

    while_down = Task.async(fn -> Bus.transaction(bus, Transaction.fprd(0x1000, {0x0130, 2})) end)
    assert {:error, :down} = Task.await(while_down)

    send(bus, {:ethercat_link, "eth0", false, true})

    assert_eventually(fn ->
      assert {:ok, %{state: :idle, carrier_up: false}} = Bus.info(bus)
    end)

    assert {:ok, %{state: :idle, carrier_up: false}} = Bus.info(bus)

    after_restore =
      Task.async(fn -> Bus.transaction(bus, Transaction.fprd(0x1000, {0x0130, 2})) end)

    restored_frame = assert_sent_frame()
    reply_with(bus, restored_frame, fn dg -> %{dg | data: <<0x12, 0x34>>, wkc: 1} end)

    assert {:ok, [%{data: <<0x12, 0x34>>, wkc: 1}]} = Task.await(after_restore)
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
    assert_receive :fake_link_drained
  end

  test "settle waits for the current in-flight transaction before draining" do
    {:ok, bus, _link_name} = start_bus()

    read = Task.async(fn -> Bus.transaction(bus, Transaction.fprd(0x1000, {0x0130, 2})) end)
    sent = assert_sent_frame()

    settle = Task.async(fn -> Bus.settle(bus) end)

    refute Task.yield(settle, 10)
    refute_receive :fake_link_drained, 10

    reply_with(bus, sent, fn dg -> %{dg | data: <<0x12, 0x34>>, wkc: 1} end)

    assert {:ok, [%{data: <<0x12, 0x34>>, wkc: 1}]} = Task.await(read)
    assert :ok = Task.await(settle)
    assert_receive :fake_link_drained
  end

  test "quiesce drains before and after the quiet window" do
    {:ok, bus, _link_name} = start_bus()

    assert :ok = Bus.quiesce(bus, 1)
    assert_receive :fake_link_drained
    assert_receive :fake_link_drained
  end

  defp start_bus(opts \\ []) do
    link_name = "fake_#{System.unique_integer([:positive, :monotonic])}"

    case Bus.start_link(
           Keyword.merge(
             [
               link_mod: FakeLink,
               transport: :udp,
               test_pid: self(),
               link_name: link_name,
               frame_timeout_ms: 50
             ],
             opts
           )
         ) do
      {:ok, bus} -> {:ok, bus, link_name}
      error -> error
    end
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

  defp assert_single_station_read(
         [%Datagram{cmd: 4, address: <<station::little-unsigned-16, 0x30, 0x01>>}],
         station
       ),
       do: :ok

  defp assert_single_station_read(datagrams, station) do
    flunk("expected single FPRD frame for station #{station}, got: #{inspect(datagrams)}")
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
