module pony/distrib_cycle_detector/Models

///
// An Actor is an entity that can send and receive messages.

var sig Actor {
  var isActive: lone Actor,
  var isDestroyed: lone Actor,
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
}

pred unchangedActors {
  Actor' = Actor
  all a: Actor | unchanged[a]
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
