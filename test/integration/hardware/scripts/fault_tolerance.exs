#!/usr/bin/env elixir
# EtherCAT fault tolerance validation.
#
# ## Hardware Requirements
#
# Required slaves:
#   - EK1100 coupler
#   - EL1809 digital input terminal at slave name `:inputs`
#   - EL2809 digital output terminal at slave name `:outputs`
#
# Optional slaves:
#   - EL3202 at slave name `:rtd` when `--no-rtd` is not used
#
# Required wiring:
#   - the maintained bench order `EK1100 -> EL1809 -> EL2809 -> EL3202`
#   - physical access to the host-side main cable and to the segment cable after
#     `:outputs` so scenarios B-D can be triggered on demand
#
# Required capabilities:
#   - runtime telemetry events for domain/slave crashes and reconnects
#   - optional split-domain support when `--split-sm` is used
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
#        - master enters :recovering
#        - domain either keeps cycling or stops, depending on whether the
#          physical topology still returns frames after the pull
#
#   D. Recovery after disconnect (reconnect cable after C)
#      slave reinitialises via :down reconnect poll →
#        - slave reaches :preop (post_transition sends {:slave_ready})
#        - if C stopped the domain, master restarts it
#        - master activates to :op → returns to :operational
#
# Usage:
#   MIX_ENV=test mix run test/integration/hardware/scripts/fault_tolerance.exs --interface enp0s31f6
#   MIX_ENV=test mix run test/integration/hardware/scripts/fault_tolerance.exs --interface enp0s31f6 --split-sm
#
# Optional flags:
#   --poll-ms N           health poll interval (default 500)
#   --miss-threshold N    domain miss threshold for scenario B (default 2)
#   --split-sm            split EL1809/EL2809 ch1/ch2 across :fast / :slow domains
#   --skip-hardware       run only scenario A (no cable pulls required)
#   --no-rtd              skip EL3202 slave

alias EtherCAT.IntegrationSupport.Hardware

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

defmodule FT.Helpers do
  alias EtherCAT.Slave.ESC.Registers

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

  def poll_until_state(target_state, timeout_ms, poll_ms \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> :ok end)
    |> Enum.reduce_while(:polling, fn _, _ ->
      state = EtherCAT.state()

      if state == {:ok, target_state} do
        {:halt, :ok}
      else
        if System.monotonic_time(:millisecond) >= deadline do
          {:halt, {:error, :timeout, state}}
        else
          Process.sleep(poll_ms)
          {:cont, :polling}
        end
      end
    end)
  end

  def poll_until_domains_state(domain_ids, target_state, timeout_ms, poll_ms \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> :ok end)
    |> Enum.reduce_while(:polling, fn _, _ ->
      states =
        Enum.map(domain_ids, fn domain_id ->
          case EtherCAT.Diagnostics.domain_info(domain_id) do
            {:ok, %{state: state}} -> {domain_id, {:ok, state}}
            {:error, reason} -> {domain_id, {:error, reason}}
          end
        end)

      if Enum.all?(states, fn
           {_domain_id, {:ok, ^target_state}} -> true
           _other -> false
         end) do
        {:halt, {:ok, states}}
      else
        if System.monotonic_time(:millisecond) >= deadline do
          {:halt, {:error, :timeout, states}}
        else
          Process.sleep(poll_ms)
          {:cont, :polling}
        end
      end
    end)
  end

  def domain_snapshot(domain_ids) do
    Enum.into(domain_ids, %{}, fn domain_id ->
      {:ok, stats} = EtherCAT.Domain.stats(domain_id)
      {:ok, info} = EtherCAT.Diagnostics.domain_info(domain_id)

      {domain_id, %{cycle_count: stats.cycle_count, state: info.state}}
    end)
  end

  def attachment_domains(slave_name) do
    with {:ok, info} <- EtherCAT.Diagnostics.slave_info(slave_name) do
      domains =
        info.attachments
        |> Enum.map(& &1.domain)
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, domains}
    end
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
      split_sm: :boolean,
      no_rtd: :boolean
    ]
  )

interface = opts[:interface] || raise "pass --interface, e.g. --interface enp0s31f6"
poll_ms = Keyword.get(opts, :poll_ms, 500)
miss_threshold = Keyword.get(opts, :miss_threshold, 2)
skip_hardware = Keyword.get(opts, :skip_hardware, false)
include_rtd = not Keyword.get(opts, :no_rtd, false)
split_sm = Keyword.get(opts, :split_sm, false)

main_domain_ids = if split_sm, do: [:fast, :slow], else: [:main]
split_slow_cycle_us = 20_000
split_rtd_cycle_us = 50_000

IO.puts("""
EtherCAT fault tolerance validation
  interface      : #{interface}
  topology       : #{if split_sm, do: "split-sm (:fast / :slow)", else: "single-domain (:main)"}
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

  domains =
    if split_sm do
      [
        Hardware.main_domain(id: :fast, cycle_time_us: 10_000, miss_threshold: miss_threshold),
        Hardware.main_domain(
          id: :slow,
          cycle_time_us: split_slow_cycle_us,
          miss_threshold: miss_threshold
        )
      ] ++
        if(include_rtd,
          do: [
            Hardware.main_domain(
              id: :rtd,
              cycle_time_us: split_rtd_cycle_us,
              miss_threshold: miss_threshold
            )
          ],
          else: []
        )
    else
      [
        Hardware.main_domain(id: :main, cycle_time_us: 10_000, miss_threshold: miss_threshold)
      ]
    end

  input_process_data =
    if split_sm do
      [ch1: :fast, ch2: :slow]
    else
      {:all, :main}
    end

  output_process_data =
    if split_sm do
      # Maintained bench assumption: ch1 stays in the fast domain and ch2 stays
      # in the slow domain on both EL1809 and EL2809. If your wiring or signal
      # split differs, update both input/output mappings together.
      [ch1: :fast, ch2: :slow]
    else
      {:all, :main}
    end

  rtd_config =
    Hardware.rtd(process_data: if(split_sm, do: {:all, :rtd}, else: {:all, :main}))

  :ok =
    EtherCAT.start(
      backend: {:raw, %{interface: interface}},
      domains: domains,
      slaves:
        [
          Hardware.coupler(),
          Hardware.inputs(process_data: input_process_data),
          Hardware.outputs(process_data: output_process_data, health_poll_ms: health_poll_ms_opt)
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
  case EtherCAT.Diagnostics.domains() do
    {:ok, [{id, _cycle_time_us, pid} | _]} -> {id, pid}
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

{:ok, slaves} = EtherCAT.Diagnostics.slaves()
%{pid: slave_pid} = Enum.find(slaves, &(&1.name == :outputs))

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
    # Maintained bench assumption: "main cable" means the host-facing cable
    # into the EK1100. If your topology uses a switch or bridge upstream,
    # adapt the pull point so this scenario causes frame-level loss.
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

    b_event_result =
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

    b_state_result =
      case FT.Helpers.poll_until_domains_state(main_domain_ids, :stopped, 5_000) do
        {:ok, states} ->
          domains =
            states
            |> Enum.map(fn {domain_id, _state} -> inspect(domain_id) end)
            |> Enum.join(", ")

          FT.Helpers.print("tracked domains reached :stopped", :ok, domains)
          :ok

        {:error, :timeout, states} ->
          FT.Helpers.print(
            "tracked domains reached :stopped",
            :error,
            inspect(states)
          )

          :error
      end

    b_result = if b_event_result == :ok and b_state_result == :ok, do: :ok, else: :error

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
    # Maintained bench assumption: the disconnect point is the segment after the
    # EL2809 named :outputs. Change both the prompt and the downstream
    # assertions if your watched slave or split point differ.
    IO.puts("  Pull the cable AFTER the :outputs (EL2809) slave.")
    IO.puts("  Expected:")
    IO.puts("    - [:ethercat, :slave, :down] fires within ~#{poll_ms} ms")
    IO.puts("    - master enters :recovering")
    IO.puts("    - domain outcome depends on topology:")
    IO.puts("        cycling  → frame return path stayed intact")
    IO.puts("        stopped  → cable pull broke the return path / segment")

    if split_sm do
      IO.puts("    - split-SM attachments on :inputs / :outputs should remain")
      IO.puts("      mapped to :fast and :slow after recovery")
    end

    start_bus.(poll_ms)

    domain_snapshot_before = FT.Helpers.domain_snapshot(main_domain_ids)

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

    # Give the domains enough time to either keep cycling or trip miss_threshold.
    Process.sleep(max(200, poll_ms))

    {domain_status, domain_modes} =
      main_domain_ids
      |> Enum.map(fn domain_id ->
        before = Map.fetch!(domain_snapshot_before, domain_id)
        domain_after = FT.Helpers.domain_snapshot([domain_id]) |> Map.fetch!(domain_id)

        case domain_after.state do
          :cycling when domain_after.cycle_count > before.cycle_count ->
            FT.Helpers.print(
              "domain stayed in :cycling after disconnect",
              :ok,
              "#{inspect(domain_id)} #{before.cycle_count} → #{domain_after.cycle_count} (+#{domain_after.cycle_count - before.cycle_count} cycles)"
            )

            {domain_id, {:ok, :cycling}}

          :stopped ->
            FT.Helpers.print(
              "domain stopped after disconnect",
              :ok,
              "#{inspect(domain_id)} segment pull broke the return path; recovery will restart it"
            )

            {domain_id, {:ok, :stopped}}

          :cycling ->
            FT.Helpers.print(
              "domain state",
              :error,
              "#{inspect(domain_id)} still :cycling but cycle_count did not advance (#{before.cycle_count} → #{domain_after.cycle_count})"
            )

            {domain_id, {:error, :cycling}}

          other ->
            FT.Helpers.print(
              "domain state",
              :error,
              "#{inspect(domain_id)} unexpected state #{inspect(other)} (cycles #{before.cycle_count} → #{domain_after.cycle_count})"
            )

            {domain_id, {:error, other}}
        end
      end)
      |> then(fn results_by_domain ->
        ok? =
          Enum.all?(results_by_domain, fn
            {_domain_id, {:ok, _mode}} -> true
            _other -> false
          end)

        modes =
          Enum.into(results_by_domain, %{}, fn {domain_id, result} ->
            {domain_id, elem(result, 1)}
          end)

        {if(ok?, do: :ok, else: :error), modes}
      end)

    # Verify master entered :recovering
    state_status =
      case FT.Helpers.poll_until_state(:recovering, 2_000) do
        :ok ->
          FT.Helpers.print("master entered :recovering", :ok)
          :ok

        {:error, :timeout, state} ->
          FT.Helpers.print("master state", :error, "expected :recovering, got #{inspect(state)}")
          :error
      end

    c_status =
      if c_result == :ok and domain_status == :ok and state_status == :ok, do: :ok, else: :error

    {Map.put(results, :c, c_status), domain_modes}
  end

# ===========================================================================
# Scenario D — Recovery after slave reconnect
# ===========================================================================

results =
  if skip_hardware or c_domain_mode == :skipped do
    IO.puts("\n── D. Recovery after reconnect ── SKIPPED ──────────────────────────")
    Map.put(results, :d, :skipped)
  else
    FT.Helpers.section("D. Recovery — reconnect and return to :operational")
    IO.puts("  Reconnect the cable. Slave will reconnect-poll, reinitialise,")
    IO.puts("  reach :preop, and master will activate it back to :op.")

    if Enum.any?(c_domain_mode, fn {_domain_id, mode} -> mode == :stopped end) do
      IO.puts("  This topology stopped the domain during C, so recovery also waits")
      IO.puts("  for the master to restart the affected domains and clear the runtime fault.")
    end

    FT.Helpers.prompt("Reconnect the cable after :outputs, then press ENTER.")

    t_reconnect = System.monotonic_time(:millisecond)

    IO.puts("  Waiting for master to return to :operational (max 15s)...")

    d_result =
      case FT.Helpers.poll_until_state(:operational, 15_000) do
        :ok ->
          latency = System.monotonic_time(:millisecond) - t_reconnect
          FT.Helpers.print("master returned to :operational", :ok, "in #{latency} ms")

          domain_result =
            case FT.Helpers.poll_until_domains_state(main_domain_ids, :cycling, 5_000) do
              {:ok, _states} ->
                FT.Helpers.print(
                  "tracked domains are cycling again",
                  :ok,
                  Enum.map_join(main_domain_ids, ", ", &inspect/1)
                )

                :ok

              {:error, :timeout, states} ->
                FT.Helpers.print(
                  "tracked domains after recovery",
                  :error,
                  inspect(states)
                )

                :error
            end

          split_attachment_result =
            if split_sm do
              expected_domains = Enum.sort(main_domain_ids)

              with {:ok, input_domains} <- FT.Helpers.attachment_domains(:inputs),
                   {:ok, output_domains} <- FT.Helpers.attachment_domains(:outputs) do
                cond do
                  input_domains != expected_domains ->
                    FT.Helpers.print(
                      "split-SM attachments on :inputs",
                      :error,
                      "expected #{inspect(expected_domains)}, got #{inspect(input_domains)}"
                    )

                    :error

                  output_domains != expected_domains ->
                    FT.Helpers.print(
                      "split-SM attachments on :outputs",
                      :error,
                      "expected #{inspect(expected_domains)}, got #{inspect(output_domains)}"
                    )

                    :error

                  true ->
                    FT.Helpers.print(
                      "split-SM attachments restored after recovery",
                      :ok,
                      "#{inspect(expected_domains)}"
                    )

                    :ok
                end
              else
                {:error, reason} ->
                  FT.Helpers.print(
                    "split-SM attachment info after recovery",
                    :error,
                    inspect(reason)
                  )

                  :error
              end
            else
              :ok
            end

          if domain_result == :ok and split_attachment_result == :ok, do: :ok, else: :error

        {:error, :timeout, last_state} ->
          FT.Helpers.print(
            "master did NOT return to :operational",
            :error,
            "last state=#{inspect(last_state)}"
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
    {:c, "C  Slave disconnect → :down + recovery domain outcome"},
    {:d, "D  Slave reconnect → :op + master :operational"}
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
