defmodule EtherCAT.Diagnostics do
  @moduledoc """
  Specialist inspection and diagnostic API.

  Normal machine-facing runtime usage should stay on `EtherCAT`. This module is
  for topology inspection, DC status, slave/domain details, and other
  lower-level runtime visibility.
  """

  alias EtherCAT.Domain
  alias EtherCAT.Master
  alias EtherCAT.Slave

  @spec bus() :: EtherCAT.master_query_result(EtherCAT.Bus.server() | nil)
  def bus, do: ok_query(Master.bus())

  @spec dc_status() :: EtherCAT.master_query_result(EtherCAT.DC.Status.t())
  def dc_status, do: ok_query(Master.dc_status())

  @spec reference_clock() ::
          {:ok, %{name: atom() | nil, station: non_neg_integer()}} | {:error, term()}
  def reference_clock, do: Master.reference_clock()

  @spec last_failure() :: EtherCAT.master_query_result(map() | nil)
  def last_failure, do: ok_query(Master.last_failure())

  @spec capabilities(atom()) ::
          [atom()] | {:error, :not_found | :timeout | {:server_exit, term()}}
  def capabilities(slave_name) do
    with {:ok, description} <- EtherCAT.describe(slave_name) do
      description.commands
    end
  end

  @spec slaves() :: EtherCAT.master_query_result([map()])
  def slaves, do: ok_query(Master.slaves())

  @spec domains() :: EtherCAT.master_query_result([tuple()])
  def domains, do: ok_query(Master.domains())

  @spec slave_info(atom()) ::
          {:ok, map()} | {:error, :not_found | :timeout | {:server_exit, term()}}
  def slave_info(slave_name), do: Slave.info(slave_name)

  @spec domain_info(atom()) ::
          {:ok, map()} | {:error, :not_found | :timeout | {:server_exit, term()}}
  def domain_info(domain_id), do: Domain.info(domain_id)

  defp ok_query({:error, _} = err), do: err
  defp ok_query(value), do: {:ok, value}
end
