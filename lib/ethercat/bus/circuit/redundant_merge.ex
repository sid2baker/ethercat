defmodule EtherCAT.Bus.Circuit.RedundantMerge do
  @moduledoc """
  Pure helpers for redundant exchange interpretation.

  This module is the future home for:

  - per-port return classification
  - path-shape inference
  - complementary-partial merge logic

  Keeping those helpers pure makes the hardest redundant-path logic testable
  without involving a live bus or transports.
  """

  alias EtherCAT.Bus.Datagram
  alias EtherCAT.Bus.Observation

  @type interpretation_t :: %{
          status: :ok | :partial | :timeout,
          redundancy: :full | :degraded | :none,
          path_shape: Observation.path_shape_t(),
          primary_rx_kind: Observation.rx_kind_t(),
          secondary_rx_kind: Observation.rx_kind_t(),
          datagrams: [Datagram.t()] | nil
        }

  @spec classify_path_shape(Observation.port_observation_t(), Observation.port_observation_t()) ::
          Observation.path_shape_t()
  def classify_path_shape(primary, secondary) when is_map(primary) and is_map(secondary) do
    do_classify(primary.rx_kind, secondary.rx_kind)
  end

  @spec interpret([Datagram.t()], [Datagram.t()] | nil, [Datagram.t()] | nil) ::
          interpretation_t()
  def interpret(sent_datagrams, nil, nil) when is_list(sent_datagrams) do
    %{
      status: :timeout,
      redundancy: :none,
      path_shape: :no_valid_return,
      primary_rx_kind: :none,
      secondary_rx_kind: :none,
      datagrams: nil
    }
  end

  def interpret(sent_datagrams, primary_datagrams, nil)
      when is_list(sent_datagrams) and is_list(primary_datagrams) do
    primary_rx_kind = classify_single_side(sent_datagrams, primary_datagrams)

    %{
      status: single_side_status(primary_rx_kind),
      redundancy: :degraded,
      path_shape: :primary_only,
      primary_rx_kind: primary_rx_kind,
      secondary_rx_kind: :none,
      datagrams: primary_datagrams
    }
  end

  def interpret(sent_datagrams, nil, secondary_datagrams)
      when is_list(sent_datagrams) and is_list(secondary_datagrams) do
    secondary_rx_kind = classify_single_side(sent_datagrams, secondary_datagrams)

    %{
      status: single_side_status(secondary_rx_kind),
      redundancy: :degraded,
      path_shape: :secondary_only,
      primary_rx_kind: :none,
      secondary_rx_kind: secondary_rx_kind,
      datagrams: secondary_datagrams
    }
  end

  def interpret(sent_datagrams, primary_datagrams, secondary_datagrams)
      when is_list(sent_datagrams) and is_list(primary_datagrams) and is_list(secondary_datagrams) do
    primary_passthrough? = passthrough_copy?(sent_datagrams, primary_datagrams)
    secondary_passthrough? = passthrough_copy?(sent_datagrams, secondary_datagrams)
    merged = merge_datagrams(sent_datagrams, primary_datagrams, secondary_datagrams)

    cond do
      primary_passthrough? and not secondary_passthrough? ->
        %{
          status: :ok,
          redundancy: :full,
          path_shape: :full_redundancy,
          primary_rx_kind: :passthrough,
          secondary_rx_kind: :processed,
          datagrams: secondary_datagrams
        }

      secondary_passthrough? and not primary_passthrough? ->
        %{
          status: :ok,
          redundancy: :full,
          path_shape: :full_redundancy,
          primary_rx_kind: :processed,
          secondary_rx_kind: :passthrough,
          datagrams: primary_datagrams
        }

      primary_passthrough? and secondary_passthrough? ->
        %{
          status: :partial,
          redundancy: :none,
          path_shape: :no_valid_return,
          primary_rx_kind: :passthrough,
          secondary_rx_kind: :passthrough,
          datagrams: primary_datagrams
        }

      merged != primary_datagrams and merged != secondary_datagrams ->
        %{
          status: :ok,
          redundancy: :degraded,
          path_shape: :complementary_partials,
          primary_rx_kind: :partial,
          secondary_rx_kind: :partial,
          datagrams: merged
        }

      primary_datagrams == secondary_datagrams ->
        %{
          status: :ok,
          redundancy: :full,
          path_shape: :full_redundancy,
          primary_rx_kind: :processed,
          secondary_rx_kind: :processed,
          datagrams: primary_datagrams
        }

      total_wkc(secondary_datagrams) > total_wkc(primary_datagrams) ->
        %{
          status: :ok,
          redundancy: :full,
          path_shape: :full_redundancy,
          primary_rx_kind: :processed,
          secondary_rx_kind: :processed,
          datagrams: secondary_datagrams
        }

      true ->
        %{
          status: :ok,
          redundancy: :full,
          path_shape: :full_redundancy,
          primary_rx_kind: :processed,
          secondary_rx_kind: :processed,
          datagrams: primary_datagrams
        }
    end
  end

  defp do_classify(:processed, :passthrough), do: :full_redundancy
  defp do_classify(:passthrough, :processed), do: :full_redundancy
  defp do_classify(:partial, :partial), do: :complementary_partials
  defp do_classify(:processed, :none), do: :primary_only
  defp do_classify(:none, :processed), do: :secondary_only
  defp do_classify(:partial, :none), do: :primary_only
  defp do_classify(:none, :partial), do: :secondary_only
  defp do_classify(:none, :none), do: :no_valid_return
  defp do_classify(:invalid, :none), do: :invalid
  defp do_classify(:none, :invalid), do: :invalid
  defp do_classify(:invalid, :invalid), do: :invalid
  defp do_classify(:processed, :processed), do: :full_redundancy
  defp do_classify(_primary, _secondary), do: :invalid

  defp classify_single_side(sent_datagrams, response_datagrams) do
    if passthrough_copy?(sent_datagrams, response_datagrams), do: :passthrough, else: :processed
  end

  defp single_side_status(:processed), do: :ok
  defp single_side_status(:passthrough), do: :partial

  @spec passthrough_copy?([Datagram.t()], [Datagram.t()]) :: boolean()
  defp passthrough_copy?(sent_datagrams, response_datagrams),
    do: sent_datagrams == response_datagrams

  @spec total_wkc([Datagram.t()]) :: non_neg_integer()
  defp total_wkc(datagrams), do: Enum.sum(Enum.map(datagrams, & &1.wkc))

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
