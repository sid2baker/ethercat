defmodule EtherCAT.Diagnostics do
  @moduledoc """
  Session-bound inspection and diagnostic API.

  Normal protocol-level runtime usage should stay on `EtherCAT`. This module is
  for topology inspection, DC status, slave/domain details, and lower-level
  runtime visibility. Every query requires its owning `%EtherCAT.Session{}`.

  Master status, domain lists, and DC queries collect live observations in the
  caller under a shared one-second timeout budget. An unavailable worker returns
  `{:error, {:diagnostic_unavailable, source, reason}}`, where `source` is `:bus`,
  `:dc`, or `{:domain, id}`. The session is revalidated after collection; results
  from a stopped or replaced generation return `{:error, :stale_session}`.
  """

  alias EtherCAT.Domain
  alias EtherCAT.Master.Diagnostics, as: MasterDiagnostics
  alias EtherCAT.Master.Status
  alias EtherCAT.Session
  alias EtherCAT.Slave

  @spec bus(Session.t()) :: EtherCAT.session_query_result(EtherCAT.Bus.server() | nil)
  def bus(session), do: ok_query(Session.call(session, :bus))

  @spec dc_status(Session.t()) :: EtherCAT.session_query_result(EtherCAT.DC.Status.t())
  def dc_status(session), do: MasterDiagnostics.query(session, :dc_status)

  @spec reference_clock(Session.t()) ::
          {:ok, %{name: atom() | nil, station: non_neg_integer()}} | {:error, term()}
  def reference_clock(session), do: MasterDiagnostics.query(session, :reference_clock)

  @spec last_failure(Session.t()) :: EtherCAT.session_query_result(map() | nil)
  def last_failure(session), do: ok_query(Session.call(session, :last_failure))

  @spec slaves(Session.t()) :: EtherCAT.session_query_result([map()])
  def slaves(session), do: ok_query(Session.call(session, :slaves))

  @spec domains(Session.t()) :: EtherCAT.session_query_result([tuple()])
  def domains(session), do: MasterDiagnostics.query(session, :domains)

  @spec master_status(Session.t()) :: {:ok, Status.t()} | {:error, term()}
  def master_status(session) do
    MasterDiagnostics.query(session, :status)
  end

  @spec slave_info(Session.t(), atom()) :: {:ok, map()} | {:error, term()}
  def slave_info(session, slave_name) when is_atom(slave_name) do
    with {:ok, slave} <- Session.slave(session, slave_name) do
      Slave.info(slave)
    end
  end

  @spec domain_info(Session.t(), atom()) :: {:ok, map()} | {:error, term()}
  def domain_info(session, domain_id) when is_atom(domain_id) do
    with {:ok, domain} <- Session.domain(session, domain_id) do
      Domain.info(domain)
    end
  end

  defp ok_query({:error, _reason} = error), do: error
  defp ok_query(value), do: {:ok, value}
end
