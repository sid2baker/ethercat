defmodule EtherCAT.Simulator.Slave.Signals do
  @moduledoc false

  @type definition :: %{
          required(:direction) => :input | :output,
          required(:pdo_index) => non_neg_integer(),
          required(:bit_offset) => non_neg_integer(),
          required(:bit_size) => pos_integer(),
          required(:type) => atom() | tuple(),
          optional(:unit) => binary(),
          optional(:scale) => number(),
          optional(:offset) => number(),
          optional(:label) => binary(),
          optional(:group) => atom()
        }

  @spec names(%{optional(atom()) => definition()}) :: [atom()]
  def names(definitions), do: Map.keys(definitions)

  @spec fetch(%{optional(atom()) => definition()}, atom()) :: {:ok, definition()} | :error
  def fetch(definitions, signal_name), do: Map.fetch(definitions, signal_name)
end
