defmodule EtherCAT.Support.Simulator do
  @moduledoc false

  use GenServer

  alias EtherCAT.Bus.Datagram
  alias EtherCAT.Support.Slave.Device

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

  @type state :: %{slaves: [Device.t()]}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec process_datagrams(pid(), [Datagram.t()]) :: {:ok, [Datagram.t()]}
  def process_datagrams(server, datagrams) do
    GenServer.call(server, {:process_datagrams, datagrams})
  end

  @spec output_value(pid(), atom()) :: {:ok, non_neg_integer()} | {:error, :not_found}
  def output_value(server, slave_name) do
    GenServer.call(server, {:output_value, slave_name})
  end

  @impl true
  def init(opts) do
    fixtures = Keyword.get(opts, :slaves, [])

    slaves =
      fixtures
      |> Enum.with_index()
      |> Enum.map(fn {fixture, position} -> Device.new(fixture, position) end)

    {:ok, %{slaves: slaves}}
  end

  @impl true
  def handle_call({:process_datagrams, datagrams}, _from, %{slaves: slaves} = state) do
    {responses, slaves} =
      Enum.map_reduce(datagrams, slaves, fn datagram, current_slaves ->
        process_datagram(datagram, current_slaves)
      end)

    {:reply, {:ok, responses}, %{state | slaves: slaves}}
  end

  def handle_call({:output_value, slave_name}, _from, %{slaves: slaves} = state) do
    reply =
      case Enum.find(slaves, &(&1.name == slave_name)) do
        nil ->
          {:error, :not_found}

        slave ->
          <<value::8>> = Device.read_register(slave, slave.output_phys, 1)
          {:ok, value}
      end

    {:reply, reply, state}
  end

  defp process_datagram(%Datagram{cmd: cmd} = datagram, slaves)
       when cmd in [@aprd, @apwr, @aprw, @armw] do
    <<position::little-signed-16, offset::little-unsigned-16>> = datagram.address
    target_position = -position

    {response_data, wkc, slaves} =
      update_single(slaves, target_position, fn slave ->
        process_register_command(slave, datagram, offset)
      end)

    {%{datagram | data: response_data, wkc: wkc}, slaves}
  end

  defp process_datagram(%Datagram{cmd: cmd} = datagram, slaves)
       when cmd in [@fprd, @fpwr, @fprw, @frmw] do
    <<station::little-unsigned-16, offset::little-unsigned-16>> = datagram.address

    {response_data, wkc, slaves} =
      update_first(
        slaves,
        fn slave ->
          slave.station == station
        end,
        fn slave ->
          process_register_command(slave, datagram, offset)
        end
      )

    {%{datagram | data: response_data, wkc: wkc}, slaves}
  end

  defp process_datagram(%Datagram{cmd: cmd} = datagram, slaves)
       when cmd in [@brd, @bwr, @brw] do
    <<_zero::little-signed-16, offset::little-unsigned-16>> = datagram.address

    {slaves, response_data, wkc} =
      Enum.reduce(slaves, {[], datagram.data, 0}, fn slave, {acc, _response_data, wkc} ->
        {updated_slave, new_response_data, increment} =
          process_register_command(slave, datagram, offset)

        {[updated_slave | acc], new_response_data, wkc + increment}
      end)

    {%{datagram | data: response_data, wkc: wkc}, Enum.reverse(slaves)}
  end

  defp process_datagram(%Datagram{cmd: cmd} = datagram, slaves) when cmd in [@lrd, @lwr, @lrw] do
    <<logical_start::little-unsigned-32>> = datagram.address

    {slaves, response_data, wkc} =
      Enum.reduce(slaves, {[], datagram.data, 0}, fn slave, {acc, response_data, wkc} ->
        {updated_slave, new_response_data, increment} =
          Device.logical_read_write(slave, cmd, logical_start, response_data)

        {[updated_slave | acc], new_response_data, wkc + increment}
      end)

    {%{datagram | data: response_data, wkc: wkc}, Enum.reverse(slaves)}
  end

  defp process_datagram(%Datagram{} = datagram, slaves), do: {%{datagram | wkc: 0}, slaves}

  defp process_register_command(slave, %Datagram{cmd: cmd, data: data}, offset)
       when cmd in [@aprd, @fprd, @brd] do
    {slave, Device.read_register(slave, offset, byte_size(data)), 1}
  end

  defp process_register_command(slave, %Datagram{cmd: cmd, data: data}, offset)
       when cmd in [@apwr, @fpwr, @bwr] do
    {Device.write_register(slave, offset, data), data, 1}
  end

  defp process_register_command(slave, %Datagram{cmd: cmd, data: data}, offset)
       when cmd in [@aprw, @fprw, @brw, @armw, @frmw] do
    response_data = Device.read_register(slave, offset, byte_size(data))
    updated_slave = Device.write_register(slave, offset, data)
    {updated_slave, response_data, 1}
  end

  defp update_single(slaves, target_position, fun) do
    {slaves, response_data, wkc, matched?} =
      Enum.reduce(slaves, {[], nil, 0, false}, fn slave, {acc, response_data, wkc, matched?} ->
        if slave.position == target_position do
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

  defp update_first(slaves, matcher, fun) do
    {updated_entries, matched?} =
      Enum.map_reduce(slaves, false, fn slave, matched? ->
        cond do
          matched? ->
            {{slave, nil, 0}, true}

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
