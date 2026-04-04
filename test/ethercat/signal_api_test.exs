defmodule EtherCAT.SlaveApiTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Domain.Image
  alias EtherCAT.Slave.Runtime.DeviceState

  defmodule DeviceStateDriver do
    @behaviour EtherCAT.Driver
    alias EtherCAT.Endpoint

    @impl true
    def signal_model(_config, _sii_pdo_configs), do: [coil: 0x1600, ch1: 0x1A00]

    @impl true
    def encode_signal(_signal, _config, value) when value in [true, 1], do: <<1>>
    def encode_signal(_signal, _config, _value), do: <<0>>

    @impl true
    def decode_signal(_signal, _config, <<_::7, bit::1>>), do: bit
    def decode_signal(_signal, _config, _raw), do: 0

    @impl true
    def describe(_config) do
      %{
        device_type: :digital_io,
        endpoints: [
          %Endpoint{signal: :coil, direction: :output, type: :boolean},
          %Endpoint{signal: :ch1, direction: :input, type: :boolean}
        ],
        commands: []
      }
    end

    @impl true
    def init(_config), do: {:ok, %{in_flight: nil}}

    @impl true
    def project_state(raw_inputs, _prev_state, driver_state, _config) do
      next_state = %{ch1: Map.get(raw_inputs, :ch1, 0) == 1}

      case driver_state.in_flight do
        %{ref: ref, expected: expected} when expected == next_state.ch1 ->
          {:ok, next_state, %{driver_state | in_flight: nil}, [{:command_completed, ref}], []}

        _other ->
          {:ok, next_state, driver_state, [], []}
      end
    end

    @impl true
    def command(
          %{ref: ref, name: :set_output, args: %{value: value}},
          _state,
          driver_state,
          _config
        )
        when is_boolean(value) do
      {:ok, [{:write, :coil, value}], %{driver_state | in_flight: %{ref: ref, expected: value}},
       []}
    end

    def command(%{name: :set_output}, _state, _driver_state, _config),
      do: {:error, :invalid_output_value}

    def command(command, _state, _driver_state, _config),
      do: EtherCAT.Driver.unsupported_command(command)
  end

  setup do
    case Process.whereis(EtherCAT.SubscriptionRegistry) do
      nil -> start_supervised!({Registry, keys: :duplicate, name: EtherCAT.SubscriptionRegistry})
      _pid -> :ok
    end

    domain_id = :"signal_api_domain_#{System.unique_integer([:positive, :monotonic])}"
    input_key = {:test_slave, {:sm, 3}}
    output_key = {:test_slave, {:sm, 2}}

    :ets.new(domain_id, [:set, :public, :named_table])
    :ets.insert(domain_id, {input_key, <<0>>, {:input, nil}})
    :ets.insert(domain_id, {output_key, <<0>>, {:output, nil}})
    Image.put_domain_status(domain_id, nil, 1_000_000)

    data =
      %EtherCAT.Slave{
        name: :test_slave,
        driver: DeviceStateDriver,
        config: %{},
        signal_registrations: %{
          ch1: %{
            domain_id: domain_id,
            sm_key: {:sm, 3},
            bit_offset: 0,
            bit_size: 1,
            direction: :input
          },
          coil: %{
            domain_id: domain_id,
            sm_key: {:sm, 2},
            bit_offset: 0,
            bit_size: 1,
            sm_size: 1,
            direction: :output
          }
        },
        output_domain_ids_by_sm: %{{:sm, 2} => [domain_id]},
        output_sm_images: %{{:sm, 2} => <<0>>},
        event_subscriptions: MapSet.new([self()]),
        subscriptions: %{},
        subscriber_refs: %{}
      }
      |> DeviceState.initialize()

    on_exit(fn ->
      if :ets.whereis(domain_id) != :undefined do
        :ets.delete(domain_id)
      end
    end)

    {:ok, domain_id: domain_id, input_key: input_key, output_key: output_key, data: data}
  end

  test "projected slave state refresh emits public slave events", %{
    domain_id: domain_id,
    input_key: input_key,
    data: data
  } do
    first_cycle = 1
    refreshed_at_us = System.monotonic_time(:microsecond)
    :ets.insert(domain_id, {input_key, <<0>>, {:input, refreshed_at_us}})
    Image.put_domain_status(domain_id, refreshed_at_us, 1_000_000)

    data = DeviceState.refresh(data, first_cycle, refreshed_at_us)

    assert data.device_state == %{ch1: false}

    assert %EtherCAT.SlaveSnapshot{
             device_type: :digital_io,
             cycle: ^first_cycle,
             updated_at_us: ^refreshed_at_us,
             faults: [],
             endpoints: [
               %EtherCAT.Endpoint{signal: :coil, direction: :output, type: :boolean},
               %EtherCAT.Endpoint{signal: :ch1, direction: :input, type: :boolean}
             ],
             state: %{ch1: false}
           } = DeviceState.snapshot(:op, data)

    refute_receive _

    next_cycle = 2
    changed_at_us = System.monotonic_time(:microsecond)
    :ets.insert(domain_id, {input_key, <<1>>, {:input, changed_at_us}})
    Image.put_domain_status(domain_id, changed_at_us, 1_000_000)

    data = DeviceState.refresh(data, next_cycle, changed_at_us)

    assert data.device_state == %{ch1: true}

    assert_receive %EtherCAT.Event{
      kind: :signal_changed,
      signal: {:test_slave, :ch1},
      slave: :test_slave,
      value: true,
      cycle: ^next_cycle,
      updated_at_us: ^changed_at_us
    }
  end

  test "slave commands stage outputs and complete from later projected state", %{
    domain_id: domain_id,
    input_key: input_key,
    output_key: output_key,
    data: data
  } do
    first_cycle = 1
    refreshed_at_us = System.monotonic_time(:microsecond)
    :ets.insert(domain_id, {input_key, <<0>>, {:input, refreshed_at_us}})
    Image.put_domain_status(domain_id, refreshed_at_us, 1_000_000)
    data = DeviceState.refresh(data, first_cycle, refreshed_at_us)

    assert {:ok, ref, data} =
             DeviceState.command(data, :set_output, %{signal: :coil, value: true})

    assert_receive %EtherCAT.Event{
      kind: :signal_changed,
      signal: {:test_slave, :coil},
      slave: :test_slave,
      value: true,
      cycle: ^first_cycle,
      updated_at_us: command_ts
    }

    assert is_integer(command_ts)

    assert_receive %EtherCAT.Event{
      kind: :event,
      slave: :test_slave,
      data: {:command_accepted, ^ref},
      cycle: ^first_cycle,
      updated_at_us: ^command_ts
    }

    assert {:ok, <<1>>} = EtherCAT.Domain.read(domain_id, output_key)

    assert %EtherCAT.SlaveSnapshot{state: %{ch1: false, coil: true}} =
             DeviceState.snapshot(:op, data)

    next_cycle = 2
    changed_at_us = System.monotonic_time(:microsecond)
    :ets.insert(domain_id, {input_key, <<1>>, {:input, changed_at_us}})
    Image.put_domain_status(domain_id, changed_at_us, 1_000_000)

    data = DeviceState.refresh(data, next_cycle, changed_at_us)

    assert_receive %EtherCAT.Event{
      kind: :signal_changed,
      signal: {:test_slave, :ch1},
      slave: :test_slave,
      value: true,
      cycle: ^next_cycle,
      updated_at_us: ^changed_at_us
    }

    assert_receive %EtherCAT.Event{
      kind: :event,
      slave: :test_slave,
      data: {:command_completed, ^ref},
      cycle: ^next_cycle,
      updated_at_us: ^changed_at_us
    }

    assert %EtherCAT.SlaveSnapshot{state: %{ch1: true, coil: true}} =
             DeviceState.snapshot(:op, data)
  end

  test "set_output requires a canonical signal name", %{data: data} do
    assert {:error, :invalid_output_signal, ^data} =
             DeviceState.command(data, :set_output, %{value: true})
  end

  test "subscribe(:all) follows slave events without enumerating current slaves", %{
    domain_id: domain_id,
    input_key: input_key,
    data: data
  } do
    data = %{data | event_subscriptions: MapSet.new(), subscriber_refs: %{}}
    assert :ok = EtherCAT.subscribe(:all, self())

    initial_at_us = System.monotonic_time(:microsecond)
    :ets.insert(domain_id, {input_key, <<0>>, {:input, initial_at_us}})
    Image.put_domain_status(domain_id, initial_at_us, 1_000_000)

    data = DeviceState.refresh(data, 6, initial_at_us)
    refute_receive _

    changed_at_us = System.monotonic_time(:microsecond)
    :ets.insert(domain_id, {input_key, <<1>>, {:input, changed_at_us}})
    Image.put_domain_status(domain_id, changed_at_us, 1_000_000)

    _data = DeviceState.refresh(data, 7, changed_at_us)

    assert_receive %EtherCAT.Event{
      kind: :signal_changed,
      signal: {:test_slave, :ch1},
      slave: :test_slave,
      value: true,
      cycle: 7,
      updated_at_us: ^changed_at_us
    }
  end

  test "subscribe(slave) filters public slave events to one slave", %{
    domain_id: domain_id,
    input_key: input_key,
    data: data
  } do
    data = %{data | event_subscriptions: MapSet.new(), subscriber_refs: %{}}
    assert :ok = EtherCAT.subscribe(:test_slave, self())

    initial_at_us = System.monotonic_time(:microsecond)
    :ets.insert(domain_id, {input_key, <<0>>, {:input, initial_at_us}})
    Image.put_domain_status(domain_id, initial_at_us, 1_000_000)
    data = DeviceState.refresh(data, 8, initial_at_us)
    refute_receive _

    changed_at_us = System.monotonic_time(:microsecond)
    :ets.insert(domain_id, {input_key, <<1>>, {:input, changed_at_us}})
    Image.put_domain_status(domain_id, changed_at_us, 1_000_000)

    _data = DeviceState.refresh(data, 9, changed_at_us)

    assert_receive %EtherCAT.Event{
      kind: :signal_changed,
      signal: {:test_slave, :ch1},
      slave: :test_slave,
      value: true,
      cycle: 9,
      updated_at_us: ^changed_at_us
    }
  end
end
