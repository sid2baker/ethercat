defmodule EtherCAT.Slave.ProcessData.PlanTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Slave.ProcessData.Plan
  alias EtherCAT.Slave.ProcessData.Plan.DomainAttachment
  alias EtherCAT.Slave.ProcessData.Signal

  defmodule TestDriver do
    @behaviour EtherCAT.Slave.Driver

    @impl true
    def identity, do: nil

    @impl true
    def signal_model(_config) do
      [
        out1: 0x1600,
        in1: 0x1A00,
        in2: 0x1A01,
        status_word: Signal.slice(0x1A02, 0, 16),
        actual_position: Signal.slice(0x1A02, 16, 32)
      ]
    end

    @impl true
    def encode_signal(_signal, _config, _value), do: <<>>

    @impl true
    def decode_signal(_signal, _config, raw), do: raw
  end

  test "normalizes :none and {:all, domain} requests" do
    assert {:ok, []} = Plan.normalize_request(:none, TestDriver, %{}, [])

    assert {:ok,
            [out1: :main, in1: :main, in2: :main, status_word: :main, actual_position: :main]} =
             Plan.normalize_request({:all, :main}, TestDriver, %{}, [])
  end

  test "rejects invalid process_data requests" do
    assert {:error, :invalid_process_data_request} =
             Plan.normalize_request([{:bad, "main"}], TestDriver, %{}, [])

    assert {:error, :invalid_process_data_request} =
             Plan.normalize_request(:bad, TestDriver, %{}, [])
  end

  test "builds sync-manager groups from driver model and SII metadata" do
    requested = [out1: :main, in1: :main, in2: :main, status_word: :main, actual_position: :main]

    model = [
      out1: 0x1600,
      in1: 0x1A00,
      in2: 0x1A01,
      status_word: Signal.slice(0x1A02, 0, 16),
      actual_position: Signal.slice(0x1A02, 16, 32)
    ]

    sii_pdo_configs = [
      %{index: 0x1600, direction: :output, sm_index: 2, bit_size: 8, bit_offset: 0},
      %{index: 0x1A00, direction: :input, sm_index: 3, bit_size: 8, bit_offset: 0},
      %{index: 0x1A01, direction: :input, sm_index: 3, bit_size: 8, bit_offset: 8},
      %{index: 0x1A02, direction: :input, sm_index: 3, bit_size: 48, bit_offset: 16}
    ]

    sii_sm_configs = [
      {2, 0x1000, 1, 0x64},
      {3, 0x1100, 2, 0x20}
    ]

    assert {:ok, [output_group, input_group]} =
             Plan.build(requested, model, sii_pdo_configs, sii_sm_configs)

    assert output_group.sm_index == 2
    assert output_group.direction == :output
    assert output_group.total_sm_size == 1
    assert output_group.fmmu_type == 0x02

    assert [
             %DomainAttachment{
               domain_id: :main,
               registrations: [%{signal_name: :out1, bit_offset: 0, bit_size: 8}]
             }
           ] = output_group.attachments

    assert input_group.sm_index == 3
    assert input_group.direction == :input
    assert input_group.total_sm_size == 8
    assert input_group.fmmu_type == 0x01

    assert [
             %DomainAttachment{
               domain_id: :main,
               registrations: [
                 %{signal_name: :in1, bit_offset: 0, bit_size: 8},
                 %{signal_name: :in2, bit_offset: 8, bit_size: 8},
                 %{signal_name: :status_word, bit_offset: 16, bit_size: 16},
                 %{signal_name: :actual_position, bit_offset: 32, bit_size: 32}
               ]
             }
           ] = input_group.attachments
  end

  test "returns explicit planning errors" do
    sii_pdo_configs = [
      %{index: 0x1600, direction: :output, sm_index: 2, bit_size: 8, bit_offset: 0}
    ]

    sii_sm_configs = [{2, 0x1000, 1, 0x64}]

    assert {:error, {:signal_not_in_driver_model, :missing}} =
             Plan.build(
               [missing: :main],
               [out1: 0x1600],
               sii_pdo_configs,
               sii_sm_configs
             )

    assert {:error, {:pdo_not_in_sii, 0x1A00}} =
             Plan.build([in1: :main], [in1: 0x1A00], sii_pdo_configs, sii_sm_configs)

    assert {:error, {:sm_not_in_sii, 3}} =
             Plan.build(
               [in1: :main],
               [in1: 0x1A00],
               [%{index: 0x1A00, direction: :input, sm_index: 3, bit_size: 8, bit_offset: 0}],
               sii_sm_configs
             )
  end

  test "rejects out-of-bounds signal slices and allows split input and output SMs" do
    sii_pdo_configs = [
      %{index: 0x1A00, direction: :input, sm_index: 3, bit_size: 16, bit_offset: 0},
      %{index: 0x1A01, direction: :input, sm_index: 3, bit_size: 16, bit_offset: 16}
    ]

    sii_sm_configs = [{3, 0x1100, 4, 0x20}]

    assert {:error, {:signal_range_out_of_bounds, :too_big, 0x1A00}} =
             Plan.build(
               [too_big: :main],
               [too_big: Signal.slice(0x1A00, 8, 16)],
               sii_pdo_configs,
               sii_sm_configs
             )

    assert {:ok, [input_group]} =
             Plan.build(
               [first: :main, second: :aux],
               [first: 0x1A00, second: 0x1A01],
               sii_pdo_configs,
               sii_sm_configs
             )

    assert input_group.sm_index == 3

    assert [
             %DomainAttachment{
               domain_id: :aux,
               registrations: [%{signal_name: :second, bit_offset: 16, bit_size: 16}]
             },
             %DomainAttachment{
               domain_id: :main,
               registrations: [%{signal_name: :first, bit_offset: 0, bit_size: 16}]
             }
           ] = input_group.attachments

    output_pdo_configs = [
      %{index: 0x1600, direction: :output, sm_index: 2, bit_size: 8, bit_offset: 0},
      %{index: 0x1601, direction: :output, sm_index: 2, bit_size: 8, bit_offset: 8}
    ]

    output_sm_configs = [{2, 0x1000, 2, 0x64}]

    assert {:ok, [output_group]} =
             Plan.build(
               [first: :main, second: :aux],
               [first: 0x1600, second: 0x1601],
               output_pdo_configs,
               output_sm_configs
             )

    assert output_group.sm_index == 2

    assert [
             %DomainAttachment{
               domain_id: :aux,
               registrations: [%{signal_name: :second, bit_offset: 8, bit_size: 8}]
             },
             %DomainAttachment{
               domain_id: :main,
               registrations: [%{signal_name: :first, bit_offset: 0, bit_size: 8}]
             }
           ] = output_group.attachments
  end
end
