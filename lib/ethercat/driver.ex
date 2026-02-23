defmodule Ethercat.Driver do
  @moduledoc """
  Declarative helper for authoring EtherCAT device drivers. The current
  scaffolding supports declaring signals and basic metadata so the rest of the
  system has something to work with while the full feature set is built out.
  """

  defmacro __using__(_opts) do
    quote do
      @behaviour Ethercat.Driver.Callbacks
      Module.register_attribute(__MODULE__, :signals, accumulate: true)

      @before_compile Ethercat.Driver

      import Ethercat.Driver, only: [identity: 3, input: 2, input: 3, output: 2, output: 3]

      @impl true
      def configure(_device, _options), do: :ok

      @impl true
      def on_preop(_device, _options), do: :ok

      @impl true
      def on_safeop(_device, _options), do: :ok

      @impl true
      def on_op(_device, _options), do: :ok

      @impl true
      def terminate(_device, _reason), do: :ok

      defoverridable configure: 2, on_preop: 2, on_safeop: 2, on_op: 2, terminate: 2
    end
  end

  defmacro __before_compile__(env) do
    signals = Module.get_attribute(env.module, :signals) |> Enum.reverse()

    quote do
      @impl true
      def signals do
        unquote(Macro.escape(signals))
        |> Enum.map(fn {name, dir, type, default} ->
          %{name: name, direction: dir, type: type, default: default}
        end)
      end

      defoverridable signals: 0
    end
  end

  # -- DSL helpers ---------------------------------------------------------

  defmacro identity(vendor_id, product_code, revision) do
    quote do
      @impl true
      def identity do
        %{
          vendor_id: unquote(vendor_id),
          product_code: unquote(product_code),
          revision: unquote(revision)
        }
      end
    end
  end

  defmacro input(name, type, opts \\ []) do
    default = Keyword.get(opts, :default, default_for_type(type))

    quote do
      @signals {unquote(name), :input, unquote(type), unquote(default)}
    end
  end

  defmacro output(name, type, opts \\ []) do
    default = Keyword.get(opts, :default, default_for_type(type))

    quote do
      @signals {unquote(name), :output, unquote(type), unquote(default)}
    end
  end

  defp default_for_type(:bool), do: false
  defp default_for_type(_), do: 0
end

defmodule Ethercat.Driver.Callbacks do
  @moduledoc false

  @callback identity() :: %{vendor_id: integer(), product_code: integer(), revision: integer()}
  @callback signals() :: list()
  @callback configure(term(), map()) :: :ok | {:error, term()}
  @callback on_preop(term(), map()) :: :ok | {:error, term()}
  @callback on_safeop(term(), map()) :: :ok | {:error, term()}
  @callback on_op(term(), map()) :: :ok | {:error, term()}
  @callback terminate(term(), term()) :: :ok
end
