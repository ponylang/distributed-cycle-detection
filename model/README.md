# Formal model

TLA+ specification of the distributed cycle detection protocol. Uses TLC for exhaustive state space exploration.

## What the model covers

- TRACE ROUTE propagation and forwarding
- Epoch-based staleness detection
- Cycle candidate detection
- Confirmation (atomic topology and RC check)
- Cycle destruction
- Self-reap (rc=0 actors)
- ACTOR IDENTIFIER reuse after destruction

## Verified properties

**DestructionSafety**: no alive actor holds a reference to a destroyed actor. Holds at scope 2 (unconstrained, 123K states) and scope 3 (state-constrained, 13.1M states).

**NoOrphanMessages**: no in-flight message is addressed to a destroyed actor. Holds at same scopes.

**CandidateSoundness**: every cycle candidate is a real cycle. Fails as expected — an intermediate actor can drop a reference after forwarding a trace. The confirmation protocol catches these false candidates.

## Findings

1. Originator-only epoch checking is insufficient for candidate soundness. Confirmation is required.
2. SelfReap must check all in-flight message references, not just messages addressed to the actor.
3. Destruction must re-verify all confirmation conditions. An in-flight message from before confirmation can deliver a reference to a cycle member.
4. Confirmation is robust to ACTOR IDENTIFIER reuse. Stale candidates from a previous incarnation either fail the topology/RC checks or describe a cycle that the new incarnation genuinely forms.

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
| `DistribCycleDetector.cfg` | 3 actors, 3 messages, MaxEpoch=1 | DestructionSafety, NoOrphanMessages | Yes | Main safety check (~2.5 min) |
| `Scope2Safety.cfg` | 2 actors, 3 messages, MaxEpoch=2 | DestructionSafety, NoOrphanMessages | No | Unconstrained safety check (~2s) |
| `CandidateSoundness.cfg` | 2 actors, 3 messages, MaxEpoch=2 | CandidateSoundness | No | Reproduce false-candidate counterexample (<1s) |

## Modeling simplifications

**Atomic confirmation.** Confirmation is a single topology check, not individual CONFIRM BLOCKED / CONFIRMED / DENIED messages. This captures the safety property without modeling the message exchange.

**Visited set, not ordered entries.** Traces carry a set of actor IDs instead of an ordered list of (ACTOR IDENTIFIER, EPOCH) pairs. Per-hop epoch checking is not modeled; only the originator's epoch is checked on return. This is the source of the CandidateSoundness violation.

**Fixed-depth reachability.** `ReachableThroughSet` uses a 3-step BFS instead of recursive transitive closure. Correct for MaxActors ≤ 3.

**State constraint at scope 3.** Bounds the sum of actors + messages + candidates + confirmed + destroyed to MaxActors + MaxMessages. This prunes states where all 3 messages coexist with protocol artifacts. Confirmation and destruction require empty queues, so the constraint does not affect those paths much.

**Epoch saturation.** At MaxEpoch, further reference drops do not increment the epoch. A stale trace from after saturation carries the current epoch and is accepted. The confirmation protocol catches the resulting false candidates.

**No leadership or deduplication.** Leadership determination, DELEGATE messages, and CONNECTION-level trace deduplication are not modeled. These are liveness and efficiency features, not safety features.
