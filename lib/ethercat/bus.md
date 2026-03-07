EtherCAT bus scheduler and frame transport coordinator.

`EtherCAT.Bus` is the single serialization point for all EtherCAT frame I/O.
Callers build `EtherCAT.Bus.Transaction` values and submit them as either:

- `transaction/2` — reliable work, eligible for batching with other reliable transactions
- `transaction/3` — realtime work with a staleness deadline; stale work is discarded

Realtime and reliable transactions are strictly separated:
realtime always has priority, and realtime transactions never share a frame with
reliable transactions.
