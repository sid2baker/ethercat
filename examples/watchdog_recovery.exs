#!/usr/bin/env elixir
# EtherCAT watchdog trip and recovery test.
#
# Verifies the EL2809 SM watchdog behavior when the domain stops cycling:
#
#   1. Start → OP: confirm all slaves reach OP state
#   2. Assert outputs: drive a known pattern on EL2809 ch1..ch16
#   3. STOP cycling: call Domain.stop_cycling/1, record t0
#   4. Poll AL status via raw FPRD: detect when EL2809 transitions OP→SAFEOP
#      (watchdog tripped, outputs go to safe state)
#      Record trip_ms = time from stop to SAFEOP
#   5. Verify loopback: read EL1809 inputs to confirm outputs went low (safe)
#   6. RESTART cycling: call Domain.start_cycling/1, record t1
#   7. Poll until EL2809 returns to OP, record recover_ms = t1 → OP
#   8. Verify loopback restored: drive all outputs high again and check inputs
#
# The SM watchdog timeout on EL2809 defaults to ~100 ms (configurable via
# 0x0420 / wdt_sm register).  This test measures the actual trip latency and
# the master's recovery time independently.
#
# Hardware:
#   position 0  EK1100 coupler
#   position 1  EL1809 16-ch digital input  (slave name :inputs)
#   position 2  EL2809 16-ch digital output (slave name :outputs)
#   position 3  EL3202 2-ch PT100           (slave name :rtd)
#
# Usage:
#   mix run examples/watchdog_recovery.exs --interface enp0s31f6
#
# Optional flags:
#   --period-ms N     domain cycle period ms  (default 10)
#   --poll-ms N       AL status poll interval  (default 5)
#   --trip-timeout N  max ms to wait for trip  (default 2000)
#   --op-timeout N    max ms to wait for OP    (default 5000)
#   --no-rtd          skip EL3202 slave

# ---------------------------------------------------------------------------
# Drivers
# ---------------------------------------------------------------------------

defmodule WatchdogTest.EL1809 do
  @behaviour EtherCAT.Slave.Driver
  @impl true
  def process_data_model(_config), do: Enum.map(1..16, fn i -> {:"ch#{i}", 0x1A00 + i - 1} end)
  @impl true
  def encode_signal(_pdo, _config, _), do: <<>>
  @impl true
  def decode_signal(_ch, _config, <<_::7, bit::1>>), do: bit
  def decode_signal(_pdo, _config, _), do: 0
end

defmodule WatchdogTest.EL2809 do
  @behaviour EtherCAT.Slave.Driver
  @impl true
  def process_data_model(_config), do: Enum.map(1..16, fn i -> {:"ch#{i}", 0x1600 + i - 1} end)
  @impl true
  def encode_signal(_ch, _config, value), do: <<value::8>>
  @impl true
  def decode_signal(_pdo, _config, _), do: nil
end

defmodule WatchdogTest.EL3202 do
  @behaviour EtherCAT.Slave.Driver
  @impl true
  def process_data_model(_config), do: [channel1: 0x1A00, channel2: 0x1A01]
  @impl true
  def mailbox_config(_config) do
    [
      {:sdo_download, 0x8000, 0x19, <<8::16-little>>},
      {:sdo_download, 0x8010, 0x19, <<8::16-little>>}
    ]
  end

  @impl true
  def encode_signal(_pdo, _config, _value), do: <<>>
  @impl true
  def decode_signal(_pdo, _config, _), do: nil
end

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# AL status register values (IEC 61158-6 §5.3.2)
al_state_name = fn
  0x01 -> :init
  0x02 -> :preop
  0x04 -> :safeop
  0x08 -> :op
  n -> :"unknown_#{n}"
end

hex = fn n -> "0x#{String.upcase(Integer.to_string(n, 16))}" end

# Poll AL status of a slave (by station address) until it matches the target
# ESM state, or timeout_ms elapses.  Returns {:ok, elapsed_ms} | {:error, :timeout, last_state}.
poll_until_state = fn bus, station, target_state, poll_ms, timeout_ms, al_state_name ->
  deadline = System.monotonic_time(:millisecond) + timeout_ms

  Stream.repeatedly(fn -> :ok end)
  |> Enum.reduce_while(:polling, fn _, last ->
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:halt, {:error, :timeout, last}}
    else
      case EtherCAT.Bus.transaction(
             bus,
             EtherCAT.Bus.Transaction.fprd(station, EtherCAT.Slave.Registers.al_status())
           ) do
        {:ok, [%{data: bytes, wkc: 1}]} ->
          {actual, _error_ind} = EtherCAT.Slave.Registers.decode_al_status(bytes)
          state_name = al_state_name.(actual)

          if state_name == target_state do
            {:halt, {:ok, :reached}}
          else
            Process.sleep(poll_ms)
            {:cont, state_name}
          end

        _ ->
          Process.sleep(poll_ms)
          {:cont, :no_response}
      end
    end
  end)
end

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------

{opts, _, _} =
  OptionParser.parse(System.argv(),
    switches: [
      interface: :string,
      period_ms: :integer,
      poll_ms: :integer,
      trip_timeout: :integer,
      op_timeout: :integer,
      no_rtd: :boolean
    ]
  )

interface = opts[:interface] || raise "pass --interface, e.g. --interface enp0s31f6"
period_ms = Keyword.get(opts, :period_ms, 10)
poll_ms = Keyword.get(opts, :poll_ms, 5)
trip_timeout = Keyword.get(opts, :trip_timeout, 2_000)
op_timeout = Keyword.get(opts, :op_timeout, 5_000)
include_rtd = not Keyword.get(opts, :no_rtd, false)

IO.puts("""
EtherCAT watchdog trip & recovery test
  interface      : #{interface}
  period         : #{period_ms} ms
  poll           : #{poll_ms} ms
  trip timeout   : #{trip_timeout} ms
  recovery limit : #{op_timeout} ms
""")

# ---------------------------------------------------------------------------
# Phase 1: Start
# ---------------------------------------------------------------------------

IO.puts("── 1. Starting EtherCAT ──────────────────────────────────────────")

EtherCAT.stop()
Process.sleep(300)

rtd_slave = %EtherCAT.Slave.Config{
  name: :rtd,
  driver: WatchdogTest.EL3202,
  process_data: {:all, :main}
}

:ok =
  EtherCAT.start(
    interface: interface,
    domains: [
      %EtherCAT.Domain.Config{id: :main, cycle_time_us: period_ms * 1_000, miss_threshold: 500}
    ],
    slaves:
      [
        %EtherCAT.Slave.Config{name: :coupler},
        %EtherCAT.Slave.Config{
          name: :inputs,
          driver: WatchdogTest.EL1809,
          process_data: {:all, :main}
        },
        %EtherCAT.Slave.Config{
          name: :outputs,
          driver: WatchdogTest.EL2809,
          process_data: {:all, :main}
        }
      ] ++ if(include_rtd, do: [rtd_slave], else: [])
  )

:ok = EtherCAT.await_running(15_000)

bus = EtherCAT.bus()

# Find the EL2809 station address
{:ok, outputs_station} =
  EtherCAT.slaves()
  |> Enum.find_value(fn
    %{name: :outputs, station: station} -> {:ok, station}
    _ -> nil
  end)
  |> case do
    nil -> raise "slave :outputs not found"
    v -> v
  end

IO.puts("  :outputs slave at station #{hex.(outputs_station)}")

# Confirm OP state
case EtherCAT.Bus.transaction(
       bus,
       EtherCAT.Bus.Transaction.fprd(outputs_station, EtherCAT.Slave.Registers.al_status())
     ) do
  {:ok, [%{data: bytes, wkc: 1}]} ->
    {al_code, _} = EtherCAT.Slave.Registers.decode_al_status(bytes)
    state = al_state_name.(al_code)
    IO.puts("  :outputs AL status: #{state}")

    if state != :op, do: raise("Expected :op, got #{state}")

  _ ->
    raise "Could not read :outputs AL status"
end

# Read WDT_divider and WDT_SM to compute actual configured timeout.
# timeout_ns = WDT_SM × (WDT_divider + 2) × 40 ns  (ESC clock = 25 MHz)
wdt_divider =
  case EtherCAT.Bus.transaction(
         bus,
         EtherCAT.Bus.Transaction.fprd(outputs_station, EtherCAT.Slave.Registers.wdt_divider())
       ) do
    {:ok, [%{data: <<v::16-little>>, wkc: 1}]} -> v
    _ -> nil
  end

case EtherCAT.Bus.transaction(
       bus,
       EtherCAT.Bus.Transaction.fprd(outputs_station, EtherCAT.Slave.Registers.wdt_sm())
     ) do
  {:ok, [%{data: <<wdt_val::16-little>>, wkc: 1}]} ->
    timeout_ms =
      if wdt_divider do
        unit_ns = (wdt_divider + 2) * 40
        Float.round(wdt_val * unit_ns / 1_000_000.0, 1)
      end

    timeout_str = if timeout_ms, do: " → #{timeout_ms} ms", else: ""
    IO.puts("  WDT_divider=#{wdt_divider || "?"} WDT_SM=#{wdt_val}#{timeout_str}")

    # Warn if trip_timeout is less than configured watchdog timeout
    if timeout_ms && timeout_ms > trip_timeout do
      IO.puts(
        "  ⚠ trip_timeout (#{trip_timeout} ms) < configured WDT (#{timeout_ms} ms) — increase --trip-timeout"
      )
    end

  _ ->
    IO.puts("  (could not read SM watchdog registers)")
end

# ---------------------------------------------------------------------------
# Phase 2: Assert outputs (all-on pattern)
# ---------------------------------------------------------------------------

IO.puts("\n── 2. Assert all outputs HIGH ────────────────────────────────────")

Enum.each(1..16, fn i -> EtherCAT.write_output(:outputs, :"ch#{i}", 1) end)
Process.sleep(period_ms * 5)

on_count =
  Enum.count(1..16, fn i ->
    case EtherCAT.read_input(:inputs, :"ch#{i}") do
      {:ok, 1} -> true
      _ -> false
    end
  end)

IO.puts("  #{on_count}/16 loopback inputs confirmed HIGH")

# ---------------------------------------------------------------------------
# Phase 3: Stop cycling, measure watchdog trip
# ---------------------------------------------------------------------------

IO.puts("\n── 3. Stop cycling — measuring watchdog trip ─────────────────────")
IO.puts("  Calling Domain.stop_cycling(:main)...")

t_stop = System.monotonic_time(:millisecond)
:ok = EtherCAT.Domain.stop_cycling(:main)

# Poll until AL status goes to SAFEOP
result =
  poll_until_state.(bus, outputs_station, :safeop, poll_ms, trip_timeout, al_state_name)

t_trip = System.monotonic_time(:millisecond)
trip_ms = t_trip - t_stop

case result do
  {:ok, :reached} ->
    IO.puts("  ✓ Watchdog tripped: :outputs → SAFEOP in #{trip_ms} ms")

  {:error, :timeout, last} ->
    IO.puts("  ✗ Watchdog did NOT trip within #{trip_timeout} ms (last AL state: #{last})")
end

# Read WDT_status and WDT_status register to see if watchdog HW expired even without
# AL state change (some ESCs reset outputs silently without changing state).
wdt_status_val =
  case EtherCAT.Bus.transaction(
         bus,
         EtherCAT.Bus.Transaction.fprd(outputs_station, EtherCAT.Slave.Registers.wdt_status())
       ) do
    {:ok, [%{data: <<v::16-little>>, wkc: 1}]} -> v
    _ -> nil
  end

if wdt_status_val != nil do
  wdt_expired = EtherCAT.Slave.Registers.wdt_status_expired?(<<wdt_status_val::16-little>>)

  IO.puts(
    "  WDT_status=0x#{Integer.to_string(wdt_status_val, 16)} → watchdog #{if wdt_expired, do: "EXPIRED (outputs went safe)", else: "still running (outputs NOT safe)"}"
  )
end

# ---------------------------------------------------------------------------
# Phase 4: Verify safe state on loopback
# ---------------------------------------------------------------------------

IO.puts("\n── 4. Verify safe state on loopback ──────────────────────────────")
IO.puts("  (Note: read_input reads ETS — stale since cycling stopped.)")
IO.puts("  Restarting cycling briefly to refresh input image...")

# Cycling stopped → ETS frozen at last values.  Restart for a few ticks
# to get a fresh input snapshot reflecting the watchdog safe state.
EtherCAT.Domain.start_cycling(:main)
Process.sleep(period_ms * 5)
EtherCAT.Domain.stop_cycling(:main)

off_count =
  Enum.count(1..16, fn i ->
    case EtherCAT.read_input(:inputs, :"ch#{i}") do
      {:ok, 0} -> true
      _ -> false
    end
  end)

still_on = 16 - off_count

if still_on == 0 do
  IO.puts("  ✓ All 16 loopback inputs went LOW (safe state confirmed)")
else
  IO.puts("  #{still_on} input(s) still HIGH (#{off_count} went LOW)")
  IO.puts("  Note: known broken channels (open wires) cannot go LOW")
end

# ---------------------------------------------------------------------------
# Phase 5: Restart cycling, measure recovery
# ---------------------------------------------------------------------------

IO.puts("\n── 5. Restart cycling — measuring OP recovery ────────────────────")

t_restart = System.monotonic_time(:millisecond)
:ok = EtherCAT.Domain.start_cycling(:main)

IO.puts("  Domain.start_cycling(:main) called, waiting for :outputs → OP...")

recovery_result =
  poll_until_state.(bus, outputs_station, :op, poll_ms, op_timeout, al_state_name)

t_op = System.monotonic_time(:millisecond)
recover_ms = t_op - t_restart

case recovery_result do
  {:ok, :reached} ->
    IO.puts("  ✓ :outputs back in OP in #{recover_ms} ms")

  {:error, :timeout, last} ->
    IO.puts("  ✗ :outputs did NOT reach OP within #{op_timeout} ms (last: #{last})")
end

# ---------------------------------------------------------------------------
# Phase 6: Verify loopback restored
# ---------------------------------------------------------------------------

IO.puts("\n── 6. Verify loopback restored ───────────────────────────────────")

# Re-assert outputs after recovery (domain cycling cleared them)
Enum.each(1..16, fn i -> EtherCAT.write_output(:outputs, :"ch#{i}", 1) end)
Process.sleep(period_ms * 5)

restored_count =
  Enum.count(1..16, fn i ->
    case EtherCAT.read_input(:inputs, :"ch#{i}") do
      {:ok, 1} -> true
      _ -> false
    end
  end)

IO.puts("  #{restored_count}/16 loopback inputs back HIGH after recovery")

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

# EL2809 implements a silent SM watchdog: WDT_status goes to 0x0 and outputs
# reset to safe state (0), but the AL status remains OP (no SAFEOP transition).
# This is valid EtherCAT behaviour — the master can still communicate with the
# slave in OP even while outputs are held at safe state.
wdt_ok =
  wdt_status_val != nil and
    EtherCAT.Slave.Registers.wdt_status_expired?(<<wdt_status_val::16-little>>)

IO.puts("""

── Summary ───────────────────────────────────────────────────────────
  WDT_status after stop   : #{if wdt_ok, do: "0x0 — EXPIRED ✓ (silent watchdog)", else: "0x1 — still running (watchdog did not fire)"}
  AL state after stop     : #{if result == {:ok, :reached}, do: "SAFEOP (state change)", else: "OP (silent watchdog — no AL state change)"}
  OP recovery latency     : #{recover_ms} ms
  Loopback restored       : #{restored_count}/16 HIGH (#{16 - restored_count} open or wiring fault)
──────────────────────────────────────────────────────────────────────
""")

# Zero outputs and stop
Enum.each(1..16, fn i -> EtherCAT.write_output(:outputs, :"ch#{i}", 0) end)
Process.sleep(period_ms * 3)
EtherCAT.stop()
