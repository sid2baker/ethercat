defmodule EtherCAT.Bus.Link.RedundantMerge do
  @moduledoc """
  Pure helpers for redundant exchange interpretation.

  Given sent datagrams and the replies from primary and secondary ports,
  classifies the rx pattern and merges both replies into a best-effort
  result with combined WKC.

  All functions are deterministic and side-effect free — the hardest
  redundant-path logic is testable without a live bus or transports.
  """

  alias EtherCAT.Bus.Datagram

  @type rx_kind_t :: :processed | :passthrough | :partial | :none | :invalid

  @type path_shape_t ::
          :single
          | :full_redundancy
          | :primary_only
          | :secondary_only
          | :complementary_partials
          | :no_valid_return
          | :invalid

  @type interpretation_t :: %{
          status: :ok | :partial | :timeout,
          redundancy: :full | :degraded | :none,
          path_shape: path_shape_t(),
          primary_rx_kind: rx_kind_t(),
          secondary_rx_kind: rx_kind_t(),
          datagrams: [Datagram.t()] | nil
        }

  @spec interpret([Datagram.t()], [Datagram.t()] | nil, [Datagram.t()] | nil) ::
          interpretation_t()
  def interpret(sent_datagrams, nil, nil) when is_list(sent_datagrams) do
    interpretation(:timeout, :none, :no_valid_return, :none, :none, nil)
  end

  def interpret(sent_datagrams, primary_datagrams, nil)
      when is_list(sent_datagrams) and is_list(primary_datagrams) do
    primary_rx_kind = classify_single_side(sent_datagrams, primary_datagrams)

    interpretation(
      single_side_status(primary_rx_kind),
      :degraded,
      :primary_only,
      primary_rx_kind,
      :none,
      primary_datagrams
    )
  end

  def interpret(sent_datagrams, nil, secondary_datagrams)
      when is_list(sent_datagrams) and is_list(secondary_datagrams) do
    secondary_rx_kind = classify_single_side(sent_datagrams, secondary_datagrams)

    interpretation(
      single_side_status(secondary_rx_kind),
      :degraded,
      :secondary_only,
      :none,
      secondary_rx_kind,
      secondary_datagrams
    )
  end

  def interpret(sent_datagrams, primary_datagrams, secondary_datagrams)
      when is_list(sent_datagrams) and is_list(primary_datagrams) and is_list(secondary_datagrams) do
    primary_passthrough? = passthrough_copy?(sent_datagrams, primary_datagrams)
    secondary_passthrough? = passthrough_copy?(sent_datagrams, secondary_datagrams)
    merged = merge_datagrams(sent_datagrams, primary_datagrams, secondary_datagrams)

    cond do
      primary_passthrough? and not secondary_passthrough? ->
        interpretation(
          :ok,
          :full,
          :full_redundancy,
          :passthrough,
          :processed,
          secondary_datagrams
        )

      secondary_passthrough? and not primary_passthrough? ->
        interpretation(:ok, :full, :full_redundancy, :processed, :passthrough, primary_datagrams)

      primary_passthrough? and secondary_passthrough? ->
        interpretation(
          :partial,
          :none,
          :no_valid_return,
          :passthrough,
          :passthrough,
          primary_datagrams
        )

      merged != primary_datagrams and merged != secondary_datagrams ->
        interpretation(:ok, :degraded, :complementary_partials, :partial, :partial, merged)

      primary_datagrams == secondary_datagrams ->
        interpretation(:ok, :full, :full_redundancy, :processed, :processed, primary_datagrams)

      total_wkc(secondary_datagrams) > total_wkc(primary_datagrams) ->
        interpretation(:ok, :full, :full_redundancy, :processed, :processed, secondary_datagrams)

      true ->
        interpretation(:ok, :full, :full_redundancy, :processed, :processed, primary_datagrams)
    end
  end

  defp interpretation(
         status,
         redundancy,
         path_shape,
         primary_rx_kind,
         secondary_rx_kind,
         datagrams
       ) do
    %{
      status: status,
      redundancy: redundancy,
      path_shape: path_shape,
      primary_rx_kind: primary_rx_kind,
      secondary_rx_kind: secondary_rx_kind,
      datagrams: datagrams
    }
  end

  defp classify_single_side(sent_datagrams, response_datagrams) do
    if passthrough_copy?(sent_datagrams, response_datagrams), do: :passthrough, else: :processed
  end

  defp single_side_status(:processed), do: :ok
  defp single_side_status(:passthrough), do: :partial

  @spec passthrough_copy?([Datagram.t()], [Datagram.t()]) :: boolean()
  defp passthrough_copy?(sent_datagrams, response_datagrams),
    do: sent_datagrams == response_datagrams

  @spec total_wkc([Datagram.t()]) :: non_neg_integer()
  defp total_wkc(datagrams),
    do: Enum.reduce(datagrams, 0, fn datagram, total -> total + datagram.wkc end)

  @doc """
  Merge two bounced replies from a broken ring.

  When both ports receive their own frame back (bounce-back), each side only
  processed the slaves reachable from that port. This function merges the
  complementary data using byte-level logical merge for commands 10/11/12.
  """
  @spec merge_bounces([Datagram.t()], [Datagram.t()], [Datagram.t()]) :: [Datagram.t()]
  def merge_bounces(sent_datagrams, primary_bounced, secondary_bounced) do
    merge_datagrams(sent_datagrams, primary_bounced, secondary_bounced)
  end

  @spec merge_datagrams([Datagram.t()], [Datagram.t()], [Datagram.t()]) :: [Datagram.t()]
  defp merge_datagrams(sent_datagrams, primary_datagrams, secondary_datagrams) do
    primary_by_idx = Map.new(primary_datagrams, &{&1.idx, &1})
    secondary_by_idx = Map.new(secondary_datagrams, &{&1.idx, &1})

    Enum.map(sent_datagrams, fn sent ->
      primary = Map.get(primary_by_idx, sent.idx)
      secondary = Map.get(secondary_by_idx, sent.idx)
      merge_datagram(sent, primary, secondary)
    end)
  end

  defp merge_datagram(sent, nil, nil), do: sent
  defp merge_datagram(_sent, primary, nil), do: primary
  defp merge_datagram(_sent, nil, secondary), do: secondary

  defp merge_datagram(sent, primary, secondary) do
    preferred = preferred_datagram(primary, secondary)

    %{
      preferred
      | data: merge_data(sent, primary, secondary, preferred),
        wkc: primary.wkc + secondary.wkc,
        circular: primary.circular or secondary.circular
    }
  end

  defp merge_data(
         %{cmd: cmd, data: sent_data},
         %{data: primary_data},
         %{data: secondary_data},
         _preferred
       )
       when cmd in [10, 11, 12] and
              byte_size(sent_data) == byte_size(primary_data) and
              byte_size(sent_data) == byte_size(secondary_data) do
    merge_logical_data(
      sent_data,
      primary_data,
      secondary_data,
      preferred_side(primary_data, secondary_data, sent_data)
    )
  end

  defp merge_data(_sent, _primary, _secondary, preferred), do: preferred.data

  defp merge_logical_data(<<>>, <<>>, <<>>, _preferred_side), do: <<>>

  defp merge_logical_data(
         <<sent_byte, sent_rest::binary>>,
         <<primary_byte, primary_rest::binary>>,
         <<secondary_byte, secondary_rest::binary>>,
         preferred_side
       ) do
    merged_byte =
      cond do
        primary_byte != sent_byte and secondary_byte == sent_byte ->
          primary_byte

        secondary_byte != sent_byte and primary_byte == sent_byte ->
          secondary_byte

        primary_byte != sent_byte and secondary_byte != sent_byte and
            primary_byte == secondary_byte ->
          primary_byte

        primary_byte != sent_byte and secondary_byte != sent_byte and preferred_side == :secondary ->
          secondary_byte

        primary_byte != sent_byte ->
          primary_byte

        secondary_byte != sent_byte ->
          secondary_byte

        true ->
          sent_byte
      end

    <<
      merged_byte,
      merge_logical_data(sent_rest, primary_rest, secondary_rest, preferred_side)::binary
    >>
  end

  defp preferred_side(primary_data, secondary_data, sent_data) do
    primary_changed? = primary_data != sent_data
    secondary_changed? = secondary_data != sent_data

    cond do
      primary_changed? and not secondary_changed? -> :primary
      secondary_changed? and not primary_changed? -> :secondary
      true -> :primary
    end
  end

  defp preferred_side(primary, secondary) do
    if secondary.wkc > primary.wkc, do: :secondary, else: :primary
  end

  defp preferred_datagram(primary, secondary) do
    if preferred_side(primary, secondary) == :secondary, do: secondary, else: primary
  end
end
