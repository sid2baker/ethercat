defmodule EtherCAT.Simulator.Transport.Udp do
  @moduledoc """
  UDP endpoint for `EtherCAT.Simulator`.

  This binds a real UDP socket and forwards EtherCAT UDP payloads to a running
  simulator segment, so the normal `UdpSocket` transport can talk to simulated
  slaves without any test-specific seam in the master runtime.

  It also owns UDP-edge fault injection for cases that cannot be modeled at the
  datagram-execution layer, such as malformed EtherCAT frame headers,
  deliberately mismatched datagram indices, or stale previous-response replay.

  Supported reply-fault injection forms:

  - `EtherCAT.Simulator.Transport.Udp.Fault.truncate()`
  - `EtherCAT.Simulator.Transport.Udp.Fault.wrong_idx() |> EtherCAT.Simulator.Transport.Udp.Fault.next(count)`
  - `EtherCAT.Simulator.Transport.Udp.Fault.script([mode, ...])`

  Supported modes:

  - `:truncate`
  - `:unsupported_type`
  - `:wrong_idx`
  - `:replay_previous`
  """

  use GenServer

  require Logger

  alias EtherCAT.Bus.Frame
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Transport.Udp.Fault
  alias EtherCAT.Utils

  @type frame_fault_mode :: :truncate | :unsupported_type | :wrong_idx | :replay_previous
  @type fault ::
          {:corrupt_next_response, frame_fault_mode()}
          | {:corrupt_next_responses, pos_integer(), frame_fault_mode()}
          | {:corrupt_response_script, [frame_fault_mode(), ...]}

  @default_port 0x88A4

  @type state :: %{
          socket: :gen_udp.socket(),
          ip: :inet.ip_address(),
          port: :inet.port_number(),
          pending_faults: [frame_fault_mode()],
          last_response_payload: binary() | nil
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

  @spec inject_fault(Fault.t() | fault()) :: :ok | {:error, :invalid_fault | :not_found}
  def inject_fault(fault) do
    case Fault.normalize(fault) do
      {:ok, normalized_fault} ->
        try do
          GenServer.call(__MODULE__, {:inject_fault, normalized_fault})
        catch
          :exit, {:noproc, _} -> {:error, :not_found}
        end

      :error ->
        {:error, :invalid_fault}
    end
  end

  @spec clear_faults() :: :ok | {:error, :not_found}
  def clear_faults do
    GenServer.call(__MODULE__, :clear_faults)
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

        Logger.metadata(
          component: :simulator,
          transport: :udp,
          listen_ip: ip,
          listen_port: actual_port
        )

        {:ok,
         %{
           socket: socket,
           ip: ip,
           port: actual_port,
           pending_faults: [],
           last_response_payload: nil
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:info, _from, state) do
    info = %{
      ip: state.ip,
      port: state.port,
      next_fault: next_fault_info(state.pending_faults),
      pending_faults: state.pending_faults,
      last_response_captured?: not is_nil(state.last_response_payload)
    }

    {:reply, {:ok, info}, state}
  end

  def handle_call({:inject_fault, fault}, _from, state) do
    case expand_fault_plan(fault) do
      {:ok, fault_modes} ->
        {:reply, :ok, %{state | pending_faults: state.pending_faults ++ fault_modes}}

      :error ->
        {:reply, {:error, :invalid_fault}, state}
    end
  end

  def handle_call(:clear_faults, _from, state) do
    {:reply, :ok, %{state | pending_faults: []}}
  end

  @impl true
  def handle_info({:udp, socket, sender_ip, sender_port, payload}, %{socket: socket} = state) do
    next_state =
      case process_payload(state, sender_ip, sender_port, payload) do
        {:ok, next_state} ->
          next_state

        {:error, reason, next_state} ->
          Logger.warning(
            "[EtherCAT.Simulator.Transport.Udp] dropped invalid payload: #{inspect(reason)}",
            event: :invalid_payload_dropped,
            reason_kind: Utils.reason_kind(reason),
            sender_ip: sender_ip,
            sender_port: sender_port
          )

          next_state
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
         {:ok, maybe_faulted_payload, pending_faults} <-
           maybe_apply_reply_fault(
             state.pending_faults,
             state.last_response_payload,
             response_datagrams,
             response_payload
           ),
         :ok <- :gen_udp.send(state.socket, sender_ip, sender_port, maybe_faulted_payload) do
      {:ok, %{state | pending_faults: pending_faults, last_response_payload: response_payload}}
    else
      {:error, :no_response} -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp expand_fault_plan({:corrupt_next_response, mode}) do
    if valid_fault_mode?(mode), do: {:ok, [mode]}, else: :error
  end

  defp expand_fault_plan({:corrupt_next_responses, count, mode})
       when is_integer(count) and count > 0 do
    if valid_fault_mode?(mode), do: {:ok, List.duplicate(mode, count)}, else: :error
  end

  defp expand_fault_plan({:corrupt_response_script, modes}) when is_list(modes) do
    if modes != [] and Enum.all?(modes, &valid_fault_mode?/1), do: {:ok, modes}, else: :error
  end

  defp expand_fault_plan(_fault), do: :error

  defp valid_fault_mode?(mode) do
    mode in [:truncate, :unsupported_type, :wrong_idx, :replay_previous]
  end

  defp next_fault_info([]), do: nil
  defp next_fault_info([mode | _rest]), do: {:corrupt_next_response, mode}

  defp maybe_apply_reply_fault([], _last_response_payload, _response_datagrams, response_payload) do
    {:ok, response_payload, []}
  end

  defp maybe_apply_reply_fault(
         [:truncate | rest],
         _last_response_payload,
         _response_datagrams,
         response_payload
       ) do
    truncated_size = max(byte_size(response_payload) - 1, 0)
    {:ok, binary_part(response_payload, 0, truncated_size), rest}
  end

  defp maybe_apply_reply_fault(
         [:unsupported_type | rest],
         _last_response_payload,
         _response_datagrams,
         <<ecat_header::little-unsigned-16, rest_payload::binary>>
       ) do
    <<_type::4, _reserved::1, len::11>> = <<ecat_header::big-unsigned-16>>
    <<faulted_header::big-unsigned-16>> = <<0::4, 0::1, len::11>>
    {:ok, <<faulted_header::little-unsigned-16, rest_payload::binary>>, rest}
  end

  defp maybe_apply_reply_fault(
         [:wrong_idx | rest],
         _last_response_payload,
         [first | response_rest],
         _response_payload
       ) do
    mutated = [%{first | idx: rem(first.idx + 1, 256)} | response_rest]

    with {:ok, faulted_payload} <- Frame.encode(mutated) do
      {:ok, faulted_payload, rest}
    end
  end

  defp maybe_apply_reply_fault(
         [:wrong_idx | rest],
         _last_response_payload,
         [],
         response_payload
       ) do
    {:ok, response_payload, rest}
  end

  defp maybe_apply_reply_fault(
         [:replay_previous | rest],
         nil,
         _response_datagrams,
         response_payload
       ) do
    {:ok, response_payload, rest}
  end

  defp maybe_apply_reply_fault(
         [:replay_previous | rest],
         last_response_payload,
         _response_datagrams,
         _response_payload
       ) do
    {:ok, last_response_payload, rest}
  end

  defp maybe_apply_reply_fault(
         [mode | _rest],
         _last_response_payload,
         _response_datagrams,
         _response_payload
       ) do
    raise ArgumentError, "unhandled UDP fault mode: #{inspect(mode)}"
  end
end
