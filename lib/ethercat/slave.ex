defmodule EtherCAT.Slave do
  @moduledoc """
  gen_statem managing the ESM (EtherCAT State Machine) lifecycle for one physical slave.

  Registered via `{:via, Registry, {EtherCAT.Registry, {:slave, station}}}`.

  On start, forces the slave to `:init`, then auto-advances to `:preop` (reads
  SII EEPROM, looks up driver). `:safeop` and `:op` require explicit `request/2`.

  ## States

      :init → :preop  (auto on state_enter)
      :preop → :safeop → :op  (explicit via request/2)
      any → :init, :preop, :safeop  (backward, explicit)
      :init ↔ :bootstrap  (explicit)

  ## Driver registry

      config :ethercat, :drivers, %{
        {0x00000002, 0x0C1E3052} => MyApp.SomeDriver
      }

  Key is `{vendor_id, product_code}` (32-bit unsigned integers).
  """

  @behaviour :gen_statem

  require Logger

  alias EtherCAT.{Link, Slave.SII}
  alias EtherCAT.Link.Transaction
  alias EtherCAT.Slave.Registers

  @al_codes %{init: 0x01, preop: 0x02, bootstrap: 0x03, safeop: 0x04, op: 0x08}

  # Direct transition path lookup — avoids BFS at runtime.
  # Key is {from, to}, value is the list of states to walk through.
  @paths %{
    {:init, :preop} => [:preop],
    {:init, :bootstrap} => [:bootstrap],
    {:init, :safeop} => [:preop, :safeop],
    {:init, :op} => [:preop, :safeop, :op],
    {:bootstrap, :init} => [:init],
    {:preop, :safeop} => [:safeop],
    {:preop, :op} => [:safeop, :op],
    {:preop, :init} => [:init],
    {:safeop, :op} => [:op],
    {:safeop, :preop} => [:preop],
    {:safeop, :init} => [:init],
    {:op, :safeop} => [:safeop],
    {:op, :preop} => [:safeop, :preop],
    {:op, :init} => [:safeop, :preop, :init]
  }

  @poll_limit 200
  @poll_interval_ms 1

  defstruct [:link, :station, :error_code, :identity, :driver, :mailbox_config]

  # -- Public API ------------------------------------------------------------

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :station)},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary,
      shutdown: 5000
    }
  end

  @doc "Start a Slave gen_statem for `station` using `link` as the link layer."
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    station = Keyword.fetch!(opts, :station)
    name = {:via, Registry, {EtherCAT.Registry, {:slave, station}}}
    :gen_statem.start_link(name, __MODULE__, opts, [])
  end

  @doc "Request a transition to `target_state`. Walks multi-step paths automatically."
  @spec request(non_neg_integer(), atom()) :: :ok | {:error, term()}
  def request(station, target), do: :gen_statem.call(via(station), {:request, target})

  @doc "Return the current ESM state atom."
  @spec state(non_neg_integer()) :: atom()
  def state(station), do: :gen_statem.call(via(station), :state)

  @doc "Return the identity map from SII EEPROM, or nil if not yet read."
  @spec identity(non_neg_integer()) :: map() | nil
  def identity(station), do: :gen_statem.call(via(station), :identity)

  @doc "Return the last AL status code, or nil if no error has occurred."
  @spec error(non_neg_integer()) :: non_neg_integer() | nil
  def error(station), do: :gen_statem.call(via(station), :error)

  # -- :gen_statem callbacks -------------------------------------------------

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(opts) do
    link = Keyword.fetch!(opts, :link)
    station = Keyword.fetch!(opts, :station)
    data = %__MODULE__{link: link, station: station}

    with {:ok, data2} <- do_transition(data, :init) do
      {:ok, :init, data2}
    else
      {:error, reason, _data} -> {:stop, reason}
    end
  end

  # -- State enter -----------------------------------------------------------

  @impl true
  def handle_event(:enter, _old, :init, _data) do
    {:keep_state_and_data, [{{:timeout, :auto_advance}, 0, nil}]}
  end

  def handle_event(:enter, _old, state, data) when state in [:preop, :safeop, :op] do
    invoke_driver(data, :"on_#{state}")
    :keep_state_and_data
  end

  def handle_event(:enter, _old, :bootstrap, _data), do: :keep_state_and_data

  # -- Auto-advance :init → :preop ------------------------------------------

  def handle_event({:timeout, :auto_advance}, nil, :init, data) do
    case read_sii(data.link, data.station) do
      {:ok, identity, mailbox_config} ->
        driver = find_driver(identity.vendor_id, identity.product_code)
        new_data = %{data | identity: identity, mailbox_config: mailbox_config, driver: driver}

        case do_transition(new_data, :preop) do
          {:ok, new_data2} ->
            {:next_state, :preop, new_data2}

          {:error, reason, new_data2} ->
            Logger.warning(
              "[Slave 0x#{Integer.to_string(data.station, 16)}] preop failed: #{inspect(reason)}"
            )

            {:keep_state, new_data2}
        end

      {:error, reason} ->
        Logger.warning(
          "[Slave 0x#{Integer.to_string(data.station, 16)}] SII read failed: #{inspect(reason)}"
        )

        :keep_state_and_data
    end
  end

  # -- API calls -------------------------------------------------------------

  def handle_event({:call, from}, :state, state, _data) do
    {:keep_state_and_data, [{:reply, from, state}]}
  end

  def handle_event({:call, from}, :identity, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.identity}]}
  end

  def handle_event({:call, from}, :error, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.error_code}]}
  end

  def handle_event({:call, from}, {:request, target}, state, _data) when state == target do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, {:request, target}, state, data) do
    case Map.get(@paths, {state, target}) do
      nil ->
        {:keep_state_and_data, [{:reply, from, {:error, :invalid_transition}}]}

      steps ->
        case walk_path(data, steps) do
          {:ok, new_data} ->
            {:next_state, target, new_data, [{:reply, from, :ok}]}

          {:error, reason, new_data} ->
            {:keep_state, new_data, [{:reply, from, {:error, reason}}]}
        end
    end
  end

  # -- Transition helpers ----------------------------------------------------

  defp walk_path(data, []), do: {:ok, data}

  defp walk_path(data, [next | rest]) do
    case do_transition(data, next) do
      {:ok, new_data} -> walk_path(new_data, rest)
      error -> error
    end
  end

  defp do_transition(data, target) do
    code = Map.fetch!(@al_codes, target)

    {al_control_addr, _} = Registers.al_control()

    with {:ok, [%{wkc: wkc}]} when wkc > 0 <-
           Link.transaction(
             data.link,
             &Transaction.fpwr(&1, data.station, al_control_addr, <<code::16-little>>)
           ) do
      poll_al(data, code, @poll_limit)
    else
      {:ok, [%{wkc: 0}]} -> {:error, :no_response, data}
      {:error, reason} -> {:error, reason, data}
    end
  end

  defp poll_al(data, _code, 0), do: {:error, :transition_timeout, data}

  defp poll_al(data, code, n) do
    {al_status_addr, al_status_size} = Registers.al_status()

    case Link.transaction(data.link, &Transaction.fprd(&1, data.station, al_status_addr, al_status_size)) do
      {:ok, [%{data: <<_::3, _err::1, state::4, _::8>>, wkc: wkc}]}
      when wkc > 0 and state == code ->
        {:ok, data}

      {:ok, [%{data: <<_::3, 1::1, _::4, _::8>>, wkc: wkc}]} when wkc > 0 ->
        {err_code, new_data} = ack_error(data)
        {:error, {:al_error, err_code}, new_data}

      {:ok, [%{data: <<_::16>>, wkc: wkc}]} when wkc > 0 ->
        Process.sleep(@poll_interval_ms)
        poll_al(data, code, n - 1)

      {:ok, [%{wkc: 0}]} ->
        {:error, :no_response, data}

      {:error, reason} ->
        {:error, reason, data}
    end
  end

  defp ack_error(data) do
    {al_status_code_addr, al_status_code_size} = Registers.al_status_code()
    {al_status_addr, al_status_size} = Registers.al_status()
    {al_control_addr, _} = Registers.al_control()

    err_code =
      case Link.transaction(data.link, &Transaction.fprd(&1, data.station, al_status_code_addr, al_status_code_size)) do
        {:ok, [%{data: <<c::16-little>>, wkc: wkc}]} when wkc > 0 -> c
        _ -> nil
      end

    state_code =
      case Link.transaction(data.link, &Transaction.fprd(&1, data.station, al_status_addr, al_status_size)) do
        {:ok, [%{data: <<_::3, _err::1, state::4, _::8>>, wkc: wkc}]} when wkc > 0 -> state
        _ -> 0x01
      end

    # Set error ack bit (bit 4) alongside the current state code
    ack_value = state_code + 0x10

    Link.transaction(
      data.link,
      &Transaction.fpwr(&1, data.station, al_control_addr, <<ack_value::16-little>>)
    )

    {err_code, %{data | error_code: err_code}}
  end

  # -- SII -------------------------------------------------------------------

  defp read_sii(link, station) do
    with {:ok, <<vid::32-little, pc::32-little, rev::32-little, sn::32-little>>} <-
           SII.read(link, station, 0x08, 8),
         {:ok, <<ro::16-little, rs::16-little, so::16-little, ss::16-little>>} <-
           SII.read(link, station, 0x18, 4) do
      {:ok, %{vendor_id: vid, product_code: pc, revision: rev, serial_number: sn},
       %{recv_offset: ro, recv_size: rs, send_offset: so, send_size: ss}}
    end
  end

  defp find_driver(vendor_id, product_code) do
    :ethercat |> Application.get_env(:drivers, %{}) |> Map.get({vendor_id, product_code})
  end

  defp invoke_driver(%{driver: nil}, _cb), do: :ok

  defp invoke_driver(data, cb) do
    if function_exported?(data.driver, cb, 2), do: apply(data.driver, cb, [data.station, data])
    :ok
  end

  defp via(station), do: {:via, Registry, {EtherCAT.Registry, {:slave, station}}}
end
