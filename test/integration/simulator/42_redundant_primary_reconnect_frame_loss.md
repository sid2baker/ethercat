## Scenario

Redundant primary port reconnection causes transient frame loss when the
slave opens its forwarding port before the master NIC is ready to receive.

## Real-World Analog

On a Raspberry Pi CM4 with two different Ethernet controllers (native
Broadcom GbE on eth0, add-on NIC on eth1), reconnecting the primary cable
causes 3-5 consecutive timeouts before the ring stabilizes. The slave near
primary detects PHY link-up and opens its forwarding port, diverting
secondary's frames toward primary. If the master's primary NIC is still
negotiating, frames are lost on the wire.

The issue is NIC-specific: swapping eth0 and eth1 roles eliminates it,
confirming different auto-negotiation timing between the two controllers.

Secondary reconnect is clean because the primary port's return path is
unaffected by the secondary-end transition.

## Expected Master Behavior

- Zero domain cycle timeouts during primary reconnect.
- Master stays operational throughout.
- Loopback I/O resumes immediately after reconnect.

## Actual Behavior Today

- 3-5 consecutive `no_arrivals` timeouts during the transition window.
- Master enters `:recovering` briefly, then resumes.
- Functionally recovers, but not seamless.

## Test Shape

Cannot reproduce in the simulator because veth pairs have identical and
near-instant link-up on both ends. This is a hardware-only scenario that
requires two physically different NICs with different auto-negotiation
timing.

1. Boot redundant ring on real hardware with two different NIC types.
2. Disconnect primary cable.
3. Wait for degraded single-port operation.
4. Reconnect primary cable.
5. Assert zero domain invalid events after reconnect.
6. Assert loopback I/O resumes without master recovery.

## Simulator API Notes

- Current simulator API cannot express this fault. The issue is at the
  physical layer (PHY auto-negotiation timing), not the EtherCAT protocol
  layer.
- A simulator extension could model asymmetric link-up delay by holding
  one endpoint's responses for a configurable period after reconnect, but
  this would duplicate what `set_response_delay` already does.
- **No API change needed** for the simulator. The fix belongs in the bus
  transport or link layer.

## Open Questions

1. Should the raw socket transport check carrier status before sending,
   to give an accurate `pri_sent?` signal during link-up transitions?
2. Should the bus retry immediately on timeout when one port recently
   transitioned from send-error to send-success?
3. Is the correct fix at the OS level (`ethtool` auto-negotiation tuning)
   rather than in the application?
