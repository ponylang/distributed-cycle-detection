module pony/distrib_cycle_detector

open pony/distrib_cycle_detector/Models
open pony/distrib_cycle_detector/StateChanges

fact { always stateChange }

run example for 8
pred example {
  ///
  // Initial constraints

  #Actor = 1
  Actor.isActive = Actor // (all initial actors begin as active)
  no Connection
  no Trace

  ///
  // Desired state change sequence, if any.

  some StateChanges.willSpawnActorFrom
  after some StateChanges.willSpawnActorFrom
  after after some StateChanges.willSpawnActorFrom
  after after after some StateChanges.willSpawnActorFrom

  ///
  // Safety checks.
  // Enable one of these below to search for safety violations.

  // eventually not noDanglingActors
}
