# EtherCAT Agent Guide

## Quick Orientation

Start here. Read in order for any non-trivial task.

| File | What it gives you |
|------|-------------------|
| `docs/references/ethercat-spec/01-llm-reference-index.md` | **Primary reference entrypoint**; chapter map and context-loading guidance |
| `ARCHITECTURE.md` | System map, data flow, key design decisions |
| `lib/ethercat/slave.md` | Slave ESM lifecycle, driver contract, PDO registration, DC config |
| `lib/ethercat/master.md` | Master scan/configure/activate sequence, DC init steps |
| `lib/ethercat/domain.md` | Domain cyclic LRW, ETS schema, frame assembly, hot path |
| `docs/references/ethercat-esc-technology.md` | ESC hardware: FMMU, SM, DC, ESM, SII, interrupts |
| `docs/references/ethercat-esc-registers.md` | Full ESC register map |
| `docs/references/README.md` | **Reference implementations index** — IgH + SOEM file map by topic |
| `docs/references/igh/master/` | IgH EtherCAT Master source (C, kernel). Key files: `fsm_slave_config.c`, `fsm_coe.c`, `fsm_master.c` |
| `docs/references/soem/src/` | SOEM source (C, userspace). Key files: `ec_dc.c`, `ec_coe.c`, `ec_config.c` |
| `docs/exec-plans/active/dc-sync1-latch-complete.md` | Planned SYNC1 + LATCH implementation |
| `docs/exec-plans/tech-debt-tracker.md` | Known gaps across all subsystems |
| `docs/design-docs/engineering-summary.md` | Narrative summary with hardware observations |

---

## Hard Rules

### API Evolution (Pre-release)

This library is pre-release. Prefer API clarity over backward compatibility.

When a cleaner API requires a breaking change, make the breaking change and update
all call sites in the same change. Do not add compatibility shims, deprecation
layers, or dual-path behavior unless explicitly requested.

### Bitwise Operations

**Never use `import Bitwise` or Bitwise operators (`&&&`, `|||`, `band`, `bor`, etc.)**

Always use binary pattern matching to extract or compose bit fields:

```elixir
# Good
<<_::3, err_flag::1, state::4, _::8>> = register_bytes

# Bad
<<status::16-little>> = register_bytes
state = Bitwise.band(status, 0x0F)
```

To set a flag: use arithmetic (`state_code + 0x10`) when fields don't overlap, or
construct bytes directly (`<<flags::8>>`).

### gen_statem Enter Callbacks

**Enter callbacks may not transition state.** Returning `{:next_state, ...}` or
`{:next_event, ...}` from an enter callback is illegal — OTP will crash the process.

Enter callbacks are for unconditional side-effects only: arming a recurring timer,
emitting telemetry, logging. Nothing that decides where to go next.

Work that causes a state transition belongs in the event handler that decides to
transition:

```elixir
# Bad — enter callback trying to decide where to go
def handle_event(:enter, _old, :configuring, data) do
  new_data = do_configure(data)
  if done?(new_data),
    do: {:keep_state, new_data, [{:next_event, :internal, :done}]},  # illegal
    else: {:keep_state, new_data}
end

# Good — caller decides, enter callback just arms the timer
def handle_event({:timeout, :scan_poll}, nil, :scanning, data) do
  configured = do_configure(data)
  if done?(configured),
    do: {:next_state, :running, configured},
    else: {:next_state, :configuring, configured}
end
```

The same applies to `gen_statem.init/1`: start in the correct initial state directly
rather than using a `timeout 0` to immediately leave a placeholder state.

---

## Tooling

Use `mix usage_rules.docs Module` or `mix usage_rules.docs Module.fun/arity` to look up
documentation for Elixir, OTP, or any dependency. Use `mix usage_rules.search_docs query`
to search across all packages.

<!-- usage-rules-start -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

## Using Usage Rules

Many packages have usage rules, which you should *thoroughly* consult before taking any
action. These usage rules contain guidelines and rules *directly from the package authors*.
They are your best source of knowledge for making decisions.

## Modules & functions in the current app and dependencies

When looking for docs for modules & functions that are dependencies of the current project,
or for Elixir itself, use `mix usage_rules.docs`

```
# Search a whole module
mix usage_rules.docs Enum

# Search a specific function
mix usage_rules.docs Enum.zip

# Search a specific function & arity
mix usage_rules.docs Enum.zip/1
```


## Searching Documentation

You should also consult the documentation of any tools you are using, early and often. The best
way to accomplish this is to use the `usage_rules.search_docs` mix task. Once you have
found what you are looking for, use the links in the search results to get more detail. For example:

```
# Search docs for all packages in the current application, including Elixir
mix usage_rules.search_docs Enum.zip

# Search docs for specific packages
mix usage_rules.search_docs Req.get -p req

# Search docs for multi-word queries
mix usage_rules.search_docs "making requests" -p req

# Search only in titles (useful for finding specific functions/modules)
mix usage_rules.search_docs "Enum.zip" --query-by title
```


<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
# Elixir Core Usage Rules

## Pattern Matching
- Use pattern matching over conditional logic when possible
- Prefer to match on function heads instead of using `if`/`else` or `case` in function bodies
- `%{}` matches ANY map, not just empty maps. Use `map_size(map) == 0` guard to check for truly empty maps

## Error Handling
- Use `{:ok, result}` and `{:error, reason}` tuples for operations that can fail
- Avoid raising exceptions for control flow
- Use `with` for chaining operations that return `{:ok, _}` or `{:error, _}`

## Common Mistakes to Avoid
- Elixir has no `return` statement, nor early returns. The last expression in a block is always returned.
- Don't use `Enum` functions on large collections when `Stream` is more appropriate
- Avoid nested `case` statements - refactor to a single `case`, `with` or separate functions
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Lists and enumerables cannot be indexed with brackets. Use pattern matching or `Enum` functions
- Prefer `Enum` functions like `Enum.reduce` over recursion
- When recursion is necessary, prefer to use pattern matching in function heads for base case detection
- Using the process dictionary is typically a sign of unidiomatic code
- Only use macros if explicitly requested
- There are many useful standard library functions, prefer to use them where possible

## Function Design
- Use guard clauses: `when is_binary(name) and byte_size(name) > 0`
- Prefer multiple function clauses over complex conditional logic
- Name functions descriptively: `calculate_total_price/2` not `calc/2`
- Predicate function names should not start with `is` and should end in a question mark.
- Names like `is_thing` should be reserved for guards

## Data Structures
- Use structs over maps when the shape is known: `defstruct [:name, :age]`
- Prefer keyword lists for options: `[timeout: 5000, retries: 3]`
- Use maps for dynamic key-value data
- Prefer to prepend to lists `[new | list]` not `list ++ [new]`

## Mix Tasks

- Use `mix help` to list available mix tasks
- Use `mix help task_name` to get docs for an individual task
- Read the docs and options fully before using tasks

## Testing
- Run tests in a specific file with `mix test test/my_test.exs` and a specific test with the line number `mix test path/to/test.exs:123`
- Limit the number of failed tests with `mix test --max-failures n`
- Use `@tag` to tag specific tests, and `mix test --only tag` to run only those tests
- Use `assert_raise` for testing expected exceptions: `assert_raise ArgumentError, fn -> invalid_function() end`
- Use `mix help test` to for full documentation on running tests

## Debugging

- Use `dbg/1` to print values while debugging. This will display the formatted value and other relevant information in the console.

<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
# OTP Usage Rules

## GenServer Best Practices
- Keep state simple and serializable
- Handle all expected messages explicitly
- Use `handle_continue/2` for post-init work
- Implement proper cleanup in `terminate/2` when necessary

## Process Communication
- Use `GenServer.call/3` for synchronous requests expecting replies
- Use `GenServer.cast/2` for fire-and-forget messages.
- When in doubt, use `call` over `cast`, to ensure back-pressure
- Set appropriate timeouts for `call/3` operations

## Fault Tolerance
- Set up processes such that they can handle crashing and being restarted by supervisors
- Use `:max_restarts` and `:max_seconds` to prevent restart loops

## Task and Async
- Use `Task.Supervisor` for better fault tolerance
- Handle task failures with `Task.yield/2` or `Task.shutdown/2`
- Set appropriate task timeouts
- Use `Task.async_stream/3` for concurrent enumeration with back-pressure

<!-- usage_rules:otp-end -->
<!-- usage-rules-end -->
