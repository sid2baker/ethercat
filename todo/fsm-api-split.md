# Refactor: Move gen_statem implementations to `FSM` submodules

## Goal

Make each top-level module (`EtherCAT.Slave`, `EtherCAT.Master`, `EtherCAT.DC`,
`EtherCAT.Domain`) the documented public API, and move the gen_statem
implementation into a `FSM` submodule inside the existing subfolder.

This is idiomatic Elixir: the module named after the concept owns the public
contract; the process machinery is an implementation detail.

## Current shape

```
lib/ethercat/slave.ex          defmodule EtherCAT.Slave          ← gen_statem today
lib/ethercat/slave/api.ex      defmodule EtherCAT.Slave.API       ← public API today

lib/ethercat/master.ex         defmodule EtherCAT.Master          ← gen_statem today
lib/ethercat/master/api.ex     defmodule EtherCAT.Master.API      ← public API today

lib/ethercat/dc.ex             defmodule EtherCAT.DC              ← gen_statem today
lib/ethercat/dc/api.ex         defmodule EtherCAT.DC.API          ← public API today

lib/ethercat/domain.ex         defmodule EtherCAT.Domain          ← gen_statem today
lib/ethercat/domain/api.ex     defmodule EtherCAT.Domain.API      ← public API today
```

## Target shape

```
lib/ethercat/slave.ex          defmodule EtherCAT.Slave           ← public API (was api.ex)
lib/ethercat/slave/fsm.ex      defmodule EtherCAT.Slave.FSM       ← gen_statem (was slave.ex)

lib/ethercat/master.ex         defmodule EtherCAT.Master          ← public API (was api.ex)
lib/ethercat/master/fsm.ex     defmodule EtherCAT.Master.FSM      ← gen_statem (was master.ex)

lib/ethercat/dc.ex             defmodule EtherCAT.DC              ← public API (was api.ex)
lib/ethercat/dc/fsm.ex         defmodule EtherCAT.DC.FSM          ← gen_statem (was dc.ex)

lib/ethercat/domain.ex         defmodule EtherCAT.Domain          ← public API (was api.ex)
lib/ethercat/domain/fsm.ex     defmodule EtherCAT.Domain.FSM      ← gen_statem (was domain.ex)
```

## Steps (per subsystem, repeat for all four)

Work one subsystem at a time. Complete and compile-check before moving to the next.

### 1. Rename the gen_statem file

```
git mv lib/ethercat/slave.ex lib/ethercat/slave/fsm.ex
```

Change the module declaration inside from `EtherCAT.Slave` to `EtherCAT.Slave.FSM`.

Update `child_spec` and `start_link` so the process registers as `EtherCAT.Slave.FSM`
(or keeps its existing registry / local name, updated to the new module name).

Add `@moduledoc false` — the FSM is an internal detail.

### 2. Rename the api.ex file to the top-level module

```
git mv lib/ethercat/slave/api.ex lib/ethercat/slave.ex
```

Change the module declaration from `EtherCAT.Slave.API` to `EtherCAT.Slave`.

The `@moduledoc` and all public `@spec`-annotated functions stay here. This is
now the documented face of the subsystem.

### 3. Update all callers of the old `EtherCAT.*.API` module name

Files that alias or call the old `.API` modules:

**lib/**
- `lib/ethercat.ex` — aliases `Slave.API`, `Master.API`, `Domain.API`
- `lib/ethercat/slave/process_data.ex` — calls `Slave.API`
- `lib/ethercat/slave/runtime/signals.ex` — calls `Slave.API`
- `lib/ethercat/master/status.ex`, `startup.ex`, `activation.ex`, `recovery.ex`,
  `calls.ex`, `preop.ex`, `deactivation.ex` — call `Master.API`, `Slave.API`,
  `Domain.API`, `DC.API`

**test/**
- `test/ethercat/dc/runtime_test.exs`
- `test/ethercat/master_test.exs`
- `test/ethercat/domain_test.exs`
- `test/ethercat/master_recovery_bus_test.exs`
- `test/ethercat/api_resilience_test.exs`
- `test/integration/hardware/scripts/*.exs`

In every file: drop the `.API` suffix from aliases and direct calls.
`EtherCAT.Slave.API.info/1` → `EtherCAT.Slave.info/1`, etc.

### 4. Update internal FSM references

Inside each FSM module, references to `__MODULE__` in `child_spec` / `start_link`
now resolve to `EtherCAT.Slave.FSM`. Confirm the process registration strategy:

- **Slave** — uses `{:via, Registry, {EtherCAT.Registry, {:slave, name}}}`.
  The via tuple is name-based so the FSM module name does not leak into lookups.
  No change needed in callers.
- **Master** — uses `{:local, EtherCAT.Master}`. After move: change to
  `{:local, EtherCAT.Master.FSM}` and update any `GenServer.call(EtherCAT.Master, ...)`
  in `Master.API` (now `EtherCAT.Master`) to `EtherCAT.Master.FSM`.
- **DC** — uses `{:local, __MODULE__}` → becomes `{:local, EtherCAT.DC.FSM}`.
  Update `DC.API` (now `EtherCAT.DC`) accordingly.
- **Domain** — no local name; pid passed explicitly. No registration change needed.

### 5. Compile check after each subsystem

```
mix compile --warnings-as-errors
```

Fix any undefined function or missing alias errors before moving to the next
subsystem.

### 6. Run the full test suite

```
mix test
```

All 345 tests must pass. No behaviour changes — this is a pure rename/restructure.

### 7. Delete the old `api.ex` files (already moved in step 2)

Git tracks the rename automatically via `git mv`. Confirm with `git status` that
no orphan files remain.

## Order of subsystems

Do them in this order to minimise cascading compile errors:

1. **DC** — smallest FSM, fewest callers, no via-registry complexity
2. **Domain** — no local name registration, isolated callers
3. **Slave** — via-registry so registration is transparent; most internal modules
4. **Master** — most callers, local-name registration change required; do last

## Invariants to preserve

- Public function signatures do not change.
- `child_spec/1` remains on the top-level module (`EtherCAT.Slave`, etc.) and
  delegates start to the FSM module.
- The `@moduledoc` (including the `File.read!` external markdown) moves with the
  public API file, not the FSM file.
- No new public functions are added during this refactor.

## Out of scope

- The `EtherCAT.Bus` / `EtherCAT.Bus.Link` restructure is tracked separately
  (see the Circuit refactor plan).
- `EtherCAT.Simulator` is not included; it has a different shape.
