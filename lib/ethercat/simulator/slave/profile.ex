defmodule EtherCAT.Simulator.Slave.Profile do
  @moduledoc false

  alias EtherCAT.Simulator.Slave.Profile

  @type t :: atom()

  @spec module(t()) :: module()
  def module(:coupler), do: Profile.Coupler
  def module(:digital_io), do: Profile.DigitalIO
  def module(:mailbox_device), do: Profile.MailboxDevice
  def module(:lan9252_demo), do: Profile.MailboxDevice
  def module(:analog_io), do: Profile.AnalogIO
  def module(:temperature_input), do: Profile.TemperatureInput
  def module(:servo_drive), do: Profile.ServoDrive

  @spec spec(t(), keyword()) :: map()
  def spec(profile, opts) do
    module(profile).spec(opts)
  end

  @spec signal_specs(t()) :: %{optional(atom()) => map()}
  def signal_specs(profile) do
    module(profile).signal_specs()
  end
end
