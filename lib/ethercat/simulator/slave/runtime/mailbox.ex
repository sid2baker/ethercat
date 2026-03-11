defmodule EtherCAT.Simulator.Slave.Runtime.Mailbox do
  @moduledoc false

  alias EtherCAT.Simulator.Slave.Runtime.Device
  alias EtherCAT.Simulator.Slave.Runtime.Dictionary

  @mailbox_type_coe 0x03
  @service_sdo_request 0x02
  @service_sdo_response 0x03

  @command_abort 0x80
  @command_upload_init_request 0x40
  @command_download_init 0x21

  @abort_unsupported 0x0504_0001
  @abort_toggle_mismatch 0x0503_0000

  @type mailbox_config :: %{
          required(:recv_offset) => non_neg_integer(),
          required(:recv_size) => non_neg_integer(),
          required(:send_offset) => non_neg_integer(),
          required(:send_size) => non_neg_integer()
        }

  @spec handle_frame(binary(), Device.t()) :: {:ok, binary(), Device.t()} | :ignore
  def handle_frame(frame, %Device{} = slave) do
    with {:ok, request} <- parse_request(frame),
         {:ok, response_body, updated_slave} <- handle_request(request, slave) do
      response =
        request.counter
        |> mailbox_frame(sdo_response_service() <> response_body)
        |> pad_send_mailbox(updated_slave.mailbox_config.send_size)

      {:ok, response, updated_slave}
    else
      :ignore -> :ignore
    end
  end

  defp parse_request(
         <<payload_length::16-little, _address::16-little, _channel::8, mailbox_type::8,
           payload::binary-size(payload_length), _padding::binary>>
       ) do
    {:ok,
     %{
       counter: div(mailbox_type, 16),
       type: rem(mailbox_type, 16),
       service: mailbox_service(payload),
       body: mailbox_body(payload)
     }}
  end

  defp parse_request(_frame), do: :ignore

  defp handle_request(
         %{type: @mailbox_type_coe, service: @service_sdo_request, body: body} = request,
         slave
       ) do
    handle_sdo_request(body, request.counter, slave)
  end

  defp handle_request(_request, _slave), do: :ignore

  defp handle_sdo_request(
         <<@command_upload_init_request, index::16-little, subindex::8, _::32>>,
         mailbox_counter,
         slave
       ) do
    case Dictionary.read_entry(slave, index, subindex) do
      {:ok, data, updated_slave} when byte_size(data) <= 4 ->
        {:ok, expedited_upload_response(index, subindex, data), updated_slave}

      {:ok, data, updated_slave} ->
        init_size = max(updated_slave.mailbox_config.send_size - 16, 0)
        initial = binary_part(data, 0, min(init_size, byte_size(data)))
        remaining = binary_part(data, byte_size(initial), byte_size(data) - byte_size(initial))

        next_slave =
          %{
            updated_slave
            | mailbox_upload: upload_state(index, subindex, remaining, mailbox_counter)
          }

        {:ok, segmented_upload_init_response(index, subindex, byte_size(data), initial),
         next_slave}

      {:error, abort_code, updated_slave} ->
        {:ok, abort_response(index, subindex, abort_code), updated_slave}
    end
  end

  defp handle_sdo_request(
         <<command::8, index::16-little, subindex::8, payload::binary-size(4)>>,
         _mailbox_counter,
         slave
       )
       when command in [0x2F, 0x2B, 0x27, 0x23] do
    size = expedited_download_size(command)
    <<data::binary-size(size), _::binary>> = payload

    case Dictionary.write_entry(slave, index, subindex, data) do
      {:ok, updated_slave} ->
        {:ok, download_ack(index, subindex), updated_slave}

      {:error, abort_code, updated_slave} ->
        {:ok, abort_response(index, subindex, abort_code), updated_slave}
    end
  end

  defp handle_sdo_request(
         <<@command_download_init, index::16-little, subindex::8, total_size::32-little,
           initial::binary>>,
         mailbox_counter,
         slave
       ) do
    current = initial

    if byte_size(current) >= total_size do
      data = binary_part(current, 0, total_size)

      case Dictionary.write_entry(slave, index, subindex, data) do
        {:ok, updated_slave} ->
          {:ok, download_ack(index, subindex), updated_slave}

        {:error, abort_code, updated_slave} ->
          {:ok, abort_response(index, subindex, abort_code), updated_slave}
      end
    else
      next_slave = %{
        slave
        | mailbox_download: %{
            index: index,
            subindex: subindex,
            data: current,
            size: total_size,
            toggle: 0,
            mailbox_counter: mailbox_counter
          }
      }

      {:ok, download_ack(index, subindex), next_slave}
    end
  end

  defp handle_sdo_request(<<command::8, payload::binary>>, _mailbox_counter, slave)
       when command in 0x00..0x1F do
    handle_download_segment(command, payload, slave)
  end

  defp handle_sdo_request(<<command::8, _rest::binary>>, _mailbox_counter, slave)
       when command in [0x60, 0x70] do
    handle_upload_segment(command, slave)
  end

  defp handle_sdo_request(
         <<_command::8, index::16-little, subindex::8, _::binary>>,
         _mailbox_counter,
         slave
       ) do
    {:ok, abort_response(index, subindex, @abort_unsupported), slave}
  end

  defp handle_sdo_request(_body, _mailbox_counter, slave) do
    {:ok, abort_response(0, 0, @abort_unsupported), slave}
  end

  defp handle_download_segment(_command, _payload, %{mailbox_download: nil} = slave) do
    {:ok, abort_response(0, 0, @abort_unsupported), slave}
  end

  defp handle_download_segment(command, payload, %{mailbox_download: transfer} = slave) do
    case Dictionary.abort_code(slave, transfer.index, transfer.subindex, :download_segment) do
      {:ok, abort_code} ->
        {:ok, abort_response(transfer.index, transfer.subindex, abort_code),
         %{slave | mailbox_download: nil}}

      :error ->
        toggle = band_toggle(command)

        if toggle != transfer.toggle do
          {:ok, abort_response(transfer.index, transfer.subindex, @abort_toggle_mismatch), slave}
        else
          last_segment? = band_last_segment?(command)
          padding = band_padding(command)
          segment = segment_download_payload(payload, last_segment?, padding)
          data = transfer.data <> segment

          if last_segment? do
            final = binary_part(data, 0, min(byte_size(data), transfer.size))

            case Dictionary.write_entry(slave, transfer.index, transfer.subindex, final) do
              {:ok, updated_slave} ->
                {:ok, segment_download_ack(toggle), %{updated_slave | mailbox_download: nil}}

              {:error, abort_code, updated_slave} ->
                {:ok, abort_response(transfer.index, transfer.subindex, abort_code),
                 %{updated_slave | mailbox_download: nil}}
            end
          else
            next_transfer = %{transfer | data: data, toggle: flip_toggle(transfer.toggle)}
            {:ok, segment_download_ack(toggle), %{slave | mailbox_download: next_transfer}}
          end
        end
    end
  end

  defp handle_upload_segment(_command, %{mailbox_upload: nil} = slave) do
    {:ok, abort_response(0, 0, @abort_unsupported), slave}
  end

  defp handle_upload_segment(command, %{mailbox_upload: transfer} = slave) do
    case Dictionary.abort_code(slave, transfer.index, transfer.subindex, :upload_segment) do
      {:ok, abort_code} ->
        {:ok, abort_response(transfer.index, transfer.subindex, abort_code),
         %{slave | mailbox_upload: nil}}

      :error ->
        toggle = band_toggle(command)

        if toggle != transfer.toggle do
          {:ok, abort_response(transfer.index, transfer.subindex, @abort_toggle_mismatch), slave}
        else
          chunk_size = max(slave.mailbox_config.send_size - 9, 0)
          remaining = transfer.remaining
          chunk = binary_part(remaining, 0, min(byte_size(remaining), chunk_size))
          rest = binary_part(remaining, byte_size(chunk), byte_size(remaining) - byte_size(chunk))
          last_segment? = byte_size(rest) == 0
          {segment, unused} = upload_segment_payload(chunk, last_segment?)

          response = upload_segment_response(toggle, last_segment?, unused, segment)

          next_slave =
            if last_segment? do
              %{slave | mailbox_upload: nil}
            else
              %{
                slave
                | mailbox_upload: %{
                    transfer
                    | remaining: rest,
                      toggle: flip_toggle(transfer.toggle)
                  }
              }
            end

          {:ok, response, next_slave}
        end
    end
  end

  defp mailbox_service(<<service::16-little, _::binary>>), do: div(service, 4096)
  defp mailbox_service(_payload), do: 0

  defp mailbox_body(<<_service::16-little, body::binary>>), do: body
  defp mailbox_body(_payload), do: <<>>

  defp mailbox_frame(counter, payload) do
    <<byte_size(payload)::16-little, 0::16-little, 0::8, mailbox_type(counter)::8,
      payload::binary>>
  end

  defp pad_send_mailbox(frame, send_size) when byte_size(frame) <= send_size do
    frame <> :binary.copy(<<0>>, send_size - byte_size(frame))
  end

  defp expedited_upload_response(index, subindex, value) do
    unused = 4 - byte_size(value)
    command = 0x43 + unused * 4
    padded = value <> :binary.copy(<<0>>, unused)
    <<command::8, index::16-little, subindex::8, padded::binary>>
  end

  defp segmented_upload_init_response(index, subindex, total_size, initial) do
    <<0x41, index::16-little, subindex::8, total_size::32-little, initial::binary>>
  end

  defp upload_segment_response(toggle, last_segment?, unused, segment) do
    last_flag = if last_segment?, do: 1, else: 0
    command = toggle * 16 + unused * 2 + last_flag
    <<command::8, segment::binary>>
  end

  defp upload_segment_payload(chunk, true) when byte_size(chunk) < 7 do
    padding = 7 - byte_size(chunk)
    {chunk <> :binary.copy(<<0>>, padding), padding}
  end

  defp upload_segment_payload(chunk, _last_segment?), do: {chunk, 0}

  defp download_ack(index, subindex) do
    <<0x60, index::16-little, subindex::8, 0::32-little>>
  end

  defp segment_download_ack(toggle) do
    <<0x20 + toggle * 16, 0::56>>
  end

  defp abort_response(index, subindex, abort_code) do
    <<@command_abort, index::16-little, subindex::8, abort_code::32-little>>
  end

  defp sdo_response_service, do: <<@service_sdo_response * 4096::16-little>>
  defp mailbox_type(counter), do: counter * 16 + @mailbox_type_coe

  defp expedited_download_size(0x2F), do: 1
  defp expedited_download_size(0x2B), do: 2
  defp expedited_download_size(0x27), do: 3
  defp expedited_download_size(0x23), do: 4

  defp upload_state(index, subindex, remaining, mailbox_counter) do
    %{
      index: index,
      subindex: subindex,
      remaining: remaining,
      toggle: 0,
      mailbox_counter: mailbox_counter
    }
  end

  defp segment_download_payload(payload, last_segment?, padding) do
    take =
      if last_segment? do
        max(byte_size(payload) - padding, 0)
      else
        byte_size(payload)
      end

    binary_part(payload, 0, take)
  end

  defp band_toggle(command) do
    <<_::3, toggle::1, _::4>> = <<command::8>>
    toggle
  end

  defp band_last_segment?(command) do
    <<_::7, last::1>> = <<command::8>>
    last == 1
  end

  defp band_padding(command) do
    <<_::4, padding::3, _::1>> = <<command::8>>
    padding
  end

  defp flip_toggle(0), do: 1
  defp flip_toggle(1), do: 0
end
