defmodule EtherCAT.Master.Config.DomainPlan do
  @moduledoc false

  @type t :: %__MODULE__{
          id: atom(),
          cycle_time_us: pos_integer(),
          miss_threshold: pos_integer(),
          logical_base: non_neg_integer()
        }

  @enforce_keys [:id, :cycle_time_us, :miss_threshold, :logical_base]
  defstruct [:id, :cycle_time_us, :miss_threshold, :logical_base]
end
