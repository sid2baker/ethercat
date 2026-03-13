defmodule EtherCAT.Simulator.Runtime.Topology do
  @moduledoc false

  @type ingress :: :primary | :secondary | nil
  @type t :: %{
          mode: :linear | :redundant,
          break_after: pos_integer() | nil
        }

  @spec linear() :: t()
  def linear do
    %{mode: :linear, break_after: nil}
  end

  @spec normalize(term(), non_neg_integer()) :: {:ok, t()} | {:error, :invalid_topology}
  def normalize(nil, _slave_count), do: {:ok, linear()}
  def normalize(:linear, _slave_count), do: {:ok, linear()}
  def normalize(:redundant, slave_count), do: normalize({:redundant, []}, slave_count)

  def normalize({:redundant, opts}, slave_count) when is_list(opts) do
    break_after = Keyword.get(opts, :break_after)

    if valid_break_after?(break_after, slave_count) do
      {:ok, %{mode: :redundant, break_after: break_after}}
    else
      {:error, :invalid_topology}
    end
  end

  def normalize(_topology, _slave_count), do: {:error, :invalid_topology}

  @spec info(t()) :: map()
  def info(%{mode: :linear}), do: %{mode: :linear}

  def info(%{mode: :redundant, break_after: break_after}),
    do: %{mode: :redundant, break_after: break_after}

  @spec unreachable_slaves(t(), ingress(), [map()]) :: MapSet.t(atom())
  def unreachable_slaves(%{mode: :linear}, _ingress, _slaves), do: MapSet.new()

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

  defp valid_break_after?(nil, _slave_count), do: true

  defp valid_break_after?(break_after, slave_count)
       when is_integer(break_after) and break_after >= 1 and break_after < slave_count,
       do: true

  defp valid_break_after?(_break_after, _slave_count), do: false

  defp names(slaves) do
    MapSet.new(slaves, & &1.name)
  end
end
