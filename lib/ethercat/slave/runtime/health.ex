defmodule EtherCAT.Slave.Runtime.Health do
  @moduledoc false

  require Logger

  alias EtherCAT.Bus
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.Slave
  alias EtherCAT.Slave.ESC.{Registers, SII}
  alias EtherCAT.Utils

  @type opts :: [
          transition_to: (%Slave{}, atom() -> {:ok, %Slave{}} | {:error, term(), %Slave{}}),
          op_code: non_neg_integer(),
          initialize_to_preop: (%Slave{} -> {:ok, atom(), %Slave{}, list()})
        ]

  @spec poll_op(%Slave{}, opts()) ::
          {:keep_state_and_data, list()}
          | {:keep_state, %Slave{}, list()}
          | {:next_state, atom(), %Slave{}}
  def poll_op(data, opts) do
    transition_to = Keyword.fetch!(opts, :transition_to)
    op_code = Keyword.fetch!(opts, :op_code)
    deadline_us = data.health_poll_ms * 500

    case Bus.transaction(
           data.bus,
           Transaction.fprd(data.station, Registers.al_status()),
           deadline_us
         ) do
      {:ok, [%{data: al_bytes, wkc: wkc}]} when wkc > 0 ->
        {al_state, error_ind} = Registers.decode_al_status(al_bytes)

        if al_state != op_code or error_ind do
          error_code = read_error_code(data, deadline_us)
          EtherCAT.Telemetry.slave_health_fault(data.name, data.station, al_state, error_code)

          Logger.warning(
            "[Slave #{data.name}] AL fault detected: state=0x#{Integer.to_string(al_state, 16)} code=0x#{Integer.to_string(error_code, 16)} — retreating to safeop",
            component: :slave,
            slave: data.name,
            station: data.station,
            event: :health_fault,
            al_state: al_state,
            error_code: error_code
          )

          case transition_to.(data, :safeop) do
            {:ok, new_data} ->
              send(EtherCAT.Master, {:slave_retreated, data.name, :safeop})
              {:next_state, :safeop, new_data}

            {:error, reason, _new_data} ->
              report_down(
                data,
                {:safeop_retreat_failed, reason},
                "safeop retreat failed: #{inspect(reason)}"
              )
          end
        else
          {:keep_state_and_data, [health_poll_action(data.health_poll_ms)]}
        end

      {:ok, [%{wkc: 0}]} ->
        report_down(data, :no_response, "wkc=0")

      {:error, reason} ->
        report_down(data, reason, "bus error #{inspect(reason)}")
    end
  end

  @spec poll_preop(%Slave{}) ::
          {:keep_state_and_data, list()} | {:next_state, atom(), %Slave{}}
  def poll_preop(data) do
    poll_held_state(data, :preop)
  end

  @spec poll_safeop(%Slave{}) ::
          {:keep_state_and_data, list()} | {:next_state, atom(), %Slave{}}
  def poll_safeop(data) do
    poll_held_state(data, :safeop)
  end

  defp poll_held_state(data, expected_state) do
    deadline_us = data.health_poll_ms * 500
    expected_code = al_state_code(expected_state)

    case Bus.transaction(
           data.bus,
           Transaction.fprd(data.station, Registers.al_status()),
           deadline_us
         ) do
      {:ok, [%{data: al_bytes, wkc: wkc}]} when wkc > 0 ->
        {al_state, error_ind} = Registers.decode_al_status(al_bytes)
        actual_state = Utils.al_state_atom(al_state)

        cond do
          al_state == expected_code and not error_ind ->
            {:keep_state_and_data, [health_poll_action(data.health_poll_ms)]}

          lower_than_expected?(actual_state, expected_state) ->
            report_retreated_state(
              data,
              expected_state,
              actual_state,
              al_state,
              error_ind,
              deadline_us
            )

          true ->
            {:keep_state_and_data, [health_poll_action(data.health_poll_ms)]}
        end

      {:ok, [%{wkc: 0}]} ->
        report_down(data, :no_response, "wkc=0")

      {:error, reason} ->
        report_down(data, reason, "bus error #{inspect(reason)}")
    end
  end

  @spec probe_reconnect(%Slave{}, opts()) ::
          {:keep_state_and_data, list()} | {:next_state, atom(), %Slave{}, list()}
  def probe_reconnect(data, opts) do
    initialize_to_preop = Keyword.fetch!(opts, :initialize_to_preop)

    case reconnect_probe(data) do
      {:ok, restored_data, mode} ->
        log_reconnect_probe_success(restored_data, mode)
        rebuild_to_preop(restored_data, initialize_to_preop)

      {:error, {:position_station_mismatch, station}} ->
        Logger.debug(
          "[Slave #{data.name}] reconnect probe found station 0x#{Integer.to_string(station, 16)} at position #{data.position}; waiting for configured device",
          component: :slave,
          slave: data.name,
          station: data.station,
          event: :reconnect_probe_station_mismatch,
          observed_station: station,
          position: data.position
        )

        {:keep_state_and_data, [health_poll_action(data.health_poll_ms)]}

      {:error, _reason} ->
        {:keep_state_and_data, [health_poll_action(data.health_poll_ms)]}
    end
  end

  @spec health_poll_action(pos_integer()) :: {{:timeout, :health_poll}, pos_integer(), nil}
  def health_poll_action(ms), do: {{:timeout, :health_poll}, ms, nil}

  defp report_down(data, reason, reason_text) do
    name = data.name
    station = data.station
    reason_kind = Utils.reason_kind(reason)

    EtherCAT.Telemetry.slave_down(name, station, reason)

    Logger.warning(
      "[Slave #{name}] health poll: #{reason_text} — entering :down",
      component: :slave,
      slave: name,
      station: station,
      event: :down,
      reason_kind: reason_kind
    )

    send(EtherCAT.Master, {:slave_down, name, reason_kind})
    {:next_state, :down, data}
  end

  defp report_retreated_state(
         data,
         expected_state,
         actual_state,
         al_state,
         error_ind,
         deadline_us
       ) do
    error_code =
      if error_ind do
        read_error_code(data, deadline_us)
      else
        0
      end

    if error_ind do
      EtherCAT.Telemetry.slave_health_fault(data.name, data.station, al_state, error_code)
    end

    Logger.warning(
      "[Slave #{data.name}] health poll: expected #{expected_state}, got #{actual_state} (state=0x#{Integer.to_string(al_state, 16)}#{format_error_code(error_ind, error_code)}) — updating local state",
      component: :slave,
      slave: data.name,
      station: data.station,
      event: :health_retreat,
      expected_state: expected_state,
      actual_state: actual_state,
      al_state: al_state,
      error_code: error_code
    )

    new_data =
      if error_ind do
        %{data | error_code: error_code}
      else
        data
      end

    send(EtherCAT.Master, {:slave_retreated, data.name, actual_state})
    {:next_state, actual_state, new_data}
  end

  defp reconnect_probe(data) do
    if station_alive?(data),
      do: {:ok, data, :station_restored},
      else: recover_station_from_position(data)
  end

  defp station_alive?(data) do
    case Bus.transaction(data.bus, Transaction.fprd(data.station, Registers.al_status())) do
      {:ok, [%{wkc: wkc}]} when wkc > 0 -> true
      _ -> false
    end
  end

  defp recover_station_from_position(data) do
    case read_station_at_position(data) do
      {:ok, 0} ->
        with :ok <- assign_station_at_position(data),
             :ok <- verify_reclaimed_identity(data) do
          {:ok, data, :station_reassigned}
        end

      {:ok, station} when station == data.station ->
        {:ok, data, :station_visible_by_position}

      {:ok, station} ->
        {:error, {:position_station_mismatch, station}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_station_at_position(data) do
    case Bus.transaction(data.bus, Transaction.aprd(data.position, Registers.station_address())) do
      {:ok, [%{data: <<station::16-little>>, wkc: wkc}]} when wkc > 0 -> {:ok, station}
      {:ok, [%{wkc: 0}]} -> {:error, :no_response}
      {:ok, _replies} -> {:error, :unexpected_station_reply}
      {:error, reason} -> {:error, reason}
    end
  end

  defp assign_station_at_position(data) do
    Utils.expect_positive_wkc(
      Bus.transaction(
        data.bus,
        Transaction.apwr(data.position, Registers.station_address(data.station))
      ),
      :no_response,
      :unexpected_station_assign_reply
    )
  end

  defp verify_reclaimed_identity(%{identity: nil}), do: :ok

  defp verify_reclaimed_identity(data) do
    case SII.read_identity(data.bus, data.station) do
      {:ok, identity} when identity == data.identity ->
        :ok

      {:ok, identity} ->
        _ = clear_reclaimed_station(data)
        {:error, {:reconnect_identity_mismatch, identity}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp clear_reclaimed_station(data) do
    Utils.expect_positive_wkc(
      Bus.transaction(data.bus, Transaction.fpwr(data.station, Registers.station_address(0))),
      :no_response,
      :unexpected_station_clear_reply
    )
  end

  defp log_reconnect_probe_success(data, mode) do
    message =
      case mode do
        :station_restored ->
          "[Slave #{data.name}] fixed station 0x#{Integer.to_string(data.station, 16)} responds again — rebuilding to :preop"

        :station_visible_by_position ->
          "[Slave #{data.name}] position #{data.position} still carries station 0x#{Integer.to_string(data.station, 16)} — rebuilding to :preop"

        :station_reassigned ->
          "[Slave #{data.name}] anonymous slave at position #{data.position} reclaimed as station 0x#{Integer.to_string(data.station, 16)} — rebuilding to :preop"
      end

    Logger.info(
      message,
      component: :slave,
      slave: data.name,
      station: data.station,
      event: :reconnected,
      reconnect_mode: mode,
      position: data.position
    )
  end

  defp rebuild_to_preop(data, initialize_to_preop) do
    case initialize_to_preop.(data) do
      {:ok, next_state, new_data, actions} ->
        {:next_state, next_state, new_data, actions}
    end
  end

  defp read_error_code(data, deadline_us) do
    case Bus.transaction(
           data.bus,
           Transaction.fprd(data.station, Registers.al_status_code()),
           deadline_us
         ) do
      {:ok, [%{data: <<code::16-little>>}]} -> code
      _ -> 0
    end
  end

  defp al_state_code(:preop), do: 0x02
  defp al_state_code(:safeop), do: 0x04

  defp lower_than_expected?(actual_state, expected_state)
       when is_atom(actual_state) and is_atom(expected_state) do
    state_rank(actual_state) < state_rank(expected_state)
  end

  defp lower_than_expected?(_actual_state, _expected_state), do: false

  defp state_rank(:init), do: 1
  defp state_rank(:bootstrap), do: 1
  defp state_rank(:preop), do: 2
  defp state_rank(:safeop), do: 3
  defp state_rank(:op), do: 4

  defp format_error_code(false, _error_code), do: ""
  defp format_error_code(true, error_code), do: " code=0x#{Integer.to_string(error_code, 16)}"
end
