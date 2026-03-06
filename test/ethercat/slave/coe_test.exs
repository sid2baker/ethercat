defmodule EtherCAT.Slave.CoETest do
  use ExUnit.Case, async: true

  alias EtherCAT.Bus.Transaction
  alias EtherCAT.Slave.CoE

  defmodule FakeBus do
    use GenServer

    def start_link(responses) do
      GenServer.start_link(__MODULE__, responses)
    end

    def calls(pid) do
      GenServer.call(pid, :calls)
    end

    @impl true
    def init(responses) do
      {:ok, %{responses: responses, calls_rev: []}}
    end

    @impl true
    def handle_call(
          {:transact, tx, _deadline_us, _enqueued_at_us},
          _from,
          %{responses: [reply | rest], calls_rev: calls_rev} = state
        ) do
      {:reply, reply, %{state | responses: rest, calls_rev: [tx | calls_rev]}}
    end

    def handle_call({:transact, _tx, _deadline_us, _enqueued_at_us}, _from, state) do
      {:reply, {:error, :unexpected_transaction}, state}
    end

    def handle_call(:calls, _from, %{calls_rev: calls_rev} = state) do
      {:reply, Enum.reverse(calls_rev), state}
    end
  end

  defmodule SegmentedMailboxDriver do
    @behaviour EtherCAT.Slave.Driver

    @impl true
    def process_data_model(_config), do: %{}

    @impl true
    def encode_signal(_signal, _config, _value), do: <<>>

    @impl true
    def decode_signal(_signal, _config, raw), do: raw

    @impl true
    def mailbox_config(_config) do
      [{:sdo_download, 0x2000, 0x01, <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12>>}]
    end
  end

  defmodule SyncModeDriver do
    @behaviour EtherCAT.Slave.Driver

    @impl true
    def process_data_model(_config), do: %{}

    @impl true
    def encode_signal(_signal, _config, _value), do: <<>>

    @impl true
    def decode_signal(_signal, _config, raw), do: raw

    @impl true
    def sync_mode(_config, _sync) do
      [{:sdo_download, 0x1C32, 0x01, <<1, 0, 0, 0>>}]
    end
  end

  @mailbox_config %{recv_offset: 0x1000, recv_size: 20, send_offset: 0x1200, send_size: 32}
  @station 0x1000

  test "download_sdo uses expedited transfer for small payloads" do
    bus =
      start_supervised!({
        FakeBus,
        [
          write_ok(),
          mailbox_ready(),
          mailbox_read(download_init_ack(1, 0x2000, 0x01), @mailbox_config.send_size)
        ]
      })

    assert {:ok, 1} =
             CoE.download_sdo(bus, @station, @mailbox_config, 0, 0x2000, 0x01, <<0x34, 0x12>>)

    [request] = mailbox_write_requests(bus, @mailbox_config.recv_offset)

    assert request.counter == 1
    assert request.service == 0x2000
    assert request.body == <<0x2B, 0x00, 0x20, 0x01, 0x34, 0x12, 0x00, 0x00>>
  end

  test "download_sdo segments larger payloads and flips the toggle bit" do
    data = <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19>>

    bus =
      start_supervised!({
        FakeBus,
        [
          write_ok(),
          mailbox_ready(),
          mailbox_read(download_init_ack(1, 0x2000, 0x01), @mailbox_config.send_size),
          write_ok(),
          mailbox_ready(),
          mailbox_read(download_segment_ack(2, 0), @mailbox_config.send_size),
          write_ok(),
          mailbox_ready(),
          mailbox_read(download_segment_ack(3, 1), @mailbox_config.send_size)
        ]
      })

    assert {:ok, 3} = CoE.download_sdo(bus, @station, @mailbox_config, 0, 0x2000, 0x01, data)

    [init_request, segment_one, segment_two] =
      mailbox_write_requests(bus, @mailbox_config.recv_offset)

    assert init_request.counter == 1
    assert init_request.body == <<0x21, 0x00, 0x20, 0x01, 20::32-little, 0, 1, 2, 3>>

    assert segment_one.counter == 2
    assert segment_one.body == <<0x00, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14>>

    assert segment_two.counter == 3
    assert segment_two.body == <<0x15, 15, 16, 17, 18, 19, 0, 0>>
  end

  test "upload_sdo returns expedited payloads directly" do
    bus =
      start_supervised!({
        FakeBus,
        [
          write_ok(),
          mailbox_ready(),
          mailbox_read(
            upload_init_expedited_response(1, 0x3000, 0x02, <<0xAA, 0xBB>>),
            @mailbox_config.send_size
          )
        ]
      })

    assert {:ok, <<0xAA, 0xBB>>, 1} =
             CoE.upload_sdo(bus, @station, @mailbox_config, 0, 0x3000, 0x02)

    [request] = mailbox_write_requests(bus, @mailbox_config.recv_offset)

    assert request.counter == 1
    assert request.body == <<0x40, 0x00, 0x30, 0x02, 0::32-little>>
  end

  test "upload_sdo assembles segmented payloads" do
    bus =
      start_supervised!({
        FakeBus,
        [
          write_ok(),
          mailbox_ready(),
          mailbox_read(
            upload_init_segmented_response(1, 0x3000, 0x02, 10, <<1, 2>>),
            @mailbox_config.send_size
          ),
          write_ok(),
          mailbox_ready(),
          mailbox_read(
            upload_segment_response(2, 0, <<3, 4, 5, 6, 7, 8, 9>>, false),
            @mailbox_config.send_size
          ),
          write_ok(),
          mailbox_ready(),
          mailbox_read(upload_segment_response(3, 1, <<10>>, true), @mailbox_config.send_size)
        ]
      })

    assert {:ok, <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>, 3} =
             CoE.upload_sdo(bus, @station, @mailbox_config, 0, 0x3000, 0x02)

    [init_request, segment_request_one, segment_request_two] =
      mailbox_write_requests(bus, @mailbox_config.recv_offset)

    assert init_request.counter == 1
    assert init_request.body == <<0x40, 0x00, 0x30, 0x02, 0::32-little>>

    assert segment_request_one.counter == 2
    assert segment_request_one.body == <<0x60, 0x00, 0x30, 0x02, 0::32-little>>

    assert segment_request_two.counter == 3
    assert segment_request_two.body == <<0x70, 0x00, 0x30, 0x02, 0::32-little>>
  end

  test "download_sdo rejects mismatched mailbox counters" do
    bus =
      start_supervised!({
        FakeBus,
        [
          write_ok(),
          mailbox_ready(),
          mailbox_read(download_init_ack(2, 0x2000, 0x01), @mailbox_config.send_size)
        ]
      })

    assert {:error, {:unexpected_mailbox_counter, 1, 2}} =
             CoE.download_sdo(bus, @station, @mailbox_config, 0, 0x2000, 0x01, <<0x34, 0x12>>)
  end

  test "slave PREOP mailbox configuration supports segmented CoE downloads" do
    from = {self(), make_ref()}

    bus =
      start_supervised!({
        FakeBus,
        [
          write_ok(),
          mailbox_ready(),
          mailbox_read(download_init_ack(1, 0x2000, 0x01), @mailbox_config.send_size),
          write_ok(),
          mailbox_ready(),
          mailbox_read(download_segment_ack(2, 0), @mailbox_config.send_size)
        ]
      })

    assert {:keep_state, %EtherCAT.Slave{} = updated, [{:reply, ^from, :ok}]} =
             EtherCAT.Slave.handle_event(
               {:call, from},
               {:configure, []},
               :preop,
               %EtherCAT.Slave{
                 bus: bus,
                 station: @station,
                 name: :sensor,
                 driver: SegmentedMailboxDriver,
                 config: %{},
                 mailbox_config: @mailbox_config,
                 mailbox_counter: 0,
                 process_data_request: :none,
                 signal_registrations: %{},
                 subscriptions: %{},
                 sii_pdo_configs: [],
                 sii_sm_configs: []
               }
             )

    assert updated.configuration_error == nil
    assert updated.mailbox_counter == 2
  end

  test "slave PREOP mailbox configuration appends driver sync_mode steps" do
    from = {self(), make_ref()}

    bus =
      start_supervised!({
        FakeBus,
        [
          write_ok(),
          mailbox_ready(),
          mailbox_read(download_init_ack(1, 0x1C32, 0x01), @mailbox_config.send_size)
        ]
      })

    assert {:keep_state, %EtherCAT.Slave{} = updated, [{:reply, ^from, :ok}]} =
             EtherCAT.Slave.handle_event(
               {:call, from},
               {:configure, []},
               :preop,
               %EtherCAT.Slave{
                 bus: bus,
                 station: @station,
                 name: :axis,
                 driver: SyncModeDriver,
                 config: %{},
                 mailbox_config: @mailbox_config,
                 mailbox_counter: 0,
                 sync_config: %EtherCAT.Slave.Sync.Config{
                   mode: :sync0,
                   sync0: %{pulse_ns: 5_000, shift_ns: 0}
                 },
                 process_data_request: :none,
                 signal_registrations: %{},
                 subscriptions: %{},
                 sii_pdo_configs: [],
                 sii_sm_configs: []
               }
             )

    assert updated.configuration_error == nil
    assert updated.mailbox_counter == 1
  end

  defp write_ok, do: {:ok, [reply_datagram(<<>>)]}

  defp mailbox_ready, do: {:ok, [reply_datagram(<<0x08>>)]}

  defp mailbox_read(frame, send_size) do
    {:ok, [reply_datagram(pad_frame(frame, send_size))]}
  end

  defp download_init_ack(counter, index, subindex) do
    mailbox_frame(
      counter,
      coe_sdo_response(<<0x60, index::16-little, subindex::8, 0::32-little>>)
    )
  end

  defp download_segment_ack(counter, toggle) do
    mailbox_frame(counter, coe_sdo_response(<<download_segment_ack_command(toggle)::8, 0::56>>))
  end

  defp upload_init_expedited_response(counter, index, subindex, data) do
    padded = data <> :binary.copy(<<0>>, 4 - byte_size(data))
    unused = 4 - byte_size(data)
    command = 0x43 + unused * 4

    mailbox_frame(
      counter,
      coe_sdo_response(<<command::8, index::16-little, subindex::8, padded::binary>>)
    )
  end

  defp upload_init_segmented_response(counter, index, subindex, size, initial) do
    mailbox_frame(
      counter,
      coe_sdo_response(<<0x41, index::16-little, subindex::8, size::32-little, initial::binary>>)
    )
  end

  defp upload_segment_response(counter, toggle, data, last_segment?) do
    {segment, unused} =
      if last_segment? and byte_size(data) < 7 do
        {data <> :binary.copy(<<0>>, 7 - byte_size(data)), 7 - byte_size(data)}
      else
        {data, 0}
      end

    last_flag = if last_segment?, do: 1, else: 0
    command = toggle * 16 + unused * 2 + last_flag
    mailbox_frame(counter, coe_sdo_response(<<command::8, segment::binary>>))
  end

  defp download_segment_ack_command(toggle), do: 0x20 + toggle * 16

  defp mailbox_frame(counter, payload) do
    <<byte_size(payload)::16-little, 0::16-little, 0::8, mailbox_type(counter)::8,
      payload::binary>>
  end

  defp coe_sdo_response(body), do: <<0x3000::16-little, body::binary>>

  defp mailbox_type(counter), do: counter * 16 + 0x03

  defp pad_frame(frame, size) do
    frame <> :binary.copy(<<0>>, size - byte_size(frame))
  end

  defp mailbox_write_requests(bus, recv_offset) do
    bus
    |> FakeBus.calls()
    |> Enum.filter(&mailbox_write?(&1, recv_offset))
    |> Enum.map(&decode_mailbox_request/1)
  end

  defp mailbox_write?(tx, recv_offset) do
    case Transaction.datagrams(tx) do
      [%{cmd: 5, address: <<_station::16-little, ^recv_offset::16-little>>}] -> true
      _ -> false
    end
  end

  defp decode_mailbox_request(tx) do
    [%{data: data}] = Transaction.datagrams(tx)
    frame = trim_frame(data)

    <<_length::16-little, _address::16-little, _channel::8, mailbox_type::8, payload::binary>> =
      frame

    <<service::16-little, body::binary>> = payload

    %{
      counter: div(mailbox_type, 16),
      type: rem(mailbox_type, 16),
      service: service,
      body: body
    }
  end

  defp trim_frame(<<payload_length::16-little, _::16, _::8, _::8, _::binary>> = frame) do
    binary_part(frame, 0, payload_length + 6)
  end

  defp reply_datagram(data) do
    %{data: data, wkc: 1, circular: false, irq: 0}
  end
end
