#!/usr/bin/env elixir
# EtherCAT fault tolerance validation.
#
# Tests the runtime fault detection and recovery mechanisms added in v0.2:
#
#   A. Process crash detection
#      A1. Kill the domain process → [:ethercat, :domain, :crashed] fires
#      A2. Kill a slave process   → [:ethercat, :slave, :crashed]  fires
#
#   B. Domain stop notification (requires brief cable pull — ~1 s)
#      Sets miss_threshold: 2, pulls cable → domain stops after 2 misses,
#      telemetry [:ethercat, :domain, :stopped] fires, master receives notification.
#
#   C. Slave health poll + ESM retreat (requires cable pull on slave segment)
#      Sets health_poll_ms: 500 on :outputs, pull cable → slave detects AL fault
#      within 500 ms, retreats to SafeOp, master enters :degraded.
#
#   D. Recovery (reconnect cable after C)
#      Master retries activation, :outputs returns to Op, master → :running.
#
# Scenarios A run without any physical interaction.
# Scenarios B, C, D require you to briefly disconnect the EtherCAT cable when prompted.
#
# Hardware:
#   position 0  EK1100 coupler          (:coupler)
#   position 1  EL1809 16-ch DI         (:inputs)
#   position 2  EL2809 16-ch DO         (:outputs)
#   position 3  EL3202 2-ch PT100       (:rtd)
#
# Usage:
#   mix run examples/fault_tolerance.exs --interface enp0s31f6
#
# Optional flags:
#   --poll-ms N           health poll interval (default 500)
#   --miss-threshold N    domain miss threshold for scenario B (default 2)
#   --skip-hardware       run only scenario A (no cable pulls required)
#   --no-rtd              skip EL3202 slave

# ---------------------------------------------------------------------------
# Drivers
# ---------------------------------------------------------------------------

defmodule FT.EL1809 do
  @behaviour EtherCAT.Slave.Driver
  def process_data_model(_), do: Enum.map(1..16, &{:"ch#{&1}", 0x1A00 + &1 - 1})
  def encode_signal(_, _, _), do: <<>>
  def decode_signal(_, _, <<_::7, bit::1>>), do: bit
  def decode_signal(_, _, _), do: 0
end

defmodule FT.EL2809 do
  @behaviour EtherCAT.Slave.Driver
  def process_data_model(_), do: Enum.map(1..16, &{:"ch#{&1}", 0x1600 + &1 - 1})
  def encode_signal(_, _, value), do: <<value::8>>
  def decode_signal(_, _, _), do: nil
end

defmodule FT.EL3202 do
  @behaviour EtherCAT.Slave.Driver
  def process_data_model(_), do: [channel1: 0x1A00, channel2: 0x1A01]
  def mailbox_config(_),
    do: [
      {:sdo_download, 0x8000, 0x19, <<8::16-little>>},
      {:sdo_download, 0x8010, 0x19, <<8::16-little>>}
    ]
  def encode_signal(_, _, _), do: <<>>
  def decode_signal(_, _, _), do: nil
end

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

defmodule FT.Helpers do
  alias EtherCAT.Slave.Registers

  def assert_telemetry(event, timeout_ms \\ 2_000) do
    ref = make_ref()
    self = self()

    :telemetry.attach(
      "ft-assert-#{inspect(ref)}",
      event,
      fn _ev, _m, _meta, _ -> send(self, {:telemetry_fired, ref, event}) end,
      nil
    )

    result =
      receive do
        {:telemetry_fired, ^ref, ^event} -> :ok
      after
        timeout_ms -> {:error, :not_fired}
      end

    :telemetry.detach("ft-assert-#{inspect(ref)}")
    result
  end

  def read_al_status(bus, station) do
    case EtherCAT.Bus.transaction(
           bus,
           EtherCAT.Bus.Transaction.fprd(station, Registers.al_status())
         ) do
      {:ok, [%{data: bytes, wkc: 1}]} -> {:ok, Registers.decode_al_status(bytes)}
      _ -> {:error, :no_response}
    end
  end

  def poll_until_al(bus, station, target_al_code, timeout_ms, poll_ms \\ 50) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> :ok end)
    |> Enum.reduce_while(:polling, fn _, _ ->
      case read_al_status(bus, station) do
        {:ok, {^target_al_code, _}} ->
          {:halt, :ok}

        {:ok, {state, _}} ->
          if System.monotonic_time(:millisecond) >= deadline do
            {:halt, {:error, :timeout, state}}
          else
            Process.sleep(poll_ms)
            {:cont, :polling}
          end

        _ ->
          Process.sleep(poll_ms)
          {:cont, :polling}
      end
    end)
  end

  def print(label, status, detail \\ "") do
    mark = if status == :ok, do: "✓", else: "✗"
    extra = if detail != "", do: "  #{detail}", else: ""
    IO.puts("  #{mark} #{label}#{extra}")
  end

  def prompt(msg) do
    IO.write("\n  ⚡ #{msg}\n  Press ENTER when ready... ")
    IO.read(:line)
    IO.puts("")
  end

  def section(title) do
    IO.puts("\n── #{title} #{String.duplicate("─", max(0, 65 - String.length(title)))}")
  end
end

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------

{opts, _, _} =
  OptionParser.parse(System.argv(),
    switches: [
      interface: :string,
      poll_ms: :integer,
      miss_threshold: :integer,
      skip_hardware: :boolean,
      no_rtd: :boolean
    ]
  )

interface      = opts[:interface] || raise "pass --interface, e.g. --interface enp0s31f6"
poll_ms        = Keyword.get(opts, :poll_ms, 500)
miss_threshold = Keyword.get(opts, :miss_threshold, 2)
skip_hardware  = Keyword.get(opts, :skip_hardware, false)
include_rtd    = not Keyword.get(opts, :no_rtd, false)

IO.puts("""
EtherCAT fault tolerance validation
  interface      : #{interface}
  health_poll_ms : #{poll_ms}
  miss_threshold : #{miss_threshold}
  hardware tests : #{if skip_hardware, do: "SKIPPED (--skip-hardware)", else: "enabled"}
""")

# ---------------------------------------------------------------------------
# Helper: start the bus in the standard config used across scenarios
# ---------------------------------------------------------------------------

start_bus = fn health_poll_ms_opt ->
  EtherCAT.stop()
  Process.sleep(500)

  rtd_config = %EtherCAT.Slave.Config{
    name: :rtd,
    driver: FT.EL3202,
    process_data: {:all, :main}
  }

  :ok =
    EtherCAT.start(
      interface: interface,
      domains: [
        %EtherCAT.Domain.Config{
          id: :main,
          cycle_time_us: 10_000,
          miss_threshold: miss_threshold
        }
      ],
      slaves:
        [
          %EtherCAT.Slave.Config{name: :coupler},
          %EtherCAT.Slave.Config{
            name: :inputs,
            driver: FT.EL1809,
            process_data: {:all, :main}
          },
          %EtherCAT.Slave.Config{
            name: :outputs,
            driver: FT.EL2809,
            process_data: {:all, :main},
            health_poll_ms: health_poll_ms_opt
          }
        ] ++ if(include_rtd, do: [rtd_config], else: [])
    )

  :ok = EtherCAT.await_running(15_000)
end

results = %{}

# ===========================================================================
# Scenario A1 — Domain process crash detection
# ===========================================================================

FT.Helpers.section("A1. Domain process crash detection")

start_bus.(nil)
EtherCAT.Telemetry.attach()

{domain_id, domain_pid} =
  case EtherCAT.domains() do
    [{id, _cycle_time_us, pid} | _] -> {id, pid}
    _ -> raise "No domains found"
  end

IO.puts("  Domain #{inspect(domain_id)} pid=#{inspect(domain_pid)}")
IO.puts("  Attaching telemetry listener for [:ethercat, :domain, :crashed]...")

# Subscribe before kill to avoid race
waiter = self()

:telemetry.attach(
  "ft-domain-crash",
  [:ethercat, :domain, :crashed],
  fn _, _, meta, _ -> send(waiter, {:got_domain_crashed, meta}) end,
  nil
)

Process.exit(domain_pid, :kill)

a1_result =
  receive do
    {:got_domain_crashed, meta} ->
      FT.Helpers.print("domain crashed event fired", :ok, "domain=#{inspect(meta.domain)}")
      :ok
  after
    2_000 ->
      FT.Helpers.print("domain crashed event", :error, "NOT received within 2s")
      :error
  end

:telemetry.detach("ft-domain-crash")
results = Map.put(results, :a1, a1_result)

# ===========================================================================
# Scenario A2 — Slave process crash detection
# ===========================================================================

FT.Helpers.section("A2. Slave process crash detection")

# Restart clean after A1 killed the domain
start_bus.(nil)

%{pid: slave_pid} = Enum.find(EtherCAT.slaves(), &(&1.name == :outputs))

IO.puts("  Slave :outputs pid=#{inspect(slave_pid)}")

:telemetry.attach(
  "ft-slave-crash",
  [:ethercat, :slave, :crashed],
  fn _, _, meta, _ -> send(waiter, {:got_slave_crashed, meta}) end,
  nil
)

Process.exit(slave_pid, :kill)

a2_result =
  receive do
    {:got_slave_crashed, meta} ->
      FT.Helpers.print("slave crashed event fired", :ok, "slave=#{inspect(meta.slave)}")
      :ok
  after
    2_000 ->
      FT.Helpers.print("slave crashed event", :error, "NOT received within 2s")
      :error
  end

:telemetry.detach("ft-slave-crash")
results = Map.put(results, :a2, a2_result)

# ===========================================================================
# Scenario B — Domain stop notification (cable pull)
# ===========================================================================

results =
  if skip_hardware do
    IO.puts("\n── B. Domain stop notification ── SKIPPED (--skip-hardware) ──────")
    Map.put(results, :b, :skipped)
  else
    FT.Helpers.section("B. Domain stop notification (cable pull — #{miss_threshold} miss threshold)")

    start_bus.(nil)

    :telemetry.attach(
      "ft-domain-stop",
      [:ethercat, :domain, :stopped],
      fn _, _, meta, _ -> send(waiter, {:got_domain_stopped, meta}) end,
      nil
    )

    FT.Helpers.prompt(
      "Pull the EtherCAT cable. The domain will stop after #{miss_threshold} consecutive misses."
    )

    b_result =
      receive do
        {:got_domain_stopped, meta} ->
          FT.Helpers.print(
            "domain stopped event fired",
            :ok,
            "domain=#{inspect(meta.domain)} reason=#{inspect(meta.reason)}"
          )

          :ok
      after
        10_000 ->
          FT.Helpers.print("domain stopped event", :error, "NOT received within 10s")
          :error
      end

    :telemetry.detach("ft-domain-stop")

    FT.Helpers.prompt("Reconnect the cable, then press ENTER.")

    Map.put(results, :b, b_result)
  end

# ===========================================================================
# Scenario C — Health poll + ESM retreat
# ===========================================================================

results =
  if skip_hardware do
    IO.puts("\n── C. Health poll + ESM retreat ── SKIPPED (--skip-hardware) ─────")
    Map.put(results, :c, :skipped)
  else
    FT.Helpers.section("C. Health poll fault detection + ESM retreat (health_poll_ms=#{poll_ms})")

    start_bus.(poll_ms)
    bus = EtherCAT.bus()

    %{station: outputs_station} =
      Enum.find(EtherCAT.slaves(), &(&1.name == :outputs)) ||
        raise("slave :outputs not found")

    IO.puts("  :outputs at station=0x#{Integer.to_string(outputs_station, 16)}")
    IO.puts("  Health poll will detect fault within ~#{poll_ms} ms of cable pull")

    :telemetry.attach(
      "ft-health-fault",
      [:ethercat, :slave, :health, :fault],
      fn _, meas, meta, _ ->
        send(waiter, {:got_health_fault, meta, meas})
      end,
      nil
    )

    FT.Helpers.prompt(
      "Pull the EtherCAT cable on the :outputs (EL2809) segment. The health poll will fire within #{poll_ms} ms."
    )

    t_pull = System.monotonic_time(:millisecond)

    c_result =
      receive do
        {:got_health_fault, meta, meas} ->
          latency = System.monotonic_time(:millisecond) - t_pull

          FT.Helpers.print(
            "health fault event fired",
            :ok,
            "slave=#{inspect(meta.slave)} al_state=0x#{Integer.to_string(meas.al_state, 16)} code=0x#{Integer.to_string(meas.error_code, 16)} latency=~#{latency}ms"
          )

          :ok
      after
        poll_ms * 4 ->
          FT.Helpers.print("health fault event", :error, "NOT received within #{poll_ms * 4}ms")
          :error
      end

    :telemetry.detach("ft-health-fault")

    # Verify AL status is now SafeOp
    Process.sleep(200)

    case FT.Helpers.read_al_status(bus, outputs_station) do
      {:ok, {0x04, _}} ->
        FT.Helpers.print("slave retreated to SafeOp (AL=0x04)", :ok)

      {:ok, {al, _}} ->
        FT.Helpers.print("slave AL state", :error, "expected 0x04 SafeOp, got 0x#{Integer.to_string(al, 16)}")

      _ ->
        FT.Helpers.print("AL status read after retreat", :error, "no response")
    end

    Map.put(results, :c, c_result)
  end

# ===========================================================================
# Scenario D — Master recovery after cable reconnect
# ===========================================================================

results =
  if skip_hardware or Map.get(results, :c) == :skipped do
    IO.puts("\n── D. Recovery ── SKIPPED ─────────────────────────────────────────")
    Map.put(results, :d, :skipped)
  else
    FT.Helpers.section("D. Recovery — reconnect and return to Op")

    bus = EtherCAT.bus()

    %{station: outputs_station} =
      Enum.find(EtherCAT.slaves(), &(&1.name == :outputs)) ||
        raise("slave :outputs not found")

    FT.Helpers.prompt("Reconnect the EtherCAT cable now.")

    t_reconnect = System.monotonic_time(:millisecond)

    IO.puts("  Waiting for :outputs to return to Op (max 10s)...")

    d_result =
      case FT.Helpers.poll_until_al(bus, outputs_station, 0x08, 10_000) do
        :ok ->
          latency = System.monotonic_time(:millisecond) - t_reconnect
          FT.Helpers.print("slave returned to Op", :ok, "in #{latency} ms")
          :ok

        {:error, :timeout, last} ->
          FT.Helpers.print("slave did NOT return to Op", :error, "last AL=0x#{Integer.to_string(last, 16)}")
          :error
      end

    Map.put(results, :d, d_result)
  end

# ===========================================================================
# Summary
# ===========================================================================

FT.Helpers.section("Summary")

Enum.each(
  [
    {:a1, "A1 Domain crash detection"},
    {:a2, "A2 Slave crash detection"},
    {:b, "B  Domain stop notification"},
    {:c, "C  Health poll fault detection"},
    {:d, "D  Slave recovery to Op"}
  ],
  fn {key, label} ->
    case Map.get(results, key, :skipped) do
      :ok      -> IO.puts("  ✓ #{label}")
      :error   -> IO.puts("  ✗ #{label}  ← FAILED")
      :skipped -> IO.puts("  - #{label}  (skipped)")
    end
  end
)

IO.puts("")
EtherCAT.stop()
