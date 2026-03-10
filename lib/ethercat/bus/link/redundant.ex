defmodule EtherCAT.Bus.Link.Redundant do
  @moduledoc false

  @behaviour EtherCAT.Bus.Link

  alias EtherCAT.Bus.InterfaceInfo
  alias EtherCAT.Bus.Frame
  alias EtherCAT.Telemetry

  defstruct [:awaiting, :primary, :primary_opts, :secondary, :secondary_opts, :transport_mod]

  @type awaiting_t :: %{
          primary?: boolean(),
          secondary?: boolean(),
          primary_payload: binary() | nil,
          primary_rx_at: integer() | nil,
          secondary_payload: binary() | nil,
          secondary_rx_at: integer() | nil
        }

  @type t :: %__MODULE__{
          awaiting: awaiting_t | nil,
          primary: EtherCAT.Bus.Transport.t(),
          primary_opts: keyword(),
          secondary: EtherCAT.Bus.Transport.t(),
          secondary_opts: keyword(),
          transport_mod: module()
        }

  @impl true
  def open(opts) do
    transport_mod = Keyword.fetch!(opts, :transport_mod)
    primary_opts = Keyword.put(opts, :interface, Keyword.fetch!(opts, :interface))
    secondary_opts = Keyword.put(opts, :interface, Keyword.fetch!(opts, :backup_interface))

    with {:ok, primary} <- transport_mod.open(primary_opts),
         {:ok, secondary} <- transport_mod.open(secondary_opts) do
      {:ok,
       %__MODULE__{
         awaiting: nil,
         primary: primary,
         primary_opts: primary_opts,
         secondary: secondary,
         secondary_opts: secondary_opts,
         transport_mod: transport_mod
       }}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def send(%__MODULE__{} = link, payload) do
    link = reconnect(link)

    {link, sent_ports, first_error} =
      [:primary, :secondary]
      |> Enum.reduce({link, [], nil}, fn port, {acc, sent, first_error} ->
        case maybe_send_port(acc, port, payload) do
          {:sent, updated} -> {updated, [port | sent], first_error}
          {:skipped, updated} -> {updated, sent, first_error}
          {:failed, updated, reason} -> {updated, sent, first_error || reason}
        end
      end)

    sent_ports = Enum.reverse(sent_ports)

    case sent_ports do
      [] ->
        {:error, clear_awaiting(link), first_error || :down}

      _ ->
        {:ok, %{link | awaiting: new_awaiting(sent_ports)}}
    end
  end

  @impl true
  def match(%__MODULE__{} = link, msg) do
    case match_port(link, :primary, msg) do
      {:matched, updated, payload, rx_at} ->
        store_and_maybe_complete(updated, :primary, payload, rx_at)

      :ignore ->
        case match_port(link, :secondary, msg) do
          {:matched, updated, payload, rx_at} ->
            store_and_maybe_complete(updated, :secondary, payload, rx_at)

          :ignore ->
            {:ignore, link}
        end
    end
  end

  @impl true
  def timeout(%__MODULE__{awaiting: nil} = link), do: {:error, link, :timeout}

  def timeout(%__MODULE__{} = link) do
    case response_payload(link.awaiting) do
      {:ok, payload, rx_at} -> {:ok, link, payload, rx_at}
      :error -> {:error, link, :timeout}
    end
  end

  @impl true
  def rearm(%__MODULE__{awaiting: nil} = link), do: link

  def rearm(%__MODULE__{} = link) do
    awaiting =
      link.awaiting
      |> Map.put(:primary_payload, nil)
      |> Map.put(:primary_rx_at, nil)
      |> Map.put(:secondary_payload, nil)
      |> Map.put(:secondary_rx_at, nil)

    link
    |> arm_expected_port(:primary, awaiting.primary?)
    |> arm_expected_port(:secondary, awaiting.secondary?)
    |> then(&%{&1 | awaiting: awaiting})
  end

  @impl true
  def clear_awaiting(%__MODULE__{} = link), do: %{link | awaiting: nil}

  @impl true
  def drain(%__MODULE__{} = link) do
    link
    |> drain_port(:primary)
    |> drain_port(:secondary)
    |> clear_awaiting()
  end

  @impl true
  def close(%__MODULE__{} = link) do
    link
    |> close_port(:primary)
    |> close_port(:secondary)
    |> clear_awaiting()
  end

  @impl true
  def carrier(%__MODULE__{} = link, ifname, false) do
    {updated, closed?} =
      link
      |> maybe_close_for_interface(:primary, ifname)
      |> maybe_close_for_interface(:secondary, ifname)

    cond do
      not closed? ->
        {:ok, updated}

      usable_after_carrier_loss?(updated) ->
        {:ok, updated}

      true ->
        {:down, updated, :carrier_lost}
    end
  end

  def carrier(%__MODULE__{} = link, _ifname, true), do: {:ok, link}

  @impl true
  def reconnect(%__MODULE__{} = link) do
    link
    |> maybe_reopen_port(:primary)
    |> maybe_reopen_port(:secondary)
  end

  @impl true
  def usable?(%__MODULE__{} = link) do
    open_port?(link, :primary) or open_port?(link, :secondary)
  end

  @impl true
  def needs_reconnect?(%__MODULE__{} = link) do
    not open_port?(link, :primary) or not open_port?(link, :secondary)
  end

  @impl true
  def name(%__MODULE__{} = link) do
    "#{port_name(link, :primary)}|#{port_name(link, :secondary)}"
  end

  @impl true
  def interfaces(%__MODULE__{} = link) do
    [:primary, :secondary]
    |> Enum.map(&port_interface(link, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp maybe_send_port(%__MODULE__{} = link, port, payload) do
    if open_port?(link, port) do
      transport_mod = link.transport_mod
      transport = port_transport(link, port)
      transport_mod.set_active_once(transport)

      case transport_mod.send(transport, payload) do
        {:ok, tx_at} ->
          Telemetry.frame_sent(port_name(link, port), port, byte_size(payload), tx_at)
          {:sent, link}

        {:error, reason} ->
          updated = close_port(link, port)
          Telemetry.link_down(port_name(link, port), reason)
          {:failed, updated, reason}
      end
    else
      {:skipped, link}
    end
  end

  defp match_port(%__MODULE__{} = link, port, msg) do
    if open_port?(link, port) do
      transport = port_transport(link, port)

      case link.transport_mod.match(transport, msg) do
        {:ok, payload, rx_at} ->
          Telemetry.frame_received(port_name(link, port), port, byte_size(payload), rx_at)
          {:matched, link, payload, rx_at}

        :ignore ->
          :ignore
      end
    else
      :ignore
    end
  end

  defp store_and_maybe_complete(%__MODULE__{awaiting: nil} = link, _port, _payload, _rx_at) do
    {:ignore, link}
  end

  defp store_and_maybe_complete(%__MODULE__{} = link, port, payload, rx_at) do
    if awaiting_port?(link.awaiting, port) do
      awaiting = put_response(link.awaiting, port, payload, rx_at)
      updated = %{link | awaiting: awaiting}

      case ready_payload(awaiting) do
        {:ok, complete_payload, complete_rx_at} ->
          {:ok, updated, complete_payload, complete_rx_at}

        :pending ->
          {:pending, updated}
      end
    else
      {:ignore, link}
    end
  end

  defp maybe_close_for_interface(%__MODULE__{} = link, port, ifname) do
    if open_port?(link, port) and port_interface(link, port) == ifname do
      Telemetry.link_down(ifname, :carrier_lost)
      {close_port(link, port), true}
    else
      {link, false}
    end
  end

  defp maybe_close_for_interface({%__MODULE__{} = link, closed?}, port, ifname) do
    if open_port?(link, port) and port_interface(link, port) == ifname do
      Telemetry.link_down(ifname, :carrier_lost)
      {close_port(link, port), true}
    else
      {link, closed?}
    end
  end

  defp maybe_reopen_port(%__MODULE__{} = link, port) do
    if open_port?(link, port) do
      link
    else
      interface = port_interface(link, port)

      if interface && carrier_up?(interface) do
        opts = port_open_opts(link, port)

        case link.transport_mod.open(opts) do
          {:ok, reopened} ->
            Telemetry.link_reconnected(link.transport_mod.name(reopened))
            put_port_transport(link, port, reopened)

          {:error, _} ->
            link
        end
      else
        link
      end
    end
  end

  defp ready_payload(awaiting) do
    cond do
      (awaiting.primary? and awaiting.secondary? and awaiting.primary_payload) &&
          awaiting.secondary_payload ->
        response_payload(awaiting)

      awaiting.primary? and not awaiting.secondary? and awaiting.primary_payload ->
        {:ok, awaiting.primary_payload, awaiting.primary_rx_at}

      awaiting.secondary? and not awaiting.primary? and awaiting.secondary_payload ->
        {:ok, awaiting.secondary_payload, awaiting.secondary_rx_at}

      true ->
        :pending
    end
  end

  defp response_payload(awaiting) do
    cond do
      awaiting.primary_payload && awaiting.secondary_payload ->
        merge_payloads(
          awaiting.primary_payload,
          awaiting.primary_rx_at,
          awaiting.secondary_payload,
          awaiting.secondary_rx_at
        )

      awaiting.primary_payload ->
        {:ok, awaiting.primary_payload, awaiting.primary_rx_at}

      awaiting.secondary_payload ->
        {:ok, awaiting.secondary_payload, awaiting.secondary_rx_at}

      true ->
        :error
    end
  end

  defp merge_payloads(primary_payload, primary_rx_at, secondary_payload, secondary_rx_at) do
    case {Frame.decode(primary_payload), Frame.decode(secondary_payload)} do
      {{:ok, primary_datagrams}, {:ok, secondary_datagrams}} ->
        merged = merge_datagrams(primary_datagrams, secondary_datagrams)

        case Frame.encode(merged) do
          {:ok, payload} -> {:ok, payload, min_timestamp(primary_rx_at, secondary_rx_at)}
          {:error, _} -> {:ok, primary_payload, primary_rx_at}
        end

      _ ->
        {:ok, primary_payload, primary_rx_at}
    end
  end

  defp merge_datagrams(primary_datagrams, secondary_datagrams) do
    secondary_by_idx = Map.new(secondary_datagrams, &{&1.idx, &1})

    Enum.map(primary_datagrams, fn primary ->
      case Map.get(secondary_by_idx, primary.idx) do
        nil -> primary
        secondary -> if secondary.wkc > primary.wkc, do: secondary, else: primary
      end
    end)
  end

  defp min_timestamp(nil, other), do: other
  defp min_timestamp(other, nil), do: other
  defp min_timestamp(left, right), do: min(left, right)

  defp put_response(awaiting, :primary, payload, rx_at) do
    %{awaiting | primary_payload: payload, primary_rx_at: rx_at}
  end

  defp put_response(awaiting, :secondary, payload, rx_at) do
    %{awaiting | secondary_payload: payload, secondary_rx_at: rx_at}
  end

  defp awaiting_port?(awaiting, :primary), do: awaiting.primary?
  defp awaiting_port?(awaiting, :secondary), do: awaiting.secondary?

  defp new_awaiting(sent_ports) do
    %{
      primary?: :primary in sent_ports,
      secondary?: :secondary in sent_ports,
      primary_payload: nil,
      primary_rx_at: nil,
      secondary_payload: nil,
      secondary_rx_at: nil
    }
  end

  defp usable_after_carrier_loss?(%__MODULE__{} = link) do
    usable?(link) or response_available?(link.awaiting)
  end

  defp response_available?(nil), do: false

  defp response_available?(awaiting) do
    not is_nil(awaiting.primary_payload) or not is_nil(awaiting.secondary_payload)
  end

  defp arm_expected_port(%__MODULE__{} = link, port, true) do
    if open_port?(link, port) do
      link.transport_mod.set_active_once(port_transport(link, port))
    end

    link
  end

  defp arm_expected_port(%__MODULE__{} = link, _port, false), do: link

  defp drain_port(%__MODULE__{} = link, port) do
    if open_port?(link, port) do
      link.transport_mod.drain(port_transport(link, port))
    end

    link
  end

  defp close_port(%__MODULE__{} = link, :primary) do
    %{link | primary: link.transport_mod.close(link.primary)}
  end

  defp close_port(%__MODULE__{} = link, :secondary) do
    %{link | secondary: link.transport_mod.close(link.secondary)}
  end

  defp put_port_transport(%__MODULE__{} = link, :primary, transport),
    do: %{link | primary: transport}

  defp put_port_transport(%__MODULE__{} = link, :secondary, transport),
    do: %{link | secondary: transport}

  defp open_port?(%__MODULE__{} = link, :primary), do: link.transport_mod.open?(link.primary)
  defp open_port?(%__MODULE__{} = link, :secondary), do: link.transport_mod.open?(link.secondary)

  defp port_transport(%__MODULE__{} = link, :primary), do: link.primary
  defp port_transport(%__MODULE__{} = link, :secondary), do: link.secondary

  defp port_open_opts(%__MODULE__{} = link, :primary), do: link.primary_opts
  defp port_open_opts(%__MODULE__{} = link, :secondary), do: link.secondary_opts

  defp port_interface(%__MODULE__{} = link, port) do
    link.transport_mod.interface(port_transport(link, port))
  end

  defp port_name(%__MODULE__{} = link, port) do
    link.transport_mod.name(port_transport(link, port))
  end

  defp carrier_up?(interface) do
    InterfaceInfo.carrier_up?(interface)
  end
end
