defmodule EtherCAT.Sample do
  @moduledoc """
  Coherent decoded process-data observation for one slave within one domain cycle.

  A sample contains protocol truth only. It does not project machine state,
  advertise semantic commands, or infer completion of application intent.
  `inputs` contains only successfully decoded values. `errors` maps failed signal
  names to decoder reasons for this cycle; no previous or substitute value is
  retained for those signals.

  Samples from different domains do not share a consistency boundary. Input
  publication is change-driven; a sample is not emitted for every unchanged
  domain cycle. Retained samples can outlive healthy cycling, so consult
  `EtherCAT.status/2` or `EtherCAT.Diagnostics.domain_info/2` for current health
  rather than treating the sample timestamp alone as a heartbeat.

  `observed_at` is a host monotonic timestamp in microseconds, not wall-clock
  time or EtherCAT distributed-clock time. Compare it only within the same VM.
  """

  @enforce_keys [:slave, :domain, :cycle, :observed_at, :inputs]
  defstruct [:slave, :domain, :cycle, :observed_at, :inputs, errors: %{}]

  @type t :: %__MODULE__{
          slave: atom(),
          domain: atom(),
          cycle: non_neg_integer(),
          observed_at: integer(),
          inputs: %{optional(atom()) => term()},
          errors: %{optional(atom()) => term()}
        }
end
