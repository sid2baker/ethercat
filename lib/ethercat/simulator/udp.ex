defmodule EtherCAT.Simulator.Udp do
  @moduledoc """
  UDP endpoint for `EtherCAT.Simulator`.

  This binds a real UDP socket and forwards EtherCAT UDP payloads to a running
  simulator segment, so the normal `UdpSocket` transport can talk to simulated
  slaves without any test-specific seam in the master runtime.
  """

  use GenServer

  require Logger

  alias EtherCAT.Bus.Frame
  alias EtherCAT.Simulator

  @default_port 0x88A4

  @type state :: %{
          socket: :gen_udp.socket(),
          ip: :inet.ip_address(),
          port: :inet.port_number()
        }

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec info() :: {:ok, map()} | {:error, term()}
  def info do
    GenServer.call(__MODULE__, :info)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  @impl true
  def init(opts) do
    ip = Keyword.fetch!(opts, :ip)
    port = Keyword.get(opts, :port, @default_port)

    sock_opts = [:binary, {:active, :once}, {:reuseaddr, true}, {:ip, ip}]

    case :gen_udp.open(port, sock_opts) do
      {:ok, socket} ->
        {:ok, {_bound_ip, actual_port}} = :inet.sockname(socket)
        {:ok, %{socket: socket, ip: ip, port: actual_port}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply, {:ok, %{ip: state.ip, port: state.port}}, state}
  end

  @impl true
  def handle_info({:udp, socket, sender_ip, sender_port, payload}, %{socket: socket} = state) do
    next_state =
      case process_payload(state, sender_ip, sender_port, payload) do
        :ok ->
          state

        {:error, reason} ->
          Logger.warning("[EtherCAT.Simulator.Udp] dropped invalid payload: #{inspect(reason)}")
          state
      end

    :inet.setopts(socket, [{:active, :once}])
    {:noreply, next_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{socket: socket}) do
    :gen_udp.close(socket)
    :ok
  end

  defp process_payload(state, sender_ip, sender_port, payload) do
    with {:ok, datagrams} <- Frame.decode(payload),
         {:ok, response_datagrams} <- Simulator.process_datagrams(datagrams),
         {:ok, response_payload} <- Frame.encode(response_datagrams),
         :ok <- :gen_udp.send(state.socket, sender_ip, sender_port, response_payload) do
      :ok
    else
      {:error, :no_response} -> :ok
    end
  end
end
