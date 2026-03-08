defmodule EtherCAT.Slave.ProcessDataPlan.DomainAttachment do
  @moduledoc false

  @type signal_registration :: %{
          required(:signal_name) => atom(),
          required(:bit_offset) => non_neg_integer(),
          required(:bit_size) => pos_integer()
        }

  @type t :: %__MODULE__{
          domain_id: atom(),
          registrations: [signal_registration()]
        }

  @enforce_keys [:domain_id, :registrations]
  defstruct [:domain_id, :registrations]
end

defmodule EtherCAT.Slave.ProcessDataPlan.SmGroup do
  @moduledoc false

  alias EtherCAT.Slave.ProcessDataPlan.DomainAttachment

  @type t :: %__MODULE__{
          sm_index: non_neg_integer(),
          sm_key: {:sm, non_neg_integer()},
          direction: :input | :output,
          phys: non_neg_integer(),
          ctrl: non_neg_integer(),
          total_sm_size: pos_integer(),
          fmmu_type: non_neg_integer(),
          attachments: [DomainAttachment.t()]
        }

  @enforce_keys [
    :sm_index,
    :sm_key,
    :direction,
    :phys,
    :ctrl,
    :total_sm_size,
    :fmmu_type,
    :attachments
  ]
  defstruct [
    :sm_index,
    :sm_key,
    :direction,
    :phys,
    :ctrl,
    :total_sm_size,
    :fmmu_type,
    :attachments
  ]
end

defmodule EtherCAT.Slave.ProcessDataPlan do
  @moduledoc false

  alias EtherCAT.Slave.ProcessDataPlan.DomainAttachment
  alias EtherCAT.Slave.ProcessDataPlan.SmGroup
  alias EtherCAT.Slave.ProcessDataSignal

  @type signal_name :: atom()
  @type process_data_request :: :none | {:all, atom()} | [{signal_name(), atom()}]

  @type sii_sm_config ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @type sii_pdo_config :: %{
          required(:index) => non_neg_integer(),
          required(:direction) => :input | :output,
          required(:sm_index) => non_neg_integer(),
          required(:bit_size) => pos_integer(),
          required(:bit_offset) => non_neg_integer()
        }

  @type process_data_model :: [{signal_name(), non_neg_integer() | ProcessDataSignal.t()}]

  @type resolved_signal :: {signal_name(), atom(), ProcessDataSignal.t(), sii_pdo_config()}

  @spec normalize_request(process_data_request(), module() | nil, map()) ::
          {:ok, [{signal_name(), atom()}]} | {:error, term()}
  def normalize_request(:none, _driver, _config), do: {:ok, []}

  def normalize_request({:all, domain_id}, driver, config)
      when is_atom(domain_id) and not is_nil(driver) do
    requested =
      driver.process_data_model(config)
      |> Enum.map(fn {signal_name, _declaration} -> {signal_name, domain_id} end)

    {:ok, requested}
  end

  def normalize_request(requested_signals, _driver, _config) when is_list(requested_signals) do
    if Enum.all?(requested_signals, &valid_requested_signal?/1) do
      {:ok, requested_signals}
    else
      {:error, :invalid_process_data_request}
    end
  end

  def normalize_request(_request, _driver, _config), do: {:error, :invalid_process_data_request}

  @spec build([{signal_name(), atom()}], process_data_model(), [sii_pdo_config()], [
          sii_sm_config()
        ]) ::
          {:ok, [SmGroup.t()]} | {:error, term()}
  def build(requested_signals, model, sii_pdo_configs, sii_sm_configs) do
    with {:ok, resolved_signals} <-
           resolve_requested_signals(requested_signals, model, sii_pdo_configs),
         {:ok, sm_groups} <- build_sm_groups(resolved_signals, sii_pdo_configs, sii_sm_configs) do
      {:ok, sm_groups}
    end
  end

  defp valid_requested_signal?({signal_name, domain_id})
       when is_atom(signal_name) and is_atom(domain_id),
       do: true

  defp valid_requested_signal?(_), do: false

  defp resolve_requested_signals(requested_signals, model, sii_pdo_configs) do
    requested_signals
    |> Enum.reduce_while({:ok, []}, fn {signal_name, domain_id}, {:ok, acc} ->
      with {:ok, signal_spec} <- fetch_signal_spec(model, signal_name),
           {:ok, pdo_cfg} <- fetch_sii_pdo_config(sii_pdo_configs, signal_spec.pdo_index),
           {:ok, resolved_spec} <- validate_signal_range(signal_name, signal_spec, pdo_cfg) do
        {:cont, {:ok, [{signal_name, domain_id, resolved_spec, pdo_cfg} | acc]}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, resolved_rev} -> {:ok, Enum.reverse(resolved_rev)}
      {:error, _} = err -> err
    end
  end

  defp fetch_signal_spec(model, signal_name) do
    case Keyword.fetch(model, signal_name) do
      {:ok, declaration} -> normalize_signal_declaration(signal_name, declaration)
      :error -> {:error, {:signal_not_in_driver_model, signal_name}}
    end
  end

  defp normalize_signal_declaration(_signal_name, declaration)
       when is_integer(declaration) and declaration >= 0 do
    {:ok, ProcessDataSignal.whole_pdo(declaration)}
  end

  defp normalize_signal_declaration(signal_name, %ProcessDataSignal{} = declaration) do
    validate_signal_declaration(signal_name, declaration)
  end

  defp normalize_signal_declaration(signal_name, _declaration) do
    {:error, {:invalid_signal_model, signal_name}}
  end

  defp validate_signal_declaration(_signal_name, %ProcessDataSignal{
         pdo_index: pdo_index,
         bit_offset: bit_offset,
         bit_size: bit_size
       })
       when is_integer(pdo_index) and pdo_index >= 0 and is_integer(bit_offset) and
              bit_offset >= 0 and
              is_integer(bit_size) and bit_size > 0 do
    {:ok, %ProcessDataSignal{pdo_index: pdo_index, bit_offset: bit_offset, bit_size: bit_size}}
  end

  defp validate_signal_declaration(
         _signal_name,
         %ProcessDataSignal{pdo_index: pdo_index, bit_offset: 0, bit_size: nil}
       )
       when is_integer(pdo_index) and pdo_index >= 0 do
    {:ok, ProcessDataSignal.whole_pdo(pdo_index)}
  end

  defp validate_signal_declaration(signal_name, _declaration) do
    {:error, {:invalid_signal_model, signal_name}}
  end

  defp fetch_sii_pdo_config(sii_pdo_configs, pdo_index) do
    case Enum.find(sii_pdo_configs, fn pdo_cfg -> pdo_cfg.index == pdo_index end) do
      nil -> {:error, {:pdo_not_in_sii, pdo_index}}
      pdo_cfg -> {:ok, pdo_cfg}
    end
  end

  defp validate_signal_range(signal_name, %ProcessDataSignal{} = signal_spec, pdo_cfg) do
    bit_size = signal_spec.bit_size || pdo_cfg.bit_size
    end_bit = signal_spec.bit_offset + bit_size

    if end_bit <= pdo_cfg.bit_size do
      {:ok, %{signal_spec | bit_size: bit_size}}
    else
      {:error, {:signal_range_out_of_bounds, signal_name, signal_spec.pdo_index}}
    end
  end

  defp build_sm_groups(resolved_signals, sii_pdo_configs, sii_sm_configs) do
    resolved_signals
    |> Enum.group_by(fn {_signal_name, _domain_id, _signal_spec, pdo_cfg} -> pdo_cfg.sm_index end)
    |> Enum.sort_by(fn {sm_index, _group} -> sm_index end)
    |> Enum.reduce_while({:ok, []}, fn {sm_index, sm_signals}, {:ok, acc} ->
      case build_sm_group(sm_index, sm_signals, sii_pdo_configs, sii_sm_configs) do
        {:ok, sm_group} -> {:cont, {:ok, [sm_group | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, groups_rev} -> {:ok, Enum.reverse(groups_rev)}
      {:error, _} = err -> err
    end
  end

  defp build_sm_group(sm_index, sm_signals, sii_pdo_configs, sii_sm_configs) do
    {_signal_name, _domain_id, _signal_spec, first_cfg} = hd(sm_signals)

    with {:ok, {^sm_index, phys, _sii_len, ctrl}} <- fetch_sm_config(sii_sm_configs, sm_index),
         {:ok, attachments} <- build_domain_attachments(sm_index, sm_signals, first_cfg.direction) do
      total_sm_bits =
        Enum.reduce(sii_pdo_configs, 0, fn
          %{sm_index: ^sm_index, bit_size: bit_size}, acc -> acc + bit_size
          _, acc -> acc
        end)

      direction = first_cfg.direction
      fmmu_type = if direction == :input, do: 0x01, else: 0x02

      {:ok,
       %SmGroup{
         sm_index: sm_index,
         sm_key: {:sm, sm_index},
         direction: direction,
         phys: phys,
         ctrl: ctrl,
         total_sm_size: div(total_sm_bits + 7, 8),
         fmmu_type: fmmu_type,
         attachments: attachments
       }}
    end
  end

  defp build_domain_attachments(_sm_index, sm_signals, _direction) do
    {:ok,
     sm_signals
     |> grouped_domain_signals()
     |> Enum.map(fn {domain_id, domain_signals} ->
       build_domain_attachment(domain_id, domain_signals)
     end)}
  end

  defp grouped_domain_signals(sm_signals) do
    sm_signals
    |> Enum.group_by(fn {_signal_name, domain_id, _signal_spec, _pdo_cfg} -> domain_id end)
    |> Enum.sort_by(fn {domain_id, _signals} -> domain_id end)
  end

  defp build_domain_attachment(domain_id, domain_signals) do
    %DomainAttachment{
      domain_id: domain_id,
      registrations:
        Enum.map(domain_signals, fn {signal_name, _domain_id, signal_spec, pdo_cfg} ->
          %{
            signal_name: signal_name,
            bit_offset: pdo_cfg.bit_offset + signal_spec.bit_offset,
            bit_size: signal_spec.bit_size
          }
        end)
    }
  end

  defp fetch_sm_config(sii_sm_configs, sm_index) do
    case Enum.find(sii_sm_configs, fn {idx, _, _, _} -> idx == sm_index end) do
      nil -> {:error, {:sm_not_in_sii, sm_index}}
      sm_config -> {:ok, sm_config}
    end
  end
end
