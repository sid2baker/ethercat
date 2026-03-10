defmodule EtherCAT.Support.Slave.Mailbox do
  @moduledoc false

  @mailbox_type_coe 0x03
  @service_sdo_request 0x02
  @service_sdo_response 0x03
  @sdo_request_service @service_sdo_request * 4096

  @command_abort 0x80
  @command_upload_init_request 0x40
  @command_download_4 0x23
  @command_download_3 0x27
  @command_download_2 0x2B
  @command_download_1 0x2F

  @abort_unsupported 0x0504_0001
  @abort_object_not_found 0x0602_0000

  @type mailbox_config :: %{
          required(:recv_offset) => non_neg_integer(),
          required(:recv_size) => non_neg_integer(),
          required(:send_offset) => non_neg_integer(),
          required(:send_size) => non_neg_integer()
        }

  @type request :: %{
          counter: non_neg_integer(),
          service: non_neg_integer(),
          body: binary()
        }

  @spec handle_frame(binary(), mailbox_config(), map()) :: {:ok, binary(), map()} | :ignore
  def handle_frame(frame, mailbox_config, object_dictionary) do
    with {:ok, request} <- parse_request(frame),
         {:ok, response_body, updated_dictionary} <-
           handle_request(request, object_dictionary) do
      padded =
        request.counter
        |> mailbox_frame(sdo_response_service() <> response_body)
        |> pad_send_mailbox(mailbox_config.send_size)

      {:ok, padded, updated_dictionary}
    else
      :ignore -> :ignore
    end
  end

  defp parse_request(
         <<payload_length::16-little, _address::16-little, _channel::8, mailbox_type::8,
           payload::binary-size(payload_length), _padding::binary>>
       ) do
    service = mailbox_service(payload)

    {:ok,
     %{
       counter: div(mailbox_type, 16),
       type: rem(mailbox_type, 16),
       service: service,
       body: mailbox_body(payload)
     }}
  end

  defp parse_request(_frame), do: :ignore

  defp handle_request(
         %{type: @mailbox_type_coe, service: @sdo_request_service, body: body},
         object_dictionary
       ) do
    handle_sdo_request(body, object_dictionary)
  end

  defp handle_request(_request, _object_dictionary), do: :ignore

  defp handle_sdo_request(
         <<@command_upload_init_request, index::16-little, subindex::8, _::32>>,
         object_dictionary
       ) do
    case Map.fetch(object_dictionary, {index, subindex}) do
      {:ok, value} when byte_size(value) <= 4 ->
        {:ok, expedited_upload_response(index, subindex, value), object_dictionary}

      {:ok, _value} ->
        {:ok, abort_response(index, subindex, @abort_unsupported), object_dictionary}

      :error ->
        {:ok, abort_response(index, subindex, @abort_object_not_found), object_dictionary}
    end
  end

  defp handle_sdo_request(
         <<command::8, index::16-little, subindex::8, payload::binary-size(4)>>,
         object_dictionary
       )
       when command in [
              @command_download_1,
              @command_download_2,
              @command_download_3,
              @command_download_4
            ] do
    size = expedited_download_size(command)
    <<value::binary-size(size), _padding::binary>> = payload
    updated_dictionary = Map.put(object_dictionary, {index, subindex}, value)
    {:ok, download_ack(index, subindex), updated_dictionary}
  end

  defp handle_sdo_request(
         <<_command::8, index::16-little, subindex::8, _::binary>>,
         object_dictionary
       ) do
    {:ok, abort_response(index, subindex, @abort_unsupported), object_dictionary}
  end

  defp handle_sdo_request(_body, object_dictionary) do
    {:ok, abort_response(0, 0, @abort_unsupported), object_dictionary}
  end

  defp expedited_upload_response(index, subindex, value) do
    unused = 4 - byte_size(value)
    command = 0x43 + unused * 4
    padded = value <> :binary.copy(<<0>>, unused)
    <<command::8, index::16-little, subindex::8, padded::binary>>
  end

  defp download_ack(index, subindex) do
    <<0x60, index::16-little, subindex::8, 0::32-little>>
  end

  defp abort_response(index, subindex, abort_code) do
    <<@command_abort, index::16-little, subindex::8, abort_code::32-little>>
  end

  defp expedited_download_size(@command_download_1), do: 1
  defp expedited_download_size(@command_download_2), do: 2
  defp expedited_download_size(@command_download_3), do: 3
  defp expedited_download_size(@command_download_4), do: 4

  defp mailbox_service(<<service::16-little, _::binary>>), do: service
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

  defp sdo_response_service, do: <<@service_sdo_response * 4096::16-little>>
  defp mailbox_type(counter), do: counter * 16 + @mailbox_type_coe
end
