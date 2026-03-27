defmodule EtherCAT.SlaveTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Domain.Image
  alias EtherCAT.Slave.ProcessData
  alias EtherCAT.Slave.ProcessData.Plan.DomainAttachment
  alias EtherCAT.Slave.ProcessData.Plan.SmGroup
  alias EtherCAT.TestSupport.FakeBus

  defmodule TestDriver do
    @behaviour EtherCAT.Driver

    @impl true
    def signal_model(_config, _sii_pdo_configs), do: []

    @impl true
    def encode_signal(_signal, _config, _value), do: <<>>

    @impl true
    def decode_signal(_signal, _config, <<_::7, bit::1>>), do: bit

    @impl true
    def decode_signal(_signal, _config, _raw), do: 0

    @impl true
    def project_state(decoded_inputs, _prev_state, driver_state, _config) do
      {:ok, decoded_inputs, driver_state, [], []}
    end

    @impl true
    def command(command, _state, _driver_state, _config),
      do: EtherCAT.Driver.unsupported_command(command)
  end

  defmodule BitDriver do
    @behaviour EtherCAT.Driver

    @impl true
    def signal_model(_config, _sii_pdo_configs), do: []

    @impl true
    def encode_signal(_signal, _config, value), do: <<value::8>>

    @impl true
    def decode_signal(_signal, _config, <<_::7, bit::1>>), do: bit

    @impl true
    def decode_signal(_signal, _config, _raw), do: 0

    @impl true
    def project_state(decoded_inputs, _prev_state, driver_state, _config) do
      {:ok, decoded_inputs, driver_state, [], []}
    end

    @impl true
    def command(command, _state, _driver_state, _config),
      do: EtherCAT.Driver.unsupported_command(command)
  end

  defmodule SplitOutputDriver do
    @behaviour EtherCAT.Driver

    @impl true
    def signal_model(_config, _sii_pdo_configs), do: [ch1: 0, ch2: 1]

    @impl true
    def encode_signal(_signal, _config, value), do: <<value::8>>

    @impl true
    def decode_signal(_signal, _config, raw), do: raw

    @impl true
    def project_state(decoded_inputs, _prev_state, driver_state, _config) do
      {:ok, decoded_inputs, driver_state, [], []}
    end

    @impl true
    def command(command, _state, _driver_state, _config),
      do: EtherCAT.Driver.unsupported_command(command)
  end

  defmodule InvalidMailboxDriver do
    @behaviour EtherCAT.Driver
    @behaviour EtherCAT.Driver.Provisioning

    @impl true
    def signal_model(_config, _sii_pdo_configs), do: []

    @impl true
    def encode_signal(_signal, _config, _value), do: <<>>

    @impl true
    def decode_signal(_signal, _config, raw), do: raw

    @impl true
    def mailbox_steps(_config, %{phase: :preop}), do: [:bad_step]
    def mailbox_steps(_config, _context), do: []

    @impl true
    def project_state(decoded_inputs, _prev_state, driver_state, _config) do
      {:ok, decoded_inputs, driver_state, [], []}
    end

    @impl true
    def command(command, _state, _driver_state, _config),
      do: EtherCAT.Driver.unsupported_command(command)
  end

  defmodule InvalidSyncModeDriver do
    @behaviour EtherCAT.Driver
    @behaviour EtherCAT.Driver.Provisioning

    @impl true
    def signal_model(_config, _sii_pdo_configs), do: []

    @impl true
    def encode_signal(_signal, _config, _value), do: <<>>

    @impl true
    def decode_signal(_signal, _config, raw), do: raw

    @impl true
    def mailbox_steps(_config, %{phase: :sync_update}), do: [:bad_step]
    def mailbox_steps(_config, _context), do: []

    @impl true
    def project_state(decoded_inputs, _prev_state, driver_state, _config) do
      {:ok, decoded_inputs, driver_state, [], []}
    end

    @impl true
    def command(command, _state, _driver_state, _config),
      do: EtherCAT.Driver.unsupported_command(command)
  end

  test "only dispatches subscribed signal updates when that signal changes inside a shared SM" do
    domain_id = :"shared_sm_domain_#{System.unique_integer([:positive, :monotonic])}"
    key = {:sensor, {:sm, 0}}
    :ets.new(domain_id, [:set, :public, :named_table])
    :ets.insert(domain_id, {key, <<0>>, {:input, nil}})
    Image.put_domain_status(domain_id, System.monotonic_time(:microsecond), 1_000_000)

    on_exit(fn ->
      if :ets.whereis(domain_id) != :undefined do
        :ets.delete(domain_id)
      end
    end)

    data = %EtherCAT.Slave{
      name: :sensor,
      driver: TestDriver,
      config: %{},
      signal_registrations: %{
        ch1: %{
          domain_id: domain_id,
          sm_key: {:sm, 0},
          bit_offset: 0,
          bit_size: 1,
          direction: :input
        },
        ch2: %{
          domain_id: domain_id,
          sm_key: {:sm, 0},
          bit_offset: 1,
          bit_size: 1,
          direction: :input
        }
      },
      signal_registrations_by_sm: %{
        {domain_id, {:sm, 0}} => [
          {:ch1, %{bit_offset: 0, bit_size: 1}},
          {:ch2, %{bit_offset: 1, bit_size: 1}}
        ]
      },
      subscriptions: %{ch1: MapSet.new([self()]), ch2: MapSet.new([self()])}
    }

    initial_at_us = System.monotonic_time(:microsecond)
    :ets.insert(domain_id, {key, <<0>>, {:input, initial_at_us}})
    Image.put_domain_status(domain_id, initial_at_us, 1_000_000)

    assert {:keep_state, _updated_data} =
             EtherCAT.Slave.FSM.handle_event(
               :info,
               {:domain_inputs, domain_id, 1, [{{:sensor, {:sm, 0}}, :unset, <<0>>}],
                initial_at_us},
               :op,
               data
             )

    assert_receive {:ethercat, :signal, :sensor, :ch1, 0}
    assert_receive {:ethercat, :signal, :sensor, :ch2, 0}
    refute_receive _

    changed_at_us = System.monotonic_time(:microsecond)
    :ets.insert(domain_id, {key, <<2>>, {:input, changed_at_us}})
    Image.put_domain_status(domain_id, changed_at_us, 1_000_000)

    assert {:keep_state, _updated_data} =
             EtherCAT.Slave.FSM.handle_event(
               :info,
               {:domain_inputs, domain_id, 2, [{{:sensor, {:sm, 0}}, <<0>>, <<2>>}],
                changed_at_us},
               :op,
               data
             )

    assert_receive {:ethercat, :signal, :sensor, :ch2, 1}
    refute_receive {:ethercat, :signal, :sensor, :ch1, _}
    refute_receive _

    unchanged_at_us = System.monotonic_time(:microsecond)
    :ets.insert(domain_id, {key, <<2>>, {:input, unchanged_at_us}})
    Image.put_domain_status(domain_id, unchanged_at_us, 1_000_000)

    assert {:keep_state, _updated_data} =
             EtherCAT.Slave.FSM.handle_event(
               :info,
               {:domain_inputs, domain_id, 3, [{{:sensor, {:sm, 0}}, <<2>>, <<2>>}],
                unchanged_at_us},
               :op,
               data
             )

    refute_receive _

    final_at_us = System.monotonic_time(:microsecond)
    :ets.insert(domain_id, {key, <<3>>, {:input, final_at_us}})
    Image.put_domain_status(domain_id, final_at_us, 1_000_000)

    assert {:keep_state, _updated_data} =
             EtherCAT.Slave.FSM.handle_event(
               :info,
               {:domain_inputs, domain_id, 4, [{{:sensor, {:sm, 0}}, <<2>>, <<3>>}], final_at_us},
               :op,
               data
             )

    assert_receive {:ethercat, :signal, :sensor, :ch1, 1}
    refute_receive {:ethercat, :signal, :sensor, :ch2, _}
  end

  test "dispatches only the signals attached to the notifying domain when one SM is split across domains" do
    fast_domain = :"fast_domain_#{System.unique_integer([:positive, :monotonic])}"
    slow_domain = :"slow_domain_#{System.unique_integer([:positive, :monotonic])}"
    fast_key = {:sensor, {:sm, 3}}
    slow_key = {:sensor, {:sm, 3}}
    :ets.new(fast_domain, [:set, :public, :named_table])
    :ets.new(slow_domain, [:set, :public, :named_table])
    :ets.insert(fast_domain, {fast_key, <<0>>, {:input, nil}})
    :ets.insert(slow_domain, {slow_key, <<0>>, {:input, nil}})
    Image.put_domain_status(fast_domain, System.monotonic_time(:microsecond), 1_000_000)
    Image.put_domain_status(slow_domain, System.monotonic_time(:microsecond), 1_000_000)

    on_exit(fn ->
      if :ets.whereis(fast_domain) != :undefined do
        :ets.delete(fast_domain)
      end

      if :ets.whereis(slow_domain) != :undefined do
        :ets.delete(slow_domain)
      end
    end)

    data = %EtherCAT.Slave{
      name: :sensor,
      driver: TestDriver,
      config: %{},
      signal_registrations: %{
        fast_ch1: %{
          domain_id: fast_domain,
          sm_key: {:sm, 3},
          bit_offset: 0,
          bit_size: 1,
          direction: :input
        },
        slow_ch2: %{
          domain_id: slow_domain,
          sm_key: {:sm, 3},
          bit_offset: 1,
          bit_size: 1,
          direction: :input
        }
      },
      signal_registrations_by_sm: %{
        {fast_domain, {:sm, 3}} => [{:fast_ch1, %{bit_offset: 0, bit_size: 1}}],
        {slow_domain, {:sm, 3}} => [{:slow_ch2, %{bit_offset: 1, bit_size: 1}}]
      },
      subscriptions: %{fast_ch1: MapSet.new([self()]), slow_ch2: MapSet.new([self()])}
    }

    fast_at_us = System.monotonic_time(:microsecond)
    :ets.insert(fast_domain, {fast_key, <<1>>, {:input, fast_at_us}})
    Image.put_domain_status(fast_domain, fast_at_us, 1_000_000)

    assert {:keep_state, _updated_data} =
             EtherCAT.Slave.FSM.handle_event(
               :info,
               {:domain_inputs, fast_domain, 1, [{{:sensor, {:sm, 3}}, <<0>>, <<1>>}],
                fast_at_us},
               :op,
               data
             )

    assert_receive {:ethercat, :signal, :sensor, :fast_ch1, 1}
    refute_receive {:ethercat, :signal, :sensor, :slow_ch2, _}

    slow_at_us = System.monotonic_time(:microsecond)
    :ets.insert(slow_domain, {slow_key, <<2>>, {:input, slow_at_us}})
    Image.put_domain_status(slow_domain, slow_at_us, 1_000_000)

    assert {:keep_state, _updated_data} =
             EtherCAT.Slave.FSM.handle_event(
               :info,
               {:domain_inputs, slow_domain, 1, [{{:sensor, {:sm, 3}}, <<0>>, <<2>>}],
                slow_at_us},
               :op,
               data
             )

    assert_receive {:ethercat, :signal, :sensor, :slow_ch2, 1}
    refute_receive {:ethercat, :signal, :sensor, :fast_ch1, _}
  end

  test "read_input returns decoded value with update time" do
    domain_id = :"sample_domain_#{System.unique_integer([:positive, :monotonic])}"
    key = {:sensor, {:sm, 0}}
    :ets.new(domain_id, [:set, :public, :named_table])
    refreshed_at_us = System.monotonic_time(:microsecond)
    :ets.insert(domain_id, {key, <<1>>, {:input, refreshed_at_us - 10_000}})
    Image.put_domain_status(domain_id, refreshed_at_us, 1_000_000)

    data = %EtherCAT.Slave{
      name: :sensor,
      driver: TestDriver,
      config: %{},
      signal_registrations: %{
        ch1: %{
          domain_id: domain_id,
          sm_key: {:sm, 0},
          bit_offset: 0,
          bit_size: 1,
          direction: :input
        }
      }
    }

    from = {self(), make_ref()}

    assert {:keep_state_and_data, [{:reply, ^from, {:ok, {1, ^refreshed_at_us}}}]} =
             EtherCAT.Slave.FSM.handle_event(
               {:call, from},
               {:read_input, :ch1},
               :op,
               data
             )
  end

  test "read_input rejects stale cached input samples" do
    domain_id = :"stale_domain_#{System.unique_integer([:positive, :monotonic])}"
    key = {:sensor, {:sm, 0}}
    :ets.new(domain_id, [:set, :public, :named_table])
    :ets.insert(domain_id, {key, <<1>>, {:input, System.monotonic_time(:microsecond) - 20_000}})

    refreshed_at_us = System.monotonic_time(:microsecond) - 5_000
    Image.put_domain_status(domain_id, refreshed_at_us, 1_000)

    data = %EtherCAT.Slave{
      name: :sensor,
      driver: TestDriver,
      config: %{},
      signal_registrations: %{
        ch1: %{
          domain_id: domain_id,
          sm_key: {:sm, 0},
          bit_offset: 0,
          bit_size: 1,
          direction: :input
        }
      }
    }

    from = {self(), make_ref()}

    assert {:keep_state_and_data,
            [
              {:reply, ^from,
               {:error,
                {:stale,
                 %{refreshed_at_us: ^refreshed_at_us, age_us: age_us, stale_after_us: 1_000}}}}
            ]} =
             EtherCAT.Slave.FSM.handle_event(
               {:call, from},
               {:read_input, :ch1},
               :op,
               data
             )

    assert is_integer(age_us)
    assert age_us > 1_000
  end

  test "preop rejects safeop and op requests when local configuration failed" do
    from = {self(), make_ref()}

    assert {:keep_state_and_data,
            [{:reply, ^from, {:error, {:preop_configuration_failed, :bad_pdo}}}]} =
             EtherCAT.Slave.FSM.handle_event(
               {:call, from},
               {:request, :safeop},
               :preop,
               %EtherCAT.Slave{configuration_error: :bad_pdo}
             )

    assert {:keep_state_and_data,
            [{:reply, ^from, {:error, {:preop_configuration_failed, :bad_pdo}}}]} =
             EtherCAT.Slave.FSM.handle_event(
               {:call, from},
               {:request, :op},
               :preop,
               %EtherCAT.Slave{configuration_error: :bad_pdo}
             )
  end

  test "preop configure rejects local process-data changes after registration" do
    from = {self(), make_ref()}

    assert {:keep_state, %EtherCAT.Slave{driver: TestDriver} = updated,
            [{:reply, ^from, :ok}, {{:timeout, :health_poll}, :cancel}]} =
             EtherCAT.Slave.FSM.handle_event(
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
             EtherCAT.Slave.FSM.handle_event(
               {:call, from},
               {:configure, [driver: TestDriver]},
               :safeop,
               %EtherCAT.Slave{}
             )

    assert {:keep_state, _data, [{:reply, ^from, {:error, :already_configured}}]} =
             EtherCAT.Slave.FSM.handle_event(
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

  test "preop configure re-arms or cancels health polling when health_poll_ms changes" do
    from = {self(), make_ref()}

    assert {:keep_state, %EtherCAT.Slave{health_poll_ms: 20},
            [{:reply, ^from, :ok}, {{:timeout, :health_poll}, 20, nil}]} =
             EtherCAT.Slave.FSM.handle_event(
               {:call, from},
               {:configure, [health_poll_ms: 20]},
               :preop,
               %EtherCAT.Slave{
                 driver: TestDriver,
                 config: %{},
                 process_data_request: :none,
                 signal_registrations: %{},
                 subscriptions: %{},
                 sii_pdo_configs: [],
                 sii_sm_configs: [],
                 health_poll_ms: nil
               }
             )

    assert {:keep_state, %EtherCAT.Slave{health_poll_ms: nil},
            [{:reply, ^from, :ok}, {{:timeout, :health_poll}, :cancel}]} =
             EtherCAT.Slave.FSM.handle_event(
               {:call, from},
               {:configure, [health_poll_ms: nil]},
               :preop,
               %EtherCAT.Slave{
                 driver: TestDriver,
                 config: %{},
                 process_data_request: :none,
                 signal_registrations: %{},
                 subscriptions: %{},
                 sii_pdo_configs: [],
                 sii_sm_configs: [],
                 health_poll_ms: 20
               }
             )
  end

  test "invalid mailbox configuration blocks PREOP activation" do
    from = {self(), make_ref()}

    assert {:keep_state, %EtherCAT.Slave{} = updated,
            [{:reply, ^from, {:error, {:invalid_mailbox_step, :bad_step}}}]} =
             EtherCAT.Slave.FSM.handle_event(
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
             EtherCAT.Slave.FSM.handle_event({:call, from}, :info, :preop, data)

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
             EtherCAT.Slave.FSM.handle_event(
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
             EtherCAT.Slave.FSM.handle_event(
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
             EtherCAT.Slave.FSM.handle_event(
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

    assert [{^key, <<1>>, {:output, fast_updated_at_us}}] = :ets.lookup(fast_domain_id, key)
    assert is_integer(fast_updated_at_us)
    assert [{^key, <<1>>, {:output, slow_updated_at_us}}] = :ets.lookup(slow_domain_id, key)
    assert is_integer(slow_updated_at_us)

    assert {:keep_state, %EtherCAT.Slave{output_sm_images: %{{:sm, 1} => <<3>>}},
            [{:reply, ^from, :ok}]} =
             EtherCAT.Slave.FSM.handle_event(
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

    assert [{^key, <<3>>, {:output, fast_updated_at_us}}] = :ets.lookup(fast_domain_id, key)
    assert is_integer(fast_updated_at_us)
    assert [{^key, <<3>>, {:output, slow_updated_at_us}}] = :ets.lookup(slow_domain_id, key)
    assert is_integer(slow_updated_at_us)
  end

  test "subscriptions are deduplicated and removed when subscribers exit" do
    from = {self(), make_ref()}
    pid = self()

    assert {:keep_state, subscribed, [{:reply, ^from, :ok}]} =
             EtherCAT.Slave.FSM.handle_event(
               {:call, from},
               {:subscribe, :ch1, pid},
               :preop,
               %EtherCAT.Slave{
                 signal_registrations: %{ch1: %{domain_id: :main}},
                 subscriptions: %{},
                 subscriber_refs: %{}
               }
             )

    ref = Map.fetch!(subscribed.subscriber_refs, pid)

    assert {:keep_state, subscribed_again, [{:reply, ^from, :ok}]} =
             EtherCAT.Slave.FSM.handle_event(
               {:call, from},
               {:subscribe, :ch1, pid},
               :preop,
               subscribed
             )

    assert Map.fetch!(subscribed_again.subscriptions, :ch1) == MapSet.new([pid])

    assert {:keep_state, cleaned} =
             EtherCAT.Slave.FSM.handle_event(
               :info,
               {:DOWN, ref, :process, pid, :normal},
               :preop,
               subscribed_again
             )

    assert cleaned.subscriptions == %{}
    assert cleaned.subscriber_refs == %{}
  end

  test "subscribe rejects unknown signal and latch names" do
    from = {self(), make_ref()}

    assert {:keep_state_and_data, [{:reply, ^from, {:error, {:not_registered, :missing}}}]} =
             EtherCAT.Slave.FSM.handle_event(
               {:call, from},
               {:subscribe, :missing, self()},
               :preop,
               %EtherCAT.Slave{
                 signal_registrations: %{},
                 latch_names: %{},
                 subscriptions: %{},
                 subscriber_refs: %{}
               }
             )
  end

  test "subscribe accepts configured latch names" do
    from = {self(), make_ref()}
    pid = self()

    assert {:keep_state, subscribed, [{:reply, ^from, :ok}]} =
             EtherCAT.Slave.FSM.handle_event(
               {:call, from},
               {:subscribe, :rise, pid},
               :preop,
               %EtherCAT.Slave{
                 signal_registrations: %{},
                 latch_names: %{{0, :pos} => :rise},
                 subscriptions: %{},
                 subscriber_refs: %{}
               }
             )

    assert Map.fetch!(subscribed.subscriptions, :rise) == MapSet.new([pid])
    assert Map.has_key?(subscribed.subscriber_refs, pid)
  end

  test "preop configure allows sync updates after process-data registration" do
    from = {self(), make_ref()}
    sync = %EtherCAT.Slave.Sync.Config{mode: :sync0, sync0: %{pulse_ns: 5_000, shift_ns: 0}}

    assert {:keep_state, %EtherCAT.Slave{} = updated,
            [{:reply, ^from, :ok}, {{:timeout, :health_poll}, :cancel}]} =
             EtherCAT.Slave.FSM.handle_event(
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

    assert {:keep_state, %EtherCAT.Slave{} = updated,
            [{:reply, ^from, :ok}, {{:timeout, :health_poll}, 250, nil}]} =
             EtherCAT.Slave.FSM.handle_event(
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
             EtherCAT.Slave.FSM.handle_event(
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
             ProcessData.cached_domain_offset(registrations, sm_group, attachment)

    assert :error =
             ProcessData.cached_domain_offset(
               put_in(registrations, [:ch2, :logical_address], 0x2001),
               sm_group,
               attachment
             )
  end

  test "cached_domain_offset keeps split-SM reconnect caches attachment-aware" do
    sm_group = %SmGroup{
      sm_index: 3,
      sm_key: {:sm, 3},
      direction: :input,
      phys: 0x1200,
      ctrl: 0x00,
      total_sm_size: 2,
      fmmu_type: 0x01,
      attachments: [
        %DomainAttachment{
          domain_id: :fast,
          registrations: [%{signal_name: :ch1, bit_offset: 0, bit_size: 8}]
        },
        %DomainAttachment{
          domain_id: :slow,
          registrations: [%{signal_name: :ch2, bit_offset: 8, bit_size: 8}]
        }
      ]
    }

    [fast_attachment, slow_attachment] = sm_group.attachments

    registrations = %{
      ch1: %{
        domain_id: :fast,
        sm_key: {:sm, 3},
        direction: :input,
        bit_offset: 0,
        bit_size: 8,
        logical_address: 0x3000,
        sm_size: 2
      },
      ch2: %{
        domain_id: :slow,
        sm_key: {:sm, 3},
        direction: :input,
        bit_offset: 8,
        bit_size: 8,
        logical_address: 0x3010,
        sm_size: 2
      }
    }

    assert {:ok, 0x3000} =
             ProcessData.cached_domain_offset(registrations, sm_group, fast_attachment)

    assert {:ok, 0x3010} =
             ProcessData.cached_domain_offset(registrations, sm_group, slow_attachment)

    assert :error =
             ProcessData.cached_domain_offset(
               put_in(registrations, [:ch2, :bit_offset], 0),
               sm_group,
               slow_attachment
             )
  end

  test "preop sync-only reconfigure rejects invalid sync-update mailbox steps" do
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
             EtherCAT.Slave.FSM.handle_event(
               {:call, from},
               {:configure, [sync: sync]},
               :preop,
               original
             )

    assert unchanged.sync_config == nil
  end

  test "entering op only arms latch polling" do
    assert {:keep_state_and_data, []} =
             EtherCAT.Slave.FSM.handle_event(
               :enter,
               :safeop,
               :op,
               %EtherCAT.Slave{
                 name: :axis,
                 driver: TestDriver,
                 config: %{},
                 latch_poll_ms: nil
               }
             )
  end

  test "entering safeop arms health polling when configured" do
    assert {:keep_state_and_data, [{{:timeout, :health_poll}, 250, nil}]} =
             EtherCAT.Slave.FSM.handle_event(
               :enter,
               :op,
               :safeop,
               %EtherCAT.Slave{health_poll_ms: 250}
             )
  end

  test "entering preop arms health polling when configured" do
    assert {:keep_state_and_data, [{{:timeout, :health_poll}, 250, nil}]} =
             EtherCAT.Slave.FSM.handle_event(
               :enter,
               :init,
               :preop,
               %EtherCAT.Slave{health_poll_ms: 250}
             )
  end

  test "preop health poll enters down on disconnect" do
    bus =
      start_supervised!(
        {FakeBus, responses: [{:ok, [%{data: <<0, 0>>, wkc: 0, circular: false, irq: 0}]}]}
      )

    data = %EtherCAT.Slave{
      bus: bus,
      station: 0x1001,
      name: :sensor,
      health_poll_ms: 250
    }

    assert {:next_state, :down, ^data} =
             EtherCAT.Slave.FSM.handle_event(
               {:timeout, :health_poll},
               nil,
               :preop,
               data
             )
  end

  test "safeop health poll enters down on disconnect" do
    bus =
      start_supervised!(
        {FakeBus, responses: [{:ok, [%{data: <<0, 0>>, wkc: 0, circular: false, irq: 0}]}]}
      )

    data = %EtherCAT.Slave{
      bus: bus,
      station: 0x1001,
      name: :sensor,
      health_poll_ms: 250
    }

    assert {:next_state, :down, ^data} =
             EtherCAT.Slave.FSM.handle_event(
               {:timeout, :health_poll},
               nil,
               :safeop,
               data
             )
  end

  test "safeop health poll follows a lower AL state" do
    bus =
      start_supervised!(
        {FakeBus, responses: [{:ok, [%{data: <<0x02, 0x00>>, wkc: 1, circular: false, irq: 0}]}]}
      )

    data = %EtherCAT.Slave{
      bus: bus,
      station: 0x1001,
      name: :sensor,
      health_poll_ms: 250
    }

    assert {:next_state, :preop, ^data} =
             EtherCAT.Slave.FSM.handle_event(
               {:timeout, :health_poll},
               nil,
               :safeop,
               data
             )
  end

  test "down reconnects immediately into local preop rebuild once the fixed station responds" do
    bus =
      start_supervised!(
        {FakeBus,
         [
           responses: [{:ok, [%{data: <<0>>, wkc: 1, circular: false, irq: 0}]}],
           default_reply: {:ok, [%{wkc: 0}]}
         ]}
      )

    data = %EtherCAT.Slave{
      bus: bus,
      position: 1,
      station: 0x1001,
      name: :sensor,
      health_poll_ms: 250
    }

    assert {:next_state, :preop, %EtherCAT.Slave{} = rebuilt, [:rebuilt]} =
             EtherCAT.Slave.Runtime.Health.probe_reconnect(
               data,
               initialize_to_preop: fn slave -> {:ok, :preop, slave, [:rebuilt]} end
             )

    assert rebuilt.station == 0x1001
    assert rebuilt.position == 1
  end

  test "sdo upload and download reject calls before mailbox setup" do
    from = {self(), make_ref()}

    assert {:keep_state_and_data, [{:reply, ^from, {:error, :mailbox_not_ready}}]} =
             EtherCAT.Slave.FSM.handle_event(
               {:call, from},
               {:download_sdo, 0x2000, 0x01, <<1, 2, 3>>},
               :init,
               %EtherCAT.Slave{}
             )

    assert {:keep_state_and_data, [{:reply, ^from, {:error, :mailbox_not_ready}}]} =
             EtherCAT.Slave.FSM.handle_event(
               {:call, from},
               {:upload_sdo, 0x2000, 0x01},
               :init,
               %EtherCAT.Slave{}
             )
  end
end
