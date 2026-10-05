# Driver catalogue experiment

Run the executable comparison:

```sh
mix test test/ethercat/driver/catalogue_example_test.exs
```

- **Before:** `SeparateDeclarations` in that test file maintains mappings and
  endpoint descriptions independently. Both functions list the signal names and
  both decide whether to include diagnostics.
- **After:** [`catalogue_example.ex`](catalogue_example.ex) implements the same
  `EtherCAT.Driver` behaviour using one private catalogue. Each row pairs an
  existing `%EtherCAT.Endpoint{}` with an existing `%EtherCAT.Driver.Signal{}`.
  Neither the public behaviour nor the runtime changes.

This is a hypothetical positioning device, not a validated hardware driver:

| Signal | Direction (master perspective) | Codec | PDO | Bit offset within PDO |
| --- | --- | --- | --- | --- |
| `controlword` | output | unsigned 16-bit | `0x1600` | 0 |
| `target_position` | output | signed 32-bit | `0x1600` | 16 |
| `statusword` | input | unsigned 16-bit | `0x1A00` | 0 |
| `actual_position` | input | signed 32-bit | `0x1A00` | 16 |
| `temperature` | input, optional | signed 16-bit | `0x1A01` | 0 |

The known device configuration `%{diagnostics?: true}` enables the temperature
signal. It does **not** perform mailbox writes or configure the hardware. The
caller must arrange the corresponding device configuration separately.

## What becomes simpler

The shared row for the optional signal is:

```elixir
{%Endpoint{signal: :temperature, direction: :input, type: :i16},
 Signal.slice(0x1A01, 0, 16)}
```

`catalogue/1` owns the configuration decision once. `signal_model/2` projects the
name and mapping; `describe/1` projects the endpoint; the codecs look up the
row's type and direction. Enabling the row therefore enables all three views.
Descriptions remain available without discovery or bus access.

The comparison tests establish identical declarations with diagnostics enabled
and disabled. They also exercise the actual runtime codec wrappers and planner:
PDO-relative offsets, mixed integer widths, signed little-endian values, missing
PDOs, short PDOs, and explicit codec errors. The baseline delegates its codecs
to the example intentionally: this is a declaration comparison, not an
independent codec implementation or a claim about total line count. Codec tests
use explicit expected byte sequences rather than just round trips.

## What this does not prove

- **It does not justify a new driver API.** The existing callbacks already allow
  shared declarations. This is an authoring pattern, not a proposed framework.
- **It does not discover arbitrary layouts.** The driver knows two configurations
  with fixed PDO indices and entry layouts. It deliberately leaves missing PDOs
  in the mapping so the planner reports them rather than silently dropping
  signals. Discovery-dependent layouts would still need a resolution step.
- **It is not necessarily faster or shorter.** The catalogue adds lookup code;
  codecs linearly search a small list on each call. No performance claim is made.
- **It does not eliminate every inconsistency.** Scalar types and slice widths
  remain explicit, and a declared direction can still disagree with discovery.
  The tests check this fixture's consistency; the row representation alone does
  not enforce it. Special encodings still require explicit custom codec logic.

**Conclusion:** sharing a device's signal declarations can remove duplicated
names and configuration branches while retaining offline descriptions and
visible errors. This supports simplifying concrete drivers first, not replacing
`EtherCAT.Driver` based on one example.
