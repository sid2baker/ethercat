defmodule EtherCAT.IntegrationSupport.LinkToggle do
  @moduledoc false

  @spec set_down!(String.t()) :: :ok
  def set_down!(interface), do: set_state!(interface, :down)

  @spec set_up!(String.t()) :: :ok
  def set_up!(interface), do: set_state!(interface, :up)

  defp set_state!(interface, state) when state in [:down, :up] do
    {command, args} = command_for(interface, state)

    case System.cmd(command, args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        raise ArgumentError,
              "failed to set #{interface} #{state} via #{command}:#{Enum.join(args, " ")} (status=#{status}): #{String.trim(output)}"
    end
  end

  defp command_for(interface, state) do
    state = Atom.to_string(state)

    if running_as_root?() do
      {"ip", ["link", "set", "dev", interface, state]}
    else
      {"sudo", ["-n", "ip", "link", "set", "dev", interface, state]}
    end
  end

  defp running_as_root? do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {"0\n", 0} -> true
      _other -> false
    end
  end
end
