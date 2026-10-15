defmodule EtherCAT.Bus.Transport.Bpf do
  @moduledoc """
  Raw Ethernet transport for EtherCAT on macOS, through a BPF device.

  macOS has no `AF_PACKET` sockets, which `EtherCAT.Bus.Transport.RawSocket` uses on Linux. Whole
  Ethernet frames are sent and received through a BPF device (`/dev/bpfN`) instead, with `ioctl`
  calls the BEAM cannot make. So this transport starts a small C program as an Erlang port, a
  process of its own, which opens the device and passes frames of EtherType 0x88A4 both ways. It is
  what `{:raw, %{interface: "en7"}}` uses on macOS; see `EtherCAT.Bus.Transport.raw/0`.

  Implements the `EtherCAT.Bus.Transport` behaviour. A frame that arrives is in the mailbox of the
  process that opened the transport at once, so `set_active_once/1` and `rearm/1` have nothing to
  arm, and `drain/1` takes the frames that are waiting there out of it.

  ## The port program

  The program is `priv/bpf/ethercat_bpf.c`. It is compiled with the system's C compiler the first
  time a transport is opened in each VM, and again when its source changes. It needs the Xcode
  command line tools (`xcode-select --install`) and nothing at build time, on any platform.
  Each build uses a new owner-only temporary directory; existing on-disk executables are never
  trusted as a cache. Successful builds remain in the OS temporary directory for reuse by this VM.

  ## Access

  Opening a BPF device needs read and write access to `/dev/bpf*`: root, or membership of the group
  `access_bpf`, which Wireshark's ChmodBPF sets up.

  ## Timing

  A received frame is stamped when the BEAM takes it from the port, not by the kernel as on Linux,
  so the time it took to come through the port program, some tens of microseconds, is part of
  every round trip. macOS is for a rack on a desk: for timing that matters, run on Linux.
  """

  @behaviour EtherCAT.Bus.Transport

  # Suppress conflict with Kernel.send/2 — this module defines its own send/2
  import Kernel, except: [send: 2]

  alias EtherCAT.Telemetry

  @ethertype 0x88A4
  @broadcast_mac <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>
  @zero_mac <<0, 0, 0, 0, 0, 0>>
  @min_frame_size 60
  @open_timeout_ms 5_000

  defstruct [:port, :interface, :src_mac]

  @type t :: %__MODULE__{
          port: port() | nil,
          interface: String.t(),
          src_mac: <<_::48>>
        }

  @impl true
  @doc "Start the port program on the given interface, and wait until it has the device open."
  @spec open(keyword()) :: {:ok, t()} | {:error, term()}
  def open(opts) do
    interface = Keyword.fetch!(opts, :interface)

    with {:ok, program} <- program() do
      port =
        Port.open({:spawn_executable, program}, [
          :binary,
          :exit_status,
          {:packet, 2},
          args: [interface]
        ])

      receive do
        {^port, {:data, <<?R, src_mac::binary-size(6)>>}} ->
          {:ok, %__MODULE__{port: port, interface: interface, src_mac: src_mac}}

        {^port, {:data, <<?E, reason::binary>>}} ->
          await_exit(port)
          {:error, {:bpf, reason}}

        {^port, {:exit_status, status}} ->
          {:error, {:bpf_port_exited, status}}
      after
        @open_timeout_ms ->
          close_port(port)
          {:error, :bpf_port_timeout}
      end
    end
  end

  @impl true
  @doc "Send an EtherCAT payload wrapped in an Ethernet frame."
  @spec send(t(), binary()) :: {:ok, integer()} | {:error, term()}
  def send(%__MODULE__{port: nil}, _ecat_payload), do: {:error, :closed}

  def send(%__MODULE__{port: port, src_mac: src}, ecat_payload) do
    tx_at = System.monotonic_time()

    frame_body = <<
      @broadcast_mac::binary,
      src::binary-size(6),
      @ethertype::big-unsigned-16,
      ecat_payload::binary
    >>

    pad_needed = max(0, @min_frame_size - byte_size(frame_body))
    frame = <<frame_body::binary, 0::size(pad_needed)-unit(8)>>

    try do
      Port.command(port, frame)
      {:ok, tx_at}
    rescue
      ArgumentError -> {:error, :closed}
    end
  end

  @impl true
  @doc "Nothing to arm: the port program delivers every frame as it comes."
  @spec set_active_once(t()) :: :ok
  def set_active_once(%__MODULE__{}), do: :ok

  @impl true
  @doc "Nothing to re-arm: a frame behind the one just read is in the mailbox already."
  @spec rearm(t()) :: :ok
  def rearm(%__MODULE__{}), do: :ok

  @impl true
  @doc """
  Match a message from this transport's port program.

  A received frame has its Ethernet headers stripped, and comes back as the EtherCAT payload with
  an rx timestamp and the frame's source MAC address (6 bytes). A frame that could not be sent, or
  a port program that has ended, is an error. Returns `:ignore` for all other messages.
  """
  @spec match(t(), term()) :: {:ok, binary(), integer(), binary()} | {:error, term()} | :ignore
  def match(%__MODULE__{port: port} = transport, {port, {:data, <<?F, frame::binary>>}})
      when is_port(port) do
    rx_at = System.monotonic_time()

    case strip_ethernet_headers(frame) do
      {:ok, ecat_payload, frame_src_mac} ->
        {:ok, ecat_payload, rx_at, frame_src_mac}

      {:error, reason} ->
        Telemetry.frame_dropped(transport.interface, byte_size(frame), reason)
        :ignore
    end
  end

  def match(%__MODULE__{port: port}, {port, {:data, <<?S, reason::binary>>}}) when is_port(port),
    do: {:error, {:send_failed, reason}}

  def match(%__MODULE__{port: port}, {port, {:exit_status, status}}) when is_port(port),
    do: {:error, {:bpf_port_exited, status}}

  def match(%__MODULE__{}, _msg), do: :ignore

  @impl true
  @doc "Returns this NIC's source MAC address (6 bytes)."
  @spec src_mac(t()) :: <<_::48>>
  def src_mac(%__MODULE__{src_mac: mac}), do: mac

  @impl true
  @doc "Take the frames that have arrived out of the mailbox."
  @spec drain(t()) :: :ok
  def drain(%__MODULE__{port: nil}), do: :ok

  def drain(%__MODULE__{port: port} = transport) do
    receive do
      {^port, {:data, <<?F, _frame::binary>>}} -> drain(transport)
    after
      0 -> :ok
    end
  end

  @impl true
  @doc "Stop the port program. Returns the struct with `port` set to `nil`."
  @spec close(t()) :: t()
  def close(%__MODULE__{port: nil} = transport), do: transport

  def close(%__MODULE__{port: port} = transport) do
    close_port(port)
    %{transport | port: nil}
  end

  @impl true
  @doc "Returns `true` when the port program is running."
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{port: nil}), do: false
  def open?(%__MODULE__{port: port}), do: Port.info(port) != nil

  @impl true
  @doc "Returns the network interface name for telemetry and link monitoring."
  @spec name(t()) :: String.t()
  def name(%__MODULE__{interface: interface}), do: interface

  @impl true
  @doc "Returns the interface name used by the bus link monitor."
  @spec interface(t()) :: String.t()
  def interface(%__MODULE__{interface: interface}), do: interface

  @doc """
  The port program, compiled securely once per VM and source revision.

  Returns `{:ok, path}`, or `{:error, reason}` when there is no C compiler or it failed.
  """
  @spec program() :: {:ok, String.t()} | {:error, term()}
  def program do
    source = Application.app_dir(:ethercat, "priv/bpf/ethercat_bpf.c")

    EtherCAT.Bus.Transport.Bpf.Program.ensure(source)
  end

  # -- private ----------------------------------------------------------------

  defp close_port(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    flush(port)
  end

  defp await_exit(port) do
    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      1_000 -> close_port(port)
    end
  end

  # What a port that is closed had still sent.
  defp flush(port) do
    receive do
      {^port, _message} -> flush(port)
    after
      0 -> :ok
    end
  end

  defp strip_ethernet_headers(<<
         _dst::binary-size(6),
         src::binary-size(6),
         0x88A4::big-unsigned-16,
         rest::binary
       >>) do
    if valid_source_mac?(src), do: {:ok, rest, src}, else: {:error, :invalid_source_mac}
  end

  # VLAN-tagged frame (802.1Q)
  defp strip_ethernet_headers(<<
         _dst::binary-size(6),
         src::binary-size(6),
         0x8100::big-unsigned-16,
         _vlan::binary-size(2),
         0x88A4::big-unsigned-16,
         rest::binary
       >>) do
    if valid_source_mac?(src), do: {:ok, rest, src}, else: {:error, :invalid_source_mac}
  end

  defp strip_ethernet_headers(_), do: {:error, :not_ethercat}

  defp valid_source_mac?(mac), do: mac not in [@broadcast_mac, @zero_mac]
end
