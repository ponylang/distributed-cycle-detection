# Formal model

TLA+ specification of the distributed cycle detection protocol. Uses TLC for exhaustive state space exploration.

## What the model covers

- TRACE ROUTE propagation and forwarding with per-hop epoch checking
- Epoch-based staleness detection (per-hop, not originator-only)
- Cycle candidate detection (pattern-1 originator detection and pattern-2 sub-cycle extraction)
- Multi-step confirmation (CONFIRM BLOCKED / CONFIRMED / DENIED exchange)
- Cascading GC release (RELEASE messages, per-member reference drop, self-reap)
- Self-reap (rc=0 actors)
- ACTOR IDENTIFIER reuse after destruction

## Verified properties

**DestructionSafety**: no alive actor holds a reference to a destroyed actor. Holds at scope 2 (unconstrained, 431K states) and scope 3 (state-constrained, 44.8M states, ~12 min).

**NoOrphanMessages**: no in-flight message is addressed to a destroyed actor. Holds at same scopes.

**CandidateSoundness**: every cycle candidate is a real cycle. Fails as expected — an actor can drop a reference after the candidate is recorded. Per-hop epoch checking prevents stale traces from producing candidates, but cannot prevent post-detection topology changes. The confirmation protocol catches these false candidates.

## Findings

1. Per-hop epoch checking eliminates false candidates from stale in-flight traces (where an intermediate actor's topology changed while the trace was in transit). CandidateSoundness still fails because topology can change after the candidate is recorded — this is inherent to any detection/confirmation split. Confirmation is required.
2. SelfReap must check all in-flight message references, not just messages addressed to the actor.
3. Destruction must re-verify all confirmation conditions. An in-flight message from before confirmation can deliver a reference to a cycle member.
4. Confirmation is robust to ACTOR IDENTIFIER reuse. Stale candidates from a previous incarnation either fail the topology/RC checks or describe a cycle that the new incarnation genuinely forms.
5. Multi-step confirmation is safe under all interleavings. Between CONFIRM BLOCKED and a member's response, topology changes (new messages, reference drops, AppMessage deliveries) can occur. Members detect these via local checks and send DENIED. SendRelease re-verifies all conditions before initiating destruction.
6. Pattern-2 sub-cycle detection is safe. When a non-originator actor finds itself in a trace's visited sequence, extracting the sub-cycle and recording it as a candidate feeds into the same confirmation and destruction pipeline as pattern-1 detection. DestructionSafety and NoOrphanMessages hold with the expanded candidate set. CandidateSoundness still fails for the same reason — post-detection topology changes.
7. Cascading GC release is safe under all interleavings. The leader sends RELEASE to each member; each member drops references to other members and increments its epoch. Members whose rc reaches 0 self-reap via existing SelfReap guards. Partial release sequences — where some members have processed RELEASE but others haven't — cannot produce dangling references because SelfReap requires no alive actor to reference the actor, which blocks self-reap until all members who reference it have dropped their references.

## Running

Build the Docker image once:

```
docker build -t tlc-runner -f model/tools/Dockerfile.tlc model/tools/
```

Download `tla2tools.jar` (gitignored) into `model/tools/`:

```
curl -L -o model/tools/tla2tools.jar \
  https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar
```

Run a check:

```
docker run --rm -v $(pwd)/model:/model -w /model \
  tlc-runner -deadlock -workers 4 -config <cfg> DistribCycleDetector
```

## Config files

| File | Scope | Invariants | Constraint | Purpose |
|------|-------|------------|------------|---------|
| `DistribCycleDetector.cfg` | 3 actors, 3 messages, MaxEpoch=1 | DestructionSafety, NoOrphanMessages | Yes | Main safety check (~12 min) |
| `Scope2Safety.cfg` | 2 actors, 3 messages, MaxEpoch=2 | DestructionSafety, NoOrphanMessages | No | Unconstrained safety check (~10s) |
| `CandidateSoundness.cfg` | 2 actors, 3 messages, MaxEpoch=2 | CandidateSoundness | No | Reproduce false-candidate counterexample (<1s) |

## Modeling simplifications

**Fixed-depth reachability.** `ReachableThroughSet` uses a 3-step BFS instead of recursive transitive closure. Correct for MaxActors ≤ 3.

**State constraint at scope 3.** Bounds the sum of actors + messages + candidates + confirmed + destroyed + pendingConfirmation to MaxActors + MaxMessages (= 6 at scope 3). Multi-step confirmation for a 3-member cycle is unreachable under this constraint: SendConfirmBlocked sends 3 messages and adds 1 pendingConfirmation, producing a state sum of at least 7. Similarly, SendRelease for a 3-member cycle sends 3 RELEASE messages, which also requires sum headroom. Only 2-member cycles can enter multi-step confirmation and cascading release at scope 3 (sum = 6, at the bound). Scope 2 unconstrained has no such limitation and exercises the full protocol for 2-member cycles.

**No explicit RC counter.** The model has no ORCA runtime maintaining reference counts. Instead, member confirmation checks simulate ORCA's rc accounting by explicitly checking inMem (no external references) and in-flight AppMsg args (no references in transit). This is more conservative than the real protocol's single rc comparison but covers the same ground.

**Epoch saturation.** At MaxEpoch, further reference drops do not increment the epoch. A stale trace from after saturation carries the current epoch and is accepted. The confirmation protocol catches the resulting false candidates.

**Implicit response tracking.** The leader does not maintain an explicit response map. Instead, `ConfirmationSucceeded` and `ConfirmationFailed` check for the existence of CONFIRMED / DENIED messages in the message set. This is equivalent but avoids adding a function-valued field to `pendingConfirmation` records, which would increase the state space.

**Leader waits for all responses before acting on denial.** `ConfirmationFailed` requires every member to have responded (CONFIRMED or DENIED) before the leader abandons the candidate. The real protocol could act on the first DENIED. Waiting longer before abandoning is conservative — more time for topology changes makes confirmation harder, not easier.

**Implicit destruction tracking.** The model has no `pendingDestruction` variable. When SendRelease sends RELEASE messages and removes the confirmed cycle from `confirmedCycles`, the pending RELEASE messages in the message set are the only record that destruction is in progress. SelfReap's existing guards — no alive actor references the actor, no messages addressed to it — prevent member self-reap until all references are dropped. This avoids adding a state variable dimension.

**No leadership or deduplication.** Leadership determination, DELEGATE messages, and CONNECTION-level trace deduplication are not modeled. These are liveness and efficiency features, not safety features.
