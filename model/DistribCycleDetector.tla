--------------------------- MODULE DistribCycleDetector ---------------------------
(**************************************************************************)
(* TLA+ specification of the distributed cycle detection protocol for     *)
(* Pony actors. Models trace propagation with per-hop epoch checking,     *)
(* CONNECTION-level trace deduplication, per-actor cycle knowledge with    *)
(* gossip propagation, connected component merging, component-level       *)
(* confirmation via CONFIRM BLOCKED / CONFIRMED / DENIED message          *)
(* exchange, leadership delegation via DELEGATE on confirmation failure,  *)
(* cascading GC release via RELEASE messages, self-reap, and CONNECTION   *)
(* reset with ACTOR IDENTIFIER reuse.                                     *)
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
    knownCycles,        \* knownCycles[a] = set of member-sets (cycles detected or received by actor a)
    cycleCandidates,    \* set of proposed component candidates
    confirmedCycles,    \* set of confirmed cycles
    destroyed,          \* set of destroyed actor ids
    pendingConfirmation,\* set of candidates awaiting confirmation responses
    sentTraces          \* set of [from, to, chain] records for deduplication

vars == <<actors, epoch, inMem, messages, knownCycles, cycleCandidates,
          confirmedCycles, destroyed, pendingConfirmation, sentTraces>>

\* Message types
TraceRouteMsg == "TraceRoute"
AppMsg == "App"
ConfirmBlockedMsg == "ConfirmBlocked"
ConfirmedMsg == "Confirmed"
DeniedMsg == "Denied"
ReleaseMsg == "Release"
DelegateMsg == "Delegate"
InformCyclesMsg == "InformCycles"

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
    m.type \in {ConfirmBlockedMsg, ConfirmedMsg, DeniedMsg, DelegateMsg}

\* Connected component containing startCycle, computed from a set of cycles.
\* Fixed-depth expansion — correct for MaxActors <= 3.
ComponentMembers(startCycle, cycles) ==
    LET step0 == startCycle
        overlap1 == UNION {c \in cycles : c \cap step0 # {}}
        overlap2 == UNION {c \in cycles : c \cap overlap1 # {}}
        overlap3 == UNION {c \in cycles : c \cap overlap2 # {}}
    IN overlap3

\* The cycles that belong to a component.
ComponentCycles(startCycle, cycles) ==
    LET members == ComponentMembers(startCycle, cycles)
    IN {c \in cycles : c \cap members # {}}

\* Component leader: most appearances across the component's cycles,
\* lowest ID tiebreaker.
ComponentLeader(cycles) ==
    LET members == UNION cycles
        Count(a) == Cardinality({c \in cycles : a \in c})
    IN CHOOSE a \in members : \A b \in members :
           \/ Count(a) > Count(b)
           \/ (Count(a) = Count(b) /\ a <= b)

\* Total (actor, cycle) pairs across all actors' knownCycles.
KnownCyclesCount ==
    Cardinality(UNION {{<<a, c>> : c \in knownCycles[a]} : a \in ActorIds})

(**************************************************************************)
(* Initial state                                                          *)
(**************************************************************************)

\* Start with a single "main" actor
Init ==
    /\ actors = {1}
    /\ epoch = [a \in ActorIds |-> 0]
    /\ inMem = [a \in ActorIds |-> {}]
    /\ messages = {}
    /\ knownCycles = [a \in ActorIds |-> {}]
    /\ cycleCandidates = {}
    /\ confirmedCycles = {}
    /\ destroyed = {}
    /\ pendingConfirmation = {}
    /\ sentTraces = {}

\* All actors alive, each referencing every other
InitFullyConnected ==
    /\ actors = ActorIds
    /\ epoch = [a \in ActorIds |-> 0]
    /\ inMem = [a \in ActorIds |-> ActorIds \ {a}]
    /\ messages = {}
    /\ knownCycles = [a \in ActorIds |-> {}]
    /\ cycleCandidates = {}
    /\ confirmedCycles = {}
    /\ destroyed = {}
    /\ pendingConfirmation = {}
    /\ sentTraces = {}

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
        /\ UNCHANGED <<messages, knownCycles, cycleCandidates,
                        confirmedCycles, destroyed, pendingConfirmation,
                        sentTraces>>

\* Reuse a destroyed actor's id for a new actor.
\* The spawner gets a reference; the new actor starts fresh.
\* CONNECTION reset: all protocol state for the old id is stale.
\* Deduplication entries mentioning the old incarnation — as sender,
\* target, or anywhere in a chain's visited sequence — are cleared
\* so the new incarnation's traces are not suppressed by stale history.
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
        /\ knownCycles' = [knownCycles EXCEPT ![reusedId] = {}]
        /\ sentTraces' = {e \in sentTraces :
                             /\ e.from # reusedId
                             /\ e.to # reusedId
                             /\ reusedId \notin VisitedIds(e.chain)}
        /\ UNCHANGED <<messages, cycleCandidates, confirmedCycles,
                        pendingConfirmation>>

\* An actor drops exactly one reference, incrementing its epoch.
\* CONNECTION reset: when the last reference to another actor is dropped,
\* all trace history and cycle state for that connection is cleared.
\* The epoch increment catches stale in-flight traces via per-hop
\* epoch checking; the sentTraces cleanup clears deduplication state
\* for the dropped connection and any chain mentioning the actor,
\* so future traces are not suppressed by stale history — especially
\* under epoch saturation where the epoch doesn't change.
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
        /\ knownCycles' = [knownCycles EXCEPT ![actor] =
                              {c \in @ : dropped \notin c}]
        /\ sentTraces' = {e \in sentTraces :
                             /\ ~(e.from = actor /\ e.to = dropped)
                             /\ actor \notin VisitedIds(e.chain)}
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
            /\ UNCHANGED <<actors, epoch, inMem, knownCycles,
                            cycleCandidates, confirmedCycles, destroyed,
                            pendingConfirmation, sentTraces>>

\* An actor receives an application message and acquires references
ReceiveAppMessage(msg) ==
    /\ msg \in messages
    /\ msg.type = AppMsg
    /\ Alive(msg.to)
    /\ inMem' = [inMem EXCEPT ![msg.to] = @ \union (msg.args \ {msg.to})]
    /\ messages' = messages \ {msg}
    /\ UNCHANGED <<actors, epoch, knownCycles, cycleCandidates,
                    confirmedCycles, destroyed, pendingConfirmation,
                    sentTraces>>

\* An actor initiates a trace to a referenced actor
InitiateTrace(initiator) ==
    /\ Alive(initiator)
    /\ inMem[initiator] # {}
    /\ Cardinality(messages) < MaxMessages
    /\ \E target \in inMem[initiator] :
        LET chain == <<[id |-> initiator, epoch |-> epoch[initiator]]>>
            entry == [from |-> initiator, to |-> target, chain |-> chain]
        IN /\ entry \notin sentTraces
           /\ messages' = messages \union {[
                  type |-> TraceRouteMsg,
                  to |-> target,
                  visited |-> chain]}
           /\ sentTraces' = sentTraces \union {entry}
    /\ UNCHANGED <<actors, epoch, inMem, knownCycles, cycleCandidates,
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
        LET augmented == Append(msg.visited,
                                [id |-> msg.to, epoch |-> epoch[msg.to]])
            entry == [from |-> msg.to, to |-> target, chain |-> augmented]
        IN /\ entry \notin sentTraces
           /\ messages' = (messages \ {msg}) \union {[
                  type |-> TraceRouteMsg,
                  to |-> target,
                  visited |-> augmented]}
           /\ sentTraces' = sentTraces \union {entry}
    /\ UNCHANGED <<actors, epoch, inMem, knownCycles, cycleCandidates,
                    confirmedCycles, destroyed, pendingConfirmation>>

\* All outgoing connections have already seen this trace chain.
\* The trace is consumed without forwarding.
SuppressDuplicateTrace(msg) ==
    /\ msg \in messages
    /\ msg.type = TraceRouteMsg
    /\ Alive(msg.to)
    /\ msg.to \notin VisitedIds(msg.visited)
    /\ inMem[msg.to] # {}
    /\ \A target \in inMem[msg.to] :
        LET augmented == Append(msg.visited,
                                [id |-> msg.to, epoch |-> epoch[msg.to]])
        IN [from |-> msg.to, to |-> target, chain |-> augmented]
           \in sentTraces
    /\ messages' = messages \ {msg}
    /\ UNCHANGED <<actors, epoch, inMem, knownCycles, cycleCandidates,
                    confirmedCycles, destroyed, pendingConfirmation,
                    sentTraces>>

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
       IN /\ members \notin knownCycles[msg.to]
          /\ knownCycles' = [knownCycles EXCEPT ![msg.to] = @ \union {members}]
    /\ messages' = messages \ {msg}
    /\ UNCHANGED <<actors, epoch, inMem, cycleCandidates, confirmedCycles,
                    destroyed, pendingConfirmation, sentTraces>>

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
    /\ UNCHANGED <<actors, epoch, inMem, knownCycles, cycleCandidates,
                    confirmedCycles, destroyed, pendingConfirmation,
                    sentTraces>>

\* A trace arrives at a non-originator actor already in the visited
\* sequence. Extract the sub-cycle (from the actor's position to the
\* end) and record it as a candidate if per-hop epochs match.
DetectSubCycle(msg) ==
    /\ msg \in messages
    /\ msg.type = TraceRouteMsg
    /\ Alive(msg.to)
    /\ msg.to \in VisitedIds(msg.visited)
    /\ msg.visited[1].id # msg.to
    /\ LET pos == CHOOSE i \in 1..Len(msg.visited) : msg.visited[i].id = msg.to
           subVisited == SubSeq(msg.visited, pos, Len(msg.visited))
           members == VisitedIds(subVisited)
       IN /\ \A i \in 1..Len(subVisited) :
               subVisited[i].epoch = epoch[subVisited[i].id]
          /\ members \notin knownCycles[msg.to]
          /\ knownCycles' = [knownCycles EXCEPT ![msg.to] = @ \union {members}]
    /\ messages' = messages \ {msg}
    /\ UNCHANGED <<actors, epoch, inMem, cycleCandidates, confirmedCycles,
                    destroyed, pendingConfirmation, sentTraces>>

\* A trace arrives at a non-originator actor already in the visited
\* sequence, but at least one per-hop epoch in the sub-cycle is stale.
DiscardStaleSubCycle(msg) ==
    /\ msg \in messages
    /\ msg.type = TraceRouteMsg
    /\ Alive(msg.to)
    /\ msg.to \in VisitedIds(msg.visited)
    /\ msg.visited[1].id # msg.to
    /\ LET pos == CHOOSE i \in 1..Len(msg.visited) : msg.visited[i].id = msg.to
           subVisited == SubSeq(msg.visited, pos, Len(msg.visited))
       IN \E i \in 1..Len(subVisited) :
           subVisited[i].epoch # epoch[subVisited[i].id]
    /\ messages' = messages \ {msg}
    /\ UNCHANGED <<actors, epoch, inMem, knownCycles, cycleCandidates,
                    confirmedCycles, destroyed, pendingConfirmation,
                    sentTraces>>

(**************************************************************************)
(* Per-actor cycle knowledge propagation                                  *)
(* Actors gossip their component's cycle set to other component members.  *)
(* The component leader proposes the merged component for confirmation.   *)
(**************************************************************************)

\* An actor sends its component's full cycle set to a component member
\* who doesn't have complete knowledge.
SendInformCycles(actor) ==
    /\ Alive(actor)
    /\ \E startCycle \in knownCycles[actor] :
        /\ actor \in startCycle
        /\ LET componentCycles == ComponentCycles(startCycle, knownCycles[actor])
           IN \E target \in ComponentMembers(startCycle, knownCycles[actor]) :
               /\ target # actor
               /\ Alive(target)
               /\ ~(componentCycles \subseteq knownCycles[target])
               /\ Cardinality(messages) < MaxMessages
               /\ messages' = messages \union {[
                      type |-> InformCyclesMsg,
                      to |-> target,
                      cycles |-> componentCycles]}
               /\ UNCHANGED <<actors, epoch, inMem, knownCycles,
                               cycleCandidates, confirmedCycles, destroyed,
                               pendingConfirmation, sentTraces>>

\* An actor receives an inform message and unions the received cycles
\* with its own knowledge.
ReceiveInformCycles(msg) ==
    /\ msg \in messages
    /\ msg.type = InformCyclesMsg
    /\ Alive(msg.to)
    /\ knownCycles' = [knownCycles EXCEPT ![msg.to] = @ \union msg.cycles]
    /\ messages' = messages \ {msg}
    /\ UNCHANGED <<actors, epoch, inMem, cycleCandidates, confirmedCycles,
                    destroyed, pendingConfirmation, sentTraces>>

\* The computed leader of a component proposes it into cycleCandidates
\* for confirmation.
ProposeComponent(actor) ==
    /\ Alive(actor)
    /\ \E startCycle \in knownCycles[actor] :
        /\ actor \in startCycle
        /\ LET component == ComponentMembers(startCycle, knownCycles[actor])
               componentCycles == ComponentCycles(startCycle, knownCycles[actor])
               leader == ComponentLeader(componentCycles)
           IN /\ leader = actor
              /\ IsRealCycle(component)
              /\ ~\E c \in cycleCandidates : c.members = component
              /\ ~\E p \in pendingConfirmation : p.members = component
              /\ cycleCandidates' = cycleCandidates \union {[
                     members |-> component,
                     detectedBy |-> leader]}
              /\ UNCHANGED <<actors, epoch, inMem, messages, knownCycles,
                              confirmedCycles, destroyed, pendingConfirmation,
                              sentTraces>>

\* An actor removes a cycle from its knownCycles when the cycle is no
\* longer a real cycle.
ForgetInvalidCycle(actor) ==
    /\ Alive(actor)
    /\ \E cycle \in knownCycles[actor] :
        /\ ~IsRealCycle(cycle)
        /\ knownCycles' = [knownCycles EXCEPT ![actor] = @ \ {cycle}]
        /\ UNCHANGED <<actors, epoch, inMem, messages, cycleCandidates,
                        confirmedCycles, destroyed, pendingConfirmation,
                        sentTraces>>

(**************************************************************************)
(* Multi-step confirmation                                                *)
(* The leader sends CONFIRM BLOCKED to each member. Each member checks    *)
(* local conditions and responds CONFIRMED or DENIED. The leader          *)
(* collects responses and either confirms the candidate, abandons it,     *)
(* or delegates leadership to a denier via a DELEGATE message.            *)
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
    /\ UNCHANGED <<actors, epoch, inMem, knownCycles, confirmedCycles,
                    destroyed, sentTraces>>

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
    /\ UNCHANGED <<actors, epoch, inMem, knownCycles, cycleCandidates,
                    confirmedCycles, destroyed, pendingConfirmation,
                    sentTraces>>

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
    /\ UNCHANGED <<actors, epoch, inMem, knownCycles, cycleCandidates,
                    confirmedCycles, destroyed, pendingConfirmation,
                    sentTraces>>

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
    /\ UNCHANGED <<actors, epoch, inMem, knownCycles, cycleCandidates,
                    destroyed, sentTraces>>

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
    /\ UNCHANGED <<actors, epoch, inMem, knownCycles, cycleCandidates,
                    confirmedCycles, destroyed, sentTraces>>

\* At least one member denied. The leader delegates leadership to one
\* of the deniers by sending a DELEGATE message with the candidate
\* updated to name the denier as the new leader. The leader consumes
\* all response messages and removes the pending confirmation.
DelegateLeadership(pending) ==
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
    \* Pick one denier as the new leader
    /\ \E denier \in pending.members :
        /\ \E resp \in messages :
            /\ resp.type = DeniedMsg
            /\ resp.to = pending.detectedBy
            /\ resp.from = denier
            /\ resp.candidate = pending
        /\ LET responses == {resp \in messages :
                   /\ resp.type \in {ConfirmedMsg, DeniedMsg}
                   /\ resp.to = pending.detectedBy
                   /\ resp.candidate = pending}
               newCandidate == [members |-> pending.members,
                                detectedBy |-> denier]
           IN /\ Cardinality(messages \ responses) < MaxMessages
              /\ messages' = (messages \ responses) \union {[
                     type |-> DelegateMsg,
                     to |-> denier,
                     candidate |-> newCandidate]}
    /\ pendingConfirmation' = pendingConfirmation \ {pending}
    /\ UNCHANGED <<actors, epoch, inMem, knownCycles, cycleCandidates,
                    confirmedCycles, destroyed, sentTraces>>

\* The new leader receives a DELEGATE message and adds the candidate
\* back to cycleCandidates for re-confirmation via SendConfirmBlocked.
ReceiveDelegate(msg) ==
    /\ msg \in messages
    /\ msg.type = DelegateMsg
    /\ Alive(msg.to)
    /\ cycleCandidates' = cycleCandidates \union {msg.candidate}
    /\ messages' = messages \ {msg}
    /\ UNCHANGED <<actors, epoch, inMem, knownCycles, confirmedCycles,
                    destroyed, pendingConfirmation, sentTraces>>

\* Confirmation fails: at least one member can't reach itself.
\* Garbage-collects stale candidates before they enter the confirmation
\* pipeline and waste message capacity.
DenyCandidate(candidate) ==
    /\ candidate \in cycleCandidates
    /\ ~IsRealCycle(candidate.members)
    /\ cycleCandidates' = cycleCandidates \ {candidate}
    /\ UNCHANGED <<actors, epoch, inMem, messages, knownCycles,
                    confirmedCycles, destroyed, pendingConfirmation,
                    sentTraces>>

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
    /\ UNCHANGED <<actors, epoch, inMem, knownCycles, cycleCandidates,
                    destroyed, pendingConfirmation, sentTraces>>

\* A member receives RELEASE and drops its references to other cycle
\* members. Increments epoch to invalidate stale traces; clears
\* sentTraces entries for the dropped connections and any chain
\* mentioning the member, closing the epoch saturation liveness gap.
ProcessRelease(msg) ==
    /\ msg \in messages
    /\ msg.type = ReleaseMsg
    /\ Alive(msg.to)
    /\ LET others == msg.confirmed.members \ {msg.to}
       IN /\ inMem' = [inMem EXCEPT ![msg.to] = @ \ others]
          /\ epoch' = [epoch EXCEPT ![msg.to] = IF @ < MaxEpoch
                                                 THEN @ + 1
                                                 ELSE @]
          /\ knownCycles' = [knownCycles EXCEPT ![msg.to] =
                                {c \in @ : c \cap others = {}}]
          /\ sentTraces' = {e \in sentTraces :
                               /\ ~(e.from = msg.to /\ e.to \in others)
                               /\ msg.to \notin VisitedIds(e.chain)}
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
    /\ knownCycles' = [knownCycles EXCEPT ![actor] = {}]
    \* Remove candidates involving this actor
    /\ cycleCandidates' = {c \in cycleCandidates :
                              actor \notin c.members}
    /\ confirmedCycles' = {c \in confirmedCycles :
                              actor \notin c.members}
    /\ pendingConfirmation' = {p \in pendingConfirmation :
                                  actor \notin p.members}
    /\ sentTraces' = {e \in sentTraces :
                         /\ e.from # actor
                         /\ e.to # actor
                         /\ actor \notin VisitedIds(e.chain)}
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
    \/ \E m \in messages : SuppressDuplicateTrace(m)
    \/ \E m \in messages : DetectCycle(m)
    \/ \E m \in messages : DiscardStaleTrace(m)
    \/ \E m \in messages : DetectSubCycle(m)
    \/ \E m \in messages : DiscardStaleSubCycle(m)
    \/ \E a \in actors : SendInformCycles(a)
    \/ \E m \in messages : ReceiveInformCycles(m)
    \/ \E a \in actors : ProposeComponent(a)
    \/ \E a \in actors : ForgetInvalidCycle(a)
    \/ \E c \in cycleCandidates : SendConfirmBlocked(c)
    \/ \E c \in cycleCandidates : DenyCandidate(c)
    \/ \E m \in messages : RespondConfirmed(m)
    \/ \E m \in messages : RespondDenied(m)
    \/ \E p \in pendingConfirmation : ConfirmationSucceeded(p)
    \/ \E p \in pendingConfirmation : ConfirmationFailed(p)
    \/ \E p \in pendingConfirmation : DelegateLeadership(p)
    \/ \E m \in messages : ReceiveDelegate(m)
    \/ \E c \in confirmedCycles : SendRelease(c)
    \/ \E m \in messages : ProcessRelease(m)
    \/ \E a \in actors : SelfReap(a)

Spec == Init /\ [][Next]_vars

SpecFC == InitFullyConnected /\ [][Next]_vars

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

\* LEADERSHIP VALIDITY: the leader of every cycle candidate is a member.
LeadershipValidity ==
    \A c \in cycleCandidates : c.detectedBy \in c.members

\* STATE CONSTRAINT: bounds total state complexity for tractable checking.
StateConstraint ==
    Cardinality(actors) + Cardinality(messages)
    + Cardinality(cycleCandidates) + Cardinality(confirmedCycles)
    + Cardinality(destroyed) + Cardinality(pendingConfirmation)
    + Cardinality(sentTraces) + KnownCyclesCount
    <= MaxActors + MaxMessages

=============================================================================
