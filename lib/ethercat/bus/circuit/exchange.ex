defmodule EtherCAT.Bus.Circuit.Exchange do
  @moduledoc """
  Immutable description of one bus exchange scheduled by `EtherCAT.Bus.FSM`.

  `Exchange` is the runtime value that a `Bus.Circuit` implementation
  will execute on the wire. It carries the encoded EtherCAT payload plus the
  decoded datagram list and the caller reply bookkeeping for one bus exchange.
  """

  alias EtherCAT.Bus.Datagram

  @type awaiting_t :: {:gen_statem.from(), [byte()]}
  @type tx_class_t :: :realtime | :reliable

  @enforce_keys [:idx, :payload, :datagrams, :awaiting, :tx_class, :tx_at]
  defstruct [
    :idx,
    :payload,
    :datagrams,
    :awaiting,
    :tx_class,
    :tx_at,
    :deadline_at,
    :payload_size,
    :datagram_count,
    :pending
  ]

  @type t :: %__MODULE__{
          idx: byte(),
          payload: binary(),
          datagrams: [Datagram.t()],
          awaiting: [awaiting_t()],
          tx_class: tx_class_t(),
          tx_at: integer(),
          deadline_at: integer() | nil,
          payload_size: non_neg_integer(),
          datagram_count: pos_integer(),
          pending: term()
        }

  @spec new(
          byte(),
          binary(),
          [Datagram.t()],
          [awaiting_t()],
          tx_class_t(),
          integer(),
          integer() | nil
        ) ::
          t()
  def new(idx, payload, datagrams, awaiting, tx_class, tx_at, deadline_at \\ nil)
      when is_integer(idx) and idx >= 0 and idx <= 255 and is_binary(payload) and
             is_list(datagrams) and datagrams != [] and is_list(awaiting) and
             tx_class in [:realtime, :reliable] and is_integer(tx_at) and
             (is_nil(deadline_at) or is_integer(deadline_at)) do
    %__MODULE__{
      idx: idx,
      payload: payload,
      datagrams: datagrams,
      awaiting: awaiting,
      tx_class: tx_class,
      tx_at: tx_at,
      deadline_at: deadline_at,
      payload_size: byte_size(payload),
      datagram_count: length(datagrams)
    }
  end

  @doc """
  Returns `true` when every expected datagram has a matching response with
  the same cmd, address, and data size.
  """
  @spec all_expected_present?(t(), [Datagram.t()]) :: boolean()
  def all_expected_present?(%__MODULE__{datagrams: expected}, response_datagrams) do
    response_by_idx = Map.new(response_datagrams, &{&1.idx, &1})

    length(expected) == length(response_datagrams) and
      Enum.all?(expected, fn expected_datagram ->
        case Map.fetch(response_by_idx, expected_datagram.idx) do
          {:ok, response_datagram} ->
            matching_response_shape?(expected_datagram, response_datagram)

          :error ->
            false
        end
      end)
  end

  defp matching_response_shape?(expected, response) do
    expected.cmd == response.cmd and
      byte_size(expected.data) == byte_size(response.data)
  end
end
