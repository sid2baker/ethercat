# EtherCAT

## Navigation

- Implementation truth lives in source, tests, and module docs:

- `lib/ethercat.ex`, `lib/ethercat/master.ex`, `lib/ethercat/slave.ex`
- `lib/ethercat/domain.ex`, `lib/ethercat/bus.ex`, `lib/ethercat/dc.ex`
- public moduledocs in the runtime boundary modules above
- `test/` — behavioral truth and regression coverage
- `ARCHITECTURE.md` — subsystem boundaries and runtime data flow

- Local LLM helper material may exist outside the tracked repo; treat it as secondary reference only, never implementation truth.

## Hard Rules

- **API**: pre-release, prefer clarity over compatibility; no shims
- **Bitwise**: never `import Bitwise`; use binary pattern matching
- **`gen_statem` enter callbacks**: side effects only, no state transitions
- **Changelog**: as soon as a change is release-note-worthy, add it to `CHANGELOG.md` under `[Unreleased]` in the right section. Include the short git hash for the change; if the commit does not exist yet, add the entry immediately and update it with the short hash before handing off or finalizing the work.

## Design Direction

- **Spec first**: prefer EtherCAT models, sequencing, and lifecycle ownership that match the spec and the bundled reference-master material.
- **BEAM as implementation strength**: use OTP supervision, process isolation, registries, and restart tolerance to implement the model more robustly, not to invent protocol semantics that fight the spec.
- **Document deliberate deviations**: if the implementation intentionally differs from the spec for pragmatic reasons, make that explicit in code and docs instead of letting it emerge accidentally.
- **Faults stay visible**: use BEAM fault tolerance to recover cleanly where possible, but do not hide transport, WKC, AL-state, or topology faults behind overly optimistic state reporting.

## Checks

- `mix test` — behavior
- `mix usage_rules.docs Module` — docs lookup
- `mix usage_rules.search_docs query` — cross-package search

<!-- usage-rules-start -->
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
- After a full test run, use `mix test --failed` to re-run only the failures
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
