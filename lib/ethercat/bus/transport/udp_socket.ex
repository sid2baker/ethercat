defmodule EtherCAT.Bus.Transport.UdpSocket do
  @moduledoc """
  UDP/IP transport for simulator and integration endpoints.

  Sends the EtherCAT payload (`Bus.Frame.encode/1` output) inside a UDP datagram,
  using the conventional EtherCAT UDP port `0x88A4` (`34980`) by default. This is
  not the raw Ethernet transport used for ordinary physical EtherCAT rings;
  the destination must explicitly support this encapsulation.

  Implements the `EtherCAT.Bus.Transport` behaviour. Application startup should
  select it through `EtherCAT.Backend`, not by opening a transport directly.

  ## Options

    - `:host` — destination IP tuple (default: `{255, 255, 255, 255}` broadcast)
    - `:port` — local bind and destination UDP port (default: `34980` = `0x88A4`)
    - `:bind_ip` — optional local IP tuple; otherwise binds all local addresses

  A same-host simulator must bind a different local address when sharing the
  port. See `EtherCAT.Simulator` for a Linux loopback example.
  """

  @behaviour EtherCAT.Bus.Transport

  @default_port 0x88A4

  defstruct [:raw, :host, :port]

  @type t :: %__MODULE__{
          raw: :gen_udp.socket() | nil,
          host: :inet.ip_address(),
          port: :inet.port_number()
        }

  @impl true
  @doc "Open a UDP socket bound to the configured port and optional local IP."
  @spec open(keyword()) :: {:ok, t()} | {:error, term()}
  def open(opts) do
    host = opts[:host] || {255, 255, 255, 255}
    port = opts[:port] || @default_port

    # Bind to port 0x88A4 so src port = dst port = 0x88A4 (conventional for EtherCAT UDP).
    # {:active, false} — passive mode; use set_active_once/1 to arm delivery.
    # {:broadcast, true} — allow sending to 255.255.255.255.
    # {:ip, bind_ip} — optional; binds to a specific NIC IP so packets egress the right interface.
    sock_opts =
      [:binary, {:active, false}, {:broadcast, true}] ++
        case opts[:bind_ip] do
          nil -> []
          ip -> [{:ip, ip}]
        end

    case :gen_udp.open(port, sock_opts) do
      {:ok, sock} ->
        {:ok, %__MODULE__{raw: sock, host: host, port: port}}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  @doc "Send an EtherCAT payload as a UDP datagram."
  @spec send(t(), binary()) :: {:ok, integer()} | {:error, term()}
  def send(%__MODULE__{raw: sock, host: host, port: port}, ecat_payload) do
    tx_at = System.monotonic_time()

    case :gen_udp.send(sock, host, port, ecat_payload) do
      :ok -> {:ok, tx_at}
      {:error, _} = err -> err
    end
  end

  @impl true
  @doc "Arm for one async delivery via `{:active, :once}`."
  @spec set_active_once(t()) :: :ok
  def set_active_once(%__MODULE__{raw: sock}) do
    :inet.setopts(sock, [{:active, :once}])
    :ok
  end

  @impl true
  @doc "Re-arm — delegates to `set_active_once/1` (UDP has no drain issue)."
  @spec rearm(t()) :: :ok
  def rearm(%__MODULE__{} = sock), do: set_active_once(sock)

  @impl true
  @doc """
  Match a `{:udp, raw, _ip, _port, data}` message from this socket.

  Returns `{:ok, ecat_payload, rx_at, nil}` when the message belongs to this
  socket. `src_mac` is always `nil` for UDP (no Ethernet headers).
  This function matches socket ownership only; EtherCAT payload validation is
  performed by the link/frame layer.
  """
  @spec match(t(), term()) :: {:ok, binary(), integer(), nil} | :ignore
  def match(%__MODULE__{raw: sock}, {:udp, sock, _ip, _port, data}) do
    {:ok, data, System.monotonic_time(), nil}
  end

  def match(%__MODULE__{}, _msg), do: :ignore

  @impl true
  @doc "Drain buffered datagrams and disable active delivery."
  @spec drain(t()) :: :ok
  def drain(%__MODULE__{raw: sock}) do
    :inet.setopts(sock, [{:active, false}])
    drain_loop(sock)
  end

  @impl true
  @doc "Close the UDP socket. Returns the struct with `raw` set to `nil`."
  @spec close(t()) :: t()
  def close(%__MODULE__{raw: nil} = sock), do: sock

  def close(%__MODULE__{raw: raw} = sock) do
    :gen_udp.close(raw)
    %{sock | raw: nil}
  end

  @impl true
  @doc "Returns `nil` — UDP has no Ethernet-level source MAC."
  @spec src_mac(t()) :: nil
  def src_mac(%__MODULE__{}), do: nil

  @impl true
  @doc "Returns `true` when the socket is open."
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{raw: nil}), do: false
  def open?(%__MODULE__{}), do: true

  @impl true
  @doc "Returns a string identifier for telemetry: `\"host:port\"`."
  @spec name(t()) :: String.t()
  def name(%__MODULE__{host: host, port: port}) do
    "#{:inet.ntoa(host)}:#{port}"
  end

  @impl true
  @doc "Returns `nil` — UDP sockets don't use OS interface link monitoring."
  @spec interface(t()) :: nil
  def interface(%__MODULE__{}), do: nil

  # -- private ----------------------------------------------------------------

  defp drain_loop(sock) do
    case :gen_udp.recv(sock, 0, 0) do
      {:ok, _} -> drain_loop(sock)
      _ -> :ok
    end
  end
end
