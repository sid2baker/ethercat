defmodule EtherCAT.Bus.Assessment do
  @moduledoc """
  Smoothed public view derived from multiple bus observations.

  The intended policy is asymmetric:

  - degrade quickly from a single strong degraded observation
  - recover conservatively, requiring several consecutive healthy redundant
    observations before promoting back to `:redundant`

  This lets `Bus.info/1` expose a stable topology/fault summary without
  forcing the runtime to carry a separate healing state machine.
  """

  alias EtherCAT.Bus.Observation

  @recovery_confirmations 3

  @type topology_t ::
          :single
          | :redundant
          | :degraded_primary_leg
          | :degraded_secondary_leg
          | :segment_break
          | :unknown

  @type fault_kind_t :: :master_leg_fault | :segment_break | :transport_fault | :unknown
  @type confidence_t :: :certain | :high | :low

  @type fault_t :: %{
          kind: fault_kind_t(),
          port: :primary | :secondary | nil,
          confidence: confidence_t()
        }

  @type change_t :: :unchanged | {:changed, topology_t(), topology_t()}

  defstruct topology: :unknown,
            fault: nil,
            observed_at: nil,
            based_on: 0,
            last_path_shape: nil,
            last_status: nil,
            consecutive_redundant: 0

  @type t :: %__MODULE__{
          topology: topology_t(),
          fault: fault_t() | nil,
          observed_at: integer() | nil,
          based_on: non_neg_integer(),
          last_path_shape: Observation.path_shape_t() | nil,
          last_status: Observation.status_t() | nil,
          consecutive_redundant: non_neg_integer()
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec from_observation(Observation.t()) :: %{topology: topology_t(), fault: fault_t() | nil}
  def from_observation(%Observation{status: :transport_error} = observation) do
    %{
      topology: :unknown,
      fault: %{kind: :transport_fault, port: transport_fault_port(observation), confidence: :low}
    }
  end

  def from_observation(%Observation{path_shape: :single}), do: %{topology: :single, fault: nil}

  def from_observation(%Observation{path_shape: :full_redundancy}),
    do: %{topology: :redundant, fault: nil}

  def from_observation(%Observation{path_shape: :primary_only}) do
    %{
      topology: :degraded_secondary_leg,
      fault: %{kind: :master_leg_fault, port: :secondary, confidence: :high}
    }
  end

  def from_observation(%Observation{path_shape: :secondary_only}) do
    %{
      topology: :degraded_primary_leg,
      fault: %{kind: :master_leg_fault, port: :primary, confidence: :high}
    }
  end

  def from_observation(%Observation{path_shape: :complementary_partials}) do
    %{
      topology: :segment_break,
      fault: %{kind: :segment_break, port: nil, confidence: :high}
    }
  end

  def from_observation(%Observation{path_shape: :no_valid_return}) do
    %{
      topology: :unknown,
      fault: %{kind: :transport_fault, port: nil, confidence: :low}
    }
  end

  def from_observation(%Observation{path_shape: :invalid}) do
    %{
      topology: :unknown,
      fault: %{kind: :unknown, port: nil, confidence: :low}
    }
  end

  @spec advance(t(), Observation.t()) :: {t(), change_t()}
  def advance(%__MODULE__{} = assessment, %Observation{} = observation) do
    inferred = from_observation(observation)
    old_topology = assessment.topology

    assessment = %{
      assessment
      | observed_at: observation.completed_at,
        last_path_shape: observation.path_shape,
        last_status: observation.status
    }

    new_assessment =
      case {inferred.topology, observation.status} do
        {:redundant, _status} ->
          promote_redundant(assessment, inferred)

        {:unknown, :transport_error} ->
          note_transport_error(assessment, inferred)

        {:unknown, _status} ->
          retain_current(assessment, inferred)

        {topology, _status} ->
          %{
            assessment
            | topology: topology,
              fault: inferred.fault,
              based_on: 1,
              consecutive_redundant: 0
          }
      end

    change =
      if new_assessment.topology != old_topology do
        {:changed, old_topology, new_assessment.topology}
      else
        :unchanged
      end

    {new_assessment, change}
  end

  defp promote_redundant(%__MODULE__{topology: topology} = assessment, inferred)
       when topology in [:single, :redundant, :unknown] do
    %{
      assessment
      | topology: inferred.topology,
        fault: nil,
        based_on: assessment.based_on + 1,
        consecutive_redundant: assessment.consecutive_redundant + 1
    }
  end

  defp promote_redundant(%__MODULE__{} = assessment, _inferred) do
    consecutive = assessment.consecutive_redundant + 1

    if consecutive >= @recovery_confirmations do
      %{
        assessment
        | topology: :redundant,
          fault: nil,
          based_on: consecutive,
          consecutive_redundant: consecutive
      }
    else
      %{assessment | based_on: consecutive, consecutive_redundant: consecutive}
    end
  end

  defp retain_current(%__MODULE__{topology: :unknown} = assessment, inferred) do
    %{assessment | fault: inferred.fault, based_on: 1, consecutive_redundant: 0}
  end

  defp retain_current(%__MODULE__{} = assessment, _inferred) do
    %{assessment | consecutive_redundant: 0}
  end

  defp note_transport_error(%__MODULE__{topology: :unknown} = assessment, inferred) do
    %{
      assessment
      | fault: inferred.fault,
        based_on: max(assessment.based_on, 1),
        consecutive_redundant: 0
    }
  end

  defp note_transport_error(%__MODULE__{} = assessment, _inferred) do
    %{assessment | based_on: max(assessment.based_on, 1), consecutive_redundant: 0}
  end

  defp transport_fault_port(%Observation{} = observation) do
    case {send_error?(observation.primary), send_error?(observation.secondary)} do
      {true, false} -> :primary
      {false, true} -> :secondary
      _other -> nil
    end
  end

  defp send_error?(%{send_result: {:error, _reason}}), do: true
  defp send_error?(_port_observation), do: false
end
