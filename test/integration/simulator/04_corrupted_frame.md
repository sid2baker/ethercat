## Scenario

Corrupted, truncated, stale, or duplicate frame at the transport boundary.

## Real-World Analog

- bad PHY or NIC behavior
- UDP wrapper corruption in the simulator transport path
- stale response replay
- wrong datagram index in a late frame

## Expected Master Behavior

- malformed frames should be dropped by the bus layer
- decode failures or stale mismatched replies should not be treated as valid
  traffic
- the in-flight caller should eventually see a timeout or dropped-frame outcome
- cyclic operation should degrade into `:recovering` if the bad frames affect
  the active domain long enough

## Actual Behavior Today

Observed with the UDP transport fault API:

- `EtherCAT.Simulator.Udp.inject_fault({:corrupt_next_response, :truncate})`
  produces a bus `frame_dropped` telemetry event with `reason: :decode_error`
- `EtherCAT.Simulator.Udp.inject_fault({:corrupt_next_response, :wrong_idx})`
  produces a bus `frame_dropped` telemetry event with `reason: :idx_mismatch`
- in both cases the domain then sees the exchange as a `:timeout`, the master
  degrades briefly, and the next healthy reply returns the system to
  `:operational`

So the transport-edge path is now testable for malformed headers/payloads,
wrong-index replies, stale previous-response replay, and repeated corruption
windows.

## Test Shape

1. boot the ring
2. inject a raw-frame fault, counted window, or scripted sequence at the UDP
   boundary
3. assert bus/domain behavior for truncate, wrong type, wrong idx, and stale
   replay modes
4. clear the fault and assert recovery

## Simulator API Notes

Current API now covers one-shot, counted, and scripted UDP-edge corruption.

The chosen API lives at the UDP/raw-frame transport edge, not inside datagram
execution:

- `EtherCAT.Simulator.Udp.inject_fault({:corrupt_next_response, :truncate})`
- `EtherCAT.Simulator.Udp.inject_fault({:corrupt_next_response, :unsupported_type})`
- `EtherCAT.Simulator.Udp.inject_fault({:corrupt_next_response, :wrong_idx})`
- `EtherCAT.Simulator.Udp.inject_fault({:corrupt_next_response, :replay_previous})`
- `EtherCAT.Simulator.Udp.inject_fault({:corrupt_next_responses, 2, :truncate})`
- `EtherCAT.Simulator.Udp.inject_fault({:corrupt_response_script, [:unsupported_type, :replay_previous]})`
