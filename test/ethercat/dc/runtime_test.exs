defmodule EtherCAT.DC.RuntimeTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Bus.Datagram
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.DC
  alias EtherCAT.DC.Config, as: DCConfig

  test "maintenance_transaction uses configured-address FRMW for dc system time" do
    station = 0x1002

    assert [%Datagram{cmd: 14, address: <<0x02, 0x10, 0x10, 0x09>>, data: <<0::64>>}] =
             station
             |> DC.maintenance_transaction()
             |> Transaction.datagrams()
  end

  test "decode_abs_sync_diff strips the sign bit from 0x092C" do
    assert 42 == DC.decode_abs_sync_diff(42)
    assert 42 == DC.decode_abs_sync_diff(0x8000_002A)
  end

  test "classify_lock uses the max observed sync diff against the threshold" do
    assert {:locked, 90} = DC.classify_lock([10, 90, 30], 100)
    assert {:locking, 101} = DC.classify_lock([10, 101, 30], 100)
    assert {:unavailable, nil} = DC.classify_lock([], 100)
  end

  test "init returns an explicit DC runtime struct" do
    bus = self()

    assert {:ok, :running,
            %DC{
              bus: ^bus,
              ref_station: 0x1000,
              config: %DCConfig{},
              monitored_stations: [0x1000],
              tick_interval_ms: 10_000,
              diagnostic_interval_cycles: 7,
              cycle_count: 0,
              fail_count: 0,
              lock_state: :locking,
              max_sync_diff_ns: nil,
              last_sync_check_at_ms: nil
            }} =
             DC.init(
               bus: bus,
               ref_station: 0x1000,
               monitored_stations: [0x1000],
               tick_interval_ms: 10_000,
               diagnostic_interval_cycles: 7,
               config: %DCConfig{}
             )
  end

  test "await_locked times out while lock state is still converging" do
    {:ok, pid} =
      start_supervised(
        {DC,
         bus: self(),
         ref_station: 0x1000,
         monitored_stations: [0x1000],
         tick_interval_ms: 10_000,
         config: %DCConfig{}}
      )

    assert {:error, :timeout} = DC.await_locked(pid, 10)
  end

  test "await_locked fails immediately when no monitorable stations exist" do
    {:ok, pid} =
      start_supervised(
        {DC,
         bus: self(),
         ref_station: 0x1000,
         monitored_stations: [],
         tick_interval_ms: 10_000,
         config: %DCConfig{}}
      )

    assert {:error, :dc_lock_unavailable} = DC.await_locked(pid, 10)
  end

  test "status exposes the configured activation and runtime lock contract" do
    {:ok, pid} =
      start_supervised(
        {DC,
         bus: self(),
         ref_station: 0x1000,
         monitored_stations: [0x1000],
         tick_interval_ms: 10_000,
         config: %DCConfig{
           cycle_ns: 1_000_000,
           await_lock?: true,
           lock_policy: :recovering
         }}
      )

    assert %DC.Status{
             configured?: true,
             active?: true,
             cycle_ns: 1_000_000,
             await_lock?: true,
             lock_policy: :recovering,
             reference_station: 0x1000,
             lock_state: :locking
           } = DC.status(pid)
  end
end
