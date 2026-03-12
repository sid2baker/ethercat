defmodule EtherCAT.Simulator.Slave.ALTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Simulator.Slave.Definition
  alias EtherCAT.Simulator.Slave.Runtime.AL
  alias EtherCAT.Simulator.Slave.Runtime.Device

  test "apply_control enforces AL transition discipline and updates AL status" do
    slave = Device.new(Definition.build(:digital_io), 0)

    assert {:error, invalid} = AL.apply_control(slave, 0x08)
    assert invalid.state == :init
    assert invalid.al_error?
    assert invalid.al_status_code == 0x0011
    assert Device.read_register(invalid, 0x0130, 2) == <<0x11, 0x00>>
    assert Device.read_register(invalid, 0x0134, 2) == <<0x11, 0x00>>

    assert {:ok, preop} = AL.apply_control(slave, 0x02)
    preop = configure_operational_layout(preop)

    assert {:ok, safeop} = AL.apply_control(preop, 0x04)
    assert {:ok, op} = AL.apply_control(safeop, 0x08)

    assert preop.state == :preop
    assert safeop.state == :safeop
    assert op.state == :op
    refute op.al_error?
    assert op.al_status_code == 0
    assert Device.read_register(op, 0x0130, 2) == <<0x08, 0x00>>
    assert Device.read_register(op, 0x0134, 2) == <<0x00, 0x00>>
  end

  test "preop rejects mailbox-capable slaves whose mailbox sync managers are not configured" do
    slave = Device.new(Definition.build(:mailbox_device), 0)

    assert {:error, failed} = AL.apply_control(slave, 0x02)
    assert failed.state == :init
    assert failed.al_error?
    assert failed.al_status_code == 0x0016
    assert Device.read_register(failed, 0x0130, 2) == <<0x11, 0x00>>
    assert Device.read_register(failed, 0x0134, 2) == <<0x16, 0x00>>
  end

  test "safeop rejects slaves whose process-data sync managers and FMMUs are not configured" do
    slave =
      Definition.build(:digital_io)
      |> Device.new(0)
      |> configure_mailbox_layout()

    assert {:ok, preop} = AL.apply_control(slave, 0x02)
    assert {:error, failed} = AL.apply_control(preop, 0x04)
    assert failed.state == :preop
    assert failed.al_error?
    assert failed.al_status_code == 0x001D
    assert Device.read_register(failed, 0x0130, 2) == <<0x12, 0x00>>
    assert Device.read_register(failed, 0x0134, 2) == <<0x1D, 0x00>>
  end

  defp configure_operational_layout(slave) do
    slave
    |> configure_mailbox_layout()
    |> configure_process_data_layout()
  end

  defp configure_mailbox_layout(%{mailbox_config: %{recv_size: 0, send_size: 0}} = slave),
    do: slave

  defp configure_mailbox_layout(slave) do
    %{recv_offset: ro, recv_size: rs, send_offset: so, send_size: ss} = slave.mailbox_config

    slave
    |> Device.write_register(0x0800, <<ro::16-little, rs::16-little, 0x26, 0, 0, 0>>)
    |> Device.write_register(0x0806, <<1>>)
    |> Device.write_register(0x0808, <<so::16-little, ss::16-little, 0x22, 0, 0, 0>>)
    |> Device.write_register(0x080E, <<1>>)
  end

  defp configure_process_data_layout(slave) do
    slave
    |> maybe_configure_sm(2, slave.output_phys, slave.output_size, 0x24)
    |> maybe_configure_sm(3, slave.input_phys, slave.input_size, 0x20)
    |> maybe_configure_fmmu(0, 0x1000, slave.output_size, slave.output_phys, 0x02)
    |> maybe_configure_fmmu(
      1,
      0x1000 + slave.output_size,
      slave.input_size,
      slave.input_phys,
      0x01
    )
  end

  defp maybe_configure_sm(slave, _index, _start, 0, _control), do: slave

  defp maybe_configure_sm(slave, index, start, size, control) do
    base = 0x0800 + index * 8

    slave
    |> Device.write_register(base, <<start::16-little, size::16-little, control, 0, 0, 0>>)
    |> Device.write_register(base + 6, <<1>>)
  end

  defp maybe_configure_fmmu(slave, _index, _logical_start, 0, _phys_start, _type), do: slave

  defp maybe_configure_fmmu(slave, index, logical_start, size, phys_start, type) do
    base = 0x0600 + index * 16

    entry =
      <<logical_start::32-little, size::16-little, 0::8, 7::8, phys_start::16-little, 0::8,
        type::8, 0x01::8, 0::24>>

    Device.write_register(slave, base, entry)
  end
end
