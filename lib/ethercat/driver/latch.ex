defmodule EtherCAT.Driver.Latch do
  @moduledoc """
  Optional DC latch hook for drivers that need side effects from latch events.
  """

  alias EtherCAT.Driver

  @type latch_edge :: :pos | :neg

  @callback on_latch(atom(), Driver.config(), 0 | 1, latch_edge(), non_neg_integer()) :: :ok

  @spec on_latch(module(), atom(), Driver.config(), 0 | 1, latch_edge(), non_neg_integer()) ::
          :ok
  def on_latch(driver, slave_name, config, latch_id, edge, timestamp_ns)
      when is_atom(driver) and is_atom(slave_name) and is_map(config) and
             latch_id in [0, 1] and edge in [:pos, :neg] and is_integer(timestamp_ns) and
             timestamp_ns >= 0 do
    if exported?(driver, :on_latch, 5) do
      apply(driver, :on_latch, [slave_name, config, latch_id, edge, timestamp_ns])
    end

    :ok
  end

  defp exported?(module, function_name, arity)
       when is_atom(module) and is_atom(function_name) and is_integer(arity) and arity >= 0 do
    Code.ensure_loaded?(module) and function_exported?(module, function_name, arity)
  end
end
