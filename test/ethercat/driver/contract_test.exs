defmodule EtherCAT.Driver.ContractTest do
  use ExUnit.Case, async: true
  alias EtherCAT.Driver.{PDO, Runtime, Signal}

  defmodule InputOnly do
    @behaviour EtherCAT.Driver
    @impl true
    def signal_model(_config, [%PDO{index: index}]), do: [input: %Signal{pdo_index: index}]
    @impl true
    def decode_signal(_signal, _config, raw), do: {:ok, raw}
  end

  test "runtime supplies public PDO structs" do
    pdo = %{index: 0x1A00, direction: :input, sm_index: 3, bit_offset: 0, bit_size: 1}
    assert [input: %Signal{pdo_index: 0x1A00}] = Runtime.signal_model(InputOnly, %{}, [pdo])
  end

  test "only codecs needed by configured directions are required" do
    assert :ok = Runtime.validate_codecs(InputOnly, [])
    assert :ok = Runtime.validate_codecs(InputOnly, [%{direction: :input}])

    assert {:error, {:missing_driver_callback, :encode_signal, 3}} =
             Runtime.validate_codecs(InputOnly, [%{direction: :output}])
  end

  test "byte width and high padding bits are validated before staging" do
    driver = EtherCAT.Driver.Default
    assert {:ok, <<255, 1>>} = Runtime.encode(driver, :value, %{}, <<255, 1>>, 9)

    assert {:error, {:encode_failed, :value, :nonzero_padding}} =
             Runtime.encode(driver, :value, %{}, <<255, 2>>, 9)

    assert {:error, {:encode_failed, :value, {:invalid_encoded_size, 2, 1}}} =
             Runtime.encode(driver, :value, %{}, <<1>>, 9)

    assert {:ok, <<255, 255>>} = Runtime.encode(driver, :value, %{}, <<255, 255>>, 16)
  end

  test "PREOP rejects missing codecs before any process image registration" do
    data = %EtherCAT.Slave{
      name: :missing_codec,
      driver: InputOnly,
      config: %{},
      process_data_request: [input: :main],
      sii_pdo_configs: [
        %{index: 0x1600, direction: :output, sm_index: 2, bit_offset: 0, bit_size: 8}
      ],
      sii_sm_configs: [{2, 0x1100, 1, 0x64}]
    }

    configured = EtherCAT.Slave.ProcessData.configure_preop(data, run_mailbox_config: &{:ok, &1})
    assert configured.configuration_error == {:missing_driver_callback, :encode_signal, 3}
    assert configured.signal_registrations == data.signal_registrations
  end
end
