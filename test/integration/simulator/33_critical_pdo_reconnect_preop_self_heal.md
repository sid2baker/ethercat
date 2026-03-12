## Scenario

A PDO-participating slave disconnects, reconnects, and then fails its first
reconnect-time PREOP mailbox configuration step before later healing on retry.

## Real-World Analog

A field device that contributes process data loses link briefly, comes back,
but its reconnect configuration sequence times out once before succeeding on a
later retry.

## Expected Master Behavior

- The disconnect should move the master into `:recovering`.
- The reconnect-time PREOP configuration failure should remain visible as a
  slave-local `{:preop, {:preop_configuration_failed, ...}}` fault.
- Once the slave's retry path succeeds, the master should clear the critical
  runtime fault too and return to `:operational`.

## Actual Behavior Today

Observed with:

1. `Fault.script/1` driving a counted disconnect for the PDO-participating slave
2. a reconnect-time segmented mailbox timeout on the first PREOP rebuild

The runtime now behaves as intended:

- the disconnect moves the master into `:recovering`
- the reconnect-time PREOP failure replaces the stale disconnect reason with the
  retained `{:preop, {:preop_configuration_failed, ...}}` slave fault
- the later PREOP retry clears both the slave fault and the master recovery state

## Test Shape

1. boot a coupler plus one PDO-participating mailbox slave in `:op`
2. inject a counted disconnect for that slave
3. fail the first reconnect-time segmented mailbox configuration step
4. assert the slave retains the PREOP configuration failure while recovery is active
5. assert the later retry clears both the slave fault and master recovery state
