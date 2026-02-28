defmodule Example.EL1809 do
  @behaviour EtherCAT.Slave.Driver

  @impl true
  def process_data_profile(_config) do
    %{
      ch1:  0x1A00, ch2:  0x1A01, ch3:  0x1A02, ch4:  0x1A03,
      ch5:  0x1A04, ch6:  0x1A05, ch7:  0x1A06, ch8:  0x1A07,
      ch9:  0x1A08, ch10: 0x1A09, ch11: 0x1A0A, ch12: 0x1A0B,
      ch13: 0x1A0C, ch14: 0x1A0D, ch15: 0x1A0E, ch16: 0x1A0F
    }
  end

  @impl true
  def encode_outputs(_pdo, _config, _), do: <<>>

  @impl true
  # 1-bit TxPDO: FMMU places the physical SM bit into logical bit 0 (LSB).
  def decode_inputs(_ch, _config, <<_::7, bit::1>>), do: bit
  def decode_inputs(_pdo, _config, _), do: 0
end

defmodule Example.EL2809 do
  @behaviour EtherCAT.Slave.Driver

  @impl true
  def process_data_profile(_config) do
    # SM0 (0x0F00): channels 1–8, SM1 (0x0F01): channels 9–16.
    # Each is a 1-bit RxPDO; master uses bit-level FMMUs to pack into SM bytes.
    %{
      ch1:  0x1600, ch2:  0x1601, ch3:  0x1602, ch4:  0x1603,
      ch5:  0x1604, ch6:  0x1605, ch7:  0x1606, ch8:  0x1607,
      ch9:  0x1608, ch10: 0x1609, ch11: 0x160A, ch12: 0x160B,
      ch13: 0x160C, ch14: 0x160D, ch15: 0x160E, ch16: 0x160F
    }
  end

  @impl true
  # 1-bit RxPDO: return 1 byte; the FMMU places bit 0 (LSB) into the SM bit.
  def encode_outputs(_ch, _config, v), do: <<v::8>>

  @impl true
  def decode_inputs(_pdo, _config, _), do: nil
end

defmodule Example.EL3202 do
  @behaviour EtherCAT.Slave.Driver

  @impl true
  def process_data_profile(_config) do
    # Two 32-bit TxPDOs on SM3: 0x1A00 = channel 1 (bytes 0–3), 0x1A01 = channel 2 (bytes 4–7)
    %{channel1: 0x1A00, channel2: 0x1A01}
  end

  @impl true
  def sdo_config(_config) do
    [
      {0x8000, 0x19, 8, 2},   # ch1 RTD element = ohm_1_16 (resistance, 1/16 Ω/bit)
      {0x8010, 0x19, 8, 2}    # ch2 RTD element = ohm_1_16
    ]
  end

  @impl true
  def encode_outputs(_pdo, _config, _value), do: <<>>

  @impl true
  def decode_inputs(:channel1, _config, <<
        _::1, error::1, _::2, _::2, overrange::1, underrange::1,
        toggle::1, state::1, _::6, value::16-little>>) do
    %{ohms: value / 16.0, overrange: overrange == 1, underrange: underrange == 1,
      error: error == 1, invalid: state == 1, toggle: toggle}
  end
  def decode_inputs(:channel2, _config, <<
        _::1, error::1, _::2, _::2, overrange::1, underrange::1,
        toggle::1, state::1, _::6, value::16-little>>) do
    %{ohms: value / 16.0, overrange: overrange == 1, underrange: underrange == 1,
      error: error == 1, invalid: state == 1, toggle: toggle}
  end
  def decode_inputs(_pdo, _config, _), do: nil
end

EtherCAT.start(
  interface: "enp0s31f6",
  domains: [
    %EtherCAT.Domain.Config{id: :main, period: 10, miss_threshold: 500}
  ],
  slaves: [
    nil,
    %EtherCAT.Slave.Config{name: :inputs, driver: Example.EL1809, domain: :main},
    %EtherCAT.Slave.Config{name: :outputs, driver: Example.EL2809, domain: :main},
    %EtherCAT.Slave.Config{name: :rtd, driver: Example.EL3202, domain: :main}
  ]
)
