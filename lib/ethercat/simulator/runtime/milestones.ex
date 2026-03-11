defmodule EtherCAT.Simulator.Runtime.Milestones do
  @moduledoc false

  alias EtherCAT.Bus.Datagram
  alias EtherCAT.Simulator.Runtime.Faults
  alias EtherCAT.Simulator.Slave.Runtime.Device
  alias EtherCAT.Slave.ESC.Registers

  @fprd 4
  @op_code 0x08
  @al_status Registers.al_status()
  @mailbox_type_coe 0x03
  @service_sdo_response 0x03
  @command_abort 0x80

  @type mailbox_step ::
          :upload_init
          | :upload_segment
          | :download_init
          | :download_segment

  @type milestone ::
          {:healthy_exchanges, pos_integer()}
          | {:healthy_polls, atom(), pos_integer()}
          | {:mailbox_step, atom(), mailbox_step(), pos_integer()}

  @type observations :: %{
          healthy_exchanges: non_neg_integer(),
          healthy_polls: %{optional(atom()) => non_neg_integer()},
          mailbox_steps: %{optional({atom(), mailbox_step()}) => non_neg_integer()}
        }

  @spec valid?(term()) :: boolean()
  def valid?({:healthy_exchanges, count}) when is_integer(count) and count > 0, do: true

  def valid?({:healthy_polls, slave_name, count})
      when is_atom(slave_name) and is_integer(count) and count > 0,
      do: true

  def valid?({:mailbox_step, slave_name, step, count})
      when is_atom(slave_name) and
             step in [:upload_init, :upload_segment, :download_init, :download_segment] and
             is_integer(count) and count > 0,
      do: true

  def valid?(_milestone), do: false

  @spec initial_remaining(milestone()) :: pos_integer()
  def initial_remaining({:healthy_exchanges, count}), do: count
  def initial_remaining({:healthy_polls, _slave_name, count}), do: count
  def initial_remaining({:mailbox_step, _slave_name, _step, count}), do: count

  @spec observe(
          [Datagram.t()],
          [Datagram.t()],
          [Device.t()],
          Faults.t(),
          Faults.exchange_fault() | nil
        ) ::
          observations()
  def observe(datagrams, responses, slaves, %Faults{} = faults, planned_fault) do
    exchange_healthy? = healthy_exchange?(responses, faults, planned_fault)

    %{
      healthy_exchanges: if(exchange_healthy?, do: 1, else: 0),
      healthy_polls: healthy_poll_counts(datagrams, responses, slaves, exchange_healthy?),
      mailbox_steps: mailbox_step_counts(datagrams, responses, slaves)
    }
  end

  @spec progress(milestone(), observations()) :: non_neg_integer()
  def progress({:healthy_exchanges, _count}, observations), do: observations.healthy_exchanges

  def progress({:healthy_polls, slave_name, _count}, observations) do
    Map.get(observations.healthy_polls, slave_name, 0)
  end

  def progress({:mailbox_step, slave_name, step, _count}, observations) do
    Map.get(observations.mailbox_steps, {slave_name, step}, 0)
  end

  defp healthy_exchange?(responses, %Faults{} = faults, planned_fault) do
    cond do
      faults.drop_responses? ->
        false

      faults.wkc_offset != 0 ->
        false

      MapSet.size(faults.disconnected) > 0 ->
        false

      not is_nil(planned_fault) ->
        false

      true ->
        responses != [] and Enum.all?(responses, &(&1.wkc > 0))
    end
  end

  defp healthy_poll_counts(_datagrams, _responses, _slaves, false), do: %{}

  defp healthy_poll_counts(datagrams, responses, slaves, true) do
    stations_to_names =
      Map.new(slaves, fn %Device{name: name, station: station} -> {station, name} end)

    datagrams
    |> Enum.zip(responses)
    |> Enum.reduce(%{}, fn {request, response}, counts ->
      case healthy_poll_target(request, response, stations_to_names) do
        {:ok, slave_name} -> Map.update(counts, slave_name, 1, &(&1 + 1))
        :error -> counts
      end
    end)
  end

  defp healthy_poll_target(
         %Datagram{
           cmd: @fprd,
           address: <<station::16-little, offset::16-little>>,
           data: request_data
         },
         %Datagram{wkc: wkc, data: al_status},
         stations_to_names
       )
       when offset == elem(@al_status, 0) and byte_size(request_data) == elem(@al_status, 1) and
              wkc > 0 and
              byte_size(al_status) == elem(@al_status, 1) do
    with {:ok, slave_name} <- Map.fetch(stations_to_names, station),
         {al_state, false} <- Registers.decode_al_status(al_status),
         true <- al_state == @op_code do
      {:ok, slave_name}
    else
      _other -> :error
    end
  end

  defp healthy_poll_target(_request, _response, _stations_to_names), do: :error

  defp mailbox_step_counts(datagrams, responses, slaves) do
    send_offsets =
      slaves
      |> Enum.filter(fn %Device{mailbox_config: %{send_size: send_size}} -> send_size > 0 end)
      |> Map.new(fn %Device{
                      name: name,
                      station: station,
                      mailbox_config: %{send_offset: send_offset}
                    } ->
        {{station, send_offset}, name}
      end)

    datagrams
    |> Enum.zip(responses)
    |> Enum.reduce(%{}, fn {request, response}, counts ->
      case mailbox_step_target(request, response, send_offsets) do
        {:ok, mailbox_key} -> Map.update(counts, mailbox_key, 1, &(&1 + 1))
        :error -> counts
      end
    end)
  end

  defp mailbox_step_target(
         %Datagram{cmd: @fprd, address: <<station::16-little, offset::16-little>>},
         %Datagram{wkc: wkc, data: response_data},
         send_offsets
       )
       when wkc > 0 do
    with {:ok, slave_name} <- Map.fetch(send_offsets, {station, offset}),
         {:ok, step} <- mailbox_step(response_data) do
      {:ok, {slave_name, step}}
    else
      _other -> :error
    end
  end

  defp mailbox_step_target(_request, _response, _send_offsets), do: :error

  defp mailbox_step(
         <<payload_length::16-little, _address::16-little, _channel::8, mailbox_type::8,
           payload::binary-size(payload_length), _padding::binary>>
       )
       when rem(mailbox_type, 16) == @mailbox_type_coe do
    with {:ok, body} <- mailbox_sdo_response_body(payload) do
      mailbox_step_from_body(body)
    else
      _other -> :error
    end
  end

  defp mailbox_step(_response_data), do: :error

  defp mailbox_sdo_response_body(<<service::16-little, body::binary>>) do
    if div(service, 4096) == @service_sdo_response do
      {:ok, body}
    else
      :error
    end
  end

  defp mailbox_sdo_response_body(_payload), do: :error

  defp mailbox_step_from_body(<<@command_abort, _rest::binary>>), do: :error

  defp mailbox_step_from_body(<<0x60, _index::16-little, _subindex::8, _rest::binary>>),
    do: {:ok, :download_init}

  defp mailbox_step_from_body(<<command::8, _index::16-little, _subindex::8, _rest::binary>>)
       when command in 0x40..0x4F,
       do: {:ok, :upload_init}

  defp mailbox_step_from_body(<<command::8, _rest::binary>>) when command in [0x20, 0x30],
    do: {:ok, :download_segment}

  defp mailbox_step_from_body(<<command::8, _rest::binary>>) when command in 0x00..0x1F,
    do: {:ok, :upload_segment}

  defp mailbox_step_from_body(_body), do: :error
end
