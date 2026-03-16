defmodule EtherCAT.Bus.Circuit.Port do
  @moduledoc """
  One named transport instance plus local send/backoff state.

  `Port` is a future-friendly wrapper around the existing `Bus.Transport`
  implementations. It does not infer topology; it only owns one transport and
  local error throttling data.
  """

  @type id_t :: :primary | :secondary

  @type warmth_t :: :warm | :cold

  @enforce_keys [:id, :transport, :transport_mod]
  defstruct [
    :id,
    :transport,
    :transport_mod,
    warmth: :warm,
    send_backoff_until: nil,
    consecutive_send_errors: 0
  ]

  @type t :: %__MODULE__{
          id: id_t(),
          transport: term(),
          transport_mod: module(),
          warmth: warmth_t(),
          send_backoff_until: integer() | nil,
          consecutive_send_errors: non_neg_integer()
        }

  @spec open(id_t(), module(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(id, transport_mod, opts)
      when id in [:primary, :secondary] and is_atom(transport_mod) do
    case transport_mod.open(opts) do
      {:ok, transport} ->
        {:ok, %__MODULE__{id: id, transport: transport, transport_mod: transport_mod}}

      {:error, _reason} = error ->
        error
    end
  end

  @spec arm(t()) :: t()
  def arm(%__MODULE__{transport: transport, transport_mod: transport_mod} = port) do
    if transport_mod.open?(transport), do: transport_mod.set_active_once(transport)
    port
  end

  @spec drain(t()) :: t()
  def drain(%__MODULE__{transport: transport, transport_mod: transport_mod} = port) do
    if transport_mod.open?(transport), do: transport_mod.drain(transport)
    port
  end

  @spec rearm(t()) :: t()
  def rearm(%__MODULE__{transport: transport, transport_mod: transport_mod} = port) do
    if transport_mod.open?(transport), do: transport_mod.rearm(transport)
    port
  end

  @spec close(t()) :: t()
  def close(%__MODULE__{transport: transport, transport_mod: transport_mod} = port) do
    %{port | transport: transport_mod.close(transport)}
  end

  @spec usable?(t()) :: boolean()
  def usable?(%__MODULE__{transport: transport, transport_mod: transport_mod}) do
    transport_mod.open?(transport)
  end

  @spec interface(t()) :: String.t() | nil
  def interface(%__MODULE__{transport: transport, transport_mod: transport_mod}) do
    transport_mod.interface(transport)
  end

  @spec name(t()) :: String.t()
  def name(%__MODULE__{transport: transport, transport_mod: transport_mod}) do
    transport_mod.name(transport)
  end

  @spec cold?(t()) :: boolean()
  def cold?(%__MODULE__{warmth: :cold}), do: true
  def cold?(%__MODULE__{}), do: false

  @spec warm(t()) :: t()
  def warm(%__MODULE__{} = port), do: %{port | warmth: :warm}

  @spec src_mac(t()) :: binary() | nil
  def src_mac(%__MODULE__{transport: transport, transport_mod: transport_mod}) do
    transport_mod.src_mac(transport)
  end

  @spec backoff_active?(t(), integer()) :: boolean()
  def backoff_active?(%__MODULE__{send_backoff_until: nil}, _now_ms), do: false
  def backoff_active?(%__MODULE__{send_backoff_until: until_ms}, now_ms), do: now_ms < until_ms

  @spec clear_send_errors(t()) :: t()
  def clear_send_errors(%__MODULE__{} = port) do
    %{port | consecutive_send_errors: 0, send_backoff_until: nil}
  end

  @spec note_send_error(t(), integer(), non_neg_integer()) :: t()
  def note_send_error(%__MODULE__{} = port, now_ms, backoff_ms) when backoff_ms >= 0 do
    %{
      port
      | consecutive_send_errors: port.consecutive_send_errors + 1,
        send_backoff_until: if(backoff_ms > 0, do: now_ms + backoff_ms, else: nil)
    }
  end

  @spec info(t()) :: map()
  def info(%__MODULE__{} = port) do
    %{
      id: port.id,
      name: name(port),
      interface: interface(port),
      usable?: usable?(port),
      warmth: port.warmth,
      consecutive_send_errors: port.consecutive_send_errors,
      send_backoff_until: port.send_backoff_until
    }
  end
end
