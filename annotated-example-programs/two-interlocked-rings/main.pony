actor Main
  new create(env: Env) =>
    // A => B => C => A
    // B => D => E => B

    let c = Single(None)
    let b = Double(c)
    let a = Single(b)
    c.next(a)

    let e = Single(None)
    let d = Single(e)
    e.next(b)
    b.next(d)

    // On startup
    // C gets create message
    // From start of scheduler run, C has received no new actor references. Do nothing.
    // B gets create message
    // From start of scheduler run, B has received a new actor reference (c). Start a "trace" run
    // // B sends C a "Trace" message of (B)
    // // B notes for connection C that it has sent (B)
    // // C has no references so the message ends there
    // A gets create message
    // From start of scheduler run, A has received a new actor reference (b). Start a "trace" run.
    // // A sends B a "Trace blocked" message of (A)
    // // B sees that for connection C it hasn't sent (A,B)
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
    // E gets create message
    // From start of scheduler run, E has received no new actor references. Do nothing.
     // D gets create message
    // From start of scheduler run, D has received a new actor reference (c). Start a "trace" run
    // // D sends E a "Trace" message of (D)
    // // D notes for connection E that it has sent (D)
    // // E has no references so the message ends there
    // E gets next message
    // From start of scheduler run, E has received a new actor reference (b). Starts a "trace" run.
    // // E sends B a TRACE message (E)
    // // E notes for connection B that it has sent (E)
    // // ABBREVIATED
    // // B sends (E,B) to to C
    // // C sends (E,B,C) to A
    // // A sends (E,B,C,A) to B
    // // B notes that it has received a TRACE that it is in
    // // B notes that the possible cycle E => B => C => A => B isn't complete.
    // // B isn't the start and end.
    // // B sees that (C,A,B) possible cycle is continuation if it sends to C so
    // //   it doesn't send to C and the message ends here
    // // The logic here needs to handle if somehow with a different program, this was the first cycle that B saw for B => C => A => B ******
    // B gets next message
    // From start of scheduler run, B has received a new actor reference (d). Starts a "trace" run.
    // // ABBREVIATED
    // // B sends D a TRACE message (B)
    // // B doesn't send C a TRACE message B as it sees it has already sent
    // // D sends E a TRACE message (B,D)
    // // E sends B a TRACE message (B,D,E)
    // // B sees that it has received a TRACE Blocked that it is in once.
    // // B notes that there is a possible cycle B => D => E => B
    // // B notes that it already is part of a possible cycle C => A => B => C
    // // B notes the existence of the larger cycle but doesn't inform others of larger cycle
    // // B informs D and E of the (B,D,E) possible cycle
    // // All members appear once so the lowest memory address member B becomes our cycle leader.
    // // B has an rc of 3 which is more than the number of times it appears (2) in the set so, it doesn't initiate a CONFIRMED BLOCK
    // Main.create ends
    // Main references end
    // E, D, C, B, and A all get release messages.
    // // On release message, E sees it isnt a cycle leader
    // // On release message, D sees it isnt a cycle leader
    // // On release message, C sees it isnt a cycle leader
    // // On release message, A sees it is a cycle leader
    // // A sees that it rc of 1 matches its number of occurrences in the set, that its queue is empty
    // // A sends CONFIRM BLOCKED to C and B for (C,B,A)
    // // B sees that it that its rc of 2 does match the number of occurrences for number of times it appears in cycles it is leader for and doesn't send any CONFIRM BLOCKED
    // // C receives CONFIRMED BLOCKED (C,B,A) has an rc of 1 and an empty queue. C sends CONFIRMED message to A
    // // B receives CONFIRMED BLOCKED (C,B,A) has has an rc of 2 which is more than the number of times it is in the cycle and sends a DENIED to A
    // // A received DENIED (C,A,B) from B. A sends a DELEGATE (C,B,A) to B. B is now the leader for (C,A,B)
    // // B receives DELEGATE (C,A,B).
    // // B sees that it has an rc of 2 that matches the number of occurences for its appearance in cycles that it is a leader for, and that its queue is empty.
    // // B sends CONFIRM BLOCKED (C,A,B) to A and C
    // // B sends CONFIRM BLOCKED (B,D,E) to D and E
    // // ABBREVIATED
    // // A sends CONFIRMED (C,A,B) to B
    // // C sends CONFIRMED (C,A,B) to C
    // // B notes that it has a match for 1 but not all cycles it is leader for and does nothing
    // // D sends CONFIRMED (B,D,E) to B
    // // E sends CONFIRMED (B,D,E) to B
    // // B sends RELEASE (C,A,B) to A and C
    // // B sends RELEASE (B,D,E) to D and E
    // releasing and gcing now happens

interface tag RingMember
  be next(next': RingMember)

actor Single
  var _next: (RingMember | None) = None

  new create(next': (RingMember | None)) =>
    _next = next'

  be next(next': RingMember) =>
    _next = next'

actor Double
  var _nexts: Array[RingMember] = _nexts.create()

  new create(next': (RingMember | None)) =>
    match next'
    | let n: RingMember => _nexts.push(n)
    end

  be next(next': RingMember) =>
    _nexts.push(next')
