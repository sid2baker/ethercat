## Scenario

Driver PREOP mailbox configuration hits a deterministic SDO abort during
startup.

## Real-World Analog

A mailbox-capable slave is present and reachable, but rejects one of the
driver's startup CoE writes while the master is trying to leave PREOP.

## Expected Master Behavior

- The master should not report a transport or topology fault.
- Startup should stop in `:activation_blocked` with a precise
  `:preop_configuration_failed` reason for the affected slave.
- The slave should remain queryable in PREOP with its configuration error
  visible.
- Clearing the injected abort and restarting the session should allow the same
  driver startup to complete.

## Actual Behavior Today

Observed with:

- a mailbox-capable driver whose `mailbox_config/1` performs
  `{:sdo_download, 0x2000, 0x02, <<1>>}`
- `Simulator.inject_fault({:mailbox_abort, :mailbox, 0x2000, 0x02, 0x0601_0002})`

- the master enters `:activation_blocked`
- `EtherCAT.await_running/1` reports `{:activation_failed, %{mailbox: {:safeop, {:preop_configuration_failed, {:mailbox_config_failed, ...}}}}}`
- `EtherCAT.slave_info(:mailbox)` reports the exact mailbox configuration error
- after clearing the injected abort and restarting the master, startup reaches
  `:operational`

## Test Shape

1. boot a coupler plus configured mailbox-capable slave in the simulator
2. inject a mailbox abort before starting the master
3. start the master with the mailbox slave targeting `:op`
4. assert startup stops in `:activation_blocked` with the exact failure tuple
5. assert the mailbox slave stays in PREOP and exposes the configuration error
6. clear faults, restart the master, and assert the same startup succeeds

## Simulator API Notes

Current API is enough for startup-time mailbox abort coverage through direct
`{:mailbox_abort, ...}` injection before master startup.

Still worth adding later:

- mailbox response timeouts during PREOP configuration, not just deterministic aborts
