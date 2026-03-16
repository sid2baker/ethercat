defmodule EtherCAT.Bus.Circuit.Redundant do
  @moduledoc """
  Dual-port circuit implementation for one EtherCAT exchange.

  The circuit always attempts to send on both currently usable ports and then
  interprets the observed returns as a per-exchange redundant-path observation.
  Topology is derived from the replies themselves, not from carrier events.
  """

  @behaviour EtherCAT.Bus.Circuit

  require Logger

  alias EtherCAT.Bus.{Frame, Observation}
  alias EtherCAT.Bus.Circuit.{Exchange, Port, RedundantMerge}
  alias EtherCAT.Telemetry

  @default_send_backoff_ms 50

  @enforce_keys [:open_opts, :primary, :secondary]
  defstruct [
    :open_opts,
    :primary,
    :secondary,
    send_backoff_ms: @default_send_backoff_ms,
    reply_grace_ms: nil
  ]

  @type t :: %__MODULE__{
          open_opts: keyword(),
          primary: Port.t(),
          secondary: Port.t(),
          send_backoff_ms: non_neg_integer(),
          reply_grace_ms: non_neg_integer()
        }

  @impl true
  def open(opts) do
    transport_mod = Keyword.fetch!(opts, :transport_mod)
    primary_opts = opts
    secondary_opts = Keyword.put(opts, :interface, Keyword.fetch!(opts, :backup_interface))
    send_backoff_ms = Keyword.get(opts, :send_backoff_ms, @default_send_backoff_ms)
    frame_timeout_ms = Keyword.get(opts, :frame_timeout_ms, 25)
    reply_grace_ms = Keyword.get(opts, :reply_grace_ms, default_reply_grace_ms(frame_timeout_ms))

    case Port.open(:primary, transport_mod, primary_opts) do
      {:ok, primary} ->
        open_secondary(
          opts,
          send_backoff_ms,
          reply_grace_ms,
          transport_mod,
          primary,
          secondary_opts
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def begin_exchange(%__MODULE__{} = circuit, %Exchange{} = exchange) do
    now_ms = System.monotonic_time(:millisecond)
    circuit = maybe_reopen_ports(circuit, now_ms)

    {circuit, primary_obs, primary_tx_at, primary_error} =
      send_on_port(circuit, :primary, exchange.payload, now_ms)

    {circuit, secondary_obs, secondary_tx_at, secondary_error} =
      send_on_port(circuit, :secondary, exchange.payload, now_ms)

    exchange = %{
      exchange
      | tx_at: earliest_timestamp(primary_tx_at, secondary_tx_at) || exchange.tx_at,
        pending: %{
          primary: primary_obs,
          secondary: secondary_obs,
          primary_reply: nil,
          secondary_reply: nil,
          grace_waiting?: false
        }
    }

    if sent_on_any_port?(exchange) do
      {:ok, circuit, exchange}
    else
      observation =
        transport_error_observation(
          exchange.pending.primary,
          exchange.pending.secondary,
          nil,
          nil,
          System.monotonic_time()
        )

      maybe_log_non_ok_observation(circuit, exchange, observation)

      {:error, circuit, observation, primary_error || secondary_error || :transport_unavailable}
    end
  end

  @impl true
  def observe(%__MODULE__{} = circuit, msg, %Exchange{} = exchange) do
    case observe_port(circuit, :primary, msg, exchange) do
      {:matched, circuit, exchange} ->
        maybe_complete(circuit, exchange)

      :ignore ->
        case observe_port(circuit, :secondary, msg, exchange) do
          {:matched, circuit, exchange} -> maybe_complete(circuit, exchange)
          :ignore -> {:ignore, circuit, exchange}
        end
    end
  end

  @impl true
  def timeout(%__MODULE__{} = circuit, %Exchange{pending: pending} = exchange) do
    interpretation =
      interpret_pending_replies(
        exchange,
        pending.primary_reply,
        pending.secondary_reply
      )

    if should_wait_for_late_reply?(circuit, exchange, interpretation) do
      exchange = %{exchange | pending: %{pending | grace_waiting?: true}}
      {:continue, circuit, exchange, circuit.reply_grace_ms}
    else
      observation = build_observation(exchange, System.monotonic_time(), interpretation)
      circuit = update_port_warmth(circuit, observation)
      maybe_log_non_ok_observation(circuit, exchange, observation)
      {:complete, circuit, observation}
    end
  end

  @impl true
  def drain(%__MODULE__{} = circuit) do
    %{circuit | primary: Port.drain(circuit.primary), secondary: Port.drain(circuit.secondary)}
  end

  @impl true
  def close(%__MODULE__{} = circuit) do
    %{circuit | primary: Port.close(circuit.primary), secondary: Port.close(circuit.secondary)}
  end

  @impl true
  def info(%__MODULE__{} = circuit) do
    %{
      type: :redundant,
      primary: Port.info(circuit.primary),
      secondary: Port.info(circuit.secondary)
    }
  end

  @spec name(t()) :: String.t()
  @impl true
  def name(%__MODULE__{} = circuit) do
    "#{Port.name(circuit.primary)}|#{Port.name(circuit.secondary)}"
  end

  defp open_secondary(
         opts,
         send_backoff_ms,
         reply_grace_ms,
         transport_mod,
         primary,
         secondary_opts
       ) do
    case Port.open(:secondary, transport_mod, secondary_opts) do
      {:ok, secondary} ->
        {:ok,
         %__MODULE__{
           open_opts: opts,
           primary: primary,
           secondary: secondary,
           send_backoff_ms: send_backoff_ms,
           reply_grace_ms: reply_grace_ms
         }}

      {:error, reason} ->
        _ = Port.close(primary)
        {:error, reason}
    end
  end

  defp maybe_reopen_ports(%__MODULE__{} = circuit, now_ms) do
    circuit
    |> maybe_reopen_port(:primary, now_ms)
    |> maybe_reopen_port(:secondary, now_ms)
  end

  defp maybe_reopen_port(%__MODULE__{} = circuit, port_id, now_ms) do
    port = port!(circuit, port_id)

    cond do
      Port.usable?(port) ->
        circuit

      Port.backoff_active?(port, now_ms) ->
        circuit

      true ->
        opts = Keyword.put(circuit.open_opts, :interface, interface_name(circuit, port_id))

        case Port.open(port_id, port.transport_mod, opts) do
          {:ok, reopened} ->
            Telemetry.link_reconnected(name(circuit), Port.name(reopened))
            put_port(circuit, port_id, reopened)

          {:error, _reason} ->
            circuit
        end
    end
  end

  defp send_on_port(%__MODULE__{} = circuit, port_id, payload, now_ms) do
    port = port!(circuit, port_id)

    cond do
      not Port.usable?(port) ->
        {circuit, Observation.port(sent?: false, send_result: :skipped), nil, nil}

      Port.backoff_active?(port, now_ms) ->
        {circuit, Observation.port(sent?: false, send_result: :skipped), nil, nil}

      true ->
        port = Port.arm(port)

        case port.transport_mod.send(port.transport, payload) do
          {:ok, tx_at} ->
            port = Port.clear_send_errors(port)

            Telemetry.frame_sent(
              name(circuit),
              Port.name(port),
              port.id,
              byte_size(payload),
              tx_at
            )

            {
              put_port(circuit, port_id, port),
              Observation.port(sent?: true, send_result: :ok),
              tx_at,
              nil
            }

          {:error, reason} ->
            port =
              port
              |> Port.close()
              |> Port.note_send_error(now_ms, circuit.send_backoff_ms)

            Telemetry.link_down(name(circuit), Port.name(port), reason)

            {
              put_port(circuit, port_id, port),
              Observation.port(sent?: true, send_result: {:error, reason}),
              nil,
              reason
            }
        end
    end
  end

  defp observe_port(%__MODULE__{} = circuit, port_id, msg, %Exchange{} = exchange) do
    port = port!(circuit, port_id)

    if Port.usable?(port) do
      case port.transport_mod.match(port.transport, msg) do
        {:ok, payload, rx_at, frame_src_mac} ->
          handle_port_payload(circuit, exchange, port_id, payload, rx_at, frame_src_mac)

        :ignore ->
          :ignore
      end
    else
      :ignore
    end
  end

  defp handle_port_payload(
         circuit,
         %Exchange{} = exchange,
         port_id,
         payload,
         rx_at,
         frame_src_mac
       ) do
    case Frame.decode(payload) do
      {:ok, datagrams} ->
        if Exchange.all_expected_present?(exchange, datagrams) do
          Telemetry.frame_received(
            name(circuit),
            Port.name(port!(circuit, port_id)),
            port_id,
            byte_size(payload),
            rx_at
          )

          circuit = maybe_resend_crossover(circuit, port_id, payload, frame_src_mac)
          {:matched, circuit, put_reply(exchange, port_id, payload, datagrams, rx_at)}
        else
          Telemetry.frame_dropped(name(circuit), byte_size(payload), :idx_mismatch)
          {:matched, rearm_port(circuit, port_id), exchange}
        end

      {:error, _reason} ->
        Telemetry.frame_dropped(name(circuit), byte_size(payload), :decode_error)
        {:matched, rearm_port(circuit, port_id), exchange}
    end
  end

  defp maybe_complete(%__MODULE__{} = circuit, %Exchange{pending: pending} = exchange) do
    interpretation =
      interpret_pending_replies(
        exchange,
        pending.primary_reply,
        pending.secondary_reply
      )

    cond do
      complete_on_current_replies?(exchange, interpretation) ->
        observation = build_observation(exchange, latest_reply_at(exchange), interpretation)
        circuit = update_port_warmth(circuit, observation)
        {:complete, circuit, observation}

      waiting_on_any_sent_reply?(exchange) ->
        {:continue, circuit, exchange}

      true ->
        observation = build_observation(exchange, latest_reply_at(exchange), interpretation)
        circuit = update_port_warmth(circuit, observation)
        maybe_log_non_ok_observation(circuit, exchange, observation)
        {:complete, circuit, observation}
    end
  end

  defp build_observation(%Exchange{pending: pending} = exchange, completed_at, interpretation) do
    datagrams = interpretation.datagrams

    Observation.new(
      status: interpretation.status,
      path_shape: interpretation.path_shape,
      payload: encoded_payload(datagrams, exchange),
      datagrams: datagrams,
      completed_at: completed_at,
      primary:
        finalize_port_observation(
          pending.primary,
          interpretation.primary_rx_kind,
          pending.primary_reply
        ),
      secondary:
        finalize_port_observation(
          pending.secondary,
          interpretation.secondary_rx_kind,
          pending.secondary_reply
        )
    )
  end

  defp put_reply(%Exchange{pending: pending} = exchange, :primary, payload, datagrams, rx_at) do
    %{
      exchange
      | pending: %{
          pending
          | primary: update_port_observation(pending.primary, payload, rx_at),
            primary_reply: %{payload: payload, datagrams: datagrams, rx_at: rx_at}
        }
    }
  end

  defp put_reply(%Exchange{pending: pending} = exchange, :secondary, payload, datagrams, rx_at) do
    %{
      exchange
      | pending: %{
          pending
          | secondary: update_port_observation(pending.secondary, payload, rx_at),
            secondary_reply: %{payload: payload, datagrams: datagrams, rx_at: rx_at}
        }
    }
  end

  defp update_port_observation(port_observation, payload, rx_at) do
    Observation.port(
      sent?: port_observation.sent?,
      send_result: port_observation.send_result,
      rx_kind: port_observation.rx_kind,
      rx_payload: payload,
      rx_at: rx_at
    )
  end

  defp finalize_port_observation(port_observation, rx_kind, nil) do
    port_observation
    |> Map.put(:rx_kind, rx_kind)
    |> Map.put(:rx_payload, nil)
    |> Map.put(:rx_at, nil)
  end

  defp finalize_port_observation(port_observation, rx_kind, reply) do
    port_observation
    |> Map.put(:rx_kind, rx_kind)
    |> Map.put(:rx_payload, reply.payload)
    |> Map.put(:rx_at, reply.rx_at)
  end

  defp encoded_payload(nil, _exchange), do: nil

  defp encoded_payload(datagrams, %Exchange{pending: pending}) do
    case Frame.encode(datagrams) do
      {:ok, payload} ->
        payload

      {:error, _reason} ->
        cond do
          pending.primary_reply -> pending.primary_reply.payload
          pending.secondary_reply -> pending.secondary_reply.payload
          true -> nil
        end
    end
  end

  defp sent_on_any_port?(%Exchange{pending: pending}) do
    pending.primary.send_result == :ok or pending.secondary.send_result == :ok
  end

  defp waiting_on_any_sent_reply?(%Exchange{pending: pending}) do
    waiting_on_sent_reply?(pending, :primary) or waiting_on_sent_reply?(pending, :secondary)
  end

  defp waiting_on_sent_reply?(pending, :primary) do
    pending.primary.send_result == :ok and is_nil(pending.primary_reply)
  end

  defp waiting_on_sent_reply?(pending, :secondary) do
    pending.secondary.send_result == :ok and is_nil(pending.secondary_reply)
  end

  defp latest_reply_at(%Exchange{pending: pending}) do
    [
      pending.primary_reply && pending.primary_reply.rx_at,
      pending.secondary_reply && pending.secondary_reply.rx_at
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> System.monotonic_time() end)
  end

  defp complete_on_current_replies?(
         %Exchange{pending: pending} = exchange,
         %{status: :ok} = interpretation
       ) do
    cond do
      both_replies_present?(pending) ->
        true

      one_port_only_sent?(pending) ->
        true

      non_logical_exchange?(exchange) and single_side_processed?(interpretation) ->
        true

      true ->
        false
    end
  end

  defp complete_on_current_replies?(_exchange, _interpretation), do: false

  defp both_replies_present?(pending) do
    not is_nil(pending.primary_reply) and not is_nil(pending.secondary_reply)
  end

  defp one_port_only_sent?(pending) do
    sent_on_primary = pending.primary.send_result == :ok
    sent_on_secondary = pending.secondary.send_result == :ok
    sent_on_primary != sent_on_secondary
  end

  defp single_side_processed?(%{primary_rx_kind: :processed, secondary_rx_kind: :none}), do: true
  defp single_side_processed?(%{primary_rx_kind: :none, secondary_rx_kind: :processed}), do: true
  defp single_side_processed?(_interpretation), do: false

  defp non_logical_exchange?(%Exchange{datagrams: datagrams}) do
    Enum.all?(datagrams, &non_logical_datagram?/1)
  end

  defp non_logical_datagram?(%{cmd: cmd}), do: cmd not in [10, 11, 12]

  defp interpret_pending_replies(%Exchange{} = exchange, primary_reply, secondary_reply) do
    RedundantMerge.interpret(
      exchange.datagrams,
      primary_reply && primary_reply.datagrams,
      secondary_reply && secondary_reply.datagrams
    )
  end

  # After each exchange, update port warmth based on observation:
  # - Port sent but got no reply → mark cold (link likely down)
  # - Port got a processed reply → mark warm (link healthy)
  # - Passthrough or not sent → leave as-is
  defp update_port_warmth(circuit, %Observation{} = obs) do
    circuit
    |> update_port_warmth_for(:primary, obs.primary)
    |> update_port_warmth_for(:secondary, obs.secondary)
  end

  defp update_port_warmth_for(circuit, port_id, port_obs) do
    port = port!(circuit, port_id)

    cond do
      port_obs.send_result != :ok ->
        circuit

      port_obs.rx_kind == :none ->
        put_port(circuit, port_id, %{port | warmth: :cold})

      port_obs.rx_kind == :processed ->
        put_port(circuit, port_id, Port.warm(port))

      true ->
        circuit
    end
  end

  # When a recently reconnected (cold) port receives a cross-over frame — one
  # sent by the *other* port's NIC — we physically re-send it so slaves get
  # their last update from the secondary direction before the reconnected port
  # takes over as leader.  After the re-send the port is marked warm.
  defp maybe_resend_crossover(%__MODULE__{} = circuit, port_id, payload, frame_src_mac) do
    port = port!(circuit, port_id)

    if Port.cold?(port) do
      other_id = other_port_id(port_id)
      other_port = port!(circuit, other_id)
      other_mac = if Port.usable?(other_port), do: Port.src_mac(other_port), else: nil

      if not is_nil(frame_src_mac) and not is_nil(other_mac) and frame_src_mac == other_mac do
        # Cross-over frame from the other port's NIC — re-send it on this port
        # so slaves get updated one last time from the secondary path.
        case port.transport_mod.send(port.transport, payload) do
          {:ok, _tx_at} ->
            Logger.info(
              "[Bus.Redundant] warming #{port_id}: re-sent cross-over frame from #{other_id}",
              component: :bus,
              circuit: name(circuit),
              event: :crossover_resend,
              port: port_id
            )

          {:error, reason} ->
            Logger.warning(
              "[Bus.Redundant] warming #{port_id}: cross-over re-send failed: #{inspect(reason)}",
              component: :bus,
              circuit: name(circuit),
              event: :crossover_resend_failed,
              port: port_id
            )
        end
      end

      put_port(circuit, port_id, Port.warm(port))
    else
      circuit
    end
  end

  defp other_port_id(:primary), do: :secondary
  defp other_port_id(:secondary), do: :primary

  defp rearm_port(%__MODULE__{} = circuit, :primary),
    do: %{circuit | primary: Port.rearm(circuit.primary)}

  defp rearm_port(%__MODULE__{} = circuit, :secondary),
    do: %{circuit | secondary: Port.rearm(circuit.secondary)}

  defp put_port(%__MODULE__{} = circuit, :primary, port), do: %{circuit | primary: port}
  defp put_port(%__MODULE__{} = circuit, :secondary, port), do: %{circuit | secondary: port}

  defp interface_name(%__MODULE__{} = circuit, :primary) do
    Keyword.fetch!(circuit.open_opts, :interface)
  end

  defp interface_name(%__MODULE__{} = circuit, :secondary) do
    Keyword.fetch!(circuit.open_opts, :backup_interface)
  end

  defp port!(%__MODULE__{primary: port}, :primary), do: port
  defp port!(%__MODULE__{secondary: port}, :secondary), do: port

  defp earliest_timestamp(nil, other), do: other
  defp earliest_timestamp(other, nil), do: other
  defp earliest_timestamp(left, right), do: min(left, right)

  defp default_reply_grace_ms(frame_timeout_ms)
       when is_integer(frame_timeout_ms) and frame_timeout_ms > 0,
       do: max(frame_timeout_ms, 25)

  defp transport_error_observation(
         primary,
         secondary,
         primary_reply,
         secondary_reply,
         completed_at
       ) do
    Observation.new(
      status: :transport_error,
      path_shape: :no_valid_return,
      completed_at: completed_at,
      primary: finalize_port_observation(primary, :none, primary_reply),
      secondary: finalize_port_observation(secondary, :none, secondary_reply)
    )
  end

  defp should_wait_for_late_reply?(
         %__MODULE__{reply_grace_ms: reply_grace_ms},
         %Exchange{pending: %{grace_waiting?: false} = pending},
         %{status: status}
       )
       when reply_grace_ms > 0 and status != :ok do
    pending.primary.send_result == :ok and pending.secondary.send_result == :ok
  end

  defp should_wait_for_late_reply?(_circuit, _exchange, _interpretation), do: false

  defp maybe_log_non_ok_observation(_circuit, _exchange, %Observation{status: :ok}), do: :ok

  defp maybe_log_non_ok_observation(
         %__MODULE__{} = circuit,
         %Exchange{} = exchange,
         %Observation{} = observation
       ) do
    Logger.warning(
      "[Bus.Redundant] exchange status=#{inspect(observation.status)} path_shape=#{inspect(observation.path_shape)} " <>
        "primary.send=#{inspect(observation.primary.send_result)} primary.rx=#{inspect(observation.primary.rx_kind)} " <>
        "secondary.send=#{inspect(observation.secondary.send_result)} secondary.rx=#{inspect(observation.secondary.rx_kind)}",
      component: :bus,
      circuit: name(circuit),
      event: :redundant_exchange_non_ok,
      status: observation.status,
      path_shape: observation.path_shape,
      primary_send_result: observation.primary.send_result,
      primary_rx_kind: observation.primary.rx_kind,
      primary_rx_delay_us: reply_delay_us(exchange.tx_at, observation.primary.rx_at),
      secondary_send_result: observation.secondary.send_result,
      secondary_rx_kind: observation.secondary.rx_kind,
      secondary_rx_delay_us: reply_delay_us(exchange.tx_at, observation.secondary.rx_at)
    )
  end

  defp reply_delay_us(_tx_at, nil), do: nil

  defp reply_delay_us(tx_at, rx_at) do
    System.convert_time_unit(rx_at - tx_at, :native, :microsecond)
  end
end
