# Formal model

TLA+ specification of the distributed cycle detection protocol. Uses TLC for exhaustive state space exploration.

## What the model covers

- TRACE ROUTE propagation and forwarding
- Epoch-based staleness detection
- Cycle candidate detection
- Multi-step confirmation (CONFIRM BLOCKED / CONFIRMED / DENIED exchange)
- Cycle destruction
- Self-reap (rc=0 actors)
- ACTOR IDENTIFIER reuse after destruction

## Verified properties

**DestructionSafety**: no alive actor holds a reference to a destroyed actor. Holds at scope 2 (unconstrained, 187K states) and scope 3 (state-constrained, 10.8M states).

**NoOrphanMessages**: no in-flight message is addressed to a destroyed actor. Holds at same scopes.

**CandidateSoundness**: every cycle candidate is a real cycle. Fails as expected — an intermediate actor can drop a reference after forwarding a trace. The confirmation protocol catches these false candidates.

## Findings

1. Originator-only epoch checking is insufficient for candidate soundness. Confirmation is required.
2. SelfReap must check all in-flight message references, not just messages addressed to the actor.
3. Destruction must re-verify all confirmation conditions. An in-flight message from before confirmation can deliver a reference to a cycle member.
4. Confirmation is robust to ACTOR IDENTIFIER reuse. Stale candidates from a previous incarnation either fail the topology/RC checks or describe a cycle that the new incarnation genuinely forms.
5. Multi-step confirmation is safe under all interleavings. Between CONFIRM BLOCKED and a member's response, topology changes (new messages, reference drops, AppMessage deliveries) can occur. Members detect these via local checks and send DENIED. DestroyConfirmedCycle re-verifies all conditions before destruction.

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
| `Scope2Safety.cfg` | 2 actors, 3 messages, MaxEpoch=2 | DestructionSafety, NoOrphanMessages | No | Unconstrained safety check (~8s) |
| `CandidateSoundness.cfg` | 2 actors, 3 messages, MaxEpoch=2 | CandidateSoundness | No | Reproduce false-candidate counterexample (<1s) |

## Modeling simplifications

**Visited set, not ordered entries.** Traces carry a set of actor IDs instead of an ordered list of (ACTOR IDENTIFIER, EPOCH) pairs. Per-hop epoch checking is not modeled; only the originator's epoch is checked on return. This is the source of the CandidateSoundness violation.

**Fixed-depth reachability.** `ReachableThroughSet` uses a 3-step BFS instead of recursive transitive closure. Correct for MaxActors ≤ 3.

**State constraint at scope 3.** Bounds the sum of actors + messages + candidates + confirmed + destroyed + pendingConfirmation to MaxActors + MaxMessages (= 6 at scope 3). Multi-step confirmation for a 3-member cycle is unreachable under this constraint: SendConfirmBlocked sends 3 messages and adds 1 pendingConfirmation, producing a state sum of at least 7. Only 2-member cycles can enter multi-step confirmation at scope 3 (sum = 6, at the bound). Scope 2 unconstrained has no such limitation and exercises the full confirmation protocol for 2-member cycles.

**No explicit RC counter.** The model has no ORCA runtime maintaining reference counts. Instead, member confirmation checks simulate ORCA's rc accounting by explicitly checking inMem (no external references) and in-flight AppMsg args (no references in transit). This is more conservative than the real protocol's single rc comparison but covers the same ground.

**Epoch saturation.** At MaxEpoch, further reference drops do not increment the epoch. A stale trace from after saturation carries the current epoch and is accepted. The confirmation protocol catches the resulting false candidates.

**Implicit response tracking.** The leader does not maintain an explicit response map. Instead, `ConfirmationSucceeded` and `ConfirmationFailed` check for the existence of CONFIRMED / DENIED messages in the message set. This is equivalent but avoids adding a function-valued field to `pendingConfirmation` records, which would increase the state space.

**Leader waits for all responses before acting on denial.** `ConfirmationFailed` requires every member to have responded (CONFIRMED or DENIED) before the leader abandons the candidate. The real protocol could act on the first DENIED. Waiting longer before abandoning is conservative — more time for topology changes makes confirmation harder, not easier.

**No leadership or deduplication.** Leadership determination, DELEGATE messages, and CONNECTION-level trace deduplication are not modeled. These are liveness and efficiency features, not safety features.
