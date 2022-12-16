actor Main
  new create(env: Env) =>
    // A => B => C => A
    let c = RingMember(None)
    let b = RingMember(c)
    let a = RingMember(b)
    c.next(a)

    // On startup
    // A is referenced by Main
    // B is referenced by Main
    // C is referenced by Main
    // all three have rc 1
    // C is referenced by B
    // C has rc of 2
    // B is referenced by A
    // B has rc of 2

    // C gets create message.
    // From start of scheduler run, C has received no new actor references. Do nothing.
    // B gets create message.
    // From start of scheduler run, B has received a new actor reference (c). Start a "trace" run
    // // B sends C a "Trace" message of (B)
    // // B notes for connection C that it has sent (B)
    // // C has no references so the trace ends there
    // A gets create message
    // From start of scheduler run, A has received a new actor reference (b). Start a "trace" run.
    // // A sends B a "Trace" message of (A)
    // // B sees that for connection C is hasn't sent (A,B)
    // // B sends (A,B) to C
    // // B notes that for Connection C that it has sent (B) and (A,B)
    // // C has not references so the trace ends there
    // C gets next message
    // From start of scheduler run, C has received a new actor reference (a). Starts a "trace" run.
    // // C sends A a "Trace" message of (C)
    // // A sees that on connection B it hasn't sent message (C,A)
    // // A sends (C,A) to connection B
    // // A notes for connection B that it has sent (A) and (C,A)
    // // B see that for connection C that it hasn't sent (C,A,B)
    // // B sends (C,A,B) to C
    // // B notes that for connection C it has sent (B), (A,B), (C,A,B)
    // A is referenced by C
    // A has rc of 2
   // // C sees that it has received a TRACE Blocked that it is in once.
    // // C notes that there is a possible cycle C => A => B => C
    // // C informs A and B of (C,A,B) as possible cycle
    // // All members appear once so the lowest memory address member A becomes our cycle leader.
    // // A has an rc of 2 which is more than the number of times it appears in the set so, it doesn't initiate a CONFIRMED BLOCK
    // Main.create ends
    // Main references end
    // C, B, and A all get release messages.
    // C has an rc of 1
    // B has an rc of 1
    // A has an rc of 1
    // // At the end of scheduler run, C, B, A will check to see if there are any cycles to release.
    // // C and B see that they aren't a cycle leader
    // // A is cycle leader.
    // // A sees that it rc of 1 matches its number of occurrences in the set, and that its queue is empty
    // // A sends CONFIRM BLOCKED to C and B for (C,B,A)
    // // C and B both have rc of 1, empty queues, and all members of the cycle set are in their respective actor maps. C and B both send CONFIRMED messages to A
    // // A receives both confirmed messages.
    // // A sends RELEASE (C,A,B) to B and C
    // // A does GC release of all members of the set in its actormap
    // // B receives RELEASE (C,A,B) and does release of all members of the set in its actormap
    // // C receives RELEASE (C,A,B) and does release of all members of the set in its actormap
    // // All of A,B,C end up with rc of 0 and empty queue and gc themselves.

actor RingMember
  var _next: (RingMember | None) = None

  new create(next': (RingMember | None)) =>
    _next = next'

  be next(next': RingMember) =>
    _next = next'
