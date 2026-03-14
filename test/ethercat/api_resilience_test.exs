defmodule EtherCAT.APIResilienceTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Domain.API, as: DomainAPI
  alias EtherCAT.Slave.API, as: SlaveAPI
  alias EtherCAT.Utils

  defmodule DummyStatem do
    @behaviour :gen_statem

    def child_spec(opts) do
      %{
        id: {__MODULE__, Keyword.fetch!(opts, :id)},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary,
        shutdown: 5000,
        type: :worker
      }
    end

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      :gen_statem.start_link(name, __MODULE__, :ok, [])
    end

    @impl true
    def callback_mode, do: :handle_event_function

    @impl true
    def init(:ok), do: {:ok, :running, %{}}

    @impl true
    def handle_event({:call, from}, _msg, :running, data) do
      {:keep_state, data, [{:reply, from, :ok}]}
    end
  end

  setup do
    _ = EtherCAT.stop()
    :ok
  end

  test "shared call exit classification returns server_exit for mid-call crashes" do
    assert {:error, {:server_exit, :killed}} =
             Utils.classify_call_exit(
               {:killed, {GenServer, :call, [EtherCAT.Master, :state, 5_000]}},
               :not_started
             )
  end

  test "domain queries return server_exit when the domain dies mid-call" do
    domain_id = :"domain_api_resilience_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {DummyStatem,
         [
           id: {:domain, domain_id},
           name: {:via, Registry, {EtherCAT.Registry, {:domain, domain_id}}}
         ]}
      )

    assert {:error, {:server_exit, _reason}} =
             crash_during_call(pid, fn -> DomainAPI.info(domain_id) end)
  end

  test "slave queries return server_exit when the slave dies mid-call" do
    slave_name = :"slave_api_resilience_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {DummyStatem,
         [
           id: {:slave, slave_name},
           name: {:via, Registry, {EtherCAT.Registry, {:slave, slave_name}}}
         ]}
      )

    assert {:error, {:server_exit, _reason}} =
             crash_during_call(pid, fn -> SlaveAPI.info(slave_name) end)
  end

  defp crash_during_call(pid, fun) do
    :sys.suspend(pid)

    task = Task.async(fun)
    Process.sleep(20)
    Process.exit(pid, :kill)

    Task.await(task)
  end
end
