defmodule EtherCAT.Simulator.Slave.Behaviour do
  @moduledoc false

  alias EtherCAT.Simulator.Slave.Device
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

  @spec transition(module(), atom(), atom(), Device.t(), term()) ::
          {:ok, term()} | {:error, non_neg_integer(), term()}
  def transition(module, from, to, device, state) do
    if function_exported?(module, :transition, 4) do
      module.transition(from, to, device, state)
    else
      {:ok, state}
    end
  end

  @spec tick(module(), Device.t(), term()) :: {:ok, term()}
  def tick(module, device, state) do
    if function_exported?(module, :tick, 2) do
      module.tick(device, state)
    else
      {:ok, state}
    end
  end

  @spec refresh_inputs(module(), Device.t(), term()) :: {:ok, map(), term()}
  def refresh_inputs(module, device, state) do
    if function_exported?(module, :refresh_inputs, 2) do
      module.refresh_inputs(device, state)
    else
      {:ok, %{}, state}
    end
  end

  @spec handle_output_change(module(), atom(), term(), Device.t(), term()) ::
          {:ok, term()} | {:error, term(), term()}
  def handle_output_change(module, signal_name, value, device, state) do
    if function_exported?(module, :handle_output_change, 4) do
      module.handle_output_change(signal_name, value, device, state)
    else
      {:ok, state}
    end
  end

  @spec read_object(
          module(),
          non_neg_integer(),
          non_neg_integer(),
          Object.t(),
          Device.t(),
          term()
        ) ::
          {:ok, Object.t(), term()} | {:error, non_neg_integer(), term()}
  def read_object(module, index, subindex, entry, device, state) do
    if function_exported?(module, :read_object, 5) do
      module.read_object(index, subindex, entry, device, state)
    else
      {:ok, entry, state}
    end
  end

  @spec write_object(
          module(),
          non_neg_integer(),
          non_neg_integer(),
          Object.t(),
          binary(),
          Device.t(),
          term()
        ) :: {:ok, Object.t(), term()} | {:error, non_neg_integer(), term()}
  def write_object(module, index, subindex, entry, binary, device, state) do
    if function_exported?(module, :write_object, 6) do
      module.write_object(index, subindex, entry, binary, device, state)
    else
      {:ok, entry, state}
    end
  end
end
