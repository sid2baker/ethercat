defmodule EtherCAT.Support.Slave do
  @moduledoc false

  alias EtherCAT.Support.Slave.Fixture

  @type fixture :: Fixture.t()

  @spec digital_io(keyword()) :: fixture()
  def digital_io(opts \\ []) do
    Fixture.digital_io(opts)
  end
end
