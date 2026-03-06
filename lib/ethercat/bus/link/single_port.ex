defmodule EtherCAT.Bus.Link.SinglePort do
  @moduledoc false

  @behaviour EtherCAT.Bus.Link

  alias EtherCAT.Telemetry

  defstruct [:open_opts, :transport, :transport_mod]

  @type t :: %__MODULE__{
          open_opts: keyword(),
          transport: EtherCAT.Bus.Transport.t(),
          transport_mod: module()
        }

  @impl true
  def open(opts) do
    transport_mod = Keyword.fetch!(opts, :transport_mod)

    case transport_mod.open(opts) do
      {:ok, transport} ->
        {:ok, %__MODULE__{open_opts: opts, transport: transport, transport_mod: transport_mod}}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def send(%__MODULE__{transport: transport, transport_mod: transport_mod} = link, payload) do
    transport_mod.set_active_once(transport)

    case transport_mod.send(transport, payload) do
      {:ok, tx_at} ->
        Telemetry.frame_sent(transport_mod.name(transport), :primary, byte_size(payload), tx_at)
        {:ok, link}

      {:error, reason} ->
        closed = close_transport(link)
        Telemetry.link_down(name(closed), reason)
        {:error, closed, reason}
    end
  end

  @impl true
  def match(%__MODULE__{transport: transport, transport_mod: transport_mod} = link, msg) do
    case transport_mod.match(transport, msg) do
      {:ok, ecat_payload, rx_at} ->
        Telemetry.frame_received(
          transport_mod.name(transport),
          :primary,
          byte_size(ecat_payload),
          rx_at
        )

        {:ok, link, ecat_payload, rx_at}

      :ignore ->
        {:ignore, link}
    end
  end

  @impl true
  def timeout(%__MODULE__{} = link), do: {:error, link, :timeout}

  @impl true
  def rearm(%__MODULE__{transport: transport, transport_mod: transport_mod} = link) do
    transport_mod.set_active_once(transport)
    link
  end

  @impl true
  def clear_awaiting(%__MODULE__{} = link), do: link

  @impl true
  def drain(%__MODULE__{transport: transport, transport_mod: transport_mod} = link) do
    transport_mod.drain(transport)
    link
  end

  @impl true
  def close(%__MODULE__{} = link), do: close_transport(link)

  @impl true
  def carrier(
        %__MODULE__{transport: transport, transport_mod: transport_mod} = link,
        ifname,
        false
      ) do
    if transport_mod.open?(transport) and transport_mod.interface(transport) == ifname do
      closed = close_transport(link)
      Telemetry.link_down(ifname, :carrier_lost)
      {:down, closed, :carrier_lost}
    else
      {:ok, link}
    end
  end

  def carrier(%__MODULE__{} = link, _ifname, true), do: {:ok, link}

  @impl true
  def reconnect(%__MODULE__{transport: transport, transport_mod: transport_mod} = link) do
    if transport_mod.open?(transport) do
      link
    else
      case transport_mod.open(link.open_opts) do
        {:ok, reopened} ->
          Telemetry.link_reconnected(transport_mod.name(reopened))
          %{link | transport: reopened}

        {:error, _} ->
          link
      end
    end
  end

  @impl true
  def usable?(%__MODULE__{transport: transport, transport_mod: transport_mod}) do
    transport_mod.open?(transport)
  end

  @impl true
  def needs_reconnect?(%__MODULE__{} = link), do: not usable?(link)

  @impl true
  def name(%__MODULE__{transport: transport, transport_mod: transport_mod}) do
    transport_mod.name(transport)
  end

  @impl true
  def interfaces(%__MODULE__{transport: transport, transport_mod: transport_mod}) do
    case transport_mod.interface(transport) do
      nil -> []
      iface -> [iface]
    end
  end

  defp close_transport(%__MODULE__{transport: transport, transport_mod: transport_mod} = link) do
    %{link | transport: transport_mod.close(transport)}
  end
end
