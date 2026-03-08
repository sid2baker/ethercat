defmodule EtherCAT.SlaveTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Slave.ProcessDataPlan.DomainAttachment
  alias EtherCAT.Slave.ProcessDataPlan.SmGroup

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

  defmodule BitDriver do
    @behaviour EtherCAT.Slave.Driver

    @impl true
    def process_data_model(_config), do: %{}

    @impl true
    def encode_signal(_signal, _config, value), do: <<value::8>>

    @impl true
    def decode_signal(_signal, _config, <<_::7, bit::1>>), do: bit

    @impl true
    def decode_signal(_signal, _config, _raw), do: 0
  end

  defmodule SplitOutputDriver do
    @behaviour EtherCAT.Slave.Driver

    @impl true
    def process_data_model(_config), do: [ch1: 0, ch2: 1]

    @impl true
    def encode_signal(_signal, _config, value), do: <<value::8>>

    @impl true
    def decode_signal(_signal, _config, raw), do: raw
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

  defmodule InvalidSyncModeDriver do
    @behaviour EtherCAT.Slave.Driver

    @impl true
    def process_data_model(_config), do: %{}

    @impl true
    def encode_signal(_signal, _config, _value), do: <<>>

    @impl true
    def decode_signal(_signal, _config, raw), do: raw

    @impl true
    def sync_mode(_config, _sync), do: [:bad_step]
  end

  defmodule OpHookDriver do
    @behaviour EtherCAT.Slave.Driver

    @impl true
    def process_data_model(_config), do: %{}

    @impl true
    def encode_signal(_signal, _config, _value), do: <<>>

    @impl true
    def decode_signal(_signal, _config, raw), do: raw

    @impl true
    def on_op(slave_name, _config) do
      send(self(), {:driver_on_op, slave_name})
      :ok
    end
  end

  defmodule FakeBus do
    use GenServer

    def start_link(responses) do
      GenServer.start_link(__MODULE__, responses)
    end

    @impl true
    def init(responses), do: {:ok, responses}

    @impl true
    def handle_call({:transact, _tx, _deadline_us, _enqueued_at_us}, _from, [reply | rest]) do
      {:reply, reply, rest}
    end

    def handle_call({:transact, _tx, _deadline_us, _enqueued_at_us}, _from, []) do
      {:reply, {:ok, [%{wkc: 0}]}, []}
    end
  end

  test "only dispatches subscribed signal updates when that signal changes inside a shared SM" do
    data = %EtherCAT.Slave{
      name: :sensor,
      driver: TestDriver,
      config: %{},
      signal_registrations: %{
        ch1: %{domain_id: :main, sm_key: {:sm, 0}, bit_offset: 0, bit_size: 1},
        ch2: %{domain_id: :main, sm_key: {:sm, 0}, bit_offset: 1, bit_size: 1}
      },
      signal_registrations_by_sm: %{
        {:main, {:sm, 0}} => [
          {:ch1, %{bit_offset: 0, bit_size: 1}},
          {:ch2, %{bit_offset: 1, bit_size: 1}}
        ]
      },
      subscriptions: %{ch1: MapSet.new([self()]), ch2: MapSet.new([self()])}
    }

    assert :keep_state_and_data =
             EtherCAT.Slave.handle_event(
               :info,
               {:domain_input, :main, {:sensor, {:sm, 0}}, :unset, <<0>>},
               :op,
               data
             )

    assert_receive {:ethercat, :signal, :sensor, :ch1, 0}
    assert_receive {:ethercat, :signal, :sensor, :ch2, 0}
    refute_receive _

    assert :keep_state_and_data =
             EtherCAT.Slave.handle_event(
               :info,
               {:domain_input, :main, {:sensor, {:sm, 0}}, <<0>>, <<2>>},
               :op,
               data
             )

    assert_receive {:ethercat, :signal, :sensor, :ch2, 1}
    refute_receive {:ethercat, :signal, :sensor, :ch1, _}
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

    assert_receive {:ethercat, :signal, :sensor, :ch1, 1}
    refute_receive {:ethercat, :signal, :sensor, :ch2, _}
  end

  test "dispatches only the signals attached to the notifying domain when one SM is split across domains" do
    data = %EtherCAT.Slave{
      name: :sensor,
      driver: TestDriver,
      config: %{},
      signal_registrations: %{
        fast_ch1: %{domain_id: :fast, sm_key: {:sm, 3}, bit_offset: 0, bit_size: 1},
        slow_ch2: %{domain_id: :slow, sm_key: {:sm, 3}, bit_offset: 1, bit_size: 1}
      },
      signal_registrations_by_sm: %{
        {:fast, {:sm, 3}} => [{:fast_ch1, %{bit_offset: 0, bit_size: 1}}],
        {:slow, {:sm, 3}} => [{:slow_ch2, %{bit_offset: 1, bit_size: 1}}]
      },
      subscriptions: %{fast_ch1: MapSet.new([self()]), slow_ch2: MapSet.new([self()])}
    }

    assert :keep_state_and_data =
             EtherCAT.Slave.handle_event(
               :info,
               {:domain_input, :fast, {:sensor, {:sm, 3}}, <<0>>, <<1>>},
               :op,
               data
             )

    assert_receive {:ethercat, :signal, :sensor, :fast_ch1, 1}
    refute_receive {:ethercat, :signal, :sensor, :slow_ch2, _}

    assert :keep_state_and_data =
             EtherCAT.Slave.handle_event(
               :info,
               {:domain_input, :slow, {:sensor, {:sm, 3}}, <<0>>, <<2>>},
               :op,
               data
             )

    assert_receive {:ethercat, :signal, :sensor, :slow_ch2, 1}
    refute_receive {:ethercat, :signal, :sensor, :fast_ch1, _}
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
                 subscriptions: %{},
                 sii_pdo_configs: [],
                 sii_sm_configs: []
               }
             )

    assert updated.configuration_error == {:invalid_mailbox_step, :bad_step}
  end

  test "info reports attachment-level FMMU usage and ESC capabilities" do
    from = {self(), make_ref()}

    data = %EtherCAT.Slave{
      name: :io,
      station: 0x1002,
      identity: %{vendor_id: 0x2, product_code: 0xAF93052, revision: 0, serial_number: 0},
      esc_info: %{fmmu_count: 3, sm_count: 4},
      driver: BitDriver,
      mailbox_config: %{recv_size: 0},
      signal_registrations: %{
        ch1: %{
          domain_id: :fast,
          sm_key: {:sm, 1},
          direction: :output,
          bit_offset: 0,
          bit_size: 1,
          logical_address: 0,
          sm_size: 2
        },
        ch2: %{
          domain_id: :slow,
          sm_key: {:sm, 1},
          direction: :output,
          bit_offset: 1,
          bit_size: 1,
          logical_address: 16,
          sm_size: 2
        }
      },
      configuration_error: nil
    }

    assert {:keep_state_and_data, [{:reply, ^from, {:ok, info}}]} =
             EtherCAT.Slave.handle_event({:call, from}, :info, :preop, data)

    assert info.esc == %{fmmu_count: 3, sm_count: 4}
    assert info.available_fmmus == 3
    assert info.used_fmmus == 2

    assert info.attachments == [
             %{
               direction: :output,
               domain: :fast,
               logical_address: 0,
               signal_count: 1,
               signals: [:ch1],
               sm_index: 1,
               sm_size: 2
             },
             %{
               direction: :output,
               domain: :slow,
               logical_address: 16,
               signal_count: 1,
               signals: [:ch2],
               sm_index: 1,
               sm_size: 2
             }
           ]
  end

  test "write_output rejects registered input signals" do
    from = {self(), make_ref()}

    assert {:keep_state_and_data, [{:reply, ^from, {:error, {:not_output, :ch1}}}]} =
             EtherCAT.Slave.handle_event(
               {:call, from},
               {:write_output, :ch1, 1},
               :op,
               %EtherCAT.Slave{
                 signal_registrations: %{
                   ch1: %{
                     domain_id: :main,
                     sm_key: {:sm, 0},
                     direction: :input,
                     bit_offset: 0,
                     bit_size: 1
                   }
                 }
               }
             )
  end

  test "read_input rejects registered output signals" do
    from = {self(), make_ref()}

    assert {:keep_state_and_data, [{:reply, ^from, {:error, {:not_input, :ch1}}}]} =
             EtherCAT.Slave.handle_event(
               {:call, from},
               {:read_input, :ch1},
               :op,
               %EtherCAT.Slave{
                 signal_registrations: %{
                   ch1: %{
                     domain_id: :main,
                     sm_key: {:sm, 1},
                     direction: :output,
                     bit_offset: 0,
                     bit_size: 1
                   }
                 }
               }
             )
  end

  test "write_output keeps split output SM staging coherent across attached domains" do
    fast_domain_id = :"domain_#{System.unique_integer([:positive])}_fast"
    slow_domain_id = :"domain_#{System.unique_integer([:positive])}_slow"
    key = {:valve, {:sm, 1}}
    fast_table = :ets.new(fast_domain_id, [:set, :public, :named_table])
    slow_table = :ets.new(slow_domain_id, [:set, :public, :named_table])
    :ets.insert(fast_table, {key, <<0>>, nil})
    :ets.insert(slow_table, {key, <<0>>, nil})

    from = {self(), make_ref()}
    initial_images = %{{:sm, 1} => <<0>>}
    attached_domains = %{{:sm, 1} => [fast_domain_id, slow_domain_id]}

    assert {:keep_state, %EtherCAT.Slave{output_sm_images: %{{:sm, 1} => <<1>>}},
            [{:reply, ^from, :ok}]} =
             EtherCAT.Slave.handle_event(
               {:call, from},
               {:write_output, :ch1, 1},
               :op,
               %EtherCAT.Slave{
                 name: :valve,
                 driver: BitDriver,
                 config: %{},
                 signal_registrations: %{
                   ch1: %{
                     domain_id: fast_domain_id,
                     sm_key: {:sm, 1},
                     direction: :output,
                     bit_offset: 0,
                     bit_size: 1,
                     sm_size: 1
                   },
                   ch2: %{
                     domain_id: slow_domain_id,
                     sm_key: {:sm, 1},
                     direction: :output,
                     bit_offset: 1,
                     bit_size: 1,
                     sm_size: 1
                   }
                 },
                 output_domain_ids_by_sm: attached_domains,
                 output_sm_images: initial_images
               }
             )

    assert [{^key, <<1>>, nil}] = :ets.lookup(fast_domain_id, key)
    assert [{^key, <<1>>, nil}] = :ets.lookup(slow_domain_id, key)

    assert {:keep_state, %EtherCAT.Slave{output_sm_images: %{{:sm, 1} => <<3>>}},
            [{:reply, ^from, :ok}]} =
             EtherCAT.Slave.handle_event(
               {:call, from},
               {:write_output, :ch2, 1},
               :op,
               %EtherCAT.Slave{
                 name: :valve,
                 driver: BitDriver,
                 config: %{},
                 signal_registrations: %{
                   ch1: %{
                     domain_id: fast_domain_id,
                     sm_key: {:sm, 1},
                     direction: :output,
                     bit_offset: 0,
                     bit_size: 1,
                     sm_size: 1
                   },
                   ch2: %{
                     domain_id: slow_domain_id,
                     sm_key: {:sm, 1},
                     direction: :output,
                     bit_offset: 1,
                     bit_size: 1,
                     sm_size: 1
                   }
                 },
                 output_domain_ids_by_sm: attached_domains,
                 output_sm_images: %{{:sm, 1} => <<1>>}
               }
             )

    assert [{^key, <<3>>, nil}] = :ets.lookup(fast_domain_id, key)
    assert [{^key, <<3>>, nil}] = :ets.lookup(slow_domain_id, key)
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
                 subscriptions: %{},
                 subscriber_refs: %{}
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

    assert Map.fetch!(subscribed_again.subscriptions, :ch1) == MapSet.new([pid])

    assert {:keep_state, cleaned} =
             EtherCAT.Slave.handle_event(
               :info,
               {:DOWN, ref, :process, pid, :normal},
               :preop,
               subscribed_again
             )

    assert cleaned.subscriptions == %{}
    assert cleaned.subscriber_refs == %{}
  end

  test "preop configure allows sync updates after process-data registration" do
    from = {self(), make_ref()}
    sync = %EtherCAT.Slave.Sync.Config{mode: :sync0, sync0: %{pulse_ns: 5_000, shift_ns: 0}}

    assert {:keep_state, %EtherCAT.Slave{} = updated, [{:reply, ^from, :ok}]} =
             EtherCAT.Slave.handle_event(
               {:call, from},
               {:configure, [sync: sync]},
               :preop,
               %EtherCAT.Slave{
                 driver: TestDriver,
                 config: %{},
                 process_data_request: :none,
                 signal_registrations: %{ch1: %{domain_id: :main}},
                 sync_config: nil
               }
             )

    assert updated.sync_config == sync
  end

  test "preop configure allows health poll updates after process-data registration" do
    from = {self(), make_ref()}

    assert {:keep_state, %EtherCAT.Slave{} = updated, [{:reply, ^from, :ok}]} =
             EtherCAT.Slave.handle_event(
               {:call, from},
               {:configure, [health_poll_ms: 250]},
               :preop,
               %EtherCAT.Slave{
                 driver: TestDriver,
                 config: %{},
                 process_data_request: :none,
                 signal_registrations: %{ch1: %{domain_id: :main}},
                 health_poll_ms: nil
               }
             )

    assert updated.health_poll_ms == 250
  end

  test "preop configure rejects process-data layouts that exceed available FMMUs" do
    from = {self(), make_ref()}

    data = %EtherCAT.Slave{
      name: :outputs,
      driver: SplitOutputDriver,
      config: %{},
      process_data_request: :none,
      signal_registrations: %{},
      esc_info: %{fmmu_count: 1, sm_count: 4},
      sii_sm_configs: [{2, 0x1100, 2, 0x64}],
      sii_pdo_configs: [
        %{index: 0, direction: :output, sm_index: 2, bit_size: 8, bit_offset: 0},
        %{index: 1, direction: :output, sm_index: 2, bit_size: 8, bit_offset: 8}
      ]
    }

    assert {:keep_state,
            %EtherCAT.Slave{configuration_error: {:fmmu_limit_reached, 2, 1}} = updated,
            [{:reply, ^from, {:error, {:fmmu_limit_reached, 2, 1}}}]} =
             EtherCAT.Slave.handle_event(
               {:call, from},
               {:configure, [process_data: [ch1: :fast, ch2: :slow]]},
               :preop,
               data
             )

    assert updated.signal_registrations == %{}
  end

  test "cached_domain_offset reuses a compatible SM logical address" do
    sm_group = %SmGroup{
      sm_index: 2,
      sm_key: {:sm, 2},
      direction: :output,
      phys: 0x1000,
      ctrl: 0x64,
      total_sm_size: 2,
      fmmu_type: 0x02,
      attachments: [
        %DomainAttachment{
          domain_id: :main,
          registrations: [
            %{signal_name: :ch1, bit_offset: 0, bit_size: 8},
            %{signal_name: :ch2, bit_offset: 8, bit_size: 8}
          ]
        }
      ]
    }

    [attachment] = sm_group.attachments

    registrations = %{
      ch1: %{
        domain_id: :main,
        sm_key: {:sm, 2},
        direction: :output,
        bit_offset: 0,
        bit_size: 8,
        logical_address: 0x2000,
        sm_size: 2
      },
      ch2: %{
        domain_id: :main,
        sm_key: {:sm, 2},
        direction: :output,
        bit_offset: 8,
        bit_size: 8,
        logical_address: 0x2000,
        sm_size: 2
      }
    }

    assert {:ok, 0x2000} =
             EtherCAT.Slave.cached_domain_offset(registrations, sm_group, attachment)

    assert :error =
             EtherCAT.Slave.cached_domain_offset(
               put_in(registrations, [:ch2, :logical_address], 0x2001),
               sm_group,
               attachment
             )
  end

  test "preop sync-only reconfigure rejects invalid sync_mode mailbox steps" do
    from = {self(), make_ref()}
    sync = %EtherCAT.Slave.Sync.Config{mode: :sync0, sync0: %{pulse_ns: 5_000, shift_ns: 0}}

    original =
      %EtherCAT.Slave{
        driver: InvalidSyncModeDriver,
        config: %{},
        process_data_request: :none,
        signal_registrations: %{ch1: %{domain_id: :main}},
        sync_config: nil
      }

    assert {:keep_state, unchanged,
            [{:reply, ^from, {:error, {:invalid_mailbox_step, :bad_step}}}]} =
             EtherCAT.Slave.handle_event(
               {:call, from},
               {:configure, [sync: sync]},
               :preop,
               original
             )

    assert unchanged.sync_config == nil
  end

  test "entering op only arms latch polling and does not invoke on_op twice" do
    assert {:keep_state_and_data, []} =
             EtherCAT.Slave.handle_event(
               :enter,
               :safeop,
               :op,
               %EtherCAT.Slave{
                 name: :axis,
                 driver: OpHookDriver,
                 config: %{},
                 latch_poll_ms: nil
               }
             )

    refute_receive {:driver_on_op, :axis}
  end

  test "down waits for master reconnect authorization after the link returns" do
    bus =
      start_supervised!({FakeBus, [{:ok, [%{data: <<0>>, wkc: 1, circular: false, irq: 0}]}]})

    data = %EtherCAT.Slave{
      bus: bus,
      station: 0x1001,
      name: :sensor,
      health_poll_ms: 250
    }

    assert {:keep_state, %EtherCAT.Slave{reconnect_ready?: true}, _actions} =
             EtherCAT.Slave.handle_event({:timeout, :health_poll}, nil, :down, data)

    from = {self(), make_ref()}

    assert {:keep_state_and_data, [{:reply, ^from, {:error, :not_reconnected}}]} =
             EtherCAT.Slave.handle_event(
               {:call, from},
               :authorize_reconnect,
               :down,
               %EtherCAT.Slave{reconnect_ready?: false}
             )
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
