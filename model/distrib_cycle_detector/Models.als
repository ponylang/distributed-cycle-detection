module pony/distrib_cycle_detector/Models

///
// An Actor is an entity that can send and receive messages.

var sig Actor {
  var isActive: lone Actor,
  var isDestroyed: lone Actor,

  // This is the set of actor references currently held in memory of the actor.
  // This includes both stack memory (local variables) and heap memory (fields).
  // At the end of a behavior, there is no more stack memory - only heap memory.
  // But we make no distinction between the two here in the model; it's one set.
  var inMem: set Actor,

  // This is the "actor map" that is within each actor in the existing runtime.
  // It is always a superset of the actor references that are in memory.
  var inMap: set Actor,
}

fact "an actor always has exactly protocol status pointing to itself" {
  always all a: Actor {
    a = (a.isActive + a.isDestroyed)
    disj[a.isActive, a.isDestroyed]
  }
}

pred unchanged[a: Actor] {
  a in Actor
  a in Actor'
  a.isActive' = a.isActive
  a.isDestroyed' = a.isDestroyed
  a.inMap' = a.inMap
  a.inMem' = a.inMem
}

pred unchangedExceptMapAndMem[a: Actor] {
  a in Actor
  a in Actor'
  a.isActive' = a.isActive
  a.isDestroyed' = a.isDestroyed
}

pred unchangedActors {
  Actor' = Actor
  all a: Actor | unchanged[a]
}

fun enqueueTarget[a: Actor]: (Actor + Message) {
  // Find the item in the Actor's queue that has nothing enqueued behind it.
  // If the Actor has no Messages enqueued, this returns the Actor itself.
  // In theory this could return more than one item (if the Actor had multiple
  // or diverging queues) but because of the rest of the logic in the model,
  // we don't expect that to happen
  { t: a.*~enqueued | no t.~enqueued }
}

///
// A Message goes into the FIFO message queue of an Actor.

abstract var sig Message {
  var enqueued: one (Actor + Message)
}

pred unchangedMessages {
  unchangedAppMessages
}

pred sendTo[m: Message', a: Actor] {
  // Put the message at the end of the Actor's queue.
  m.enqueued' = a.enqueueTarget
}

pred receiveNow[message: Message] {
  // Messages are a FIFO queue, so we can only process this message if it is
  // enqueued to the Actor rather than enqueued "behind" another Message.
  message.enqueued in Actor

  // The next enqueued message becomes enqueued directly to the Actor,
  // ready to be received next by the Actor.
  message.enqueued.~enqueued' = message.~enqueued
  unchangedExceptEnqueued[message.~enqueued]

  // The message gets removed as it is received.
  message not in Message'
  Message' = Message - message

  // All other messages are unchanged.
  all existing: (Message - message - message.~enqueued) | unchanged[existing]
}


///
// An AppMessage carries application-level data from one Actor to another.

var sig AppMessage extends Message {
  // This is the set of actor references that are in the message arguments.
  // For the purpose of this model we ignore the all other data in the message.
  var inArgs: set Actor,
}

pred unchanged[m: AppMessage] {
  m.unchangedExceptEnqueued
  m.enqueued' = m.enqueued
}

pred unchangedExceptEnqueued[m: AppMessage] {
  m in AppMessage
  m in AppMessage'
  m.inArgs' = m.inArgs
}

pred unchangedAppMessages {
  AppMessage' = AppMessage
  all m: AppMessage | unchanged[m]
}

///
// A Connection represents one Actor's knowledge about another Actor.

var sig Connection {
  var from: one Actor,
  var to: one Actor,
}

pred unchanged[c: Connection] {
  c in Connection
  c in Connection'
  c.from' = c.from
  c.to' = c.to
}

pred unchangedConnections {
  Connection' = Connection
  all c: Connection | unchanged[c]
}

///
// Traces indicate Actor message paths in a Connection.

var sig Trace {
  var conn: one Connection,
}

pred unchanged[t: Trace] {
  t in Trace
  t in Trace'
  t.conn' = t.conn
}

pred unchangedTraces {
  Trace' = Trace
  all t: Trace | unchanged[t]
}

///
// TraceElements are items in the linked-list of a Trace.

var sig TraceElement {
  var prior: one (TraceElement + Trace),
}

fact "trace elements each form a lined list leading to a Trace" {
  always {
    // Every TraceElement must be chained from a Trace.
    all e: TraceElement | one t: Trace | t in e.^prior

    // Every Trace and TraceElement have at most one TraceElement chained to it.
    all t: Trace | lone t.~prior
    all e: TraceElement | lone e.~prior
  }
}
