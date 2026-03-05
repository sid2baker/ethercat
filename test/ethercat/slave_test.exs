defmodule EtherCAT.SlaveTest do
  use ExUnit.Case, async: true

  defmodule TestDriver do
    @behaviour EtherCAT.Slave.Driver

    @impl true
    def process_data_profile(_config), do: %{}

    @impl true
    def encode_outputs(_pdo, _config, _value), do: <<>>

    @impl true
    def decode_inputs(_pdo, _config, <<_::7, bit::1>>), do: bit

    @impl true
    def decode_inputs(_pdo, _config, _raw), do: 0
  end

  test "only dispatches subscribed PDO updates when that PDO changes inside a shared SM" do
    data = %EtherCAT.Slave{
      name: :sensor,
      driver: TestDriver,
      config: %{},
      pdo_registrations: %{
        ch1: %{sm_key: {:sm, 0}, bit_offset: 0, bit_size: 1},
        ch2: %{sm_key: {:sm, 0}, bit_offset: 1, bit_size: 1}
      },
      pdo_subscriptions: %{ch1: [self()], ch2: [self()]}
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
end
