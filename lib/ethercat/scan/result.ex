defmodule EtherCAT.Scan.Result do
  @moduledoc """
  Stable observational scan result for one backend probe.
  """

  alias EtherCAT.Backend

  @type discovered_slave :: %{
          position: non_neg_integer(),
          station: non_neg_integer(),
          identity: map() | nil,
          al_state: atom() | nil,
          al_status_raw: non_neg_integer() | nil,
          al_error?: boolean() | nil,
          al_status_code: non_neg_integer() | nil,
          topology: %{
            dl_status: binary() | nil,
            active_ports: [0 | 1 | 2 | 3]
          }
        }

  @type t :: %__MODULE__{
          backend: Backend.t(),
          topology: %{
            slave_count: non_neg_integer(),
            stations: [non_neg_integer()]
          },
          discovered_slaves: [discovered_slave()],
          al_states: %{optional(non_neg_integer()) => map()},
          observed_faults: [map()]
        }

  @enforce_keys [:backend]
  defstruct [
    :backend,
    topology: %{slave_count: 0, stations: []},
    discovered_slaves: [],
    al_states: %{},
    observed_faults: []
  ]
end
