defmodule EtherCAT.Bus.Circuit.Single do
  @moduledoc """
  Single-port circuit implementation for one EtherCAT exchange.

  This is the first concrete `Bus.Circuit` implementation. It executes one
  exchange over one transport-backed port, incrementally classifies received
  traffic, and emits a final `Bus.Observation`.
  """

  @behaviour EtherCAT.Bus.Circuit

  alias EtherCAT.Bus.{Frame, Observation}
  alias EtherCAT.Bus.Circuit.{Exchange, Port}
  alias EtherCAT.Telemetry

  @enforce_keys [:open_opts, :port]
  defstruct [:open_opts, :port]

  @type t :: %__MODULE__{
          open_opts: keyword(),
          port: Port.t()
        }

  @impl true
  def open(opts) do
    transport_mod = Keyword.fetch!(opts, :transport_mod)

    case Port.open(:primary, transport_mod, opts) do
      {:ok, port} -> {:ok, %__MODULE__{open_opts: opts, port: port}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def begin_exchange(%__MODULE__{} = circuit, %Exchange{} = exchange) do
    circuit = maybe_reopen_port(circuit)
    port = circuit.port

    if not Port.usable?(port) do
      {:error, circuit, transport_error_observation(:skipped), :transport_unavailable}
    else
      port = Port.arm(port)

      case port.transport_mod.send(port.transport, exchange.payload) do
        {:ok, tx_at} ->
          exchange = %{exchange | tx_at: tx_at, pending: %{port: port}}

          Telemetry.frame_sent(
            name(circuit),
            Port.name(port),
            :primary,
            exchange.payload_size,
            tx_at
          )

          {:ok, %{circuit | port: port}, exchange}

        {:error, reason} ->
          port = Port.close(port)
          closed = %{circuit | port: port}
          Telemetry.link_down(name(closed), Port.name(port), reason)
          {:error, closed, transport_error_observation({:error, reason}), reason}
      end
    end
  end

  @impl true
  def observe(%__MODULE__{} = circuit, msg, %Exchange{pending: %{port: port}} = exchange) do
    case port.transport_mod.match(port.transport, msg) do
      {:ok, ecat_payload, rx_at, _src_mac} ->
        handle_payload(circuit, exchange, ecat_payload, rx_at)

      :ignore ->
        {:ignore, circuit, exchange}
    end
  end

  @impl true
  def timeout(%__MODULE__{} = circuit, %Exchange{pending: %{port: port}}) do
    observation =
      Observation.new(
        status: :timeout,
        path_shape: :no_valid_return,
        completed_at: System.monotonic_time(),
        primary:
          Observation.port(
            sent?: true,
            send_result: :ok,
            rx_kind: :none
          )
      )

    {:complete, %{circuit | port: port}, observation}
  end

  @impl true
  def drain(%__MODULE__{port: port} = circuit), do: %{circuit | port: Port.drain(port)}

  @impl true
  def close(%__MODULE__{port: port} = circuit), do: %{circuit | port: Port.close(port)}

  @impl true
  def info(%__MODULE__{port: port}) do
    %{
      type: :single,
      port: Port.info(port)
    }
  end

  @spec name(t()) :: String.t()
  @impl true
  def name(%__MODULE__{port: port}), do: Port.name(port)

  defp maybe_reopen_port(%__MODULE__{} = circuit) do
    if Port.usable?(circuit.port) do
      circuit
    else
      case Port.open(:primary, circuit.port.transport_mod, circuit.open_opts) do
        {:ok, port} ->
          Telemetry.link_reconnected(name(circuit), Port.name(port))
          %{circuit | port: port}

        {:error, _reason} ->
          circuit
      end
    end
  end

  defp handle_payload(circuit, %Exchange{pending: %{port: port}} = exchange, ecat_payload, rx_at) do
    case Frame.decode(ecat_payload) do
      {:ok, datagrams} ->
        if Exchange.all_expected_present?(exchange, datagrams) do
          Telemetry.frame_received(
            name(circuit),
            Port.name(port),
            :primary,
            byte_size(ecat_payload),
            rx_at
          )

          observation =
            Observation.new(
              status: :ok,
              path_shape: :single,
              payload: ecat_payload,
              datagrams: datagrams,
              completed_at: rx_at,
              primary:
                Observation.port(
                  sent?: true,
                  send_result: :ok,
                  rx_kind: :processed,
                  rx_payload: ecat_payload,
                  rx_at: rx_at
                )
            )

          {:complete, %{circuit | port: port}, observation}
        else
          Telemetry.frame_dropped(name(circuit), byte_size(ecat_payload), :idx_mismatch)
          port = Port.rearm(port)
          exchange = %{exchange | pending: %{port: port}}
          {:continue, %{circuit | port: port}, exchange}
        end

      {:error, _reason} ->
        Telemetry.frame_dropped(name(circuit), byte_size(ecat_payload), :decode_error)
        port = Port.rearm(port)
        exchange = %{exchange | pending: %{port: port}}
        {:continue, %{circuit | port: port}, exchange}
    end
  end

  defp transport_error_observation(send_result) do
    Observation.new(
      status: :transport_error,
      path_shape: :no_valid_return,
      completed_at: System.monotonic_time(),
      primary:
        Observation.port(
          sent?: send_result != :skipped,
          send_result: send_result,
          rx_kind: :none
        )
    )
  end
end
