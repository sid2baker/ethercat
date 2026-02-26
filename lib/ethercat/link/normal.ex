defmodule EtherCAT.Link.Normal do
  @moduledoc """
  Single-port EtherCAT link.

  ## States

    - `:idle`     — socket open, ready for transactions
    - `:awaiting` — frame sent, waiting for response (new calls postponed)
    - `:down`     — socket lost, waiting for carrier

  Subscribes to VintageNet `lower_up` property for proactive carrier
  detection — transitions to `:down` immediately when the cable is pulled.
  """

  @behaviour :gen_statem

  alias EtherCAT.Link.{Frame, Socket}
  alias EtherCAT.Telemetry

  @debounce_interval 200

  defstruct [:sock, :idx, :from, :expected_idx, :tx_at]

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(opts) do
    interface = Keyword.fetch!(opts, :interface)
    VintageNet.subscribe(["interface", interface, "lower_up"])

    case Socket.open(interface) do
      {:ok, sock} ->
        {:ok, :idle, %__MODULE__{sock: sock, idx: 0}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # -- VintageNet carrier detection (any state) --------------------------------

  @impl true
  def handle_event(
        :info,
        {VintageNet, ["interface", _, "lower_up"], _old, false, _meta},
        state,
        data
      )
      when state != :down do
    Telemetry.socket_down(data.sock.interface, :carrier_lost)

    case state do
      :awaiting ->
        {:next_state, :down, data, [{:reply, data.from, {:error, :down}}]}

      :idle ->
        {:next_state, :down, data}
    end
  end

  # Carrier restored — debounce before reconnecting (NICs flap on replug)
  def handle_event(
        :info,
        {VintageNet, ["interface", _, "lower_up"], _old, true, _meta},
        :down,
        _data
      ) do
    {:keep_state_and_data, [{:state_timeout, @debounce_interval, :reconnect}]}
  end

  # Ignore other VintageNet messages
  def handle_event(:info, {VintageNet, _, _, _, _}, _state, _data) do
    :keep_state_and_data
  end

  # -- idle -------------------------------------------------------------------

  def handle_event(:enter, _old, :idle, _data), do: :keep_state_and_data

  def handle_event({:call, from}, {:transact, datagrams}, :idle, data) do
    <<idx>> = <<data.idx::8>>
    stamped = Enum.map(datagrams, &%{&1 | idx: idx})

    with {:ok, frame} <- Frame.encode(stamped, data.sock.src_mac),
         {:ok, tx_at} <- Socket.send(data.sock, frame) do
      Telemetry.frame_sent(data.sock.interface, :primary, byte_size(frame), tx_at)
      Socket.recv_async(data.sock)

      new_data = %{data | idx: data.idx + 1, from: from, expected_idx: idx, tx_at: tx_at}
      {:next_state, :awaiting, new_data, [{:state_timeout, 100, :timeout}]}
    else
      {:error, :frame_too_large} = err ->
        {:keep_state_and_data, [{:reply, from, err}]}

      {:error, reason} ->
        Telemetry.socket_down(data.sock.interface, reason)
        {:next_state, :down, data, [{:reply, from, {:error, :down}}]}
    end
  end

  # -- awaiting ---------------------------------------------------------------

  def handle_event(:enter, _old, :awaiting, _data), do: :keep_state_and_data

  def handle_event({:call, _from}, {:transact, _}, :awaiting, data) do
    Telemetry.transact_postponed(data.sock.interface)
    {:keep_state_and_data, [:postpone]}
  end

  def handle_event(
        :info,
        {:"$socket", raw, :select, _ref},
        :awaiting,
        %{sock: %{raw: raw}} = data
      ) do
    case Socket.recv(data.sock) do
      {:ok, raw_frame, rx_at} ->
        Telemetry.frame_received(data.sock.interface, :primary, byte_size(raw_frame), rx_at)
        handle_response(raw_frame, rx_at, data)

      {:select, _} ->
        :keep_state_and_data

      {:error, reason} ->
        Telemetry.socket_down(data.sock.interface, reason)
        {:next_state, :down, data, [{:reply, data.from, {:error, :down}}]}
    end
  end

  def handle_event(:state_timeout, :timeout, :awaiting, data) do
    reply_and_idle(data, {:error, :timeout})
  end

  # -- down -------------------------------------------------------------------

  def handle_event(:enter, _old, :down, data) do
    sock = Socket.close(data.sock)
    {:keep_state, %{data | sock: sock}}
  end

  def handle_event(:state_timeout, :reconnect, :down, data) do
    if carrier_up?(data.sock.interface) do
      case Socket.open(data.sock.interface) do
        {:ok, sock} ->
          Telemetry.socket_reconnected(sock.interface)
          {:next_state, :idle, %{data | sock: sock}}

        {:error, _} ->
          :keep_state_and_data
      end
    else
      :keep_state_and_data
    end
  end

  def handle_event({:call, from}, {:transact, _}, :down, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :down}}]}
  end

  # -- catch-all --------------------------------------------------------------

  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  # -- internal ---------------------------------------------------------------

  defp handle_response(raw_frame, _rx_at, data) do
    case Frame.decode(raw_frame) do
      {:ok, datagrams, _src_mac} ->
        matching = Enum.filter(datagrams, &(&1.idx == data.expected_idx))

        if matching != [] do
          reply_and_idle(data, {:ok, matching})
        else
          Telemetry.frame_dropped(data.sock.interface, byte_size(raw_frame), :idx_mismatch)
          Socket.recv_async(data.sock)
          :keep_state_and_data
        end

      {:error, _} ->
        Telemetry.frame_dropped(data.sock.interface, byte_size(raw_frame), :decode_error)
        Socket.recv_async(data.sock)
        :keep_state_and_data
    end
  end

  defp reply_and_idle(data, reply) do
    {:next_state, :idle, %{data | from: nil, expected_idx: nil, tx_at: nil},
     [{:reply, data.from, reply}]}
  end

  defp carrier_up?(interface) do
    VintageNet.get(["interface", interface, "lower_up"]) == true
  end
end
