defmodule EtherCAT.Simulator.Runtime.Topology do
  @moduledoc false

  @type ingress :: :primary | :secondary | nil
  @type t :: %{
          mode: :linear | :redundant,
          break_after: pos_integer() | nil,
          master_break: :primary | :secondary | nil
        }

  @spec linear() :: t()
  def linear do
    %{mode: :linear, break_after: nil, master_break: nil}
  end

  @spec normalize(term(), non_neg_integer()) :: {:ok, t()} | {:error, :invalid_topology}
  def normalize(nil, _slave_count), do: {:ok, linear()}
  def normalize(:linear, _slave_count), do: {:ok, linear()}
  def normalize(:redundant, slave_count), do: normalize({:redundant, []}, slave_count)

  def normalize({:redundant, opts}, slave_count) when is_list(opts) do
    break_after = Keyword.get(opts, :break_after)
    master_break = Keyword.get(opts, :master_break)

    if valid_break_after?(break_after, slave_count) and valid_master_break?(master_break) and
         compatible_breaks?(break_after, master_break) do
      {:ok, %{mode: :redundant, break_after: break_after, master_break: master_break}}
    else
      {:error, :invalid_topology}
    end
  end

  def normalize(_topology, _slave_count), do: {:error, :invalid_topology}

  @spec info(t()) :: map()
  def info(%{mode: :linear}), do: %{mode: :linear}

  def info(%{mode: :redundant, break_after: break_after, master_break: master_break}) do
    %{mode: :redundant, break_after: break_after}
    |> maybe_put_master_break(master_break)
  end

  @spec unreachable_slaves(t(), ingress(), [map()]) :: MapSet.t(atom())
  def unreachable_slaves(%{mode: :linear}, _ingress, _slaves), do: MapSet.new()

  def unreachable_slaves(%{mode: :redundant, master_break: :primary}, :primary, slaves),
    do: names(slaves)

  def unreachable_slaves(%{mode: :redundant, master_break: :primary}, :secondary, _slaves),
    do: MapSet.new()

  def unreachable_slaves(%{mode: :redundant, master_break: :secondary}, :secondary, slaves),
    do: names(slaves)

  def unreachable_slaves(%{mode: :redundant, master_break: :secondary}, ingress, _slaves)
      when ingress in [nil, :primary],
      do: MapSet.new()

  def unreachable_slaves(%{mode: :redundant, break_after: nil}, :secondary, slaves) do
    names(slaves)
  end

  def unreachable_slaves(%{mode: :redundant, break_after: nil}, ingress, _slaves)
      when ingress in [nil, :primary] do
    MapSet.new()
  end

  def unreachable_slaves(%{mode: :redundant, break_after: break_after}, ingress, slaves)
      when ingress in [nil, :primary] do
    slaves
    |> Enum.drop(break_after)
    |> names()
  end

  def unreachable_slaves(%{mode: :redundant, break_after: break_after}, :secondary, slaves) do
    slaves
    |> Enum.take(break_after)
    |> names()
  end

  @spec response_egress(t(), ingress()) :: ingress()
  def response_egress(%{mode: :linear}, ingress), do: ingress || :primary

  def response_egress(%{mode: :redundant, master_break: :primary}, :secondary), do: :secondary

  def response_egress(%{mode: :redundant, master_break: :primary}, ingress),
    do: ingress || :primary

  def response_egress(%{mode: :redundant, master_break: :secondary}, :primary), do: :primary
  def response_egress(%{mode: :redundant, master_break: :secondary}, :secondary), do: :secondary
  def response_egress(%{mode: :redundant, master_break: :secondary}, nil), do: :primary

  def response_egress(%{mode: :redundant, break_after: nil}, :primary), do: :secondary
  def response_egress(%{mode: :redundant, break_after: nil}, :secondary), do: :primary
  def response_egress(%{mode: :redundant, break_after: nil}, nil), do: :primary

  def response_egress(%{mode: :redundant}, ingress) when ingress in [:primary, :secondary],
    do: ingress

  def response_egress(%{mode: :redundant}, nil), do: :primary

  defp valid_break_after?(nil, _slave_count), do: true

  defp valid_break_after?(break_after, slave_count)
       when is_integer(break_after) and break_after >= 1 and break_after < slave_count,
       do: true

  defp valid_break_after?(_break_after, _slave_count), do: false

  defp valid_master_break?(master_break) when master_break in [nil, :primary, :secondary],
    do: true

  defp valid_master_break?(_master_break), do: false

  defp compatible_breaks?(nil, _master_break), do: true
  defp compatible_breaks?(_break_after, nil), do: true
  defp compatible_breaks?(_break_after, _master_break), do: false

  defp names(slaves) do
    MapSet.new(slaves, & &1.name)
  end

  defp maybe_put_master_break(info, nil), do: info
  defp maybe_put_master_break(info, master_break), do: Map.put(info, :master_break, master_break)
end
