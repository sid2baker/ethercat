defmodule EtherCAT.SlaveTest do
  use ExUnit.Case, async: true

  defmodule TestDriver do
    @behaviour EtherCAT.Slave.Driver

    @impl true
    def process_data_model(_config), do: %{}

    @impl true
    def encode_signal(_signal, _config, _value), do: <<>>

    @impl true
    def decode_signal(_signal, _config, <<_::7, bit::1>>), do: bit

    @impl true
    def decode_signal(_signal, _config, _raw), do: 0
  end

  defmodule InvalidMailboxDriver do
    @behaviour EtherCAT.Slave.Driver

    @impl true
    def process_data_model(_config), do: %{}

    @impl true
    def encode_signal(_signal, _config, _value), do: <<>>

    @impl true
    def decode_signal(_signal, _config, raw), do: raw

    @impl true
    def mailbox_config(_config), do: [:bad_step]
  end

  test "only dispatches subscribed signal updates when that signal changes inside a shared SM" do
    data = %EtherCAT.Slave{
      name: :sensor,
      driver: TestDriver,
      config: %{},
      signal_registrations: %{
        ch1: %{sm_key: {:sm, 0}, bit_offset: 0, bit_size: 1},
        ch2: %{sm_key: {:sm, 0}, bit_offset: 1, bit_size: 1}
      },
      signal_registrations_by_sm: %{
        {:sm, 0} => [
          {:ch1, %{bit_offset: 0, bit_size: 1}},
          {:ch2, %{bit_offset: 1, bit_size: 1}}
        ]
      },
      input_subscriptions: %{ch1: MapSet.new([self()]), ch2: MapSet.new([self()])}
    }

    assert :keep_state_and_data =
             EtherCAT.Slave.handle_event(
               :info,
               {:domain_input, :main, {:sensor, {:sm, 0}}, :unset, <<0>>},
               :op,
               data
             )

    assert_receive {:slave_input, :sensor, :ch1, 0}
    assert_receive {:slave_input, :sensor, :ch2, 0}
    refute_receive _

    assert :keep_state_and_data =
             EtherCAT.Slave.handle_event(
               :info,
               {:domain_input, :main, {:sensor, {:sm, 0}}, <<0>>, <<2>>},
               :op,
               data
             )

    assert_receive {:slave_input, :sensor, :ch2, 1}
    refute_receive {:slave_input, :sensor, :ch1, _}
    refute_receive _

    assert :keep_state_and_data =
             EtherCAT.Slave.handle_event(
               :info,
               {:domain_input, :main, {:sensor, {:sm, 0}}, <<2>>, <<2>>},
               :op,
               data
             )

    refute_receive _

    assert :keep_state_and_data =
             EtherCAT.Slave.handle_event(
               :info,
               {:domain_input, :main, {:sensor, {:sm, 0}}, <<2>>, <<3>>},
               :op,
               data
             )

    assert_receive {:slave_input, :sensor, :ch1, 1}
    refute_receive {:slave_input, :sensor, :ch2, _}
  end

  test "preop rejects safeop and op requests when local configuration failed" do
    from = {self(), make_ref()}

    assert {:keep_state_and_data,
            [{:reply, ^from, {:error, {:preop_configuration_failed, :bad_pdo}}}]} =
             EtherCAT.Slave.handle_event(
               {:call, from},
               {:request, :safeop},
               :preop,
               %EtherCAT.Slave{configuration_error: :bad_pdo}
             )

    assert {:keep_state_and_data,
            [{:reply, ^from, {:error, {:preop_configuration_failed, :bad_pdo}}}]} =
             EtherCAT.Slave.handle_event(
               {:call, from},
               {:request, :op},
               :preop,
               %EtherCAT.Slave{configuration_error: :bad_pdo}
             )
  end

  test "preop configure rejects local process-data changes after registration" do
    from = {self(), make_ref()}

    assert {:keep_state, %EtherCAT.Slave{driver: TestDriver} = updated, [{:reply, ^from, :ok}]} =
             EtherCAT.Slave.handle_event(
               {:call, from},
               {:configure, [driver: TestDriver]},
               :preop,
               %EtherCAT.Slave{
                 driver: TestDriver,
                 config: %{},
                 process_data_request: :none,
                 signal_registrations: %{ch1: %{domain_id: :main}}
               }
             )

    assert updated.signal_registrations == %{ch1: %{domain_id: :main}}

    assert {:keep_state_and_data, [{:reply, ^from, {:error, :not_preop}}]} =
             EtherCAT.Slave.handle_event(
               {:call, from},
               {:configure, [driver: TestDriver]},
               :safeop,
               %EtherCAT.Slave{}
             )

    assert {:keep_state, _data, [{:reply, ^from, {:error, :already_configured}}]} =
             EtherCAT.Slave.handle_event(
               {:call, from},
               {:configure, [process_data: {:all, :main}]},
               :preop,
               %EtherCAT.Slave{
                 driver: TestDriver,
                 config: %{},
                 process_data_request: :none,
                 signal_registrations: %{ch1: %{domain_id: :main}}
               }
             )
  end

  test "invalid mailbox configuration blocks PREOP activation" do
    from = {self(), make_ref()}

    assert {:keep_state, %EtherCAT.Slave{} = updated,
            [{:reply, ^from, {:error, {:invalid_mailbox_step, :bad_step}}}]} =
             EtherCAT.Slave.handle_event(
               {:call, from},
               {:configure, []},
               :preop,
               %EtherCAT.Slave{
                 name: :sensor,
                 driver: InvalidMailboxDriver,
                 config: %{},
                 process_data_request: :none,
                 signal_registrations: %{},
                 input_subscriptions: %{},
                 sii_pdo_configs: [],
                 sii_sm_configs: []
               }
             )

    assert updated.configuration_error == {:invalid_mailbox_step, :bad_step}
  end

  test "subscriptions are deduplicated and removed when subscribers exit" do
    from = {self(), make_ref()}
    pid = self()

    assert {:keep_state, subscribed, [{:reply, ^from, :ok}]} =
             EtherCAT.Slave.handle_event(
               {:call, from},
               {:subscribe, :ch1, pid},
               :preop,
               %EtherCAT.Slave{
                 input_subscriptions: %{},
                 subscriber_refs: %{},
                 latch_subscriptions: %{}
               }
             )

    ref = Map.fetch!(subscribed.subscriber_refs, pid)

    assert {:keep_state, subscribed_again, [{:reply, ^from, :ok}]} =
             EtherCAT.Slave.handle_event(
               {:call, from},
               {:subscribe, :ch1, pid},
               :preop,
               subscribed
             )

    assert Map.fetch!(subscribed_again.input_subscriptions, :ch1) == MapSet.new([pid])

    assert {:keep_state, cleaned} =
             EtherCAT.Slave.handle_event(
               :info,
               {:DOWN, ref, :process, pid, :normal},
               :preop,
               subscribed_again
             )

    assert cleaned.input_subscriptions == %{}
    assert cleaned.latch_subscriptions == %{}
    assert cleaned.subscriber_refs == %{}
  end

  test "sdo upload and download reject calls before mailbox setup" do
    from = {self(), make_ref()}

    assert {:keep_state_and_data, [{:reply, ^from, {:error, :mailbox_not_ready}}]} =
             EtherCAT.Slave.handle_event(
               {:call, from},
               {:download_sdo, 0x2000, 0x01, <<1, 2, 3>>},
               :init,
               %EtherCAT.Slave{}
             )

    assert {:keep_state_and_data, [{:reply, ^from, {:error, :mailbox_not_ready}}]} =
             EtherCAT.Slave.handle_event(
               {:call, from},
               {:upload_sdo, 0x2000, 0x01},
               :init,
               %EtherCAT.Slave{}
             )
  end
end
