# Implementation planning

What needs to be designed and decided before implementing the distributed cycle detection protocol in ponyc. The protocol specification is in `protocol.md`. The formal model and its verification results are in `model/README.md`.

## Per-actor storage

Each actor needs the following state for the protocol:

**Epoch counter.** A monotonic counter, incremented when the actor loses a CONNECTION (GC release or RELEASE processing). Used in TRACE ROUTE entries so recipients can detect stale traces. The counter saturates at its maximum value — the confirmation protocol catches false candidates that slip through under saturation.

**Known cycles.** A set of member-sets — the cycles this actor has detected locally. Populated by local detection (finding itself in a TRACE ROUTE). Pruned when the actor loses a CONNECTION to a member. Cleared entirely on destruction or ACTOR IDENTIFIER reuse.

**Per-CONNECTION trace history.** For each outgoing CONNECTION, the set of trace chains already forwarded on that connection. Used for deduplication: if the chain has already been sent on this connection, don't send it again. Cleared when the CONNECTION is lost. The storage cost and bounding strategy for this history is an open question — see "Trace deduplication bounds" below.

**No explicit leadership state.** Leadership is computed from the known cycles when needed — the actor that appears in the component's cycles most often (lowest ID tiebreaker). No persistent leadership state is stored. An actor determines locally whether it is the leader of a component and acts accordingly.

**No explicit confirmation response tracking.** The leader does not maintain a response map during confirmation. Instead, it checks whether CONFIRMED or DENIED messages exist for each member. This is how the model works; the implementation may want an explicit response map for efficiency, but correctness does not require one.

## ORCA integration

The distributed protocol hooks into ORCA at three points:

**GC release triggers CONNECTION reset.** When ORCA's GC release drops an actor's rc to 0 for a target, the CONNECTION to that target is reset: trace history cleared, known cycles involving the target pruned, epoch incremented, trace deduplication entries cleared. See "CONNECTION lifecycle" in `protocol.md`.

**RC check during confirmation.** A member responds CONFIRMED to a CONFIRM BLOCKED message when its rc equals its appearance count in the component and its message queue is empty (no messages other than the CONFIRM BLOCKED itself). The rc check is ORCA's rc — the count of foreign references. In the model, this is simulated by checking that no actor outside the component references the member and no in-flight application message carries a reference to the member. The implementation uses ORCA's actual rc value.

**Self-reap criterion.** An actor with rc=0 and an empty message queue can self-reap. This is the same criterion used by orphaned actors and ponynoblock mode. The distributed protocol adds guards: the actor must not be involved in any pending confirmation, and no in-flight confirmation message must reference it in a candidate. These guards prevent destroying an actor while a confirmation exchange about it is in progress.

## Runtime mode selection

Three cycle detection modes coexist, selected by a runtime flag:

- **Centralized CD** (current default): the existing cycle detector actor. Proven, works for stable topologies.
- **Distributed protocol**: actors detect and destroy cycles among themselves. Scales under churn.
- **ponynoblock**: no cycle detection. Zero overhead, programmer guarantees no cycles.

The flag selects which mode initializes at startup. The modes are mutually exclusive — only one runs at a time. The distributed mode replaces the centralized CD's role entirely; it does not layer on top of it.

Design questions:
- What is the flag? A command-line option, an environment variable, or a compile-time flag?
- Does the runtime need to support switching modes, or is the choice fixed at startup?
- What is the default? Centralized CD remains the safe default until the distributed protocol is proven in production.

## Trace deduplication bounds

Per-CONNECTION trace history could grow in highly-connected graphs. Each outgoing CONNECTION stores the set of trace chains already forwarded on it. A trace chain is a sequence of (ACTOR IDENTIFIER, EPOCH) pairs — its length equals the number of hops the trace has taken.

The number of distinct chains passing through a connection depends on the graph topology. In the worst case (dense, many overlapping cycles), the history could grow large enough to matter for memory.

Options to bound it:
- **Cap size**: limit the number of entries per CONNECTION. When the cap is reached, either stop recording (new traces are always forwarded, losing deduplication benefit) or evict oldest entries (stale chains may be re-sent, wasting bandwidth but not breaking correctness).
- **Expiry**: entries older than some threshold are cleared. Same tradeoff as cap eviction.
- **Bloom filters**: probabilistic deduplication. False positives suppress valid traces (liveness impact, not safety). False negatives re-send duplicates (bandwidth cost). Tunable via filter size and hash count.
- **No bound**: let the history grow. May be acceptable if real Pony topologies don't produce enough distinct chains to matter.

This needs empirical evaluation against realistic Pony topologies — the model can't answer it because it operates at scope 2-3 (2-3 actors), far below real workload sizes. The right bound depends on how many distinct chains actually flow through a connection in practice.

Deduplication is an optimization, not a correctness requirement. Removing it entirely doesn't break safety — the confirmation protocol catches false candidates regardless. It does increase trace message volume, which affects performance.

## Trace trigger policy

When should an actor initiate a TRACE ROUTE message? The protocol mechanism is independent of the trigger — this is a performance tuning question. `protocol.md` documents the options:

- **On acquisition** (current protocol choice): initiate a trace when gaining a new CONNECTION. Early topology discovery, higher message traffic during active execution, faster reap once actors block.
- **On block**: initiate traces when the actor blocks (empty queue, rc > 0). Zero protocol overhead during active execution, discovery delayed until idle.
- **Batched on block**: accumulate new CONNECTIONs during active execution, send traces for all of them when the actor blocks.

The choice affects latency (how quickly cycles are detected after forming) and overhead (how many trace messages flow during normal execution). On-acquisition has the lowest detection latency but the highest overhead. On-block has zero overhead during active execution but delays detection until actors go idle — which is exactly when cycles become a problem (blocked actors holding references to each other).

This also needs empirical evaluation. The formal model uses on-acquisition but doesn't model performance — only safety.

## Model findings that constrain implementation

The formal model verified safety across ~38M states at scope 3. Key findings that constrain implementation choices:

- **Local-only epoch checking is sufficient.** The detecting actor checks only its own epoch entry when a trace returns. Intermediate actors' epochs go unchecked because the implementation has no way to read them. More false candidates reach the confirmation protocol than per-hop checking would allow, but the confirmation protocol catches them. Safety is verified under this weaker check.
- **Confirmation must re-verify at RELEASE time.** Between confirmation and destruction, topology can change. SendRelease re-checks all conditions before initiating destruction.
- **Chain-content cleanup prevents liveness gaps.** When clearing trace deduplication entries for a dropped CONNECTION, entries where the actor appears anywhere in a chain's visited sequence (not just as sender or target) must also be cleared. Without this, stale entries can suppress valid traces under epoch saturation.
- **Self-reap guards must check all in-flight references.** Not just messages addressed to the actor — also application message arguments and trace route visited sequences. And the actor must not be referenced in any pending confirmation candidate.

## What this document does not cover

- **Message format and encoding.** How TRACE ROUTE, CONFIRM BLOCKED, CONFIRMED, DENIED, DELEGATE, and RELEASE messages are represented in ponyc's message system. This depends on ponyc runtime internals.
- **Scheduler integration.** How the protocol's actions (trace initiation, confirmation checks) are triggered by the scheduler. This depends on the trigger policy decision and on scheduler internals.
- **Testing strategy.** How to test the implementation against the properties verified by the model.
- **Migration path.** How to transition existing applications from centralized CD to the distributed protocol.
