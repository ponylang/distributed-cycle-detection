# TODO

## Protocol design

- Define exactly which state changes trigger an EPOCH increment. Candidates: gaining a CONNECTION, losing a CONNECTION, changes to known cycle set. The formal model should guide this.
- Document the MERGE operation for connected components (when overlapping cycles are discovered, how their member sets and cycle sets are unified).
- Document the RESET operation for CONNECTIONs (what exactly gets cleared, what messages are sent to other cycle members).
- Define how CONFIRM BLOCKED, CONFIRMED, DENIED, DELEGATE, and RELEASE messages carry enough information (cycle identity, EPOCHs) for recipients to validate them.
- Evaluate trace deduplication storage: per-CONNECTION trace history could grow in highly-connected graphs. Consider bounds (cap size, expiry, bloom filters). Empirical evaluation needed against realistic Pony topologies.
- Evaluate TRACE ROUTE trigger policy empirically: on-acquisition (eager) vs. on-block (lazy) vs. batched-on-block. The protocol mechanism is independent of the trigger — this is a performance tuning question.

## Terminology

- Resolve overlap between ORCA terminology and this protocol's terminology. CONNECTION is distinct from ORCA concepts. Other terms may need disambiguation.

## Formal model

- Extend the Alloy model (or build a TLA+ model) to cover the full protocol lifecycle: trace propagation, cycle detection, confirmation, destruction, CONNECTION reset, EPOCH handling, ACTOR IDENTIFIER reuse.
- The model should verify: self-reap safety for non-cyclic actors, confirmation correctness (no live actors collected), epoch-based staleness detection, CONNECTION reset preventing stale state after ID reuse.
- Test the model against a fully connected actor setup.

## Implementation planning

- Design the runtime flag for selecting cycle detection mode (centralized CD, distributed protocol, ponynoblock). All three coexist.
- Identify the per-actor storage needed for the protocol (known cycles, CONNECTION state, trace history, epoch counter, leadership state).
- Plan integration with ORCA: how GC release triggers CONNECTION reset, how rc changes interact with confirmation checks.
