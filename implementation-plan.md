# Distributed cycle detection — implementation plan

## Decisions

- **Trigger policy**: on-block (zero protocol overhead during active execution)
- **Runtime flag**: single `--ponycycledetector` with values `classic` (default), `none`, `distributed`
- **Actor identifier**: actor address (`pony_actor_t*`)
- **Trace deduplication**: unbounded initially
- **The three modes coexist**: centralized CD (`classic`), no CD (`none`), distributed protocol (`distributed`)

## Divergences from current behavior

1. **`--ponynoblock` removed.** Replaced by `--ponycycledetector none`. This is a breaking change for any Pony program that passes `--ponynoblock` on the command line or sets `ponynoblock = true` in `@runtime_override_defaults`.

2. **`RuntimeOptions.ponynoblock` field removed.** Replaced by `RuntimeOptions.ponycycledetector` (a `U8` encoding the mode enum). Programs using `@runtime_override_defaults` to set `ponynoblock` must change.

3. **`--ponycdinterval` scoped to classic mode.** The option still exists but is ignored when the mode is not `classic`. Passing it with `--ponycycledetector none` or `--ponycycledetector distributed` prints a warning and continues.

4. **Non-deterministic leadership.** Actor addresses determine the leader tiebreaker. Which actor leads a component varies across runs due to ASLR. This does not affect safety — the formal model verified that leadership determination by any consistent ordering is safe. Under `USE_SYSTEMATIC_TESTING`, `systematic_testing_id` is used instead for reproducibility.

5. **New per-actor state.** Every actor in `distributed` mode carries a pointer to distributed CD state (`distcd_t*`). This is NULL in `classic` and `none` modes. The pointer (8 bytes) fits within existing tail padding in `pony_actor_t` — the struct has 16 bytes of tail padding (from `alignas(64)` on `heap` rounding `sizeof` to 320, while content ends at 304). Adding the pointer after `gc` does not change `sizeof(pony_actor_t)`.

## Architecture overview

In `distributed` mode:
- No cycle detector actor is created (`ponyint_cycle_create()` is skipped).
- Actors with `rc=0` and empty queue self-reap (same behavior as `none` mode).
- Actors detect cycles among themselves via TRACE ROUTE messages and coordinate destruction via the confirmation protocol.
- All protocol actions happen during an actor's scheduler run, triggered by message receipt or by the actor blocking.
- The delta mechanism (`gc.delta`) is not used — actors don't report to a central actor.

## Data structures

### Per-actor distributed CD state

```c
typedef struct trace_entry_t {
  pony_actor_t* actor;
  uint32_t epoch;
} trace_entry_t;

typedef struct trace_chain_t {
  trace_entry_t* entries;  // dynamic array of (actor, epoch) pairs
  size_t count;            // number of entries
} trace_chain_t;

// A cycle is a set of actor pointers (stored sorted for equality comparison)
typedef struct cycle_t {
  pony_actor_t** members;  // sorted array
  size_t count;
} cycle_t;

// Per-connection trace history (which chains have been sent on this connection)
// Keyed by the hash of chain content
DECLARE_HASHMAP(ponyint_traceset, traceset_t, trace_chain_t);

// Set of known cycles
DECLARE_HASHMAP(ponyint_cycleset, cycleset_t, cycle_t);

// Candidate record for confirmation
typedef struct distcd_candidate_t {
  pony_actor_t** members;  // sorted member set
  size_t count;
  pony_actor_t* leader;
  size_t confirmed_count;  // responses received
  size_t denied_count;
  pony_actor_t* first_denier;
} distcd_candidate_t;

// Per-connection trace history map: target actor -> traceset
DECLARE_HASHMAP(ponyint_conn_traces, conn_traces_t, conn_trace_entry_t);

typedef struct conn_trace_entry_t {
  pony_actor_t* target;
  traceset_t traces;
} conn_trace_entry_t;

typedef struct distcd_t {
  uint32_t epoch;
  cycleset_t known_cycles;
  conn_traces_t conn_traces;
  // Active confirmation (as leader), NULL if not leading
  distcd_candidate_t* leading_candidate;
  // Active confirmation (as member) — candidate we're participating in
  distcd_candidate_t* member_candidate;
} distcd_t;
```

Hash/comparison functions needed:
- **trace_chain_t**: hash over the full sequence of (actor, epoch) pairs; equality is element-wise comparison of the arrays.
- **cycle_t**: hash over the sorted member array; equality is element-wise comparison.
- **conn_trace_entry_t**: hash and equality on the `target` pointer (it's the map key).

### Message types

New system message IDs (shift `ACTORMSG_APPLICATION_START` down to make room):

```c
#define ACTORMSG_APPLICATION_START (UINT32_MAX - 16)
#define ACTORMSG_DIST_TRACE       (UINT32_MAX - 15)  // TRACE ROUTE
#define ACTORMSG_DIST_INFORM      (UINT32_MAX - 14)  // INFORM CYCLES
#define ACTORMSG_DIST_CONFIRM     (UINT32_MAX - 13)  // CONFIRM BLOCKED
#define ACTORMSG_DIST_CONFIRMED   (UINT32_MAX - 12)  // CONFIRMED
#define ACTORMSG_DIST_DENIED      (UINT32_MAX - 11)  // DENIED
#define ACTORMSG_DIST_DELEGATE    (UINT32_MAX - 10)  // DELEGATE
#define ACTORMSG_DIST_DESTROY     (UINT32_MAX - 9)   // protocol's RELEASE (named DESTROY to avoid confusion with ACTORMSG_RELEASE which is the GC/ORCA release)
// Existing centralized CD messages stay at their current IDs
#define ACTORMSG_CHECKBLOCKED     (UINT32_MAX - 8)
// ... rest unchanged
```

**Invariant**: all `ACTORMSG_DIST_*` IDs must be above `ACTORMSG_APPLICATION_START`. The `has_app_msg` flag in `ponyint_send` (actor.c) is computed as `id <= ACTORMSG_APPLICATION_START` — if a distributed message ID falls at or below that boundary, it would be misclassified as an application message and trigger muting/backpressure. Add a compile-time `static_assert` that `ACTORMSG_DIST_DESTROY > ACTORMSG_APPLICATION_START` (the lowest DIST ID being above the boundary implies all are).

Message structs for the protocol messages:

```c
// TRACE ROUTE: carries a variable-length chain
typedef struct dist_trace_msg_t {
  pony_msg_t msg;
  trace_chain_t* chain;  // heap-allocated, recipient takes ownership
} dist_trace_msg_t;

// INFORM CYCLES: carries a set of cycles
typedef struct dist_inform_msg_t {
  pony_msg_t msg;
  cycle_t* cycles;  // array of cycles
  size_t count;
} dist_inform_msg_t;

// CONFIRM BLOCKED, CONFIRMED, DENIED, DELEGATE, DESTROY:
// all carry a candidate record identifying the component
typedef struct dist_candidate_msg_t {
  pony_msg_t msg;
  pony_actor_t** members;  // sorted member set
  size_t member_count;
  pony_actor_t* leader;
} dist_candidate_msg_t;
```

**Allocation and send path**: all protocol message structs and their payloads (`trace_chain_t`, `cycle_t` arrays, member arrays) are allocated with `ponyint_pool_alloc_size()` and freed with `ponyint_pool_free_size()`. The recipient takes ownership of heap-allocated payloads (e.g., `dist_trace_msg_t.chain`) and frees them with the pool allocator after processing. No `malloc`/`free` — all allocations go through the pool allocator for consistency with the runtime's memory model.

The existing convenience functions (`ponyint_sendp`, `ponyint_sendi`) handle fixed single-payload layouts that don't match the DIST message structs. Add convenience functions for the DIST message shapes in `distcd.c`:
- `distcd_send_trace(pony_ctx_t* ctx, pony_actor_t* to, trace_chain_t* chain)` — allocates `dist_trace_msg_t`, sets chain, sends with `has_app_msg = false`
- `distcd_send_inform(pony_ctx_t* ctx, pony_actor_t* to, cycle_t* cycles, size_t count)` — allocates `dist_inform_msg_t`, sends
- `distcd_send_candidate(pony_ctx_t* ctx, pony_actor_t* to, uint32_t msg_id, pony_actor_t** members, size_t member_count, pony_actor_t* leader)` — allocates `dist_candidate_msg_t`, sends. Used for CONFIRM, CONFIRMED, DENIED, DELEGATE, and DESTROY (same struct, different message ID).

Each allocates via `pony_alloc_msg(POOL_INDEX(sizeof(dist_*_msg_t)), msg_id)`, populates the fields, and calls `pony_sendv(ctx, to, &msg->msg, &msg->msg, false)`.

**`handle_message()` routing**: all seven `ACTORMSG_DIST_*` message types need explicit cases in `handle_message()` (actor.c). Each case:
- Includes `pony_assert(!ponyint_is_cycle(actor))` — these are regular actor messages, not cycle detector messages.
- Does NOT call `maybe_unblock()` — distributed protocol messages are system messages that must not clear the BLOCKED flag or dispatch to the actor's Pony-level behavior.
- Calls the appropriate `distcd_handle_*()` function.
- Under `USE_RUNTIMESTATS_MESSAGES`, decrements memory stats following the existing pattern (e.g., actor.c:323-326): `mem_used_inflight_messages -= sizeof(dist_*_msg_t)` and `mem_allocated_inflight_messages -= POOL_ALLOC_SIZE(dist_*_msg_t)`. The `mem_used` tracks logical size, `mem_allocated` tracks actual pool allocation size.
- Returns `false` (not an application message).

## Implementation steps

### Step 1: Runtime mode flag

**Files changed:** `src/libponyrt/sched/start.c`, `src/libponyrt/actor/actor.h`, `src/libponyrt/actor/actor.c`, `src/libponyrt/options/options.h`, `src/libponyrt/gc/cycle.c`, `src/libponyrt/gc/gc.c`, `src/libponyrt/gc/actormap.c`, `src/libponyrt/sched/scheduler.c`, `src/libponyrt/tracing/tracing.c`, `packages/builtin/runtime_options.pony`, new file `packages/builtin/cycle_detector.pony`

Add a cycle detection mode enum:
```c
typedef enum cd_mode_t {
  CD_MODE_CLASSIC = 0,
  CD_MODE_NONE = 1,
  CD_MODE_DISTRIBUTED = 2,
} cd_mode_t;
```

Changes:
- `options_t`: replace `bool noblock` with `uint8_t cd_mode` at the same position. `bool` and `uint8_t` are both 1 byte, so the struct layout is preserved — the subsequent fields (`pin`, `pinasio`, `pinpat`, etc.) stay at the same offsets.
- `RuntimeOptions`: replace `ponynoblock: Bool = false` with `ponycycledetector: U8 = 0` at the same position. `Bool` and `U8` are both 1 byte in Pony — the byte-for-byte match with `options_t` is maintained.
- Add `packages/builtin/cycle_detector.pony` with named constants so users don't write raw numbers:
  ```pony
  primitive CycleDetector
    fun classic(): U8 => 0
    fun none(): U8 => 1
    fun distributed(): U8 => 2
  ```
  Usage: `rto.ponycycledetector = CycleDetector.none()`
- `parse_opts()`: validate the mode value — values outside `{0, 1, 2}` are rejected with an error message and program exit, the same way other invalid option values are handled.
- `args[]`: remove `{"ponynoblock", ...}`, add `{"ponycycledetector", 0, OPT_ARG_REQUIRED, OPT_CDMODE}`
- `parse_opts`: parse the string value (`"classic"`, `"none"`, `"distributed"`) into the enum
- Replace `static bool actor_noblock` with `static cd_mode_t cd_mode = CD_MODE_CLASSIC`
- Replace `ponyint_actor_setnoblock(bool)` / `ponyint_actor_getnoblock()` with `ponyint_actor_set_cd_mode(cd_mode_t)` / `ponyint_actor_get_cd_mode()`
- `pony_init()`: skip `ponyint_cycle_create()` when mode is not `CD_MODE_CLASSIC`
- Guard `ponyint_cycle_terminate()` in `scheduler.c:1350` on `cd_mode == CD_MODE_CLASSIC`. Without this guard, the terminate path dereferences the `cycle_detector` pointer — which is NULL when the CD was never created — crashing at `ponyint_become(ctx, cycle_detector)`.
- Guard `ponyint_cycle_check_blocked()` calls in scheduler.c (lines 667, 865, 1018). These are already gated on `!ponyint_actor_getnoblock()` — change the guard to `ponyint_actor_get_cd_mode() == CD_MODE_CLASSIC`. The function dereferences `cycle_detector` (casts to `detector_t*` and reads `d->detect_interval`), so calling it with a NULL `cycle_detector` crashes.
- Guard `ponyint_is_cycle()` in scheduler.c:885 — this is already NULL-safe (compares `actor == cycle_detector`, returns false when NULL), but for clarity, the encompassing `ponyint_cycle_check_blocked` guard already prevents reaching this path.
- `actormap.c:ponyint_actormap_sweep()` — takes `bool actor_noblock` as a parameter (not the global getter). Change the parameter to `uint8_t cd_mode` and update the check at line 214 from `if(!actor_noblock)` to `if(cd_mode == CD_MODE_CLASSIC)`. Update all callers in gc.c (lines 591, 594, 764, 767) to pass the mode.
- `tracing.c:get_actor_behavior_string()` — has a switch on message IDs. Add cases for all `ACTORMSG_DIST_*` IDs returning descriptive strings (e.g., `"DIST_TRACE"`, `"DIST_CONFIRM"`). These IDs exist in the header even though the distributed mode logic doesn't land until PR 2; the tracing switch should handle them from the start.
- Update `PONYRT_HELP` in options.h
- Update the `sugar.c` default `@runtime_override_defaults` if needed (currently a no-op, should stay no-op since default is set in C)

The guard logic changes from:
- `actor_noblock` → `cd_mode != CD_MODE_CLASSIC` (for skipping delta/CD interaction)
- `!actor_noblock` → `cd_mode == CD_MODE_CLASSIC` (for CD-specific paths)
- `actor_noblock` in self-reap → `cd_mode != CD_MODE_CLASSIC` (both `none` and `distributed` self-reap rc=0 actors)

**Invariant to document in actor.c**: `maybe_unblock()` (lines 291-302) calls `ponyint_cycle_unblock()` unconditionally when `ACTOR_FLAG_BLOCKED_SENT` is set. In non-classic modes, `BLOCKED_SENT` is never set — all paths to `send_block` are gated on classic mode (the scheduler's `ponyint_cycle_check_blocked` calls, and the actor's CD-contact path at line 734). Add a comment at `maybe_unblock` stating this invariant so a future reader knows why the unconditional call is safe.

Callsites to update (from grep of `actor_noblock` and `ponyint_actor_getnoblock`):
- `actor.c:545,565` — RC_OVER_ZERO_SEEN tracking: skip when not classic
- `actor.c:656` — self-reap for rc=0: enable when not classic
- `actor.c:728,734` — forced GC and CD contact: only when classic
- `gc.c:87,106,127,526` — delta updates gated on noblock: only when classic
- `gc.c:591,594,764,767` — `actormap_sweep` calls passing noblock: pass cd_mode
- `scheduler.c:667,865,1018` — `cycle_check_blocked` calls: only when classic
- `scheduler.c:1350` — `cycle_terminate`: only when classic
- `actormap.c:159,162,214` — sweep parameter and check: change to cd_mode

**Tests:**
- All existing `ci-core` tests pass (default mode is `classic`, so no behavioral change).
- Full-program test that exercises `--ponycycledetector none` and verifies it behaves like the old `--ponynoblock` (actors self-reap, no CD).
- Full-program test that exercises `--ponycycledetector distributed` with rc=0 actors — verify they self-reap and the program exits cleanly.
- Test that an invalid value (e.g., `--ponycycledetector bogus`) produces an error.

**How to verify:** Build debug, run `ctest --preset debug -L ci-core`. All existing tests should pass with the default (`classic`) mode. Run the new full-program tests.

### Step 2: Per-actor distributed CD state

**Files changed:** `src/libponyrt/actor/actor.h`, `src/libponyrt/actor/actor.c`, new file `src/libponyrt/gc/distcd.h`, new file `src/libponyrt/gc/distcd.c`, `CMakeLists.txt` (to add new source files)

Add `distcd_t* distcd` to `pony_actor_t` after `gc_t gc`. This makes `distcd` the final member, so update `PONY_ACTOR_PAD_SIZE` to reference it: `(offsetof(pony_actor_t, distcd) + sizeof(distcd_t*) - sizeof(pony_type_t*))`. Update the static assert in actor.c to reference `distcd` as the final member too.

The pointer fits within the existing 16 bytes of tail padding (see Divergence 5), so `sizeof(pony_actor_t)` does not change.

In `pony_create()`: when `cd_mode == CD_MODE_DISTRIBUTED`, allocate and zero-initialize `distcd_t`. Otherwise leave NULL.

In `ponyint_actor_destroy()`: free the `distcd_t` if non-NULL (including all owned dynamic structures — chains, cycle sets, trace sets).

Create `distcd.h` and `distcd.c` with:
- Type definitions for `trace_entry_t`, `trace_chain_t`, `cycle_t`, `conn_trace_entry_t`, `traceset_t`, `cycleset_t`, `conn_traces_t`, `distcd_t`, `distcd_candidate_t`
- DECLARE_HASHMAP instantiations with concrete types:
  - `DECLARE_HASHMAP(ponyint_traceset, traceset_t, trace_chain_t)` — keyed by chain content hash
  - `DECLARE_HASHMAP(ponyint_cycleset, cycleset_t, cycle_t)` — keyed by sorted member hash
  - `DECLARE_HASHMAP(ponyint_conn_traces, conn_traces_t, conn_trace_entry_t)` — keyed by target actor pointer
- Hash and comparison functions:
  - `ponyint_trace_chain_hash(trace_chain_t*)` — hash over the (actor, epoch) pair sequence
  - `ponyint_trace_chain_cmp(trace_chain_t*, trace_chain_t*)` — element-wise equality
  - `ponyint_cycle_hash(cycle_t*)` — hash over sorted member pointer array
  - `ponyint_cycle_cmp(cycle_t*, cycle_t*)` — element-wise equality
  - `ponyint_conn_trace_hash(conn_trace_entry_t*)` — hash of target pointer
  - `ponyint_conn_trace_cmp(conn_trace_entry_t*, conn_trace_entry_t*)` — pointer equality
- Allocation/deallocation: `distcd_init(distcd_t*)`, `distcd_destroy(distcd_t*)`

**Tests:** Unit tests for the hash/comparison functions and allocation/deallocation (no leaks under Valgrind).

**How to verify:** Build debug. Run existing tests — no behavioral change. Valgrind a simple program under distributed mode.

### Step 3: Trace propagation (on-block trigger)

**Files changed:** `src/libponyrt/gc/distcd.c`, `src/libponyrt/actor/actor.c`, `src/libponyrt/actor/actor.h`

When a distributed-mode actor blocks with `rc > 0` (in `ponyint_actor_run`, at the rc>0 blocked path around lines 728-740, where classic mode does forced GC and CD contact):
1. If the actor has outgoing CONNECTIONs (entries in `gc.foreign`):
   - For each outgoing connection, initiate a TRACE ROUTE with a single entry: `(self, self->distcd->epoch)`
   - Use trace dedup: if this chain has already been sent on this connection, skip
   - Record sent chains in the per-connection trace history

When a distributed-mode actor receives `ACTORMSG_DIST_TRACE`:
1. Add a case in `handle_message()` for `ACTORMSG_DIST_TRACE`
2. Call `distcd_handle_trace(actor, chain)` in distcd.c
3. The handler implements the TRACE ROUTE message handling algorithm from protocol.md:
   - If actor has no outgoing CONNECTIONs: discard
   - If actor's own ID is in the chain:
     - Check this actor's own entry's epoch against its current epoch. If it doesn't match, the trace is stale — discard it.
     - If the epoch matches: extract cycle, add to known cycles, trigger gossip.
     - **Per-hop epoch checking — model vs. implementation**: the TLA+ model checks every entry's epoch against that entry's actor's current epoch (it has global state access). A real distributed implementation cannot do this — the detecting actor only knows its own current epoch. The detecting actor checks its own entry; intermediate actors' epoch staleness is caught by the confirmation protocol (when a member receives CONFIRM BLOCKED, it checks its own rc and queue state, which will have changed if its topology changed since forwarding). The confirmation protocol is the backstop for intermediate topology changes, not trace-time epoch checking. This is consistent with model finding #1: "Confirmation is required."
   - If actor's own ID is NOT in the chain:
     - Augment chain with `(self, self->distcd->epoch)`
     - For each outgoing connection: check dedup, forward if new, record

Functions to add in distcd.c:
- `distcd_initiate_traces(pony_ctx_t* ctx, pony_actor_t* actor)` — called when actor blocks
- `distcd_handle_trace(pony_ctx_t* ctx, pony_actor_t* actor, trace_chain_t* chain)` — called on ACTORMSG_DIST_TRACE receipt
- `distcd_chain_contains(trace_chain_t* chain, pony_actor_t* actor)` — check if actor is in chain
- `distcd_extract_cycle(trace_chain_t* chain, pony_actor_t* actor)` — extract cycle from chain
- `distcd_chain_hash(trace_chain_t* chain)` — hash function for dedup
- `distcd_chain_eq(trace_chain_t* a, trace_chain_t* b)` — equality for dedup

**Tests:** Create a test program with a known cycle (A→B→C→A). Run with `--ponycycledetector distributed`. Verify traces propagate and cycles are detected via tracing output.

**How to verify:** Build debug. Run the test programs. Inspect tracing output for trace propagation. Run existing `ci-core` suite to verify no regressions.

### Step 4: Gossip and component merging

**Files changed:** `src/libponyrt/gc/distcd.c`

When an actor's known cycles change:
1. Compute the connected component: union of all cycles that transitively share members
2. Send `ACTORMSG_DIST_INFORM` to each other member of the component, carrying the full set of cycles

When receiving `ACTORMSG_DIST_INFORM`:
1. Union the received cycles with own known cycle set
2. If the set changed, re-compute the connected component and re-gossip

Component merging algorithm (transitive overlap expansion):
- Start with any cycle
- Collect all cycles sharing a member
- Repeat until no new cycles are added
- The result is the connected component's member set

Functions to add:
- `distcd_gossip(pony_ctx_t* ctx, pony_actor_t* actor)` — send INFORM to component members
- `distcd_handle_inform(pony_ctx_t* ctx, pony_actor_t* actor, cycle_t* cycles, size_t count)` — handle received gossip
- `distcd_compute_component(distcd_t* d, pony_actor_t*** members_out, size_t* count_out)` — compute connected component from known cycles
- `distcd_cycle_add(distcd_t* d, cycle_t* cycle)` — add cycle to known set (returns true if new)
- `distcd_prune_cycles(distcd_t* d, pony_actor_t* dropped_actor)` — remove cycles involving a dropped actor

### Step 5: Confirmation protocol

**Files changed:** `src/libponyrt/gc/distcd.c`, `src/libponyrt/actor/actor.c`

Leadership determination:
- The leader is the actor that appears most often across the component's cycles
- Tiebreaker: lowest actor address (or `systematic_testing_id` under `USE_SYSTEMATIC_TESTING`)
- Each actor computes this locally; the result is deterministic given the same known cycles

When the leader blocks with empty queue and `rc == appearance_count`:
1. Build candidate record (members, leader ID)
2. Send `ACTORMSG_DIST_CONFIRM` to each member
3. Set `distcd->leading_candidate`

When a member receives `ACTORMSG_DIST_CONFIRM`:
1. Set `distcd->member_candidate`
2. Check: queue empty? `rc == appearance_count_in_component`?
3. If yes: send `ACTORMSG_DIST_CONFIRMED` to leader
4. If no: send `ACTORMSG_DIST_DENIED` to leader

When the leader receives responses:
- All CONFIRMED → component confirmed, proceed to destruction
- Any DENIED → delegate to the first denier via `ACTORMSG_DIST_DELEGATE`
- Delegation: clear own `leading_candidate`, send DELEGATE carrying the candidate
- Recipient of DELEGATE becomes new leader, re-enters confirmation

Functions to add:
- `distcd_check_leader(pony_actor_t* actor)` — determine if actor is leader, check confirmation conditions
- `distcd_send_confirm(pony_ctx_t* ctx, pony_actor_t* actor)` — send CONFIRM BLOCKED
- `distcd_handle_confirm(pony_ctx_t* ctx, pony_actor_t* actor, dist_candidate_msg_t* msg)` — handle CONFIRM BLOCKED
- `distcd_handle_confirmed(pony_ctx_t* ctx, pony_actor_t* actor, dist_candidate_msg_t* msg)` — handle CONFIRMED
- `distcd_handle_denied(pony_ctx_t* ctx, pony_actor_t* actor, dist_candidate_msg_t* msg)` — handle DENIED
- `distcd_handle_delegate(pony_ctx_t* ctx, pony_actor_t* actor, dist_candidate_msg_t* msg)` — handle DELEGATE

### Step 6: Destruction

**Files changed:** `src/libponyrt/gc/distcd.c`, `src/libponyrt/actor/actor.c`

When the leader has all CONFIRMED:
1. Re-verify all conditions before sending RELEASE. The model requires this: topology can change between confirmation and destruction. The leader re-checks that it is still blocked, its rc still matches, and its queue is still empty. If any condition fails, abort the destruction (clear `leading_candidate`, the cycle will be re-detected if it still exists).
2. Send `ACTORMSG_DIST_DESTROY` to each member carrying the candidate
3. Leader does GC release of each member in its actormap

When a member receives `ACTORMSG_DIST_DESTROY`:
1. Verify the candidate matches expectations (same members, same leader)
2. **Re-verify conditions at DESTROY handling time**: the member re-checks that it is still blocked, its rc still matches, and its queue contains only the DESTROY message itself. If conditions fail, the member ignores the DESTROY — the cycle's actual topology has changed, and re-detection will happen naturally. This is required by the model: members must re-verify at RELEASE processing time, not just at CONFIRM BLOCKED processing time.
3. Do GC release of each other member in its actormap
4. This triggers CONNECTION lifecycle cleanup for each dropped connection
5. After GC releases, if `rc == 0` and queue empty: self-reap

CONNECTION lifecycle cleanup (on losing a connection):
1. Remove the connection from outgoing connections (this happens via GC release in the actormap)
2. Increment `distcd->epoch`
3. Remove known cycles involving the dropped actor
4. Clear trace dedup entries for the dropped connection (remove the `conn_trace_entry_t` for this target from `conn_traces`)
5. Clear trace dedup entries where any chain's visited sequence mentions the dropped actor (the chain-content cleanup from model finding 12). This means iterating all `conn_traces` entries and removing chains that reference the dropped actor — more expensive than clearing a single connection's history, but required to prevent liveness gaps under epoch saturation.

Functions to add:
- `distcd_send_destroy(pony_ctx_t* ctx, pony_actor_t* actor)` — send RELEASE (protocol) to all members
- `distcd_handle_destroy(pony_ctx_t* ctx, pony_actor_t* actor, dist_candidate_msg_t* msg)` — handle RELEASE
- `distcd_connection_lost(distcd_t* d, pony_actor_t* dropped)` — CONNECTION lifecycle cleanup

ORCA integration for destruction:
- The GC release triggered by `ACTORMSG_DIST_DESTROY` handling uses the existing `ponyint_gc_sendrelease()` / `ponyint_actor_sendrelease()` path
- This sends `ACTORMSG_RELEASE` (GC protocol) to actors referenced by each member, decrementing their rc
- Members whose rc drops to 0 self-reap via the existing path

### Step 7: CONNECTION lifecycle and ORCA integration

**Files changed:** `src/libponyrt/gc/distcd.c`, `src/libponyrt/gc/gc.c`, `src/libponyrt/gc/actormap.c`

Hook into ORCA's GC release path (outgoing connections):
- In `ponyint_actormap_sweep()` (actormap.c), when an actormap entry is removed during sweep (the entry's rc drops to 0 and it is deleted from the map), if `cd_mode == CD_MODE_DISTRIBUTED`, call `distcd_connection_lost()` on the sweeping actor for the removed target. The hook fires on entry removal, not just rc hitting 0 — an actormap entry with rc=0 is being swept away, which is the moment the CONNECTION to that target is lost.
- This increments the actor's epoch and cleans up stale trace/cycle state

Hook into GC acquire:
- When a distributed-mode actor acquires a new outgoing connection (new entry in `gc.foreign`), no immediate action — the on-block trigger handles trace initiation

**Tests:** The full correctness test suite (see Testing strategy section).

**How to verify:** Build debug. Run the full correctness test suite. Run Valgrind to check for leaks and use-after-free. Run existing `ci-core` tests to verify no regressions.

### Step 8: Self-reap guards for distributed mode

**Files changed:** `src/libponyrt/actor/actor.c`

In `ponyint_actor_run`, the self-reap path for rc=0 actors (lines 656-688) currently gates on `actor_noblock || !has_internal_flag(actor, ACTOR_FLAG_RC_OVER_ZERO_SEEN)`. In distributed mode, the same self-reap applies — actors with rc=0 and empty queue self-reap directly without involving any central actor.

Self-reap guard additions for distributed mode (from the formal model's constraints):
- The actor must not be referenced in any pending confirmation candidate. Check: `distcd->member_candidate == NULL` and `distcd->leading_candidate == NULL`. If `member_candidate` is NULL and the actor has rc=0, no confirmation can reference it (rc=0 means no other actor holds a reference, so it can't be a cycle member). But check both to be safe against race windows.
- Global dedup cleanup (clearing stale trace dedup entries across the system when an actor is destroyed) is deferred. Stale entries may suppress valid traces when actor addresses are reused, but this is a liveness issue, not safety — the confirmation protocol catches false candidates. If performance evaluation shows this matters, a cleanup mechanism can be added later.

## Testing strategy

### Correctness tests

Tests are Pony programs (in `test/full-programs/distributed-cd/` or similar) compiled and run with `--ponycycledetector distributed`. Each test is a standalone program that exercises a specific scenario and exits with a non-zero code on failure.

1. **Self-reap**: actors with rc=0 are destroyed in distributed mode (same as none mode)
2. **Simple cycle**: A→B→A, both blocked — detected and destroyed
3. **Longer cycle**: A→B→C→D→A — detected and destroyed
4. **Overlapping cycles**: A→B→A, B→C→B — component merging produces {A,B,C}, destroyed as one
5. **Active actor in cycle**: A→B→A where A keeps sending — DENIED, no destruction
6. **External reference into cycle**: A→B→C→B, A is not in the cycle but references B — cycle {B,C} should not be confirmed (B's rc > appearance count)
7. **Cycle breaks**: A→B→A, then A drops reference to B — cycle pruned, B self-reaps if rc=0
8. **Cascading destruction**: cycle {A,B,C}, C references D (not in cycle) — after cycle destroyed, D's rc drops, D self-reaps
9. **Epoch staleness**: form cycle, break it, re-form it — stale traces discarded via epoch check
10. **Delegation**: confirmation denied by one member, leadership delegates to denier

All tests land with the implementation in a single PR.

### Performance tests

These compare distributed mode against classic mode and none mode:

1. **High actor churn** (ponyc#6181 pattern): create and destroy millions of short-lived actors. Measure: peak memory, time to completion, actors alive at steady state.
2. **Stable cycle detection latency**: create a cycle, measure time from all actors blocking to cycle destruction.
3. **Trace message volume**: count DIST_TRACE messages under various topologies — linear chains, trees, dense meshes.
4. **Per-actor memory overhead**: measure `distcd_t` memory per actor under realistic workloads.
5. **Throughput under active execution**: measure overhead of distributed mode vs none mode for a workload with no cycles (should be near-zero since trigger is on-block).
6. **Scalability**: vary actor count (100, 1000, 10000) with cycles — measure time to detect and destroy all cycles.

Performance tests live in a separate benchmark directory, not part of CI, but runnable manually. They output metrics (timing, memory, message counts) for comparison.

### Build and run commands

```bash
# Build ponyc debug
cmake --build --preset debug

# Run core test suite (verifies no regressions)
ctest --preset debug -L ci-core

# Run distributed CD specific tests (once they exist)
ctest --preset debug -R distributed-cd

# Run a specific test program manually
cd build/debug && ./ponyc -b test_distcd --pic ../../test/full-programs/distributed-cd/simple-cycle
./test_distcd --ponycycledetector distributed
```

## Phasing

**Single PR.** All steps land together. The mode flag is only useful with the protocol behind it, and detection without destruction is not a meaningful checkpoint. The PR replaces `--ponynoblock` with `--ponycycledetector`, adds the full distributed protocol (trace propagation, gossip, component merging, confirmation, destruction, CONNECTION lifecycle), and includes the complete correctness test suite.

**Performance benchmarks** are added alongside or after the PR — they need the full protocol to be meaningful.

## Documentation updates

- Update `AGENTS.md` and `CONTRIBUTING.md` to document the `--ponycycledetector` flag and the three modes. Update any references to `--ponynoblock`. Update the `PONYRT_HELP` text in `options.h`.
- Document the distributed mode's behavior and the protocol's operation (high-level, in a code comment at the top of `distcd.c`).

## Open items for Sean

None — all design questions are resolved. The plan is ready for implementation pending review.
