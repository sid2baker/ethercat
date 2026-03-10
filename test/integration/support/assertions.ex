defmodule EtherCAT.Integration.Assertions do
  @moduledoc false

  def assert_eventually(fun, attempts \\ 20)

  def assert_eventually(fun, 0) do
    fun.()
  end

  def assert_eventually(fun, attempts) do
    fun.()
  rescue
    _error in [ExUnit.AssertionError, MatchError] ->
      Process.sleep(20)
      assert_eventually(fun, attempts - 1)
  else
    result ->
      result
  end
end
