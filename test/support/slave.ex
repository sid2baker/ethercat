defmodule EtherCAT.Support.Slave do
  @moduledoc false

  alias EtherCAT.Support.Slave.Fixture

  @type fixture :: Fixture.t()

  @spec digital_io(keyword()) :: fixture()
  def digital_io(opts \\ []) do
    Fixture.digital_io(opts)
  end

  @spec lan9252_demo(keyword()) :: fixture()
  def lan9252_demo(opts \\ []) do
    Fixture.lan9252_demo(opts)
  end

  @spec coupler(keyword()) :: fixture()
  def coupler(opts \\ []) do
    Fixture.coupler(opts)
  end
end
