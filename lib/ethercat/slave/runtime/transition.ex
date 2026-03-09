defmodule EtherCAT.Slave.Runtime.Transition do
  @moduledoc false

  require Logger

  alias EtherCAT.Bus
  alias EtherCAT.Bus.Transaction
  alias EtherCAT.Slave.Runtime.ALTransition
  alias EtherCAT.Slave.ESC.Registers

  @type hook_opts :: [
          al_codes: %{required(atom()) => non_neg_integer()},
          poll_limit: pos_integer(),
          poll_interval_ms: non_neg_integer(),
          post_transition: (atom(), %EtherCAT.Slave{} ->
                              {:ok, %EtherCAT.Slave{}} | {:error, term(), %EtherCAT.Slave{}})
        ]

  @spec walk_path(%EtherCAT.Slave{}, [atom()], hook_opts()) ::
          {:ok, %EtherCAT.Slave{}} | {:error, term(), %EtherCAT.Slave{}}
  def walk_path(data, [], _opts), do: {:ok, data}

  def walk_path(data, [next | rest], opts) do
    case transition_to(data, next, opts) do
      {:ok, new_data} -> walk_path(new_data, rest, opts)
      error -> error
    end
  end

  @spec transition_to(%EtherCAT.Slave{}, atom(), hook_opts()) ::
          {:ok, %EtherCAT.Slave{}} | {:error, term(), %EtherCAT.Slave{}}
  def transition_to(data, target, opts) do
    with {:ok, transitioned_data} <- do_transition(data, target, opts) do
      Keyword.fetch!(opts, :post_transition).(target, transitioned_data)
    end
  end

  defp do_transition(data, target, opts) do
    code = Map.fetch!(Keyword.fetch!(opts, :al_codes), target)
    Logger.debug("[Slave #{data.name}] AL → #{target} (code=0x#{Integer.to_string(code, 16)})")

    with {:ok, [%{wkc: 1}]} <-
           Bus.transaction(data.bus, Transaction.fpwr(data.station, Registers.al_control(code))) do
      poll_al(data, code, Keyword.fetch!(opts, :poll_limit), opts)
    else
      {:ok, [%{wkc: 0}]} ->
        Logger.warning("[Slave #{data.name}] AL → #{target}: no response (wkc=0)")
        {:error, :no_response, data}

      {:ok, [%{wkc: wkc}]} ->
        Logger.warning("[Slave #{data.name}] AL → #{target}: unexpected wkc=#{inspect(wkc)}")
        {:error, {:unexpected_wkc, wkc}, data}

      {:error, reason} ->
        Logger.warning("[Slave #{data.name}] AL → #{target} failed: #{inspect(reason)}")
        {:error, reason, data}
    end
  end

  defp poll_al(data, _code, 0, _opts), do: {:error, :transition_timeout, data}

  defp poll_al(data, code, remaining, opts) do
    case Bus.transaction(data.bus, Transaction.fprd(data.station, Registers.al_status())) do
      {:ok, [%{data: status, wkc: wkc}]} when wkc > 0 ->
        cond do
          ALTransition.error_latched?(status) ->
            ack_error(data, status)

          ALTransition.target_reached?(status, code) ->
            {:ok, data}

          true ->
            Process.sleep(Keyword.fetch!(opts, :poll_interval_ms))
            poll_al(data, code, remaining - 1, opts)
        end

      {:ok, [%{wkc: 0}]} ->
        {:error, :no_response, data}

      {:error, reason} ->
        {:error, reason, data}
    end
  end

  defp ack_error(data, status) do
    err_code =
      case Bus.transaction(data.bus, Transaction.fprd(data.station, Registers.al_status_code())) do
        {:ok, [%{data: <<c::16-little>>, wkc: wkc}]} when wkc > 0 -> c
        _ -> nil
      end

    new_data = %{data | error_code: err_code}
    ack_value = ALTransition.ack_value(status)

    case ALTransition.classify_ack_write(
           err_code,
           Bus.transaction(
             data.bus,
             Transaction.fpwr(data.station, Registers.al_control(ack_value))
           )
         ) do
      {:ok, acked_err_code} -> {:error, {:al_error, acked_err_code}, new_data}
      {:error, reason} -> {:error, reason, new_data}
    end
  end
end
