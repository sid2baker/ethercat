defmodule EtherCAT.Simulator.Udp.Fault do
  @moduledoc """
  Builder API for `EtherCAT.Simulator.Udp.inject_fault/1`.

  Typical usage:

      alias EtherCAT.Simulator.Udp
      alias EtherCAT.Simulator.Udp.Fault

      Udp.inject_fault(Fault.truncate())
      Udp.inject_fault(Fault.wrong_idx() |> Fault.next(3))
      Udp.inject_fault(Fault.script([Fault.unsupported_type(), Fault.replay_previous()]))
      Fault.describe(Fault.truncate() |> Fault.next(2))
  """

  @modes [:truncate, :unsupported_type, :wrong_idx, :replay_previous]

  @type mode :: :truncate | :unsupported_type | :wrong_idx | :replay_previous
  @type t :: %__MODULE__{
          kind: :counted | :script,
          mode: mode() | nil,
          count: non_neg_integer(),
          script: [mode()] | nil
        }

  defstruct kind: :counted, mode: nil, count: 1, script: nil

  @spec truncate() :: t()
  def truncate, do: %__MODULE__{mode: :truncate}

  @spec unsupported_type() :: t()
  def unsupported_type, do: %__MODULE__{mode: :unsupported_type}

  @spec wrong_idx() :: t()
  def wrong_idx, do: %__MODULE__{mode: :wrong_idx}

  @spec replay_previous() :: t()
  def replay_previous, do: %__MODULE__{mode: :replay_previous}

  @spec next(t(), pos_integer()) :: t()
  def next(%__MODULE__{kind: :counted} = fault, count \\ 1)
      when is_integer(count) and count > 0 do
    %{fault | count: count}
  end

  @spec script([t(), ...]) :: t()
  def script(steps) when is_list(steps) and steps != [] do
    %__MODULE__{
      kind: :script,
      script: Enum.map(steps, &mode!/1),
      mode: nil,
      count: 0
    }
  end

  @spec normalize(t() | EtherCAT.Simulator.Udp.fault()) ::
          {:ok, EtherCAT.Simulator.Udp.fault()} | :error
  def normalize(%__MODULE__{kind: :counted, mode: mode, count: 1}) when mode in @modes do
    {:ok, {:corrupt_next_response, mode}}
  end

  def normalize(%__MODULE__{kind: :counted, mode: mode, count: count})
      when mode in @modes and is_integer(count) and count > 1 do
    {:ok, {:corrupt_next_responses, count, mode}}
  end

  def normalize(%__MODULE__{kind: :script, script: script})
      when is_list(script) and script != [] do
    {:ok, {:corrupt_response_script, script}}
  end

  def normalize(%__MODULE__{}), do: :error
  def normalize(raw_fault), do: {:ok, raw_fault}

  @spec describe(t() | EtherCAT.Simulator.Udp.fault()) :: String.t()
  def describe(%__MODULE__{} = fault) do
    case normalize(fault) do
      {:ok, raw_fault} -> describe(raw_fault)
      :error -> inspect(fault)
    end
  end

  def describe(mode) when mode in @modes, do: describe_mode(mode)

  def describe({:corrupt_next_response, mode}) when mode in @modes do
    "next UDP reply #{describe_mode(mode)}"
  end

  def describe({:corrupt_next_responses, count, mode}) when mode in @modes do
    "next #{count} UDP replies #{describe_mode(mode)}"
  end

  def describe({:corrupt_response_script, modes}) when is_list(modes) do
    "UDP reply script [#{Enum.map_join(modes, ", ", &describe_mode/1)}]"
  end

  def describe(other), do: inspect(other)

  defp mode!(%__MODULE__{kind: :counted, mode: mode}) when mode in @modes, do: mode

  defp mode!(_fault),
    do: raise(ArgumentError, "UDP fault scripts only accept unscheduled UDP modes")

  defp describe_mode(:truncate), do: "truncate"
  defp describe_mode(:unsupported_type), do: "unsupported type"
  defp describe_mode(:wrong_idx), do: "wrong index"
  defp describe_mode(:replay_previous), do: "replay previous response"
end
