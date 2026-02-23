defmodule Examples.IoQuick do
  @moduledoc false

  import Bitwise

  alias Ethercat.Protocol.{Datagram, Transport}

  def main(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        switches: [
          interface: :string,
          cycles: :integer,
          period_ms: :integer,
          out0: :integer,
          out1: :integer,
          in0: :integer,
          hold_cycles: :integer,
          count_only: :boolean,
          dump_sm: :boolean,
          verbose: :boolean,
          physical: :boolean
        ]
      )

    interface = Keyword.get(opts, :interface) || usage()

    cycles = Keyword.get(opts, :cycles, 200)
    period_ms = Keyword.get(opts, :period_ms, 10)
    hold_cycles = Keyword.get(opts, :hold_cycles, 50)

    out0 = Keyword.get(opts, :out0, 0x0F00)
    out1 = Keyword.get(opts, :out1, 0x0F01)
    in0 = Keyword.get(opts, :in0, 0x1000)

    {:ok, pid} = Transport.start_link(interface: interface)

    {:ok, stations} = assign_station_addresses(pid)
    IO.puts("Stations: #{inspect(stations)}")

    if Keyword.get(opts, :count_only, false) do
      :ok
    else
      :ok = configure_known_sms(pid, stations)
      :ok = configure_known_fmmus(pid, stations)

      if Keyword.get(opts, :dump_sm, false) do
        dump_sync_managers(pid, Map.fetch!(stations, 2))
      end

      :ok = transition_all(pid, stations, :safeop)
      :ok = transition_all(pid, stations, :op)

      verbose = Keyword.get(opts, :verbose, false)
      physical? = Keyword.get(opts, :physical, false)

      run_cycles(
        pid,
        stations,
        cycles,
        period_ms,
        hold_cycles,
        out0,
        out1,
        in0,
        verbose,
        physical?
      )
    end
  end

  defp usage do
    IO.puts("Usage: mix run --no-start examples/io_quick.exs --interface enp0s31f6")
    System.halt(1)
  end

  defp dump_sync_managers(pid, station) do
    {:ok, [sm0, sm1]} =
      Transport.transact(
        pid,
        [
          Datagram.fprd(station, 0x0800, 8),
          Datagram.fprd(station, 0x0808, 8)
        ],
        200_000
      )

    IO.puts("SM0 raw: #{inspect(sm0.data)}")
    IO.puts("SM1 raw: #{inspect(sm1.data)}")
    :ok
  end

  defp configure_known_sms(pid, stations) do
    in_station = Map.fetch!(stations, 1)
    out_station = Map.fetch!(stations, 2)

    # These values are based on the PDO/SM dump you provided.
    sm_in0 = sm_page(0x1000, 2, 0x20, 1)
    sm_out0 = sm_page(0x0F00, 1, 0x44, 1)
    sm_out1 = sm_page(0x0F01, 1, 0x44, 1)

    {:ok, _} = Transport.transact(pid, [Datagram.fpwr(in_station, 0x0800, sm_in0)], 200_000)

    {:ok, _} =
      Transport.transact(
        pid,
        [
          Datagram.fpwr(out_station, 0x0800, sm_out0),
          Datagram.fpwr(out_station, 0x0808, sm_out1)
        ],
        200_000
      )

    :ok
  end

  defp sm_page(start_addr, length, control, enable) do
    activate = if enable == 1, do: 0x01, else: 0x00
    <<start_addr::16-little, length::16-little, control::8, 0::8, activate::8, 0::8>>
  end

  defp assign_station_addresses(pid) do
    {:ok, [%{working_counter: count}]} =
      Transport.transact(pid, [Datagram.brd(0x0000, 1)], 200_000)

    stations =
      for pos <- 0..(count - 1) do
        station = 0x1000 + pos
        adp = -pos

        {:ok, _} =
          Transport.transact(
            pid,
            [Datagram.apwr(adp, 0x0010, <<station::16-little>>)],
            200_000
          )

        {pos, station}
      end

    {:ok, Map.new(stations)}
  end

  defp transition_all(pid, stations, target) do
    stations
    |> Enum.sort_by(fn {pos, _} -> pos end)
    |> Enum.reduce_while(:ok, fn {_pos, station}, :ok ->
      case transition(pid, station, target) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {station, reason}}}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, _} = err -> raise "AL transition failed: #{inspect(err)}"
    end
  end

  defp transition(pid, station, target) when target in [:safeop, :op] do
    request = if target == :safeop, do: 0x0004, else: 0x0008

    with {:ok, _} <-
           Transport.transact(
             pid,
             [Datagram.fpwr(station, 0x0120, <<request::16-little>>)],
             200_000
           ),
         :ok <- wait_al(pid, station, request, 200) do
      :ok
    end
  end

  defp wait_al(_pid, _station, _request, 0), do: {:error, :al_timeout}

  defp wait_al(pid, station, request, attempts) do
    case Transport.transact(pid, [Datagram.fprd(station, 0x0130, 2)], 200_000) do
      {:ok, [%{data: <<status::16-little>>}]} ->
        if (status &&& 0x000F) == request do
          :ok
        else
          :timer.sleep(5)
          wait_al(pid, station, request, attempts - 1)
        end

      _ ->
        :timer.sleep(5)
        wait_al(pid, station, request, attempts - 1)
    end
  end

  defp run_cycles(
         pid,
         stations,
         cycles,
         period_ms,
         hold_cycles,
         out0,
         out1,
         in0,
         verbose,
         physical?
       ) do
    in_station = Map.fetch!(stations, 1)
    out_station = Map.fetch!(stations, 2)

    IO.puts(
      "Using in_station=#{in_station} out_station=#{out_station} out=#{Integer.to_string(out0, 16)}/#{Integer.to_string(out1, 16)} in=#{Integer.to_string(in0, 16)}"
    )

    IO.puts("Mode: #{if(physical?, do: "physical FPRW/FPRD", else: "logical LWR/LRD")}")

    loop(
      pid,
      in_station,
      out_station,
      cycles,
      period_ms,
      hold_cycles,
      out0,
      out1,
      in0,
      verbose,
      physical?,
      0,
      nil,
      0
    )
  end

  defp loop(
         _pid,
         _in_station,
         _out_station,
         cycles,
         _period_ms,
         _hold_cycles,
         _out0,
         _out1,
         _in0,
         _verbose,
         _physical?,
         step,
         _last,
         _timeouts
       )
       when step >= cycles do
    IO.puts("Done")
    :ok
  end

  defp loop(
         pid,
         in_station,
         out_station,
         cycles,
         period_ms,
         hold_cycles,
         out0,
         out1,
         in0,
         verbose,
         physical?,
         step,
         last_inputs,
         timeouts
       ) do
    phase = div(step, hold_cycles)
    on? = rem(phase, 2) == 0

    out_word = if on?, do: 0xFFFF, else: 0x0000
    low = <<band(out_word, 0xFF)::8>>
    high = <<band(out_word >>> 8, 0xFF)::8>>

    result =
      if physical? do
        Transport.transact(
          pid,
          [
            Datagram.fprw(out_station, out0, low),
            Datagram.fprw(out_station, out1, high),
            Datagram.fprd(in_station, in0, 2)
          ],
          50_000
        )
      else
        Transport.transact(
          pid,
          [
            Datagram.lwr(0x0000, 2, <<low::binary, high::binary>>),
            Datagram.lrd(0x0010, 2)
          ],
          50_000
        )
      end

    {last_inputs, timeouts} =
      case result do
        {:ok, resp} ->
          {out0_resp, out1_resp, inputs} =
            if physical? do
              out0_resp = Enum.at(resp, 0)
              out1_resp = Enum.at(resp, 1)
              %{data: <<inputs::16-little>>} = Enum.at(resp, 2)
              {out0_resp, out1_resp, inputs}
            else
              out_resp = Enum.at(resp, 0)
              in_resp = Enum.at(resp, 1)
              %{data: <<inputs::16-little>>} = in_resp
              {out_resp, out_resp, inputs}
            end

          timeouts = 0

          if verbose and step < 10 do
            IO.puts(
              "step=#{step} wkc=#{out0_resp.working_counter}/#{out1_resp.working_counter} out_rb=#{inspect(out0_resp.data)}/#{inspect(out1_resp.data)}"
            )
          end

          if last_inputs != inputs or rem(step, 50) == 0 do
            IO.puts(
              "step=#{step} out=#{if(on?, do: "on", else: "off")} inputs=0x#{hex16(inputs)}"
            )
          end

          {inputs, timeouts}

        {:error, :timeout} ->
          timeouts = timeouts + 1
          IO.puts("step=#{step} timeout (#{timeouts})")
          {last_inputs, timeouts}

        {:error, reason} ->
          IO.puts("step=#{step} error=#{inspect(reason)}")
          {last_inputs, timeouts}
      end

    if timeouts >= 10 do
      raise "too many timeouts"
    end

    :timer.sleep(period_ms)

    loop(
      pid,
      in_station,
      out_station,
      cycles,
      period_ms,
      hold_cycles,
      out0,
      out1,
      in0,
      verbose,
      physical?,
      step + 1,
      last_inputs,
      timeouts
    )
  end

  defp configure_known_fmmus(pid, stations) do
    in_station = Map.fetch!(stations, 1)
    out_station = Map.fetch!(stations, 2)

    # Out slave: map logical 0x0000..0x0001 -> physical 0x0F00..0x0F01 (write)
    out_fmmu0 = fmmu_page(0x0000, 2, 0x0F00, :write)
    # In slave: map logical 0x0010..0x0011 -> physical 0x1000..0x1001 (read)
    in_fmmu0 = fmmu_page(0x0010, 2, 0x1000, :read)

    {:ok, _} = Transport.transact(pid, [Datagram.fpwr(out_station, 0x0600, out_fmmu0)], 200_000)
    {:ok, _} = Transport.transact(pid, [Datagram.fpwr(in_station, 0x0600, in_fmmu0)], 200_000)

    :ok
  end

  defp fmmu_page(logical_start, size_bytes, physical_start, dir) do
    type =
      case dir do
        :read -> 0x01
        :write -> 0x02
        :read_write -> 0x03
      end

    <<
      logical_start::32-little,
      size_bytes::16-little,
      0::8,
      7::8,
      physical_start::16-little,
      0::8,
      type::8,
      0x01::8,
      0::24
    >>
  end

  defp hex16(int) do
    int
    |> Integer.to_string(16)
    |> String.pad_leading(4, "0")
  end
end

Examples.IoQuick.main(System.argv())
