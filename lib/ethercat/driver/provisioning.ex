defmodule EtherCAT.Driver.Provisioning do
  @moduledoc """
  Optional provisioning extension API for driver-authored mailbox setup.

  Drivers that need CoE startup downloads or sync reconfiguration steps may
  implement this behaviour alongside `EtherCAT.Driver`.
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
