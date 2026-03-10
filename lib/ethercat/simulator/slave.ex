defmodule EtherCAT.Simulator.Slave do
  @moduledoc """
  Fixture and signal-level API for simulated EtherCAT slaves.

  Use this module to build reusable slave fixtures such as digital I/O or
  mailbox-capable demo devices, and to inspect or override named signal values
  on a running simulator.
  """

  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Slave.Fixture

  @type fixture :: map()

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

  @spec signals(fixture()) :: [atom()]
  def signals(%{signals: signals}) do
    Map.keys(signals)
  end

  @spec signal_definitions(fixture()) :: %{optional(atom()) => map()}
  def signal_definitions(%{signals: signals}), do: signals

  @spec signals(pid(), atom()) :: {:ok, [atom()]} | {:error, :not_found}
  def signals(simulator, slave_name) when is_pid(simulator) and is_atom(slave_name) do
    Simulator.signals(simulator, slave_name)
  end

  @spec get_value(pid(), atom(), atom()) ::
          {:ok, term()} | {:error, :not_found | :unknown_signal}
  def get_value(simulator, slave_name, signal_name)
      when is_pid(simulator) and is_atom(slave_name) and is_atom(signal_name) do
    Simulator.get_value(simulator, slave_name, signal_name)
  end

  @spec set_value(pid(), atom(), atom(), term()) ::
          :ok | {:error, :not_found | :unknown_signal | :invalid_value}
  def set_value(simulator, slave_name, signal_name, value)
      when is_pid(simulator) and is_atom(slave_name) and is_atom(signal_name) do
    Simulator.set_value(simulator, slave_name, signal_name, value)
  end
end
