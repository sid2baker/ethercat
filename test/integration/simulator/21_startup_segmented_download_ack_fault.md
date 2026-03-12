## Scenario

Driver PREOP mailbox configuration begins a segmented CoE download, then a
later download-segment acknowledgement comes back malformed.

## Real-World Analog

A mailbox-capable slave is reachable during startup and accepts part of a large
configuration write, but one of the later acknowledgements returns malformed
CoE data instead of a valid segment acknowledgement.

## Expected Master Behavior

- The master should not report a transport or topology fault.
- Startup should stop in `:activation_blocked` with a precise
  `:preop_configuration_failed` reason for the affected slave.
- The failure should preserve the exact segmented-download parser error from the
  mailbox helper.
- Clearing the injected fault and restarting the session should allow the same
  startup mailbox configuration to complete.

## Actual Behavior Today

Observed with:

- a mailbox-capable driver whose `mailbox_config/1` performs a segmented
  `{:sdo_download, 0x2003, 0x01, binary}`
- `Simulator.inject_fault(Fault.mailbox_protocol_fault(:mailbox, 0x2003, 0x01, :download_segment, :invalid_coe_payload) |> Fault.after_milestone(Fault.mailbox_step(:mailbox, :download_segment, 1)))`

- the master enters `:activation_blocked`
- `EtherCAT.await_running/1` reports
  `{:activation_failed, %{mailbox: {:safeop, {:preop_configuration_failed, {:mailbox_config_failed, 0x2003, 0x01, :invalid_coe_response}}}}}`
- `EtherCAT.slave_info(:mailbox)` reports the exact mailbox configuration error
- after clearing the injected fault and restarting the master, startup reaches
  `:operational`

## Test Shape

1. boot a coupler plus segmented-configured mailbox slave in the simulator
2. schedule a malformed later download acknowledgement before starting the
   master
3. start the master with the mailbox slave targeting `:op`
4. assert startup stops in `:activation_blocked` with the exact failure tuple
5. assert the mailbox slave stays in PREOP and exposes the configuration error
6. clear faults, restart the master, and assert the same startup succeeds

## Simulator API Notes

Current API is now enough for startup-time segmented-download-ack coverage
through `Fault.after_milestone/2` plus `Fault.mailbox_protocol_fault/5`.

Still worth adding later:

- mailbox aborts during PREOP retry paths, not just direct public SDO calls
