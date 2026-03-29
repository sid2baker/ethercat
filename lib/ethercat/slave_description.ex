defmodule EtherCAT.SlaveDescription do
  @moduledoc """
  Public effective description for one configured slave.

  Drivers describe native endpoints. `EtherCAT` applies slave-local aliases on
  top of that native surface so applications can bind against configured
  endpoint names while still seeing the backing raw signal for each endpoint.
  """

  alias EtherCAT.Driver
  alias EtherCAT.Endpoint
  alias EtherCAT.Slave.ProcessData.Signal
  alias EtherCAT.SlaveSnapshot

  @enforce_keys [:name, :driver, :endpoints]
  defstruct [
    :name,
    :driver,
    :device_type,
    :al_state,
    endpoints: [],
    commands: [],
    updated_at_us: nil,
    faults: []
  ]

  @type t :: %__MODULE__{
          name: atom(),
          driver: module(),
          device_type: atom() | nil,
          al_state: atom() | nil,
          endpoints: [Endpoint.t()],
          commands: [atom()],
          updated_at_us: integer() | nil,
          faults: [term()]
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

  @spec effective(atom(), module(), Driver.config(), %{optional(atom()) => atom()}, keyword()) ::
          t()
  def effective(name, driver, config, aliases, opts \\ [])
      when is_atom(name) and is_atom(driver) and is_map(config) and is_map(aliases) and
             is_list(opts) do
    native = native_description(driver, config)

    %__MODULE__{
      name: name,
      driver: driver,
      device_type: native.device_type,
      al_state: Keyword.get(opts, :al_state),
      endpoints: apply_aliases(native.endpoints, aliases),
      commands: native.commands,
      updated_at_us: Keyword.get(opts, :updated_at_us),
      faults: Keyword.get(opts, :faults, [])
    }
  end

  @spec from_snapshot(SlaveSnapshot.t()) :: t()
  def from_snapshot(%SlaveSnapshot{} = snapshot) do
    %__MODULE__{
      name: snapshot.name,
      driver: snapshot.driver,
      device_type: snapshot.device_type,
      al_state: snapshot.al_state,
      endpoints: snapshot.endpoints,
      commands: snapshot.commands,
      updated_at_us: snapshot.updated_at_us,
      faults: snapshot.faults
    }
  end

  @spec validate_aliases(module(), Driver.config(), %{optional(atom()) => atom()}) ::
          :ok | {:error, term()}
  def validate_aliases(driver, config, aliases)
      when is_atom(driver) and is_map(config) and is_map(aliases) do
    native_endpoints = native_description(driver, config).endpoints
    native_signals = MapSet.new(Enum.map(native_endpoints, & &1.signal))

    with :ok <- validate_alias_keys(aliases, native_signals),
         :ok <- validate_alias_values(aliases),
         :ok <- validate_unique_effective_names(native_endpoints, aliases) do
      :ok
    end
  end

  @spec effective_name_by_signal(t()) :: %{optional(atom()) => atom()}
  def effective_name_by_signal(%__MODULE__{endpoints: endpoints}) do
    Map.new(endpoints, &{&1.signal, &1.name})
  end

  @spec signal_for_name(t(), atom()) :: {:ok, atom()} | :error
  def signal_for_name(%__MODULE__{endpoints: endpoints}, name) when is_atom(name) do
    case Enum.find(endpoints, &(&1.name == name)) do
      %Endpoint{signal: signal} -> {:ok, signal}
      nil -> :error
    end
  end

  defp apply_aliases(endpoints, aliases) do
    Enum.map(endpoints, fn %Endpoint{} = endpoint ->
      %{endpoint | name: Map.get(aliases, endpoint.signal, endpoint.name)}
    end)
  end

  defp normalize_endpoints(endpoints) when is_list(endpoints) do
    endpoints
    |> Enum.map(&normalize_endpoint!/1)
    |> ensure_unique!(:signal)
    |> ensure_unique!(:name)
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
        name: Map.get(attrs, :name, signal),
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
           name: name,
           direction: direction,
           type: type,
           label: label,
           description: description
         } = endpoint
       )
       when is_atom(signal) and is_atom(name) and direction in [:input, :output] and is_atom(type) and
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
        name: signal_name,
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

  defp validate_alias_keys(aliases, native_signals) do
    Enum.reduce_while(aliases, :ok, fn
      {signal, _name}, :ok when is_atom(signal) ->
        if MapSet.member?(native_signals, signal) do
          {:cont, :ok}
        else
          {:halt, {:error, {:unknown_endpoint_signal, signal}}}
        end

      {_signal, _name}, :ok ->
        {:halt, {:error, :invalid_aliases}}
    end)
  end

  defp validate_alias_values(aliases) do
    Enum.reduce_while(aliases, :ok, fn
      {_signal, name}, :ok when is_atom(name) ->
        {:cont, :ok}

      {_signal, _name}, :ok ->
        {:halt, {:error, :invalid_aliases}}
    end)
  end

  defp validate_unique_effective_names(native_endpoints, aliases) do
    names =
      native_endpoints
      |> apply_aliases(aliases)
      |> Enum.map(& &1.name)

    if length(names) == length(Enum.uniq(names)) do
      :ok
    else
      {:error, :duplicate_endpoint_name}
    end
  end

  defp ensure_unique!(entries, field) do
    values = Enum.map(entries, &Map.fetch!(&1, field))

    if length(values) == length(Enum.uniq(values)) do
      entries
    else
      raise ArgumentError, "duplicate endpoint #{field} in driver description"
    end
  end
end
