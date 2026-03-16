defmodule EtherCAT.Bus.AssessmentTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Bus.{Assessment, Observation}

  test "maps one healthy redundant observation to redundant topology" do
    observation =
      Observation.new(
        status: :ok,
        path_shape: :full_redundancy,
        completed_at: 1,
        primary: Observation.port(sent?: true, send_result: :ok, rx_kind: :passthrough),
        secondary: Observation.port(sent?: true, send_result: :ok, rx_kind: :processed)
      )

    {assessment, change} = Assessment.advance(Assessment.new(), observation)

    assert change == {:changed, :unknown, :redundant}
    assert assessment.topology == :redundant
    assert assessment.fault == nil
    assert assessment.based_on == 1
    assert assessment.last_path_shape == :full_redundancy
  end

  test "degrades immediately on one strong one-sided observation" do
    {baseline, _} =
      Assessment.advance(
        Assessment.new(),
        Observation.new(
          status: :ok,
          path_shape: :full_redundancy,
          completed_at: 1,
          primary: Observation.port(sent?: true, send_result: :ok, rx_kind: :passthrough),
          secondary: Observation.port(sent?: true, send_result: :ok, rx_kind: :processed)
        )
      )

    {degraded, change} =
      Assessment.advance(
        baseline,
        Observation.new(
          status: :ok,
          path_shape: :secondary_only,
          completed_at: 2,
          primary: Observation.port(sent?: true, send_result: :ok, rx_kind: :none),
          secondary: Observation.port(sent?: true, send_result: :ok, rx_kind: :processed)
        )
      )

    assert change == {:changed, :redundant, :degraded_primary_leg}
    assert degraded.topology == :degraded_primary_leg
    assert degraded.fault == %{kind: :master_leg_fault, port: :primary, confidence: :high}
    assert degraded.based_on == 1
    assert degraded.consecutive_redundant == 0
  end

  test "requires repeated healthy observations before promoting back to redundant" do
    {degraded, _} =
      Assessment.advance(
        Assessment.new(),
        Observation.new(
          status: :ok,
          path_shape: :secondary_only,
          completed_at: 1,
          primary: Observation.port(sent?: true, send_result: :ok, rx_kind: :none),
          secondary: Observation.port(sent?: true, send_result: :ok, rx_kind: :processed)
        )
      )

    {recovering_1, change_1} =
      Assessment.advance(
        degraded,
        Observation.new(
          status: :ok,
          path_shape: :full_redundancy,
          completed_at: 2,
          primary: Observation.port(sent?: true, send_result: :ok, rx_kind: :passthrough),
          secondary: Observation.port(sent?: true, send_result: :ok, rx_kind: :processed)
        )
      )

    {recovering_2, change_2} =
      Assessment.advance(
        recovering_1,
        Observation.new(
          status: :ok,
          path_shape: :full_redundancy,
          completed_at: 3,
          primary: Observation.port(sent?: true, send_result: :ok, rx_kind: :passthrough),
          secondary: Observation.port(sent?: true, send_result: :ok, rx_kind: :processed)
        )
      )

    {recovered, change_3} =
      Assessment.advance(
        recovering_2,
        Observation.new(
          status: :ok,
          path_shape: :full_redundancy,
          completed_at: 4,
          primary: Observation.port(sent?: true, send_result: :ok, rx_kind: :passthrough),
          secondary: Observation.port(sent?: true, send_result: :ok, rx_kind: :processed)
        )
      )

    assert change_1 == :unchanged
    assert recovering_1.topology == :degraded_primary_leg
    assert recovering_1.consecutive_redundant == 1

    assert change_2 == :unchanged
    assert recovering_2.topology == :degraded_primary_leg
    assert recovering_2.consecutive_redundant == 2

    assert change_3 == {:changed, :degraded_primary_leg, :redundant}
    assert recovered.topology == :redundant
    assert recovered.fault == nil
    assert recovered.based_on == 3
  end

  test "maps complementary partials to a segment break assessment" do
    observation =
      Observation.new(
        status: :partial,
        path_shape: :complementary_partials,
        completed_at: 1,
        primary: Observation.port(sent?: true, send_result: :ok, rx_kind: :partial),
        secondary: Observation.port(sent?: true, send_result: :ok, rx_kind: :partial)
      )

    {assessment, _} = Assessment.advance(Assessment.new(), observation)

    assert assessment.topology == :segment_break
    assert assessment.fault == %{kind: :segment_break, port: nil, confidence: :high}
  end

  test "keeps the current degraded assessment through unknown observations" do
    {degraded, _} =
      Assessment.advance(
        Assessment.new(),
        Observation.new(
          status: :ok,
          path_shape: :primary_only,
          completed_at: 1,
          primary: Observation.port(sent?: true, send_result: :ok, rx_kind: :processed),
          secondary: Observation.port(sent?: true, send_result: :ok, rx_kind: :none)
        )
      )

    {unknown, change} =
      Assessment.advance(
        degraded,
        Observation.new(
          status: :timeout,
          path_shape: :no_valid_return,
          completed_at: 2,
          primary: Observation.port(sent?: true, send_result: :ok, rx_kind: :none),
          secondary: Observation.port(sent?: true, send_result: :ok, rx_kind: :none)
        )
      )

    assert change == :unchanged
    assert unknown.topology == :degraded_secondary_leg
    assert unknown.fault == %{kind: :master_leg_fault, port: :secondary, confidence: :high}
    assert unknown.last_status == :timeout
    assert unknown.consecutive_redundant == 0
  end

  test "keeps topology and fault assessment stable across transport_error observations" do
    {baseline, _} =
      Assessment.advance(
        Assessment.new(),
        Observation.new(
          status: :ok,
          path_shape: :single,
          completed_at: 1,
          primary: Observation.port(sent?: true, send_result: :ok, rx_kind: :processed),
          secondary: Observation.port()
        )
      )

    {failed, change} =
      Assessment.advance(
        baseline,
        Observation.new(
          status: :transport_error,
          path_shape: :no_valid_return,
          completed_at: 2,
          primary: Observation.port(),
          secondary: Observation.port()
        )
      )

    assert change == :unchanged
    assert failed.topology == :single
    assert failed.fault == nil
    assert failed.last_status == :transport_error
  end

  test "transport_error infers the failing port while topology is still unknown" do
    {failed, _} =
      Assessment.advance(
        Assessment.new(),
        Observation.new(
          status: :transport_error,
          path_shape: :no_valid_return,
          completed_at: 1,
          primary: Observation.port(sent?: true, send_result: {:error, :enetdown}),
          secondary: Observation.port(send_result: :skipped)
        )
      )

    assert failed.topology == :unknown
    assert failed.fault == %{kind: :transport_fault, port: :primary, confidence: :low}
    assert failed.last_status == :transport_error
  end
end
