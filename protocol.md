# Distributed cycle detection protocol

## Terminology

### ACTOR IDENTIFIER

An ACTOR IDENTIFIER is used to denote a given instance of an actor. Actor identifier are expected to be a combination of a "semi-unique identifier" for a
given actor such as a guid or the memory address the actor occupies.

ACTOR IDENTIFIERS are not guaranteed to be unique across the lifetime of an application but we do guarantee that two actors that exist at the same time will not share an identifier.

ACTOR IDENTIFIERS need to be sortable such that one can say "this identifier is less than this other one".

### TRACE ROUTE message

A special runtime message that is used to find cycles amongst actor relationships.

Cycles are found by sending TRACE ROUTE messages from actor to actor and using the results to find routes that circle back on themselves. Found cycles can be can be used to find larger connected components that share some members between different cycles. A connected component is composed of 1 or more cycles.

The same cycle can be found from multiple different starting points. For example, "A to B to C to A" is the same cycle as "C to A to B to C".

TRACE ROUTE messages are an ordered list of ACTOR IDENTIFIERS.

For example, if actor A initiates a trace to actor B then the TRACE ROUTE message is in the form of (A) where "A" is the ACTOR IDENTIFIER for the sending actor A.

### initiate a trace

The actor of creating a new trace message and sending it to another actor.

### outgoing reference/outgoing connection

A reference from one actor to another where the first actor is able to send messages to the other.

### passing along a TRACE ROUTE message

The act of an actor taking a received TRACE ROUTE message, augmenting it with the actor's own ACTOR INDENTIFIER and sending to an actor that is an outgoing connection.

## Protocol stages

There are several stages to finding and reaping strongly connected actor components.

### Finding cycles

If the actor has receives any new actor references for an actor it doesn't already have a reference to then it initiates a new TRACE ROUTE message to the newly received actor.

Upon receipt of a TRACE ROUTE message, an actor follows the TRACE ROUTE message handling steps.

### TRACE ROUTE message handling

Upon receipt of a trace route message, the following algorithm is applied:

If the actor receiving the message has no outgoing references, nothing is done. An actor will no outgoing messages can be attached to a cycle but can not by definition be part of a cycle itself as it has no outgoing connections.

If the actor receiving the message has outgoing connections, then we take the following possible steps:

The receiving actor examines the TRACE ROUTE message to see if its own ACTOR IDENTIFIER is in the ordered list of identifiers for the message. If the actor doesn't find its own identifier, then it passes along that message where passing along is handled as follows:

The message is augmented by adding the receiving actor's ACTOR IDENTIFIER to the end of identifier list. If the resulting trace message chain has already been sent from the receiving actor to the actor on the other end of the outgoing reference then, the receiving actor does not send the message. If it hasn't been sent, then receiving actor sends the TRACE ROUTE message to its outgoing connection and notes in state for that outgoing connection that it has sent the TRACE ROUTE message.

If when examining the TRACE ROUTE message for its own ACTOR IDENTIFIER, the actor found its own identifier, then a cycle has been found. There are two basic patterns of ACTOR IDENTIFIERS in a TRACE ROUTE message that should be seen. The first, is where an actor A receives a message where it is the first ACTOR IDENTIFIER in the message list. That is, it is the originating actor for the trace. In this case, the route in the received TRACE ROUTE message in the cycle in question. The other case, is slightly more complicated. It is possible that an actor that is connected to the cycle but isn't known to be part of the cycle originated the message. In that case, the "cycle" is a subset of a route in the TRACE ROUTE message. For example, if actor A received a message with (E,A,B) then the cycle is (A,B).

Cycles are independent of route. That is, cycle (A,B) is the same as cycle (B,A). What is important is the equivalence of members, not the order. With routes in a TRACE MESSAGE order matters for determing if to send, but it doesn't matter for noting "new cycles".

Upon finding a cycle, the actor that found the cycle checks its set of known cycles to see if the newly found cycle is the same as or a subset of any known cycle. If the cycle is known then no further processing happens for the TRACE ROUTE message.

When an actor finds a new cycle, it adds it to its set of known cycles. Upon finding a new cycle, the finding actor informs all the actors in connected component of the full set of cycles that represents the connected component. That is, each actor that appears as a member of any known cycle is informed of all known cycles that make up the larger connected component.

## Leadership determination

- Leadership for a connected component is initially determined locally
- Each time a connected component has a state change, leadership is redetermined locally
- Locally the only determination is "I am the leader" or "I am not the leader"
- A leader can delegate leadership to a different member of the connected component
- The leader is the actor that appears in the connected component most often
- If more than 1 actor has the same number of appearances, the actor with the lowest ACTOR IDENTIFIER is the leader

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

## OLD NOTES, NEED ORGANIZATION

- If an actor gc releases (0) another actor, any "connection" info about messages sent is reset in case a new actor gets the same id.
- If an actor gc releases (0) another actor that is part of a possible cycle, then it should remove the cycle from its list of cycles and inform all members of the cycle set that the cycle is no longer valid.
- Each "connection" that was part of a removed cycle probably needs to be "reset"
- Each "connection" probably needs a epoch of some type. (tbd)
- Each message probably needs to include the connection epoch (tbd)
