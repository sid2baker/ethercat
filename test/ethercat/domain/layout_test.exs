defmodule EtherCAT.Domain.LayoutTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Domain.Layout
  alias EtherCAT.Domain.Layout.CyclePlan

  test "register preserves PDO order and computes expected LRW WKC" do
    pid = self()

    {0, layout} = Layout.register(Layout.new(), {:sensor, {:sm, 0}}, 2, :input, pid)
    {2, layout} = Layout.register(layout, {:valve, {:sm, 0}}, 1, :output, nil)
    {3, layout} = Layout.register(layout, {:valve, {:sm, 1}}, 1, :output, nil)
    {4, layout} = Layout.register(layout, {:thermo, {:sm, 3}}, 8, :input, pid)

    assert Layout.image_size(layout) == 12
    assert Layout.expected_wkc(layout) == 4

    assert {:ok,
            %CyclePlan{
              image_size: 12,
              output_patches: [
                {2, 1, {:valve, {:sm, 0}}},
                {3, 1, {:valve, {:sm, 1}}}
              ],
              input_slices: [
                {0, 2, {:sensor, {:sm, 0}}, ^pid},
                {4, 8, {:thermo, {:sm, 3}}, ^pid}
              ],
              expected_wkc: 4
            }} = Layout.prepare(layout)
  end

  test "prepare rejects LRW images larger than one EtherCAT payload" do
    {0, layout} = Layout.register(Layout.new(), {:big, :pdo}, 2036, :output, nil)

    assert {:error, {:image_too_large, 2036, 2035}} = Layout.prepare(layout)
  end
end
