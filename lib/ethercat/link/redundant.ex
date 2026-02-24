defmodule EtherCAT.Link.Redundant do
  @moduledoc """
  Dual-port redundant EtherCAT link.

  Sends each frame on both sockets. Per-datagram merge picks the higher WKC.

  ## States

    - `:idle`     — both sockets open
    - `{:awaiting, mode}` — frame(s) sent, collecting responses
    - `:degraded` — one socket lost, operates single-port while reconnecting
    - `:down`     — both sockets lost, reconnecting
  """

  @behaviour :gen_statem

  alias EtherCAT.{Frame, Telemetry}
  alias EtherCAT.Link.Socket

  @reconnect_interval 1_000

  defstruct [
    :interface,
    :backup_interface,
    :primary,
    :secondary,
    :idx,
    :from,
    :expected_idx,
    primary_result: nil,
    secondary_result: nil
  ]

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(opts) do
    interface = Keyword.fetch!(opts, :interface)
    backup = Keyword.fetch!(opts, :backup_interface)

    data = %__MODULE__{interface: interface, backup_interface: backup, idx: 0}

    with {:ok, pri} <- Socket.open(interface),
         {:ok, sec} <- Socket.open(backup) do
      {:ok, :idle, %{data | primary: pri, secondary: sec}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # -- idle -------------------------------------------------------------------

  @impl true
  def handle_event(:enter, _old, :idle, _data), do: :keep_state_and_data

  def handle_event({:call, from}, {:transact, datagrams}, :idle, data) do
    send_to_both(datagrams, from, data)
  end

  # -- awaiting ---------------------------------------------------------------

  def handle_event(:enter, _old, {:awaiting, _}, _data), do: :keep_state_and_data

  def handle_event({:call, _from}, {:transact, _}, {:awaiting, _}, _data) do
    {:keep_state_and_data, [:postpone]}
  end

  def handle_event(
        :info,
        {:"$socket", raw, :select, _ref},
        {:awaiting, mode},
        %{primary: %{raw: raw}} = data
      )
      when mode in [:both, :primary_only] do
    handle_recv(:primary, data.primary, mode, data)
  end

  def handle_event(
        :info,
        {:"$socket", raw, :select, _ref},
        {:awaiting, mode},
        %{secondary: %{raw: raw}} = data
      )
      when mode in [:both, :secondary_only] do
    handle_recv(:secondary, data.secondary, mode, data)
  end

  def handle_event(:state_timeout, :timeout, {:awaiting, _}, data) do
    case {data.primary_result, data.secondary_result} do
      {nil, nil} -> reply_and_transition(data, {:error, :timeout})
      _ -> reply_and_transition(data, {:ok, merge(data.primary_result, data.secondary_result)})
    end
  end

  # -- degraded ---------------------------------------------------------------

  def handle_event(:enter, _old, :degraded, _data) do
    {:keep_state_and_data, [{:state_timeout, @reconnect_interval, :reconnect}]}
  end

  def handle_event(:state_timeout, :reconnect, :degraded, data) do
    data = try_reconnect(data)

    if data.primary && data.secondary do
      {:next_state, :idle, data}
    else
      {:keep_state, data, [{:state_timeout, @reconnect_interval, :reconnect}]}
    end
  end

  def handle_event({:call, from}, {:transact, datagrams}, :degraded, data) do
    send_single(datagrams, from, data)
  end

  # -- down -------------------------------------------------------------------

  def handle_event(:enter, _old, :down, data) do
    {:keep_state, close_sockets(data), [{:state_timeout, @reconnect_interval, :reconnect}]}
  end

  def handle_event(:state_timeout, :reconnect, :down, data) do
    data = try_reconnect(data)

    cond do
      data.primary && data.secondary -> {:next_state, :idle, data}
      data.primary || data.secondary -> {:next_state, :degraded, data}
      true -> {:keep_state, data, [{:state_timeout, @reconnect_interval, :reconnect}]}
    end
  end

  def handle_event({:call, from}, {:transact, _}, :down, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :down}}]}
  end

  # -- catch-all --------------------------------------------------------------

  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  # -- sending ----------------------------------------------------------------

  defp send_to_both(datagrams, from, data) do
    <<idx>> = <<data.idx::8>>
    stamped = Enum.map(datagrams, &%{&1 | idx: idx})
    src_mac = data.primary.src_mac

    case Frame.encode(stamped, src_mac) do
      {:error, :frame_too_large} = err ->
        {:keep_state_and_data, [{:reply, from, err}]}

      {:ok, frame} ->
        size = byte_size(frame)
        pri_res = Socket.send(data.primary, frame)
        sec_res = Socket.send(data.secondary, frame)

        case {pri_res, sec_res} do
          {{:ok, tx}, {:ok, tx2}} ->
            Telemetry.frame_sent(data.primary.interface, :primary, size, tx)
            Telemetry.frame_sent(data.secondary.interface, :secondary, size, tx2)
            Socket.recv_async(data.primary)
            Socket.recv_async(data.secondary)
            await(data, from, idx, :both)

          {{:ok, tx}, {:error, reason}} ->
            Telemetry.frame_sent(data.primary.interface, :primary, size, tx)
            Telemetry.socket_down(data.secondary.interface, reason)
            Socket.recv_async(data.primary)
            await(%{data | secondary: nil}, from, idx, :primary_only)

          {{:error, reason}, {:ok, tx}} ->
            Telemetry.frame_sent(data.secondary.interface, :secondary, size, tx)
            Telemetry.socket_down(data.primary.interface, reason)
            Socket.recv_async(data.secondary)
            await(%{data | primary: nil}, from, idx, :secondary_only)

          {{:error, r1}, {:error, r2}} ->
            Telemetry.socket_down(data.primary.interface, r1)
            Telemetry.socket_down(data.secondary.interface, r2)
            {:next_state, :down, close_sockets(data), [{:reply, from, {:error, :down}}]}
        end
    end
  end

  defp send_single(datagrams, from, data) do
    <<idx>> = <<data.idx::8>>
    stamped = Enum.map(datagrams, &%{&1 | idx: idx})

    {sock, port} =
      if data.primary,
        do: {data.primary, :primary},
        else: {data.secondary, :secondary}

    case Frame.encode(stamped, sock.src_mac) do
      {:error, :frame_too_large} = err ->
        {:keep_state_and_data, [{:reply, from, err}]}

      {:ok, frame} ->
        case Socket.send(sock, frame) do
          {:ok, tx} ->
            Telemetry.frame_sent(sock.interface, port, byte_size(frame), tx)
            Socket.recv_async(sock)
            mode = if port == :primary, do: :primary_only, else: :secondary_only
            await(data, from, idx, mode)

          {:error, reason} ->
            Telemetry.socket_down(sock.interface, reason)
            {:next_state, :down, close_sockets(data), [{:reply, from, {:error, :down}}]}
        end
    end
  end

  defp await(data, from, idx, mode) do
    new_data = %{
      data
      | idx: data.idx + 1,
        from: from,
        expected_idx: idx,
        primary_result: if(mode == :secondary_only, do: [], else: nil),
        secondary_result: if(mode == :primary_only, do: [], else: nil)
    }

    {:next_state, {:awaiting, mode}, new_data, [{:state_timeout, 100, :timeout}]}
  end

  # -- receiving --------------------------------------------------------------

  defp handle_recv(which, sock, mode, data) do
    case Socket.recv(sock) do
      {:ok, raw, rx_at} ->
        Telemetry.frame_received(sock.interface, which, byte_size(raw), rx_at)

        case decode_matching(raw, data.expected_idx) do
          {:ok, dgs} ->
            data = store(data, which, dgs)
            maybe_complete(data, mode)

          :skip ->
            Telemetry.frame_dropped(sock.interface, byte_size(raw), :idx_mismatch)
            Socket.recv_async(sock)
            :keep_state_and_data
        end

      {:select, _} ->
        :keep_state_and_data

      {:error, reason} ->
        Telemetry.socket_down(sock.interface, reason)
        data = store(data, which, [])
        maybe_complete(data, mode)
    end
  end

  defp decode_matching(raw, expected_idx) do
    with {:ok, datagrams, _src_mac} <- Frame.decode(raw),
         [_ | _] = matching <- Enum.filter(datagrams, &(&1.idx == expected_idx)) do
      {:ok, matching}
    else
      _ -> :skip
    end
  end

  defp store(data, :primary, result), do: %{data | primary_result: result}
  defp store(data, :secondary, result), do: %{data | secondary_result: result}

  defp maybe_complete(%{primary_result: p, secondary_result: s} = data, _mode)
       when not is_nil(p) and not is_nil(s) do
    reply_and_transition(data, {:ok, merge(p, s)})
  end

  defp maybe_complete(data, _mode), do: {:keep_state, data}

  # -- merge ------------------------------------------------------------------

  @doc false
  def merge([], dgs), do: dgs
  def merge(dgs, []), do: dgs

  def merge(a, b) do
    Enum.zip(a, b)
    |> Enum.map(fn {p, s} -> if p.wkc >= s.wkc, do: p, else: s end)
  end

  # -- state transitions ------------------------------------------------------

  defp reply_and_transition(data, reply) do
    next =
      cond do
        data.primary && data.secondary -> :idle
        data.primary || data.secondary -> :degraded
        true -> :down
      end

    clean = %{data | from: nil, expected_idx: nil, primary_result: nil, secondary_result: nil}
    {:next_state, next, clean, [{:reply, data.from, reply}]}
  end

  defp close_sockets(data) do
    if data.primary, do: Socket.close(data.primary)
    if data.secondary, do: Socket.close(data.secondary)
    %{data | primary: nil, secondary: nil}
  end

  defp try_reconnect(data) do
    data =
      if is_nil(data.primary) do
        case Socket.open(data.interface) do
          {:ok, sock} ->
            Telemetry.socket_reconnected(sock.interface)
            %{data | primary: sock}

          {:error, _} ->
            data
        end
      else
        data
      end

    if is_nil(data.secondary) do
      case Socket.open(data.backup_interface) do
        {:ok, sock} ->
          Telemetry.socket_reconnected(sock.interface)
          %{data | secondary: sock}

        {:error, _} ->
          data
      end
    else
      data
    end
  end
end
