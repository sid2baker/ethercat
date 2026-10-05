defmodule EtherCAT.Slave.Runtime.Samples do
  @moduledoc false

  alias EtherCAT.Sample
  alias EtherCAT.Slave
  alias EtherCAT.Slave.Runtime.Notifications
  alias EtherCAT.Slave.Runtime.Signals

  @type sample_map :: %{optional(atom()) => Sample.t()}

  @spec initialize(Slave.t()) :: Slave.t()
  def initialize(%Slave{} = data), do: %{data | samples: %{}}

  @spec refresh(Slave.t(), atom(), non_neg_integer(), map(), integer(), [atom()]) :: Slave.t()
  def refresh(
        %Slave{} = data,
        domain_id,
        cycle,
        sm_inputs,
        observed_at,
        changed_signal_names
      )
      when is_atom(domain_id) and is_integer(cycle) and cycle >= 0 and is_map(sm_inputs) and
             is_integer(observed_at) and is_list(changed_signal_names) do
    {inputs, errors} = decode_inputs(data, domain_id, sm_inputs)

    sample = %Sample{
      slave: data.name,
      domain: domain_id,
      cycle: cycle,
      observed_at: observed_at,
      inputs: inputs,
      errors: errors
    }

    Signals.dispatch_sampled_inputs(data, changed_signal_names, inputs, errors)
    Notifications.dispatch(data, sample)
    %{data | samples: Map.put(data.samples, domain_id, sample)}
  end

  @spec all(Slave.t()) :: sample_map()
  def all(%Slave{} = data), do: data.samples

  defp decode_inputs(data, domain_id, sm_inputs) do
    data.signal_registrations
    |> Enum.filter(fn {_name, registration} ->
      registration.direction == :input and registration.domain_id == domain_id
    end)
    |> Enum.reduce({%{}, %{}}, fn {signal_name, registration}, {inputs, errors} ->
      sm_bytes = Map.fetch!(sm_inputs, {data.name, registration.sm_key})
      raw = Signals.extract_sm_bits(sm_bytes, registration.bit_offset, registration.bit_size)

      case EtherCAT.Driver.Runtime.decode(data.driver, signal_name, data.config, raw) do
        {:ok, value} ->
          {Map.put(inputs, signal_name, value), errors}

        {:error, {:decode_failed, ^signal_name, reason}} ->
          {inputs, Map.put(errors, signal_name, reason)}
      end
    end)
  end
end
