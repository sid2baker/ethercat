defmodule EtherCAT.Bus.Observation do
  @moduledoc """
  Per-exchange truth observed on the wire.

  `Observation` is intentionally narrower than a public bus health report. It
  records what one exchange actually did and what came back on each port. A
  higher layer can smooth multiple observations into a public topology/fault
  assessment.
  """

  @type status_t :: :ok | :partial | :timeout | :transport_error | :invalid
  @type path_shape_t ::
          :single
          | :full_redundancy
          | :primary_only
          | :secondary_only
          | :complementary_partials
          | :no_valid_return
          | :invalid

  @type send_result_t :: :ok | {:error, term()} | :skipped
  @type rx_kind_t :: :processed | :passthrough | :partial | :none | :invalid

  @type port_observation_t :: %{
          sent?: boolean(),
          send_result: send_result_t(),
          rx_kind: rx_kind_t(),
          rx_payload: binary() | nil,
          rx_at: integer() | nil
        }

  @enforce_keys [:status, :path_shape, :primary, :secondary]
  defstruct [
    :status,
    :path_shape,
    :payload,
    :datagrams,
    :completed_at,
    :primary,
    :secondary
  ]

  @type t :: %__MODULE__{
          status: status_t(),
          path_shape: path_shape_t(),
          payload: binary() | nil,
          datagrams: [EtherCAT.Bus.Datagram.t()] | nil,
          completed_at: integer() | nil,
          primary: port_observation_t(),
          secondary: port_observation_t()
        }

  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    %__MODULE__{
      status: Keyword.fetch!(attrs, :status),
      path_shape: Keyword.fetch!(attrs, :path_shape),
      payload: Keyword.get(attrs, :payload),
      datagrams: Keyword.get(attrs, :datagrams),
      completed_at: Keyword.get(attrs, :completed_at),
      primary: Keyword.get(attrs, :primary, port()),
      secondary: Keyword.get(attrs, :secondary, port())
    }
  end

  @spec port(keyword()) :: port_observation_t()
  def port(attrs \\ []) when is_list(attrs) do
    %{
      sent?: Keyword.get(attrs, :sent?, false),
      send_result: Keyword.get(attrs, :send_result, :skipped),
      rx_kind: Keyword.get(attrs, :rx_kind, :none),
      rx_payload: Keyword.get(attrs, :rx_payload),
      rx_at: Keyword.get(attrs, :rx_at)
    }
  end
end
