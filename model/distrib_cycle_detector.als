module pony/distrib_cycle_detector

open pony/distrib_cycle_detector/Models
open pony/distrib_cycle_detector/StateChanges

fact { always stateChange }

one var sig Main in Actor {}
lone var sig A in Actor {}
lone var sig B in Actor {}
lone var sig C in Actor {}

fact "initial conditions" {
  Actor = Main
  Actor.isActive = Actor // (all initial actors begin as active)
  no Actor.inMap
  no Actor.inMem

  no AppMessage
  no Connection
  no Trace
}

run example for 4
pred example {
  ///
  // Desired state change sequence, if any.

  // some StateChanges.willSpawnActorFrom
  // after some StateChanges.willSpawnActorFrom
  // after after some StateChanges.willSendAppMessageFrom
  // after after after some StateChanges.willSpawnActorFrom

  ///
  // Expected intermediate state, if any.

  // Spawn a ring of 3 actors, all held by a Main actor.
  eventually {
    some A
    some B
    some C

    Connection.from = Main
    Connection.to = (A + B + C)

    // Main holds a reference to all three of A, B, C.
    // And each holds a reference to one of the others, in a ring.
    Main.inMem = (A + B + C)
    B.inMem = C
    A.inMem = B
    C.inMem = A
  }

  ///
  // Safety checks.
  // Enable one of these below to search for safety violations.

  // eventually not noDanglingActors
}
