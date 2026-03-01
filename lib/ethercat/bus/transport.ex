defmodule EtherCAT.Bus.Transport do
  @moduledoc """
  Behaviour for EtherCAT frame transports.

  Modelled after `:gen_udp`'s `{active, once}` pattern:
  arm once, receive one message containing the EtherCAT payload, repeat.

  ## Implementations

    - `EtherCAT.Bus.Transport.RawSocket` — AF_PACKET raw Ethernet
    - `EtherCAT.Bus.Transport.UdpSocket` — UDP/IP encapsulation (spec §2.6)

  ## Async receive flow

      # After sending a frame, arm for one delivery:
      transport_mod.set_active_once(transport)

      # In gen_statem handle_event(:info, msg, :awaiting, data):
      case transport_mod.match(transport, msg) do
        {:ok, ecat_payload, rx_at} -> # process response
        :ignore -> :keep_state_and_data
      end
  """

  @type t :: struct()

  @doc "Open a transport from keyword options."
  @callback open(keyword()) :: {:ok, t()} | {:error, term()}

  @doc """
  Send an EtherCAT payload. Returns monotonic tx timestamp on success.

  The transport is responsible for any outer framing (Ethernet headers,
  UDP/IP headers). The payload is the output of `Bus.Frame.encode/1`.
  """
  @callback send(t(), ecat_payload :: binary()) :: {:ok, tx_at :: integer()} | {:error, term()}

  @doc """
  Arm for exactly one async delivery — analogous to `inet:setopts([{active, once}])`.

  After calling this, the next received frame will be delivered as a message
  to the calling process. Use `match/2` to decode it.

  - `RawSocket`: calls `:socket.recvmsg(:nowait)` to register the kernel select
  - `UdpSocket`: calls `:inet.setopts([{:active, :once}])`
  """
  @callback set_active_once(t()) :: :ok

  @doc """
  Decode one process mailbox message from this transport.

  Returns `{:ok, ecat_payload, rx_at}` when the message belongs to this
  transport and data is ready; `:ignore` for all other messages.

  - `RawSocket`: matches `{:"$socket", raw, :select, _}`, calls `recvmsg`
    internally, strips Ethernet headers. The two-step select dance is hidden.
  - `UdpSocket`: matches `{:udp, raw, _ip, _port, data}` and returns data inline.
  """
  @callback match(t(), msg :: term()) ::
              {:ok, ecat_payload :: binary(), rx_at :: integer()} | :ignore

  @doc "Drain buffered frames and cancel any pending select/active registration."
  @callback drain(t()) :: :ok

  @doc "Close the transport. Returns the struct with the socket set to nil."
  @callback close(t()) :: t()

  @doc "Returns `true` when the transport is open."
  @callback open?(t()) :: boolean()

  @doc """
  Warm up the transport's transmit path.

  Called after `open/1` to pay any cold-start latency (e.g. DMA descriptor
  initialization on some NICs) before real transactions begin.
  Should be a no-op for transports that don't need it.
  """
  @callback warmup(t()) :: :ok | {:error, term()}

  @doc """
  Returns a human-readable transport identifier for telemetry and logging.

  - `RawSocket`: returns the interface name (e.g. `"eth0"`)
  - `UdpSocket`: returns `"host:port"` (e.g. `"192.168.1.1:34980"`)
  """
  @callback name(t()) :: String.t()

  @doc """
  Returns the network interface name, or `nil` if not applicable.

  Used to subscribe to VintageNet carrier events. Returns `nil` for transports
  that don't rely on a named OS interface (e.g. `UdpSocket`).
  """
  @callback interface(t()) :: String.t() | nil
end
