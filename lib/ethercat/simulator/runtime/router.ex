defmodule EtherCAT.Simulator.Runtime.Router do
  @moduledoc false

  alias EtherCAT.Bus.Datagram
  alias EtherCAT.Simulator.Slave.Runtime.Device

  @aprd 1
  @apwr 2
  @aprw 3
  @fprd 4
  @fpwr 5
  @fprw 6
  @brd 7
  @bwr 8
  @brw 9
  @lrd 10
  @lwr 11
  @lrw 12
  @armw 13
  @frmw 14

  @spec process_datagrams(
          [Datagram.t()],
          [Device.t()],
          MapSet.t(atom()),
          integer(),
          %{optional(atom()) => integer()}
        ) ::
          {[Datagram.t()], [Device.t()]}
  def process_datagrams(datagrams, slaves, disconnected, wkc_offset, logical_wkc_offsets) do
    slaves = Enum.map(slaves, &Device.prepare/1)

    {responses, slaves} =
      Enum.map_reduce(datagrams, slaves, fn datagram, current_slaves ->
        process_datagram(datagram, current_slaves, disconnected, logical_wkc_offsets)
      end)

    {maybe_adjust_wkc(responses, wkc_offset), slaves}
  end

  defp process_datagram(
         %Datagram{cmd: cmd} = datagram,
         slaves,
         disconnected,
         _logical_wkc_offsets
       )
       when cmd in [@aprd, @apwr, @aprw, @armw] do
    <<position::little-signed-16, offset::little-unsigned-16>> = datagram.address
    target_position = -position

    {response_data, wkc, slaves} =
      update_single(slaves, disconnected, target_position, fn slave ->
        process_register_command(slave, datagram, offset)
      end)

    {%{datagram | data: response_data, wkc: wkc}, slaves}
  end

  defp process_datagram(
         %Datagram{cmd: cmd} = datagram,
         slaves,
         disconnected,
         _logical_wkc_offsets
       )
       when cmd in [@fprd, @fpwr, @fprw, @frmw] do
    <<station::little-unsigned-16, offset::little-unsigned-16>> = datagram.address

    {response_data, wkc, slaves} =
      update_first(
        slaves,
        disconnected,
        fn slave -> slave.station == station end,
        fn slave -> process_register_command(slave, datagram, offset) end
      )

    {%{datagram | data: response_data, wkc: wkc}, slaves}
  end

  defp process_datagram(
         %Datagram{cmd: cmd} = datagram,
         slaves,
         disconnected,
         _logical_wkc_offsets
       )
       when cmd in [@brd, @bwr, @brw] do
    <<_zero::little-signed-16, offset::little-unsigned-16>> = datagram.address

    {slaves, response_data, wkc} =
      Enum.reduce(slaves, {[], datagram.data, 0}, fn slave, {acc, _response_data, wkc} ->
        if MapSet.member?(disconnected, slave.name) do
          {[slave | acc], datagram.data, wkc}
        else
          {updated_slave, new_response_data, increment} =
            process_register_command(slave, datagram, offset)

          {[updated_slave | acc], new_response_data, wkc + increment}
        end
      end)

    {%{datagram | data: response_data, wkc: wkc}, Enum.reverse(slaves)}
  end

  defp process_datagram(%Datagram{cmd: cmd} = datagram, slaves, disconnected, logical_wkc_offsets)
       when cmd in [@lrd, @lwr, @lrw] do
    <<logical_start::little-unsigned-32>> = datagram.address

    {slaves, response_data, wkc} =
      Enum.reduce(slaves, {[], datagram.data, 0}, fn slave, {acc, response_data, wkc} ->
        if MapSet.member?(disconnected, slave.name) do
          {[slave | acc], response_data, wkc}
        else
          {updated_slave, new_response_data, increment} =
            Device.logical_read_write(slave, cmd, logical_start, response_data)

          adjusted_increment =
            maybe_adjust_logical_increment(increment, slave.name, logical_wkc_offsets)

          {[updated_slave | acc], new_response_data, wkc + adjusted_increment}
        end
      end)

    {%{datagram | data: response_data, wkc: wkc}, Enum.reverse(slaves)}
  end

  defp process_datagram(%Datagram{} = datagram, slaves, _disconnected, _logical_wkc_offsets),
    do: {%{datagram | wkc: 0}, slaves}

  defp maybe_adjust_wkc(datagrams, 0), do: datagrams

  defp maybe_adjust_wkc(datagrams, offset) do
    Enum.map(datagrams, fn datagram ->
      %{datagram | wkc: max(datagram.wkc + offset, 0)}
    end)
  end

  defp maybe_adjust_logical_increment(increment, slave_name, logical_wkc_offsets)
       when is_integer(increment) and increment >= 0 do
    increment
    |> Kernel.+(Map.get(logical_wkc_offsets, slave_name, 0))
    |> max(0)
  end

  defp process_register_command(slave, %Datagram{cmd: cmd, data: data}, offset)
       when cmd in [@aprd, @fprd, @brd] do
    {updated_slave, response_data} = Device.read_datagram(slave, offset, byte_size(data))
    {updated_slave, response_data, 1}
  end

  defp process_register_command(slave, %Datagram{cmd: cmd, data: data}, offset)
       when cmd in [@apwr, @fpwr, @bwr] do
    {Device.write_datagram(slave, offset, data), data, 1}
  end

  defp process_register_command(slave, %Datagram{cmd: cmd, data: data}, offset)
       when cmd in [@aprw, @fprw, @brw, @armw, @frmw] do
    {read_slave, response_data} = Device.read_datagram(slave, offset, byte_size(data))
    updated_slave = Device.write_datagram(read_slave, offset, data)
    {updated_slave, response_data, 1}
  end

  defp update_single(slaves, disconnected, target_position, fun) do
    {slaves, response_data, wkc, matched?} =
      Enum.reduce(slaves, {[], nil, 0, false}, fn slave, {acc, response_data, wkc, matched?} ->
        if slave.position == target_position and not MapSet.member?(disconnected, slave.name) do
          {updated_slave, current_response_data, current_wkc} = fun.(slave)
          {[updated_slave | acc], current_response_data, current_wkc, true}
        else
          {[slave | acc], response_data, wkc, matched?}
        end
      end)

    if matched? do
      {response_data || <<>>, wkc, Enum.reverse(slaves)}
    else
      {<<>>, 0, Enum.reverse(slaves)}
    end
  end

  defp update_first(slaves, disconnected, matcher, fun) do
    {updated_entries, matched?} =
      Enum.map_reduce(slaves, false, fn slave, matched? ->
        cond do
          matched? ->
            {{slave, nil, 0}, true}

          MapSet.member?(disconnected, slave.name) ->
            {{slave, nil, 0}, false}

          matcher.(slave) ->
            {updated_slave, response_data, wkc} = fun.(slave)
            {{updated_slave, response_data, wkc}, true}

          true ->
            {{slave, nil, 0}, false}
        end
      end)

    {slaves, response_data, wkc} =
      Enum.reduce(updated_entries, {[], nil, 0}, fn {slave, response_data, wkc},
                                                    {acc, found_data, found_wkc} ->
        data =
          if is_nil(found_data) and not is_nil(response_data), do: response_data, else: found_data

        current_wkc = if found_wkc == 0 and wkc > 0, do: wkc, else: found_wkc
        {[slave | acc], data, current_wkc}
      end)

    slaves = Enum.reverse(slaves)

    if matched? do
      {response_data || <<>>, wkc, slaves}
    else
      {<<>>, 0, slaves}
    end
  end
end
