## Finding cycles

- During a scheduler run, if an actor has received a new actor reference, it will check to see if it should start a trace.
- Trace messages are in the form (ACTOR,ACTOR,etc) where each actor in the trace adds itself to the trace list. If actor A started a trace the message would be (A). If it sends to actor B that sends along, B would send (A,B)
- A trace will be sent on each reference connection if it hasn't sent the same message on that connection previously
- If a message arrives back at the actor that originated it, then it is a "possible cycle"
- TRACE message sending ends when a possible cycle is found
- If an actor receives a release for an actor, any "connection" info about messages sent is reset in case a new actor gets the same id.
- If an actor receives a release for an actor that is part of a possible cycle, then it should remove the cycle from its list of cycles and inform all members of the cycle set that the cycle is no longer valid.
- Each "connection" that was part of a removed cycle probably needs to be "reset"
- Each "connection" probably needs a epoch of some type. (tbd)
- Each message probably needs to include the connection epoch (tbd)

## Leadership determination

- Leadership for a cycle is initially determined locally
- A leader can delegate leadership to a different member of the possible cycle
- If two cycles are merged together, a new leadership "election" happens.
- The leader is the actor that appears in the cycle most often
- If more than 1 actor has the same number of appearances, the actor with the lowest memory address is the leader

## Cycle confirmation

- If at the end of any scheduler run, the leader of a cycle has an empty queue and rc equal to the number of times it appears in the cycle then it will initiate a CONFIRM BLOCKED.
- CONFIRM BLOCKED involves send a message from the leader to each member of the cycle with the cycle to confirm
- If receiver has an empty queue, an rc equal to the number of times it is in the cycle then it will send a CONFIRMED message to the leader. If any of the checks fails, it will send a DENIED to the leader.
- If any actor sends back DENIED, then the leader will make the first DENIED sender the new leader via a DELEGATE message.
- If all members send back CONFIRMED then the cycle is confirmed

## Cycle destruction

- Leader sends RELEASE to all other members of the cycle set
- Leader does a GC release of any member of the set that is in its actor map
- Each member responds to RELEASE by doing a GC release of any member of the set that is in its actor map
