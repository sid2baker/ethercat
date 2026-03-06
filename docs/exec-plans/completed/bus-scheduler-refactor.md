# Plan: Refactor Bus into Scheduler + Link Adapter

## Status: COMPLETED

## Reading Note

This is the execution plan that led to the current bus architecture. It
intentionally contains historical references to removed APIs such as
`transaction_queue/2` because those were the target of the refactor, not current
guidance.

## Outcome

Implemented:
- `EtherCAT.Bus` as the only scheduler `gen_statem`
- one public API: `Bus.transaction/2|3`
- `Submission` and `InFlight` as explicit internal lifecycle records
- `Bus.Link.SinglePort` and `Bus.Link.Redundant` as topology-specific roundtrip adapters
- strict realtime priority with no mixed realtime/reliable frames
- removal of `transaction_queue/2`, `Command`, and the legacy redundant scheduler module

## Goal

Refactor the EtherCAT bus layer so `EtherCAT.Bus` is the real scheduler `gen_statem`,
with one public transaction API:

```elixir
Bus.transaction(bus, tx)
Bus.transaction(bus, tx, deadline_us)
```

The result should be:
- one public verb instead of `transaction/3` plus `transaction_queue/2`
- one scheduler implementation instead of duplicating policy in `SinglePort` and later `Redundant`
- clearer separation between caller intent, bus scheduling, link behavior, and low-level transport
- no added idle-path latency from the refactor

## Non-Goals

- Do not change EtherCAT wire encoding semantics in `Datagram` or `Frame`.
- Do not change the meaning of `Result` fields.
- Do not add "wait to batch" behavior when the bus is idle.

## Current Structural Problem

Today `EtherCAT.Bus` is not the scheduler. `Bus.start_link/1` selects `SinglePort` or
`Redundant` as the actual `gen_statem`, so the top-level bus API module does not own state.
That inversion causes the current duplication and boundary drift:

- `Bus` defines the public API
- `SinglePort` owns scheduling, batching, IDX stamping, reply demux, and queue policy
- `Redundant` mirrors the same concerns in a different module
- `transaction_queue/2` exposes scheduling policy as a second public verb

The refactor should reverse that:

- `Bus` owns scheduling and policy
- link modules own link-specific behavior only
- low-level transport modules own raw socket / UDP mechanics only

## Target Abstraction Model

### `EtherCAT.Bus`

The only bus process and the only scheduler state machine.

Owns:
- realtime and reliable queues
- expiry checks
- fairness policy
- frame packing
- datagram IDX stamping
- in-flight tracking
- response slicing back to original callers
- frame timeout handling
- carrier/reconnect coordination
- telemetry emission around scheduling and frame lifecycle

States:
- `:idle`
- `:awaiting`
- `:down`

### `EtherCAT.Bus.Transaction`

Public caller-side request object.

Responsibilities:
- express one ordered unit of caller intent
- preserve caller-defined datagram grouping
- remain independent of frame packing decisions

`Transaction` remains a better public name than `Request` because one transaction is a
logical caller operation that may become part of a larger combined frame.

### `EtherCAT.Bus.Datagram`

Protocol primitive and wire codec.

Responsibilities:
- datagram struct
- datagram encode/decode
- wire-size calculation

No queueing or scheduling policy belongs here.

### `EtherCAT.Bus.Submission`

Internal pre-send scheduling record.

Purpose:
- represent one queued caller submission before anything is put on the wire
- keep scheduling data separate from send/receive tracking

Proposed shape:

```elixir
defmodule EtherCAT.Bus.Submission do
  @type t :: %__MODULE__{
          from: :gen_statem.from(),
          tx: EtherCAT.Bus.Transaction.t(),
          deadline_us: pos_integer() | nil,
          enqueued_at_us: integer()
        }

  defstruct [:from, :tx, :deadline_us, :enqueued_at_us]
end
```

Notes:
- `deadline_us == nil` means reliable
- `deadline_us != nil` means realtime
- no IDXs here
- no wire payload here
- no reply routing here

### `EtherCAT.Bus.InFlight`

Internal post-send tracking record for the one frame currently awaiting a response.

Purpose:
- record exactly how the sent frame maps back to original callers
- separate reply routing from queue scheduling

Proposed shape:

```elixir
defmodule EtherCAT.Bus.InFlight do
  @type awaiting_t :: {:gen_statem.from(), [byte()]}

  @type t :: %__MODULE__{
          awaiting: [awaiting_t],
          tx_at: integer(),
          payload_size: non_neg_integer(),
          datagram_count: pos_integer()
        }

  defstruct [:awaiting, :tx_at, :payload_size, :datagram_count]
end
```

Notes:
- `awaiting` is the critical reply-slicing structure
- `Submission` is pre-send
- `InFlight` is post-send
- these should stay separate abstractions

### `EtherCAT.Bus.Result`

Public per-datagram response item.

Keep this struct and its semantics:
- `data`
- `wkc`
- `circular`
- `irq`

`Result` remains a reasonable public name. `Response` is less precise because:
- one API call returns many per-datagram results
- one frame response may satisfy multiple queued submissions
- frame boundaries and transaction boundaries do not always align

### `EtherCAT.Bus.Link`

New narrow link-adapter behavior.

This is the correct abstraction for `SinglePort` now and `Redundant` later.

Responsibilities:
- open/close link resources
- send one EtherCAT payload
- arm for one receive
- match incoming process messages
- drain buffered frames
- expose interface metadata needed by `Bus`

Non-responsibilities:
- no caller queues
- no deadline handling
- no batching policy
- no IDX stamping
- no reply demux

### `EtherCAT.Bus.Transport`

Low-level socket transport behavior remains below the link adapter.

Examples:
- `RawSocket`
- `UdpSocket`

This layer owns raw Ethernet / UDP mechanics, not bus scheduling.

## Public API Decision

Replace the current split API:

```elixir
Bus.transaction(bus, fun, timeout_us)
Bus.transaction_queue(bus, fun)
```

with:

```elixir
Bus.transaction(bus, tx)
Bus.transaction(bus, tx, deadline_us)
```

Semantics:
- `transaction/2` = reliable
- `transaction/3` = realtime, discard if stale at dispatch time

Important:
- do not use named options for policy
- do not keep `transaction_queue/2`
- do not use a default third argument; define two heads explicitly

## Transaction Ergonomics

`Bus.transaction/2|3` should accept `Transaction.t()` directly, not a builder callback.

This is a smaller change than it looks because the current callback is already executed in the
caller process before the `gen_statem` call.

To keep call sites terse, `Transaction` should support both:

```elixir
Transaction.new()
|> Transaction.fpwr(station, reg)
|> Transaction.fprd(station, reg)
```

and single-transaction constructors:

```elixir
Transaction.fprd(station, reg)
Transaction.fpwr(station, reg)
Transaction.lrw({logical_addr, image})
```

That implies dual-arity helpers where useful:
- `fprd/2` and `fprd/3`
- `fpwr/2` and `fpwr/3`
- etc.

The goal is:
- no callback-based builder API
- no forced `Transaction.new()` for single datagram requests

## Naming Decision: `Transaction` / `Submission` / `InFlight` / `Result`

Do not rename everything to `Request` / `Response`.

Those names blur important lifecycle distinctions:
- API request
- queued request
- sent frame
- frame response
- per-datagram caller result

The clearer naming is:
- `Transaction` = public caller intent
- `Submission` = internal queued work
- `InFlight` = internal sent-frame routing record
- `Result` = public per-datagram response item

This keeps abstractions phase-specific instead of overloading "request" and "response".

## Scheduling Policy

### Queue Structure

Replace `:postpone` with explicit queues.

Use separate internal queues:
- realtime queue
- reliable queue

Use an append-efficient structure such as `:queue`.

Reasons:
- deterministic expiry checks
- visible and inspectable backlog
- transport-agnostic policy
- no hidden dependence on the `gen_statem` internal event queue

### Dispatch Rules

When the bus is idle:
- send immediately
- do not wait to accumulate more reliable work just to batch
- never hold realtime work to coalesce it with reliable work

After a response, timeout, or reconnect:
1. expire stale realtime submissions
2. if any live realtime submission exists, send exactly one realtime transaction
3. otherwise take as many reliable submissions as fit under MTU and send them in one frame

This preserves low latency while moving frame packing fully into the bus.

### Class Separation and Priority

Treat realtime and reliable as strictly separate scheduling classes.

Hard rules:
- realtime and reliable submissions must never share a frame
- realtime always has priority over reliable after stale realtime submissions are expired
- a dispatched realtime transaction is always sent alone
- reliable batching is only allowed with other reliable submissions

Consequences:
- realtime gets the lowest possible latency the architecture can provide
- reliable work can starve under sustained realtime load

That tradeoff is intentional and correct for cyclic EtherCAT traffic. If fairness is ever
needed later, it should be introduced deliberately as a policy change rather than emerging
accidentally from queue mechanics.

### Caller Intent vs Frame Packing

Keep transaction boundaries.

Meaning:
- the caller still defines which datagrams belong together as one logical transaction
- the bus decides whether multiple reliable transactions can share one frame

The bus may coalesce multiple reliable transactions into one frame, but it must still reply
to each original caller with results in that transaction's original order.

## Carrier Monitoring and Reconnect Ownership

`Bus` should own VintageNet subscriptions and reconnect coordination.

Today the `SinglePort` process subscribes directly. That should move to `Bus.init/1`.

The active link adapter should expose enough interface metadata for `Bus` to decide whether:
- carrier monitoring applies
- which interface(s) to subscribe to

Do not add a generic `subscribe/1` callback. Subscription ownership belongs with the process
that owns state transitions, which is `Bus`.

## Warmup Decision

Remove `warmup/1` from the shared abstraction model.

Rationale:
- it is not a bus concern
- it is not really a link concern
- it is only a transport-specific workaround

If a transport-specific startup workaround is still needed later, keep it internal to that
transport's open path rather than exposing it as a generic lifecycle callback.

## Redundant Path

Redundant mode now follows the same scheduler boundary as single-port mode:
- `Bus` owns queueing, deadlines, batching, IDX stamping, and reply slicing
- `Bus.Link.Redundant` owns duplicate send, per-port receive, response merge, degradation, and reconnect

The old `lib/ethercat/bus/transport/redundant.ex` scheduler path was removed.

## Files to Create

### 1. `lib/ethercat/bus/submission.ex`

Internal `Submission` struct module.

### 2. `lib/ethercat/bus/in_flight.ex`

Internal `InFlight` struct module.

### 3. `lib/ethercat/bus/link.ex`

New link-adapter behavior for `SinglePort` now and `Redundant` later.

### 4. `lib/ethercat/bus/link/single_port.ex`

New home for single-port link adapter logic after removing scheduler concerns from the
current `transport/single_port.ex`.

### 5. `test/ethercat/bus_test.exs`

New tests for bus scheduling semantics, queue policy, expiry, batching, and reply slicing.

## Files to Edit

### 6. `lib/ethercat/bus.ex`

Rewrite as the actual scheduler `gen_statem`.

Required changes:
- implement `init/1`, `callback_mode/0`, and `handle_event/4`
- own `:idle`, `:awaiting`, and `:down`
- accept `Transaction.t()` directly
- provide `transaction/2` and `transaction/3`
- remove `transaction_queue/2`
- normalize inputs into `Submission`
- own explicit realtime/reliable queues
- build `InFlight` at send time
- own frame timeout handling
- own carrier-related transitions

### 7. `lib/ethercat/bus/transaction.ex`

Refactor `Transaction` into a real value object.

Required changes:
- remove dependency on `Command`
- build `%Datagram{}` directly
- support direct constructors for single-datagram transactions
- keep append-efficient internal storage
- finalize ordering once before send

### 8. `lib/ethercat/bus/result.ex`

Likely no semantic change, but confirm docs still describe the new single-API flow.

### 9. `lib/ethercat/bus/transport.ex`

Remove `warmup/1` from the behavior and docs.

Keep only low-level transport responsibilities.

### 10. `lib/ethercat/bus/transport/raw_socket.ex`

Adjust to the simplified transport behavior.

If startup warmup behavior is still needed, hide it internally rather than exposing it through
the generic behavior.

### 11. `lib/ethercat/bus/transport/udp_socket.ex`

Adjust to the simplified transport behavior.

### 12. `lib/ethercat/bus/transport/single_port.ex`

Retire or replace. Its scheduler responsibilities move into `Bus`, and its remaining
link-specific behavior moves to `lib/ethercat/bus/link/single_port.ex`.

### 13. `lib/ethercat/master.ex`

Update bus call sites:
- scan BRD
- station assignment
- DL status reads

All call sites should build `Transaction.t()` and use `Bus.transaction/2|3`.

### 14. `lib/ethercat/dc.ex`

Update:
- periodic ARMW drift tick -> `Bus.transaction(bus, tx, deadline_us)`
- clock init reads/writes -> `Bus.transaction(bus, tx)`

### 15. `lib/ethercat/domain.ex`

Update cyclic LRW call site to `Bus.transaction(bus, tx, deadline_us)`.

### 16. `lib/ethercat/slave.ex`

Update:
- AL transitions
- mailbox/SM/FMMU/DC config writes
- latch polling
- all config/runtime bus access to the new transaction API

### 17. `lib/ethercat/slave/sii.ex`

Update register reads/writes to the new transaction API.

### 18. `lib/ethercat/slave/coe.ex`

Update mailbox send/poll/read operations to the new transaction API.

### 19. `lib/ethercat/slave/registers.ex`

Update docs/examples that currently reference `transaction_queue/2`.

### 20. `ARCHITECTURE.md`

Update the bus description so it matches the final architecture.

### 21. `lib/ethercat/master.md`

Update public/internal bus semantics references.

### 22. `lib/ethercat/domain.md`

Update runtime transaction semantics references.

## Files to Delete

### 23. `lib/ethercat/bus/command.ex`

Delete after `Transaction` owns datagram construction directly.

## Files Explicitly Out of Scope

- `lib/ethercat/bus/frame.ex`
  Wire-format framing remains unchanged.

- `lib/ethercat/bus/datagram.ex`
  Keep encode/decode logic and wire-size helpers unless a small supporting edit is needed.

## Implementation Phases

### Phase 1 -- Public API and Core Value Objects

1. Change `Bus.transaction/2|3` to accept `Transaction.t()`.
2. Remove `transaction_queue/2`.
3. Refactor `Transaction` to build datagrams directly.
4. Delete `Command`.
5. Add append-efficient transaction internals and finalize-on-send behavior.

Expected result:
- public API shape settled
- call sites can be migrated incrementally
- duplicated opcode surface removed

### Phase 2 -- Internal Scheduling Abstractions

1. Add `Submission`.
2. Add `InFlight`.
3. Define internal bus queue state and dispatch helpers.
4. Define explicit expiry and fairness logic.

Expected result:
- scheduler concepts are explicit in code before transport boundaries are moved

### Phase 3 -- Move Scheduling into `Bus`

1. Rewrite `Bus` as the actual `gen_statem`.
2. Move queueing, batching, IDX stamping, reply slicing, and timeout logic into `Bus`.
3. Build `InFlight` at send time and consume it at response time.

Expected result:
- `Bus` is the only scheduler
- there is one implementation of queueing and reply demux

### Phase 4 -- Extract Link Adapter Boundary

1. Introduce `Bus.Link` behavior.
2. Move single-port wire/link mechanics into `link/single_port.ex`.
3. Move carrier monitoring ownership into `Bus`.
4. Remove generic warmup from the shared abstraction model.

Expected result:
- single-port path uses the new boundary
- link behavior is separated from scheduler policy

### Phase 5 -- Migrate Call Sites

Update all bus consumers to the new API:
- `master.ex`
- `dc.ex`
- `domain.ex`
- `slave.ex`
- `slave/sii.ex`
- `slave/coe.ex`

Guideline:
- `Bus.transaction(bus, tx)` for reliable/configuration/mailbox work
- `Bus.transaction(bus, tx, deadline_us)` for stale-sensitive runtime work

### Phase 6 -- Port Redundant and Remove Old Paths

1. Port `backup_interface` to `Bus.Link.Redundant`.
2. Remove old single-port and redundant scheduler code paths.
3. Ensure `Bus.start_link/1` always starts `Bus` itself.

Expected result:
- no split-brain scheduler architecture remains

### Phase 7 -- Tests and Docs

1. Add scheduling and reply-slicing tests.
2. Update architecture and subsystem docs.
3. Verify that docs no longer describe `transaction_queue/2` or transport-owned scheduling.

## Test Plan

Add focused tests for:

- `Transaction` preserves caller order
- single-datagram convenience constructors
- reliable `transaction/2`
- realtime `transaction/3`
- expiry of stale realtime submissions
- no intentional batching delay on an idle bus
- reliable batching up to MTU
- one realtime submission dispatched ahead of reliable backlog after expiry filtering
- realtime and reliable submissions never mixed into the same frame
- `InFlight.awaiting` reply slicing back to the correct caller
- frame timeout behavior
- down/reconnect transitions with carrier signals owned by `Bus`

Do not rely on `:postpone` semantics in tests after the refactor.

## Acceptance Criteria

The refactor is complete when all of the following are true:

1. `Bus.start_link/1` always starts `EtherCAT.Bus` as the scheduler process.
2. `Bus.transaction_queue/2` no longer exists.
3. `Bus.transaction/2` means reliable and `Bus.transaction/3` means realtime.
4. `Bus.transaction/2|3` accepts `Transaction.t()` directly.
5. `EtherCAT.Bus.Command` no longer exists.
6. `Bus` owns queueing, batching, IDX stamping, timeout handling, and reply demux.
7. `Submission` exists as the internal pre-send record.
8. `InFlight` exists as the internal post-send routing record.
9. `SinglePort` no longer owns pending queues, deadline logic, IDX logic, or reply slicing.
10. `Bus` owns carrier monitoring and reconnect transitions.
11. The implementation does not wait on an idle bus merely to batch reliable work.
12. Realtime expiry is deterministic and explicit.
13. Realtime and reliable submissions are never mixed into the same frame.
14. Live realtime submissions always dispatch ahead of reliable backlog.
15. Redundant mode is ported to the new boundary.
16. All docs and call sites reflect the new single-API model.
