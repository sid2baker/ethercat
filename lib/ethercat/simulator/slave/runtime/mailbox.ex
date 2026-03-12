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

  @type protocol_fault_stage ::
          :request
          | :upload_init
          | :upload_segment
          | :download_init
          | :download_segment

  @type protocol_fault_kind ::
          :drop_response
          | :counter_mismatch
          | :toggle_mismatch
          | {:mailbox_type, 0..15}
          | {:coe_service, 0..15}
          | :invalid_coe_payload
          | {:sdo_command, 0..255}
          | :invalid_segment_padding
          | {:segment_command, 0..255}

  @type response_spec :: %{
          required(:body) => binary(),
          required(:index) => non_neg_integer(),
          required(:subindex) => non_neg_integer(),
          required(:stage) => protocol_fault_stage(),
          required(:mailbox_type) => 0..15,
          required(:service) => 0..15,
          required(:payload_override) => binary() | nil
        }

  @spec inject_protocol_fault(
          map(),
          non_neg_integer(),
          non_neg_integer(),
          protocol_fault_stage(),
          protocol_fault_kind(),
          keyword()
        ) :: map()
  def inject_protocol_fault(slave, index, subindex, stage, fault_kind, opts \\ [])
      when stage in [:request, :upload_init, :upload_segment, :download_init, :download_segment] do
    if valid_protocol_fault?(stage, fault_kind) do
      rule = %{
        index: index,
        subindex: subindex,
        stage: stage,
        fault_kind: fault_kind,
        once?: Keyword.get(opts, :once?, false)
      }

      %{slave | mailbox_protocol_fault_rules: upsert_protocol_fault_rule(slave, rule)}
    else
      slave
    end
  end

  @spec clear_protocol_faults(map()) :: map()
  def clear_protocol_faults(slave) do
    %{slave | mailbox_protocol_fault_rules: []}
  end

  @spec handle_frame(binary(), Device.t()) ::
          {:ok, binary(), Device.t()} | {:drop_response, Device.t()} | :ignore
  def handle_frame(frame, %Device{} = slave) do
    with {:ok, request} <- parse_request(frame),
         {:ok, response, updated_slave} <- handle_request(request, slave) do
      case maybe_apply_protocol_fault(response, request.counter, updated_slave) do
        {:ok, response_counter, response, updated_slave} ->
          response =
            response_counter
            |> mailbox_frame(response)
            |> pad_send_mailbox(updated_slave.mailbox_config.send_size)

          {:ok, response, updated_slave}

        {:drop_response, updated_slave} ->
          {:drop_response, updated_slave}
      end
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
        {:ok,
         response(
           expedited_upload_response(index, subindex, data),
           index,
           subindex,
           :upload_init
         ), updated_slave}

      {:ok, data, updated_slave} ->
        init_size = max(updated_slave.mailbox_config.send_size - 16, 0)
        initial = binary_part(data, 0, min(init_size, byte_size(data)))
        remaining = binary_part(data, byte_size(initial), byte_size(data) - byte_size(initial))

        next_slave =
          %{
            updated_slave
            | mailbox_upload: upload_state(index, subindex, remaining, mailbox_counter)
          }

        {:ok,
         response(
           segmented_upload_init_response(index, subindex, byte_size(data), initial),
           index,
           subindex,
           :upload_init
         ), next_slave}

      {:error, abort_code, updated_slave} ->
        {:ok,
         response(abort_response(index, subindex, abort_code), index, subindex, :upload_init),
         updated_slave}
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
        {:ok, response(download_ack(index, subindex), index, subindex, :download_init),
         updated_slave}

      {:error, abort_code, updated_slave} ->
        {:ok,
         response(abort_response(index, subindex, abort_code), index, subindex, :download_init),
         updated_slave}
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
          {:ok, response(download_ack(index, subindex), index, subindex, :download_init),
           updated_slave}

        {:error, abort_code, updated_slave} ->
          {:ok,
           response(abort_response(index, subindex, abort_code), index, subindex, :download_init),
           updated_slave}
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

      {:ok, response(download_ack(index, subindex), index, subindex, :download_init), next_slave}
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
    {:ok,
     response(abort_response(index, subindex, @abort_unsupported), index, subindex, :request),
     slave}
  end

  defp handle_sdo_request(_body, _mailbox_counter, slave) do
    {:ok, response(abort_response(0, 0, @abort_unsupported), 0, 0, :request), slave}
  end

  defp handle_download_segment(_command, _payload, %{mailbox_download: nil} = slave) do
    {:ok, response(abort_response(0, 0, @abort_unsupported), 0, 0, :download_segment), slave}
  end

  defp handle_download_segment(command, payload, %{mailbox_download: transfer} = slave) do
    case Dictionary.abort_code(slave, transfer.index, transfer.subindex, :download_segment) do
      {:ok, abort_code} ->
        {:ok,
         response(
           abort_response(transfer.index, transfer.subindex, abort_code),
           transfer.index,
           transfer.subindex,
           :download_segment
         ), %{slave | mailbox_download: nil}}

      :error ->
        toggle = band_toggle(command)

        if toggle != transfer.toggle do
          {:ok,
           response(
             abort_response(transfer.index, transfer.subindex, @abort_toggle_mismatch),
             transfer.index,
             transfer.subindex,
             :download_segment
           ), slave}
        else
          last_segment? = band_last_segment?(command)
          padding = band_padding(command)
          segment = segment_download_payload(payload, last_segment?, padding)
          data = transfer.data <> segment

          if last_segment? do
            final = binary_part(data, 0, min(byte_size(data), transfer.size))

            case Dictionary.write_entry(slave, transfer.index, transfer.subindex, final) do
              {:ok, updated_slave} ->
                {:ok,
                 response(
                   segment_download_ack(toggle),
                   transfer.index,
                   transfer.subindex,
                   :download_segment
                 ), %{updated_slave | mailbox_download: nil}}

              {:error, abort_code, updated_slave} ->
                {:ok,
                 response(
                   abort_response(transfer.index, transfer.subindex, abort_code),
                   transfer.index,
                   transfer.subindex,
                   :download_segment
                 ), %{updated_slave | mailbox_download: nil}}
            end
          else
            next_transfer = %{transfer | data: data, toggle: flip_toggle(transfer.toggle)}

            {:ok,
             response(
               segment_download_ack(toggle),
               transfer.index,
               transfer.subindex,
               :download_segment
             ), %{slave | mailbox_download: next_transfer}}
          end
        end
    end
  end

  defp handle_upload_segment(_command, %{mailbox_upload: nil} = slave) do
    {:ok, response(abort_response(0, 0, @abort_unsupported), 0, 0, :upload_segment), slave}
  end

  defp handle_upload_segment(command, %{mailbox_upload: transfer} = slave) do
    case Dictionary.abort_code(slave, transfer.index, transfer.subindex, :upload_segment) do
      {:ok, abort_code} ->
        {:ok,
         response(
           abort_response(transfer.index, transfer.subindex, abort_code),
           transfer.index,
           transfer.subindex,
           :upload_segment
         ), %{slave | mailbox_upload: nil}}

      :error ->
        toggle = band_toggle(command)

        if toggle != transfer.toggle do
          {:ok,
           response(
             abort_response(transfer.index, transfer.subindex, @abort_toggle_mismatch),
             transfer.index,
             transfer.subindex,
             :upload_segment
           ), slave}
        else
          chunk_size = max(slave.mailbox_config.send_size - 9, 0)
          remaining = transfer.remaining
          chunk = binary_part(remaining, 0, min(byte_size(remaining), chunk_size))
          rest = binary_part(remaining, byte_size(chunk), byte_size(remaining) - byte_size(chunk))
          last_segment? = byte_size(rest) == 0
          {segment, unused} = upload_segment_payload(chunk, last_segment?)

          segment_response_body = upload_segment_response(toggle, last_segment?, unused, segment)

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

          {:ok,
           response(
             segment_response_body,
             transfer.index,
             transfer.subindex,
             :upload_segment
           ), next_slave}
        end
    end
  end

  defp maybe_apply_protocol_fault(
         %{index: index, subindex: subindex, stage: stage} = response,
         request_counter,
         slave
       ) do
    case protocol_fault(slave, index, subindex, stage) do
      {:ok, :drop_response, updated_slave} ->
        {:drop_response, updated_slave}

      {:ok, :counter_mismatch, updated_slave} ->
        {:ok, next_mailbox_counter(request_counter), response, updated_slave}

      {:ok, :toggle_mismatch, updated_slave} ->
        {:ok, request_counter, %{response | body: maybe_flip_toggle(response.body, stage)},
         updated_slave}

      {:ok, {:mailbox_type, mailbox_type}, updated_slave} ->
        {:ok, request_counter, %{response | mailbox_type: mailbox_type}, updated_slave}

      {:ok, {:coe_service, service}, updated_slave} ->
        {:ok, request_counter, %{response | service: service}, updated_slave}

      {:ok, :invalid_coe_payload, updated_slave} ->
        {:ok, request_counter, %{response | payload_override: <<@service_sdo_response>>},
         updated_slave}

      {:ok, {:sdo_command, command}, updated_slave} ->
        {:ok, request_counter, %{response | body: replace_sdo_command(response.body, command)},
         updated_slave}

      {:ok, :invalid_segment_padding, updated_slave} ->
        {:ok, request_counter,
         %{response | body: invalid_segment_padding_body(response.body, stage)}, updated_slave}

      {:ok, {:segment_command, command}, updated_slave} ->
        {:ok, request_counter, %{response | body: replace_segment_command(command)},
         updated_slave}

      :error ->
        {:ok, request_counter, response, slave}
    end
  end

  defp mailbox_service(<<service::16-little, _::binary>>), do: div(service, 4096)
  defp mailbox_service(_payload), do: 0

  defp mailbox_body(<<_service::16-little, body::binary>>), do: body
  defp mailbox_body(_payload), do: <<>>

  defp mailbox_frame(counter, %{payload_override: payload, mailbox_type: mailbox_type})
       when is_binary(payload) do
    <<byte_size(payload)::16-little, 0::16-little, 0::8, mailbox_type(counter, mailbox_type)::8,
      payload::binary>>
  end

  defp mailbox_frame(counter, %{service: service, mailbox_type: mailbox_type, body: body}) do
    payload = <<service * 4096::16-little, body::binary>>

    <<byte_size(payload)::16-little, 0::16-little, 0::8, mailbox_type(counter, mailbox_type)::8,
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

  defp response(body, index, subindex, stage) do
    %{
      body: body,
      index: index,
      subindex: subindex,
      stage: stage,
      mailbox_type: @mailbox_type_coe,
      service: @service_sdo_response,
      payload_override: nil
    }
  end

  defp protocol_fault(slave, index, subindex, stage) do
    case pop_protocol_fault_rule(slave.mailbox_protocol_fault_rules, index, subindex, stage) do
      {:ok, %{fault_kind: fault_kind}, mailbox_protocol_fault_rules} ->
        {:ok, fault_kind, %{slave | mailbox_protocol_fault_rules: mailbox_protocol_fault_rules}}

      nil ->
        :error
    end
  end

  defp maybe_flip_toggle(<<0::2, 1::1, toggle::1, rest::4, tail::binary>>, :download_segment) do
    <<0::2, 1::1, flip_toggle(toggle)::1, rest::4, tail::binary>>
  end

  defp maybe_flip_toggle(<<0::3, toggle::1, rest::4, tail::binary>>, :upload_segment) do
    <<0::3, flip_toggle(toggle)::1, rest::4, tail::binary>>
  end

  defp maybe_flip_toggle(body, _stage), do: body

  defp replace_sdo_command(<<_::8, rest::binary>>, command), do: <<command::8, rest::binary>>
  defp replace_sdo_command(_body, command), do: <<command::8>>

  defp invalid_segment_padding_body(
         <<0::3, toggle::1, _unused::3, _last::1, _segment::binary>>,
         :upload_segment
       ) do
    <<0::3, toggle::1, 7::3, 1::1>>
  end

  defp invalid_segment_padding_body(body, _stage), do: body

  defp replace_segment_command(command), do: <<command::8>>

  defp download_ack(index, subindex) do
    <<0x60, index::16-little, subindex::8, 0::32-little>>
  end

  defp segment_download_ack(toggle) do
    <<0x20 + toggle * 16, 0::56>>
  end

  defp abort_response(index, subindex, abort_code) do
    <<@command_abort, index::16-little, subindex::8, abort_code::32-little>>
  end

  defp mailbox_type(counter, type), do: counter * 16 + type
  defp next_mailbox_counter(7), do: 1

  defp next_mailbox_counter(counter) when is_integer(counter) and counter >= 0 and counter < 7,
    do: counter + 1

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

  defp valid_protocol_fault?(stage, :drop_response)
       when stage in [:request, :upload_init, :upload_segment, :download_init, :download_segment],
       do: true

  defp valid_protocol_fault?(stage, :counter_mismatch)
       when stage in [:request, :upload_init, :upload_segment, :download_init, :download_segment],
       do: true

  defp valid_protocol_fault?(stage, :toggle_mismatch)
       when stage in [:upload_segment, :download_segment],
       do: true

  defp valid_protocol_fault?(stage, {:mailbox_type, mailbox_type})
       when stage in [:request, :upload_init, :upload_segment, :download_init, :download_segment] and
              is_integer(mailbox_type) and mailbox_type >= 0 and mailbox_type <= 15,
       do: true

  defp valid_protocol_fault?(stage, {:coe_service, service})
       when stage in [:request, :upload_init, :upload_segment, :download_init, :download_segment] and
              is_integer(service) and service >= 0 and service <= 15,
       do: true

  defp valid_protocol_fault?(stage, :invalid_coe_payload)
       when stage in [:request, :upload_init, :upload_segment, :download_init, :download_segment],
       do: true

  defp valid_protocol_fault?(stage, {:sdo_command, command})
       when stage == :upload_init and is_integer(command) and command >= 0 and command <= 255,
       do: true

  defp valid_protocol_fault?(stage, :invalid_segment_padding)
       when stage == :upload_segment,
       do: true

  defp valid_protocol_fault?(stage, {:segment_command, command})
       when stage in [:upload_segment, :download_segment] and is_integer(command) and
              command >= 0 and command <= 255,
       do: true

  defp valid_protocol_fault?(_stage, _fault_kind), do: false

  defp upsert_protocol_fault_rule(slave, %{index: index, subindex: subindex, stage: stage} = rule) do
    filtered =
      Enum.reject(slave.mailbox_protocol_fault_rules, fn existing ->
        existing.index == index and existing.subindex == subindex and existing.stage == stage
      end)

    filtered ++ [rule]
  end

  defp matches_protocol_fault_rule?(rule, index, subindex, stage) do
    rule.index == index and rule.subindex == subindex and rule.stage == stage
  end

  defp pop_protocol_fault_rule(rules, index, subindex, stage) do
    case Enum.find_index(rules, &matches_protocol_fault_rule?(&1, index, subindex, stage)) do
      nil ->
        nil

      idx ->
        rule = Enum.at(rules, idx)

        mailbox_protocol_fault_rules =
          if Map.get(rule, :once?, false) do
            List.delete_at(rules, idx)
          else
            rules
          end

        {:ok, rule, mailbox_protocol_fault_rules}
    end
  end
end
