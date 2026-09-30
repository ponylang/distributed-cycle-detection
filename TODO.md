# TODO

## Protocol design

- Define exactly which state changes trigger an EPOCH increment. Candidates: gaining a CONNECTION, losing a CONNECTION, changes to known cycle set. The formal model should guide this.
- Document the MERGE operation for connected components (when overlapping cycles are discovered, how their member sets and cycle sets are unified).
- Document the RESET operation for CONNECTIONs (what exactly gets cleared, what messages are sent to other cycle members).
- Define how CONFIRM BLOCKED, CONFIRMED, DENIED, DELEGATE, and RELEASE messages carry enough information (cycle identity, EPOCHs) for recipients to validate them. The TLA+ model uses the candidate record (members + detectedBy) as the identity; the real implementation may need a more compact representation.
- Evaluate trace deduplication storage: per-CONNECTION trace history could grow in highly-connected graphs. Consider bounds (cap size, expiry, bloom filters). Empirical evaluation needed against realistic Pony topologies.
- Evaluate TRACE ROUTE trigger policy empirically: on-acquisition (eager) vs. on-block (lazy) vs. batched-on-block. The protocol mechanism is independent of the trigger — this is a performance tuning question.

## Terminology

- Resolve overlap between ORCA terminology and this protocol's terminology. CONNECTION is distinct from ORCA concepts. Other terms may need disambiguation.

## Formal model

- ~~Extend the Alloy model (or build a TLA+ model) to cover the full protocol lifecycle.~~ Done: TLA+ model covers trace propagation, cycle detection, multi-step confirmation, destruction, CONNECTION reset, EPOCH handling, ACTOR IDENTIFIER reuse.
- ~~Model cascading GC release during destruction. Currently DestroyConfirmedCycle removes all members atomically. A more realistic model would mark members for destruction, release references one at a time, and let members self-reap as their rc reaches 0.~~ Done: PR #9. SendRelease, ProcessRelease, and SelfReap replace atomic destruction.
- ~~Model per-hop epoch checking. Traces currently carry a set of actor IDs, not an ordered list of (ACTOR IDENTIFIER, EPOCH) pairs. Adding per-hop epochs would make the model more faithful and potentially fix CandidateSoundness.~~ Done: PR #10. Traces carry per-hop (id, epoch) records.
- ~~Model leadership determination and DELEGATE on DENIED. Currently the leader is fixed (detectedBy). In the protocol, leadership delegates to the first denier.~~ Done: PRs #12 and #13. Leader is lowest ID; DelegateLeadership sends DELEGATE to a denier on confirmation failure.
- ~~Test the model against a fully connected actor setup.~~

## Implementation planning

- Design the runtime flag for selecting cycle detection mode (centralized CD, distributed protocol, ponynoblock). All three coexist.
- Identify the per-actor storage needed for the protocol (known cycles, CONNECTION state, trace history, epoch counter, leadership state).
- Plan integration with ORCA: how GC release triggers CONNECTION reset, how rc changes interact with confirmation checks.
