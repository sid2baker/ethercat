## Simulator Integration Loop

Use this folder as a bounded self-improvement loop for the simulator and the
master runtime.

The rule is simple:

1. Write a short scenario spec first as `NN_case_name.md`.
2. Add the smallest failing integration test as `NN_case_name_test.exs`.
3. Classify the failure:
   - simulator cannot express the fault
   - simulator expresses it, but assertions/observability are weak
   - master/domain/slave behavior is wrong
4. Fix the smallest layer that unblocks the scenario:
   - missing fault model -> extend simulator API
   - missing visibility -> extend snapshots, telemetry, or test helpers
   - product bug -> fix implementation
5. Re-run the targeted test, then the simulator suite.
6. Only then move to a harder scenario.

The point is to keep every improvement tied to a concrete scenario instead of
letting the loop invent arbitrary refactors.

## Naming

- Scenario doc: `NN_case_name.md`
- Matching test: `NN_case_name_test.exs`
- Shared harness code lives in `test/integration/support/`

## Current Scenario Set

- `00`: baseline healthy ring boot and PDO exchange
- `01`: transient full-response timeout
- `02`: cyclic WKC mismatch
- `03`: slave disconnect with health polling and reconnect
- `04`: raw frame corruption or stale/duplicate frame
- `05`: slave retreat to `SAFEOP` with health polling
- `06`: mailbox abort during startup or recovery
- `07`: combined fault script, e.g. timeout -> reconnect -> WKC skew
- `08`: delayed slave-local mutation after exchange-fault recovery
- `09`: milestone-aware slave-local fault after healthy polls
- `10`: segmented mailbox abort during upload/download
- `11`: reusable fault script with embedded milestone wait
- `12`: startup mailbox abort during driver PREOP mailbox configuration
- `13`: targeted logical-WKC skew without inventing a slave-local fault
- `14`: command-targeted WKC skew outside logical PDO traffic
- `15`: mailbox milestone-timed segmented abort after successful segment progress
- `16`: mailbox protocol-shape faults during public SDO upload
- `17`: malformed mailbox response headers during public SDO upload
- `18`: malformed CoE payloads during public SDO upload
- `19`: malformed segmented CoE upload responses
- `20`: malformed segmented CoE download acknowledgements
- `21`: startup segmented-download acknowledgement faults during PREOP configuration
- `22`: startup mailbox response timeouts during PREOP configuration
- `23`: public mailbox response timeouts during segmented SDO upload/download
- `24`: reconnect-time mailbox abort during PREOP rebuild without full-session restart
- `25`: reconnect-time mailbox response timeouts during PREOP rebuild without full-session restart
- `26`: reconnect-time malformed segmented-download acknowledgements during PREOP rebuild without full-session restart
- `27`: reconnect-time malformed final segmented-download acknowledgements during PREOP rebuild, including committed-write semantics

These are the current regression scenarios, not just backlog items. Each one
should keep its `.md` note and matching `_test.exs` file aligned.

## Current Fault Shapes

For datagram/runtime faults, prefer the builder surface on
`EtherCAT.Simulator.Fault`:

- `EtherCAT.Simulator.inject_fault(Fault.next(fault))`
- `EtherCAT.Simulator.inject_fault(Fault.next(fault, count))`
- `EtherCAT.Simulator.inject_fault(Fault.script([step, ...]))`
- `EtherCAT.Simulator.inject_fault(Fault.after_ms(fault, delay_ms))`
- `EtherCAT.Simulator.inject_fault(Fault.after_milestone(fault, milestone))`

Current exchange-scoped faults:

- `:drop_responses`
- `{:wkc_offset, delta}`
- `{:command_wkc_offset, command_name, delta}`
- `{:logical_wkc_offset, slave_name, delta}`
- `{:disconnect, slave_name}`

Current milestones:

- `{:healthy_exchanges, count}`
- `{:healthy_polls, slave_name, count}`
- `{:mailbox_step, slave_name, step, count}`

Current in-script wait steps:

- `Fault.wait_for(Fault.healthy_exchanges(count))`
- `Fault.wait_for(Fault.healthy_polls(slave_name, count))`
- `Fault.wait_for(Fault.mailbox_step(slave_name, step, count))`

For raw transport corruption, use the UDP-edge API instead:

- `EtherCAT.Simulator.Udp.inject_fault(UdpFault.truncate())`
- `EtherCAT.Simulator.Udp.inject_fault(UdpFault.wrong_idx() |> UdpFault.next(count))`
- `EtherCAT.Simulator.Udp.inject_fault(UdpFault.script([UdpFault.unsupported_type(), ...]))`

Current UDP corruption modes:

- `:truncate`
- `:unsupported_type`
- `:wrong_idx`
- `:replay_previous`

For tooling and scenario output, prefer `Fault.describe/1` and
`UdpFault.describe/1` instead of rebuilding labels from tuple shapes.

`EtherCAT.Simulator.info/0` and `EtherCAT.Simulator.Udp.info/0` expose
queued and delayed fault state through `next_fault`, `pending_faults`,
`scheduled_faults`, and active `command_wkc_offsets` / `logical_wkc_offsets`,
including milestone `waiting_on` / `remaining`, so new scenarios should assert queue drain explicitly
instead of relying on sleeps alone.

Current mailbox protocol fault kinds:

- `:drop_response`
- `:counter_mismatch`
- `:toggle_mismatch`
- `{:mailbox_type, type}`
- `{:coe_service, service}`
- `:invalid_coe_payload`
- `{:sdo_command, command}`
- `:invalid_segment_padding`
- `{:segment_command, command}`

## Next Directions

The next useful scenarios are the narrower ones beyond the new reconnect
final-ack coverage:

- mixed reconnect PREOP rebuild scripts where the first retry hits a mailbox fault and a later retry self-heals without manual fault clearing

## Current Rule Of Thumb

- If the scenario is awkward because fault timing is too coarse, prefer a more
  scriptable simulator API over brittle sleeps in tests.
- If the scenario is easy to trigger but hard to assert, improve snapshots or
  test helpers before changing runtime behavior.
- If the scenario exposes a mismatch with expected master behavior, fix the bug
  before adding more scenarios on top.
- If the idea is really an address-space or protocol-limit boundary, cover it
  in focused master/startup unit tests instead of inventing giant simulator
  rings the transport cannot honestly address.
- Keep the fault boundary honest:
  datagram/runtime faults belong on `EtherCAT.Simulator`, while raw reply
  corruption belongs on `EtherCAT.Simulator.Udp`.
