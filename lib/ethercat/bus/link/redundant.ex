defmodule EtherCAT.Bus.Link.Redundant do
  @moduledoc """
  Redundant dual-link adapter for EtherCAT bus I/O.

  The same EtherCAT payload is transmitted on both master links and the
  returned datagrams are merged into a single reply.

  ## Physical path model

  Healthy ring:

  - the primary-originated frame traverses slaves in forward station order and
    returns on the secondary port with slave data
  - the secondary-originated frame traverses the healthy line in reverse and
    returns on the primary port as an unchanged passthrough copy

  Single break between two slave groups:

  - the primary-originated frame processes the left side up to the break and
    bounces back to the primary port
  - the secondary-originated frame reaches the break in reverse, then
    processes the right side in forward station order on the way back to the
    secondary port

  This means a healthy redundant exchange usually yields one processed reply
  plus one reverse-path passthrough copy, while a single break yields two
  complementary partial replies.

  ## Merge model

  This adapter is transport-level. It assumes the underlying transports return
  the physically correct per-port payloads.

  When both replies are available:

  - working counters are summed
  - logical datagram payloads are merged against the original sent payload so
    complementary process-data halves survive a single break
  - non-logical datagrams keep the side with the stronger WKC

  When only one reply is available by timeout, that partial reply is surfaced.
  """

  @behaviour EtherCAT.Bus.Link

  alias EtherCAT.Bus.InterfaceInfo
  alias EtherCAT.Bus.Frame
  alias EtherCAT.Telemetry

  defstruct [
    :awaiting,
    :primary,
    :primary_opts,
    :primary_carrier_state,
    :secondary,
    :secondary_opts,
    :secondary_carrier_state,
    :transport_mod,
    primary_rejoin_warmup: 0,
    secondary_rejoin_warmup: 0
  ]

  @type awaiting_t :: %{
          primary?: boolean(),
          secondary?: boolean(),
          sent_payload: binary(),
          primary_payload: binary() | nil,
          primary_rx_at: integer() | nil,
          secondary_payload: binary() | nil,
          secondary_rx_at: integer() | nil
        }

  @type t :: %__MODULE__{
          awaiting: awaiting_t | nil,
          primary: EtherCAT.Bus.Transport.t(),
          primary_opts: keyword(),
          primary_carrier_state: boolean() | :unknown,
          primary_rejoin_warmup: non_neg_integer(),
          secondary: EtherCAT.Bus.Transport.t(),
          secondary_opts: keyword(),
          secondary_carrier_state: boolean() | :unknown,
          secondary_rejoin_warmup: non_neg_integer(),
          transport_mod: module()
        }

  @rejoin_warmup_cycles 1

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
         primary_carrier_state: :unknown,
         primary_rejoin_warmup: 0,
         secondary: secondary,
         secondary_opts: secondary_opts,
         secondary_carrier_state: :unknown,
         secondary_rejoin_warmup: 0,
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
    send_ports = send_ports(link)

    {link, sent_ports, first_error} =
      send_ports
      |> Enum.reduce({link, [], nil}, fn port, {acc, sent, first_error} ->
        case maybe_send_port(acc, port, payload) do
          {:sent, updated} -> {updated, [port | sent], first_error}
          {:skipped, updated} -> {updated, sent, first_error}
          {:failed, updated, reason} -> {updated, sent, first_error || reason}
        end
      end)
      |> then(fn {updated, sent, error} -> {advance_rejoin_warmup(updated), sent, error} end)

    sent_ports = Enum.reverse(sent_ports)

    case sent_ports do
      [] ->
        {:error, clear_awaiting(link), first_error || :down}

      _ ->
        {:ok, %{link | awaiting: new_awaiting(sent_ports, payload)}}
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

  def carrier(%__MODULE__{} = link, ifname, true) do
    {:ok,
     link
     |> maybe_mark_carrier(:primary, ifname, true)
     |> maybe_mark_carrier(:secondary, ifname, true)}
  end

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
          Telemetry.frame_sent(name(link), port_name(link, port), port, byte_size(payload), tx_at)
          {:sent, link}

        {:error, reason} ->
          updated = close_port(link, port)
          Telemetry.link_down(name(link), port_name(link, port), reason)
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
          Telemetry.frame_received(
            name(link),
            port_name(link, port),
            port,
            byte_size(payload),
            rx_at
          )

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
      Telemetry.link_down(name(link), ifname, :carrier_lost)
      {link |> close_port(port) |> put_carrier_state(port, false), true}
    else
      {link, false}
    end
  end

  defp maybe_close_for_interface({%__MODULE__{} = link, closed?}, port, ifname) do
    if open_port?(link, port) and port_interface(link, port) == ifname do
      Telemetry.link_down(name(link), ifname, :carrier_lost)
      {link |> close_port(port) |> put_carrier_state(port, false), true}
    else
      {link, closed?}
    end
  end

  defp maybe_mark_carrier(%__MODULE__{} = link, port, ifname, state) do
    if port_interface(link, port) == ifname do
      put_carrier_state(link, port, state)
    else
      link
    end
  end

  defp maybe_reopen_port(%__MODULE__{} = link, port) do
    if open_port?(link, port) do
      link
    else
      interface = port_interface(link, port)

      if interface && reopen_allowed?(link, port, interface) do
        opts = port_open_opts(link, port)

        case link.transport_mod.open(opts) do
          {:ok, reopened} ->
            link.transport_mod.drain(reopened)
            Telemetry.link_reconnected(name(link), link.transport_mod.name(reopened))

            link
            |> put_port_transport(port, reopened)
            |> arm_rejoin_warmup(port)

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
          awaiting.sent_payload,
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

  defp merge_payloads(
         sent_payload,
         primary_payload,
         primary_rx_at,
         secondary_payload,
         secondary_rx_at
       ) do
    case {
      Frame.decode(sent_payload),
      Frame.decode(primary_payload),
      Frame.decode(secondary_payload)
    } do
      {{:ok, sent_datagrams}, {:ok, primary_datagrams}, {:ok, secondary_datagrams}} ->
        merged = merge_datagrams(sent_datagrams, primary_datagrams, secondary_datagrams)

        case Frame.encode(merged) do
          {:ok, payload} -> {:ok, payload, min_timestamp(primary_rx_at, secondary_rx_at)}
          {:error, _} -> {:ok, primary_payload, primary_rx_at}
        end

      _ ->
        {:ok, primary_payload, primary_rx_at}
    end
  end

  defp merge_datagrams(sent_datagrams, primary_datagrams, secondary_datagrams) do
    primary_by_idx = Map.new(primary_datagrams, &{&1.idx, &1})
    secondary_by_idx = Map.new(secondary_datagrams, &{&1.idx, &1})

    Enum.map(sent_datagrams, fn sent ->
      primary = Map.get(primary_by_idx, sent.idx)
      secondary = Map.get(secondary_by_idx, sent.idx)
      merge_datagram(sent, primary, secondary)
    end)
  end

  defp merge_datagram(sent, nil, nil), do: sent
  defp merge_datagram(_sent, primary, nil), do: primary
  defp merge_datagram(_sent, nil, secondary), do: secondary

  defp merge_datagram(sent, primary, secondary) do
    preferred = preferred_datagram(primary, secondary)

    %{
      preferred
      | data: merge_data(sent, primary, secondary, preferred),
        wkc: primary.wkc + secondary.wkc,
        circular: primary.circular or secondary.circular
    }
  end

  defp merge_data(
         %{cmd: cmd, data: sent_data},
         %{data: primary_data},
         %{data: secondary_data},
         _preferred
       )
       when cmd in [10, 11, 12] and
              byte_size(sent_data) == byte_size(primary_data) and
              byte_size(sent_data) == byte_size(secondary_data) do
    merge_logical_data(
      sent_data,
      primary_data,
      secondary_data,
      preferred_side(primary_data, secondary_data, sent_data)
    )
  end

  defp merge_data(_sent, _primary, _secondary, preferred), do: preferred.data

  defp merge_logical_data(<<>>, <<>>, <<>>, _preferred_side), do: <<>>

  defp merge_logical_data(
         <<sent_byte, sent_rest::binary>>,
         <<primary_byte, primary_rest::binary>>,
         <<secondary_byte, secondary_rest::binary>>,
         preferred_side
       ) do
    merged_byte =
      cond do
        primary_byte != sent_byte and secondary_byte == sent_byte ->
          primary_byte

        secondary_byte != sent_byte and primary_byte == sent_byte ->
          secondary_byte

        primary_byte != sent_byte and secondary_byte != sent_byte and
            primary_byte == secondary_byte ->
          primary_byte

        primary_byte != sent_byte and secondary_byte != sent_byte and preferred_side == :secondary ->
          secondary_byte

        primary_byte != sent_byte ->
          primary_byte

        secondary_byte != sent_byte ->
          secondary_byte

        true ->
          sent_byte
      end

    <<
      merged_byte,
      merge_logical_data(sent_rest, primary_rest, secondary_rest, preferred_side)::binary
    >>
  end

  defp preferred_side(primary_data, secondary_data, sent_data) do
    primary_changed? = primary_data != sent_data
    secondary_changed? = secondary_data != sent_data

    cond do
      primary_changed? and not secondary_changed? -> :primary
      secondary_changed? and not primary_changed? -> :secondary
      true -> :primary
    end
  end

  defp preferred_side(primary, secondary) do
    if secondary.wkc > primary.wkc, do: :secondary, else: :primary
  end

  defp preferred_datagram(primary, secondary) do
    if preferred_side(primary, secondary) == :secondary, do: secondary, else: primary
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

  defp new_awaiting(sent_ports, sent_payload) do
    %{
      primary?: :primary in sent_ports,
      secondary?: :secondary in sent_ports,
      sent_payload: sent_payload,
      primary_payload: nil,
      primary_rx_at: nil,
      secondary_payload: nil,
      secondary_rx_at: nil
    }
  end

  defp usable_after_carrier_loss?(%__MODULE__{} = link) do
    usable?(link) or response_available?(link.awaiting)
  end

  defp send_ports(%__MODULE__{} = link) do
    open_ports =
      [:primary, :secondary]
      |> Enum.filter(&open_port?(link, &1))

    case Enum.reject(open_ports, &warming_up?(link, &1)) do
      [] -> open_ports
      ready_ports -> ready_ports
    end
  end

  defp response_available?(nil), do: false

  defp response_available?(awaiting) do
    not is_nil(awaiting.primary_payload) or not is_nil(awaiting.secondary_payload)
  end

  defp arm_expected_port(%__MODULE__{} = link, port, true) do
    if open_port?(link, port) do
      link.transport_mod.rearm(port_transport(link, port))
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
    %{link | primary: link.transport_mod.close(link.primary), primary_rejoin_warmup: 0}
  end

  defp close_port(%__MODULE__{} = link, :secondary) do
    %{link | secondary: link.transport_mod.close(link.secondary), secondary_rejoin_warmup: 0}
  end

  defp put_port_transport(%__MODULE__{} = link, :primary, transport),
    do: %{link | primary: transport}

  defp put_port_transport(%__MODULE__{} = link, :secondary, transport),
    do: %{link | secondary: transport}

  defp put_carrier_state(%__MODULE__{} = link, :primary, state),
    do: %{link | primary_carrier_state: state}

  defp put_carrier_state(%__MODULE__{} = link, :secondary, state),
    do: %{link | secondary_carrier_state: state}

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

  defp reopen_allowed?(%__MODULE__{} = link, :primary, interface) do
    case link.primary_carrier_state do
      true -> true
      false -> false
      :unknown -> carrier_up?(interface)
    end
  end

  defp reopen_allowed?(%__MODULE__{} = link, :secondary, interface) do
    case link.secondary_carrier_state do
      true -> true
      false -> false
      :unknown -> carrier_up?(interface)
    end
  end

  defp carrier_up?(interface) do
    InterfaceInfo.carrier_up?(interface)
  end

  defp arm_rejoin_warmup(%__MODULE__{} = link, :primary),
    do: %{link | primary_rejoin_warmup: @rejoin_warmup_cycles}

  defp arm_rejoin_warmup(%__MODULE__{} = link, :secondary),
    do: %{link | secondary_rejoin_warmup: @rejoin_warmup_cycles}

  defp advance_rejoin_warmup(%__MODULE__{} = link) do
    link
    |> decrement_rejoin_warmup(:primary)
    |> decrement_rejoin_warmup(:secondary)
  end

  defp decrement_rejoin_warmup(%__MODULE__{} = link, :primary) do
    %{link | primary_rejoin_warmup: decrement_rejoin_counter(link.primary_rejoin_warmup)}
  end

  defp decrement_rejoin_warmup(%__MODULE__{} = link, :secondary) do
    %{link | secondary_rejoin_warmup: decrement_rejoin_counter(link.secondary_rejoin_warmup)}
  end

  defp decrement_rejoin_counter(counter) when counter > 0, do: counter - 1
  defp decrement_rejoin_counter(counter), do: counter

  defp warming_up?(%__MODULE__{primary_rejoin_warmup: counter}, :primary), do: counter > 0
  defp warming_up?(%__MODULE__{secondary_rejoin_warmup: counter}, :secondary), do: counter > 0
end
