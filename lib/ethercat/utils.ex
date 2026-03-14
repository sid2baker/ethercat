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

  @spec reason_kind(term()) :: atom()
  def reason_kind(reason) when is_atom(reason), do: reason

  def reason_kind({reason, _rest}) when is_atom(reason), do: reason
  def reason_kind({reason, _, _}) when is_atom(reason), do: reason
  def reason_kind({reason, _, _, _}) when is_atom(reason), do: reason

  def reason_kind(%{__exception__: true}), do: :exception
  def reason_kind(_reason), do: :unknown

  @spec fault_kind(term()) :: atom() | nil
  def fault_kind(nil), do: nil
  def fault_kind(fault) when is_atom(fault), do: fault
  def fault_kind({fault, _details}) when is_atom(fault), do: fault
  def fault_kind({fault, _, _}) when is_atom(fault), do: fault
  def fault_kind(_fault), do: :unknown

  @spec fault_detail(term()) :: atom() | nil
  def fault_detail(nil), do: nil
  def fault_detail(fault) when is_atom(fault), do: fault
  def fault_detail({_fault, detail}) when is_atom(detail), do: detail
  def fault_detail({_fault, detail}), do: reason_kind(detail)
  def fault_detail({_fault, detail, _extra}) when is_atom(detail), do: detail
  def fault_detail({_fault, detail, _extra}), do: reason_kind(detail)
  def fault_detail(_fault), do: :unknown

  @spec cycle_reason_metadata(term()) :: %{
          reason: atom(),
          expected_wkc: non_neg_integer() | nil,
          actual_wkc: non_neg_integer() | nil,
          reply_count: non_neg_integer() | nil
        }
  def cycle_reason_metadata({:wkc_mismatch, %{expected: expected_wkc, actual: actual_wkc}})
      when is_integer(expected_wkc) and expected_wkc >= 0 and is_integer(actual_wkc) and
             actual_wkc >= 0 do
    %{
      reason: :wkc_mismatch,
      expected_wkc: expected_wkc,
      actual_wkc: actual_wkc,
      reply_count: 1
    }
  end

  def cycle_reason_metadata({:unexpected_reply, reply_count})
      when is_integer(reply_count) and reply_count >= 0 do
    %{
      reason: :unexpected_reply,
      expected_wkc: nil,
      actual_wkc: nil,
      reply_count: reply_count
    }
  end

  def cycle_reason_metadata(reason) do
    %{
      reason: reason_kind(reason),
      expected_wkc: nil,
      actual_wkc: nil,
      reply_count: nil
    }
  end

  @spec retry_log_level(pos_integer()) :: :debug | :warning
  def retry_log_level(retry_count) when is_integer(retry_count) and retry_count > 0 do
    if retry_count == 1 or rem(retry_count, 10) == 0, do: :warning, else: :debug
  end
end
