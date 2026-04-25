defmodule EtherCAT.Scan do
  @moduledoc """
  One-shot backend scan that reports observed topology without starting the
  master runtime.

  `scan/1` is a standalone discovery path. It will refuse to probe a backend
  that is already owned by a live local master session, because scan assigns
  station addresses as part of discovery and is therefore not safe to run
  against an active runtime on the same backend.
  """

  alias EtherCAT.Backend
  alias EtherCAT.Bus
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.DC.Snapshot, as: DCSnapshot
  alias EtherCAT.Master
  alias EtherCAT.Master.Status, as: MasterStatus
  alias EtherCAT.Scan.Result
  alias EtherCAT.Slave.ESC.{Registers, SII}
  alias EtherCAT.Utils

  @base_station 0x1000

  @spec scan(Backend.input() | Backend.t()) :: {:ok, Result.t()} | {:error, term()}
  def scan(backend_spec) do
    with {:ok, backend} <- Backend.normalize(backend_spec),
         :ok <- ensure_backend_available(backend),
         {:ok, bus} <- Bus.start_link(Backend.to_bus_opts(backend)) do
      try do
        do_scan(bus, backend)
      after
        :gen_statem.stop(bus)
      end
    end
  end

  defp ensure_backend_available(backend) do
    case Master.status() do
      %MasterStatus{lifecycle: lifecycle} when lifecycle in [:stopped, :idle] ->
        :ok

      %MasterStatus{backend: active_backend} when is_struct(active_backend) ->
        if Backend.conflicts?(backend, active_backend) do
          {:error, {:backend_in_use, active_backend}}
        else
          :ok
        end

      %MasterStatus{} ->
        {:error, :master_running}

      {:error, reason} ->
        {:error, {:scan_unavailable, reason}}
    end
  end

  defp do_scan(bus, backend) do
    with {:ok, slave_count} <- read_slave_count(bus),
         :ok <- assign_stations(bus, slave_count) do
      {discovered_slaves, observed_faults} = discover_slaves(bus, slave_count)

      {:ok,
       %Result{
         backend: backend,
         topology: %{
           slave_count: slave_count,
           stations: Enum.map(discovered_slaves, & &1.station)
         },
         discovered_slaves: discovered_slaves,
         al_states: build_al_state_index(discovered_slaves),
         observed_faults: observed_faults
       }}
    end
  end

  defp read_slave_count(bus) do
    case Bus.transaction(bus, Transaction.brd(Registers.esc_type())) do
      {:ok, [%{wkc: count}]} when is_integer(count) and count >= 0 ->
        {:ok, count}

      {:ok, [%{wkc: wkc}]} ->
        {:error, {:scan_failed, {:unexpected_wkc, wkc}}}

      {:error, reason} ->
        {:error, {:scan_failed, reason}}
    end
  end

  defp assign_stations(_bus, 0), do: :ok

  defp assign_stations(bus, slave_count) do
    Enum.reduce_while(0..(slave_count - 1), :ok, fn position, :ok ->
      station = @base_station + position

      case Bus.transaction(bus, Transaction.apwr(position, Registers.station_address(station))) do
        {:ok, [%{wkc: 1}]} ->
          {:cont, :ok}

        {:ok, [%{wkc: wkc}]} ->
          {:halt, {:error, {:station_assign_failed, position, station, {:unexpected_wkc, wkc}}}}

        {:error, reason} ->
          {:halt, {:error, {:station_assign_failed, position, station, reason}}}
      end
    end)
  end

  defp discover_slaves(_bus, 0), do: {[], []}

  defp discover_slaves(bus, slave_count) do
    Enum.reduce(0..(slave_count - 1), {[], []}, fn position, {slaves, faults} ->
      station = @base_station + position
      {slave, slave_faults} = discover_slave(bus, position, station)
      {[slave | slaves], Enum.reverse(slave_faults) ++ faults}
    end)
    |> then(fn {slaves, faults} -> {Enum.reverse(slaves), Enum.reverse(faults)} end)
  end

  defp discover_slave(bus, position, station) do
    {dl_status, dl_faults} = read_dl_status(bus, station)
    {identity, identity_faults} = read_identity(bus, station)
    {al_status, al_faults} = read_al_status(bus, station)

    active_ports =
      case dl_status do
        value when is_binary(value) and byte_size(value) == 2 -> DCSnapshot.active_ports(value)
        _other -> []
      end

    slave = %{
      position: position,
      station: station,
      identity: identity,
      al_state: Map.get(al_status, :state),
      al_status_raw: Map.get(al_status, :raw),
      al_error?: Map.get(al_status, :error?),
      al_status_code: Map.get(al_status, :error_code),
      topology: %{
        dl_status: dl_status,
        active_ports: active_ports
      }
    }

    {slave, dl_faults ++ identity_faults ++ al_faults ++ al_fault_from_snapshot(slave)}
  end

  defp read_dl_status(bus, station) do
    case Bus.transaction(bus, Transaction.fprd(station, Registers.dl_status())) do
      {:ok, [%{data: dl_status, wkc: 1}]} when is_binary(dl_status) ->
        {dl_status, []}

      {:ok, [%{wkc: wkc}]} ->
        {nil, [%{kind: :dl_status_read_failed, station: station, reason: {:unexpected_wkc, wkc}}]}

      {:error, reason} ->
        {nil, [%{kind: :dl_status_read_failed, station: station, reason: reason}]}
    end
  end

  defp read_identity(bus, station) do
    case SII.read_identity(bus, station) do
      {:ok, identity} ->
        {identity, []}

      {:error, reason} ->
        {nil, [%{kind: :identity_read_failed, station: station, reason: reason}]}
    end
  end

  defp read_al_status(bus, station) do
    case Bus.transaction(bus, Transaction.fprd(station, Registers.al_status())) do
      {:ok, [%{data: al_bytes, wkc: 1}]} when is_binary(al_bytes) ->
        {al_status_raw, error?} = Registers.decode_al_status(al_bytes)

        status = %{
          raw: al_status_raw,
          state: Utils.al_state_atom(al_status_raw),
          error?: error?,
          error_code: if(error?, do: read_al_status_code(bus, station), else: nil)
        }

        {status, []}

      {:ok, [%{wkc: wkc}]} ->
        {%{raw: nil, state: nil, error?: nil, error_code: nil},
         [%{kind: :al_status_read_failed, station: station, reason: {:unexpected_wkc, wkc}}]}

      {:error, reason} ->
        {%{raw: nil, state: nil, error?: nil, error_code: nil},
         [%{kind: :al_status_read_failed, station: station, reason: reason}]}
    end
  end

  defp read_al_status_code(bus, station) do
    case Bus.transaction(bus, Transaction.fprd(station, Registers.al_status_code())) do
      {:ok, [%{data: <<code::16-little>>, wkc: 1}]} -> code
      _other -> nil
    end
  end

  defp build_al_state_index(discovered_slaves) do
    Map.new(discovered_slaves, fn slave ->
      {slave.station,
       %{
         state: slave.al_state,
         raw: slave.al_status_raw,
         error?: slave.al_error?,
         error_code: slave.al_status_code
       }}
    end)
  end

  defp al_fault_from_snapshot(%{station: station, al_error?: true} = slave) do
    [
      %{
        kind: :al_error,
        station: station,
        state: slave.al_state,
        raw: slave.al_status_raw,
        error_code: slave.al_status_code
      }
    ]
  end

  defp al_fault_from_snapshot(_slave), do: []
end
