#!/usr/bin/env elixir
# Channel wiring map — commission-time loopback verification.
#
# Activates each EL2809 output channel one at a time, waits two domain cycles,
# then reads all 16 EL1809 input channels to find the matching input.
#
# Output is a wiring table:
#
#   output ch1  →  input ch1   ✓ expected
#   output ch2  →  input ch2   ✓ expected
#   output ch3  →  input ch3   ✓ expected
#   ...
#   output ch8  →  NONE        ✗ wire missing or broken
#   output ch9  →  input ch1   ✗ crossed wire (expected ch9)
#
# Intended use: run once after physical installation to verify all 16 loopback
# wires are in the correct positions.
#
# Hardware:
#   position 0  EK1100 coupler
#   position 1  EL1809 16-ch digital input  (slave name :inputs)
#   position 2  EL2809 16-ch digital output (slave name :outputs)
#   position 3  EL3202 2-ch PT100           (slave name :rtd)
#
# Usage:
#   mix run examples/wiring_map.exs --interface enp0s31f6
#
# Optional flags:
#   --period-ms N     domain cycle period in ms (default 10)
#   --settle-ms N     time to settle after each output toggle (default 40)
#   --no-rtd          skip starting EL3202 (shorter startup if RTD not present)

# ---------------------------------------------------------------------------
# Driver definitions
# ---------------------------------------------------------------------------

defmodule WiringMap.EL1809 do
  @behaviour EtherCAT.Slave.Driver
  @impl true
  def process_data_model(_config) do
    Enum.map(1..16, fn i -> {:"ch#{i}", 0x1A00 + i - 1} end)
  end

  @impl true
  def encode_signal(_pdo, _config, _), do: <<>>

  @impl true
  def decode_signal(_ch, _config, <<_::7, bit::1>>), do: bit
  def decode_signal(_pdo, _config, _), do: 0
end

defmodule WiringMap.EL2809 do
  @behaviour EtherCAT.Slave.Driver
  @impl true
  def process_data_model(_config) do
    Enum.map(1..16, fn i -> {:"ch#{i}", 0x1600 + i - 1} end)
  end

  @impl true
  def encode_signal(_ch, _config, value), do: <<value::8>>

  @impl true
  def decode_signal(_pdo, _config, _), do: nil
end

defmodule WiringMap.EL3202 do
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
# Parse args
# ---------------------------------------------------------------------------

{opts, _, _} =
  OptionParser.parse(System.argv(),
    switches: [interface: :string, period_ms: :integer, settle_ms: :integer, no_rtd: :boolean]
  )

interface = opts[:interface] || raise "pass --interface, e.g. --interface enp0s31f6"
period_ms = Keyword.get(opts, :period_ms, 10)
settle_ms = Keyword.get(opts, :settle_ms, 40)
include_rtd = not Keyword.get(opts, :no_rtd, false)

IO.puts("""
EtherCAT channel wiring map
  interface  : #{interface}
  period     : #{period_ms} ms
  settle     : #{settle_ms} ms per channel
  rtd        : #{if include_rtd, do: "enabled", else: "skipped"}
""")

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

EtherCAT.stop()
Process.sleep(300)

rtd_slave = %EtherCAT.Slave.Config{
  name: :rtd,
  driver: WiringMap.EL3202,
  process_data: {:all, :main}
}

slaves =
  [
    %EtherCAT.Slave.Config{name: :coupler},
    %EtherCAT.Slave.Config{name: :inputs, driver: WiringMap.EL1809, process_data: {:all, :main}},
    %EtherCAT.Slave.Config{name: :outputs, driver: WiringMap.EL2809, process_data: {:all, :main}}
  ] ++ if(include_rtd, do: [rtd_slave], else: [])

:ok =
  EtherCAT.start(
    interface: interface,
    domains: [
      %EtherCAT.Domain.Config{id: :main, cycle_time_us: period_ms * 1_000, miss_threshold: 500}
    ],
    slaves: slaves
  )

IO.puts("Waiting for bus to reach OP...")
:ok = EtherCAT.await_running(15_000)

# Zero all outputs to start clean
Enum.each(1..16, fn i -> EtherCAT.write_output(:outputs, :"ch#{i}", 0) end)
Process.sleep(settle_ms)

# ---------------------------------------------------------------------------
# Read all input channels (poll-based — no subscription needed for wiring map)
# ---------------------------------------------------------------------------

read_all_inputs = fn ->
  Enum.into(1..16, %{}, fn i ->
    ch = :"ch#{i}"

    case EtherCAT.read_input(:inputs, ch) do
      {:ok, val} -> {ch, val}
      _ -> {ch, nil}
    end
  end)
end

# Baseline: any inputs already high before we start (shorted lines, leakage)
baseline = read_all_inputs.()

baseline_high =
  Enum.filter(baseline, fn {_, v} -> v == 1 end) |> Enum.map(fn {ch, _} -> ch end)

if baseline_high != [] do
  IO.puts(
    "  ⚠ baseline inputs already high (shorted/powered externally): #{inspect(baseline_high)}\n"
  )
end

# ---------------------------------------------------------------------------
# Walk each output channel
# ---------------------------------------------------------------------------

channels = Enum.map(1..16, &:"ch#{&1}")

IO.puts("Probing 16 output channels (#{settle_ms} ms settle each)...\n")
IO.puts(String.pad_trailing("  Output", 16) <> "→  Input(s) found        Status")
IO.puts(String.duplicate("-", 60))

results =
  Enum.map(channels, fn out_ch ->
    # Turn on this output; all others remain off
    EtherCAT.write_output(:outputs, out_ch, 1)
    Process.sleep(settle_ms)

    after_map = read_all_inputs.()

    # Inputs that went high (excluding baseline)
    responding =
      Enum.filter(after_map, fn {ch, v} ->
        v == 1 and Map.get(baseline, ch) != 1
      end)
      |> Enum.map(fn {ch, _} -> ch end)
      |> Enum.sort()

    # Turn it back off and settle
    EtherCAT.write_output(:outputs, out_ch, 0)
    Process.sleep(settle_ms)

    expected_in = :"ch#{String.trim_leading(Atom.to_string(out_ch), "ch")}"
    {out_ch, responding, expected_in}
  end)

# ---------------------------------------------------------------------------
# Print table + verdict
# ---------------------------------------------------------------------------

Enum.each(results, fn {out_ch, responding, expected_in} ->
  found_str =
    case responding do
      [] -> "NONE"
      chs -> Enum.map_join(chs, ", ", &Atom.to_string/1)
    end

  {status, mark} =
    cond do
      responding == [expected_in] -> {"expected", "✓"}
      responding == [] -> {"OPEN — no input responded", "✗"}
      expected_in in responding and length(responding) > 1 -> {"SHORT — extra inputs high", "✗"}
      expected_in not in responding -> {"CROSSED — wrong input(s)", "✗"}
      true -> {"?", "?"}
    end

  out_str = String.pad_trailing("  #{out_ch}", 16)
  in_str = String.pad_trailing(found_str, 24)
  IO.puts("#{out_str}→  #{in_str}#{mark} #{status}")
end)

IO.puts(String.duplicate("-", 60))

pass_count =
  Enum.count(results, fn {_out_ch, responding, expected_in} ->
    responding == [expected_in]
  end)

fail_count = 16 - pass_count

IO.puts("\n  #{pass_count}/16 channels wired correctly")

if fail_count > 0 do
  IO.puts("  #{fail_count} channel(s) need attention ✗")
else
  IO.puts("  All channels OK ✓")
end

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

Enum.each(1..16, fn i -> EtherCAT.write_output(:outputs, :"ch#{i}", 0) end)
EtherCAT.stop()
