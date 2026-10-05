defmodule EtherCAT.SlaveDescription do
  @moduledoc """
  Public description for one configured slave.

  Descriptions contain configuration and static signal metadata. Use
  `EtherCAT.status/2` for runtime status and `EtherCAT.samples/2` for observations.
  """

  alias EtherCAT.Driver
  alias EtherCAT.Endpoint
  alias EtherCAT.Slave.ProcessData.Signal

  @enforce_keys [:name, :driver, :endpoints]
  defstruct [
    :name,
    :driver,
    :device_type,
    :target_state,
    endpoints: []
  ]

  @type t :: %__MODULE__{
          name: atom(),
          driver: module(),
          device_type: atom() | nil,
          target_state: :preop | :op,
          endpoints: [Endpoint.t()]
        }

  @type native_description :: %{
          required(:device_type) => atom() | nil,
          required(:endpoints) => [Endpoint.t()]
        }

  @spec native_description(module(), Driver.config()) :: native_description()
  def native_description(driver, config) when is_atom(driver) and is_map(config) do
    raw_description =
      if Code.ensure_loaded?(driver) and function_exported?(driver, :describe, 1) do
        apply(driver, :describe, [config]) || %{}
      else
        %{}
      end

    %{
      device_type: Map.get(raw_description, :device_type),
      endpoints:
        raw_description
        |> Map.get(:endpoints, infer_endpoints(driver, config))
        |> normalize_endpoints()
    }
  end

  @doc false
  @spec from_config(EtherCAT.Slave.Config.t()) :: t()
  def from_config(%EtherCAT.Slave.Config{} = config) do
    native = native_description(config.driver, config.config)

    %__MODULE__{
      name: config.name,
      driver: config.driver,
      device_type: native.device_type,
      target_state: config.target_state,
      endpoints: native.endpoints
    }
  end

  defp normalize_endpoints(endpoints) when is_list(endpoints) do
    endpoints
    |> Enum.map(&normalize_endpoint!/1)
    |> ensure_unique!(:signal)
  end

  defp normalize_endpoints(_endpoints), do: []

  defp normalize_endpoint!(%Endpoint{} = endpoint) do
    validate_endpoint!(endpoint)
  end

  defp normalize_endpoint!(%{} = endpoint) do
    endpoint
    |> Map.new()
    |> then(fn attrs ->
      signal = Map.fetch!(attrs, :signal)

      %Endpoint{
        signal: signal,
        direction: Map.fetch!(attrs, :direction),
        type: Map.fetch!(attrs, :type),
        label: Map.get(attrs, :label),
        description: Map.get(attrs, :description)
      }
    end)
    |> validate_endpoint!()
  end

  defp normalize_endpoint!(endpoint) do
    raise ArgumentError, "invalid endpoint description: #{inspect(endpoint)}"
  end

  defp validate_endpoint!(
         %Endpoint{
           signal: signal,
           direction: direction,
           type: type,
           label: label,
           description: description
         } = endpoint
       )
       when is_atom(signal) and direction in [:input, :output] and is_atom(type) and
              (is_binary(label) or is_nil(label)) and
              (is_binary(description) or is_nil(description)) do
    endpoint
  end

  defp validate_endpoint!(endpoint) do
    raise ArgumentError, "invalid endpoint description: #{inspect(endpoint)}"
  end

  defp infer_endpoints(driver, config) do
    driver
    |> EtherCAT.Driver.Runtime.signal_model(config, [])
    |> Enum.map(fn {signal_name, signal_model} ->
      %Endpoint{
        signal: signal_name,
        direction: infer_direction(signal_model),
        type: :raw
      }
    end)
  end

  defp infer_direction(%Signal{pdo_index: pdo_index}), do: infer_direction(pdo_index)

  defp infer_direction(pdo_index)
       when is_integer(pdo_index) and pdo_index >= 0x1600 and pdo_index < 0x1A00,
       do: :output

  defp infer_direction(pdo_index) when is_integer(pdo_index) and pdo_index >= 0x1A00, do: :input
  defp infer_direction(_other), do: :input

  defp ensure_unique!(entries, field) do
    values = Enum.map(entries, &Map.fetch!(&1, field))

    if length(values) == length(Enum.uniq(values)) do
      entries
    else
      raise ArgumentError, "duplicate endpoint #{field} in driver description"
    end
  end
end
