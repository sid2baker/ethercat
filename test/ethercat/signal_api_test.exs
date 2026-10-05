defmodule EtherCAT.SampleApiTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Domain.Image
  alias EtherCAT.Domain.Status, as: DomainStatus
  alias EtherCAT.Notification
  alias EtherCAT.Sample
  alias EtherCAT.Slave.Status, as: SlaveStatus
  alias EtherCAT.Slave.Runtime.Notifications
  alias EtherCAT.Slave.Runtime.Outputs
  alias EtherCAT.Slave.Runtime.Samples

  defmodule ProtocolDriver do
    @behaviour EtherCAT.Driver

    alias EtherCAT.Endpoint

    @impl true
    def signal_model(_config, _sii_pdo_configs),
      do: [
        coil: %EtherCAT.Driver.Signal{pdo_index: 0x1600},
        ch1: %EtherCAT.Driver.Signal{pdo_index: 0x1A00},
        ch2: %EtherCAT.Driver.Signal{pdo_index: 0x1A01}
      ]

    @impl true
    def encode_signal(_signal, _config, value) when value in [true, 1], do: {:ok, <<1>>}
    def encode_signal(_signal, _config, value) when value in [false, 0], do: {:ok, <<0>>}
    def encode_signal(_signal, _config, _value), do: {:error, :invalid_value}

    @impl true
    def decode_signal(_signal, _config, <<_::7, bit::1>>), do: {:ok, bit == 1}
    def decode_signal(_signal, _config, _raw), do: {:error, :invalid_data}

    @impl true
    def describe(_config) do
      %{
        device_type: :digital_io,
        endpoints: [
          %Endpoint{signal: :coil, direction: :output, type: :boolean},
          %Endpoint{signal: :ch1, direction: :input, type: :boolean},
          %Endpoint{signal: :ch2, direction: :input, type: :boolean}
        ]
      }
    end
  end

  defmodule FailingDriver do
    @behaviour EtherCAT.Driver
    @impl true
    def signal_model(_config, _pdos), do: []
    @impl true
    def encode_signal(_signal, %{encoded: encoded}, _value), do: {:ok, encoded}
    @impl true
    def decode_signal(_signal, _config, _raw), do: {:error, :bad_sensor_data}
  end

  setup do
    domain_id = :"sample_api_domain_#{System.unique_integer([:positive, :monotonic])}"
    input_key = {:test_slave, {:sm, 3}}
    output_key = {:test_slave, {:sm, 2}}

    :ets.new(domain_id, [:set, :public, :named_table])
    :ets.insert(domain_id, {output_key, <<0>>, {:output, nil}})
    Image.put_domain_status(domain_id, nil, 1_000_000)

    data =
      %EtherCAT.Slave{
        name: :test_slave,
        driver: ProtocolDriver,
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
        samples: %{},
        protocol_subscriptions: %{},
        domain_statuses: %{},
        subscriptions: %{},
        subscriber_refs: %{}
      }
      |> Samples.initialize()

    on_exit(fn ->
      if :ets.whereis(domain_id) != :undefined, do: :ets.delete(domain_id)
    end)

    {:ok, domain_id: domain_id, input_key: input_key, output_key: output_key, data: data}
  end

  test "invalid writes leave the process image unchanged", %{
    data: data,
    domain_id: domain,
    output_key: key
  } do
    assert {:error, {:encode_failed, :coil, :invalid_value}} =
             Outputs.write_signal(data, :coil, :invalid)

    for encoded <- [<<>>, <<1, 0>>, <<2>>] do
      bad = %{data | driver: FailingDriver, config: %{encoded: encoded}}
      assert {:error, {:encode_failed, :coil, _reason}} = Outputs.write_signal(bad, :coil, true)
      assert {:ok, <<0>>} = EtherCAT.Domain.read(domain, key)
    end
  end

  test "direct reads propagate decoding errors", %{data: data, domain_id: domain, input_key: key} do
    now = System.monotonic_time(:microsecond)
    :ets.insert(domain, {key, <<1>>, {:input, now}})
    Image.put_domain_status(domain, now, 1_000_000)

    assert {:error, {:decode_failed, :ch1, :bad_sensor_data}} =
             EtherCAT.Slave.Runtime.Signals.read_input(%{data | driver: FailingDriver}, :ch1)
  end

  test "failed decoding replaces the previous value with an explicit cycle error", %{
    data: data,
    domain_id: domain,
    input_key: key
  } do
    {ref, data} = Notifications.subscribe(data, self())
    data = Samples.refresh(data, domain, 1, %{key => <<1>>}, 1, [:ch1])
    assert data.samples[domain].inputs == %{ch1: true}
    assert_receive {:ethercat, ^ref, %Sample{cycle: 1}}
    data = %{data | driver: FailingDriver, subscriptions: %{ch1: MapSet.new([self()])}}
    data = Samples.refresh(data, domain, 2, %{key => <<1>>}, 2, [])
    assert %Sample{inputs: %{}, errors: %{ch1: :bad_sensor_data}} = data.samples[domain]
    assert_receive {:ethercat, ^ref, %Sample{cycle: 2, errors: %{ch1: :bad_sensor_data}}}
    assert_receive {:ethercat, :signal_error, :test_slave, :ch1, :bad_sensor_data}
    refute_receive {:ethercat, :signal, :test_slave, :ch1, _}
  end

  test "sample refresh publishes a complete coherent domain observation", %{
    domain_id: domain_id,
    input_key: input_key,
    data: data
  } do
    {ref, data} = Notifications.subscribe(data, self())
    observed_at = System.monotonic_time(:microsecond)

    data =
      Samples.refresh(data, domain_id, 7, %{input_key => <<1>>}, observed_at, [:ch1])

    assert_receive {:ethercat, ^ref,
                    %Sample{
                      slave: :test_slave,
                      domain: ^domain_id,
                      cycle: 7,
                      observed_at: ^observed_at,
                      inputs: %{ch1: true}
                    }}

    assert %Sample{inputs: %{ch1: true}} = data.samples[domain_id]
  end

  test "raw signal delivery reuses the decoded coherent sample", %{
    domain_id: domain_id,
    input_key: input_key,
    data: data
  } do
    data = %{data | subscriptions: %{ch1: MapSet.new([self()])}}
    observed_at = System.monotonic_time(:microsecond)

    _data =
      Samples.refresh(data, domain_id, 8, %{input_key => <<1>>}, observed_at, [:ch1])

    assert_receive {:ethercat, :signal, :test_slave, :ch1, true}
  end

  test "protocol subscription reports current status and later runtime notifications", %{
    domain_id: domain_id,
    data: data
  } do
    {ref, data} = Notifications.subscribe(data, self())
    status = SlaveStatus.from_runtime(:safeop, data)

    assert %DomainStatus{lifecycle: :open, cycle_health: :not_ready} =
             status.domains[domain_id]

    assert :ok = Notifications.state_changed(data, :safeop, :op)

    assert_receive {:ethercat, ^ref,
                    %Notification{
                      slave: :test_slave,
                      kind: :slave_state_changed,
                      details: %{previous_state: :safeop, current: %SlaveStatus{state: :op}}
                    }}
  end

  test "domain status changes are retained and published without duplicates", %{
    domain_id: domain_id,
    data: data
  } do
    {ref, data} = Notifications.subscribe(data, self())
    observed_at = System.monotonic_time(:microsecond)

    degraded =
      DomainStatus.protocol_status(domain_id, :cycling, :degraded, :timeout, observed_at)

    data = Notifications.domain_status(data, degraded)

    assert_receive {:ethercat, ^ref,
                    %Notification{
                      slave: :test_slave,
                      kind: :domain_status_changed,
                      observed_at: ^observed_at,
                      details: %{current: ^degraded}
                    }}

    duplicate = %{degraded | observed_at: observed_at + 1}
    _data = Notifications.domain_status(data, duplicate)
    refute_receive {:ethercat, ^ref, %Notification{kind: :domain_status_changed}}
  end

  test "cancellation preserves other registrations and releases the final monitor", %{data: data} do
    {first, data} = Notifications.subscribe(data, self())
    {second, data} = Notifications.subscribe(data, self())
    refute first == second
    monitor = Map.fetch!(data.subscriber_refs, self())
    data = Notifications.unsubscribe(data, first)
    assert Map.fetch!(data.subscriber_refs, self()) == monitor
    assert :ok = Notifications.state_changed(data, :safeop, :op)
    refute_receive {:ethercat, ^first, _}
    assert_receive {:ethercat, ^second, %Notification{}}
    data = Notifications.unsubscribe(data, second)
    assert data.protocol_subscriptions == %{}
    assert data.subscriber_refs == %{}
    assert Notifications.unsubscribe(data, second) == data
  end

  test "protocol cancellation preserves a signal subscriber's monitor", %{data: data} do
    {ref, data} = Notifications.subscribe(data, self())
    data = %{data | subscriptions: %{ch1: MapSet.new([self()])}}
    data = Notifications.unsubscribe(data, ref)
    assert Map.has_key?(data.subscriber_refs, self())
    assert MapSet.member?(data.subscriptions.ch1, self())
  end

  test "protocol output writes stage directly into the domain image", %{
    domain_id: domain_id,
    output_key: output_key,
    data: data
  } do
    assert {:ok, _data} = Outputs.write_signal(data, :coil, true)
    assert {:ok, <<1>>} = EtherCAT.Domain.read(domain_id, output_key)
  end

  test "samples from different domains do not form one consistency boundary", %{data: data} do
    slow_domain = :"sample_api_slow_#{System.unique_integer([:positive, :monotonic])}"
    slow_key = {:test_slave, {:sm, 4}}

    data = %{
      data
      | signal_registrations:
          Map.put(data.signal_registrations, :ch2, %{
            domain_id: slow_domain,
            sm_key: {:sm, 4},
            bit_offset: 0,
            bit_size: 1,
            direction: :input
          })
    }

    data =
      Samples.refresh(
        data,
        slow_domain,
        3,
        %{slow_key => <<1>>},
        System.monotonic_time(:microsecond),
        [:ch2]
      )

    assert %Sample{domain: ^slow_domain, inputs: %{ch2: true}} = data.samples[slow_domain]
    refute Map.has_key?(data.samples[slow_domain].inputs, :ch1)
  end
end
