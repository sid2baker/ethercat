defmodule EtherCAT.Telemetry do
  @moduledoc """
  Telemetry integration for the EtherCAT stack.

  Emits events via `:telemetry` if the dependency is available.
  When `:telemetry` is not installed, all calls are silent no-ops.
  This makes `:telemetry` an optional dependency.

  ## Events

  ### Transaction span (emitted by `Link.transact/3`)

      [:ethercat, :link, :transact, :start]
        measurements: %{system_time: integer(), monotonic_time: integer()}
        metadata:     %{datagram_count: integer()}

      [:ethercat, :link, :transact, :stop]
        measurements: %{duration: integer()}
        metadata:     %{datagram_count: integer(), total_wkc: integer()}

      [:ethercat, :link, :transact, :exception]
        measurements: %{duration: integer()}
        metadata:     %{kind: atom(), reason: term(), stacktrace: list()}

  ### Frame-level events

      [:ethercat, :link, :frame, :sent]
        measurements: %{size: integer(), tx_timestamp: integer() | nil}
        metadata:     %{interface: String.t(), port: :primary | :secondary}

      [:ethercat, :link, :frame, :received]
        measurements: %{size: integer(), rx_timestamp: integer() | nil}
        metadata:     %{interface: String.t(), port: :primary | :secondary}

      [:ethercat, :link, :frame, :dropped]
        measurements: %{size: integer()}
        metadata:     %{interface: String.t(), reason: atom()}

  ### Socket lifecycle events

      [:ethercat, :link, :socket, :down]
        measurements: %{}
        metadata:     %{interface: String.t(), reason: term()}

      [:ethercat, :link, :socket, :reconnected]
        measurements: %{}
        metadata:     %{interface: String.t()}

  ## Timestamps

  `tx_timestamp` and `rx_timestamp` are `System.monotonic_time/0` values.
  When Linux `SO_TIMESTAMPING` is available, `rx_timestamp` is derived from
  the kernel's software RX timestamp for nanosecond accuracy. Their difference
  gives wire-level round-trip time.

  ## Example

      :telemetry.attach_many("ethercat-log", [
        [:ethercat, :link, :transact, :stop],
        [:ethercat, :link, :socket, :down]
      ], &MyHandler.handle_event/4, nil)
  """

  # ---------------------------------------------------------------------------
  # Core wrappers — delegate to :telemetry at runtime, no-op if absent
  # ---------------------------------------------------------------------------

  @doc false
  def execute(event, measurements, metadata \\ %{}) do
    if telemetry_available?() do
      :telemetry.execute(event, measurements, metadata)
    end

    :ok
  end

  @doc false
  def span(event_prefix, start_metadata, fun) when is_function(fun, 0) do
    if telemetry_available?() do
      :telemetry.span(event_prefix, start_metadata, fun)
    else
      {result, _stop_meta} = fun.()
      result
    end
  end

  # ---------------------------------------------------------------------------
  # Convenience emitters — called from Link.Normal and Link.Redundant
  # ---------------------------------------------------------------------------

  @doc false
  def frame_sent(interface, port, size, tx_timestamp \\ nil) do
    execute(
      [:ethercat, :link, :frame, :sent],
      %{size: size, tx_timestamp: tx_timestamp},
      %{interface: interface, port: port}
    )
  end

  @doc false
  def frame_received(interface, port, size, rx_timestamp \\ nil) do
    execute(
      [:ethercat, :link, :frame, :received],
      %{size: size, rx_timestamp: rx_timestamp},
      %{interface: interface, port: port}
    )
  end

  @doc false
  def frame_dropped(interface, size, reason) do
    execute(
      [:ethercat, :link, :frame, :dropped],
      %{size: size},
      %{interface: interface, reason: reason}
    )
  end

  @doc false
  def socket_down(interface, reason) do
    execute(
      [:ethercat, :link, :socket, :down],
      %{},
      %{interface: interface, reason: reason}
    )
  end

  @doc false
  def socket_reconnected(interface) do
    execute(
      [:ethercat, :link, :socket, :reconnected],
      %{},
      %{interface: interface}
    )
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp telemetry_available? do
    Code.ensure_loaded?(:telemetry) and function_exported?(:telemetry, :execute, 3)
  end
end
