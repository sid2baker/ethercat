#!/usr/bin/env elixir
# EtherCAT fault tolerance validation.
#
# Tests the runtime fault detection and recovery mechanisms:
#
#   A. Process crash detection (no hardware interaction required)
#      A1. Kill the domain process → [:ethercat, :domain, :crashed] fires
#      A2. Kill a slave process   → [:ethercat, :slave, :crashed]  fires
#
#   B. Domain stop on total bus failure (main cable pull — ~1 s)
#      miss_threshold: 2, pull main cable → frame errors accumulate →
#      [:ethercat, :domain, :stopped] fires. Domain only stops on frame errors,
#      NOT on WKC mismatch (partial slave loss).
#
#   C. Slave disconnect → :down state (cable pull on slave segment)
#      health_poll_ms: 500 on :outputs; pull cable after :outputs →
#        - [:ethercat, :slave, :down] fires within ~500 ms
#        - master enters :degraded
#        - domain either keeps cycling or stops, depending on whether the
#          physical topology still returns frames after the pull
#
#   D. Recovery after disconnect (reconnect cable after C)
#      slave reinitialises via :down reconnect poll →
#        - slave reaches :preop (post_transition sends {:slave_ready})
#        - if C stopped the domain, master restarts it
#        - master activates to :op → returns to :running
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

  def poll_until_phase(target_phase, timeout_ms, poll_ms \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> :ok end)
    |> Enum.reduce_while(:polling, fn _, _ ->
      phase = EtherCAT.phase()

      if phase == target_phase do
        {:halt, :ok}
      else
        if System.monotonic_time(:millisecond) >= deadline do
          {:halt, {:error, :timeout, phase}}
        else
          Process.sleep(poll_ms)
          {:cont, :polling}
        end
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

defmodule FT.TelemetryHandlers do
  def forward(_event, _measurements, metadata, %{waiter: waiter, tag: tag}) do
    send(waiter, {tag, metadata})
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

interface = opts[:interface] || raise "pass --interface, e.g. --interface enp0s31f6"
poll_ms = Keyword.get(opts, :poll_ms, 500)
miss_threshold = Keyword.get(opts, :miss_threshold, 2)
skip_hardware = Keyword.get(opts, :skip_hardware, false)
include_rtd = not Keyword.get(opts, :no_rtd, false)

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
waiter = self()

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

:telemetry.attach(
  "ft-domain-crash",
  [:ethercat, :domain, :crashed],
  &FT.TelemetryHandlers.forward/4,
  %{waiter: waiter, tag: :got_domain_crashed}
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

start_bus.(nil)

%{pid: slave_pid} = Enum.find(EtherCAT.slaves(), &(&1.name == :outputs))

IO.puts("  Slave :outputs pid=#{inspect(slave_pid)}")

:telemetry.attach(
  "ft-slave-crash",
  [:ethercat, :slave, :crashed],
  &FT.TelemetryHandlers.forward/4,
  %{waiter: waiter, tag: :got_slave_crashed}
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
# Scenario B — Domain stop on total bus failure (main cable pull)
# ===========================================================================

results =
  if skip_hardware do
    IO.puts("\n── B. Domain stop (total bus failure) ── SKIPPED (--skip-hardware) ─")
    Map.put(results, :b, :skipped)
  else
    FT.Helpers.section("B. Domain stop on total bus failure (miss_threshold=#{miss_threshold})")
    IO.puts("  NOTE: Pull the MAIN cable (from PC/switch to EK1100 coupler),")
    IO.puts("        NOT a cable between slaves. This causes frame-level errors")
    IO.puts("        which accumulate toward miss_threshold.")
    IO.puts("        Pulling between slaves causes WKC mismatch (scenario C),")
    IO.puts("        which now keeps the domain cycling.")

    start_bus.(nil)

    :telemetry.attach(
      "ft-domain-stop",
      [:ethercat, :domain, :stopped],
      &FT.TelemetryHandlers.forward/4,
      %{waiter: waiter, tag: :got_domain_stopped}
    )

    FT.Helpers.prompt(
      "Pull the MAIN EtherCAT cable (PC → EK1100). Domain stops after #{miss_threshold} frame errors."
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

    FT.Helpers.prompt("Reconnect the main cable, then press ENTER.")

    Map.put(results, :b, b_result)
  end

# ===========================================================================
# Scenario C — Slave disconnect → :down state (cable pull on slave segment)
# ===========================================================================

{results, c_domain_mode} =
  if skip_hardware do
    IO.puts("\n── C. Slave disconnect → :down ── SKIPPED (--skip-hardware) ────────")
    {Map.put(results, :c, :skipped), :skipped}
  else
    FT.Helpers.section("C. Slave disconnect → :down (health_poll_ms=#{poll_ms})")
    IO.puts("  Pull the cable AFTER the :outputs (EL2809) slave.")
    IO.puts("  Expected:")
    IO.puts("    - [:ethercat, :slave, :down] fires within ~#{poll_ms} ms")
    IO.puts("    - master enters :degraded")
    IO.puts("    - domain outcome depends on topology:")
    IO.puts("        cycling  → frame return path stayed intact")
    IO.puts("        stopped  → cable pull broke the return path / segment")

    start_bus.(poll_ms)

    {:ok, stats_before} = EtherCAT.Domain.stats(:main)
    cycle_before = stats_before.cycle_count

    :telemetry.attach(
      "ft-slave-down",
      [:ethercat, :slave, :down],
      &FT.TelemetryHandlers.forward/4,
      %{waiter: waiter, tag: :got_slave_down}
    )

    FT.Helpers.prompt(
      "Pull the cable AFTER :outputs (EL2809). Health poll detects within #{poll_ms} ms."
    )

    t_pull = System.monotonic_time(:millisecond)

    c_result =
      receive do
        {:got_slave_down, meta} ->
          latency = System.monotonic_time(:millisecond) - t_pull

          FT.Helpers.print(
            "slave_down event fired",
            :ok,
            "slave=#{inspect(meta.slave)} latency=~#{latency}ms"
          )

          :ok
      after
        poll_ms * 4 ->
          FT.Helpers.print("slave_down event", :error, "NOT received within #{poll_ms * 4}ms")
          :error
      end

    :telemetry.detach("ft-slave-down")

    # Give the domain enough time to either keep cycling or trip miss_threshold.
    Process.sleep(200)
    {:ok, stats_after} = EtherCAT.Domain.stats(:main)
    {:ok, domain_info_after} = EtherCAT.domain_info(:main)
    cycle_after = stats_after.cycle_count

    {domain_status, domain_mode} =
      case domain_info_after.state do
        :cycling when cycle_after > cycle_before ->
          FT.Helpers.print(
            "domain stayed in :cycling after disconnect",
            :ok,
            "#{cycle_before} → #{cycle_after} (+#{cycle_after - cycle_before} cycles)"
          )

          {:ok, :cycling}

        :stopped ->
          FT.Helpers.print(
            "domain stopped after disconnect",
            :ok,
            "segment pull broke the return path; recovery will restart it"
          )

          {:ok, :stopped}

        :cycling ->
          FT.Helpers.print(
            "domain state",
            :error,
            "still :cycling but cycle_count did not advance (#{cycle_before} → #{cycle_after})"
          )

          {:error, :cycling}

        other ->
          FT.Helpers.print(
            "domain state",
            :error,
            "unexpected state #{inspect(other)} (cycles #{cycle_before} → #{cycle_after})"
          )

          {:error, other}
      end

    # Verify master entered :degraded
    phase_status =
      case FT.Helpers.poll_until_phase(:degraded, 2_000) do
        :ok ->
          FT.Helpers.print("master entered :degraded", :ok)
          :ok

        {:error, :timeout, phase} ->
          FT.Helpers.print("master phase", :error, "expected :degraded, got #{inspect(phase)}")
          :error
      end

    c_status =
      if c_result == :ok and domain_status == :ok and phase_status == :ok do
        :ok
      else
        :error
      end

    {Map.put(results, :c, c_status), domain_mode}
  end

# ===========================================================================
# Scenario D — Recovery after slave reconnect
# ===========================================================================

results =
  if skip_hardware or c_domain_mode == :skipped do
    IO.puts("\n── D. Recovery after reconnect ── SKIPPED ──────────────────────────")
    Map.put(results, :d, :skipped)
  else
    FT.Helpers.section("D. Recovery — reconnect and return to :running")
    IO.puts("  Reconnect the cable. Slave will reconnect-poll, reinitialise,")
    IO.puts("  reach :preop, and master will activate it back to :op.")

    if c_domain_mode == :stopped do
      IO.puts("  This topology stopped the domain during C, so recovery also waits")
      IO.puts("  for the master to restart :main and clear the runtime fault.")
    end

    FT.Helpers.prompt("Reconnect the cable after :outputs, then press ENTER.")

    t_reconnect = System.monotonic_time(:millisecond)

    IO.puts("  Waiting for master to return to :running (max 15s)...")

    d_result =
      case FT.Helpers.poll_until_phase(:operational, 15_000) do
        :ok ->
          latency = System.monotonic_time(:millisecond) - t_reconnect
          FT.Helpers.print("master returned to :running / :operational", :ok, "in #{latency} ms")

          case EtherCAT.domain_info(:main) do
            {:ok, %{state: :cycling}} ->
              FT.Helpers.print("domain :main is cycling again", :ok)
              :ok

            {:ok, %{state: state}} ->
              FT.Helpers.print(
                "domain :main state after recovery",
                :error,
                "expected :cycling, got #{inspect(state)}"
              )

              :error

            {:error, reason} ->
              FT.Helpers.print(
                "domain :main info after recovery",
                :error,
                inspect(reason)
              )

              :error
          end

        {:error, :timeout, last_phase} ->
          FT.Helpers.print(
            "master did NOT return to :running",
            :error,
            "last phase=#{inspect(last_phase)}"
          )

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
    {:b, "B  Domain stop on total bus failure"},
    {:c, "C  Slave disconnect → :down + degraded domain outcome"},
    {:d, "D  Slave reconnect → :op + master :running"}
  ],
  fn {key, label} ->
    case Map.get(results, key, :skipped) do
      :ok -> IO.puts("  ✓ #{label}")
      :error -> IO.puts("  ✗ #{label}  ← FAILED")
      :skipped -> IO.puts("  - #{label}  (skipped)")
    end
  end
)

IO.puts("")
EtherCAT.stop()
