defmodule EtherCAT.Slave.Sync.CoE do
  @moduledoc """
  Helpers for common CoE application sync-mode objects.

  This module is driver-facing. It builds mailbox steps for the common
  synchronization objects:

  - `0x1C32` — SM output parameter
  - `0x1C33` — SM input parameter

  The public application API still uses `%EtherCAT.Slave.Sync.Config{}` for generic ESC
  SYNC/latch intent. Drivers may use these helpers from `c:EtherCAT.Slave.Driver.sync_mode/2`
  when a slave application also needs CoE object-dictionary sync-mode writes.

  This module does not talk to the mailbox itself. It only builds
  `{:sdo_download, ...}` steps for `EtherCAT.Slave.Mailbox.CoE` to execute later.

  The generated steps intentionally cover only the common writable fields:

  - subindex `0x01` — synchronization mode
  - subindex `0x02` — cycle time

  They do not attempt to write device-specific read-only or optional timing
  fields such as shift/calc-and-copy delays.

  ## Examples

      def sync_mode(_config, %EtherCAT.Slave.Sync.Config{mode: :sync0} = sync) do
        EtherCAT.Slave.Sync.CoE.steps!(
          cycle_ns: 1_000_000,
          output: :sync0,
          input: :sync0
        )
      end

      def sync_mode(_config, _sync) do
        EtherCAT.Slave.Sync.CoE.steps!(
          cycle_ns: 1_000_000,
          output: :sm_event,
          input: {:sm_event, :sm2}
        )
      end
  """

  @type mailbox_step ::
          EtherCAT.Slave.Driver.mailbox_step()

  @type output_mode :: :free_run | :sm_event | :sync0 | :sync1
  @type input_mode :: :free_run | {:sm_event, :sm2 | :sm3} | :sync0 | :sync1

  @doc """
  Build a combined list of CoE mailbox steps for `0x1C32` and/or `0x1C33`.

  Options:
    - `:cycle_ns` (required) — cycle time written to subindex `0x02`
    - `:output` — optional output application mode for `0x1C32`
    - `:input` — optional input application mode for `0x1C33`

  Returns a flat list of `{:sdo_download, index, subindex, binary}` steps.
  """
  @spec steps!(keyword()) :: [mailbox_step()]
  def steps!(opts) when is_list(opts) do
    cycle_ns = Keyword.fetch!(opts, :cycle_ns)
    output = Keyword.get(opts, :output)
    input = Keyword.get(opts, :input)

    validate_cycle_ns!(cycle_ns)

    output_steps(output, cycle_ns) ++ input_steps(input, cycle_ns)
  end

  @doc """
  Build CoE mailbox steps for the output sync object `0x1C32`.
  """
  @spec output_steps(output_mode() | nil, pos_integer()) :: [mailbox_step()]
  def output_steps(nil, _cycle_ns), do: []

  def output_steps(mode, cycle_ns) do
    validate_cycle_ns!(cycle_ns)

    [
      {:sdo_download, 0x1C32, 0x01, <<output_mode_code(mode)::16-little>>},
      {:sdo_download, 0x1C32, 0x02, <<cycle_ns::32-little>>}
    ]
  end

  @doc """
  Build CoE mailbox steps for the input sync object `0x1C33`.
  """
  @spec input_steps(input_mode() | nil, pos_integer()) :: [mailbox_step()]
  def input_steps(nil, _cycle_ns), do: []

  def input_steps(mode, cycle_ns) do
    validate_cycle_ns!(cycle_ns)

    [
      {:sdo_download, 0x1C33, 0x01, <<input_mode_code(mode)::16-little>>},
      {:sdo_download, 0x1C33, 0x02, <<cycle_ns::32-little>>}
    ]
  end

  defp validate_cycle_ns!(cycle_ns) when is_integer(cycle_ns) and cycle_ns > 0, do: :ok

  defp validate_cycle_ns!(cycle_ns) do
    raise ArgumentError, "expected :cycle_ns to be a positive integer, got: #{inspect(cycle_ns)}"
  end

  defp output_mode_code(:free_run), do: 0x0000
  defp output_mode_code(:sm_event), do: 0x0001
  defp output_mode_code(:sync0), do: 0x0002
  defp output_mode_code(:sync1), do: 0x0003

  defp output_mode_code(mode) do
    raise ArgumentError,
          "unsupported CoE output sync mode #{inspect(mode)}; expected :free_run, :sm_event, :sync0, or :sync1"
  end

  defp input_mode_code(:free_run), do: 0x0000
  defp input_mode_code({:sm_event, :sm3}), do: 0x0001
  defp input_mode_code(:sync0), do: 0x0002
  defp input_mode_code(:sync1), do: 0x0003
  defp input_mode_code({:sm_event, :sm2}), do: 0x0022

  defp input_mode_code(mode) do
    raise ArgumentError,
          "unsupported CoE input sync mode #{inspect(mode)}; expected :free_run, {:sm_event, :sm2 | :sm3}, :sync0, or :sync1"
  end
end
