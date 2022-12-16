actor Main
  new create(env: Env) =>
    // A => B => C => A
    // C => _stub
    let c = RingMember(None)
    let b = RingMember(c)
    let a = RingMember(b)
    c.next(a)
    c.create_stub()

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
    // C is blocked.
    // C has no outgoing references and doesn't send to anyone
    // B gets create message.
    // B is blocked
    // // B sends C a "Trace blocked" message of (B)
    // // B notes for connection C that it has sent (B)
    // // C has no references so the message ends there
    // A gets create message
    // A is blocked
    // // A sends B a "Trace blocked" message of (A)
    // // B sees that for connection C is hasn't sent (A,B)
    // // B sends (A,B) to C
    // // B notes that for Connection C that it has sent (B) and (A,B)
    // // C has no references so the message ends there
    // C gets next message
    // A is referenced by C
    // A has rc of 2
    // C gets create stub
    // _stub gets created. Has Rc of 1.
    // C is blocked
    // // C sends _stub a "Trace blocked" message of (C)
    // // _stub has no refences so the message ends there
    // // C sends A a "Trace blocked" message of (C)
    // // A sees that connection B it hasn't sent message (C,A)
    // // A sends (C,A) to connection B
    // // A notes for connection B that it has sent (A) and (C,A)
    // // B see that for connection C that it hasn't sent (C,A,B)
    // // B sends (C,A,B) to C
    // // B notes that for connection C it has sent (B), (A,B), (C,A,B)
    // // C sees that it has received a TRACE Blocked that it is in once.
    // // C notes that there is a possible cycle C => A => B => C
    // // C informs A and B of (C,A,B) possible cycle
    // // C, B, A all have rc of 2 and they are in the possible cycle once so there's nothing else to do right now
    // Main.create ends
    // Main references end
    // C, B, and A all get release messages.
    // C has an rc of 1
    // B has an rc of 1
    // A has an rc of 1
    // // On release message, C checks to see if any possible cycle it knows about it eligible to be collected
    // // On release message, B checks to see if any possible cycle it knows about it eligible to be collected
    // // On release message, A checks to see if any possible cycle it knows about it eligible to be collected
    // // A, B, C are all blocked
    // // A, B, C all have rc 1 of 1 which is equal to times in (C,A,B) possible cycle so we know it probably is a cycle
    // // We need to determine if everyone is still blocked
    // // C is start of possible cycle.
    // // C still knows about A.
    // // C sends CONF to A, B "confirm blocked cycle" (C,A,B)
    // // A has rc of 1 and is blocked and still knows about B. Send ACK (C,A,B) to C
    // // B has rc of 1 and is blocked and still knows about C. Send ACK (C,A,B) to C
    // // C sends RELEASE (C,A,B) to A and B
    // C sends gc release of A
    // A sends gc release of B
    // B sends gc release of C
    // A gets gc release. Rc of 0. Blocked. GC's itself.
    // B gets gc release. Rc of 0. Blocked. GC's itself.
    // C gets gc release. Rc of 0. Blocked. GC's itself.
    // _stub gets gc release. Rc of 0. Blocked. GC's itself.

actor RingMember
  var _next: (RingMember | None) = None
  var _stub: (Stub | None) = None

  new create(next': (RingMember | None)) =>
    _next = next'

  be next(next': RingMember) =>
    _next = next'

  be create_stub() =>
    match _stub
    | None => _stub = Stub
    end

actor Stub
  new create() => None
