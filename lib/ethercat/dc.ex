defmodule EtherCAT.DC do
  @moduledoc """
  Distributed Clocks — clock initialization and ongoing drift maintenance.

  ## Initialization

  `DC.init/2` performs the one-time clock synchronization sequence described in
  §9.1.3.6 of the ESC datasheet:

  1. Trigger receive-time latch on all slaves (BWR to 0x0900).
  2. Read per-port receive times from every slave.
  3. Identify the reference clock (first DC-capable slave).
  4. Calculate propagation delays and write to each slave.
  5. Write system time offset to align each slave to master time.
  6. Reset PLL filters (write speed counter start).
  7. Pre-compensate static drift with 1,000 ARMW frames.

  ## Drift maintenance

  After `start_link/1`, the gen_statem sends one ARMW datagram to the system
  time register (0x0910) of the reference clock every `period_ms` milliseconds.
  The EtherCAT frame passes through each slave in order — the reference clock's
  system time is read and written to every subsequent slave in a single pass,
  keeping all clocks aligned.

  ## SYNC0 configuration

  `configure_sync0/5` writes the SYNC0 start time, cycle time, pulse length,
  and activation register to a single slave. Called by Master for each slave
  whose driver profile includes a `dc:` key.
  """

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.Link
  alias EtherCAT.Link.Transaction
  alias EtherCAT.Slave.Registers

  # ns between Unix epoch (1970) and EtherCAT epoch (2000-01-01 00:00:00)
  @ethercat_epoch_offset_ns 946_684_800_000_000_000

  # Number of ARMW frames sent during static pre-compensation.
  # Each frame is a sequential Link.transaction call (~BEAM scheduling overhead),
  # so 1_000 is a practical ceiling. The ESC PLL filter converges any remaining
  # drift within the first second of cyclic ARMW maintenance.
  @precomp_frames 1_000

  # -- Public API ------------------------------------------------------------

  @doc """
  One-time DC initialization. Must be called after `assign_stations` and before
  `start_slaves`.

  `slave_stations` is a list of `{station, dl_status_binary}` tuples — one per
  slave, in bus order. DL status is a 2-byte little-endian value from register
  0x0110, used to determine which ports are open (topology).

  Returns `{:ok, ref_station}` where `ref_station` is the station address of
  the reference clock slave, or `{:error, reason}`.
  """
  @spec init(Link.server(), [{non_neg_integer(), binary()}]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def init(link, slave_stations) when slave_stations != [] do
    stations = Enum.map(slave_stations, &elem(&1, 0))

    # Step 1: trigger receive-time latch on all slaves
    with :ok <- trigger_recv_latch(link),
         # Step 2: read receive times from every slave
         {:ok, recv_times} <- read_recv_times(link, stations),
         # Step 3: identify reference clock
         {:ok, ref_idx} <- find_ref_clock(recv_times),
         ref_station = Enum.at(stations, ref_idx) do
      Logger.debug("[DC] reference clock at station 0x#{Integer.to_string(ref_station, 16)}")

      # Step 4: calculate propagation delays and write to each slave
      delays = calc_delays(recv_times, slave_stations)
      write_delays(link, stations, delays)

      # Step 5: write system time offsets
      master_ns = System.os_time(:nanosecond) - @ethercat_epoch_offset_ns
      {ref_ecat_ns, _, _} = Enum.at(recv_times, ref_idx)
      write_offsets(link, stations, recv_times, ref_idx, ref_ecat_ns, master_ns)

      # Step 6: reset PLL filters on all DC-capable slaves
      reset_filters(link, stations, recv_times)

      # Step 7: static drift pre-compensation is done by the DC gen_statem
      # on startup so it runs concurrently with slave init and SII reads.
      {:ok, ref_station}
    end
  end

  def init(_link, []), do: {:error, :no_slaves}

  @doc """
  Configure SYNC0 on a single slave. Called by Master for each slave whose
  driver profile has a `dc:` key.

  - `system_time_ns` — current DC system time in ns (master time - epoch offset)
  - `cycle_ns` — SYNC0 period in ns (= domain period)
  - `pulse_ns` — SYNC0 pulse width in ns (hardware-specific, from driver profile)
  """
  @spec configure_sync0(
          Link.server(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: :ok
  def configure_sync0(link, station, system_time_ns, cycle_ns, pulse_ns) do
    start_time = system_time_ns + 100_000

    fpwr(link, station, Registers.dc_sync0_cycle_time(), <<cycle_ns::32-little>>)
    fpwr(link, station, Registers.dc_pulse_length(), <<pulse_ns::16-little>>)
    fpwr(link, station, Registers.dc_sync0_start_time(), <<start_time::64-little>>)
    fpwr(link, station, Registers.dc_activation(), <<0x03>>)
    :ok
  end

  # -- child_spec / start_link -----------------------------------------------

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5000
    }
  end

  @doc """
  Start the DC drift maintenance gen_statem.

  Options:
    - `:link` (required) — Link server reference
    - `:ref_station` (required) — station address of the reference clock
    - `:period_ms` — drift correction interval, default 10 ms
  """
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    :gen_statem.start_link({:local, __MODULE__}, __MODULE__, opts, [])
  end

  # -- :gen_statem callbacks -------------------------------------------------

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(opts) do
    link = Keyword.fetch!(opts, :link)
    ref_station = Keyword.fetch!(opts, :ref_station)
    period_ms = Keyword.get(opts, :period_ms, 10)

    data = %{link: link, ref_station: ref_station, period_ms: period_ms, fail_count: 0}

    # Pre-compensation runs in this process so it doesn't block Master
    # (and therefore doesn't block slave SII reads running concurrently).
    precompensate(link, ref_station)

    {:ok, :running, data}
  end

  @impl true
  def handle_event(:enter, _old, :running, data) do
    {:keep_state_and_data, [{:state_timeout, data.period_ms, :tick}]}
  end

  def handle_event(:enter, _old, :stopped, _data), do: :keep_state_and_data

  def handle_event(:state_timeout, :tick, :running, data) do
    result =
      Link.transaction(
        data.link,
        &Transaction.armw(&1, data.ref_station, 0x0910, <<0::64>>)
      )

    new_data =
      case result do
        {:ok, [%{wkc: wkc}]} ->
          if data.fail_count > 0 do
            Logger.info("[DC] drift tick recovered after #{data.fail_count} failure(s)")
          end

          :telemetry.execute(
            [:ethercat, :dc, :tick],
            %{wkc: wkc},
            %{ref_station: data.ref_station}
          )

          %{data | fail_count: 0}

        {:error, reason} ->
          n = data.fail_count + 1

          if n == 1 or rem(n, 100) == 0 do
            Logger.warning("[DC] drift tick failed: #{inspect(reason)} (#{n} consecutive)")
          end

          %{data | fail_count: n}
      end

    {:keep_state, new_data, [{:state_timeout, data.period_ms, :tick}]}
  end

  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  # -- Init helpers ----------------------------------------------------------

  defp trigger_recv_latch(link) do
    # BWR to 0x0900 — all slaves latch local time on all ports simultaneously
    case Link.transaction(link, &Transaction.bwr(&1, 0x0900, <<0::32>>)) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp read_recv_times(link, stations) do
    results =
      Enum.map(stations, fn station ->
        ecat =
          case Link.transaction(link, &Transaction.fprd(&1, station, 0x0918, 8)) do
            {:ok, [%{data: <<t::64-little>>, wkc: 1}]} -> t
            _ -> nil
          end

        p0 =
          case Link.transaction(link, &Transaction.fprd(&1, station, 0x0900, 4)) do
            {:ok, [%{data: <<t::32-little>>, wkc: 1}]} -> t
            _ -> nil
          end

        p1 =
          case Link.transaction(link, &Transaction.fprd(&1, station, 0x0904, 4)) do
            {:ok, [%{data: <<t::32-little>>, wkc: 1}]} -> t
            _ -> nil
          end

        {ecat, p0, p1}
      end)

    {:ok, results}
  end

  # Reference clock = first slave with a valid ECAT receive time (wkc > 0)
  defp find_ref_clock(recv_times) do
    case Enum.find_index(recv_times, fn {ecat, _, _} -> ecat != nil end) do
      nil -> {:error, :no_dc_capable_slave}
      idx -> {:ok, idx}
    end
  end

  # Linear-chain propagation delay calculation.
  # For a simple chain: delay between adjacent slaves = (port1_time - port0_time) / 2.
  # Cumulative delay to each slave is the sum of hop delays up to that point.
  defp calc_delays(recv_times, _slave_stations) do
    recv_times
    |> Enum.reduce({[], 0}, fn {_ecat, p0, p1}, {acc, cumulative} ->
      hop_delay =
        if p0 != nil and p1 != nil do
          diff = p1 - p0
          # Handle 32-bit overflow
          diff = if diff < 0, do: diff + 0x100_000_000, else: diff
          div(diff, 2)
        else
          0
        end

      {[cumulative + hop_delay | acc], cumulative + hop_delay}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp write_delays(link, stations, delays) do
    Enum.zip(stations, delays)
    |> Enum.each(fn {station, delay} ->
      fpwr(link, station, Registers.dc_system_time_delay(), <<delay::32-little>>)
    end)
  end

  defp write_offsets(link, stations, recv_times, ref_idx, ref_ecat_ns, master_ns) do
    ref_offset = master_ns - ref_ecat_ns

    Enum.zip(stations, recv_times)
    |> Enum.with_index()
    |> Enum.each(fn {{station, {ecat_ns, _, _}}, idx} ->
      if ecat_ns != nil do
        offset =
          if idx == ref_idx do
            ref_offset
          else
            ref_ecat_ns - ecat_ns + ref_offset
          end

        fpwr(link, station, Registers.dc_system_time_offset(), <<offset::64-signed-little>>)
      end
    end)
  end

  defp reset_filters(link, stations, recv_times) do
    Enum.zip(stations, recv_times)
    |> Enum.each(fn {station, {ecat_ns, _, _}} ->
      if ecat_ns != nil do
        # Read current value and write it back — this resets the filter
        case Link.transaction(link, &Transaction.fprd(&1, station, 0x0930, 2)) do
          {:ok, [%{data: val, wkc: 1}]} ->
            fpwr(link, station, Registers.dc_speed_counter_start(), val)

          _ ->
            fpwr(link, station, Registers.dc_speed_counter_start(), <<0x1000::16-little>>)
        end
      end
    end)
  end

  defp precompensate(link, ref_station) do
    Logger.info("[DC] pre-compensating drift (#{@precomp_frames} frames)...")

    for _ <- 1..@precomp_frames do
      Link.transaction(link, &Transaction.armw(&1, ref_station, 0x0910, <<0::64>>))
    end

    Logger.info("[DC] pre-compensation done")
  end

  # Thin wrapper — ignore wkc for init writes (slaves may not all respond)
  defp fpwr(link, station, {addr, _size}, data) do
    Link.transaction(link, &Transaction.fpwr(&1, station, addr, data))
  end
end
