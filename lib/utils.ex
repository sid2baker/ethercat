defmodule EtherCAT.Utils do
  @moduledoc false

  @spec classify_call_exit(term(), term()) :: {:error, term()}
  def classify_call_exit({:timeout, _}, _missing_reason), do: {:error, :timeout}
  def classify_call_exit({:noproc, _}, missing_reason), do: {:error, missing_reason}
  def classify_call_exit({:normal, _}, missing_reason), do: {:error, missing_reason}

  def classify_call_exit({reason, {GenServer, :call, _call_args}}, _missing_reason),
    do: {:error, {:server_exit, reason}}

  def classify_call_exit(reason, _missing_reason), do: {:error, {:server_exit, reason}}

  @spec ensure_expected_wkcs([%{wkc: integer()}], non_neg_integer(), term()) ::
          :ok | {:error, term()}
  def ensure_expected_wkcs(replies, expected_wkc, error_tag)
      when is_list(replies) and replies != [] and is_integer(expected_wkc) and expected_wkc >= 0 do
    if Enum.all?(replies, &(&1.wkc == expected_wkc)) do
      :ok
    else
      {:error, error_tag}
    end
  end

  def ensure_expected_wkcs(_replies, _expected_wkc, error_tag), do: {:error, error_tag}

  @spec expect_positive_wkc({:ok, [map()]} | {:error, term()}, term(), term()) ::
          :ok | {:error, term()}
  def expect_positive_wkc({:ok, [%{wkc: wkc}]}, _zero_reason, _unexpected_reason) when wkc > 0,
    do: :ok

  def expect_positive_wkc({:ok, [%{wkc: 0}]}, zero_reason, _unexpected_reason),
    do: {:error, zero_reason}

  def expect_positive_wkc({:ok, _replies}, _zero_reason, unexpected_reason),
    do: {:error, unexpected_reason}

  def expect_positive_wkc({:error, _} = err, _zero_reason, _unexpected_reason), do: err
end
