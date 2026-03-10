defmodule EtherCAT.DC.State do
  @moduledoc false

  alias EtherCAT.DC
  alias EtherCAT.DC.Runtime

  @spec new(keyword()) :: %DC{}
  def new(opts) do
    config = Keyword.fetch!(opts, :config)

    monitored_stations =
      Keyword.get(opts, :monitored_stations, [Keyword.fetch!(opts, :ref_station)])

    %DC{
      bus: Keyword.fetch!(opts, :bus),
      ref_station: Keyword.fetch!(opts, :ref_station),
      config: config,
      monitored_stations: monitored_stations,
      tick_interval_ms:
        Keyword.get(opts, :tick_interval_ms, Runtime.tick_interval_ms(config.cycle_ns)),
      diagnostic_interval_cycles:
        Keyword.get(
          opts,
          :diagnostic_interval_cycles,
          Runtime.diagnostic_interval_cycles(config.cycle_ns)
        ),
      lock_state: Runtime.initial_lock_state(monitored_stations),
      max_sync_diff_ns: nil,
      last_sync_check_at_ms: nil
    }
  end
end
