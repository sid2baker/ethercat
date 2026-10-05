defmodule EtherCAT.Driver.Provisioning do
  @moduledoc """
  Optional provisioning extension API for driver-authored mailbox setup.

  Drivers that need CoE startup downloads or sync reconfiguration steps may
  implement this behaviour alongside `EtherCAT.Driver`. The callback declares
  an ordered list of writes; the runtime executes them through the slave mailbox.
  It is not a hook for opening a second bus connection.

  For example, a driver can declare a device-specific unsigned 16-bit setting
  for PREOP and no additional sync-update writes:

      @behaviour EtherCAT.Driver.Provisioning

      @impl true
      def mailbox_steps(%{setting: value}, %{phase: :preop})
          when is_integer(value) and value in 0..65_535 do
        [{:sdo_download, 0x2000, 0x01, <<value::little-unsigned-16>>}]
      end

      def mailbox_steps(_config, %{phase: :sync_update}), do: []

  The object address and width above are illustrative, not a generic device
  setting. Use the device's object dictionary. PREOP setup may run again during
  reconnect, so consider the device's write/retry semantics when authoring steps.
  """

  alias EtherCAT.Driver
  alias EtherCAT.Slave.Sync.Config, as: SyncConfig

  @type mailbox_step ::
          {:sdo_download, index :: non_neg_integer(), subindex :: non_neg_integer(),
           data :: binary()}

  @type mailbox_phase :: :preop | :sync_update
  @type mailbox_context :: %{
          required(:phase) => mailbox_phase(),
          required(:sync) => SyncConfig.t() | nil
        }

  @doc """
  Return ordered SDO downloads for PREOP setup or a synchronization update.

  `context.phase` is `:preop` or `:sync_update`; `context.sync` is the requested
  `EtherCAT.Slave.Sync.Config` or `nil`. Return `[]` when no writes are needed.
  Drivers without this extension also default to no steps.
  """
  @callback mailbox_steps(Driver.config(), mailbox_context()) :: [mailbox_step()]

  @spec mailbox_steps(module(), Driver.config(), mailbox_context()) :: [mailbox_step()]
  def mailbox_steps(driver, config, context)
      when is_atom(driver) and is_map(config) and is_map(context) do
    if exported?(driver, :mailbox_steps, 2) do
      apply(driver, :mailbox_steps, [config, context])
    else
      []
    end
  end

  defp exported?(module, function_name, arity)
       when is_atom(module) and is_atom(function_name) and is_integer(arity) and arity >= 0 do
    Code.ensure_loaded?(module) and function_exported?(module, function_name, arity)
  end
end
