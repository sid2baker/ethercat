#!/usr/bin/env elixir
# Continuous digital loopback watch for redundant primary-link reconnect
# debugging.
#
# This watcher does not start EtherCAT. It assumes the current BEAM runtime
# already owns a running master with:
#
# - slave names: :coupler, :inputs, :outputs
# - digital signal names: :ch1 .. :ch8 on both :inputs and :outputs
# - redundant bus link: primary "eth1", secondary "eth0"
#
# The watcher continuously writes an 8-bit counter across outputs.ch1..ch8,
# waits for inputs.ch1..ch8 to match, and logs both application-level loopback
# results and high-signal telemetry while you manually unplug/replug the
# primary cable.
#
# Usage as a script inside the same runtime is uncommon; the intended use is:
#
# - `Code.require_file/1` from IEx
# - a Livebook cell in the same runtime as the already-running master
#
# A direct `mix run` only works if that same process also started EtherCAT.
#
# Optional flags:
#   --primary-interface IFACE  expected primary link name (default eth1)
#   --backup-interface IFACE   expected secondary link name (default eth0)
#   --step-ms N                application step period in ms (default 20)
#   --match-timeout-ms N       wait this long for input match (default 200)
#   --poll-ms N                input poll interval while waiting (default 1)
#   --steps N                  stop after N steps (default: run forever)
#   --help                     print this message

defmodule EtherCAT.HardwareScripts.RedundantReplugWatch do
  @telemetry_events [
    [:ethercat, :bus, :link, :down],
    [:ethercat, :bus, :link, :reconnected],
    [:ethercat, :master, :state, :changed],
    [:ethercat, :master, :slave_fault, :changed],
    [:ethercat, :domain, :cycle, :invalid],
    [:ethercat, :domain, :cycle, :transport_miss],
    [:ethercat, :slave, :down],
    [:ethercat, :slave, :health, :fault]
  ]

  @default_primary_interface "eth1"
  @default_backup_interface "eth0"
  @default_step_ms 20
  @default_match_timeout_ms 200
  @default_poll_ms 1

  def main(argv) do
    case parse_args(argv) do
      {:help, text} ->
        IO.puts(text)

      {:error, text} ->
        IO.puts(:stderr, text)
        System.halt(1)

      {:ok, opts} ->
        case run(opts) do
          {:ok, _result} -> :ok
          {:error, reason} -> IO.puts(:stderr, inspect(reason))
        end
    end
  end

  def run(opts) when is_list(opts), do: opts |> Enum.into(%{}) |> run()

  def run(opts) when is_map(opts) do
    opts = normalize_runtime_opts(opts)
    start_ms = System.monotonic_time(:millisecond)
    sink = start_sink(start_ms)
    handler_id = "replug-watch-#{System.unique_integer([:positive, :monotonic])}"

    :ok = attach_telemetry(handler_id, sink)

    try do
      with :ok <- ensure_operational_master(opts),
           :ok <- log_startup_summary(sink, opts),
           :ok <- exercise_loop(sink, opts) do
        {:ok, :finished}
      end
    after
      :telemetry.detach(handler_id)
      stop_sink(sink)
    end
  end

  def handle_telemetry(event, measurements, metadata, sink) do
    log(sink, :telemetry, format_telemetry(event, measurements, metadata))
  end

  defp parse_args(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [
          primary_interface: :string,
          backup_interface: :string,
          step_ms: :integer,
          match_timeout_ms: :integer,
          poll_ms: :integer,
          steps: :integer,
          help: :boolean
        ]
      )

    cond do
      opts[:help] || args == ["--help"] ->
        {:help, usage()}

      invalid != [] ->
        {:error, "invalid options: #{inspect(invalid)}\n\n#{usage()}"}

      true ->
        with {:ok, step_ms} <- positive_option(opts[:step_ms], @default_step_ms, "--step-ms"),
             {:ok, match_timeout_ms} <-
               positive_option(
                 opts[:match_timeout_ms],
                 @default_match_timeout_ms,
                 "--match-timeout-ms"
               ),
             {:ok, poll_ms} <- positive_option(opts[:poll_ms], @default_poll_ms, "--poll-ms"),
             {:ok, steps} <- optional_positive_option(opts[:steps], "--steps") do
          {:ok,
           %{
             primary_interface: opts[:primary_interface] || @default_primary_interface,
             backup_interface: opts[:backup_interface] || @default_backup_interface,
             step_ms: step_ms,
             match_timeout_ms: match_timeout_ms,
             poll_ms: poll_ms,
             steps: steps
           }}
        else
          {:error, reason} -> {:error, "#{reason}\n\n#{usage()}"}
        end
    end
  end

  defp normalize_runtime_opts(opts) do
    %{
      primary_interface: Map.get(opts, :primary_interface, @default_primary_interface),
      backup_interface: Map.get(opts, :backup_interface, @default_backup_interface),
      step_ms: Map.get(opts, :step_ms, @default_step_ms),
      match_timeout_ms: Map.get(opts, :match_timeout_ms, @default_match_timeout_ms),
      poll_ms: Map.get(opts, :poll_ms, @default_poll_ms),
      steps: Map.get(opts, :steps)
    }
  end

  defp ensure_operational_master(opts) do
    with {:ok, :operational} <- EtherCAT.state(),
         {:ok, bus_info} <- EtherCAT.Bus.info(EtherCAT.Bus) do
      expected_link = "#{opts.primary_interface}|#{opts.backup_interface}"

      cond do
        bus_info.circuit != expected_link ->
          {:error,
           {:unexpected_bus_link, expected_link, bus_info.circuit,
            "run this watcher in the same runtime as the redundant master"}}

        bus_info.topology not in [
          :redundant,
          :degraded_primary_leg,
          :degraded_secondary_leg,
          :segment_break,
          :unknown
        ] ->
          {:error, {:unexpected_topology, bus_info.topology}}

        true ->
          :ok
      end
    else
      {:ok, state} ->
        {:error, {:master_not_operational, state}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp exercise_loop(sink, opts) do
    Stream.iterate(1, &rem(&1 + 1, 256))
    |> Stream.with_index(1)
    |> Enum.reduce_while(:ok, fn {pattern, step}, :ok ->
      started_us = System.monotonic_time(:microsecond)

      case write_pattern(pattern) do
        :ok ->
          case wait_for_match(pattern, opts.match_timeout_ms, opts.poll_ms) do
            {:ok, observed, matched_at_us, values} ->
              latency_us = matched_at_us - started_us
              log_step_ok(sink, step, pattern, observed, values, latency_us)

            {:error, last_observation} ->
              log_step_timeout(sink, step, pattern, last_observation, opts.match_timeout_ms)
          end

        {:error, reason} ->
          log(
            sink,
            :error,
            "step=#{step} write failed pattern=#{format_byte(pattern)} reason=#{inspect(reason)}"
          )
      end

      Process.sleep(opts.step_ms)

      if is_integer(opts.steps) and step >= opts.steps do
        {:halt, :ok}
      else
        {:cont, :ok}
      end
    end)

    :ok
  end

  defp write_pattern(byte) when is_integer(byte) and byte >= 0 and byte <= 255 do
    bits = channel_values(byte)

    1..8
    |> Enum.zip(bits)
    |> Enum.reduce_while(:ok, fn {index, value}, :ok ->
      case EtherCAT.write_output(:outputs, channel_name(index), value) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {channel_name(index), reason}}}
      end
    end)
  end

  defp wait_for_match(expected, timeout_ms, poll_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_match(expected, deadline_ms, poll_ms, nil)
  end

  defp do_wait_for_match(expected, deadline_ms, poll_ms, last_observation) do
    observation = read_pattern()

    case observation do
      {:ok, ^expected, matched_at_us, values} ->
        {:ok, expected, matched_at_us, values}

      _other ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          {:error, observation || last_observation}
        else
          Process.sleep(poll_ms)
          do_wait_for_match(expected, deadline_ms, poll_ms, observation)
        end
    end
  end

  defp read_pattern do
    1..8
    |> Enum.reduce_while({:ok, []}, fn index, {:ok, values} ->
      case EtherCAT.read_input(:inputs, channel_name(index)) do
        {:ok, {value, updated_at_us}} when value in [0, 1] and is_integer(updated_at_us) ->
          {:cont, {:ok, [{index, value, updated_at_us} | values]}}

        {:ok, other} ->
          {:halt, {:error, {channel_name(index), {:unexpected_value, other}}}}

        {:error, reason} ->
          {:halt, {:error, {channel_name(index), reason}}}
      end
    end)
    |> case do
      {:ok, values} ->
        values = Enum.reverse(values)

        [b1, b2, b3, b4, b5, b6, b7, b8] =
          Enum.map(values, fn {_index, value, _updated_at_us} -> value end)

        <<byte::little-unsigned-integer-size(8)>> =
          <<b1::1, b2::1, b3::1, b4::1, b5::1, b6::1, b7::1, b8::1>>

        matched_at_us =
          Enum.max(Enum.map(values, fn {_index, _value, updated_at_us} -> updated_at_us end))

        {:ok, byte, matched_at_us, values}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp log_startup_summary(sink, opts) do
    {:ok, bus_info} = EtherCAT.Bus.info(EtherCAT.Bus)
    {:ok, domain_info} = EtherCAT.domain_info(:main)

    log(
      sink,
      :info,
      "attached to existing master circuit=#{inspect(bus_info.circuit)} topology=#{inspect(bus_info.topology)} " <>
        "cycle_time_us=#{domain_info.cycle_time_us} step_ms=#{opts.step_ms} " <>
        "match_timeout_ms=#{opts.match_timeout_ms} poll_ms=#{opts.poll_ms}"
    )

    :ok
  end

  defp log_step_ok(sink, step, expected, observed, values, latency_us) do
    snapshot = snapshot()

    log(
      sink,
      :app,
      "step=#{step} pattern=#{format_byte(expected)} observed=#{format_byte(observed)} " <>
        "latency_us=#{latency_us} inputs=#{format_values(values)} #{format_snapshot(snapshot)}"
    )
  end

  defp log_step_timeout(sink, step, expected, observation, timeout_ms) do
    snapshot = snapshot()

    detail =
      case observation do
        {:ok, observed, matched_at_us, values} ->
          "observed=#{format_byte(observed)} input_updated_at_us=#{matched_at_us} " <>
            "inputs=#{format_values(values)}"

        {:error, {channel, reason}} ->
          "read_error=#{inspect(channel)}:#{inspect(reason)}"

        nil ->
          "observed=none"
      end

    log(
      sink,
      :error,
      "timeout step=#{step} pattern=#{format_byte(expected)} timeout_ms=#{timeout_ms} " <>
        "#{detail} #{format_snapshot(snapshot)}"
    )
  end

  defp snapshot do
    master_state = EtherCAT.state()
    domain = EtherCAT.domain_info(:main)
    bus = EtherCAT.Bus.info(EtherCAT.Bus)

    %{
      master_state: unwrap_ok(master_state),
      domain: unwrap_ok(domain),
      bus: unwrap_ok(bus)
    }
  end

  defp unwrap_ok({:ok, value}), do: value
  defp unwrap_ok(other), do: other

  defp format_snapshot(%{master_state: master_state, domain: domain, bus: bus}) do
    state_part = "master=#{inspect(master_state)}"

    domain_part =
      case domain do
        %{cycle_count: cycle_count, miss_count: miss_count, total_miss_count: total_miss_count} =
            info ->
          "domain_cycle=#{cycle_count} miss=#{miss_count}/#{total_miss_count} " <>
            "cycle_health=#{inspect(Map.get(info, :cycle_health))}"

        other ->
          "domain=#{inspect(other)}"
      end

    bus_part =
      case bus do
        %{topology: topology} = info ->
          "topology=#{inspect(topology)} fault=#{inspect(Map.get(info, :fault))} " <>
            "last_error_reason=#{inspect(Map.get(info, :last_error_reason))}"

        other ->
          "bus=#{inspect(other)}"
      end

    "#{state_part} #{domain_part} #{bus_part}"
  end

  defp attach_telemetry(handler_id, sink) do
    :telemetry.attach_many(handler_id, @telemetry_events, &__MODULE__.handle_telemetry/4, sink)
  end

  defp start_sink(start_ms) do
    spawn_link(fn -> sink_loop(start_ms) end)
  end

  defp stop_sink(pid) when is_pid(pid) do
    send(pid, :stop)
  end

  defp sink_loop(start_ms) do
    receive do
      :stop ->
        :ok

      {:log, level, message} ->
        delta_ms = System.monotonic_time(:millisecond) - start_ms
        IO.puts("[t+#{delta_ms}ms] #{level} #{message}")
        sink_loop(start_ms)
    end
  end

  defp log(pid, level, message) do
    send(pid, {:log, level, message})
  end

  defp format_telemetry([:ethercat, :bus, :link, :down], _measurements, metadata) do
    "bus.link.down endpoint=#{metadata.endpoint} reason=#{inspect(metadata.reason)} link=#{inspect(metadata.link)}"
  end

  defp format_telemetry([:ethercat, :bus, :link, :reconnected], _measurements, metadata) do
    "bus.link.reconnected endpoint=#{metadata.endpoint} link=#{inspect(metadata.link)}"
  end

  defp format_telemetry([:ethercat, :master, :state, :changed], _measurements, metadata) do
    "master.state #{inspect(metadata.from)} -> #{inspect(metadata.to)} public=#{inspect(metadata.public_state)} target=#{inspect(metadata.runtime_target)}"
  end

  defp format_telemetry([:ethercat, :master, :slave_fault, :changed], _measurements, metadata) do
    "master.slave_fault slave=#{inspect(metadata.slave)} #{inspect(metadata.from)}/#{inspect(metadata.from_detail)} -> #{inspect(metadata.to)}/#{inspect(metadata.to_detail)}"
  end

  defp format_telemetry([:ethercat, :domain, :cycle, :invalid], measurements, metadata) do
    "domain.invalid domain=#{inspect(metadata.domain)} reason=#{inspect(metadata.reason)} expected_wkc=#{inspect(metadata.expected_wkc)} actual_wkc=#{inspect(metadata.actual_wkc)} total_invalid=#{measurements.total_invalid_count}"
  end

  defp format_telemetry([:ethercat, :domain, :cycle, :transport_miss], measurements, metadata) do
    "domain.transport_miss domain=#{inspect(metadata.domain)} reason=#{inspect(metadata.reason)} consecutive=#{measurements.consecutive_miss_count} total_invalid=#{measurements.total_invalid_count}"
  end

  defp format_telemetry([:ethercat, :slave, :down], _measurements, metadata) do
    "slave.down slave=#{inspect(metadata.slave)} station=0x#{Integer.to_string(metadata.station, 16)} reason=#{inspect(metadata.reason)}"
  end

  defp format_telemetry([:ethercat, :slave, :health, :fault], measurements, metadata) do
    "slave.health_fault slave=#{inspect(metadata.slave)} station=0x#{Integer.to_string(metadata.station, 16)} al_state=#{inspect(measurements.al_state)} error_code=#{inspect(measurements.error_code)}"
  end

  defp format_telemetry(event, measurements, metadata) do
    "#{Enum.join(Enum.map(event, &to_string/1), ".")} measurements=#{inspect(measurements)} metadata=#{inspect(metadata)}"
  end

  defp positive_option(nil, default, _flag), do: {:ok, default}

  defp positive_option(value, _default, _flag) when is_integer(value) and value > 0 do
    {:ok, value}
  end

  defp positive_option(_value, _default, flag), do: {:error, "#{flag} must be a positive integer"}

  defp optional_positive_option(nil, _flag), do: {:ok, nil}

  defp optional_positive_option(value, _flag) when is_integer(value) and value > 0 do
    {:ok, value}
  end

  defp optional_positive_option(_value, flag),
    do: {:error, "#{flag} must be a positive integer"}

  defp channel_name(index), do: String.to_atom("ch#{index}")

  defp channel_values(byte) do
    <<b1::1, b2::1, b3::1, b4::1, b5::1, b6::1, b7::1, b8::1>> =
      <<byte::little-unsigned-integer-size(8)>>

    [b1, b2, b3, b4, b5, b6, b7, b8]
  end

  defp format_byte(byte) when is_integer(byte) do
    hex =
      byte
      |> Integer.to_string(16)
      |> String.upcase()
      |> String.pad_leading(2, "0")

    "0x#{hex} ch1..8=#{inspect(channel_values(byte))}"
  end

  defp format_values(values) when is_list(values) do
    values
    |> Enum.map(fn {index, value, updated_at_us} ->
      "ch#{index}=#{value}@#{updated_at_us}"
    end)
    |> Enum.join(" ")
  end

  defp usage do
    """
    Usage:
      MIX_ENV=test mix run test/integration/hardware/scripts/redundant_replug_watch.exs -- [options]

    Options:
      --primary-interface IFACE  expected primary link name (default #{@default_primary_interface})
      --backup-interface IFACE   expected secondary link name (default #{@default_backup_interface})
      --step-ms N                application step period in ms (default #{@default_step_ms})
      --match-timeout-ms N       wait this long for input match (default #{@default_match_timeout_ms})
      --poll-ms N                input poll interval while waiting (default #{@default_poll_ms})
      --steps N                  stop after N steps (default: run forever)
      --help                     print this message
    """
  end
end

unless System.get_env("ETHERCAT_REPLUG_WATCH_NOAUTORUN") in ["1", "true"] do
  EtherCAT.HardwareScripts.RedundantReplugWatch.main(System.argv())
end
