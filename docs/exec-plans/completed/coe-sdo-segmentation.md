# Plan: CoE SDO Segmentation and Mailbox Core

## Status: COMPLETED

## Reading Note

This is the execution plan that led to the current CoE mailbox implementation.
It includes the original target API discussion; the actual implementation kept
the mailbox counter explicit in the internal `CoE` API and exposed public SDO
helpers at the `Slave`/`EtherCAT` layers.

## Outcome

Implemented:
- any-size CoE SDO download via expedited or segmented transfer
- any-size CoE SDO upload via expedited or segmented transfer
- explicit mailbox counter ownership in `EtherCAT.Slave`
- strict mailbox/CoE/SDO response envelope validation
- public `Slave.download_sdo/4`, `Slave.upload_sdo/3`, `EtherCAT.download_sdo/4`, and `EtherCAT.upload_sdo/3`
- PREOP `mailbox_config/1` support for arbitrary binary payload sizes
- focused protocol tests and PREOP integration tests

## Goal

Implement a spec-aligned CoE mailbox layer that supports any-size SDO
downloads and uploads via:

- expedited transfer for small payloads
- normal + segmented transfer for larger payloads
- strict mailbox/CoE/SDO response validation

This should replace the current expedited-download-only path in
`lib/ethercat/slave/coe.ex`.

## Why This Matters

The current CoE layer is intentionally narrow:

- expedited SDO download only
- payload size limited to `1 | 2 | 4` bytes
- no upload path
- no segmented transfer

That is sufficient for many Beckhoff terminals, but not for more general
EtherCAT slaves and not for a serious CoE implementation. Larger object
values, strings, arrays, richer PDO remaps, and many drive parameters need
normal/segmented SDO transfer.

This work moves the library closer to the EtherCAT/CoE model described in:

- `docs/references/notes/coe-sdo.md`
- `docs/references/soem/src/ec_coe.c`
- `docs/references/igh/master/fsm_coe.c`

## Scope

### In scope

1. Mailbox send/check/fetch helpers with stricter validation.
2. Any-size SDO download:
   - expedited when possible
   - normal init + segmented continuation otherwise
3. Any-size SDO upload:
   - expedited response path
   - normal init + segmented continuation otherwise
4. Proper SDO abort parsing and propagation.
5. Mailbox counter handling for request/response matching.
6. Tests for protocol correctness and failure modes.

### Explicitly out of scope

1. Block transfer.
2. Complete Access.
3. Emergency object handling beyond "ignore and continue checking" if needed.
4. General CoE object-dictionary browsing APIs.
5. FoE, EoE, SoE.

Those can come later. Do not blur this implementation with a full mailbox
subsystem rewrite.

## Target API

Keep the public shape small and honest.

### Internal CoE API

Replace the current write-only function with:

```elixir
CoE.download_sdo(bus, station, mailbox_config, mailbox_counter, index, subindex, binary)
CoE.upload_sdo(bus, station, mailbox_config, mailbox_counter, index, subindex)
```

Semantics:

- `download_sdo/7` accepts any non-empty binary
- `upload_sdo/6` returns `{:ok, binary, mailbox_counter}` or `{:error, reason}`
- transfer mode is selected internally

Public slave-facing wrappers:

```elixir
Slave.download_sdo(slave_name, index, subindex, binary)
Slave.upload_sdo(slave_name, index, subindex)
```

### Driver integration

`mailbox_config/1` already returns binary payloads:

```elixir
{:sdo_download, index, subindex, binary}
```

That API should remain unchanged. `Slave.run_mailbox_config/1` should call the
new `CoE.download_sdo/7`.

## Design

### 1. Separate mailbox transport from SDO protocol

Split `EtherCAT.Slave.Mailbox.CoE` into two conceptual layers even if they stay in one
module at first:

1. Mailbox transport helpers
   - `send_mailbox/4`
   - `wait_mailbox_response/3`
   - `fetch_mailbox/4`
   - mailbox header parsing/validation

2. SDO protocol helpers
   - build init download/upload requests
   - parse init responses
   - build segment requests
   - parse segment responses
   - abort handling

This keeps the protocol state machine readable.

### 2. Introduce explicit transfer state structs

Add internal structs:

```elixir
%Download{
  index: non_neg_integer(),
  subindex: non_neg_integer(),
  data: binary(),
  offset: non_neg_integer(),
  toggle: 0 | 1,
  mailbox_counter: 0..7
}

%Upload{
  index: non_neg_integer(),
  subindex: non_neg_integer(),
  data: iodata(),
  size: non_neg_integer() | nil,
  toggle: 0 | 1,
  mailbox_counter: 0..7
}
```

These are internal only. They exist to keep segment loops explicit and testable.

### 3. Keep the implementation procedural, not `gen_statem`

For this codebase, follow the SOEM-style blocking approach rather than the
IgH FSM shape.

Reason:

- `CoE` is currently a blocking helper called from slave PREOP handling
- no separate CoE process exists
- procedural transfer loops are simpler here

Use the references for protocol logic, not for architecture.

### 4. Make mailbox counters explicit

Today the mailbox header hardcodes counter `0`.

That is too weak for a real CoE layer.

Add:

- a mailbox counter allocator per slave process
- request header counter assignment
- response counter validation when possible

The simplest shape is to store `mailbox_counter` in `EtherCAT.Slave` state and
pass the next counter into `CoE`.

Recommended API:

```elixir
CoE.download_sdo(bus, station, mailbox_config, mailbox_counter, index, subindex, binary)
CoE.upload_sdo(bus, station, mailbox_config, mailbox_counter, index, subindex)
```

Then `Slave` owns counter progression.

### 5. Validate the full response envelope

Every received mailbox response should validate:

1. mailbox protocol type is CoE
2. CoE service class is SDO response
3. index/subindex echo matches
4. command class matches expected transfer phase
5. abort frames are handled before generic validation
6. segment toggle matches expected value

Do not accept "looks vaguely like CoE" responses.

### 6. Implement transfer modes in this order

#### Phase A: expedited download

Keep the current path, but rewrite it using the new request/response helpers.

#### Phase B: normal + segmented download

For payloads larger than expedited capacity:

1. send init download request with declared total size
2. include as much initial data as mailbox size allows
3. validate init response
4. send segment requests until done
5. flip toggle bit on each segment
6. validate last-segment acknowledgement

#### Phase C: upload

1. send upload-init request
2. parse response
3. if expedited, return immediately
4. if normal transfer, capture total size if present
5. request segments until last flag
6. flip toggle bit on each segment
7. assemble response binary

### 7. Keep timeout policy simple

Do not introduce separate timers/processes.

Use the existing blocking call model:

- mailbox write
- mailbox status poll
- mailbox fetch

Add one coherent timeout option for the whole SDO transfer and derive per-loop
poll exhaustion from that.

## File Plan

### Primary files

- `lib/ethercat/slave/coe.ex`
- `lib/ethercat/slave.ex`

### New internal helpers if needed

- `lib/ethercat/slave/coe/mailbox.ex`
- `lib/ethercat/slave/coe/sdo.ex`
- `lib/ethercat/slave/coe/download.ex`
- `lib/ethercat/slave/coe/upload.ex`

Do not split prematurely. Start in one file, extract only if the protocol code
gets too dense.

### Tests

- `test/ethercat/slave/coe_test.exs`
- update slave PREOP config tests as needed

## Test Strategy

### Unit tests

1. expedited download request encoding
2. normal download init request encoding
3. segment request encoding
4. expedited upload response parsing
5. normal upload init parsing
6. segment response parsing
7. abort parsing
8. toggle mismatch rejection
9. wrong index/subindex rejection
10. wrong mailbox protocol rejection

### Procedural transfer tests

Use a fake mailbox exchange layer or fake Bus responses to simulate:

1. successful expedited download
2. successful segmented download across multiple segments
3. successful expedited upload
4. successful segmented upload
5. abort on init response
6. abort on middle segment
7. response timeout
8. malformed segment response

### Integration tests

1. `mailbox_config/1` with a `> 4` byte payload succeeds through `Slave`
2. PREOP activation fails cleanly on CoE abort

## Acceptance Criteria

1. `mailbox_config/1` supports arbitrary binary payload sizes.
2. `CoE.upload_sdo/6` exists and returns arbitrary-size binaries.
3. Expedited and segmented SDO paths share one validation model.
4. Mailbox counters are no longer hardcoded.
5. Abort frames return structured errors.
6. Toggle mismatch is detected and treated as a transfer error.
7. Full test suite passes.

## Recommended Implementation Order

1. Introduce mailbox counter ownership in `Slave`.
2. Refactor `CoE` around mailbox request/check/fetch helpers.
3. Re-implement expedited download on the new helpers.
4. Add normal + segmented download.
5. Switch `mailbox_config/1` to any-size download.
6. Add upload init + expedited upload.
7. Add segmented upload.
8. Tighten docs and examples.

## Risks

1. Mailbox counter semantics may vary across slaves more than the simple path
   assumes. Keep validation strict but not speculative.
2. Some slaves emit emergency mailbox frames between request and response.
   Decide explicitly whether to ignore-and-continue or reject.
3. Segmented upload/download loops are easy to get subtly wrong on toggle and
   last-segment padding. Test these heavily.

## Non-Goals for This Pass

Do not try to become a full generic CoE browser yet.

This implementation should stop at:

- robust SDO upload/download
- correct segmentation
- correct mailbox handling

That is enough to unblock larger PREOP configs and device parameter access
without turning the refactor into an open-ended protocol project.
