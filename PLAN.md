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

- **Alloy model** (model/): Covers basic actor/message/connection structure and state changes (spawn, reduce memory, send/receive app messages). Does NOT yet model the distributed cycle detection protocol — no TRACE ROUTE handling, no cycle detection logic, no confirmation, no destruction, no epochs, no CONNECTION reset.

- **Annotated examples** (annotated-example-programs/): Worked examples showing protocol operation on ring topologies.

## What's next: formal model

The protocol has enough shape to start formal modeling. The model should verify safety properties that hand reasoning can't reliably cover.

### What to model

In priority order:

1. **TRACE ROUTE propagation and cycle detection.** Actors send and forward traces. Cycles are detected when an actor sees its own ID. Verify: every actual cycle is eventually detected (completeness). No false cycles are detected for non-cyclic topologies (soundness).

2. **Epoch-based staleness detection.** Actors increment epochs on state changes. Protocol messages carry epochs. Stale messages are discarded. Verify: no stale trace leads to collecting a live actor. Identify which state changes must trigger an epoch increment.

3. **Confirmation and destruction.** Leader sends CONFIRM BLOCKED, members respond. Confirmed cycles are destroyed via RELEASE and GC release. Verify: only truly dead cycles are confirmed. Members can't self-reap during confirmation. Destruction cascades correctly (rc drops, further self-reaps).

4. **CONNECTION reset and ACTOR IDENTIFIER reuse.** When an actor GC releases another to rc 0, the CONNECTION is reset. An address can be reused by a new actor. Verify: stale protocol state doesn't cause incorrect behavior after ID reuse. In-flight protocol messages to freed addresses are handled safely (by epoch or by confirmation failure).

5. **Self-reap safety.** Actors with rc=0 and empty queues self-reap without any central coordination. Verify: no entity holds a dangling pointer after self-reap. Cascading self-reap terminates.

### What the existing model provides

The Alloy model already has:
- Actor sig with id, active/destroyed status, inMem (memory references), inMap (actor map)
- Message FIFO queues (AppMessage with inArgs)
- Connection sig (from, to)
- Trace and TraceElement sigs (linked list structure)
- State changes: spawn, reduce memory, send/receive app messages
- Temporal logic framework (always/eventually)

This provides the actor and message infrastructure. The protocol logic (trace handling, cycle detection, confirmation, destruction, epoch, CONNECTION reset) needs to be built on top.

### Modeling tool

The existing model uses Alloy 6 (temporal logic). The model should continue in Alloy unless a specific safety property is better suited to TLA+. The choice between tools is a judgment call when starting the modeling work — if the protocol's concurrency properties (message ordering, interleaving of actor actions) are hard to express in Alloy's temporal logic, TLA+ may be more natural.

## Key source code references (ponyc)

For understanding the current centralized CD and how the runtime manages actors:

- Actor self-reap path: `src/libponyrt/actor/actor.c` lines 644-688 (`RC_OVER_ZERO_SEEN` guard at line 656)
- CD fast-reap: `src/libponyrt/gc/cycle.c` lines 1103-1167 (`block()` with rc=0)
- CD delta-based view creation: `src/libponyrt/gc/cycle.c` line 445 (`get_view` with `create=rc>0`)
- CD scheduling: `src/libponyrt/gc/cycle.c` lines 1510-1523 (time-gated via `detect_interval`)
- CD message processing: `src/libponyrt/actor/actor.c` lines 549,609 (head-limited, not full drain)
- ORCA reference counting: `src/libponyrt/gc/gc.c`
