defmodule EtherCAT.Master.Diagnostics do
  @moduledoc false

  alias EtherCAT.{Bus, DC, Session, Utils}
  alias EtherCAT.DC.Status, as: DCStatus
  alias EtherCAT.Master.Status

  @observation_timeout_ms 1_000

  @type query :: :status | :dc_status | :reference_clock | :domains
  @type t :: %__MODULE__{status: Status.t(), bus: pid() | nil, dc: pid() | nil}
  defstruct [:status, :bus, :dc]

  # Capture identities while the master serializes the session. Collection must
  # use these pids, never resolve names again after the snapshot is returned.
  @spec capture(Status.lifecycle(), %EtherCAT.Master{}) :: t()
  def capture(lifecycle, data) do
    domains =
      Enum.map(data.domain_configs, fn config ->
        %{
          id: config.id,
          configured_cycle_time_us: config.cycle_time_us,
          logical_base: config.logical_base,
          pid: lookup_domain_pid(config.id),
          live_cycle_time_us: nil
        }
      end)

    %__MODULE__{
      status:
        Status.from_runtime(lifecycle, data, %{
          dc_status: configured_dc_status(data),
          bus_status: nil,
          configured_domains: domains,
          configured_slaves: configured_slaves(data)
        }),
      bus: Process.whereis(Bus),
      dc: Process.whereis(DC)
    }
  end

  @spec query(Session.t(), query()) :: {:ok, term()} | {:error, term()}
  def query(session, query) do
    with {:ok, snapshot} <- Session.call(session, :diagnostic_snapshot) do
      result = collect(snapshot, query)

      # A stopped/replaced session invalidates even a successful observation.
      with {:ok, _generation} <- Session.call(session, :session_identity) do
        result
      end
    end
  end

  @spec collect(t(), query()) :: {:ok, term()} | {:error, term()}
  def collect(snapshot, query) do
    deadline = System.monotonic_time(:millisecond) + @observation_timeout_ms
    collect(snapshot, query, deadline)
  end

  defp collect(snapshot, :status, deadline) do
    with {:ok, dc} <- read_dc(snapshot, deadline),
         {:ok, bus} <- read_bus(snapshot.bus, deadline),
         {:ok, domains} <- read_domains(snapshot.status.configured_domains, deadline) do
      reference_clock =
        case Status.reference_clock_reply(dc) do
          {:ok, clock} -> clock
          {:error, _reason} -> nil
        end

      {:ok,
       %{
         snapshot.status
         | dc_status: dc,
           bus_status: bus,
           configured_domains: domains,
           reference_clock: reference_clock
       }}
    end
  end

  defp collect(snapshot, :dc_status, deadline), do: read_dc(snapshot, deadline)

  defp collect(snapshot, :reference_clock, deadline) do
    with {:ok, dc} <- read_dc(snapshot, deadline) do
      Status.reference_clock_reply(dc)
    end
  end

  defp collect(snapshot, :domains, deadline) do
    with {:ok, domains} <- read_domains(snapshot.status.configured_domains, deadline) do
      live =
        for domain <- domains,
            is_pid(domain.pid),
            do: {domain.id, domain.live_cycle_time_us, domain.pid}

      {:ok, live}
    end
  end

  defp read_dc(%{status: %{dc_status: %{configured?: false} = dc}}, _deadline), do: {:ok, dc}
  defp read_dc(%{dc: nil, status: %{dc_status: dc}}, _deadline), do: {:ok, dc}

  defp read_dc(snapshot, deadline) do
    with {:ok, dc} <- observe(snapshot.dc, :status, :dc, deadline) do
      {:ok, %{dc | reference_clock: snapshot.status.dc_status.reference_clock}}
    end
  end

  defp read_bus(nil, _deadline), do: {:ok, nil}
  defp read_bus(pid, deadline), do: observe(pid, :info, :bus, deadline)

  defp read_domains(domains, deadline) do
    Enum.reduce_while(domains, {:ok, []}, fn
      %{pid: nil} = domain, {:ok, acc} ->
        {:cont, {:ok, [domain | acc]}}

      domain, {:ok, acc} ->
        case observe(domain.pid, :info, {:domain, domain.id}, deadline) do
          {:ok, %{cycle_time_us: cycle_time_us}}
          when is_integer(cycle_time_us) and cycle_time_us > 0 ->
            {:cont, {:ok, [%{domain | live_cycle_time_us: cycle_time_us} | acc]}}

          {:ok, _reply} ->
            {:halt, unavailable({:domain, domain.id}, :invalid_reply)}

          {:error, _reason} = error ->
            {:halt, error}
        end
    end)
    |> reverse_domains()
  end

  defp reverse_domains({:ok, domains}), do: {:ok, Enum.reverse(domains)}
  defp reverse_domains({:error, _reason} = error), do: error

  defp observe(pid, message, source, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      case {message, Utils.statem_call(pid, message, :not_running, remaining)} do
        {:status, %DCStatus{} = status} -> {:ok, status}
        {:info, {:ok, info}} when is_map(info) -> {:ok, info}
        {_message, {:error, reason}} -> unavailable(source, reason)
        _reply -> unavailable(source, :invalid_reply)
      end
    else
      unavailable(source, :timeout)
    end
  end

  defp unavailable(source, reason), do: {:error, {:diagnostic_unavailable, source, reason}}

  defp configured_dc_status(%{dc_config: nil}), do: %DCStatus{lock_state: :disabled}

  defp configured_dc_status(data) do
    %DCStatus{
      configured?: true,
      active?: false,
      cycle_ns: data.dc_config.cycle_ns,
      await_lock?: data.dc_config.await_lock?,
      lock_policy: data.dc_config.lock_policy,
      reference_station: data.dc_ref_station,
      reference_clock: reference_clock_name(data),
      lock_state: :inactive
    }
  end

  @spec slaves(%EtherCAT.Master{}) ::
          [
            %{
              name: atom(),
              station: non_neg_integer(),
              server: :gen_statem.server_ref(),
              pid: pid() | nil,
              fault: term() | nil
            }
          ]
  def slaves(data) do
    Enum.map(data.slaves, fn {name, station} ->
      %{
        name: name,
        station: station,
        server: slave_server(name),
        pid: lookup_slave_pid(name),
        fault: Map.get(data.slave_faults, name)
      }
    end)
  end

  @spec configured_slaves(%EtherCAT.Master{}) :: [Status.configured_slave()]
  def configured_slaves(data) do
    station_by_name = Map.new(data.slaves)

    Enum.map(data.slave_configs, fn config ->
      %{
        name: config.name,
        station: Map.get(station_by_name, config.name),
        server: slave_server(config.name),
        pid: lookup_slave_pid(config.name),
        driver: config.driver,
        config: config.config,
        target_state: config.target_state,
        process_data: config.process_data,
        health_poll_ms: config.health_poll_ms,
        fault: Map.get(data.slave_faults, config.name)
      }
    end)
  end

  defp reference_clock_name(%{dc_ref_station: nil}), do: nil

  defp reference_clock_name(data) do
    case Enum.find(data.slaves, fn {_name, station} ->
           station == data.dc_ref_station
         end) do
      {name, _station} -> name
      nil -> nil
    end
  end

  defp lookup_slave_pid(name) do
    case Registry.lookup(EtherCAT.Registry, {:slave, name}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp slave_server(name), do: {:via, Registry, {EtherCAT.Registry, {:slave, name}}}

  defp lookup_domain_pid(id) do
    case Registry.lookup(EtherCAT.Registry, {:domain, id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
