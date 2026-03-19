defmodule EtherCAT.TestHelperTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @redundant_env_vars [
    {"ETHERCAT_REDUNDANT_RAW_MASTER_PRIMARY_INTERFACE", "ethercat-test-missing-m0"},
    {"ETHERCAT_REDUNDANT_RAW_SIMULATOR_PRIMARY_INTERFACE", "ethercat-test-missing-s0"},
    {"ETHERCAT_REDUNDANT_RAW_MASTER_SECONDARY_INTERFACE", "ethercat-test-missing-m1"},
    {"ETHERCAT_REDUNDANT_RAW_SIMULATOR_SECONDARY_INTERFACE", "ethercat-test-missing-s1"}
  ]

  setup do
    previous_values =
      Enum.map(@redundant_env_vars, fn {name, _value} ->
        {name, System.get_env(name)}
      end)

    Enum.each(@redundant_env_vars, fn {name, value} ->
      System.put_env(name, value)
    end)

    on_exit(fn ->
      Enum.each(previous_values, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "redundant raw exclusions only warn once when interfaces are missing" do
    stderr =
      capture_io(:stderr, fn ->
        assert [:raw_socket_redundant] = EtherCAT.TestHelper.raw_socket_redundant_excludes()

        assert [:raw_socket_redundant_toggle] =
                 EtherCAT.TestHelper.raw_socket_redundant_toggle_excludes()
      end)

    assert warning_count(stderr) == 1
    refute stderr =~ ":raw_socket_redundant_toggle tests because"
  end

  defp warning_count(stderr) do
    Regex.scan(
      ~r/warning: excluding :raw_socket_redundant tests for redundant raw simulator\./,
      stderr
    )
    |> length()
  end
end
