defmodule EtherCAT.Simulator.Slave do
  @moduledoc """
  Device and signal-level API for simulated EtherCAT slaves.

  Use this module to build reusable simulated slave devices such as digital I/O
  or mailbox-capable demo devices, and to inspect or override named signal
  values on a running simulator.
  """

  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Slave.Definition

  @type profile :: atom()
  @type device :: map()
  @type signal_ref :: {atom(), atom()}

  @spec device(profile(), keyword()) :: device()
  def device(profile, opts \\ []) do
    Definition.build(profile, opts)
  end

  @spec digital_io(keyword()) :: device()
  def digital_io(opts \\ []) do
    device(:digital_io, opts)
  end

  @spec lan9252_demo(keyword()) :: device()
  def lan9252_demo(opts \\ []) do
    mailbox_device(opts)
  end

  @spec mailbox_device(keyword()) :: device()
  def mailbox_device(opts \\ []) do
    device(:mailbox_device, opts)
  end

  @spec analog_io(keyword()) :: device()
  def analog_io(opts \\ []) do
    device(:analog_io, opts)
  end

  @spec temperature_input(keyword()) :: device()
  def temperature_input(opts \\ []) do
    device(:temperature_input, opts)
  end

  @spec servo_drive(keyword()) :: device()
  def servo_drive(opts \\ []) do
    device(:servo_drive, opts)
  end

  @spec coupler(keyword()) :: device()
  def coupler(opts \\ []) do
    device(:coupler, opts)
  end

  @spec signals(device()) :: [atom()]
  def signals(%{signals: signals}) do
    Map.keys(signals)
  end

  @spec signal_definitions(device()) :: %{optional(atom()) => map()}
  def signal_definitions(%{signals: signals}), do: signals

  @spec signal_definitions(pid(), atom()) ::
          {:ok, %{optional(atom()) => map()}} | {:error, :not_found}
  def signal_definitions(simulator, slave_name)
      when is_pid(simulator) and is_atom(slave_name) do
    Simulator.signal_definitions(simulator, slave_name)
  end

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

  @spec connect(pid(), signal_ref(), signal_ref()) ::
          :ok | {:error, :not_found | :unknown_signal | :invalid_value}
  def connect(simulator, {source_slave, source_signal}, {target_slave, target_signal})
      when is_pid(simulator) and is_atom(source_slave) and is_atom(source_signal) and
             is_atom(target_slave) and is_atom(target_signal) do
    Simulator.connect(simulator, {source_slave, source_signal}, {target_slave, target_signal})
  end

  @spec disconnect(pid(), signal_ref(), signal_ref()) :: :ok | {:error, :not_found}
  def disconnect(simulator, {source_slave, source_signal}, {target_slave, target_signal})
      when is_pid(simulator) and is_atom(source_slave) and is_atom(source_signal) and
             is_atom(target_slave) and is_atom(target_signal) do
    Simulator.disconnect(simulator, {source_slave, source_signal}, {target_slave, target_signal})
  end

  @spec connections(pid()) :: {:ok, [map()]} | {:error, :not_found | :timeout}
  def connections(simulator) when is_pid(simulator) do
    Simulator.connections(simulator)
  end

  @spec subscribe(pid(), atom(), atom() | :all, pid()) :: :ok | {:error, :not_found}
  def subscribe(simulator, slave_name, signal_name \\ :all, subscriber \\ self())
      when is_pid(simulator) and is_atom(slave_name) and
             (is_atom(signal_name) or signal_name == :all) and is_pid(subscriber) do
    Simulator.subscribe(simulator, slave_name, signal_name, subscriber)
  end

  @spec unsubscribe(pid(), atom(), atom() | :all, pid()) :: :ok | {:error, :not_found}
  def unsubscribe(simulator, slave_name, signal_name \\ :all, subscriber \\ self())
      when is_pid(simulator) and is_atom(slave_name) and
             (is_atom(signal_name) or signal_name == :all) and is_pid(subscriber) do
    Simulator.unsubscribe(simulator, slave_name, signal_name, subscriber)
  end
end
