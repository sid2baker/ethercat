defmodule EtherCAT.Slave.Runtime.ALTransition do
  @moduledoc false

  @spec target_reached?(binary(), non_neg_integer()) :: boolean()
  def target_reached?(<<_::3, 0::1, state::4, _::8>>, target_code) when state == target_code,
    do: true

  def target_reached?(_status, _target_code), do: false

  @spec error_latched?(binary()) :: boolean()
  def error_latched?(<<_::3, 1::1, _::4, _::8>>), do: true
  def error_latched?(_status), do: false

  @spec ack_value(binary()) :: non_neg_integer()
  def ack_value(<<_::3, _error::1, state::4, _::8>>), do: state + 0x10

  @spec classify_ack_write(non_neg_integer() | nil, term()) ::
          {:ok, non_neg_integer() | nil} | {:error, term()}
  def classify_ack_write(err_code, {:ok, [%{wkc: 1}]}) do
    {:ok, err_code}
  end

  def classify_ack_write(err_code, {:ok, [%{wkc: 0}]}) do
    {:error, {:al_error, err_code, {:ack_failed, :no_response}}}
  end

  def classify_ack_write(err_code, {:ok, [%{wkc: wkc}]}) when is_integer(wkc) do
    {:error, {:al_error, err_code, {:ack_failed, {:unexpected_wkc, wkc}}}}
  end

  def classify_ack_write(err_code, {:error, reason}) do
    {:error, {:al_error, err_code, {:ack_failed, reason}}}
  end

  def classify_ack_write(err_code, reply) do
    {:error, {:al_error, err_code, {:ack_failed, {:unexpected_reply, reply}}}}
  end
end
