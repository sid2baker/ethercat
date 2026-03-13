defmodule EtherCAT.IntegrationSupport.HardwareSimulatorRing do
  @moduledoc false

  alias EtherCAT.IntegrationSupport.Drivers.{EK1100, EL1809, EL2809, EL3202}
  alias EtherCAT.IntegrationSupport.Hardware
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
        [
          domains: [Hardware.main_domain()],
          slaves: slaves(Keyword.get(opts, :slave_config_opts, []))
        ],
        Keyword.get(opts, :start_opts, [])
      )

    SimulatorRing.boot_operational!(
      simulator_opts: simulator_opts,
      start_opts: start_opts,
      await_operational_ms: Keyword.get(opts, :await_operational_ms, 2_500)
    )
  end

  @spec devices() :: [struct()]
  def devices do
    [
      Slave.from_driver(EK1100, name: :coupler),
      Slave.from_driver(EL1809, name: :inputs),
      Slave.from_driver(EL2809, name: :outputs),
      Slave.from_driver(EL3202, name: :rtd)
    ]
  end

  @spec slaves(keyword()) :: [SlaveConfig.t()]
  def slaves(opts \\ []) do
    shared_health_poll_ms = Keyword.get(opts, :health_poll_ms)

    [
      Hardware.coupler(
        health_poll_ms: Keyword.get(opts, :coupler_health_poll_ms, shared_health_poll_ms)
      ),
      Hardware.inputs(
        health_poll_ms: Keyword.get(opts, :input_health_poll_ms, shared_health_poll_ms)
      ),
      Hardware.outputs(
        health_poll_ms: Keyword.get(opts, :output_health_poll_ms, shared_health_poll_ms)
      ),
      Hardware.rtd(health_poll_ms: Keyword.get(opts, :rtd_health_poll_ms, shared_health_poll_ms))
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
