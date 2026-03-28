defmodule Mix.Tasks.Ethercat.Capture do
  @moduledoc """
  Boot an interactive PREOP capture session against a live EtherCAT ring.

  Typical usage:

      iex -S mix ethercat.capture --interface eth0

  Optional UDP transport arguments are supported for simulator-backed sessions:

      iex -S mix ethercat.capture --transport udp --host 127.0.0.2 --bind-ip 127.0.0.1
  """

  use Mix.Task

  @shortdoc "Boot an interactive PREOP capture session"
  @requirements ["app.start"]

  @default_await_ms 10_000
  @default_scan_poll_ms 100
  @default_scan_stable_ms 1_000

  @impl true
  def run(args) do
    opts = parse_args!(args)

    ensure_session_available!()

    case EtherCAT.start(build_start_opts(opts)) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.raise("failed to start EtherCAT capture session: #{inspect(reason)}")
    end

    case EtherCAT.await_running(Keyword.fetch!(opts, :await_ms)) do
      :ok ->
        print_session_banner(opts)

      {:error, reason} ->
        _ = EtherCAT.stop()
        Mix.raise("capture session did not reach a usable PREOP state: #{inspect(reason)}")
    end
  end

  defp parse_args!(args) do
    {parsed, rest, invalid} =
      OptionParser.parse(
        args,
        strict: [
          interface: :string,
          transport: :string,
          host: :string,
          bind_ip: :string,
          port: :integer,
          await_ms: :integer,
          scan_poll_ms: :integer,
          scan_stable_ms: :integer,
          frame_timeout_ms: :integer
        ]
      )

    if rest != [] do
      Mix.raise("unexpected positional arguments: #{Enum.join(rest, " ")}")
    end

    if invalid != [] do
      Mix.raise("invalid capture options: #{inspect(invalid)}")
    end

    transport = parse_transport!(Keyword.get(parsed, :transport, "raw"))

    parsed
    |> Keyword.put(:transport, transport)
    |> Keyword.put_new(:await_ms, @default_await_ms)
    |> Keyword.put_new(:scan_poll_ms, @default_scan_poll_ms)
    |> Keyword.put_new(:scan_stable_ms, @default_scan_stable_ms)
    |> maybe_parse_ip(:host)
    |> maybe_parse_ip(:bind_ip)
  end

  defp parse_transport!("raw"), do: :raw
  defp parse_transport!("udp"), do: :udp

  defp parse_transport!(other),
    do: Mix.raise("unsupported transport #{inspect(other)}; use raw or udp")

  defp maybe_parse_ip(opts, key) do
    case Keyword.get(opts, key) do
      nil ->
        opts

      ip ->
        case :inet.parse_address(String.to_charlist(ip)) do
          {:ok, parsed_ip} ->
            Keyword.put(opts, key, parsed_ip)

          {:error, _reason} ->
            Mix.raise(
              "invalid IP for --#{key |> Atom.to_string() |> String.replace("_", "-")}: #{ip}"
            )
        end
    end
  end

  defp ensure_session_available! do
    case EtherCAT.state() do
      {:error, :not_started} ->
        :ok

      {:ok, :idle} ->
        :ok

      state ->
        Mix.raise(
          "EtherCAT session already running in state #{inspect(state)}; stop it before starting capture"
        )
    end
  end

  defp build_start_opts(opts) do
    start_opts = [
      dc: nil,
      domains: [],
      slaves: [],
      scan_poll_ms: Keyword.fetch!(opts, :scan_poll_ms),
      scan_stable_ms: Keyword.fetch!(opts, :scan_stable_ms)
    ]

    start_opts =
      case Keyword.get(opts, :frame_timeout_ms) do
        timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 ->
          Keyword.put(start_opts, :frame_timeout_ms, timeout_ms)

        _ ->
          start_opts
      end

    case Keyword.fetch!(opts, :transport) do
      :raw ->
        case Keyword.get(opts, :interface) do
          interface when is_binary(interface) ->
            Keyword.put(start_opts, :backend, {:raw, %{interface: interface}})

          _ ->
            Mix.raise("raw capture sessions require --interface")
        end

      :udp ->
        start_opts
        |> Keyword.put(:backend, udp_backend(opts))
    end
  end

  defp print_session_banner(opts) do
    Mix.shell().info("")
    Mix.shell().info("EtherCAT capture session ready")
    Mix.shell().info("State: #{inspect(EtherCAT.state())}")
    Mix.shell().info("Backend: #{backend_label(opts)}")

    case EtherCAT.Capture.list_slaves() do
      {:ok, slaves} ->
        Mix.shell().info("Discovered slaves:")

        Enum.each(slaves, fn slave ->
          Mix.shell().info(
            "  #{inspect(slave.name)} station=0x#{Integer.to_string(slave.station, 16)} al_state=#{inspect(Map.get(slave, :al_state))} coe=#{inspect(Map.get(slave, :coe))}"
          )
        end)

      {:error, reason} ->
        Mix.shell().info("Failed to list slaves: #{inspect(reason)}")
    end

    Mix.shell().info("")

    unless IEx.started?() do
      Mix.shell().info("This task is most useful under IEx:")
      Mix.shell().info("  iex -S mix ethercat.capture --interface eth0")
      Mix.shell().info("")
    end

    EtherCAT.Capture.help()
  end

  defp backend_label(opts) do
    case Keyword.fetch!(opts, :transport) do
      :raw ->
        Keyword.fetch!(opts, :interface)

      :udp ->
        host =
          case Keyword.get(opts, :host) do
            nil -> "255.255.255.255"
            ip -> :inet.ntoa(ip) |> List.to_string()
          end

        port = Keyword.get(opts, :port, 0x88A4)
        "#{host}:#{port}"
    end
  end

  defp udp_backend(opts) do
    host = Keyword.get(opts, :host, {255, 255, 255, 255})
    port = Keyword.get(opts, :port, 0x88A4)

    case Keyword.get(opts, :bind_ip) do
      nil ->
        {:udp, %{host: host, port: port}}

      bind_ip ->
        {:udp, %{host: host, bind_ip: bind_ip, port: port}}
    end
  end
end
