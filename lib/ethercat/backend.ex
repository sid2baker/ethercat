defmodule EtherCAT.Backend.Udp do
  @moduledoc """
  Canonical UDP backend description.
  """

  @default_port 0x88A4

  @enforce_keys [:host]
  defstruct [:host, :bind_ip, port: @default_port]

  @type t :: %__MODULE__{
          host: :inet.ip_address(),
          bind_ip: :inet.ip_address() | nil,
          port: :inet.port_number()
        }
end

defmodule EtherCAT.Backend.Raw do
  @moduledoc """
  Canonical raw-socket backend description.
  """

  @enforce_keys [:interface]
  defstruct [:interface]

  @type t :: %__MODULE__{
          interface: String.t()
        }
end

defmodule EtherCAT.Backend.Redundant do
  @moduledoc """
  Canonical redundant raw backend description.
  """

  alias EtherCAT.Backend.Raw

  @enforce_keys [:primary, :secondary]
  defstruct [:primary, :secondary]

  @type t :: %__MODULE__{
          primary: Raw.t(),
          secondary: Raw.t()
        }
end

defmodule EtherCAT.Backend do
  @moduledoc """
  Canonical backend description for master startup, simulator transport, and scan.

  Public API boundaries accept tagged tuples such as:

  - `{:udp, %{host: {127, 0, 0, 2}, bind_ip: {127, 0, 0, 1}, port: 0x88A4}}`
  - `{:raw, %{interface: "eth0"}}`
  - `{:redundant, %{primary: {:raw, %{interface: "eth0"}}, secondary: {:raw, %{interface: "eth1"}}}}`

  Internally those normalize to `%EtherCAT.Backend.*{}` structs so the runtime,
  status, and scan layers all speak the same transport shape.
  """

  alias __MODULE__.{Raw, Redundant, Udp}

  @type opts_container :: keyword() | map()
  @type input ::
          t()
          | {:udp, opts_container()}
          | {:raw, opts_container()}
          | {:redundant, opts_container()}

  @type t :: Udp.t() | Raw.t() | Redundant.t()

  @spec normalize(term()) :: {:ok, t()} | {:error, term()}
  def normalize(%Udp{} = backend), do: {:ok, backend}
  def normalize(%Raw{} = backend), do: {:ok, backend}
  def normalize(%Redundant{} = backend), do: normalize_redundant_struct(backend)

  def normalize({:udp, opts}) do
    with {:ok, normalized_opts} <- normalize_opts(opts),
         :ok <- reject_unknown_fields(normalized_opts, [:host, :bind_ip, :port], :udp),
         {:ok, host} <- fetch_ip(normalized_opts, :host, :missing_host),
         {:ok, bind_ip} <- fetch_optional_ip(normalized_opts, :bind_ip),
         {:ok, port} <- fetch_port(normalized_opts, :port, 0x88A4) do
      {:ok, %Udp{host: host, bind_ip: bind_ip, port: port}}
    end
  end

  def normalize({:raw, opts}) do
    with {:ok, normalized_opts} <- normalize_opts(opts),
         :ok <- reject_unknown_fields(normalized_opts, [:interface], :raw),
         {:ok, interface} <- fetch_binary(normalized_opts, :interface, :missing_interface) do
      {:ok, %Raw{interface: interface}}
    end
  end

  def normalize({:redundant, opts}) do
    with {:ok, normalized_opts} <- normalize_opts(opts),
         :ok <- reject_unknown_fields(normalized_opts, [:primary, :secondary], :redundant),
         {:ok, primary_spec} <- fetch_field(normalized_opts, :primary, :missing_primary_backend),
         {:ok, secondary_spec} <-
           fetch_field(normalized_opts, :secondary, :missing_secondary_backend),
         {:ok, %Raw{} = primary} <- normalize(primary_spec),
         {:ok, %Raw{} = secondary} <- normalize(secondary_spec) do
      {:ok, %Redundant{primary: primary, secondary: secondary}}
    else
      {:ok, _other_backend} ->
        {:error, {:invalid_backend, :redundant_requires_raw_backends}}

      {:error, _} = err ->
        err
    end
  end

  def normalize(_backend), do: {:error, {:invalid_backend, :unsupported_backend}}

  @spec to_bus_opts(t()) :: keyword()
  def to_bus_opts(%Udp{} = backend) do
    [transport: :udp, host: backend.host, port: backend.port]
    |> maybe_put(:bind_ip, backend.bind_ip)
  end

  def to_bus_opts(%Raw{} = backend) do
    [interface: backend.interface]
  end

  def to_bus_opts(%Redundant{primary: primary, secondary: secondary}) do
    [interface: primary.interface, backup_interface: secondary.interface]
  end

  @spec to_simulator_opts(t(), term()) :: keyword()
  def to_simulator_opts(backend, transport_opts \\ [])

  def to_simulator_opts(%Udp{} = backend, transport_opts) when is_list(transport_opts) do
    [udp: Keyword.merge([ip: backend.host, port: backend.port], transport_opts)]
  end

  def to_simulator_opts(%Udp{} = backend, _transport_opts) do
    [udp: [ip: backend.host, port: backend.port]]
  end

  def to_simulator_opts(%Raw{} = backend, transport_opts) when is_list(transport_opts) do
    [raw: Keyword.merge([interface: backend.interface], transport_opts)]
  end

  def to_simulator_opts(%Raw{} = backend, _transport_opts) do
    [raw: [interface: backend.interface]]
  end

  def to_simulator_opts(%Redundant{primary: primary, secondary: secondary}, transport_opts) do
    primary_transport_opts = redundant_transport_opts(transport_opts, :primary)
    secondary_transport_opts = redundant_transport_opts(transport_opts, :secondary)

    [
      raw: [
        primary: Keyword.merge([interface: primary.interface], primary_transport_opts),
        secondary: Keyword.merge([interface: secondary.interface], secondary_transport_opts)
      ]
    ]
  end

  @spec merge_runtime(t(), map()) :: t()
  def merge_runtime(%Udp{} = backend, %{ip: host, port: port})
      when is_tuple(host) and is_integer(port) and port >= 0 do
    %{backend | host: host, port: port}
  end

  def merge_runtime(%Raw{} = backend, %{primary: %{interface: interface}})
      when is_binary(interface) do
    %{backend | interface: interface}
  end

  def merge_runtime(
        %Redundant{} = backend,
        %{primary: %{interface: primary}, secondary: %{interface: secondary}}
      )
      when is_binary(primary) and is_binary(secondary) do
    %{
      backend
      | primary: %{backend.primary | interface: primary},
        secondary: %{backend.secondary | interface: secondary}
    }
  end

  def merge_runtime(%Redundant{} = backend, %{primary: %{interface: primary}})
      when is_binary(primary) do
    %{backend | primary: %{backend.primary | interface: primary}}
  end

  def merge_runtime(%Raw{} = backend, %{interface: interface}) when is_binary(interface) do
    %{backend | interface: interface}
  end

  def merge_runtime(%Udp{} = backend, _runtime_info), do: backend
  def merge_runtime(%Raw{} = backend, _runtime_info), do: backend
  def merge_runtime(%Redundant{} = backend, _runtime_info), do: backend

  @spec transport(t()) :: :udp | :raw | :redundant
  def transport(%Udp{}), do: :udp
  def transport(%Raw{}), do: :raw
  def transport(%Redundant{}), do: :redundant

  defp normalize_redundant_struct(%Redundant{primary: %Raw{}, secondary: %Raw{}} = backend) do
    {:ok, backend}
  end

  defp normalize_redundant_struct(_backend) do
    {:error, {:invalid_backend, :redundant_requires_raw_backends}}
  end

  defp normalize_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      {:ok, Map.new(opts)}
    else
      {:error, {:invalid_backend, :invalid_backend_options}}
    end
  end

  defp normalize_opts(opts) when is_map(opts), do: {:ok, opts}
  defp normalize_opts(_opts), do: {:error, {:invalid_backend, :invalid_backend_options}}

  defp reject_unknown_fields(opts, allowed_fields, transport) do
    unknown_fields =
      opts
      |> Map.keys()
      |> Enum.reject(&(&1 in allowed_fields))

    if unknown_fields == [] do
      :ok
    else
      {:error, {:invalid_backend, {transport, {:unknown_fields, unknown_fields}}}}
    end
  end

  defp fetch_field(opts, key, error_reason) do
    case Map.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_backend, error_reason}}
    end
  end

  defp fetch_ip(opts, key, error_reason) do
    with {:ok, value} <- fetch_field(opts, key, error_reason),
         true <- ip?(value) do
      {:ok, value}
    else
      false -> {:error, {:invalid_backend, {key, :invalid_ip}}}
      {:error, _} = err -> err
    end
  end

  defp fetch_optional_ip(opts, key) do
    case Map.get(opts, key) do
      nil ->
        {:ok, nil}

      value ->
        if ip?(value) do
          {:ok, value}
        else
          {:error, {:invalid_backend, {key, :invalid_ip}}}
        end
    end
  end

  defp fetch_port(opts, key, default) do
    case Map.get(opts, key, default) do
      port when is_integer(port) and port >= 0 and port <= 0xFFFF ->
        {:ok, port}

      _other ->
        {:error, {:invalid_backend, {key, :invalid_port}}}
    end
  end

  defp fetch_binary(opts, key, error_reason) do
    case Map.get(opts, key) do
      value when is_binary(value) and byte_size(value) > 0 ->
        {:ok, value}

      nil ->
        {:error, {:invalid_backend, error_reason}}

      _other ->
        {:error, {:invalid_backend, {key, :invalid_value}}}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp redundant_transport_opts(opts, key) when is_map(opts) do
    case Map.get(opts, key, []) do
      endpoint_opts when is_list(endpoint_opts) -> endpoint_opts
      _other -> []
    end
  end

  defp redundant_transport_opts(opts, key) when is_list(opts) do
    case Keyword.get(opts, key, []) do
      endpoint_opts when is_list(endpoint_opts) -> endpoint_opts
      _other -> []
    end
  end

  defp redundant_transport_opts(_opts, _key), do: []

  defp ip?(value) when is_tuple(value) do
    case tuple_size(value) do
      4 -> ipv4_tuple?(value)
      8 -> ipv6_tuple?(value)
      _other -> false
    end
  end

  defp ip?(_value), do: false

  defp ipv4_tuple?({a, b, c, d}) do
    Enum.all?([a, b, c, d], &byte?/1)
  end

  defp ipv6_tuple?({a, b, c, d, e, f, g, h}) do
    Enum.all?([a, b, c, d, e, f, g, h], &word?/1)
  end

  defp byte?(value), do: is_integer(value) and value >= 0 and value <= 0xFF
  defp word?(value), do: is_integer(value) and value >= 0 and value <= 0xFFFF
end
