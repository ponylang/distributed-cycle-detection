module pony/distrib_cycle_detector/StateChanges

open pony/distrib_cycle_detector/Models

///
// The StateChanges sig is used for visually depicting
// which particular kind of state change is about to
// occur. That is, it is not part of the model. It just
// assists with understanding the flow of events.
//
// (However, note that the rest of this file defines
// the actual state change predicates, which certainly
// are part of the model, in that they define the valid
// state changes that are possible in the temporal model)
//
// Each field of the sig points to something when the
// corresponding predicate (of the same name) is true.
one sig StateChanges {
  var willNotChange: lone StateChanges,
  var willSpawnActorFrom: lone Actor,
  var willReduceMemOf: lone Actor,
} {
  always {
    willNotChange = (willNotChange implies StateChanges else none)
    willSpawnActorFrom = { a: Actor | willSpawnActorFrom[a] }
    willReduceMemOf = { a: Actor | willReduceMemOf[a] }
  }
}

// The stateChange predicate defines which changes are
// possible in the system, meant to be used as an
// "always" predicate by the main command being run.
pred stateChange {
  willNotChange
    or (one a: Actor | willSpawnActorFrom[a])
    or (one a: Actor | willReduceMemOf[a])
}

// It's always possible to pass a step that doesn't
// change anything in the program. Note that including
// an operation like this allows the program to loop
// (a requirement in Alloy 6 temporal analysis) in a
// kind of "no operation" state without changes.
pred willNotChange {
  unchangedActors
  unchangedConnections
  unchangedTraces
}

///
// An actor may spawn a new actor.

pred willSpawnActorFrom[spawnerActor: Actor] {
  one newActor: Actor' {
    newActor not in Actor
    Actor' = Actor + newActor
    newActor.isActive' = newActor
    no newActor.inMap'
    no newActor.inMem'

    // The new actor will be added to the actor map and memory of its spawner.
    // In the real world, it may not always stay in memory, but we account
    // for that in the model by allowing things to be dropped from memory
    // at any time using the willReduceMemOf predicate.
    spawnerActor.inMap' = spawnerActor.inMap + newActor
    spawnerActor.inMem' = spawnerActor.inMem + newActor

    // Everything else in the spawner actor is unchanged.
    unchangedExceptMapAndMem[spawnerActor]

    one newConn: Connection' {
      newConn not in Connection
      Connection' = Connection + newConn

      newConn.from' = spawnerActor
      newConn.to' = newActor
    }
  }

  // All existing actors other than the spawner actor are unchanged.
  all existing: (Actor - spawnerActor) | unchanged[existing]

  // All existing connections are unchanged.
  all existing: Connection | unchanged[existing]

  // Other entities are not changed in any way.
  unchangedTraces
}

///
// An actor may drop one or more actor references from its memory.

pred willReduceMemOf[actor: Actor] {
  // Everything that remains in memory must have already been in memory.
  actor.inMem' in actor.inMem

  // There are some actors which were in memory, but will not remain in memory.
  some a: Actor {
    a in actor.inMem
    a not in actor.inMem'
  }

  // Everything else about the actor is unchanged.
  actor.inMap' = actor.inMap
  unchangedExceptMapAndMem[actor]

  // All existing actors other than the spawner actor are unchanged.
  Actor' = Actor
  all existing: (Actor - actor) | unchanged[existing]

  // Other entities are not changed in any way.
  unchangedConnections
  unchangedTraces
}
