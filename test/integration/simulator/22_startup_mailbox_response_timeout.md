## Scenario

Driver PREOP mailbox configuration begins a segmented CoE download, then a
later mailbox response never appears.

## Real-World Analog

A mailbox-capable slave accepts part of a large startup write, but a later
mailbox response stalls and SM1 never presents the expected reply during PREOP
configuration.

## Expected Master Behavior

- The master should not report a transport or topology fault.
- Startup should stop in `:activation_blocked` with a precise
  `:preop_configuration_failed` reason for the affected slave.
- The failure should preserve the exact mailbox timeout reason from the mailbox
  helper.
- Clearing the injected fault and restarting the session should allow the same
  startup mailbox configuration to complete.

## Actual Behavior Today

Observed with:

- a mailbox-capable driver whose `mailbox_config/1` performs a segmented
  `{:sdo_download, 0x2003, 0x01, binary}`
- `Simulator.inject_fault(Fault.mailbox_protocol_fault(:mailbox, 0x2003, 0x01, :download_segment, :drop_response) |> Fault.after_milestone(Fault.mailbox_step(:mailbox, :download_segment, 1)))`

- the master enters `:activation_blocked`
- `EtherCAT.await_running/1` reports
  `{:activation_failed, %{mailbox: {:safeop, {:preop_configuration_failed, {:mailbox_config_failed, 0x2003, 0x01, :response_timeout}}}}}`
- `EtherCAT.slave_info(:mailbox)` reports the exact mailbox configuration error
- after clearing the injected fault and restarting the master, startup reaches
  `:operational`

## Test Shape

1. boot a coupler plus segmented-configured mailbox slave in the simulator
2. schedule a mailbox-local dropped response after one successful segmented
   download acknowledgement
3. start the master with the mailbox slave targeting `:op`
4. assert startup stops in `:activation_blocked` with the exact timeout tuple
5. assert the mailbox slave stays in PREOP and exposes the configuration error
6. clear faults, restart the master, and assert the same startup succeeds

## Simulator API Notes

Current API is now enough for mailbox-local response timeouts through:

- `Fault.mailbox_protocol_fault(slave_name, index, subindex, stage, :drop_response)`

Still worth adding later:

- mailbox aborts during PREOP retry paths, not just direct public SDO calls
