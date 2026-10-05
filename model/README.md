# Formal model

TLA+ specification of the distributed cycle detection protocol. Uses TLC for exhaustive state space exploration.

## What the model covers

- TRACE ROUTE propagation and forwarding with local-only epoch checking
- CONNECTION-level trace deduplication (suppresses duplicate chains per connection)
- Epoch-based staleness detection (detecting actor's own epoch only)
- Cycle candidate detection (pattern-1 originator detection and pattern-2 sub-cycle extraction)
- Per-actor cycle knowledge (local detection only)
- Component-level confirmation (CONFIRM BLOCKED / CONFIRMED / DENIED exchange)
- Leadership delegation via DELEGATE on confirmation failure
- Cascading GC release (RELEASE messages, per-member reference drop, self-reap)
- Self-reap (rc=0 actors)
- ACTOR IDENTIFIER reuse after destruction

## Verified properties

**DestructionSafety**: no alive actor holds a reference to a destroyed actor. Holds at scope 2 (unconstrained, 14.5M states) and scope 3 (state-constrained, 38.0M states, ~13 min). Also holds under fully connected initial topology at scope 2 (14.5M states) and scope 3 (37.5M states, ~15 min), and under overlapping cycles initial topology at scope 3 (37.5M states, ~15 min).

**NoOrphanMessages**: no in-flight message is addressed to a destroyed actor. Holds at same scopes, including fully connected and overlapping cycles initial topologies.

**LeadershipValidity**: the leader of every cycle candidate is a member of that candidate. Holds at all scopes, including fully connected and overlapping cycles initial topologies.

**CandidateSoundness**: every cycle candidate is a real cycle. Fails as expected — an actor can drop a reference after the candidate is recorded. Local-only epoch checking catches traces that are stale from the detecting actor's perspective but cannot check intermediate actors' epochs, so more false candidates reach the pipeline than per-hop checking would allow. The confirmation protocol catches these false candidates.

## Findings

1. Local-only epoch checking (detecting actor checks only its own epoch entry) is safe. The implementation cannot check intermediate actors' epochs — it only knows its own. The model now matches this: detection checks only the detecting actor's epoch, not every hop. More false candidates reach the confirmation pipeline than per-hop checking would allow (intermediate topology changes go undetected), but the confirmation protocol catches them. CandidateSoundness still fails because topology can change after the candidate is recorded — this is inherent to any detection/confirmation split. Confirmation is required.
2. SelfReap must check all in-flight message references, not just messages addressed to the actor.
3. Destruction must re-verify all confirmation conditions. An in-flight message from before confirmation can deliver a reference to a cycle member.
4. Confirmation is robust to ACTOR IDENTIFIER reuse. Stale candidates from a previous incarnation either fail the topology/RC checks or describe a cycle that the new incarnation genuinely forms.
5. Multi-step confirmation is safe under all interleavings. Between CONFIRM BLOCKED and a member's response, topology changes (new messages, reference drops, AppMessage deliveries) can occur. Members detect these via local checks and send DENIED. SendRelease re-verifies all conditions before initiating destruction.
6. Pattern-2 sub-cycle detection is safe. When a non-originator actor finds itself in a trace's visited sequence, extracting the sub-cycle and recording it as a candidate feeds into the same confirmation and destruction pipeline as pattern-1 detection. DestructionSafety and NoOrphanMessages hold with the expanded candidate set. CandidateSoundness still fails for the same reason — post-detection topology changes.
7. Cascading GC release is safe under all interleavings. The leader sends RELEASE to each member; each member drops references to other members and increments its epoch. Members whose rc reaches 0 self-reap via existing SelfReap guards. Partial release sequences — where some members have processed RELEASE but others haven't — cannot produce dangling references because SelfReap requires no alive actor to reference the actor, which blocks self-reap until all members who reference it have dropped their references.
8. Leadership delegation on confirmation failure is safe. When the leader delegates to a denier via a DELEGATE message, the existing SelfReap guards prevent the denier from being destroyed while the DELEGATE is in flight — SelfReap requires that no message is addressed to the actor and that no confirmation protocol message references the actor in a candidate. The delegated candidate re-enters the confirmation pipeline through SendConfirmBlocked, where the same topology and RC checks apply. The model explores both delegation and abandonment on denial; safety holds under either strategy.
9. Leadership determination by lowest actor identifier is safe and reduces the state space. When the detecting actor was always the leader, the same cycle detected by different members produced different candidates (different `detectedBy`). With deterministic leader selection, they produce the same candidate, so the existing set-union deduplicates them without additional mechanism.
10. Safety holds under fully connected initial topologies. When all actors start alive and each references every other, cycles exist from the first state. DestructionSafety, NoOrphanMessages, and LeadershipValidity all hold. The fully connected topology produces slightly fewer distinct states than the standard init at scope 3 because SpawnActor is disabled when all IDs are in use. The protocol's safety does not depend on how topology forms — confirmation re-verifies all conditions regardless of initial state.
11. CONNECTION-level trace deduplication is safe. Suppressing duplicate trace chains per connection does not break DestructionSafety or NoOrphanMessages. The `sentTraces` state tracks which `[from, to, chain]` tuples have been sent; ForwardTrace and InitiateTrace check and record entries; SuppressDuplicateTrace consumes traces when all outgoing connections have already seen the chain. CONNECTION reset (ReduceMem, ProcessRelease) clears deduplication entries for dropped connections and any chain mentioning the actor, preventing stale history from suppressing traces after topology changes. SelfReap and ReuseActorId clear all entries mentioning the destroyed/reused actor — as sender, target, or anywhere in a chain's visited sequence.
12. Clearing deduplication entries that mention an actor inside chain contents closes a liveness gap. Without chain-content cleanup, a stale entry `[from=A, to=B, chain=<<..., [id=X, epoch=0], ...>>]` can survive topology changes when X appears only inside the chain, not as sender or target. If X re-forms the same topology with the same epoch, the stale entry suppresses a valid trace — a liveness gap, not a safety violation. This matters under epoch saturation (epoch at MaxEpoch): dropping and re-acquiring a reference doesn't increment the epoch, so the stale and new chains are structurally identical. All four cleanup sites now scan chain contents: SelfReap and ReuseActorId (actor destruction/reuse), ReduceMem (reference drop), and ProcessRelease (cycle member release).
13. Per-actor cycle knowledge with component-level confirmation is safe. Each actor maintains its own set of known cycles (populated by local detection). Overlapping cycles cannot be confirmed individually — shared members' reference counts reflect all overlapping cycles, so the rc check fails. Actors clean up stale cycle knowledge when references change (ReduceMem, ProcessRelease) or actors are destroyed (SelfReap, ReuseActorId). The overlapping cycles initial topology (`OverlappingCycles.cfg`) exercises overlapping cycles: actors 1–2–3 form two cycles ({1,2} and {2,3}). A mechanism for converging on overlapping cycle confirmation is an open design question.

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
| `DistribCycleDetector.cfg` | 3 actors, 3 messages, MaxEpoch=1 | DestructionSafety, NoOrphanMessages, LeadershipValidity | Yes | Main safety check (~13 min) |
| `Scope2Safety.cfg` | 2 actors, 3 messages, MaxEpoch=2 | DestructionSafety, NoOrphanMessages, LeadershipValidity | No | Unconstrained safety check (~3 min) |
| `CandidateSoundness.cfg` | 2 actors, 3 messages, MaxEpoch=2 | CandidateSoundness | No | Reproduce false-candidate counterexample (<1s) |
| `FullyConnectedScope2.cfg` | 2 actors, 3 messages, MaxEpoch=2 | DestructionSafety, NoOrphanMessages, LeadershipValidity | No | Fully connected init, unconstrained (~4 min) |
| `FullyConnectedScope3.cfg` | 3 actors, 3 messages, MaxEpoch=1 | DestructionSafety, NoOrphanMessages, LeadershipValidity | Yes | Fully connected init, state-constrained (~15 min) |
| `OverlappingCycles.cfg` | 3 actors, 3 messages, MaxEpoch=1 | DestructionSafety, NoOrphanMessages, LeadershipValidity | Yes | Overlapping cycles init, state-constrained (~15 min) |

## Modeling simplifications

**Fixed-depth reachability.** `ReachableThroughSet` uses a 3-step BFS instead of recursive transitive closure. Correct for MaxActors ≤ 3.

**State constraint at scope 3.** Bounds the sum of actors + messages + candidates + confirmed + destroyed + pendingConfirmation + sentTraces + knownCycles to MaxActors + MaxMessages (= 6 at scope 3). Multi-step confirmation for a 3-member cycle is unreachable under this constraint: SendConfirmBlocked sends 3 messages and adds 1 pendingConfirmation, producing a state sum of at least 7. Similarly, SendRelease for a 3-member cycle sends 3 RELEASE messages, which also requires sum headroom. Only 2-member cycles can enter multi-step confirmation and cascading release at scope 3 (sum = 6, at the bound). The overlapping cycles config uses the same constraint, so overlapping cycles are exercised but 3-member components cannot reach full confirmation. Scope 2 unconstrained has no such limitation and exercises the full protocol for 2-member cycles.

**No explicit RC counter.** The model has no ORCA runtime maintaining reference counts. Instead, member confirmation checks simulate ORCA's rc accounting by explicitly checking inMem (no external references) and in-flight AppMsg args (no references in transit). This is more conservative than the real protocol's single rc comparison but covers the same ground.

**Epoch saturation.** At MaxEpoch, further reference drops do not increment the epoch. A stale trace from after saturation carries the current epoch and is accepted. The confirmation protocol catches the resulting false candidates. The chain-content cleanup in ReduceMem, ProcessRelease, SelfReap, and ReuseActorId mitigates the deduplication liveness gap: stale sentTraces entries mentioning an actor whose topology changed are cleared regardless of whether the epoch incremented.

**Implicit response tracking.** The leader does not maintain an explicit response map. Instead, `ConfirmationSucceeded`, `ConfirmationFailed`, and `DelegateLeadership` check for the existence of CONFIRMED / DENIED messages in the message set. This is equivalent but avoids adding a function-valued field to `pendingConfirmation` records, which would increase the state space.

**Leader waits for all responses before acting on denial.** `ConfirmationFailed` and `DelegateLeadership` require every member to have responded (CONFIRMED or DENIED) before the leader acts. The real protocol could act on the first DENIED. Waiting longer is conservative — more time for topology changes makes confirmation harder, not easier.

**Implicit destruction tracking.** The model has no `pendingDestruction` variable. When SendRelease sends RELEASE messages and removes the confirmed cycle from `confirmedCycles`, the pending RELEASE messages in the message set are the only record that destruction is in progress. SelfReap's existing guards — no alive actor references the actor, no messages addressed to it — prevent member self-reap until all references are dropped. This avoids adding a state variable dimension.

**Global knowledge guard on forget.** `ForgetInvalidCycle` uses a global check to verify that a cycle an actor knows about is no longer valid (a member's topology changed). The real protocol discovers this during confirmation (DENIED responses) or local topology changes. The model's guard lets actors drop stale knowledge eagerly, which is conservative — forgetting a cycle that would fail confirmation anyway does not weaken safety, and eagerly pruning stale knowledge reduces the state space.

**Note:** The TLA+ model still contains `SendInformCycles` (gossip) and `ComponentMembers` (transitive overlap expansion) from an earlier protocol version. These are no longer part of the protocol. The model needs to be updated to match: remove `SendInformCycles` and proactive component merging. Until then, the model over-approximates the protocol (actors learn about cycles faster than the real protocol allows), which is conservative for safety verification.
