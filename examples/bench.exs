# EtherCAT link latency benchmark.
#
# Sends N BRD frames and reports RTT statistics.
# Paste into IEx on the target, or run via: mix run examples/bench.exs
#
# Usage in IEx:
#   import_file("examples/bench.exs")
#   Bench.run("eth0")
#   Bench.run("eth0", frames: 200)

defmodule Bench do
  alias EtherCAT.Link
  alias EtherCAT.Link.Transaction

  @default_frames 100

  def run(interface, opts \\ []) do
    frames = Keyword.get(opts, :frames, @default_frames)

    IO.puts("\nEtherCAT link bench — #{interface}, #{frames} frames")
    IO.puts(String.duplicate("-", 50))

    {:ok, link} = Link.start_link(interface: interface)

    # Warm-up: one frame to prime the socket
    Link.transaction(link, &Transaction.brd(&1, {0x0000, 1}))

    samples =
      Enum.map(1..frames, fn i ->
        t0 = System.monotonic_time(:microsecond)
        result = Link.transaction(link, &Transaction.brd(&1, {0x0000, 1}))
        t1 = System.monotonic_time(:microsecond)
        rtt_us = t1 - t0

        case result do
          {:ok, [%{wkc: wkc}]} -> {rtt_us, wkc, :ok}
          {:error, reason} ->
            IO.puts("  frame #{i}: #{inspect(reason)}")
            {rtt_us, 0, :error}
        end
      end)

    ok_samples = for {rtt, _wkc, :ok} <- samples, do: rtt
    err_count = Enum.count(samples, fn {_, _, s} -> s == :error end)

    if ok_samples == [] do
      IO.puts("All #{frames} frames failed — check cable and interface.")
    else
      sorted = Enum.sort(ok_samples)
      n = length(sorted)
      min_us = List.first(sorted)
      max_us = List.last(sorted)
      avg_us = div(Enum.sum(sorted), n)
      p50_us = Enum.at(sorted, div(n, 2))
      p95_us = Enum.at(sorted, round(n * 0.95) - 1)
      p99_us = Enum.at(sorted, round(n * 0.99) - 1)

      {_rtt, wkc, _} = hd(samples)

      IO.puts("  slaves (wkc)  : #{wkc}")
      IO.puts("  frames ok/err : #{n}/#{err_count}")
      IO.puts("  min  RTT      : #{fmt(min_us)}")
      IO.puts("  avg  RTT      : #{fmt(avg_us)}")
      IO.puts("  p50  RTT      : #{fmt(p50_us)}")
      IO.puts("  p95  RTT      : #{fmt(p95_us)}")
      IO.puts("  p99  RTT      : #{fmt(p99_us)}")
      IO.puts("  max  RTT      : #{fmt(max_us)}")
      IO.puts("")

      cond do
        avg_us < 1_000 ->
          IO.puts("  EXCELLENT — well within EtherCAT timing budget.")
        avg_us < 10_000 ->
          IO.puts("  OK — usable, but check for jitter if using DC sync.")
        avg_us < 90_000 ->
          IO.puts("  SLOW — link timeouts may need tuning (current limit: 100ms).")
        true ->
          IO.puts("  TOO SLOW — at #{fmt(avg_us)} avg, DC and slave init will timeout.")
          IO.puts("             Check: NIC driver, kernel AF_PACKET config, USB path.")
      end
    end

    :gen_statem.stop(link)
    :ok
  end

  defp fmt(us) when us < 1_000, do: "#{us} µs"
  defp fmt(us), do: "#{Float.round(us / 1_000.0, 1)} ms"
end

# Auto-run if invoked via mix run
if System.get_env("MIX_ENV") != nil or match?([_ | _], System.argv()) do
  {opts, _, _} = OptionParser.parse(System.argv(), switches: [interface: :string, frames: :integer])
  interface = opts[:interface] || "eth0"
  frames = opts[:frames] || 100
  Bench.run(interface, frames: frames)
end
