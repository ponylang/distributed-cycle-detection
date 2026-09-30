--------------------------- MODULE DistribCycleDetector ---------------------------
(**************************************************************************)
(* TLA+ specification of the distributed cycle detection protocol for     *)
(* Pony actors. Models trace propagation, epoch-based staleness, cycle    *)
(* candidate detection, confirmation, destruction, self-reap, and         *)
(* CONNECTION reset with ACTOR IDENTIFIER reuse.                          *)
(**************************************************************************)
EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS
    MaxActors,      \* maximum number of actors (bound for model checking)
    MaxMessages,    \* maximum number of messages
    MaxEpoch,       \* maximum epoch value
    ActorIds        \* set of possible actor identifiers

VARIABLES
    actors,             \* set of active actor ids
    epoch,              \* epoch[a] = current epoch of actor a
    inMem,              \* inMem[a] = set of actors that a references
    messages,           \* set of messages in transit (records)
    cycleCandidates,    \* set of detected cycle candidates
    confirmedCycles,    \* set of confirmed cycles
    destroyed           \* set of destroyed actor ids

vars == <<actors, epoch, inMem, messages, cycleCandidates,
          confirmedCycles, destroyed>>

\* Message types
TraceRouteMsg == "TraceRoute"
AppMsg == "App"

(**************************************************************************)
(* Helper operators                                                       *)
(**************************************************************************)

\* An actor is alive if it's in actors and not destroyed
Alive(a) == a \in actors /\ a \notin destroyed

\* Messages enqueued to a specific actor
MessagesTo(a) == {m \in messages : m.to = a}

\* Can actor a reach itself through inMem restricted to a set S?
\* Fixed-depth BFS — correct for MaxActors <= 3.
ReachableThroughSet(a, S) ==
    LET Succ(x) == {y \in S : y \in inMem[x]}
        step1 == Succ(a)
        step2 == UNION {Succ(x) : x \in step1}
        step3 == UNION {Succ(x) : x \in step2}
        reachable == step1 \union step2 \union step3
    IN a \in reachable

\* All members of a cycle can reach themselves through inMem within members
IsRealCycle(members) ==
    /\ members # {}
    /\ \A a \in members : ReachableThroughSet(a, members)

(**************************************************************************)
(* Initial state                                                          *)
(**************************************************************************)

\* Start with a single "main" actor
Init ==
    /\ actors = {1}
    /\ epoch = [a \in ActorIds |-> 0]
    /\ inMem = [a \in ActorIds |-> {}]
    /\ messages = {}
    /\ cycleCandidates = {}
    /\ confirmedCycles = {}
    /\ destroyed = {}

(**************************************************************************)
(* Actions                                                                *)
(**************************************************************************)

\* Spawn a new actor from an existing actor (fresh id, never used before)
SpawnActor(spawner) ==
    /\ Alive(spawner)
    /\ \E newId \in ActorIds \ actors :
        /\ newId \notin destroyed
        /\ Cardinality(actors \ destroyed) < MaxActors
        /\ actors' = actors \union {newId}
        /\ epoch' = [epoch EXCEPT ![newId] = 0]
        /\ inMem' = [inMem EXCEPT ![spawner] = @ \union {newId},
                                   ![newId] = {}]
        /\ UNCHANGED <<messages, cycleCandidates, confirmedCycles, destroyed>>

\* Reuse a destroyed actor's id for a new actor.
\* The spawner gets a reference; the new actor starts fresh.
\* CONNECTION reset: all protocol state for the old id is stale.
ReuseActorId(spawner) ==
    /\ Alive(spawner)
    /\ \E reusedId \in destroyed :
        /\ Cardinality(actors \ destroyed) < MaxActors
        /\ actors' = actors
        /\ destroyed' = destroyed \ {reusedId}
        /\ epoch' = [epoch EXCEPT ![reusedId] = 0]
        /\ inMem' = [inMem EXCEPT ![spawner] = @ \union {reusedId},
                                   ![reusedId] = {}]
        \* Stale candidates/confirmed cycles involving the old incarnation
        \* are NOT automatically cleared — the protocol must handle this
        \* via confirmation checks. This tests whether confirmation is
        \* robust to id reuse.
        /\ UNCHANGED <<messages, cycleCandidates, confirmedCycles>>

\* An actor drops exactly one reference, incrementing its epoch.
\* CONNECTION reset: when the last reference to another actor is dropped,
\* all trace history and cycle state for that connection is cleared.
\* In the model, this is captured by the epoch increment — stale traces
\* from before the drop are discarded when they return to the originator.
\*
\* Epoch saturation: when epoch reaches MaxEpoch, further drops don't
\* increment it. A stale trace from after saturation carries the same
\* epoch as the current one and is accepted. This means the model
\* underreports staleness bugs at low MaxEpoch values. The confirmation
\* protocol catches these false candidates regardless.
ReduceMem(actor) ==
    /\ Alive(actor)
    /\ inMem[actor] # {}
    /\ \E dropped \in inMem[actor] :
        /\ inMem' = [inMem EXCEPT ![actor] = @ \ {dropped}]
        /\ epoch' = [epoch EXCEPT ![actor] = IF @ < MaxEpoch
                                              THEN @ + 1
                                              ELSE @]
        /\ UNCHANGED <<actors, messages, cycleCandidates,
                        confirmedCycles, destroyed>>

\* An actor sends an application message carrying one actor reference
SendAppMessage(sender) ==
    /\ Alive(sender)
    /\ inMem[sender] # {}
    /\ Cardinality(messages) < MaxMessages
    /\ \E receiver \in inMem[sender] :
        \E arg \in inMem[sender] \union {sender} :
            /\ messages' = messages \union {[
                   type |-> AppMsg,
                   to |-> receiver,
                   args |-> {arg}]}
            /\ UNCHANGED <<actors, epoch, inMem, cycleCandidates,
                            confirmedCycles, destroyed>>

\* An actor receives an application message and acquires references
ReceiveAppMessage(msg) ==
    /\ msg \in messages
    /\ msg.type = AppMsg
    /\ Alive(msg.to)
    /\ inMem' = [inMem EXCEPT ![msg.to] = @ \union (msg.args \ {msg.to})]
    /\ messages' = messages \ {msg}
    /\ UNCHANGED <<actors, epoch, cycleCandidates, confirmedCycles,
                    destroyed>>

\* An actor initiates a trace to a referenced actor
InitiateTrace(initiator) ==
    /\ Alive(initiator)
    /\ inMem[initiator] # {}
    /\ Cardinality(messages) < MaxMessages
    /\ \E target \in inMem[initiator] :
        /\ messages' = messages \union {[
               type |-> TraceRouteMsg,
               to |-> target,
               visited |-> {initiator},
               originator |-> initiator,
               originatorEpoch |-> epoch[initiator]]}
        /\ UNCHANGED <<actors, epoch, inMem, cycleCandidates,
                        confirmedCycles, destroyed>>

\* An actor receives a trace whose originator is NOT itself; forwards it
ForwardTrace(msg) ==
    /\ msg \in messages
    /\ msg.type = TraceRouteMsg
    /\ Alive(msg.to)
    /\ msg.originator # msg.to
    /\ inMem[msg.to] # {}
    /\ Cardinality(messages) < MaxMessages
    /\ \E target \in inMem[msg.to] :
        /\ messages' = (messages \ {msg}) \union {[
               type |-> TraceRouteMsg,
               to |-> target,
               visited |-> msg.visited \union {msg.to},
               originator |-> msg.originator,
               originatorEpoch |-> msg.originatorEpoch]}
        /\ UNCHANGED <<actors, epoch, inMem, cycleCandidates,
                        confirmedCycles, destroyed>>

\* An actor receives a trace whose originator IS itself, epoch matches
DetectCycle(msg) ==
    /\ msg \in messages
    /\ msg.type = TraceRouteMsg
    /\ Alive(msg.to)
    /\ msg.originator = msg.to
    /\ msg.originatorEpoch = epoch[msg.to]
    /\ LET members == msg.visited
       IN /\ ~\E c \in cycleCandidates :
               c.members = members /\ c.detectedBy = msg.to
          /\ cycleCandidates' = cycleCandidates \union {[
                 members |-> members,
                 detectedBy |-> msg.to]}
    /\ messages' = messages \ {msg}
    /\ UNCHANGED <<actors, epoch, inMem, confirmedCycles, destroyed>>

\* An actor receives a trace whose originator IS itself, epoch mismatch
DiscardStaleTrace(msg) ==
    /\ msg \in messages
    /\ msg.type = TraceRouteMsg
    /\ Alive(msg.to)
    /\ msg.originator = msg.to
    /\ msg.originatorEpoch # epoch[msg.to]
    /\ messages' = messages \ {msg}
    /\ UNCHANGED <<actors, epoch, inMem, cycleCandidates,
                    confirmedCycles, destroyed>>

\* Confirmation succeeds: all members still form a real cycle AND
\* the only references to each member come from other members (rc check).
ConfirmCandidate(candidate) ==
    /\ candidate \in cycleCandidates
    /\ IsRealCycle(candidate.members)
    /\ \A a \in candidate.members : Alive(a)
    \* RC check: no actor outside the cycle references any member
    /\ \A a \in candidate.members :
        ~\E other \in (actors \ destroyed) \ candidate.members :
            a \in inMem[other]
    \* No in-flight message carries a reference to any member
    /\ \A a \in candidate.members :
        ~\E m \in messages :
            \/ (m.type = AppMsg /\ a \in m.args)
            \/ (m.type = TraceRouteMsg /\ a \in m.visited)
    \* No messages queued for any member (empty queue check)
    /\ \A a \in candidate.members :
        MessagesTo(a) = {}
    /\ cycleCandidates' = cycleCandidates \ {candidate}
    /\ confirmedCycles' = confirmedCycles \union {[
           members |-> candidate.members,
           confirmedBy |-> candidate.detectedBy]}
    /\ UNCHANGED <<actors, epoch, inMem, messages, destroyed>>

\* Confirmation fails: at least one member can't reach itself
DenyCandidate(candidate) ==
    /\ candidate \in cycleCandidates
    /\ ~IsRealCycle(candidate.members)
    /\ cycleCandidates' = cycleCandidates \ {candidate}
    /\ UNCHANGED <<actors, epoch, inMem, messages,
                    confirmedCycles, destroyed>>

\* Destroy a confirmed cycle: remove all members.
\* Re-checks all confirmation conditions.
DestroyConfirmedCycle(confirmed) ==
    /\ confirmed \in confirmedCycles
    /\ \A a \in confirmed.members : Alive(a)
    /\ IsRealCycle(confirmed.members)
    \* RC check: no external references to any member
    /\ \A a \in confirmed.members :
        ~\E other \in (actors \ destroyed) \ confirmed.members :
            a \in inMem[other]
    \* No in-flight message carries a reference to any member
    /\ \A a \in confirmed.members :
        ~\E m \in messages :
            \/ (m.type = AppMsg /\ a \in m.args)
            \/ (m.type = TraceRouteMsg /\ a \in m.visited)
    \* No messages queued for any member
    /\ \A a \in confirmed.members :
        MessagesTo(a) = {}
    /\ destroyed' = destroyed \union confirmed.members
    /\ confirmedCycles' = confirmedCycles \ {confirmed}
    /\ inMem' = [a \in ActorIds |->
                    IF a \in confirmed.members
                    THEN {}
                    ELSE inMem[a] \ confirmed.members]
    \* Remove messages to/from destroyed actors
    /\ messages' = {m \in messages :
                       /\ m.to \notin confirmed.members
                       /\ (m.type = TraceRouteMsg =>
                           m.originator \notin confirmed.members)}
    \* Remove candidates involving destroyed actors
    /\ cycleCandidates' = {c \in cycleCandidates :
                              c.members \cap confirmed.members = {}}
    /\ UNCHANGED <<actors, epoch>>

\* Self-reap: an actor with rc=0 and no messages in its queue.
SelfReap(actor) ==
    /\ Alive(actor)
    \* No other alive actor references this actor
    /\ ~\E other \in actors \ destroyed :
        other # actor /\ actor \in inMem[other]
    \* No in-flight message carries a reference to this actor
    /\ ~\E m \in messages :
        \/ m.to = actor
        \/ (m.type = AppMsg /\ actor \in m.args)
        \/ (m.type = TraceRouteMsg /\ actor \in m.visited)
    /\ destroyed' = destroyed \union {actor}
    /\ inMem' = [inMem EXCEPT ![actor] = {}]
    \* Remove candidates involving this actor
    /\ cycleCandidates' = {c \in cycleCandidates :
                              actor \notin c.members}
    /\ confirmedCycles' = {c \in confirmedCycles :
                              actor \notin c.members}
    /\ UNCHANGED <<actors, epoch, messages>>

(**************************************************************************)
(* Overall next-state relation                                            *)
(**************************************************************************)

Next ==
    \/ \E a \in actors : SpawnActor(a)
    \/ \E a \in actors : ReuseActorId(a)
    \/ \E a \in actors : ReduceMem(a)
    \/ \E a \in actors : SendAppMessage(a)
    \/ \E m \in messages : ReceiveAppMessage(m)
    \/ \E a \in actors : InitiateTrace(a)
    \/ \E m \in messages : ForwardTrace(m)
    \/ \E m \in messages : DetectCycle(m)
    \/ \E m \in messages : DiscardStaleTrace(m)
    \/ \E c \in cycleCandidates : ConfirmCandidate(c)
    \/ \E c \in cycleCandidates : DenyCandidate(c)
    \/ \E c \in confirmedCycles : DestroyConfirmedCycle(c)
    \/ \E a \in actors : SelfReap(a)

Spec == Init /\ [][Next]_vars

(**************************************************************************)
(* Invariants                                                             *)
(**************************************************************************)

\* CANDIDATE SOUNDNESS: every cycle candidate is a real cycle.
\* Expected to FAIL — an intermediate actor can drop a reference after
\* forwarding a trace.
CandidateSoundness ==
    \A c \in cycleCandidates : IsRealCycle(c.members)

\* DESTRUCTION SAFETY: no alive actor references a destroyed actor.
DestructionSafety ==
    \A a \in actors \ destroyed :
        inMem[a] \cap destroyed = {}

\* NO ORPHAN MESSAGES: no message is addressed to a destroyed actor.
NoOrphanMessages ==
    \A m \in messages : m.to \notin destroyed

\* STATE CONSTRAINT: bounds total state complexity for tractable checking.
\* This prunes states with many simultaneous objects. Confirmation and
\* destruction require empty queues, so the constraint doesn't affect
\* those paths much, but it may miss bugs requiring many concurrent
\* messages during non-destruction actions.
StateConstraint ==
    Cardinality(actors) + Cardinality(messages)
    + Cardinality(cycleCandidates) + Cardinality(confirmedCycles)
    + Cardinality(destroyed) <= MaxActors + MaxMessages

=============================================================================
