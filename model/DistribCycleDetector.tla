--------------------------- MODULE DistribCycleDetector ---------------------------
(**************************************************************************)
(* TLA+ specification of the distributed cycle detection protocol for     *)
(* Pony actors. Models trace propagation with per-hop epoch checking,     *)
(* cycle candidate detection, multi-step confirmation via CONFIRM         *)
(* BLOCKED / CONFIRMED / DENIED message exchange, cascading GC release    *)
(* via RELEASE messages, self-reap, and CONNECTION reset with ACTOR       *)
(* IDENTIFIER reuse.                                                      *)
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
    destroyed,          \* set of destroyed actor ids
    pendingConfirmation \* set of candidates awaiting confirmation responses

vars == <<actors, epoch, inMem, messages, cycleCandidates,
          confirmedCycles, destroyed, pendingConfirmation>>

\* Message types
TraceRouteMsg == "TraceRoute"
AppMsg == "App"
ConfirmBlockedMsg == "ConfirmBlocked"
ConfirmedMsg == "Confirmed"
DeniedMsg == "Denied"
ReleaseMsg == "Release"

(**************************************************************************)
(* Helper operators                                                       *)
(**************************************************************************)

\* An actor is alive if it's in actors and not destroyed
Alive(a) == a \in actors /\ a \notin destroyed

VisitedIds(visited) == {visited[i].id : i \in 1..Len(visited)}

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

\* Is a message a confirmation protocol message?
IsConfirmationMsg(m) ==
    m.type \in {ConfirmBlockedMsg, ConfirmedMsg, DeniedMsg}

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
    /\ pendingConfirmation = {}

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
        /\ UNCHANGED <<messages, cycleCandidates, confirmedCycles,
                        destroyed, pendingConfirmation>>

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
        /\ UNCHANGED <<messages, cycleCandidates, confirmedCycles,
                        pendingConfirmation>>

\* An actor drops exactly one reference, incrementing its epoch.
\* CONNECTION reset: when the last reference to another actor is dropped,
\* all trace history and cycle state for that connection is cleared.
\* In the model, this is captured by the epoch increment — stale traces
\* from before the drop are caught by per-hop epoch checking.
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
                        confirmedCycles, destroyed, pendingConfirmation>>

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
                            confirmedCycles, destroyed,
                            pendingConfirmation>>

\* An actor receives an application message and acquires references
ReceiveAppMessage(msg) ==
    /\ msg \in messages
    /\ msg.type = AppMsg
    /\ Alive(msg.to)
    /\ inMem' = [inMem EXCEPT ![msg.to] = @ \union (msg.args \ {msg.to})]
    /\ messages' = messages \ {msg}
    /\ UNCHANGED <<actors, epoch, cycleCandidates, confirmedCycles,
                    destroyed, pendingConfirmation>>

\* An actor initiates a trace to a referenced actor
InitiateTrace(initiator) ==
    /\ Alive(initiator)
    /\ inMem[initiator] # {}
    /\ Cardinality(messages) < MaxMessages
    /\ \E target \in inMem[initiator] :
        /\ messages' = messages \union {[
               type |-> TraceRouteMsg,
               to |-> target,
               visited |-> <<[id |-> initiator,
                              epoch |-> epoch[initiator]]>>]}
        /\ UNCHANGED <<actors, epoch, inMem, cycleCandidates,
                        confirmedCycles, destroyed, pendingConfirmation>>

\* An unvisited actor receives a trace and forwards it
ForwardTrace(msg) ==
    /\ msg \in messages
    /\ msg.type = TraceRouteMsg
    /\ Alive(msg.to)
    /\ msg.to \notin VisitedIds(msg.visited)
    /\ inMem[msg.to] # {}
    /\ Cardinality(messages) < MaxMessages
    /\ \E target \in inMem[msg.to] :
        /\ messages' = (messages \ {msg}) \union {[
               type |-> TraceRouteMsg,
               to |-> target,
               visited |-> Append(msg.visited,
                                  [id |-> msg.to,
                                   epoch |-> epoch[msg.to]])]}
        /\ UNCHANGED <<actors, epoch, inMem, cycleCandidates,
                        confirmedCycles, destroyed, pendingConfirmation>>

\* An actor receives a trace whose originator IS itself and all
\* per-hop epochs match their actors' current epochs.
DetectCycle(msg) ==
    /\ msg \in messages
    /\ msg.type = TraceRouteMsg
    /\ Alive(msg.to)
    /\ msg.visited[1].id = msg.to
    /\ \A i \in 1..Len(msg.visited) :
        msg.visited[i].epoch = epoch[msg.visited[i].id]
    /\ LET members == VisitedIds(msg.visited)
       IN /\ ~\E c \in cycleCandidates :
               c.members = members /\ c.detectedBy = msg.to
          /\ cycleCandidates' = cycleCandidates \union {[
                 members |-> members,
                 detectedBy |-> msg.to]}
    /\ messages' = messages \ {msg}
    /\ UNCHANGED <<actors, epoch, inMem, confirmedCycles, destroyed,
                    pendingConfirmation>>

\* An actor receives a trace whose originator IS itself but at least
\* one per-hop epoch does not match its actor's current epoch.
DiscardStaleTrace(msg) ==
    /\ msg \in messages
    /\ msg.type = TraceRouteMsg
    /\ Alive(msg.to)
    /\ msg.visited[1].id = msg.to
    /\ \E i \in 1..Len(msg.visited) :
        msg.visited[i].epoch # epoch[msg.visited[i].id]
    /\ messages' = messages \ {msg}
    /\ UNCHANGED <<actors, epoch, inMem, cycleCandidates,
                    confirmedCycles, destroyed, pendingConfirmation>>

\* A trace arrives at a non-originator actor already in the visited
\* sequence. Pattern-2 cycle detection (extracting the sub-cycle) is
\* not modeled, so the trace is discarded.
DropStuckTrace(msg) ==
    /\ msg \in messages
    /\ msg.type = TraceRouteMsg
    /\ Alive(msg.to)
    /\ msg.to \in VisitedIds(msg.visited)
    /\ msg.visited[1].id # msg.to
    /\ messages' = messages \ {msg}
    /\ UNCHANGED <<actors, epoch, inMem, cycleCandidates,
                    confirmedCycles, destroyed, pendingConfirmation>>

(**************************************************************************)
(* Multi-step confirmation                                                *)
(* The leader sends CONFIRM BLOCKED to each member. Each member checks    *)
(* local conditions and responds CONFIRMED or DENIED. The leader          *)
(* collects responses and either confirms or abandons the candidate.      *)
(**************************************************************************)

\* The leader initiates confirmation by sending CONFIRM BLOCKED to
\* each cycle member (including itself — uniform processing).
SendConfirmBlocked(candidate) ==
    /\ candidate \in cycleCandidates
    /\ Alive(candidate.detectedBy)
    /\ Cardinality(messages) + Cardinality(candidate.members) <= MaxMessages
    /\ LET cand == [members |-> candidate.members,
                     detectedBy |-> candidate.detectedBy]
       IN /\ messages' = messages \union
              {[type |-> ConfirmBlockedMsg,
                to |-> m,
                candidate |-> cand] : m \in candidate.members}
          /\ pendingConfirmation' = pendingConfirmation \union {cand}
    /\ cycleCandidates' = cycleCandidates \ {candidate}
    /\ UNCHANGED <<actors, epoch, inMem, confirmedCycles, destroyed>>

\* A member receives CONFIRM BLOCKED and confirms. All local conditions
\* hold: empty queue, no external references, no in-flight AppMsg
\* references. The in-flight AppMsg check simulates ORCA's rc accounting,
\* which the model lacks.
RespondConfirmed(msg) ==
    /\ msg \in messages
    /\ msg.type = ConfirmBlockedMsg
    /\ Alive(msg.to)
    \* Empty queue: no other messages addressed to this actor
    /\ MessagesTo(msg.to) \ {msg} = {}
    \* RC check: no actor outside the cycle references this member
    /\ ~\E other \in (actors \ destroyed) \ msg.candidate.members :
        msg.to \in inMem[other]
    \* In-flight reference check: no AppMsg carries a reference to this
    \* member. Simulates ORCA's rc accounting — in the real protocol,
    \* rc = cycle_appearance_count implies no external in-flight refs.
    /\ ~\E m \in messages :
        m.type = AppMsg /\ msg.to \in m.args
    /\ messages' = (messages \ {msg}) \union {[
           type |-> ConfirmedMsg,
           to |-> msg.candidate.detectedBy,
           from |-> msg.to,
           candidate |-> msg.candidate]}
    /\ UNCHANGED <<actors, epoch, inMem, cycleCandidates,
                    confirmedCycles, destroyed, pendingConfirmation>>

\* A member receives CONFIRM BLOCKED and denies — at least one local
\* condition fails.
RespondDenied(msg) ==
    /\ msg \in messages
    /\ msg.type = ConfirmBlockedMsg
    /\ Alive(msg.to)
    \* At least one condition fails
    /\ \/ MessagesTo(msg.to) \ {msg} # {}
       \/ \E other \in (actors \ destroyed) \ msg.candidate.members :
           msg.to \in inMem[other]
       \/ \E m \in messages :
           m.type = AppMsg /\ msg.to \in m.args
    /\ messages' = (messages \ {msg}) \union {[
           type |-> DeniedMsg,
           to |-> msg.candidate.detectedBy,
           from |-> msg.to,
           candidate |-> msg.candidate]}
    /\ UNCHANGED <<actors, epoch, inMem, cycleCandidates,
                    confirmedCycles, destroyed, pendingConfirmation>>

\* All members confirmed. The leader moves the candidate to
\* confirmedCycles and consumes the response messages.
ConfirmationSucceeded(pending) ==
    /\ pending \in pendingConfirmation
    \* Every member sent CONFIRMED
    /\ \A m \in pending.members :
        \E resp \in messages :
            /\ resp.type = ConfirmedMsg
            /\ resp.to = pending.detectedBy
            /\ resp.from = m
            /\ resp.candidate = pending
    /\ LET responses == {resp \in messages :
               /\ resp.type = ConfirmedMsg
               /\ resp.to = pending.detectedBy
               /\ resp.candidate = pending}
       IN messages' = messages \ responses
    /\ confirmedCycles' = confirmedCycles \union {[
           members |-> pending.members,
           confirmedBy |-> pending.detectedBy]}
    /\ pendingConfirmation' = pendingConfirmation \ {pending}
    /\ UNCHANGED <<actors, epoch, inMem, cycleCandidates, destroyed>>

\* At least one member denied. The leader abandons the candidate and
\* consumes all response messages.
ConfirmationFailed(pending) ==
    /\ pending \in pendingConfirmation
    \* Every member has responded (confirmed or denied)
    /\ \A m \in pending.members :
        \E resp \in messages :
            /\ resp.type \in {ConfirmedMsg, DeniedMsg}
            /\ resp.to = pending.detectedBy
            /\ resp.from = m
            /\ resp.candidate = pending
    \* At least one denied
    /\ \E resp \in messages :
        /\ resp.type = DeniedMsg
        /\ resp.to = pending.detectedBy
        /\ resp.candidate = pending
    /\ LET responses == {resp \in messages :
               /\ resp.type \in {ConfirmedMsg, DeniedMsg}
               /\ resp.to = pending.detectedBy
               /\ resp.candidate = pending}
       IN messages' = messages \ responses
    /\ pendingConfirmation' = pendingConfirmation \ {pending}
    /\ UNCHANGED <<actors, epoch, inMem, cycleCandidates,
                    confirmedCycles, destroyed>>

\* Confirmation fails: at least one member can't reach itself.
\* Garbage-collects stale candidates before they enter the confirmation
\* pipeline and waste message capacity.
DenyCandidate(candidate) ==
    /\ candidate \in cycleCandidates
    /\ ~IsRealCycle(candidate.members)
    /\ cycleCandidates' = cycleCandidates \ {candidate}
    /\ UNCHANGED <<actors, epoch, inMem, messages,
                    confirmedCycles, destroyed, pendingConfirmation>>

(**************************************************************************)
(* Cascading GC release                                                   *)
(* The leader sends RELEASE to each cycle member. Each member drops its   *)
(* references to other members. Members whose rc reaches 0 self-reap via  *)
(* the existing SelfReap action.                                          *)
(**************************************************************************)

\* The leader initiates destruction by sending RELEASE to each cycle
\* member (including itself — uniform processing). Re-verifies all
\* confirmation conditions before proceeding.
SendRelease(confirmed) ==
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
            \/ (m.type = TraceRouteMsg /\ a \in VisitedIds(m.visited))
    \* No messages queued for any member
    /\ \A a \in confirmed.members :
        MessagesTo(a) = {}
    /\ Cardinality(messages) + Cardinality(confirmed.members) <= MaxMessages
    /\ messages' = messages \union
           {[type |-> ReleaseMsg,
             to |-> m,
             confirmed |-> confirmed] : m \in confirmed.members}
    /\ confirmedCycles' = confirmedCycles \ {confirmed}
    /\ UNCHANGED <<actors, epoch, inMem, cycleCandidates,
                    destroyed, pendingConfirmation>>

\* A member receives RELEASE and drops its references to other cycle
\* members. Increments epoch to invalidate stale traces.
ProcessRelease(msg) ==
    /\ msg \in messages
    /\ msg.type = ReleaseMsg
    /\ Alive(msg.to)
    /\ LET others == msg.confirmed.members \ {msg.to}
       IN /\ inMem' = [inMem EXCEPT ![msg.to] = @ \ others]
          /\ epoch' = [epoch EXCEPT ![msg.to] = IF @ < MaxEpoch
                                                 THEN @ + 1
                                                 ELSE @]
    /\ messages' = messages \ {msg}
    /\ UNCHANGED <<actors, cycleCandidates, confirmedCycles,
                    destroyed, pendingConfirmation>>

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
        \/ (m.type = TraceRouteMsg /\ actor \in VisitedIds(m.visited))
    \* Not involved in any pending confirmation
    /\ ~\E p \in pendingConfirmation : actor \in p.members
    \* No protocol message references this actor in a candidate
    /\ ~\E m \in messages :
        IsConfirmationMsg(m) /\ actor \in m.candidate.members
    /\ destroyed' = destroyed \union {actor}
    /\ inMem' = [inMem EXCEPT ![actor] = {}]
    \* Remove candidates involving this actor
    /\ cycleCandidates' = {c \in cycleCandidates :
                              actor \notin c.members}
    /\ confirmedCycles' = {c \in confirmedCycles :
                              actor \notin c.members}
    /\ pendingConfirmation' = {p \in pendingConfirmation :
                                  actor \notin p.members}
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
    \/ \E m \in messages : DropStuckTrace(m)
    \/ \E c \in cycleCandidates : SendConfirmBlocked(c)
    \/ \E c \in cycleCandidates : DenyCandidate(c)
    \/ \E m \in messages : RespondConfirmed(m)
    \/ \E m \in messages : RespondDenied(m)
    \/ \E p \in pendingConfirmation : ConfirmationSucceeded(p)
    \/ \E p \in pendingConfirmation : ConfirmationFailed(p)
    \/ \E c \in confirmedCycles : SendRelease(c)
    \/ \E m \in messages : ProcessRelease(m)
    \/ \E a \in actors : SelfReap(a)

Spec == Init /\ [][Next]_vars

(**************************************************************************)
(* Invariants                                                             *)
(**************************************************************************)

\* CANDIDATE SOUNDNESS: every cycle candidate is a real cycle.
\* Expected to FAIL — an actor can drop a reference after the candidate
\* is recorded. Per-hop epoch checking prevents stale traces from
\* producing candidates, but cannot prevent post-detection topology
\* changes. The confirmation protocol catches these.
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
\* Confirmation protocol messages and pendingConfirmation records count
\* toward the bound.
StateConstraint ==
    Cardinality(actors) + Cardinality(messages)
    + Cardinality(cycleCandidates) + Cardinality(confirmedCycles)
    + Cardinality(destroyed) + Cardinality(pendingConfirmation)
    <= MaxActors + MaxMessages

=============================================================================
