defmodule EtherCAT.Slave.Runtime.Status do
  @moduledoc false

  alias EtherCAT.Slave
  alias EtherCAT.Slave.Runtime.Signals

  @spec info_snapshot(atom(), %Slave{}) :: map()
  def info_snapshot(state, data) do
    attachments = Signals.attachment_summaries(data.signal_registrations)

    %{
      name: data.name,
      station: data.station,
      al_state: state,
      identity: data.identity,
      esc: data.esc_info,
      driver: data.driver,
      coe: match?(%{recv_size: n} when n > 0, data.mailbox_config),
      available_fmmus: data.esc_info && data.esc_info.fmmu_count,
      used_fmmus: length(attachments),
      attachments: attachments,
      signals: signal_summaries(data.signal_registrations),
      configuration_error: data.configuration_error
    }
  end

  defp signal_summaries(nil), do: []

  defp signal_summaries(registrations) do
    registrations
    |> Enum.map(fn {name, reg} ->
      %{
        name: name,
        domain: reg.domain_id,
        direction: reg.direction,
        sm_index: elem(reg.sm_key, 1),
        bit_offset: reg.bit_offset,
        bit_size: reg.bit_size
      }
    end)
    |> Enum.sort_by(&{&1.sm_index, &1.bit_offset})
  end
end
