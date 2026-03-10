defmodule EtherCAT.Slave.Runtime.Signals do
  @moduledoc false

  alias EtherCAT.Domain.API, as: DomainAPI

  @spec attachment_summaries(map() | nil) :: [map()]
  def attachment_summaries(nil), do: []

  def attachment_summaries(registrations) when is_map(registrations) do
    registrations
    |> Enum.reduce(%{}, fn {signal_name, registration}, acc ->
      key = {registration.domain_id, registration.sm_key}

      Map.update(
        acc,
        key,
        %{
          domain: registration.domain_id,
          sm_index: elem(registration.sm_key, 1),
          direction: registration.direction,
          logical_address: Map.get(registration, :logical_address),
          sm_size: Map.get(registration, :sm_size),
          signals: [signal_name]
        },
        fn summary ->
          %{summary | signals: [signal_name | summary.signals]}
        end
      )
    end)
    |> Enum.map(fn {_key, summary} ->
      signals = summary.signals |> Enum.uniq() |> Enum.sort()
      Map.merge(summary, %{signal_count: length(signals), signals: signals})
    end)
    |> Enum.sort_by(&{&1.sm_index, &1.domain})
  end

  @spec subscribe_pid(%EtherCAT.Slave{}, atom(), pid()) :: %EtherCAT.Slave{}
  def subscribe_pid(data, signal_name, pid) do
    {subscriber_refs, pid_set} =
      ensure_subscriber_monitor(
        data.subscriber_refs,
        Map.get(data.subscriptions, signal_name, MapSet.new()),
        pid
      )

    %{
      data
      | subscriber_refs: subscriber_refs,
        subscriptions: Map.put(data.subscriptions, signal_name, pid_set)
    }
  end

  @spec drop_subscriber(%EtherCAT.Slave{}, pid()) :: %EtherCAT.Slave{}
  def drop_subscriber(data, pid) do
    subscriptions = prune_subscription_pid(data.subscriptions, pid)

    %{
      data
      | subscriptions: subscriptions,
        subscriber_refs: Map.delete(data.subscriber_refs, pid)
    }
  end

  @spec read_input(%EtherCAT.Slave{}, atom()) :: {:ok, {term(), integer()}} | {:error, term()}
  def read_input(data, signal_name) do
    case Map.get(data.signal_registrations, signal_name) do
      nil ->
        {:error, {:not_registered, signal_name}}

      %{direction: :output} ->
        {:error, {:not_input, signal_name}}

      %{
        domain_id: domain_id,
        sm_key: sm_key,
        bit_offset: bit_offset,
        bit_size: bit_size,
        direction: :input
      } ->
        case DomainAPI.sample(domain_id, {data.name, sm_key}) do
          {:error, _} = err ->
            err

          {:ok, %{value: sm_bytes, updated_at_us: updated_at_us}}
          when is_integer(updated_at_us) ->
            raw = extract_sm_bits(sm_bytes, bit_offset, bit_size)
            {:ok, {data.driver.decode_signal(signal_name, data.config, raw), updated_at_us}}
        end
    end
  end

  @spec dispatch_domain_input(
          %EtherCAT.Slave{},
          atom(),
          tuple(),
          binary(),
          binary()
        ) :: :ok
  def dispatch_domain_input(data, domain_id, sm_key, old_sm_bytes, new_sm_bytes) do
    notifications =
      data.signal_registrations_by_sm
      |> Map.get({domain_id, sm_key}, [])
      |> Enum.reduce([], fn {signal_name, %{bit_offset: bit_offset, bit_size: bit_size}}, acc ->
        if signal_changed?(old_sm_bytes, new_sm_bytes, bit_offset, bit_size) do
          raw = extract_sm_bits(new_sm_bytes, bit_offset, bit_size)

          decoded =
            if data.driver != nil do
              data.driver.decode_signal(signal_name, data.config, raw)
            else
              raw
            end

          data.subscriptions
          |> Map.get(signal_name, MapSet.new())
          |> Enum.reduce(acc, fn pid, pid_acc ->
            [{pid, signal_name, decoded} | pid_acc]
          end)
        else
          acc
        end
      end)

    Enum.each(Enum.reverse(notifications), fn {pid, signal_name, decoded} ->
      send(pid, {:ethercat, :signal, data.name, signal_name, decoded})
    end)
  end

  @spec extract_sm_bits(binary(), non_neg_integer(), pos_integer()) :: binary()
  def extract_sm_bits(sm_bytes, bit_offset, bit_size) do
    if rem(bit_offset, 8) == 0 and rem(bit_size, 8) == 0 do
      binary_part(sm_bytes, div(bit_offset, 8), div(bit_size, 8))
    else
      total_bits = byte_size(sm_bytes) * 8
      <<sm_value::unsigned-little-size(total_bits)>> = sm_bytes
      high_bits = total_bits - bit_offset - bit_size

      <<_::size(high_bits), raw::size(bit_size), _::size(bit_offset)>> =
        <<sm_value::size(total_bits)>>

      encoded_bits = ceil_div(bit_size, 8) * 8

      <<encoded_value::size(encoded_bits)>> =
        <<0::size(encoded_bits - bit_size), raw::size(bit_size)>>

      <<encoded_value::unsigned-little-size(encoded_bits)>>
    end
  end

  @spec signal_changed?(binary() | :unset, binary(), non_neg_integer(), pos_integer()) ::
          boolean()
  def signal_changed?(:unset, _new_sm_bytes, _bit_offset, _bit_size), do: true

  def signal_changed?(old_sm_bytes, new_sm_bytes, bit_offset, bit_size) do
    extract_sm_bits(old_sm_bytes, bit_offset, bit_size) !=
      extract_sm_bits(new_sm_bytes, bit_offset, bit_size)
  end

  defp ensure_subscriber_monitor(subscriber_refs, current_set, pid) do
    refs =
      if Map.has_key?(subscriber_refs, pid) do
        subscriber_refs
      else
        Map.put(subscriber_refs, pid, Process.monitor(pid))
      end

    {refs, MapSet.put(current_set, pid)}
  end

  defp prune_subscription_pid(subscriptions, pid) do
    Enum.reduce(subscriptions, %{}, fn {key, pid_set}, acc ->
      next_set = MapSet.delete(pid_set, pid)

      if MapSet.size(next_set) == 0 do
        acc
      else
        Map.put(acc, key, next_set)
      end
    end)
  end

  defp ceil_div(value, divisor) when is_integer(value) and is_integer(divisor) and divisor > 0 do
    div(value + divisor - 1, divisor)
  end
end
