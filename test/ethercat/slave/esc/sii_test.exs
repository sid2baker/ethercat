defmodule EtherCAT.Slave.ESC.SIITest do
  use ExUnit.Case, async: true

  alias EtherCAT.Slave.ESC.SII
  alias EtherCAT.TestSupport.FakeBus

  test "read_sm_configs returns an error for malformed SM category tails" do
    responses =
      eeprom_read_responses(<<0x0029::16-little, 1::16-little>>) ++
        eeprom_read_responses(<<0, 0>>)

    bus = start_supervised!({FakeBus, responses: responses})

    assert {:error, :malformed_sm_category} = SII.read_sm_configs(bus, 0x1000)
  end

  test "read_pdo_configs returns an error for malformed PDO category headers" do
    responses =
      eeprom_read_responses(<<0x0032::16-little, 1::16-little>>) ++
        eeprom_read_responses(<<0, 0>>)

    bus = start_supervised!({FakeBus, responses: responses})

    assert {:error, :malformed_pdo_category} = SII.read_pdo_configs(bus, 0x1000)
  end

  test "read_pdo_configs tolerates under-reported PDO entry data" do
    pdo_header = <<0x1A00::16-little, 1::8, 3::8, 0::8, 0::8, 0::16-little>>

    responses =
      eeprom_read_responses(<<0x0032::16-little, 4::16-little>>) ++
        eeprom_read_responses(pdo_header) ++
        eeprom_read_responses(<<0xFFFF::16-little, 0::16-little>>)

    bus = start_supervised!({FakeBus, responses: responses})

    assert {:ok,
            [
              %{
                index: 0x1A00,
                direction: :input,
                sm_index: 3,
                bit_size: 0,
                bit_offset: 0
              }
            ]} = SII.read_pdo_configs(bus, 0x1000)
  end

  defp eeprom_read_responses(data) do
    [
      ok_data(<<1, 0>>),
      ok_data(<<0, 0>>),
      ok_data(<<0, 0>>),
      ok_wkc(),
      ok_wkc(),
      ok_data(<<0, 0>>),
      ok_data(<<0, 0>>),
      ok_data(data)
    ]
  end

  defp ok_data(data), do: {:ok, [%{data: data, wkc: 1, circular: false, irq: 0}]}
  defp ok_wkc, do: {:ok, [%{data: <<>>, wkc: 1, circular: false, irq: 0}]}
end
