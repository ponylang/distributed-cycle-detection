# Distributed cycle detection protocol

## Motivation

The current centralized cycle detector is a single actor that becomes a bottleneck under high actor churn. Actors are created faster than the CD can reap them, leading to OOM (ponyc#6181). The CD's message queue grows without bound because every non-orphan actor with rc=0 must send a BLK message to it.

Short-term fixes (batching, adaptive scheduling, sharding) don't solve the problem — they delay it. The only fix is eliminating the central bottleneck: actors detect cycles among themselves and coordinate their own destruction via message passing.

## Design constraints

- All coordination via message passing. No atomics, no locks, no shared mutable state.
- The distributed protocol is one of three coexisting runtime options (selected by flag):
  - Centralized CD (current default): proven, works for stable topologies
  - Distributed protocol: scales under churn
  - No cycle detection (ponynoblock): zero overhead, programmer guarantees no cycles
- Each option survives as long as it has a use case.

## Terminology

### ACTOR IDENTIFIER

An ACTOR IDENTIFIER denotes a given instance of an actor. Actor identifiers are expected to be a combination of a "semi-unique identifier" for a given actor such as a guid or the memory address the actor occupies.

ACTOR IDENTIFIERS are not guaranteed to be unique across the lifetime of an application but we do guarantee that two actors that exist at the same time will not share an identifier.

ACTOR IDENTIFIERS need to be sortable such that one can say "this identifier is less than this other one".

### CONNECTION

A CONNECTION represents one actor's knowledge of and relationship with another actor. A CONNECTION is directional: from the actor that holds the reference to the actor being referenced.

Each CONNECTION is identified by the target ACTOR IDENTIFIER. A CONNECTION carries state used by the protocol: the trace history (which TRACE ROUTE messages have been forwarded on this connection) and participation in known cycles. See CONNECTION lifecycle for the full reset mechanics.

### EPOCH

Each actor maintains a single monotonic EPOCH counter. The EPOCH is included in protocol messages sent by the actor. The EPOCH is only meaningful to the actor that owns it — other actors carry it but do not interpret it.

When a protocol message returns to the actor that originated it, the actor checks if the EPOCH in the message matches its current EPOCH. If the EPOCHs do not match, the message reflects stale state and is discarded.

The EPOCH increments when the actor loses a CONNECTION — either by GC releasing a reference (dropping a CONNECTION directly) or by processing a RELEASE message during cycle destruction (dropping CONNECTIONs to other cycle members). Losing a CONNECTION invalidates any in-flight TRACE ROUTE message that passed through the actor before the drop, because the trace reflects a topology that no longer exists. Gaining a CONNECTION does not increment the EPOCH — a new connection cannot invalidate an existing trace.

### TRACE ROUTE message

A special runtime message used to find cycles amongst actor relationships.

Cycles are found by sending TRACE ROUTE messages from actor to actor and using the results to find routes that circle back on themselves. Found cycles can be used to find larger connected components that share some members between different cycles. A connected component is composed of 1 or more cycles.

The same cycle can be found from multiple different starting points. For example, "A to B to C to A" is the same cycle as "C to A to B to C".

TRACE ROUTE messages are an ordered list of entries, where each entry is an (ACTOR IDENTIFIER, EPOCH) pair.

For example, if actor A (at epoch 5) initiates a trace to actor B then the TRACE ROUTE message is in the form of ((A,5)) where "A" is the ACTOR IDENTIFIER and "5" is A's current EPOCH.

### Initiate a trace

The act of creating a new TRACE ROUTE message and sending it to another actor.

### Outgoing reference / outgoing connection

A reference from one actor to another where the first actor is able to send messages to the other.

### Passing along a TRACE ROUTE message

The act of an actor taking a received TRACE ROUTE message, augmenting it with the actor's own (ACTOR IDENTIFIER, EPOCH) entry, and sending to an actor that is an outgoing CONNECTION.

## Self-reap of non-cyclic actors

In the distributed model, there is no central cycle detector actor holding raw pointers to actors via deltas. An actor with rc=0 and an empty message queue can self-reap — the same criterion already used by orphaned actors and ponynoblock mode.

ORCA guarantees that rc=0 means no foreign references and no in-flight messages carrying a reference to this actor. No other entity in the distributed model holds a raw pointer to the actor. Self-reap is safe.

When a self-reaping actor runs sendrelease, actors it referenced may see their rc drop to 0 and also self-reap. This cascading effect handles trees, DAGs, and isolated actors — everything except actual cycles.

This alone addresses the primary bottleneck in ponyc#6181: short-lived actors whose rc was ever above 0 no longer need to go through any central actor to be reaped.

## Protocol stages

There are several stages to finding and reaping strongly connected actor components.

### Finding cycles

When an actor receives a new actor reference for an actor it doesn't already have a CONNECTION to, it initiates a new TRACE ROUTE message to the newly received actor.

Note: the trigger for trace initiation (on reference acquisition vs. on block vs. batched on block) is a design choice that should be evaluated empirically. The current design uses on-acquisition (eager discovery), but the protocol mechanism is independent of the trigger policy:

- **On acquisition** (current choice): early topology discovery, higher message traffic during active execution, faster reap once actors block
- **On block**: zero protocol overhead during active execution, discovery delayed until idle
- **Batched on block**: accumulate new references during active execution, send traces only when blocking

Upon receipt of a TRACE ROUTE message, an actor follows the TRACE ROUTE message handling steps.

### TRACE ROUTE message handling

Upon receipt of a TRACE ROUTE message, the following algorithm is applied:

If the receiving actor has no outgoing CONNECTIONs, nothing is done. An actor with no outgoing CONNECTIONs can be referenced by a cycle but cannot be part of a cycle itself.

If the receiving actor has outgoing CONNECTIONs, then:

The receiving actor examines the TRACE ROUTE message to see if its own ACTOR IDENTIFIER is in the ordered list. If the actor doesn't find its own identifier, then it passes along the message as follows:

The message is augmented by adding the receiving actor's (ACTOR IDENTIFIER, EPOCH) entry to the end of the list. If the resulting trace message chain has already been sent from the receiving actor to the actor on the other end of the outgoing CONNECTION, the receiving actor does not send the message. If it hasn't been sent, the receiving actor sends the TRACE ROUTE message to its outgoing CONNECTION and records in the CONNECTION state that it has sent this trace chain.

If the receiving actor finds its own ACTOR IDENTIFIER in the TRACE ROUTE message, then a cycle has been found. The actor first checks the EPOCH in the entry: if the EPOCH does not match the actor's current EPOCH, the trace is stale and is discarded. If the EPOCH matches, the cycle is real.

There are two patterns for cycle discovery:

1. The actor is the first ACTOR IDENTIFIER in the list — it originated the trace. The full route is the cycle.
2. The actor appears later in the list — an actor outside the cycle originated the trace. The cycle is the subset of the route from the actor's entry to the end. For example, if actor A receives a message with (E,A,B) then the cycle is (A,B).

Cycles are independent of route order. Cycle (A,B) is the same as cycle (B,A). Member equivalence is what matters, not order. Route order matters for deduplication (whether to send) but not for cycle identity.

Upon finding a cycle, the actor checks its set of known cycles to see if the newly found cycle is the same as or a subset of any known cycle. If the cycle is known then no further processing happens.

When an actor finds a new cycle, it adds it to its set of known cycles.

### Per-actor cycle knowledge

Each actor maintains its own set of known cycles. This set is populated by local detection (finding a cycle in a received TRACE ROUTE message).

An actor removes a cycle from its known cycle set when it loses a CONNECTION to a member of that cycle (see CONNECTION lifecycle).

## Leadership determination

- Leadership for a connected component is initially determined locally
- Each time a connected component has a state change, leadership is redetermined locally
- Locally the only determination is "I am the leader" or "I am not the leader"
- A leader can delegate leadership to a different member of the connected component
- The leader is the actor that appears in the connected component most often
- If more than 1 actor has the same number of appearances, the actor with the lowest ACTOR IDENTIFIER is the leader

## Cycle confirmation

All confirmation messages carry a candidate record that identifies the component being confirmed: the member set and the leader's ACTOR IDENTIFIER. Recipients use the candidate record to verify they are responding to the correct confirmation and to route responses back to the leader.

- If at the end of any scheduler run, the leader of a component has an empty queue and rc equal to the number of times it appears in the component then it will initiate a CONFIRM BLOCKED.
- CONFIRM BLOCKED involves sending a message from the leader to each member of the component, carrying the candidate record.
- If receiver has an empty queue, and rc equal to the number of times it is in the component, then it will send a CONFIRMED message to the leader carrying the candidate record. If any of the checks fail, it will send a DENIED to the leader carrying the candidate record.
- If any actor sends back DENIED, then the leader will make the first DENIED sender the new leader via a DELEGATE message carrying the candidate record. The new leader re-enters confirmation by sending CONFIRM BLOCKED.
- If all members send back CONFIRMED then the component is confirmed.

A member may deny because its rc exceeds its appearance count in the candidate — this happens when the member belongs to overlapping cycles the leader hasn't discovered yet. The cycles carried in the DENIED response let the leader expand the candidate to account for all internal references, so the rc check can succeed on retry.

Note: component members cannot self-reap during the confirmation window. A member's rc is held above 0 by the other members' references. A member's rc can only drop to 0 during cycle destruction (after RELEASE). If the component breaks (an external actor drops a reference, or a member gets new work), the confirmation check (rc equals component appearance count) will fail and the member sends DENIED.

## Component destruction

- Leader sends RELEASE to each member of the confirmed component, carrying the candidate record.
- Leader does a GC release of any member of the component that is in its actor map.
- Each member responds to RELEASE by doing a GC release of any member of the component that is in its actor map. This triggers the CONNECTION lifecycle cleanup for each dropped CONNECTION.
- After GC releases, members' rc values drop. Members whose rc reaches 0 with empty queues self-reap.

## CONNECTION lifecycle

When an actor loses a CONNECTION — either by GC releasing a reference directly or by processing a RELEASE message during cycle destruction — the following state is cleared:

- The CONNECTION itself is removed from the actor's set of outgoing CONNECTIONs.
- The actor's EPOCH is incremented (invalidating any in-flight TRACE ROUTE message that passed through this actor before the drop).
- Any known cycle that included the dropped actor is removed from the actor's known cycle set.
- All trace deduplication entries for the dropped CONNECTION (where this actor sent a trace to the dropped target) are cleared.
- All trace deduplication entries where this actor appears anywhere in a chain's visited sequence are cleared. This prevents stale entries from suppressing valid traces after the topology change — without it, an entry mentioning an actor whose topology changed could survive and suppress a trace that reflects the new topology.

The same cleanup applies during RELEASE processing, where a member drops CONNECTIONs to all other members of the destroyed component. Any known cycle that includes any of the dropped members is removed from the actor's known cycle set.

When an actor is destroyed (self-reap) or its ACTOR IDENTIFIER is reused, all trace deduplication entries mentioning the actor — as sender, as target, or anywhere in a chain's visited sequence — are cleared across the entire deduplication state.
