defmodule EtherCAT.Master.Calls do
  @moduledoc false

  alias EtherCAT.DC
  alias EtherCAT.Domain
  alias EtherCAT.Master.Status

  @spec handle_active(term(), term(), atom(), %EtherCAT.Master{}) ::
          :gen_statem.event_handler_result(atom())
  def handle_active(from, :state, state, _data) do
    {:keep_state_and_data, [{:reply, from, state}]}
  end

  def handle_active(from, :last_failure, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.last_failure}]}
  end

  def handle_active(from, :dc_status, _state, data) do
    {:keep_state_and_data, [{:reply, from, Status.dc_status(data)}]}
  end

  def handle_active(from, :reference_clock, _state, data) do
    {:keep_state_and_data, [{:reply, from, Status.reference_clock_reply(Status.dc_status(data))}]}
  end

  def handle_active(from, :dc_runtime, _state, %{dc_config: nil}) do
    {:keep_state_and_data, [{:reply, from, {:error, :dc_disabled}}]}
  end

  def handle_active(from, :dc_runtime, _state, _data) do
    if dc_running?() do
      {:keep_state_and_data, [{:reply, from, {:ok, DC}}]}
    else
      {:keep_state_and_data, [{:reply, from, {:error, :dc_inactive}}]}
    end
  end

  def handle_active(from, :slaves, _state, data) do
    {:keep_state_and_data, [{:reply, from, Status.slaves(data)}]}
  end

  def handle_active(from, :domains, _state, data) do
    {:keep_state_and_data, [{:reply, from, Status.domains(data)}]}
  end

  def handle_active(from, :bus, _state, data) do
    {:keep_state_and_data, [{:reply, from, Status.bus_public_ref(data)}]}
  end

  def handle_active(from, {:update_domain_cycle_time, domain_id, cycle_time_us}, _state, data)
      when is_atom(domain_id) and is_integer(cycle_time_us) and cycle_time_us > 0 do
    case update_domain_cycle_time(data, domain_id, cycle_time_us) do
      :ok ->
        {:keep_state_and_data, [{:reply, from, :ok}]}

      {:error, :unknown_domain} ->
        {:keep_state_and_data, [{:reply, from, {:error, {:unknown_domain, domain_id}}}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_active(from, _event, state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, state}}]}
  end

  defp update_domain_cycle_time(%{domain_configs: domain_configs}, domain_id, cycle_time_us) do
    if Enum.any?(domain_configs || [], &(&1.id == domain_id)) do
      Domain.update_cycle_time(domain_id, cycle_time_us)
    else
      {:error, :unknown_domain}
    end
  end

  defp dc_running? do
    is_pid(Process.whereis(DC))
  end
end
