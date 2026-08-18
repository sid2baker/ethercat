defmodule EtherCAT.Runtime.Handle do
  @moduledoc """
  Generation-bound handle for one started EtherCAT master session.

  A handle is bound to both the master process and one session generation.
  Calls made with a handle from a stopped or replaced session return
  `{:error, :stale_handle}` instead of accidentally targeting the replacement
  session.
  """

  @type t :: %__MODULE__{master: pid(), session: reference()}

  @enforce_keys [:master, :session]
  defstruct [:master, :session]

  @doc false
  @spec new(pid(), reference()) :: t()
  def new(master, session) when is_pid(master) and is_reference(session) do
    %__MODULE__{master: master, session: session}
  end

  @doc false
  @spec master(t()) :: pid()
  def master(%__MODULE__{master: master}), do: master

  @doc false
  @spec session(t()) :: reference()
  def session(%__MODULE__{session: session}), do: session
end
