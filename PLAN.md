# Plan: Distributed Cycle Detection for Pony

## Problem

The centralized cycle detector in ponyc is a single actor that becomes a bottleneck under high actor churn, leading to OOM (ponyc#6181). Every non-orphan actor with rc=0 must send a BLK message to the CD and wait for it to process the reap. With enough scheduler threads creating actors, the CD's message queue grows faster than it can drain.

All short-term fixes were evaluated and eliminated:
- Batching BLK messages: just delays the OOM
- Adaptive CD scheduling: one thread can't outrun N producer threads
- Sharding the CD: spreads the bottleneck, doesn't eliminate it
- Expanding self-reap with atomic coordination: rejected (no atomics constraint)
- Eliminating delta-based view creation: breaks the CD's ability to build topology for cycle detection

The distributed protocol is the only approach that eliminates the bottleneck.

## Design decisions made

These are recorded in protocol.md. Summary:

1. **Message passing only.** No atomics, no locks, no shared mutable state for coordination.

2. **Self-reap for non-cyclic actors works.** With no central CD holding raw pointers via deltas, any actor with rc=0 and an empty queue can self-reap. The criterion is already trusted by the runtime (orphan self-reap and ponynoblock mode use it). This alone fixes the majority of the churn bottleneck.

3. **Per-actor epoch, communicated in messages.** Each actor has a single monotonic epoch counter. Protocol messages carry the sender's epoch. Only meaningful to the owning actor — other actors carry it without interpreting it. When a message returns to the originator, the epoch is checked for staleness. Not per-connection (too much state) and not centralized (would reintroduce the bottleneck or require distributed consensus).

4. **Three runtime modes coexist.** Centralized CD, distributed protocol, and ponynoblock — selected by a flag. Each survives as long as it has a use case. The distributed protocol ships as opt-in.

5. **Trace trigger timing is a policy decision.** On-acquisition (eager), on-block (lazy), or batched-on-block. The mechanism is independent of the trigger. Start with on-acquisition; switch if empirical testing shows problems.

6. **Cycle members cannot self-reap during confirmation.** Their rc is held above 0 by other members' references. The confirmation check (rc equals cycle appearance count) fails if an external actor drops a reference or a member gets new work. No special handling needed for "missing members."

## Current state of the repo

- **protocol.md**: Protocol design covering terminology, self-reap, TRACE ROUTE messages with epochs, cycle detection, leadership, confirmation, destruction, and CONNECTION lifecycle. Some areas still need detail (MERGE, exact RESET semantics, message formats for CONFIRM BLOCKED / RELEASE).

- **TODO.md**: Open design questions, formal modeling needs, implementation planning.

- **TLA+ model** (model/): Covers trace propagation, epoch-based staleness detection, cycle candidate detection, multi-step confirmation (CONFIRM BLOCKED / CONFIRMED / DENIED exchange), destruction with re-verification, self-reap, and ACTOR IDENTIFIER reuse. Safety properties (DestructionSafety, NoOrphanMessages) verified at scope 2 unconstrained and scope 3 state-constrained. See model/README.md for details.

- **Annotated examples** (annotated-example-programs/): Worked examples showing protocol operation on ring topologies.

## What's next: extending the formal model

The TLA+ model verifies safety for the core protocol. Remaining modeling work (see TODO.md):

1. **Cascading GC release.** DestroyConfirmedCycle currently removes all members atomically. A more realistic model would release references one at a time and let members self-reap as their rc reaches 0.

2. **Per-hop epoch checking.** Traces carry a set of actor IDs, not an ordered list of (ACTOR IDENTIFIER, EPOCH) pairs. Adding per-hop epochs would make the model more faithful and potentially fix CandidateSoundness.

3. **Leadership determination and delegation.** The model uses a fixed leader (detectedBy). The protocol delegates leadership to the first denier on DENIED.

## Key source code references (ponyc)

For understanding the current centralized CD and how the runtime manages actors:

- Actor self-reap path: `src/libponyrt/actor/actor.c` lines 644-688 (`RC_OVER_ZERO_SEEN` guard at line 656)
- CD fast-reap: `src/libponyrt/gc/cycle.c` lines 1103-1167 (`block()` with rc=0)
- CD delta-based view creation: `src/libponyrt/gc/cycle.c` line 445 (`get_view` with `create=rc>0`)
- CD scheduling: `src/libponyrt/gc/cycle.c` lines 1510-1523 (time-gated via `detect_interval`)
- CD message processing: `src/libponyrt/actor/actor.c` lines 549,609 (head-limited, not full drain)
- ORCA reference counting: `src/libponyrt/gc/gc.c`
