defmodule EtherCAT.Driver.CatalogueExampleTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Driver.{CatalogueExample, PDO, Runtime, Signal}
  alias EtherCAT.Endpoint
  alias EtherCAT.Slave.ProcessData.Plan

  # A baseline with separately maintained declaration callbacks. Codec forwarding
  # deliberately keeps this comparison about declarations, not codec code length.
  defmodule SeparateDeclarations do
    @behaviour EtherCAT.Driver

    @impl true
    def signal_model(config, _pdos) do
      base = [
        controlword: Signal.slice(0x1600, 0, 16),
        target_position: Signal.slice(0x1600, 16, 32),
        statusword: Signal.slice(0x1A00, 0, 16),
        actual_position: Signal.slice(0x1A00, 16, 32)
      ]

      if Map.get(config, :diagnostics?, false) do
        base ++ [temperature: Signal.slice(0x1A01, 0, 16)]
      else
        base
      end
    end

    @impl true
    def describe(config) do
      base = [
        %Endpoint{signal: :controlword, direction: :output, type: :u16},
        %Endpoint{signal: :target_position, direction: :output, type: :i32},
        %Endpoint{signal: :statusword, direction: :input, type: :u16},
        %Endpoint{signal: :actual_position, direction: :input, type: :i32}
      ]

      endpoints =
        if Map.get(config, :diagnostics?, false) do
          base ++ [%Endpoint{signal: :temperature, direction: :input, type: :i16}]
        else
          base
        end

      %{device_type: :positioning_device, endpoints: endpoints}
    end

    @impl true
    defdelegate encode_signal(signal, config, value), to: CatalogueExample

    @impl true
    defdelegate decode_signal(signal, config, raw), to: CatalogueExample
  end

  test "a shared catalogue preserves the separate declarations in both configurations" do
    for config <- [%{}, %{diagnostics?: false}, %{diagnostics?: true}] do
      assert Runtime.signal_model(CatalogueExample, config, pdos(config)) ==
               Runtime.signal_model(SeparateDeclarations, config, pdos(config))

      assert Runtime.describe(CatalogueExample, config) ==
               Runtime.describe(SeparateDeclarations, config)
    end
  end

  test "one configuration switch adds the signal to mapping, offline metadata, and decoding" do
    base = Runtime.describe(CatalogueExample, %{})
    extended = Runtime.describe(CatalogueExample, %{diagnostics?: true})

    assert Enum.map(base.endpoints, & &1.signal) ==
             [:controlword, :target_position, :statusword, :actual_position]

    assert extended.endpoints ==
             base.endpoints ++ [%Endpoint{signal: :temperature, direction: :input, type: :i16}]

    # No PDO discovery or bus is needed for either view of this known device.
    assert CatalogueExample.signal_model(%{diagnostics?: true}, []) ==
             CatalogueExample.signal_model(%{}, []) ++
               [temperature: Signal.slice(0x1A01, 0, 16)]

    assert {:error, :unknown_signal} = CatalogueExample.decode_signal(:temperature, %{}, <<0, 0>>)

    assert {:ok, -1200} =
             CatalogueExample.decode_signal(:temperature, %{diagnostics?: true}, <<80, 251>>)
  end

  test "the real planner resolves mixed fields and PDO-relative offsets in both configurations" do
    for config <- [%{}, %{diagnostics?: true}] do
      assert {:ok, [output, input] = groups} = plan(config, pdos(config))
      assert :ok = Runtime.validate_codecs(CatalogueExample, groups)
      assert output.direction == :output
      assert output.total_sm_size == 6

      assert [%{registrations: output_signals}] = output.attachments

      assert output_signals == [
               %{signal_name: :controlword, bit_offset: 0, bit_size: 16},
               %{signal_name: :target_position, bit_offset: 16, bit_size: 32}
             ]

      assert input.direction == :input
      assert [%{registrations: input_signals}] = input.attachments

      expected_inputs = [
        %{signal_name: :statusword, bit_offset: 0, bit_size: 16},
        %{signal_name: :actual_position, bit_offset: 16, bit_size: 32}
      ]

      if Map.get(config, :diagnostics?, false) do
        assert input.total_sm_size == 8

        # Temperature starts at bit 0 of its PDO, but bit 48 of the input SM.
        assert input_signals ==
                 expected_inputs ++ [%{signal_name: :temperature, bit_offset: 48, bit_size: 16}]
      else
        assert input.total_sm_size == 6
        assert input_signals == expected_inputs
      end

      descriptions =
        Map.new(Runtime.describe(CatalogueExample, config).endpoints, &{&1.signal, &1})

      for group <- groups,
          attachment <- group.attachments,
          registration <- attachment.registrations do
        assert descriptions[registration.signal_name].direction == group.direction
      end
    end
  end

  test "an enabled but undiscovered diagnostic PDO stays a visible planning error" do
    assert {:ok, _groups} = plan(%{}, pdos(%{}))

    assert {:error, {:pdo_not_in_sii, 0x1A01}} =
             plan(%{diagnostics?: true}, pdos(%{}))
  end

  test "a discovered PDO that is too short is rejected rather than truncating a field" do
    [output | inputs] = pdos(%{})

    assert {:error, {:signal_range_out_of_bounds, :target_position, 0x1600}} =
             plan(%{}, [%{output | bit_size: 32} | inputs])
  end

  test "scalar codecs preserve little-endian signed values and integer boundaries" do
    for {value, raw} <- [{0, <<0, 0>>}, {65_535, <<255, 255>>}, {0x1234, <<52, 18>>}] do
      assert {:ok, ^raw} = Runtime.encode(CatalogueExample, :controlword, %{}, value, 16)
      assert {:ok, ^value} = Runtime.decode(CatalogueExample, :statusword, %{}, raw)
    end

    for {value, raw} <- [
          {-2_147_483_648, <<0, 0, 0, 128>>},
          {2_147_483_647, <<255, 255, 255, 127>>},
          {-1200, <<80, 251, 255, 255>>},
          {0, <<0, 0, 0, 0>>}
        ] do
      assert {:ok, ^raw} = Runtime.encode(CatalogueExample, :target_position, %{}, value, 32)
      assert {:ok, ^value} = Runtime.decode(CatalogueExample, :actual_position, %{}, raw)
    end

    for {value, raw} <- [{-32_768, <<0, 128>>}, {32_767, <<255, 127>>}] do
      assert {:ok, ^value} =
               Runtime.decode(CatalogueExample, :temperature, %{diagnostics?: true}, raw)
    end
  end

  test "invalid values, malformed bytes, unknown signals, and wrong directions remain errors" do
    for value <- [-1, 65_536, 1.5, true, <<0, 0>>] do
      assert {:error, {:encode_failed, :controlword, :invalid_value}} =
               Runtime.encode(CatalogueExample, :controlword, %{}, value, 16)
    end

    for value <- [-2_147_483_649, 2_147_483_648, 1.5] do
      assert {:error, {:encode_failed, :target_position, :invalid_value}} =
               Runtime.encode(CatalogueExample, :target_position, %{}, value, 32)
    end

    for raw <- [<<>>, <<0>>, <<0, 0, 0>>, <<0, 0, 0, 0, 0>>, :not_binary] do
      assert {:error, {:decode_failed, :actual_position, :invalid_data}} =
               Runtime.decode(CatalogueExample, :actual_position, %{}, raw)
    end

    assert {:error, :unknown_signal} = CatalogueExample.encode_signal(:missing, %{}, 1)
    assert {:error, :unknown_signal} = CatalogueExample.decode_signal(:missing, %{}, <<0, 0>>)
    assert {:error, :wrong_direction} = CatalogueExample.encode_signal(:statusword, %{}, 1)

    assert {:error, :wrong_direction} =
             CatalogueExample.decode_signal(:controlword, %{}, <<0, 0>>)
  end

  defp plan(config, discovered_pdos) do
    with {:ok, requested} <-
           Plan.normalize_request({:all, :main}, CatalogueExample, config, discovered_pdos) do
      model = Runtime.signal_model(CatalogueExample, config, discovered_pdos)
      Plan.build(requested, model, discovered_pdos, [{2, 0x1100, 6, 0x64}, {3, 0x1180, 8, 0x20}])
    end
  end

  defp pdos(config) do
    base = [
      %PDO{index: 0x1600, direction: :output, sm_index: 2, bit_offset: 0, bit_size: 48},
      %PDO{index: 0x1A00, direction: :input, sm_index: 3, bit_offset: 0, bit_size: 48}
    ]

    if Map.get(config, :diagnostics?, false) do
      base ++ [%PDO{index: 0x1A01, direction: :input, sm_index: 3, bit_offset: 48, bit_size: 16}]
    else
      base
    end
  end
end
