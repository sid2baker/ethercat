defmodule EtherCAT.Slave.Health do
  @moduledoc false

  require Logger

  alias EtherCAT.Bus
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.Slave
  alias EtherCAT.Slave.Registers

  @type opts :: [
          transition_to: (%Slave{}, atom() -> {:ok, %Slave{}} | {:error, term(), %Slave{}}),
          op_code: non_neg_integer()
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
            "[Slave #{data.name}] AL fault detected: state=0x#{Integer.to_string(al_state, 16)} code=0x#{Integer.to_string(error_code, 16)} — retreating to safeop"
          )

          case transition_to.(data, :safeop) do
            {:ok, new_data} ->
              send(EtherCAT.Master, {:slave_retreated, data.name, :safeop})
              {:next_state, :safeop, new_data}

            {:error, reason, new_data} ->
              Logger.error("[Slave #{data.name}] SafeOp retreat failed: #{inspect(reason)}")
              {:keep_state, new_data, [health_poll_action(data.health_poll_ms)]}
          end
        else
          {:keep_state_and_data, [health_poll_action(data.health_poll_ms)]}
        end

      {:ok, [%{wkc: 0}]} ->
        report_down(data, "wkc=0")

      {:error, reason} ->
        report_down(data, "bus error #{inspect(reason)}")
    end
  end

  @spec probe_reconnect(%Slave{}) ::
          {:keep_state_and_data, list()} | {:keep_state, %Slave{}, list()}
  def probe_reconnect(data) do
    deadline_us = data.health_poll_ms * 500

    case Bus.transaction(
           data.bus,
           Transaction.fprd(data.station, Registers.al_status()),
           deadline_us
         ) do
      {:ok, [%{wkc: wkc}]} when wkc > 0 ->
        Logger.info("[Slave #{data.name}] reconnected — waiting for master authorization")
        send(EtherCAT.Master, {:slave_reconnected, data.name})

        {:keep_state, %{data | reconnect_ready?: true}, [health_poll_action(data.health_poll_ms)]}

      _ ->
        {:keep_state_and_data, [health_poll_action(data.health_poll_ms)]}
    end
  end

  @spec confirm_reconnect(%Slave{}) ::
          {:keep_state_and_data, list()} | {:keep_state, %Slave{}, list()}
  def confirm_reconnect(data) do
    deadline_us = data.health_poll_ms * 500

    case Bus.transaction(
           data.bus,
           Transaction.fprd(data.station, Registers.al_status()),
           deadline_us
         ) do
      {:ok, [%{wkc: wkc}]} when wkc > 0 ->
        {:keep_state_and_data, [health_poll_action(data.health_poll_ms)]}

      _ ->
        {:keep_state, %{data | reconnect_ready?: false},
         [health_poll_action(data.health_poll_ms)]}
    end
  end

  @spec health_poll_action(pos_integer()) :: {{:timeout, :health_poll}, pos_integer(), nil}
  def health_poll_action(ms), do: {{:timeout, :health_poll}, ms, nil}

  defp report_down(data, reason_text) do
    EtherCAT.Telemetry.slave_down(data.name, data.station)
    Logger.warning("[Slave #{data.name}] health poll: #{reason_text} — entering :down")
    send(EtherCAT.Master, {:slave_down, data.name})
    {:next_state, :down, data}
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
end
