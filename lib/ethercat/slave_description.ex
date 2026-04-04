defmodule EtherCAT.SlaveDescription do
  @moduledoc """
  Public description for one configured slave.

  This struct is intentionally configuration-backed. It carries the
  interface plus light runtime summary fields such as station, pid, target
  state, and tracked fault. Current endpoint values stay on
  `EtherCAT.SlaveSnapshot`.
  """

  alias EtherCAT.Driver
  alias EtherCAT.Endpoint
  alias EtherCAT.Slave.ProcessData.Signal
  alias EtherCAT.Master.Status
  alias EtherCAT.SlaveSnapshot

  @enforce_keys [:name, :driver, :endpoints]
  defstruct [
    :name,
    :driver,
    :device_type,
    :station,
    :pid,
    :target_state,
    :fault,
    endpoints: [],
    commands: []
  ]

  @type t :: %__MODULE__{
          name: atom(),
          driver: module(),
          device_type: atom() | nil,
          station: non_neg_integer() | nil,
          pid: pid() | nil,
          target_state: :preop | :op | nil,
          fault: term() | nil,
          endpoints: [Endpoint.t()],
          commands: [atom()]
        }

  @type native_description :: %{
          required(:device_type) => atom() | nil,
          required(:endpoints) => [Endpoint.t()],
          required(:commands) => [atom()]
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
        |> normalize_endpoints(),
      commands:
        raw_description
        |> Map.get(:commands, Map.get(raw_description, :capabilities, []))
        |> normalize_commands()
    }
  end

  @spec effective(atom(), module(), Driver.config(), keyword()) :: t()
  def effective(name, driver, config, opts \\ [])
      when is_atom(name) and is_atom(driver) and is_map(config) and is_list(opts) do
    native = native_description(driver, config)

    %__MODULE__{
      name: name,
      driver: driver,
      device_type: native.device_type,
      station: Keyword.get(opts, :station),
      pid: Keyword.get(opts, :pid),
      target_state: Keyword.get(opts, :target_state),
      fault: Keyword.get(opts, :fault),
      endpoints: native.endpoints,
      commands: native.commands
    }
  end

  @spec from_configured_slave(Status.configured_slave()) :: t()
  def from_configured_slave(%{
        name: name,
        driver: driver,
        config: config,
        station: station,
        pid: pid,
        target_state: target_state,
        fault: fault
      })
      when is_atom(name) and is_atom(driver) and is_map(config) do
    effective(name, driver, config,
      station: station,
      pid: pid,
      target_state: target_state,
      fault: fault
    )
  end

  @spec from_snapshot(SlaveSnapshot.t()) :: t()
  def from_snapshot(%SlaveSnapshot{} = snapshot) do
    %__MODULE__{
      name: snapshot.name,
      driver: snapshot.driver,
      device_type: snapshot.device_type,
      station: nil,
      pid: nil,
      target_state: nil,
      fault: nil,
      endpoints: snapshot.endpoints,
      commands: snapshot.commands
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

  defp normalize_commands(commands) when is_list(commands) do
    commands
    |> Enum.map(fn
      command when is_atom(command) -> command
      other -> raise ArgumentError, "invalid driver command description: #{inspect(other)}"
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_commands(_commands), do: []

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
