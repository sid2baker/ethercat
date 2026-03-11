defmodule EtherCAT.Simulator.Slave.Runtime.CoE do
  @moduledoc false

  alias EtherCAT.Simulator.Slave.Runtime.Mailbox

  @spec handle_write(map(), non_neg_integer(), binary(), non_neg_integer()) :: map()
  def handle_write(
        %{mailbox_config: %{recv_offset: recv_offset, recv_size: recv_size}} = slave,
        offset,
        data,
        status_offset
      )
      when recv_size > 0 and offset == recv_offset and byte_size(data) == recv_size do
    case Mailbox.handle_frame(data, slave) do
      {:ok, response, updated_slave} ->
        updated_slave
        |> write_memory(updated_slave.mailbox_config.send_offset, response)
        |> write_memory(status_offset, <<0x08>>)

      {:drop_response, updated_slave} ->
        updated_slave

      :ignore ->
        slave
    end
  end

  def handle_write(slave, _offset, _data, _status_offset), do: slave

  @spec send_read?(map(), non_neg_integer(), non_neg_integer()) :: boolean()
  def send_read?(
        %{mailbox_config: %{send_offset: send_offset, send_size: send_size}},
        offset,
        length
      )
      when send_size > 0 do
    offset == send_offset and length == send_size
  end

  def send_read?(_slave, _offset, _length), do: false

  @spec clear_send_response(map(), non_neg_integer(), non_neg_integer()) :: map()
  def clear_send_response(
        %{mailbox_config: %{send_offset: send_offset, send_size: send_size}} = slave,
        status_offset,
        status_length
      ) do
    slave
    |> write_memory(send_offset, :binary.copy(<<0>>, send_size))
    |> write_memory(status_offset, :binary.copy(<<0>>, status_length))
  end

  defp write_memory(%{memory: memory} = slave, offset, data) do
    %{slave | memory: replace_binary(memory, offset, data)}
  end

  defp replace_binary(binary, offset, value) do
    prefix = binary_part(binary, 0, offset)
    suffix_offset = offset + byte_size(value)
    suffix = binary_part(binary, suffix_offset, byte_size(binary) - suffix_offset)
    prefix <> value <> suffix
  end
end
