defmodule EtherCAT.Simulator.Slave.Behaviour do
  @moduledoc false

  alias EtherCAT.Simulator.Slave.Runtime.Device
  alias EtherCAT.Simulator.Slave.Object

  @callback init(map()) :: term()
  @callback transition(atom(), atom(), Device.t(), term()) ::
              {:ok, term()} | {:error, non_neg_integer(), term()}
  @callback tick(Device.t(), term()) :: {:ok, term()}
  @callback refresh_inputs(Device.t(), term()) :: {:ok, %{optional(atom()) => term()}, term()}
  @callback handle_output_change(atom(), term(), Device.t(), term()) ::
              {:ok, term()} | {:error, term(), term()}
  @callback read_object(non_neg_integer(), non_neg_integer(), Object.t(), Device.t(), term()) ::
              {:ok, Object.t(), term()} | {:error, non_neg_integer(), term()}
  @callback write_object(
              non_neg_integer(),
              non_neg_integer(),
              Object.t(),
              binary(),
              Device.t(),
              term()
            ) ::
              {:ok, Object.t(), term()} | {:error, non_neg_integer(), term()}

  defmacro __using__(_opts) do
    quote do
      @behaviour EtherCAT.Simulator.Slave.Behaviour

      def init(_definition), do: %{}

      def transition(_from, _to, _device, state), do: {:ok, state}

      def tick(_device, state), do: {:ok, state}

      def refresh_inputs(_device, state), do: {:ok, %{}, state}

      def handle_output_change(_signal_name, _value, _device, state), do: {:ok, state}

      def read_object(_index, _subindex, entry, _device, state), do: {:ok, entry, state}

      def write_object(_index, _subindex, entry, _binary, _device, state),
        do: {:ok, entry, state}

      defoverridable init: 1,
                     transition: 4,
                     tick: 2,
                     refresh_inputs: 2,
                     handle_output_change: 4,
                     read_object: 5,
                     write_object: 6
    end
  end

  @spec init(module(), map()) :: term()
  def init(module, definition) when is_atom(module) and is_map(definition),
    do: module.init(definition)

  @spec transition(module(), atom(), atom(), Device.t(), term()) ::
          {:ok, term()} | {:error, non_neg_integer(), term()}
  def transition(module, from, to, device, state),
    do: module.transition(from, to, device, state)

  @spec tick(module(), Device.t(), term()) :: {:ok, term()}
  def tick(module, device, state), do: module.tick(device, state)

  @spec refresh_inputs(module(), Device.t(), term()) :: {:ok, map(), term()}
  def refresh_inputs(module, device, state), do: module.refresh_inputs(device, state)

  @spec handle_output_change(module(), atom(), term(), Device.t(), term()) ::
          {:ok, term()} | {:error, term(), term()}
  def handle_output_change(module, signal_name, value, device, state),
    do: module.handle_output_change(signal_name, value, device, state)

  @spec read_object(
          module(),
          non_neg_integer(),
          non_neg_integer(),
          Object.t(),
          Device.t(),
          term()
        ) ::
          {:ok, Object.t(), term()} | {:error, non_neg_integer(), term()}
  def read_object(module, index, subindex, entry, device, state),
    do: module.read_object(index, subindex, entry, device, state)

  @spec write_object(
          module(),
          non_neg_integer(),
          non_neg_integer(),
          Object.t(),
          binary(),
          Device.t(),
          term()
        ) :: {:ok, Object.t(), term()} | {:error, non_neg_integer(), term()}
  def write_object(module, index, subindex, entry, binary, device, state),
    do: module.write_object(index, subindex, entry, binary, device, state)
end
