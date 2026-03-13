# Simulator Fault Model

## Overview

Datagram/runtime fault injection has two modes:

- sticky faults that stay active until `EtherCAT.Simulator.clear_faults/0`
- queued and scripted runtime faults injected through
  `EtherCAT.Simulator.inject_fault/1` using `EtherCAT.Simulator.Fault`

Queued fault builders include:

- `Fault.next(fault)`
- `Fault.next(fault, count)`
- `Fault.script([step, ...])`
- `Fault.after_ms(fault, delay_ms)`
- `Fault.after_milestone(fault, milestone)`

Master-observed runtime events like `:recovering` entry or a retained slave
fault stay in the integration helper layer. They are better modeled through
telemetry-triggered test helpers than as simulator-core milestones.

Those helpers should complete the follow-up injection before the matching
telemetry callback returns. Otherwise the scenario starts depending on BEAM
scheduler timing instead of causal event ordering.

## Exchange-Scoped Runtime Faults

The current exchange-scoped fault set is:

- `:drop_responses`
- `{:wkc_offset, delta}`
- `{:command_wkc_offset, command_name, delta}`
- `{:logical_wkc_offset, slave_name, delta}`
- `{:disconnect, slave_name}`

Sequential fault scripts can pause on:

- `Fault.wait_for(Fault.healthy_exchanges(count))`
- `Fault.wait_for(Fault.healthy_polls(slave_name, count))`
- `Fault.wait_for(Fault.mailbox_step(slave_name, step, count))`

## Mailbox Faults

Mailbox-local response faults include:

- `{:mailbox_abort, slave_name, index, subindex, abort_code}`
- `{:mailbox_abort, slave_name, index, subindex, abort_code, stage}`
- `{:mailbox_protocol_fault, slave_name, index, subindex, stage, fault_kind}`

Direct mailbox-local injections stay active until
`EtherCAT.Simulator.clear_faults/0`.

The same mailbox protocol fault injected as a step inside `Fault.script/1` is
consumed on first match. That makes scripted reconnect/retry scenarios able to
fail once and self-heal on a later master retry.

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

## Runtime vs UDP Boundary

Use the runtime-side API when the fault should affect datagram semantics or
slave availability:

```elixir
alias EtherCAT.Simulator.Fault

EtherCAT.Simulator.inject_fault(
  Fault.drop_responses()
  |> Fault.next(10)
)

EtherCAT.Simulator.inject_fault(
  Fault.wkc_offset(-1)
  |> Fault.next(6)
)

EtherCAT.Simulator.inject_fault(
  Fault.command_wkc_offset(:fprd, -1)
  |> Fault.next(30)
)

EtherCAT.Simulator.inject_fault(
  Fault.logical_wkc_offset(:outputs, -1)
  |> Fault.next(6)
)

EtherCAT.Simulator.inject_fault(
  Fault.script([Fault.drop_responses(), Fault.disconnect(:outputs)])
)

EtherCAT.Simulator.inject_fault(
  Fault.retreat_to_safeop(:outputs)
  |> Fault.after_ms(250)
)

EtherCAT.Simulator.inject_fault(
  Fault.retreat_to_safeop(:outputs)
  |> Fault.after_milestone(Fault.healthy_polls(:outputs, 10))
)

EtherCAT.Simulator.inject_fault(
  Fault.mailbox_abort(:mailbox, 0x2003, 0x01, 0x0800_0000, stage: :upload_segment)
  |> Fault.after_milestone(Fault.mailbox_step(:mailbox, :upload_segment, 2))
)

EtherCAT.Simulator.inject_fault(
  Fault.mailbox_protocol_fault(:mailbox, 0x2003, 0x01, :upload_segment, :toggle_mismatch)
)

EtherCAT.Simulator.inject_fault(
  Fault.mailbox_protocol_fault(:mailbox, 0x2001, 0x01, :upload_init, {:coe_service, 0x02})
)

EtherCAT.Simulator.inject_fault(
  Fault.mailbox_protocol_fault(:mailbox, 0x2001, 0x01, :upload_init, :invalid_coe_payload)
)

EtherCAT.Simulator.inject_fault(
  Fault.mailbox_protocol_fault(:mailbox, 0x2003, 0x01, :upload_segment, :invalid_segment_padding)
)

EtherCAT.Simulator.inject_fault(
  Fault.script([
    Fault.drop_responses(),
    Fault.wait_for(Fault.healthy_polls(:outputs, 10)),
    Fault.retreat_to_safeop(:outputs)
  ])
)
```

Use the UDP-side API when the fault should corrupt raw replies at the transport
edge:

```elixir
alias EtherCAT.Simulator.Udp.Fault, as: UdpFault

EtherCAT.Simulator.Udp.inject_fault(UdpFault.truncate())
EtherCAT.Simulator.Udp.inject_fault(UdpFault.wrong_idx() |> UdpFault.next(2))

EtherCAT.Simulator.Udp.inject_fault(
  UdpFault.script([UdpFault.unsupported_type(), UdpFault.replay_previous()])
)
```

That boundary matters:

- `EtherCAT.Simulator` owns datagram/runtime behavior
- `EtherCAT.Simulator.Udp` owns malformed, stale, or mismatched raw replies
- both builder modules expose `describe/1` for widget-facing labels

## Delay Semantics

The simulator currently supports delayed fault scheduling, not general transport
latency simulation.

What exists today:

- `Fault.after_ms(fault, delay_ms)` delays when a fault becomes active
- `Fault.after_milestone(fault, milestone)` delays fault activation until a
  deterministic simulator milestone is observed
- the DC register model carries `system_time_delay_ns` so DC reads can expose
  realistic-looking delay values during clock setup and diagnostics

What does not exist today:

- no built-in "reply after N ms" transport fault
- no random jitter model
- no per-port or per-hop wire propagation model

Normal UDP reply handling is otherwise immediate: `EtherCAT.Simulator.Udp`
decodes the payload, runs the datagrams, encodes the reply, and sends it back
in the same request/response path.

That is deliberate. Most master regressions in this repo are about missing
replies, wrong WKCs, malformed mailbox exchanges, reconnect sequencing, and
fault retention. Those benefit from deterministic fault windows more than from
approximate latency modeling.

If late-but-valid replies ever become important, add them as a narrow UDP-edge
fault with explicit timing, not as a broad jitter or physics model across the
whole simulator.

## Intentional Limits

Current deliberate scope limits:

- no raw-socket simulator endpoint yet
- no carrier/link-loss simulation below the protocol layer
- no generic transport-latency or jitter model
- no full motion physics for drives
- no complete SDO Info service surface
- no attempt to mirror SOES internal control flow one-to-one

The simulator is meant to be a deterministic protocol and device-behavior test
tool, not a full field-device firmware stack.
