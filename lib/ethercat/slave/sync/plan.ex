defmodule EtherCAT.Slave.Sync.Plan do
  @moduledoc false

  alias EtherCAT.Slave.Sync.Config

  @default_start_delay_ns 100_000_000

  @type t :: %__MODULE__{
          mode: Config.mode(),
          cyclic_unit_control: non_neg_integer(),
          activation: non_neg_integer(),
          sync0_cycle_ns: pos_integer() | nil,
          sync1_cycle_ns: non_neg_integer(),
          pulse_ns: pos_integer() | nil,
          start_time_ns: non_neg_integer() | nil,
          sync_diff_ns: non_neg_integer() | nil,
          latch_names: %{{0 | 1, :pos | :neg} => atom()},
          active_latches: [{0 | 1, :pos | :neg}],
          latch0_control: non_neg_integer(),
          latch1_control: non_neg_integer()
        }

  defstruct [
    :mode,
    :cyclic_unit_control,
    :activation,
    :sync0_cycle_ns,
    :sync1_cycle_ns,
    :pulse_ns,
    :start_time_ns,
    :sync_diff_ns,
    :latch_names,
    :active_latches,
    :latch0_control,
    :latch1_control
  ]

  @spec build(Config.t(), pos_integer(), non_neg_integer() | nil, non_neg_integer() | nil) ::
          {:ok, t()} | {:error, term()}
  def build(%Config{} = config, cycle_ns, local_time_ns, sync_diff_ns)
      when is_integer(cycle_ns) and cycle_ns > 0 do
    latch_names =
      Enum.into(config.latches, %{}, fn {name, key} -> {key, name} end)

    active_latches =
      latch_names
      |> Map.keys()
      |> Enum.sort()

    plan = %__MODULE__{
      mode: config.mode,
      cyclic_unit_control: cyclic_unit_control(config.mode),
      activation: activation(config.mode),
      sync0_cycle_ns: sync0_cycle_ns(config.mode, cycle_ns),
      sync1_cycle_ns: sync1_cycle_ns(config.mode, cycle_ns, config.sync1),
      pulse_ns: pulse_ns(config.mode, config.sync0),
      start_time_ns: start_time_ns(config.mode, cycle_ns, config, local_time_ns),
      sync_diff_ns: sync_diff_ns,
      latch_names: latch_names,
      active_latches: active_latches,
      latch0_control: latch_control(active_latches, 0),
      latch1_control: latch_control(active_latches, 1)
    }

    validate_plan(plan)
  end

  def build(_config, _cycle_ns, _local_time_ns, _sync_diff_ns), do: {:error, :invalid_sync_plan}

  defp validate_plan(%__MODULE__{mode: mode, start_time_ns: nil}) when mode in [:sync0, :sync1],
    do: {:error, :missing_dc_time}

  defp validate_plan(plan), do: {:ok, plan}

  @spec activation(Config.mode()) :: non_neg_integer()
  def activation(nil), do: 0x00
  def activation(:free_run), do: 0x00
  def activation(:sync0), do: 0x03
  def activation(:sync1), do: 0x07

  @spec cyclic_unit_control(Config.mode()) :: non_neg_integer()
  def cyclic_unit_control(_mode), do: 0x0000

  @spec start_time_ns(Config.mode(), pos_integer(), Config.t(), non_neg_integer() | nil) ::
          non_neg_integer() | nil
  def start_time_ns(mode, _cycle_ns, _config, _local_time_ns) when mode in [nil, :free_run],
    do: nil

  def start_time_ns(mode, cycle_ns, %Config{} = config, local_time_ns)
      when mode in [:sync0, :sync1] and is_integer(local_time_ns) and local_time_ns >= 0 do
    shift_ns = sync0_shift_ns(config.sync0)
    alignment_cycle_ns = alignment_cycle_ns(cycle_ns, config.sync1)
    earliest = local_time_ns + @default_start_delay_ns
    div(earliest, alignment_cycle_ns) * alignment_cycle_ns + alignment_cycle_ns + shift_ns
  end

  def start_time_ns(mode, _cycle_ns, _config, _local_time_ns) when mode in [:sync0, :sync1],
    do: nil

  @spec alignment_cycle_ns(pos_integer(), map() | nil) :: pos_integer()
  def alignment_cycle_ns(cycle_ns, nil) when is_integer(cycle_ns) and cycle_ns > 0, do: cycle_ns

  def alignment_cycle_ns(cycle_ns, %{offset_ns: offset_ns})
      when is_integer(cycle_ns) and cycle_ns > 0 and is_integer(offset_ns) and offset_ns >= 0 do
    (div(offset_ns, cycle_ns) + 1) * cycle_ns
  end

  @spec sync1_cycle_ns(Config.mode(), pos_integer(), map() | nil) :: non_neg_integer()
  def sync1_cycle_ns(:sync1, _cycle_ns, %{offset_ns: offset_ns})
      when is_integer(offset_ns) and offset_ns >= 0,
      do: offset_ns

  def sync1_cycle_ns(_mode, _cycle_ns, _sync1), do: 0

  defp sync0_cycle_ns(mode, cycle_ns) when mode in [:sync0, :sync1], do: cycle_ns
  defp sync0_cycle_ns(_mode, _cycle_ns), do: nil

  defp pulse_ns(mode, %{pulse_ns: pulse_ns}) when mode in [:sync0, :sync1], do: pulse_ns
  defp pulse_ns(_mode, _sync0), do: nil

  defp sync0_shift_ns(%{shift_ns: shift_ns}) when is_integer(shift_ns), do: shift_ns
  defp sync0_shift_ns(_sync0), do: 0

  defp latch_control(active_latches, latch_id) do
    if(Enum.member?(active_latches, {latch_id, :pos}), do: 0x01, else: 0x00) +
      if(Enum.member?(active_latches, {latch_id, :neg}), do: 0x02, else: 0x00)
  end
end
