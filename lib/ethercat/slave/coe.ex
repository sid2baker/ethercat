defmodule EtherCAT.Slave.CoE.Download do
  @moduledoc false

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          subindex: non_neg_integer(),
          data: binary(),
          offset: non_neg_integer(),
          remaining: non_neg_integer(),
          toggle: 0 | 1,
          mailbox_counter: 0..7
        }

  @enforce_keys [:index, :subindex, :data, :remaining, :mailbox_counter]
  defstruct [:index, :subindex, :data, :remaining, :mailbox_counter, offset: 0, toggle: 0]
end

defmodule EtherCAT.Slave.CoE.Upload do
  @moduledoc false

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          subindex: non_neg_integer(),
          data_rev: [binary()],
          size: non_neg_integer() | nil,
          toggle: 0 | 1,
          mailbox_counter: 0..7
        }

  @enforce_keys [:index, :subindex, :mailbox_counter]
  defstruct [:index, :subindex, :size, :mailbox_counter, data_rev: [], toggle: 0]
end

defmodule EtherCAT.Slave.CoE do
  @moduledoc """
  CANopen over EtherCAT (CoE) mailbox protocol.

  Implements blocking SDO download/upload transfers over the mailbox SyncManagers.
  The transfer mode is selected internally:

  - expedited for small payloads
  - normal + segmented for larger payloads

  This module stays procedural and synchronous because it is currently used from
  slave PREOP configuration paths, not as a standalone mailbox state machine.

  This is the runtime CoE transport/protocol layer. For the small driver-facing
  helper that builds common `0x1C32` / `0x1C33` mailbox steps, see
  `EtherCAT.Slave.Sync.CoE`.
  """

  alias EtherCAT.Bus
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.Slave.CoE.{Download, Upload}
  alias EtherCAT.Slave.Registers

  @mailbox_type_coe 0x03
  @mailbox_type_error 0x00
  @service_sdo_request 0x02
  @service_sdo_response 0x03

  @command_abort 0x80
  @command_upload_init_request 0x40
  @command_upload_segment_request 0x60
  @command_download_init 0x21

  @poll_limit 1000
  @poll_interval_ms 1

  @mailbox_header_size 6
  @init_request_overhead 16
  @segment_request_overhead 9

  @type mailbox_config :: %{
          required(:recv_offset) => non_neg_integer(),
          required(:recv_size) => pos_integer(),
          required(:send_offset) => non_neg_integer(),
          required(:send_size) => pos_integer()
        }

  @spec next_mailbox_counter(0..7) :: 1..7
  def next_mailbox_counter(counter) when is_integer(counter) and counter >= 0 and counter <= 7 do
    next = counter + 1

    if next > 7 do
      1
    else
      next
    end
  end

  @doc """
  Download an SDO value of any size.

  `mailbox_counter` is the last mailbox counter used for this slave. The return
  value includes the final counter after the full transfer.
  """
  @spec download_sdo(
          pid(),
          non_neg_integer(),
          mailbox_config(),
          0..7,
          non_neg_integer(),
          non_neg_integer(),
          binary()
        ) :: {:ok, 1..7} | {:error, term()}
  def download_sdo(bus, station, mailbox_config, mailbox_counter, index, subindex, data)
      when is_binary(data) and byte_size(data) > 0 do
    transfer = %Download{
      index: index,
      subindex: subindex,
      data: data,
      remaining: byte_size(data),
      mailbox_counter: mailbox_counter
    }

    if expedited_download?(data) do
      do_expedited_download(bus, station, mailbox_config, transfer)
    else
      do_segmented_download(bus, station, mailbox_config, transfer)
    end
  end

  @doc """
  Upload an SDO value of any size.

  Returns the full payload and the final mailbox counter.
  """
  @spec upload_sdo(
          pid(),
          non_neg_integer(),
          mailbox_config(),
          0..7,
          non_neg_integer(),
          non_neg_integer()
        ) :: {:ok, binary(), 1..7} | {:error, term()}
  def upload_sdo(bus, station, mailbox_config, mailbox_counter, index, subindex) do
    next_counter = next_mailbox_counter(mailbox_counter)

    with {:ok, response} <-
           exchange_mailbox(
             bus,
             station,
             mailbox_config,
             build_upload_init_request_frame(index, subindex, next_counter)
           ),
         {:ok, result} <- parse_upload_init_response(response, next_counter, index, subindex) do
      finalize_upload(bus, station, mailbox_config, next_counter, index, subindex, result)
    end
  end

  defp expedited_download?(data), do: byte_size(data) <= 4

  defp do_expedited_download(bus, station, mailbox_config, %Download{} = transfer) do
    next_counter = next_mailbox_counter(transfer.mailbox_counter)

    with {:ok, response} <-
           exchange_mailbox(
             bus,
             station,
             mailbox_config,
             build_expedited_download_frame(
               transfer.index,
               transfer.subindex,
               transfer.data,
               next_counter
             )
           ),
         :ok <-
           validate_download_init_response(
             response,
             next_counter,
             transfer.index,
             transfer.subindex
           ) do
      {:ok, next_counter}
    end
  end

  defp do_segmented_download(bus, station, mailbox_config, %Download{} = transfer) do
    with {:ok, init_size} <- initial_download_capacity(mailbox_config),
         next_counter <- next_mailbox_counter(transfer.mailbox_counter),
         init_data <- take_binary(transfer.data, 0, init_size),
         init_remaining <- byte_size(transfer.data) - byte_size(init_data),
         {:ok, response} <-
           exchange_mailbox(
             bus,
             station,
             mailbox_config,
             build_download_init_frame(
               transfer.index,
               transfer.subindex,
               transfer.data,
               init_data,
               next_counter
             )
           ),
         :ok <-
           validate_download_init_response(
             response,
             next_counter,
             transfer.index,
             transfer.subindex
           ) do
      segment_download(
        bus,
        station,
        mailbox_config,
        %Download{
          transfer
          | offset: byte_size(init_data),
            remaining: init_remaining,
            mailbox_counter: next_counter
        }
      )
    end
  end

  defp segment_download(_bus, _station, _mailbox_config, %Download{
         remaining: 0,
         mailbox_counter: counter
       }) do
    {:ok, counter}
  end

  defp segment_download(bus, station, mailbox_config, %Download{} = transfer) do
    with {:ok, segment_size} <- segment_download_capacity(mailbox_config),
         chunk_size <- min(segment_size, transfer.remaining),
         chunk <- take_binary(transfer.data, transfer.offset, chunk_size),
         next_counter <- next_mailbox_counter(transfer.mailbox_counter),
         last_segment? <- transfer.remaining == chunk_size,
         {:ok, response} <-
           exchange_mailbox(
             bus,
             station,
             mailbox_config,
             build_download_segment_frame(chunk, last_segment?, transfer.toggle, next_counter)
           ),
         :ok <- validate_download_segment_response(response, next_counter, transfer.toggle) do
      next_transfer = %Download{
        transfer
        | offset: transfer.offset + chunk_size,
          remaining: transfer.remaining - chunk_size,
          toggle: flip_toggle(transfer.toggle),
          mailbox_counter: next_counter
      }

      segment_download(bus, station, mailbox_config, next_transfer)
    end
  end

  defp finalize_upload(
         _bus,
         _station,
         _mailbox_config,
         mailbox_counter,
         _index,
         _subindex,
         {:expedited, data}
       ) do
    {:ok, data, mailbox_counter}
  end

  defp finalize_upload(
         _bus,
         _station,
         _mailbox_config,
         mailbox_counter,
         _index,
         _subindex,
         {:normal, data}
       ) do
    {:ok, data, mailbox_counter}
  end

  defp finalize_upload(
         bus,
         station,
         mailbox_config,
         mailbox_counter,
         index,
         subindex,
         {:segmented, %Upload{} = upload}
       ) do
    segment_upload(
      bus,
      station,
      mailbox_config,
      %Upload{upload | mailbox_counter: mailbox_counter, index: index, subindex: subindex}
    )
  end

  defp segment_upload(bus, station, mailbox_config, %Upload{} = upload) do
    next_counter = next_mailbox_counter(upload.mailbox_counter)

    with {:ok, response} <-
           exchange_mailbox(
             bus,
             station,
             mailbox_config,
             build_upload_segment_request_frame(
               upload.index,
               upload.subindex,
               upload.toggle,
               next_counter
             )
           ),
         {:ok, segment, last_segment?} <-
           parse_upload_segment_response(response, next_counter, upload.toggle) do
      next_upload = %Upload{
        upload
        | data_rev: [segment | upload.data_rev],
          toggle: flip_toggle(upload.toggle),
          mailbox_counter: next_counter
      }

      if last_segment? do
        data = :erlang.iolist_to_binary(Enum.reverse(next_upload.data_rev))

        case next_upload.size do
          nil ->
            {:ok, data, next_counter}

          size when byte_size(data) == size ->
            {:ok, data, next_counter}

          size when byte_size(data) > size ->
            {:ok, binary_part(data, 0, size), next_counter}

          size ->
            {:error, {:upload_size_mismatch, size, byte_size(data)}}
        end
      else
        segment_upload(bus, station, mailbox_config, next_upload)
      end
    end
  end

  defp build_expedited_download_frame(index, subindex, data, mailbox_counter) do
    command = expedited_download_command(byte_size(data))
    padded = data <> :binary.copy(<<0>>, 4 - byte_size(data))

    build_mailbox_frame(
      mailbox_counter,
      build_sdo_request_payload(<<command::8, index::16-little, subindex::8, padded::binary>>)
    )
  end

  defp build_download_init_frame(index, subindex, full_data, init_data, mailbox_counter) do
    payload =
      build_sdo_request_payload(
        <<@command_download_init::8, index::16-little, subindex::8,
          byte_size(full_data)::32-little, init_data::binary>>
      )

    build_mailbox_frame(mailbox_counter, payload)
  end

  defp build_download_segment_frame(data, last_segment?, toggle, mailbox_counter) do
    {chunk, padding_count} =
      if last_segment? and byte_size(data) < 7 do
        {data <> :binary.copy(<<0>>, 7 - byte_size(data)), 7 - byte_size(data)}
      else
        {data, 0}
      end

    last_flag = if last_segment?, do: 1, else: 0
    command = last_flag + padding_count * 2 + toggle * 16

    build_mailbox_frame(
      mailbox_counter,
      <<sdo_request_service()::binary, command::8, chunk::binary>>
    )
  end

  defp build_upload_init_request_frame(index, subindex, mailbox_counter) do
    build_mailbox_frame(
      mailbox_counter,
      build_sdo_request_payload(
        <<@command_upload_init_request::8, index::16-little, subindex::8, 0::32-little>>
      )
    )
  end

  defp build_upload_segment_request_frame(index, subindex, toggle, mailbox_counter) do
    command = @command_upload_segment_request + toggle * 16

    build_mailbox_frame(
      mailbox_counter,
      build_sdo_request_payload(<<command::8, index::16-little, subindex::8, 0::32-little>>)
    )
  end

  defp build_mailbox_frame(mailbox_counter, payload) do
    <<byte_size(payload)::16-little, 0::16-little, 0::8, mailbox_type(mailbox_counter)::8,
      payload::binary>>
  end

  defp build_sdo_request_payload(body), do: <<sdo_request_service()::binary, body::binary>>

  defp sdo_request_service, do: <<@service_sdo_request * 4096::16-little>>

  defp mailbox_type(counter), do: counter * 16 + @mailbox_type_coe

  defp expedited_download_command(1), do: 0x2F
  defp expedited_download_command(2), do: 0x2B
  defp expedited_download_command(3), do: 0x27
  defp expedited_download_command(4), do: 0x23

  defp initial_download_capacity(%{recv_size: recv_size})
       when recv_size >= @init_request_overhead do
    {:ok, recv_size - @init_request_overhead}
  end

  defp initial_download_capacity(_mailbox_config), do: {:error, :mailbox_too_small}

  defp segment_download_capacity(%{recv_size: recv_size})
       when recv_size > @segment_request_overhead do
    {:ok, recv_size - @segment_request_overhead}
  end

  defp segment_download_capacity(_mailbox_config), do: {:error, :mailbox_too_small}

  defp exchange_mailbox(bus, station, mailbox_config, frame) do
    with {:ok, padded} <- pad_mailbox_frame(frame, mailbox_config.recv_size),
         :ok <- write_mailbox(bus, station, mailbox_config.recv_offset, padded),
         :ok <- wait_response(bus, station),
         {:ok, response} <-
           read_mailbox(bus, station, mailbox_config.send_offset, mailbox_config.send_size) do
      {:ok, response}
    end
  end

  defp pad_mailbox_frame(frame, recv_size) when byte_size(frame) <= recv_size do
    {:ok, frame <> :binary.copy(<<0>>, recv_size - byte_size(frame))}
  end

  defp pad_mailbox_frame(_frame, _recv_size), do: {:error, :mailbox_too_small}

  defp write_mailbox(bus, station, recv_offset, frame) do
    case Bus.transaction(bus, Transaction.fpwr(station, {recv_offset, frame})) do
      {:ok, [%{wkc: wkc}]} when wkc > 0 -> :ok
      {:ok, [%{wkc: 0}]} -> {:error, :no_response}
      {:error, _} = err -> err
    end
  end

  defp wait_response(bus, station), do: wait_response(bus, station, @poll_limit)

  defp wait_response(_bus, _station, 0), do: {:error, :response_timeout}

  defp wait_response(bus, station, remaining) do
    case Bus.transaction(bus, Transaction.fprd(station, Registers.sm_status(1))) do
      {:ok, [%{data: <<status::8>>, wkc: wkc}]} when wkc > 0 ->
        case <<status::8>> do
          <<_::4, 1::1, _::3>> ->
            :ok

          _ ->
            Process.sleep(@poll_interval_ms)
            wait_response(bus, station, remaining - 1)
        end

      {:ok, [%{wkc: 0}]} ->
        {:error, :no_response}

      {:error, _} = err ->
        err
    end
  end

  defp read_mailbox(bus, station, send_offset, send_size) do
    case Bus.transaction(bus, Transaction.fprd(station, {send_offset, send_size})) do
      {:ok, [%{data: data, wkc: wkc}]} when wkc > 0 ->
        trim_mailbox_frame(data)

      {:ok, [%{wkc: 0}]} ->
        {:error, :no_response}

      {:error, _} = err ->
        err
    end
  end

  defp trim_mailbox_frame(
         <<payload_length::16-little, _address::16-little, _channel::8, _type::8, _::binary>> =
           frame
       ) do
    total_size = @mailbox_header_size + payload_length

    if byte_size(frame) >= total_size do
      {:ok, binary_part(frame, 0, total_size)}
    else
      {:error, :truncated_mailbox_response}
    end
  end

  defp trim_mailbox_frame(_frame), do: {:error, :invalid_mailbox_response}

  defp validate_download_init_response(response, expected_counter, index, subindex) do
    with {:ok, body} <- sdo_response_body(response, expected_counter) do
      case body do
        <<0x60, ^index::16-little, ^subindex::8, _::binary>> ->
          :ok

        <<@command_abort, ^index::16-little, ^subindex::8, abort_code::32-little, _::binary>> ->
          {:error, {:sdo_abort, index, subindex, abort_code}}

        _ ->
          {:error, {:unexpected_sdo_response, index, subindex, response}}
      end
    end
  end

  defp validate_download_segment_response(response, expected_counter, expected_toggle) do
    with {:ok, body} <- sdo_response_body(response, expected_counter) do
      case body do
        <<0::2, 1::1, toggle::1, _::4, _rest::binary>> when toggle == expected_toggle ->
          :ok

        <<0::2, 1::1, toggle::1, _::4, _rest::binary>> ->
          {:error, {:toggle_mismatch, expected_toggle, toggle}}

        <<@command_abort, _::16-little, _::8, abort_code::32-little, _::binary>> ->
          {:error, {:sdo_abort, abort_code}}

        _ ->
          {:error, {:unexpected_sdo_segment_response, response}}
      end
    end
  end

  defp parse_upload_init_response(response, expected_counter, index, subindex) do
    with {:ok, body} <- sdo_response_body(response, expected_counter) do
      case body do
        <<@command_abort, ^index::16-little, ^subindex::8, abort_code::32-little, _::binary>> ->
          {:error, {:sdo_abort, index, subindex, abort_code}}

        <<command::8, ^index::16-little, ^subindex::8, response_payload::binary>> ->
          parse_upload_init_payload(command, index, subindex, response_payload, response)

        _ ->
          {:error, {:unexpected_sdo_response, index, subindex, response}}
      end
    end
  end

  defp parse_upload_init_payload(command, index, subindex, data, _response)
       when byte_size(data) >= 4 do
    case {expedited_upload_response?(command), normal_upload_response?(command)} do
      {true, _} ->
        <<expedited::binary-size(4), _::binary>> = data
        {:ok, {:expedited, expedited_upload_data(command, expedited)}}

      {false, true} ->
        <<size::32-little, initial::binary>> = data

        if byte_size(initial) >= size do
          {:ok, {:normal, binary_part(initial, 0, size)}}
        else
          {:ok,
           {:segmented,
            %Upload{
              index: index,
              subindex: subindex,
              size: size,
              data_rev: [initial],
              mailbox_counter: 0
            }}}
        end

      _ ->
        {:error, {:unexpected_sdo_command, command}}
    end
  end

  defp parse_upload_init_payload(_command, index, subindex, _data, response) do
    {:error, {:unexpected_sdo_response, index, subindex, response}}
  end

  defp parse_upload_segment_response(response, expected_counter, expected_toggle) do
    with {:ok, body} <- sdo_response_body(response, expected_counter) do
      case body do
        <<0::3, toggle::1, unused::3, last::1, segment::binary>> when toggle == expected_toggle ->
          last_segment? = last == 1
          segment_size = valid_segment_size(byte_size(segment), last_segment?, unused)

          if is_integer(segment_size) do
            {:ok, binary_part(segment, 0, segment_size), last_segment?}
          else
            {:error, segment_size}
          end

        <<0::3, toggle::1, _::3, _::1, _::binary>> ->
          {:error, {:toggle_mismatch, expected_toggle, toggle}}

        <<@command_abort, _::16-little, _::8, abort_code::32-little, _::binary>> ->
          {:error, {:sdo_abort, abort_code}}

        _ ->
          {:error, {:unexpected_sdo_segment_response, response}}
      end
    end
  end

  defp sdo_response_body(response, expected_counter) do
    with {:ok, mailbox_frame} <- parse_mailbox_frame(response),
         :ok <- validate_mailbox_counter(mailbox_frame, expected_counter),
         {:ok, payload} <- require_coe_payload(mailbox_frame),
         {:ok, body} <- require_sdo_response(payload) do
      {:ok, body}
    end
  end

  defp parse_mailbox_frame(
         <<payload_length::16-little, _address::16-little, _channel::8, mailbox_type::8,
           payload::binary-size(payload_length)>>
       ) do
    {:ok,
     %{
       type: rem(mailbox_type, 16),
       counter: div(mailbox_type, 16),
       payload: payload
     }}
  end

  defp parse_mailbox_frame(_frame), do: {:error, :invalid_mailbox_response}

  defp validate_mailbox_counter(%{counter: expected_counter}, expected_counter), do: :ok

  defp validate_mailbox_counter(%{counter: counter}, expected_counter) do
    {:error, {:unexpected_mailbox_counter, expected_counter, counter}}
  end

  defp require_coe_payload(%{type: @mailbox_type_coe, payload: payload}), do: {:ok, payload}

  defp require_coe_payload(%{type: @mailbox_type_error, payload: payload}),
    do: {:error, {:mailbox_error, payload}}

  defp require_coe_payload(%{type: type}), do: {:error, {:unexpected_mailbox_type, type}}

  defp require_sdo_response(<<service::16-little, body::binary>>) do
    if div(service, 4096) == @service_sdo_response do
      {:ok, body}
    else
      {:error, {:unexpected_coe_service, div(service, 4096)}}
    end
  end

  defp require_sdo_response(_payload), do: {:error, :invalid_coe_response}

  defp expedited_upload_response?(command) do
    case <<command::8>> do
      <<0::1, 1::1, 0::1, _::1, _unused::2, 1::1, _::1>> -> true
      _ -> false
    end
  end

  defp normal_upload_response?(command) do
    case <<command::8>> do
      <<0::1, 1::1, 0::1, _::1, _unused::2, 0::1, _::1>> -> true
      _ -> false
    end
  end

  defp expedited_upload_data(command, data) do
    <<0::1, 1::1, 0::1, _::1, unused::2, _::1, size_indicated::1>> = <<command::8>>
    actual_size = if size_indicated == 1, do: 4 - unused, else: 4
    binary_part(data, 0, actual_size)
  end

  defp valid_segment_size(size, false, _unused), do: size

  defp valid_segment_size(size, true, unused) when unused <= size do
    size - unused
  end

  defp valid_segment_size(_size, true, unused), do: {:invalid_segment_padding, unused}

  defp take_binary(_data, _offset, 0), do: <<>>
  defp take_binary(data, offset, length), do: binary_part(data, offset, length)

  defp flip_toggle(0), do: 1
  defp flip_toggle(1), do: 0
end
