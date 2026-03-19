defmodule EtherCAT.Simulator.Transport do
  @moduledoc """
  Transport namespace for `EtherCAT.Simulator`.

  The simulator core owns EtherCAT datagram execution, slave state, topology,
  and transport-independent faults. Concrete transport runtimes such as UDP and
  raw Ethernet live under this namespace and expose any transport-edge fault
  surfaces that only make sense at that boundary.
  """
end
