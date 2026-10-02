# TODO

## Implementation

See `implementation-planning.md` for the full planning document. The remaining work is implementation design and empirical evaluation — the protocol specification (`protocol.md`) and formal model (`model/`) are complete.

Open design questions:

- Trace deduplication storage bounds (cap, expiry, bloom filters, or unbounded). Needs empirical evaluation against realistic Pony topologies.
- TRACE ROUTE trigger policy (on-acquisition, on-block, batched-on-block). Needs empirical evaluation.
- Runtime mode flag design (command-line, env var, compile-time).
- Per-actor storage layout in ponyc runtime.
- ORCA integration points (GC release → CONNECTION reset, rc → confirmation checks, self-reap guards).

## Formal model

- ~~Extend the Alloy model (or build a TLA+ model) to cover the full protocol lifecycle.~~ Done: TLA+ model covers trace propagation, cycle detection, multi-step confirmation, destruction, CONNECTION reset, EPOCH handling, ACTOR IDENTIFIER reuse.
- ~~Model cascading GC release during destruction. Currently DestroyConfirmedCycle removes all members atomically. A more realistic model would mark members for destruction, release references one at a time, and let members self-reap as their rc reaches 0.~~ Done: PR #9. SendRelease, ProcessRelease, and SelfReap replace atomic destruction.
- ~~Model per-hop epoch checking. Traces currently carry a set of actor IDs, not an ordered list of (ACTOR IDENTIFIER, EPOCH) pairs. Adding per-hop epochs would make the model more faithful and potentially fix CandidateSoundness.~~ Done: PR #10. Traces carry per-hop (id, epoch) records.
- ~~Model leadership determination and DELEGATE on DENIED. Currently the leader is fixed (detectedBy). In the protocol, leadership delegates to the first denier.~~ Done: PRs #12 and #13. Leader is lowest ID; DelegateLeadership sends DELEGATE to a denier on confirmation failure.
- ~~Test the model against a fully connected actor setup.~~
