defmodule EtherCAT.DomainTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Domain

  setup do
    domain_id = :"domain_test_#{System.unique_integer([:positive, :monotonic])}"

    {:ok, _pid} =
      start_supervised(
        {Domain, [id: domain_id, bus: self(), cycle_time_us: 60_000, miss_threshold: 500]}
      )

    %{domain_id: domain_id}
  end

  test "expected WKC counts each slave once per direction for LRW", %{domain_id: domain_id} do
    assert {:ok, 0} = Domain.register_pdo(domain_id, {:sensor, {:sm, 0}}, 2, :input)
    assert {:ok, 2} = Domain.register_pdo(domain_id, {:valve, {:sm, 0}}, 1, :output)
    assert {:ok, 3} = Domain.register_pdo(domain_id, {:valve, {:sm, 1}}, 1, :output)
    assert {:ok, 4} = Domain.register_pdo(domain_id, {:thermo, {:sm, 3}}, 8, :input)

    assert :ok = Domain.start_cycling(domain_id)
    assert {:ok, %{expected_wkc: 4}} = Domain.stats(domain_id)
  end

  test "start_cycling fails when nothing is registered", %{domain_id: domain_id} do
    assert {:error, :nothing_registered} = Domain.start_cycling(domain_id)
  end

  test "stop_cycling is idempotent while open", %{domain_id: domain_id} do
    assert :ok = Domain.stop_cycling(domain_id)
  end

  test "start_cycling fails fast for oversized LRW images", %{domain_id: domain_id} do
    assert {:ok, 0} = Domain.register_pdo(domain_id, {:big, :pdo}, 2036, :output)

    assert {:error, {:image_too_large, 2036, 2035}} = Domain.start_cycling(domain_id)
  end
end
