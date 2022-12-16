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
} {
  always {
    willNotChange = (willNotChange implies StateChanges else none)
    willSpawnActorFrom = { a: Actor | willSpawnActorFrom[a] }
  }
}

// The stateChange predicate defines which changes are
// possible in the system, meant to be used as an
// "always" predicate by the main command being run.
pred stateChange {
  willNotChange
    or (one a: Actor | willSpawnActorFrom[a])
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

// TODO: Document.
pred willSpawnActorFrom[a: Actor] {
  one newActor: Actor' {
    newActor not in Actor
    Actor' = Actor + newActor
    newActor.isActive' = newActor

    one newConn: Connection' {
      newConn not in Connection
      Connection' = Connection + newConn

      newConn.from' = a
      newConn.to' = newActor
    }
  }

  // All existing actors and connections are unchanged.
  all existing: Actor | unchanged[existing]
  all existing: Connection | unchanged[existing]

  // Other entities are not changed in any way.
  unchangedTraces
}
