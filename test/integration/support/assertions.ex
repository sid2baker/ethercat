defmodule EtherCAT.Integration.Assertions do
  @moduledoc false

  alias EtherCAT.Integration.Expect

  def assert_eventually(fun, attempts \\ 20)

  def assert_eventually(fun, attempts) do
    Expect.eventually(fun, attempts: attempts)
  end

  def assert_stays(fun, attempts \\ 5)

  def assert_stays(fun, attempts) do
    Expect.stays(fun, attempts: attempts)
  end
end
