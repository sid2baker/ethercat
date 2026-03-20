defmodule EtherCAT.Snapshot do
  @moduledoc """
  Public driver-backed aggregate snapshot for the current EtherCAT session.
  """

  alias EtherCAT.SlaveSnapshot

  @enforce_keys [:slaves]
  defstruct cycle: nil, slaves: %{}, updated_at_us: nil

  @type t :: %__MODULE__{
          cycle: integer() | nil,
          slaves: %{optional(atom()) => SlaveSnapshot.t()},
          updated_at_us: integer() | nil
        }

  @spec from_slaves(integer() | nil, %{optional(atom()) => SlaveSnapshot.t()}) :: t()
  def from_slaves(cycle, slaves) when is_map(slaves) do
    %__MODULE__{
      cycle: cycle,
      slaves: slaves,
      updated_at_us: project_updated_at_us(slaves)
    }
  end

  defp project_updated_at_us(slaves) do
    slaves
    |> Map.values()
    |> Enum.reduce([], fn
      %SlaveSnapshot{updated_at_us: updated_at_us}, acc when is_integer(updated_at_us) ->
        [updated_at_us | acc]

      _snapshot, acc ->
        acc
    end)
    |> case do
      [] -> nil
      timestamps -> Enum.max(timestamps)
    end
  end
end
