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
  var willSendAppMessageFrom: lone Actor,
  var willReceiveAppMessage: lone AppMessage,
} {
  always {
    willNotChange = (willNotChange implies StateChanges else none)
    willSpawnActorFrom = { a: Actor | willSpawnActorFrom[a] }
    willReduceMemOf = { a: Actor | willReduceMemOf[a] }
    willSendAppMessageFrom = { a: Actor | willSendAppMessageFrom[a] }
    willReceiveAppMessage = { m: AppMessage | willReceiveAppMessage[m] }
  }
}

// The stateChange predicate defines which changes are
// possible in the system, meant to be used as an
// "always" predicate by the main command being run.
pred stateChange {
  willNotChange
    or (one a: Actor | willSpawnActorFrom[a])
    or (one a: Actor | willReduceMemOf[a])
    or (one a: Actor | willSendAppMessageFrom[a])
    or (one m: AppMessage | willReceiveAppMessage[m])
}

// It's always possible to pass a step that doesn't
// change anything in the program. Note that including
// an operation like this allows the program to loop
// (a requirement in Alloy 6 temporal analysis) in a
// kind of "no operation" state without changes.
pred willNotChange {
  unchangedActors
  unchangedMessages
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
  unchangedMessages
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
  unchangedMessages
  unchangedConnections
  unchangedTraces
}

///
// An actor may send an application message containing one or more actor references.

pred willSendAppMessageFrom[senderActor: Actor] {
  one newMessage: AppMessage' {
    newMessage not in AppMessage
    AppMessage' = AppMessage + newMessage

    // All actor references in the message must be from the sender's memory,
    // or it must be a reference to the sending actor itself.
    newMessage.inArgs' in (senderActor.inMem + senderActor)

    // Send it to an Actor.
    one a: Actor | newMessage.sendTo[a]
  }

  // All existing app messages are unchanged.
  all existing: AppMessage | unchanged[existing]

  // Other entities are not changed in any way.
  unchangedActors
  unchangedConnections
  unchangedTraces
}

///
// An actor may receive an application message to obtain its actor references.

pred willReceiveAppMessage[message: AppMessage] {
  message.receiveNow

  one receiverActor: Actor {
    message.enqueued = receiverActor

    // The receiving actor accepts the actor references into its actor map,
    // and into its memory (excluding itself if it was in the arguments).
    receiverActor.inMap' = receiverActor.inMap + message.inArgs - receiverActor
    receiverActor.inMem' = receiverActor.inMem + message.inArgs - receiverActor

    // The receiving actor is otherwise unchanged.
    unchangedExceptMapAndMem[receiverActor]
  }

  // All existing actors (other than the receiving one) are unchanged.
  Actor' = Actor
  all existing: (Actor - message.enqueued) | unchanged[existing]

  // Other entities are not changed in any way.
  unchangedConnections
  unchangedTraces
}
