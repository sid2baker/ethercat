defmodule EtherCAT.Simulator.Runtime.Milestones do
  @moduledoc false

  alias EtherCAT.Bus.Datagram
  alias EtherCAT.Simulator.Runtime.Faults
  alias EtherCAT.Simulator.Slave.Runtime.Device
  alias EtherCAT.Slave.ESC.Registers

  @fprd 4
  @op_code 0x08
  @al_status Registers.al_status()

  @type milestone ::
          {:healthy_exchanges, pos_integer()}
          | {:healthy_polls, atom(), pos_integer()}

  @type observations :: %{
          healthy_exchanges: non_neg_integer(),
          healthy_polls: %{optional(atom()) => non_neg_integer()}
        }

  @spec valid?(term()) :: boolean()
  def valid?({:healthy_exchanges, count}) when is_integer(count) and count > 0, do: true

  def valid?({:healthy_polls, slave_name, count})
      when is_atom(slave_name) and is_integer(count) and count > 0,
      do: true

  def valid?(_milestone), do: false

  @spec initial_remaining(milestone()) :: pos_integer()
  def initial_remaining({:healthy_exchanges, count}), do: count
  def initial_remaining({:healthy_polls, _slave_name, count}), do: count

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
      healthy_polls: healthy_poll_counts(datagrams, responses, slaves, exchange_healthy?)
    }
  end

  @spec progress(milestone(), observations()) :: non_neg_integer()
  def progress({:healthy_exchanges, _count}, observations), do: observations.healthy_exchanges

  def progress({:healthy_polls, slave_name, _count}, observations) do
    Map.get(observations.healthy_polls, slave_name, 0)
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
end
