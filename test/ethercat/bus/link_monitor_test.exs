defmodule EtherCAT.Bus.LinkMonitorTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Bus.LinkMonitor

  test "decode_events extracts lower_up state from RTM_NEWLINK messages" do
    message =
      build_newlink_message("eth0", lower_up?: true) <>
        build_newlink_message("eth1", lower_up?: false)

    assert LinkMonitor.decode_events(message) == [{"eth0", true}, {"eth1", false}]
  end

  test "decode_events ignores messages without ifname attributes" do
    message =
      <<32::32-native, 16::16-native, 0::16-native, 1::32-native, 0::32-native, 0::8, 0::8,
        1::16-native, 2::32-native, 0::32-native, 0xFFFF_FFFF::32-native, 0::16-native,
        0::16-native>>

    assert LinkMonitor.decode_events(message) == []
  end

  defp build_newlink_message(ifname, opts) do
    flags =
      if Keyword.get(opts, :lower_up?, false) do
        0x0001_0000
      else
        0
      end

    ifname_payload = ifname <> <<0>>
    attr_len = 4 + byte_size(ifname_payload)
    attr_pad = align4(attr_len) - attr_len

    attrs =
      <<attr_len::16-native, 3::16-native, ifname_payload::binary, 0::size(attr_pad * 8)>>

    body =
      <<0::8, 0::8, 1::16-native, 2::32-native, flags::32-native, 0xFFFF_FFFF::32-native,
        attrs::binary>>

    len = 16 + byte_size(body)
    pad = align4(len) - len

    <<len::32-native, 16::16-native, 0::16-native, 1::32-native, 0::32-native, body::binary,
      0::size(pad * 8)>>
  end

  defp align4(len), do: div(len + 3, 4) * 4
end
