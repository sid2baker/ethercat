defmodule EtherCAT.IntegrationSupport.SegmentedMailboxRing do
  @moduledoc false

  alias EtherCAT.IntegrationSupport.Drivers.{
    EK1100,
    EL1809,
    EL2809,
    SegmentedConfiguredMailboxDevice
  }

  alias EtherCAT.IntegrationSupport.SimulatorRing
  alias EtherCAT.Simulator.Slave
  alias EtherCAT.Slave.Config, as: SlaveConfig

  @spec boot_operational!(keyword()) :: %{port: :inet.port_number()}
  def boot_operational!(opts \\ []) do
    simulator_opts =
      Keyword.merge(
        [devices: devices(), connections: connections()],
        Keyword.get(opts, :simulator_opts, [])
      )

    start_opts =
      Keyword.merge(
        [domains: [SimulatorRing.default_domain()], slaves: slaves()],
        Keyword.get(opts, :start_opts, [])
      )

    SimulatorRing.boot_operational!(
      simulator_opts: simulator_opts,
      start_opts: start_opts,
      await_operational_ms: Keyword.get(opts, :await_operational_ms, 2_500)
    )
  end

  @spec startup_blob() :: binary()
  def startup_blob do
    0..191
    |> Enum.map(fn value -> rem(value * 13 + 7, 256) end)
    |> :erlang.list_to_binary()
  end

  @spec devices() :: [struct()]
  def devices do
    [
      Slave.from_driver(EK1100, name: :coupler),
      Slave.from_driver(EL1809, name: :inputs),
      Slave.from_driver(EL2809, name: :outputs),
      Slave.from_driver(SegmentedConfiguredMailboxDevice, name: :mailbox)
    ]
  end

  @spec slaves() :: [SlaveConfig.t()]
  def slaves do
    [
      %SlaveConfig{name: :coupler, driver: EK1100, process_data: :none, target_state: :op},
      %SlaveConfig{
        name: :inputs,
        driver: EL1809,
        process_data: {:all, :main},
        target_state: :op
      },
      %SlaveConfig{
        name: :outputs,
        driver: EL2809,
        process_data: {:all, :main},
        target_state: :op,
        health_poll_ms: 20
      },
      %SlaveConfig{
        name: :mailbox,
        driver: SegmentedConfiguredMailboxDevice,
        process_data: :none,
        target_state: :op,
        health_poll_ms: 20
      }
    ]
  end

  @spec connections() :: [{{atom(), atom()}, {atom(), atom()}}]
  def connections do
    [
      {{:outputs, :ch1}, {:inputs, :ch1}},
      {{:outputs, :ch16}, {:inputs, :ch16}}
    ]
  end
end
