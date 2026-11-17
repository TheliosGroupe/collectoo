# M2c-6b-2 build plan — ops book our transfer lines, then the pages and the statement's « Suivi »

Refines `docs/design/m2c-6b-plan.md` (§1.2 row 6b-2, §2.3, §2.6, §2.7, §4.1–§4.4, §5, §6) for what M2c-6b-1 actually
built (PR #29, head `ab1a1f8`, eight review rounds). Every departure from that plan is in §1.3 with its reason.
Shape ids `S01`…`S27` are the inventory of the lines 6b-1 sent to « ops' booking in M2c-6b-2 » (reproduced in §1.1).
Line numbers `l.NNNN` are `supabase/migrations/20261116090000_debit_bookings.sql` at `ab1a1f8` unless another file is
named; re-read them on `main` once PR #29 is merged.

**Precondition.** Branch `m2c6b-2a` from `main` after PR #29 is merged (if it is not, stack on its branch and rebase
before the PR). `m2c6b-2b` branches from `main` after 6b-2a is merged. The cancellation-after-download switch stays
**OFF** in both (`private.feature_switch` `downloaded_file_cancellation`; 6b-3 switches it on); tests that need a
cancelled member of a live downloaded file switch it on inside their own rolled-back subtransaction, as 034/035 do.
pgTAP 033 and 034 are not edited.

**Hard rules this plan keeps** (CLAUDE.md): every amount from the ledger and the database's rules, integer minor units,
double-entry append-only entries, corrections by reversal; RLS on every exposed table; bookings written only by
`SECURITY DEFINER` functions; an idempotency key on the command; forward-only migrations; French copy; no banking or
legal rule invented — each unknown below is a founder question (§8) or a COMPLIANCE open question (§7) with a default.

---

## 1. Scope, split and size

### 1.1 Every inventory shape: how it is booked, or why it stays

| Id | Shape (inventory) | Exit in 6b-2 | Parts (§2.4) | Slice |
|---|---|---|---|---|
| S01 | RMT debit of a payout cancelled (run cancelled before download) | **booked** | `unplanned_payout(x)` (+ `fee` if line > A) | 2a |
| S02 | batch line: live members + a late cancelled member | **booked** (switch on in tests only; real cases arrive with 6b-3) | `payout` × live + `unplanned_payout` × cancelled | 2a |
| S03 | second debit of a booked/returned payout by its RMT id | **booked**, P = 0 | `unplanned_payout(x)` | 2a |
| S04 | batch line whose members are all booked/returned | **booked**, P = 0 each | `unplanned_payout` × n (`unplanned_sweep` for a sweep PmtInf) | 2a |
| S05 | batch line = live members' first debit + a booked member's second | **booked** | `payout` × live + `unplanned_payout` (P = 0) | 2a |
| S06 | debit of a payout never handed out (ordered, or file never downloaded) | **left** → 6b-3 (Q9) | — | — |
| S07 | RMT/SWP-shaped id or TF PmtInfId no transfer of ours holds | **booked** when the counterparty IBAN is a client's payout IBAN or one of our own IBANs; else **left** (bank) | `unplanned_payout(client)` / `unplanned_sweep()` | 2a |
| S08 | payout debited with the bank's charge on the same line (N + F) | **booked** | `payout(t)` + `fee` | 2a |
| S08b | payout debit for less than N, other account or currency | **left** (bank's detail) | — | — |
| S09 | batch line short of a member (one rejected / not executed) | **booked** when the members executed are the only subset of the PmtInf making the line | `payout` × named | 2a |
| S10 | payout debit whose run is not in flight with that transfer | **left** → 6b-3 (late predecessor) | — | — |
| S11 | several refunds in one PmtInf line, or legacy payouts+refunds (`batch_mixed`) | **left** (Q5, OQ-83) | — | — |
| S12 | reference-less debit of an in-flight payout's amount (CSV) | **booked** (plan rule 3b, uniqueness added) | `payout(t)` | 2a; mis-booking guards 2b |
| S13 | debit to a client's registered payout IBAN without our id | **booked**, P = 0 (Q8) | `unplanned_payout(client)` | 2a; guards 2b |
| S14 | debit to our own IBAN without SWP id nor TF PmtInfId | **booked** | `sweep(t)` (rule 3b for sweeps) or `unplanned_sweep()` | 2a; explanation refused 2b |
| S15 | SWP debit of a cancelled sweep, or a second debit of a booked sweep | **booked** | `unplanned_sweep(x)` | 2a |
| S16 | our payout/sweep returned, unflagged (own/client credit kinds) | **booked** | `payout_returned(t)` / `sweep_returned(t)` (+ `fee`) | 2a |
| S17 | returns the job refuses (more than N, second return, unknown id, other account) | **left** (bank) | — | — |
| S18 | `return_before_debit` | no part: booked by the job once ops book its debit; the command queues the funds pass (§2.2 step 9) | — | 2a |
| S19 | short return of a line of its own (booked in full + fee) | unchanged (OQ-84 (j), Q10) | — | — |
| S20 | credit naming a handed-out lot of ours | **booked** for payout/sweep lots (unique subset of booked members); refund lots **left** (Q5); the M2b pass's `changed` gets its own reason | `payout_returned` × members | 2a |
| S21 | unsplit credit entry holding ours | **booked** only when the bank's detail shows our payouts/sweeps (and a charge) and the parts add up (Q11); entries holding a debtor's money, a refund or a top-up **left** | signed parts | 2a |
| S22 | unsplit debit entry holding ours | as S21; alert added | signed parts | 2a |
| S23 | payments made of our transfers coming back (imported before rounds 4/8) | **left** (no command un-makes a payment); texts no longer promise a screen | — | 2a texts |
| S24 | TOP/RMT/SWP id only in a CSV label outside `/REF` | **left** (same blocker; the bank's e2e column) | — | — |
| S25 | our refund's RFD debit that cannot be linked (OQ-81 (b), Q2) | **left** → 6b-3 with Q2's entries chosen (§8) | — | — |
| S26 | `changed` / `posting_failed` on our lines | retried in strict mode by the command | the underlying shape's | 2a |
| S27 | return of an unplanned payout or sweep | **booked** (new kinds) | `unplanned_payout_returned` / `unplanned_sweep_returned` (+ `fee`) | 2a |

### 1.2 Left for later, and why
- **6b-3**: S06 and S10 need the late-predecessor machinery (booking a transfer as its run's payout while superseding a
  file never downloaded, `FOR UPDATE` on that file, m2c-6b-plan §3.1); S25 needs Q2's entries decided (§8 Q2); the
  switch itself; real S02 cases.
- **M2c-7**: recovery of the `double_payout` advances (claw-back, repayment request, `advance_open`, write-off); a
  line-split model for an unsplit entry holding a debtor's payment, a refund or a top-up (S21/S22 residue, S23, S24).
- **The bank / founder #15**: S08b, S11, S17, S24 and the S21/S22 residue need the bank's per-transaction detail (OQ-83,
  OQ-84); S07 without a registered counterparty IBAN needs the order's origin.

### 1.3 Departures from `m2c-6b-plan.md`, with why
1. **The command does not go through `private.post_bank_bookings(org, true)`** (plan §2.6). That re-check is the job's,
   reviewed in eight rounds; ops' rules are wider (mixed parts, subsets, a fee beside a payout, reference-less lines,
   returns on own/client credit kinds, lot credits, unsplit lines) and would each have to be carved out of it. 6b-2a
   adds its own rule function (`private.transfer_line_check`) with the same lock order, posts the unplanned kinds and
   the returns itself, and hands the planned kinds (`payout`, `sweep`, `fee`) to the unchanged
   `private.bank_booking_post_rows` (settlements, cover, breach rows, run booked, completeness). `post_bank_bookings`
   is redefined only in 6b-2b, hint text only.
2. **Ops never pick a batch line's members.** The database proposes the only subset of the PmtInf's members (live,
   booked, returned or cancelled) whose amounts make the line, and refuses `batch_ambiguous` when there are several or
   the bound is passed (§2.5). Plan rule 3 compared only with « other subsets of open members »: a re-executed booked
   member of the same amount could then be booked as the missing live one (S05).
3. **Unplanned-payout eligibility** (plan §2.6: x cancelled, booked or returned, by its own id or `transfer_late_lines`):
   widened to a batch line naming x's PmtInf in its file (S04/S05: `transfer_late_lines` reads only superseded or
   rejected files, l.2575-2586); narrowed by leaving x `ordered`/`in_file` (S06, S10) to 6b-3 — plan §2.3 said « ops
   unplanned » for S06, §2.6 refused it; the right booking is the run's own payout (§8 Q9).
4. **c's draft is re-prepared, not « sent back »** (plan §2.3 [critic]). `private.remittance_back_to_draft` acts only on
   a draft queued for approval (20261112090000 l.1605-1616), and an unreserved −A row does not change the approval's
   item count (l.1637-1639). 6b-2a requeues c's draft for a prepare under a new token (§2.6.4).
5. **Returns of unplanned payouts are new kinds** (`unplanned_payout_returned`, `unplanned_sweep_returned`), not
   `payout_returned`: the guard requires reversing `x.entry_id` (l.1671-1674), `bank_line_booking_return_uq` allows one
   return per transfer (l.224-225) and I20 flags a return on a transfer not booked (l.2868-2871).
6. **A double execution followed by a return** (S03 then the payee's bank sends one back): the job books that credit as
   the planned payout's return, as today (the credit carries x's id, x is booked). Money-consistent (the client is owed
   N again, the double-payout advance stays open to recover) but the payout account is marked `returned`. Kept as a
   residual, pinned by a test, founder question Q12 — changing it means redefining the job's re-check and candidates.
7. **« Suivi » is the events of the client's earlier runs posted in (previous statement's K, this K]**, not a state
   diff against stored payloads (plan §2.7). One pending run per client (`remittance_run_pending_uq`,
   20261112090000 l.100) means every earlier run is booked or cancelled at K: « still in flight » cannot occur. The new
   payload key `previous_payouts` replaces M2c-5's `follow_up` (current state, not as of K, l.4262-4275).
8. **Two PRs** (6b-2a command and reads, 6b-2b pages, « Suivi », E2E) instead of one (§1.4).
9. **P for a client debit with no transfer is 0** (S13): Q4's default defines « paid » only through a cancelled run's
   items. Founder question Q8.
10. **New mis-booking guards** the plan did not foresee (6b-2b, with the screen that replaces them): « Frais bancaires »
    and « Classer sans comptabiliser » refused on a reference-less debit an in-flight payout or sweep may be, on a
    debit to a client's payout IBAN, and (the explanation) on a debit to our own IBAN.
11. **`transfer_unknown` is P0 everywhere**: ADR-0014 « M2c-6b-1 » calls it P0 and the web ranks it so; the worker's
    `P0_REVIEWS` and the alerts did not (payments/debits.py l.325-327; l.3341-3350).
12. **A lot credit returning several members** uses one reversal key per transfer, `return:<line>:<transfer>`; the
    job's `return:<line>` allows one return per line.
13. **Texts**: the « écran à venir » promises are kept where 6b-2 keeps them (reworded in 6b-2b when the screen ships)
    and withdrawn now where 6b-2 does not book the shape (S23, held duplicates read before round 4: reworded in 6b-2a).

### 1.4 Size estimate and split decision
Lines of non-test code, counted from the functions they copy in `20261116090000` (redefinitions are copied whole by
house rule; their diff against the source is small and reviewed as a diff):

| | 6b-2a | 6b-2b |
|---|---|---|
| SQL, new | ≈ 1,750 (rules ≈ 600, posting ≈ 300, command ≈ 130, locks ≈ 100, reads ≈ 320, helpers ≈ 220, schema ≈ 80) | ≈ 350 (statement events ≈ 150, run and transfer reads ≈ 130, guards ≈ 70) |
| SQL, redefinitions copied | ≈ 700 (guard 106, `apply_debit_decisions` 35, `run_transfer_checks` 275, `pending_item_deadlines` 95, `assign_payment` 108, `resolve_duplicate` 78) | ≈ 1,580 (`link_debit` 116, `debit_queue` 162, `remittance_statement_build` 428, hint-only: `post_bank_bookings` 430, `post_debit_links` 342, `release_own_credit` 100) |
| Worker | ≈ 40 (P0 set, `_held_to` parity) | ≈ 180 (renderer fr-3) |
| Web | ≈ 150 (refusal and decision labels, S23 texts) | ≈ 1,050 (sheets, actions, `lib/payments/transfer-lines.ts`, run page, Virements, client space, rewording) |
| **Total** | **≈ 2,640** (≈ 1,940 new or changed) | **≈ 3,160** (≈ 1,600 new or changed) |

**Decision: split.** The whole would be ≈ 5,800 lines. **6b-2a** — the ops command and its reads, pgTAP 036, worker
parity, labels: shippable alone (nothing a user sees changes but error labels, the S23 texts and the « Traités »
labels; every « écran à venir » stays true because no screen ships). **6b-2b** — the pages, the mis-booking guards, the
hints reworded, « Suivi » (fr-3), pgTAP 037, E2E, screenshots: shippable alone on top of 6b-2a. Both pass 2,500 only
through verbatim copies; if the reviewer counts them, peel « Suivi » (`remittance_statement_build` copy, its events,
the renderer, the golden PDF, pgTAP 037 ≈ 760 lines) off 6b-2b as **6b-2c**, independent of the pages.
Shapes: 6b-2a books S01–S05, S07 (client/own IBAN), S08, S09, S12–S16, S20–S22, S26, S27 (by API); 6b-2b gives them a
screen and adds the S12/S13/S14 mis-booking guards and « Suivi ».

---

## 2. 6b-2a — migration `20261117090000_transfer_line_ops.sql`

Header (house rule): what is new, what is redefined and from which file, with settings and grants restated. The
switch stays off; 033/034 unchanged.

### 2.1 Schema
- `public.bank_line_booking`: kind check += `unplanned_payout_returned`, `unplanned_sweep_returned`; index
  `bank_line_booking_transfer_idx (transfer_id) where transfer_id is not null` (the unplanned kinds have no index on
  their transfer: the rules, the alerts and « Suivi » read them by key).
- `public.bank_debit_review.reason` check += `own_transfer_line` (the M2b pass's own reason, S20 / OQ-84 (i)).
- No new table: `client_advance` (cause `double_payout` already allowed), `private.remittance_pending` (kind
  `unplanned_payout` already allowed, 20261111090000 l.1238), `remittance_line.kind` (`unplanned_payout` allowed,
  20261112090000 l.246), the commission engine (`LineKind.UNPLANNED_PAYOUT` never commissioned,
  `remittance/commission.py` l.154-165) need no change.

### 2.2 The command
```
public.book_transfer_line(p_idempotency_key text, p_bank_transaction_id uuid, p_parts jsonb,
                          p_expected_text text, p_reason text) returns jsonb
  security definer, set search_path = '', set lock_timeout = '2s'
```
Plan §2.6 [critic]'s signature, unchanged. Steps:
1. Read the line; `private.has_role(line.organization_id, array['admin','ops_manager'])` (aal2 for servicer staff)
   else `insufficient_privilege` « not allowed » (also for a line that does not exist).
2. Normalise the request `{bank_transaction_id, parts (as given, amounts as text), expected_text, reason (trimmed)}`;
   `private.command_replay('book_transfer_line', key, request)`; a stored result is returned as is (same key, another
   request: command_replay's own refusal).
3. Reason 1–2,000 characters else `a reason is required` (check_violation, as every command).
4. Parse `p_parts` (§2.4.0) else `bad_request`; `p_expected_text` non-empty ≤ 100,000 else `bad_request`.
5. `private.transfer_line_locks(line, parts)` (§2.8).
6. `private.transfer_line_check(line, parts, strict => true)` under the locks: raises the first refusal
   (`transfer line booking refused: <code>`, check_violation); fills `pg_temp._tl` (one row per part with its facts and
   its effects: P, the advance, the client, the run).
7. Compare and set: `private.transfer_line_text()` (§2.9) ≠ `p_expected_text` → `split_changed`.
8. `private.transfer_line_post(org)` (§2.6, §2.7); LG*, 22*, 23* raised inside → `posting_failed (<state>: <message>)`
   (as `post_bank_bookings` strict, l.1484-1493).
9. Requeue c's draft (§2.6.4); queue the funds pass when a `return_before_debit` review names a transfer this call
   booked (`pgmq.send('payments', {"type": "process_debits", "organization_id": org, "funds_after": null})`, as
   `resolve_duplicate` queues it, l.5548): S18's exit.
10. `command_record`; return `{bank_transaction_id, bookings: [{seq, kind, transfer_id, client_id, amount_minor,
    entry_id, paid_minor, advance_minor}], drafts_requeued: [run ids], funds_pass_queued, expected_text}` (amounts text).

One person (founder Q6's default): no second approval. Grants: execute to `authenticated`; revoked from `public, anon`.

### 2.3 Line classes (read under the lock; first that applies)
- **U** — `unsplit_ours > 0` (an entry the bank kept unsplit holding a detail of ours, l.123).
- **E** — our id: a debit whose `end_to_end_id ~ '^(RMT|SWP)[0-9A-F]{12}$'`; a credit whose own or original id is.
- **B** — our lot: `end_to_end_id is null` and `payment_info_id` names a file of the line's account through
  `transfer_file_item.pmt_inf_id` (debit: our batch line, as the job reads it; credit: `private.names_our_lot`, a file
  downloaded or sent).
- **N** — neither an end-to-end id nor a PmtInfId (a CSV feed without the reference column).
- **O** — anything else (a foreign end-to-end id or PmtInfId).

An E/B line whose id names no transfer or file of ours is `transfer_unknown` for every transfer part; only the client
and own-IBAN parts (§2.4.4, §2.4.6) can book it (S07).

### 2.4 Part kinds — acceptance rules (evaluated in this order; the first failure is the refusal)

**2.4.0 Parse** (`bad_request`): an array of 1–10,000 objects `{kind, transfer_id?, client_id?, returns_line_id?,
amount}`; `amount ~ '^[0-9]{1,16}$'` and > 0; kind one of the nine below; `transfer_id` required for `payout`,
`sweep`, `payout_returned`, `sweep_returned`; exactly one of `transfer_id` / `client_id` for `unplanned_payout`;
`unplanned_sweep` with a transfer or nothing; `returns_line_id` required for the two unplanned return kinds and nowhere
else; no two parts with the same (kind, transfer_id, client_id, returns_line_id); at most one `fee`; at most one part
without a transfer. Part `n` is its 1-based position (it keys the entries).

**2.4.1 Line state** (any part): held duplicate → `held_duplicate`; a booking or an own-credit release on the line →
`already_booked`; an M2b link → `already_linked`; a payment of the line → `line_is_payment`; signed Σ of the parts ≠
signed line (debit parts −, return parts +, a fee −; the line − for a debit, + for a credit) → `parts_do_not_add_up`.
Shapes LEFT are refused here by their class: a line holding a refund member (B with a refund in the PmtInf) →
`batch_mixed`.

**2.4.2 `payout(t)`** — a planned payout's debit (S08, S09, S12, S26; the planned half of S02, S05):
1. t of the servicer, kind payout → `transfer_unknown`.
2. Line a debit (class U: either direction) → `wrong_direction`.
3. Identity → `not_its_line`: E: `line.end_to_end_id = t.end_to_end_id`; B: t is a member of the named PmtInf **in its
   current file** (`i.file_id = t.transfer_file_id`) and the decomposition rule (§2.5) holds; N: rule 3b below; U:
   §2.4.9; O: refused.
4. t `cancelled` → `transfer_cancelled`; `booked`/`returned` or a debit booking of t → `already_debited`; not `in_file`,
   or its file never downloaded or not downloaded/sent → `not_handed_out` (S06: 6b-3).
5. `t.debtor_bank_account_id` and currency = the line's → `transfer_differs`.
6. t's run approved or sent with `run.transfer_id = t` → else `run_not_in_flight` (S10: 6b-3).
7. `amount` = `t.amount_minor` → `amount_differs`. On E: the line = t's amount, or t's amount + the `fee` part (S08);
   a line below t's amount is `amount_differs` (S08b: left).
8. **Rule 3b (class N only)**, the payout twin of round 7's refund rule (m2c-6b-plan §2.4 3b) plus uniqueness:
   - t re-issues none (`replaces_transfer_id is null`) → `not_its_line`;
   - line date ≥ t's item `execution_date` in its current file → `before_execution`;
   - the line's `counterparty_iban`, when present, = `t.payee_iban` → `not_its_line`;
   - **no other candidate**: no other payout or sweep u of the line's account `in_file` in a downloaded/sent file, run
     approved/sent with it (payouts), re-issuing none, of the line's amount, `execution_date` ≤ line date, and
     `payee_iban` = the counterparty when the line has one → else `line_ambiguous`;
   - no `fee` part on class N → `fee_not_allowed`.

**2.4.3 `sweep(t)`** — the same rules for kind `sweep` (no run rule 6): E by SWP id, B by its PmtInf (a sweep is alone
in its PmtInf since 6b-1, l.276+), N by rule 3b (a CSV debit to our own IBAN of the sweep's amount: S14 when a sweep is
in flight).

**2.4.4 `unplanned_payout(x)` / `unplanned_payout(client c)`** — money that left for a client outside its run (S01–S05,
S07, S13):
- With a transfer x:
  1. x of the servicer, kind payout → `transfer_unknown`.
  2. Line a debit (U: either) → `wrong_direction`.
  3. Identity → `not_its_line`: E: `line.end_to_end_id = x.end_to_end_id`; B: x is an item of the named PmtInf in that
     file (whatever x's current file) and §2.5 holds; N and O: refused (a reference-less or foreign line is a planned
     payout by rule 3b, or a client's unplanned payout by IBAN); U: §2.4.9.
  4. x `cancelled`, `booked` or `returned` → else `not_cancelled_nor_booked` (x `ordered`/`in_file`: S06/S10, 6b-3).
  5. Account and currency → `transfer_differs`.
  6. `amount` = `x.amount_minor` → `amount_differs` (E: the line = A, or A + the fee part).
  - Effects: client c = `x.client_organization_id`, A = x's amount, P = `private.unplanned_paid_part` (§2.6.1) when x is
    cancelled, 0 when booked or returned; advance = A − P.
- With a client c (no transfer):
  1. c a client of the servicer → `client_unknown`.
  2. Line a debit of class N, O, or E/B naming nothing of ours → else `not_its_line`.
  3. `line.counterparty_iban` = the IBAN of a confirmed payout account of c (`client_payout_account` with
     `confirmed_at` not null, status `active`, `returned` or `retired`, the line's currency) → `client_iban_mismatch`;
     the IBAN registered for another client too → `client_ambiguous`.
  4. Class N with a rule-3b payout candidate on the line → `payout_in_flight_matches` (book it as that payout).
  5. `amount` = the line − the fee part → `amount_differs`.
  - Effects: A = amount, **P = 0** (Q8), advance = A; the entry's source is the line.

**2.4.5 `unplanned_sweep(x)`** — a sweep's late or second debit (S15, S04 for a sweep PmtInf): as 2.4.4 with kind
sweep (rules 1–6); effects: a `servicer_sweep` of A to `x.creditor_bank_account_id`.

**2.4.6 `unplanned_sweep()`** (no transfer) — a debit to our own IBAN we did not order (S14, S07):
1. Line a debit of class N, O, or E/B naming nothing of ours → `not_its_line`.
2. `line.counterparty_iban` = an active `bank_account` of the servicer with `purpose = 'own'`, the line's currency →
   `own_account_unknown`.
3. A rule-3b sweep candidate on the line → `sweep_in_flight_matches`.
4. `amount` = the line (− the fee part) → `amount_differs`.

Common to 2.4.5 and 2.4.6: a file of the line's account never downloaded (`download_count = 0`, status `generated`)
holding an `in_file` sweep → `sweep_file_pending` (that sweep was computed before this debit lowered −Σ4679: ops cancel
that file first — before download it is superseded and the sweep recomputed at the next file). A sweep already handed
out may still over-sweep: 4679 then goes into debit and `servicer_shortfall` (P0, exists) asks for a top-up.

**2.4.7 `fee`** (no transfer): only beside a transfer part on the same line, on class E (a debit: the bank's charge on
our payout's or sweep's own line, S08; a credit: the charge deducted from our transfer's return, S16, S27), on the
client/own-IBAN unplanned lines (N/O), or on class U → else `fee_not_allowed`; amount = whatever makes the line
(rule 2.4.1). A fee alone stays `link_debit` « Frais bancaires ».

**2.4.8 `payout_returned(t)` / `sweep_returned(t)`** — a return the job did not book (S16, S20, U):
1. t kind payout / sweep → `transfer_unknown`.
2. Line a credit (U: either) → `wrong_direction`.
3. Line kind (or a released duplicate's) in `return`, `own_transfer_in`, `client_transfer_in` → `not_a_return`.
4. Identity → `not_its_line`: E: the line's original id (else its own) = `t.end_to_end_id`; B (lot credit): t is a member
   of the named PmtInf in that file and its current file is that file, and §2.5 holds over the lot's booked members;
   U: §2.4.9; N/O: refused.
5. t `ordered`/`in_file` → `return_before_debit`; `returned` or a return booking → `already_returned`; `cancelled` →
   `transfer_cancelled` (its late debit is an unplanned payout: book `unplanned_payout_returned`); `booked` without its
   debit booking → `return_differs`.
6. Account and currency → `transfer_differs`.
7. Line date ≥ t's debit entry date → `return_before_debit`.
8. `amount` = t's amount; on E the line = t's amount, or t's amount − the fee part; line > t's amount → `return_differs`.
   On B no fee part (`fee_not_allowed`): a lot returned short is the bank's detail's (left).

**2.4.9 Unsplit lines (class U, S21/S22)** — ops transcribe the bank's detail; the rules add, to each part's own rule
(identity rule 3 and direction rule 2 replaced):
- the number of transfer parts = `line.unsplit_ours` → `unsplit_count`;
- when the line carries an RMT/SWP id of ours (own or original), that transfer is among the named ones →
  `unsplit_id_missing`;
- planned parts keep rules 4–7 (a payout in flight, a payout booked for a return, …); the signed sum rule 2.4.1.
A debtor's payment, a refund or a top-up inside the entry cannot be named: such an entry never adds up and stays (§1.2).

**2.4.10 `unplanned_payout_returned(x | client c, returns_line_id)` / `unplanned_sweep_returned`** (S27):
1. The line `returns_line_id` holds an `unplanned_payout` (`unplanned_sweep`) booking of that transfer (or, without a
   transfer, of client c: its entry's client) → `transfer_unknown`.
2. That booking's entry not reversed (`ledger_entry_reversed_once_uq`) → `already_returned`.
3. This line a credit of kind `return`, `own_transfer_in` or `client_transfer_in` → `not_a_return`; identity: class E by
   x's id, or the line's `counterparty_iban` = the IBAN the unplanned payout went to (`x.payee_iban`, or the debit
   line's counterparty) → `not_its_line`.
4. Line date ≥ the unplanned entry's date → `return_before_debit`.
5. Its `double_payout` advance (if any) has no `commission_settlement` (`document_kind = 'advance'`) →
   `advance_settled` (M2c-7's claw-back would have used part of it).
6. `amount` = A; the line = A or A − the fee part → `amount_differs`.

### 2.5 Batch lines and lots: the only subset
- **Universe M**: every item of the named PmtInf in its file (`transfer_file_item` where `pmt_inf_id` = the line's and
  the file is of the line's account), whatever the member's status: live (`in_file` there), left (`booked`/`returned`
  there), cancelled (returned seen or not). For a lot credit: the members `booked` there, not returned. One kind (a
  refund in M → `batch_mixed`). The file never downloaded → `not_handed_out` (6b-3).
- **Rule**: the named parts' transfers ⊆ M (else `not_its_line`), their amounts add up to the line (2.4.1), and the
  number of subsets of M whose amounts make the line is exactly 1 (`private.unique_subset`) → else `batch_ambiguous`.
  Live members of the subset take `payout`, left and cancelled ones `unplanned_payout` (`unplanned_sweep`).
- **`private.unique_subset(p_amounts bigint[], p_target bigint) returns integer[]`** (immutable, parallel safe): the
  1-based indexes of the only subset summing to `p_target`, or null (none, several, or past the bounds). Dynamic
  programme over partial sums with a count capped at 2 and, for count 1, the path; it works on the smaller side,
  `t' = least(p_target, Σ − p_target)` (a subset makes t iff its complement makes Σ − t, so the counts are equal) and
  returns the complement when t' ≠ p_target; amounts > t' skipped; past **10,000 partial sums** (as
  `private.amounts_make_up`, 20261115090000 l.1145) or 200,000 stored path entries → null. A Python twin
  `payments.debits.unique_subset` (same bounds) is the Hypothesis oracle's subject (§6.2).
- **The options read proposes that subset** (§2.11); ops confirm it, they never compose a batch line.

### 2.6 Unplanned payouts: P, the pending row, the advance, the draft
**2.6.1 P** (Q4's default, OQ-82): what the late payout paid of x's cancelled run's own items still waiting.
`private.unplanned_paid_part(p_transfer uuid, p_amount bigint, p_taken_run bigint, p_taken_client bigint) returns bigint`:
```
P = greatest(0, least(p_amount,
                      owed(c) − p_taken_client,
                      pool(run) − earlier(run) − p_taken_run))
  owed(c)    = −client_payable_balance(c, currency)                      -- under the allocation lock
  pool(run)  = Σ remittance_pending.amount_minor of the entries of x's run's RELEASED lines
               (remittance_line where run_id = x.run_id and released; pending reserved by a draft or not)
  earlier(run) = Σ over existing, unreversed unplanned_payout bookings of transfers of that run
                 of (booking amount − its double_payout advance)          -- P already counted
P = 0 when x is booked or returned, when x's run is not cancelled, or for a client debit (Q8)
```
`p_taken_*`: the P of earlier parts of the same call (same run, same client), so one line's parts never count an item
twice. **Every approximation errs toward a smaller P** (more of the servicer's money advanced), never toward holding
back the client's money: an item released by two cancelled runs may be counted by both pools — the owed cap bounds it,
and `earlier` subtracts what an earlier booking took.

**2.6.2 The pending row** (plan §2.3 [critic], kept): one `private.remittance_pending` row per unplanned payout part,
`ledger_entry_id` = its `remittance` entry, kind `unplanned_payout`, amount **−A**, `posted_at` = the entry's,
`draft_run_id` null. The 4670 trigger skips `remittance` entries (20261111090000 l.1286-1299); the advance's own posting
queues `client_advance` +(A − P) through the trigger. Net in the queue −P; I14 holds (owed falls by P, pending by P);
`remittance_line_insert_guard` accepts the next run's −A line (its entry's 4670 posting).

**2.6.3 The advance**: when A − P > 0, a `client_advance` entry and row (cause `double_payout`, `cause_entry_id` = the
remittance entry, `bank_transaction_id` = the line, `transfer_id` = x or null, `mandate_id` null), posted after the
remittance so LG008 holds at `private.ledger_check_now()`.

**2.6.4 The draft**: for each client of an unplanned payout part (and of an unplanned return), if the client has a run
in status `draft` for the currency (at most one, `remittance_run_pending_uq`), `private.remittance_draft_requeue(run,
'unplanned_payout', line)` — `refresh_remittance_run`'s body without the command: `remittance_clear_draft`, reserve the
client's unreserved pending items, `job = 'prepare'`, a new `job_token`, `known_at = clock_timestamp()`, `prepared_at`
and `inputs_hash` null, `item_count` recounted, `last_failure = {code: 'unplanned_payout', detail: <line id>, at,
step: 'prepare'}`, `version + 1`, `pgmq.send('remittances', {type: 'prepare', run_id, token})`. A prepare or approval
in flight finds another token and does nothing (`status: skipped`, 20261114090000 l.811). Its row was locked in step 1
of §2.8 and the allocation lock is held. A client whose live run is approved or sent: nothing (its items are frozen;
P counted only what was still pending). The run page shows the requeue reason (6b-2b label).

### 2.7 Entries posted (all at the line's booking date; + debit / − credit)
| Part | Entry (type) | Lines | Idempotency key | Source | State changes |
|---|---|---|---|---|---|
| `payout(t)` | `remittance`; `client_settlement`; cover `client_advance` (`payout_overrun`) if 4670[c] > 0 | +4670[c] N / −5120 N; +4670[c] D / −4679 D ‖ +4689 D / −4111[c] Dc / −4112[c] Da ‖ +44574 v / −44571 v; +4679 X / −4670[c] X ‖ +4112[c] X / −4689 X | `remit:<t>`, `settle:<run>`, `adv:payout:<t>` | bank_transfer t; remittance_run; client_advance | via `bank_booking_post_rows`: t booked (`entry_id`), run booked (`booked_on`), breach row per positive live line with `latest_execution_date` < date (`payout_returned` lines « bloqué »), the line's review deleted |
| `sweep(t)` | `servicer_sweep` | +4679 S / −5120 S ‖ +5122[t.creditor] S / −4689 S | `sweep:<t>` | bank_transfer t | t booked |
| `fee` | `bank_fee` | +4679 F / −5120 F ‖ +6270 F / −4689 F | `fee:<line>` | bank_transaction | — |
| `unplanned_payout(x)` | `remittance` | +4670[c] A / −5120 A | `remit:line:<line>:<n>` | bank_transfer x | pending row −A; x unchanged (cancelled stays cancelled, `bank_transfer_guard`) |
| … its advance (A − P > 0) | `client_advance` | +4679 (A−P) / −4670[c] (A−P) ‖ +4112[c] (A−P) / −4689 (A−P) | `adv:line:<line>:<n>` | client_advance row | trigger queues `client_advance` +(A−P) |
| `unplanned_payout(c)` | `remittance` (+ advance A) | as above | `remit:line:<line>:<n>`, `adv:line:<line>:<n>` | bank_transaction line | as above, P = 0 |
| `unplanned_sweep(x)` / `()` | `servicer_sweep` | +4679 S / −5120 S ‖ +5122[x.creditor or the own account of the counterparty] S / −4689 S | `sweep:line:<line>:<n>` | bank_transfer x / bank_transaction | 4679 may go into debit (`servicer_shortfall`) |
| `payout_returned(t)` | reversal of `t.entry_id` (`private.ledger_reverse`) | +5120 N / −4670[c] N | `return:<line>:<t>` | — | trigger queues `payout_returned` +N; t returned (`return_entry_id`); the run's payout account `active → returned` (only while active) |
| `sweep_returned(t)` | reversal of `t.entry_id` | +5120 S / −4679 S ‖ +4689 S / −5122 S | `return:<line>:<t>` | — | t returned |
| `unplanned_payout_returned` | reversal of the unplanned `remittance`; reversal of its advance | +5120 A / −4670[c] A; −4679 X / +4670[c] X ‖ −4112[c] X / +4689 X | `return:<line>:<n>`, `return:adv:<line>:<n>` | — | trigger queues `payout_returned` +A and `client_advance_reversal` −(A−P): net +P; payout account (x's run's, or c's of that IBAN) `active → returned` |
| `unplanned_sweep_returned` | reversal of the unplanned `servicer_sweep` | +5120 S / −4679 S ‖ +4689 S / −5122 S | `return:<line>:<n>` | — | — |

Entry reasons (French, fixed; ops' motif stays on the booking): « Virement exécuté hors reversement (relevé du jj/mm/
aaaa) », « Virement hors reversement : avance du cabinet (le client a reçu plus que ce qui lui restait dû) », « Virement
au compte propre hors ordre de Collectoo (relevé du …) », « Virement de reversement revenu impayé (relevé du …) » (the
job's), « Virement hors reversement revenu impayé (relevé du …) ».

**`private.transfer_line_post(org)`**, in this order (one transaction, the command's):
1. Unplanned remittances and sweeps (one `ledger_post_set`), their advances (one `ledger_post_set` + `client_advance`
   rows), the pending rows, the returns and unplanned returns (`ledger_reverse`, one per part, few), the bookings of
   these parts (seq 1..k on the line: `max(seq) + row_number() over (partition by line order by n)`), transfers
   `returned` with `return_entry_id` (by the array of their ids, keyed as l.1015-1020), payout accounts returned.
2. The planned parts (`payout`, `sweep`, `fee`): `private.bank_booking_begin()`, their rows into `_bank_booking`
   (method `ops`, `decided_by = auth.uid()`, the motif), `pg_temp._bb` built with **exactly the columns
   `private.post_bank_bookings` builds** (its select list l.1189-1238, copied; `book_minor` = the part's amount), then
   `private.bank_booking_post_rows(org)` unchanged: it numbers its bookings after step 1's, posts settlements, covers
   and breach rows, books runs, deletes the line's review, runs `ledger_check_now()` and checks the line booked whole.
   Only these kinds enter `_bank_booking`, whose `unique nulls not distinct (bank_transaction_id, transfer_id)` (l.487)
   admits one transfer-less row per line: the `fee` (at most one per line, §2.4.0); the transfer-less unplanned parts
   stay in step 1. pgTAP 036 checks the two `_bb` builds have the same columns in the same order.
3. Without planned parts: delete the line's review, `private.ledger_check_now()`, the line's signed completeness
   (`private.bank_line_cash_moved` = signed line, else LG001), `set constraints public.bank_line_booking_complete
   immediate` then `deferred`.

### 2.8 Locks — the job's order (l.1102-1118), plus the drafts and the generated files
`private.transfer_line_locks(p_line uuid, p_parts jsonb)` collects the keys without locks (the transfers named; every
member of a class-B line's PmtInf; every rule-3b candidate of a class-N line; the transfers of the unplanned bookings an
unplanned return names), then locks, each set in id order:
1. runs `FOR UPDATE`: the transfers' runs **and the live `draft` run of every client of an unplanned part** (read by
   `remittance_run_pending_uq`'s key, re-read under the lock);
2. `client_payout_account` `FOR NO KEY UPDATE`: the accounts a return marks `returned`;
3. `bank_account` `FOR SHARE`: the line's, the transfers' debtor and creditor accounts, the own account of the
   counterparty IBAN;
4. `payment` `FOR KEY SHARE`: the payments of the payout parts' runs' lines late at this date (6b-1 concurrency-2,
   l.1153-1185);
5. `pg_advisory_xact_lock(hashtext('payments:' || org))` (always: every part but a sweep's or a fee moves 4670);
6. `bank_transaction` `FOR NO KEY UPDATE`: the line and the debit lines `returns_line_id` names;
7. `pg_advisory_xact_lock(hashtext('remit:' || org))`;
8. `transfer_file` `FOR SHARE`: the transfers' current files, the PmtInf's file, the account's generated files (2.4.6);
9. `bank_transfer` `FOR UPDATE`: every key transfer (all members of a PmtInf, booked or not).
The rules are then read under these locks (stale between the options read and the command → `split_changed` or a rule's
refusal, never a wrong booking). The funds pass takes the same order, so the job and the command serialise on the line
(the job re-checks `booked` and skips it; `apply_bank_bookings` writes no review on a booked line, l.1574-1586).

### 2.9 Compare and set, idempotency, replay
- `private.transfer_line_text()`: the parts in order, each `kind:transfer_or_client:amount:P:advance:returns_line`, joined
  by `;`, then `|drafts:` and the draft run ids requeued. The options read (§2.11) and the preview compute it with the
  same function on the same rules; the command recomputes it under the locks; any difference → `split_changed`.
- Replay: `command_replay`/`command_record` on (`book_transfer_line`, key, request). A second call with a new key on the
  same line → `already_booked`. The entries' keys (`remit:line:<line>:<n>`, …) cannot be reused: a line is booked once.
- The funds job: a line ops booked leaves `private.bank_booking_candidates` (booked lines excluded) for good.

### 2.10 Refusal codes and French labels
Raised as `transfer line booking refused: <code>` (check_violation); mapped in `lib/payments/transfer-lines.ts`
(6b-2a), every code tested present.

| Code | Label |
|---|---|
| `bad_request` | « La demande est incomplète ou mal formée : rouvrez la ligne et recommencez. » |
| `held_duplicate` | « Cette ligne est retenue comme doublon possible : traitez-la d'abord dans « Doublons possibles ». » |
| `already_booked` | « Cette ligne est déjà comptabilisée. » |
| `already_linked` | « Cette ligne est déjà rattachée ou classée. » |
| `line_is_payment` | « Cette ligne a été enregistrée comme le paiement d'un débiteur : elle ne peut pas être comptabilisée ici. Prévenez le support. » |
| `parts_do_not_add_up` | « Les montants choisis ne font pas exactement le montant de la ligne. » |
| `transfer_unknown` | « Ce virement n'est pas un virement du cabinet sur ce compte. » |
| `wrong_direction` | « Ce virement ne peut pas être comptabilisé sur une ligne de ce sens (débit ou crédit). » |
| `not_its_line` | « Cette ligne ne porte ni la référence de ce virement, ni celle de son lot dans son fichier. » |
| `transfer_cancelled` | « Ce virement est annulé : son débit se comptabilise comme « Virement hors reversement ». » |
| `already_debited` | « Ce virement est déjà débité : un second débit se comptabilise comme « Virement hors reversement ». » |
| `not_handed_out` | « Le fichier de ce virement n'a jamais été téléchargé : ce débit ne peut pas encore être comptabilisé. Vérifiez dans la banque d'où vient cet ordre et prévenez le support. » |
| `transfer_differs` | « Ce virement est d'un autre compte ou d'une autre devise que la ligne. » |
| `run_not_in_flight` | « Le reversement de ce virement n'est plus en cours : ce débit ne peut pas encore être comptabilisé comme le sien. Prévenez le support. » |
| `amount_differs` | « Le montant ne correspond pas à celui du virement. » |
| `before_execution` | « La ligne est datée d'avant l'exécution demandée de ce virement. » |
| `line_ambiguous` | « Plusieurs virements en cours ont ce montant : sans référence sur la ligne, impossible de savoir lequel la banque a exécuté. Demandez le détail à la banque. » |
| `batch_ambiguous` | « Plusieurs combinaisons des virements de ce lot font le montant de la ligne, ou le lot est trop grand pour le vérifier : demandez à la banque le détail du lot. » |
| `batch_mixed` | « Ce lot contient des remboursements ou des virements de natures différentes : il ne peut pas être comptabilisé ici. Demandez le détail à la banque. » |
| `not_cancelled_nor_booked` | « Ce virement n'est ni annulé ni déjà débité : comptabilisez la ligne comme « Débit d'un reversement ». » |
| `client_unknown` | « Ce client n'est pas un client du cabinet. » |
| `client_iban_mismatch` | « Le compte crédité n'est pas un compte de reversement enregistré de ce client. » |
| `client_ambiguous` | « Ce compte de reversement est enregistré pour plusieurs clients : prévenez le support. » |
| `payout_in_flight_matches` | « Un reversement en cours de ce montant vers ce compte peut être ce débit : comptabilisez-le comme « Débit d'un reversement ». » |
| `own_account_unknown` | « Le compte crédité n'est pas l'un de nos comptes propres enregistrés. » |
| `sweep_in_flight_matches` | « Une quote-part du cabinet en cours de ce montant peut être ce débit : comptabilisez-la comme son débit. » |
| `sweep_file_pending` | « Un fichier pas encore téléchargé contient une quote-part du cabinet calculée avant ce virement : annulez d'abord ce fichier (avant téléchargement, la quote-part est recalculée au fichier suivant), puis recommencez. » |
| `fee_not_allowed` | « Des frais bancaires ne se comptabilisent ici qu'à côté d'un virement du cabinet, sur sa propre ligne. » |
| `not_a_return` | « Cette ligne n'est pas un crédit qui revient. » |
| `return_before_debit` | « Le débit de ce virement n'est pas comptabilisé, ou il est daté d'après ce retour. » |
| `already_returned` | « Ce virement est déjà revenu. » |
| `return_differs` | « Ce retour ne correspond pas au virement (montant supérieur, ou virement sans débit comptabilisé). » |
| `advance_settled` | « L'avance liée à ce virement a déjà été en partie récupérée : ce retour ne peut pas être comptabilisé ici. Prévenez le support. » |
| `unsplit_count` | « Le relevé compte un autre nombre de nos virements dans cette écriture. » |
| `unsplit_id_missing` | « Le virement dont la ligne porte la référence doit faire partie des virements nommés. » |
| `split_changed` | « La situation a changé depuis l'affichage (sommes en attente, brouillon, virements) : rouvrez la ligne pour voir la nouvelle répartition. » |
| `posting_failed` | « La comptabilisation a été refusée par les contrôles du grand livre : rien n'est enregistré. Prévenez le support. » |
« not allowed » and « a reason is required » keep their existing labels; the lock timeout (SQLSTATE 55P03, `lock_timeout
2s`) gets a new code `busy`: « La ligne est en cours de traitement ; réessayez dans un instant. »

### 2.11 Reads (6b-2a, used by 6b-2b's pages)
Both `SECURITY DEFINER`, money staff of the line's servicer only (`private.money_staff_org_ids()`; another servicer's
line, a client member, a collector → null), volatile (they build temporary tables, `on commit drop`), keyed (no
sequential scan of `bank_transfer`, `bank_transaction`, `transfer_file_item`; `enable_seqscan = off` where 6b-1 sets it).
- `public.transfer_line_options(p_bank_transaction_id uuid) returns jsonb`:
  `{class, kind, direction, amount_minor, unsplit_ours, proposals: [{action, parts: [{kind, transfer_id, client_id,
  returns_line_id, amount_minor, end_to_end_id, run_id, run_number, client_name, status}], preview}], members:
  [{transfer_id, kind, status, amount_minor, run_number, client_name, end_to_end_id, in_proposal}], candidates:
  [...], refusal}`. Proposals per class: E debit — t live: `payout(t)` (+ `fee` when the line > N); t cancelled/booked/
  returned: `unplanned_payout(t)` (`unplanned_sweep`) (+ `fee`); E credit — t booked: `payout_returned(t)` (+ `fee` when
  the line < N); t with an open unplanned booking: `unplanned_payout_returned`; B debit — the unique subset (§2.5) or
  `refusal: batch_ambiguous` with `members`; B credit — the unique subset of booked members; N debit — the one rule-3b
  candidate, else the client by IBAN (`unplanned_payout(c)`), else our own IBAN (`unplanned_sweep()`), else `refusal`
  (`line_ambiguous` or nothing); O debit — client or own IBAN; client/own credit without our id — the open unplanned
  payouts to that IBAN of the line's amount (`unplanned_payout_returned`), when exactly one; U — no proposal,
  `candidates` (our transfers on the account a part may name: payouts and sweeps `in_file` in a handed-out file, booked
  and not returned; ≤ 200, most recent first). `action` ∈ `payout` (« Débit d'un reversement »), `lot` (« Débit d'un
  lot de reversements », mixed planned and unplanned), `unplanned_payout` (« Virement hors reversement »),
  `unplanned_sweep` (« Virement au compte propre »), `returned` (« Virement revenu »), `detail` (U).
- `public.transfer_line_preview(p_bank_transaction_id uuid, p_parts jsonb) returns jsonb`: `{ok, why, parts: [{…,
  paid_minor, advance_minor, late}], drafts: [{run_id, number}], expected_text}`; the same `transfer_line_check` with
  `strict => false` (never raises a refusal; returns `why`), no lock taken. `late` = the payout part's run has a positive
  live line whose `latest_execution_date` < the line's date (a breach row will be written).

### 2.12 Redefinitions in 6b-2a (each copied from the file named; only the stated change)
- `private.bank_line_booking_guard` (20261116090000): `fee` also on a debit of kind `transfer_out` or `batch_unsplit`
  and on a credit of kind `own_transfer_in` / `client_transfer_in`; `payout_returned` / `sweep_returned` also on those
  two credit kinds; on a line with `unsplit_ours > 0` the planned and return kinds in either direction; the two new
  kinds: entry `reversal` whose reversed entry is the entry of an `unplanned_payout` (`unplanned_sweep`) booking of the
  same transfer (or of none), on a credit of kind `return`, `own_transfer_in` or `client_transfer_in`. Still one keyed
  lookup per row.
- `private.apply_debit_decisions` (20261111090000 l.3726): a skipped row whose `why` is `own_transfer_line` is reviewed
  `own_transfer_line` (not `changed`): S20's a04/a05, OQ-84 (i).
- `private.run_transfer_checks` (20261116090000 l.3165): new alerts `transfer_unknown` (P0; the lines the job reviewed
  so, not booked nor linked) and `double_payout_open` (an advance of cause `double_payout`, open = amount − settlements,
  0 once its entry is reversed); `payout_returned` also for an unplanned payout's return (its reversed remittance's
  source a `bank_transaction`, or a cancelled x); `sweep_returned` also for `unplanned_sweep_returned`;
  `bank_line_unbooked` also counts, after one business day, an unsplit debit holding ours (`batch_unsplit`,
  `unsplit_ours > 0`), a credit naming our lot, an own or client credit carrying our RMT/SWP id (S16), each not booked
  nor linked (inventory: l.3393-3407 missed them).
- `private.pending_item_deadlines` (20261116090000 l.3848) and the worker's `_held_to` (`jobs/remittances.py` l.595,
  parity): a `payout_returned` item whose reversed remittance is an **unplanned** payout of x takes the earliest latest
  execution date of x's run's positive dated lines **released included** (the run was cancelled: its lines are
  released; that is the R124-6 date of the money that came back, Q7's default). An unplanned payout to a client with no
  transfer has no line: its returned item has no deadline (as an advance's), recorded in OQ-36.
- `public.assign_payment` and `public.resolve_duplicate` (20261116090000 l.5564, l.5486), hint only (S23 is not booked
  in 6b-2): « Ce paiement vient d'une ligne qui porte la référence de l'un de nos propres virements (reversement,
  quote-part du cabinet, lot de notre fichier) : c'est ce virement qui revient, pas le paiement d'un débiteur. Il ne
  s'affecte à aucun dossier, et Collectoo ne peut pas encore le comptabiliser comme le retour de ce virement (un
  paiement enregistré ne se défait pas) : prévenez le support. » — and for the duplicate: « … Lue ainsi avant la
  correction de l'import, elle ne peut être ni libérée comme un paiement ni encore comptabilisée comme ce retour : elle
  reste dans « Doublons possibles ». Prévenez le support. » (Build: check whether « Libérer » can release such a held
  line as a `return`; if it can, the text says so instead.) Their page twins change with them (6b-2a, vitest):
  `payment_own_transfer_line` and `duplicate_own_transfer_line` (`lib/boarding/forms.ts` l.621-626) and
  `OUR_TRANSFER_PAYMENT_NOTE` (`lib/payments/matching.ts` l.286-287) drop « par l'équipe (écran à venir) » for the same
  « Collectoo ne peut pas encore le comptabiliser comme le retour de ce virement … prévenez le support ».

### 2.13 How a booked line leaves « À classer »
Every « À classer » branch of `public.debit_queue` already excludes a line with a booking (l.2416-2431); the review row
is deleted by the posting; `cancelled_transfer_debited`, `transfer_debited_twice`, `transfer_not_handed_out`,
`transfer_unknown` and `bank_line_unbooked` exclude booked lines; `transfer_late_lines` too (l.2563-2591), so the P0
alert of a cancelled transfer's late debit stops once it is booked. A transfer held `already_debited`
(`transfer_hold_reason`, which reads the debit whether booked or not) stays held: the booking does not release it (with
the switch off no re-issue exists; 6b-3 decides its fate). The line appears in « Traités » with
`decision` = its bookings' kinds joined by `+` (l.2468); labels (6b-2a, `lib/payments/debits.ts` `DECISION_LABEL`):
`payout` « Débit d'un reversement », `sweep` « Débit de la quote-part du cabinet », `unplanned_payout` « Virement hors
reversement », `unplanned_sweep` « Virement au compte propre », `payout_returned` « Reversement revenu »,
`sweep_returned` « Quote-part revenue », `unplanned_payout_returned` « Virement hors reversement revenu »,
`unplanned_sweep_returned` « Virement au compte propre revenu », `fee` « Frais bancaires ».

---

## 3. 6b-2b — migration `20261117120000_transfer_line_pages.sql`

### 3.1 Mis-booking guards (with the screen that replaces them)
- `public.link_debit` (20261111090000 l.3290): `fee` and `explained` refused `payout_candidate` on a debit of class N
  that a rule-3b payout or sweep candidate may be; refused `client_payout_line` on a debit whose counterparty is a
  client's confirmed payout IBAN; `explained` refused `own_transfer_out_line` on a `transfer_out` debit to our own IBAN
  (S14: money from client funds to our account is booked, never explained; I9). Labels: « Cette ligne a le montant d'un
  reversement (ou d'une quote-part) en cours et ne porte aucune référence : comptabilisez-la comme son débit (« Débit
  d'un reversement »), ou attendez que ce virement soit débité. », « Ce débit va vers un compte de reversement d'un
  client : il se comptabilise comme « Virement hors reversement » (ou comme le débit de son reversement en cours). »,
  « Un virement vers notre compte propre se comptabilise (« Virement au compte propre »), il ne se classe pas sans
  comptabiliser. »
- `public.debit_queue` (20261116090000 l.2336, same signature): « Frais » leaves out those lines; « À classer » lists
  them with `review_reason` `payout_amount_match` (candidates: the transfers) or `client_payout_iban` (the client),
  keyed from the in-flight payouts (few) to the account's lines by `(bank_account_id, booking_date)`, as
  `transfer_debit_may_be_seen` reads them (l.3440). Labels: « Débit sans référence du montant d'un reversement en cours
  sur ce compte : s'il s'agit de ce reversement, comptabilisez-le comme son débit. », « Débit vers le compte de
  reversement d'un client, sans référence du cabinet : virement hors reversement (ou débit d'un reversement en cours
  sans sa référence). »

### 3.2 Hints and texts reworded now that the screen exists
SQL (copied whole, hint only): `private.post_bank_bookings` (l.1468-1471) and `private.post_debit_links` (l.2113-2115):
« Cette ligne est un débit ou un retour de nos propres virements (reversement, quote-part du cabinet, lot de notre
fichier) : elle se comptabilise depuis le relevé, automatiquement à l'import ou par l'équipe dans « Débits et retours »
(débit d'un reversement, virement hors reversement, virement au compte propre, virement revenu). Elle ne se rattache
pas à un paiement et ne se classe pas sans comptabilisation. »; `public.release_own_credit` (l.4636-4638): « … sinon
par l'équipe dans « Débits et retours » (« Virement revenu »). Il ne devient jamais le paiement d'un débiteur ni un
approvisionnement. »
Web (`lib/boarding/forms.ts`, `lib/payments/debits.ts`; vitest `debits.test.ts` l.1467, 1502 and `transfers.test.ts`
l.1243, 1268 follow):
- `PAYOUT_BOOKED_WHEN`: « automatiquement à l'import quand la ligne porte sa référence RMT ou celle de son lot ; sinon
  l'équipe la comptabilise dans « Débits et retours » (« Débit d'un reversement ») »; `FILE_BOOKED_WHEN` the same for
  the sweep (« Débit de la quote-part du cabinet »).
- `own_transfer_line`, `own_credit_own_transfer_line`: « … par l'équipe dans « Débits et retours » … ».
- `OUR_TRANSFER_CREDIT_NOTE`: « Crédit portant la référence de l'un de nos virements (reversement ou quote-part du
  cabinet) : c'est ce virement qui revient, sans que la banque l'ait signalé comme un retour. Comptabilisez-le avec
  « Virement revenu » ; il ne devient ni le paiement d'un débiteur ni un approvisionnement. »
- `OUR_LOT_CREDIT_NOTE`, `OUR_LOT_FOREIGN_E2E_NOTE`, `OUR_LOT_OWN_CREDIT_NOTE`: « … c'est ce lot, ou des virements de ce
  lot, qui reviennent. « Virement revenu » propose les virements du lot dont les montants font seuls celui de la ligne ;
  sinon, demandez à la banque le détail du retour et prévenez le support. » (+ `OUR_LOT_REFUND_BACK_NOTE` unchanged.)
- `UNSPLIT_OURS_NOTE`: « … son montant est celui de toute l'écriture, rien n'est comptabilisé automatiquement. Si la
  banque vous donne le détail et qu'il ne contient que nos virements (et ses frais), comptabilisez-la avec
  « Comptabiliser d'après le détail de la banque » ; s'il contient le paiement d'un débiteur, un remboursement ou un
  approvisionnement, elle ne peut pas être comptabilisée ici : prévenez le support. »
- `DEBIT_REVIEW` (debit words; the credit words follow): `cancelled_transfer_debited` « … Rien n'est comptabilisé :
  vérifiez dans la banque, puis comptabilisez-le comme « Virement hors reversement » (risque de double paiement). »;
  `transfer_debited_twice` « … la banque l'a peut-être exécuté deux fois. Vérifiez avec la banque, puis comptabilisez ce
  second débit comme « Virement hors reversement ». »; `batch_partial` « Lot débité pour un autre montant que ses
  virements en cours (un virement manque, a été rejeté, ou un virement déjà débité l'a été de nouveau) : « Débit d'un
  lot » le comptabilise si une seule combinaison de ses virements fait ce montant ; sinon, demandez le détail à la
  banque. »; `transfer_differs` « … si la banque a prélevé ses frais sur la même ligne, comptabilisez-la comme « Débit
  d'un reversement » et frais ; sinon, vérifiez dans la banque. »; `own_transfer_out` « Virement émis vers l'un de nos
  comptes sans ordre de Collectoo : comptabilisez-le comme « Virement au compte propre » après vérification dans la
  banque. »; `own_transfer_line` (new, M2b pass, 6b-2a wording kept: « Le passage des paiements a écarté cette ligne :
  elle porte la référence de l'un de nos virements ou de nos lots, et ne se rattache à aucun paiement ni remboursement. »).

### 3.3 Statement « Suivi » — `private.remittance_statement_build` (from 20261116090000 l.3988) and `releve-reversement-fr-3`
- The payload drops `follow_up` and adds **`previous_payouts`**: the events, posted after the client's previous
  statement's K (`max(remittance_statement.known_at) < r.known_at`, same client and currency; −∞ for the first) and at
  or before this run's K (`r.known_at`), of the client's earlier runs of the currency with `net_minor > 0` (ADR-0012:
  `ledger_entry.posted_at`, `remittance_run.cancelled_at` against K; the dates shown are effective dates). One entry
  per event, ordered by its date then the run number:
  - `debited`: the run's transfer's (or chain's) planned debit booking — `{run_number, amount_minor, end_to_end_id,
    on: debit date}`;
  - `returned`: its return booking — `{…, debited_on, on: return date, repaid: 'here' | 'run' | 'pending', repaid_by}`
    — `here` when this run holds its `payout_returned` item, `run` when a run approved by K holds it (`repaid_by` its
    number), else `pending`;
  - `cancelled`: the run cancelled (`cancelled_at` in the window) — `{…, on}`;
  - `executed_after_cancellation` / `debited_again`: an unplanned booking of one of the run's transfers posted in the
    window, x cancelled / booked — `{…, unplanned_minor, on, here}` (`here` when this run holds that entry's −A line).
    A run with both a `cancelled` and an `executed_after_cancellation` event in one window gets the latter only.
  Unplanned payouts with no transfer (S13) are not « Suivi » events (their −A line is in « Sommes encaissées »).
- Renderer (`remittance/statement.py` `_previous_payouts` in place of `_follow_up`, `TEMPLATE_VERSION =
  "releve-reversement-fr-3"`, `TEMPLATE_VERSIONS` = fr-3 only: stored statements are never re-rendered; a payload with
  `follow_up` is refused `payload_version`); French:
  - `debited` « Reversement RV-… : virement de 1 640,00 € (référence RMT…) débité de notre compte dédié le 03/11/2026. »
  - `returned` + `here` « Reversement RV-… : virement de 1 640,00 € débité le 03/11/2026, revenu impayé le 05/11/2026 ;
    son montant figure dans le présent reversement (« Virement revenu impayé — reversé à nouveau »). » · `run` « … ;
    reversé à nouveau par le reversement RV-2026-000003. » · `pending` « … ; son montant vous sera reversé par un
    prochain reversement. »
  - `cancelled` « Reversement RV-… annulé le 03/11/2026, avant que son virement soit remis à la banque. » (true while the
    cancellation after download is off: a run is then cancelled only before its file is downloaded; 6b-3 rewords it for
    a cancellation after download. M2c-5's « virement annulé avant son exécution » is dropped: the bank may still
    execute it, S01.)
  - `executed_after_cancellation` « Reversement RV-… annulé le 03/11/2026 : la banque a néanmoins exécuté son virement de
    1 640,00 € le 05/11/2026 ; ce montant, que vous avez reçu, figure dans le présent reversement (« Virement exécuté
    hors reversement »). » (not `here`: « … ; il sera pris en compte dans un prochain reversement. »)
  - `debited_again` « Reversement RV-… : la banque a exécuté son virement une seconde fois le 05/11/2026 (1 640,00 €) ;
    ce second virement, que vous avez reçu, figure dans le présent reversement (« Virement exécuté hors reversement »,
    et « Avance du cabinet » pour ce qui ne vous était pas dû). » (not `here`: « … ; il sera pris en compte dans un
    prochain reversement. »)
  - none: « Rien à signaler sur vos reversements précédents depuis le relevé RV-… du jj/mm/aaaa. » (first statement:
    « Aucun reversement précédent à suivre. »).
- CSV unchanged (lines only); renderer version unchanged (the template version changes); golden PDF regenerated; read
  cost: the client's runs by `remittance_run_client_idx`, their transfers by run, bookings by
  `bank_line_booking_transfer_idx`, entries by key.

### 3.4 Reads for the run page, « Virements » and the client space
- `public.remittance_run_payout(p_run_id uuid) returns jsonb` (money staff): `{transfers: [{id, status, end_to_end_id,
  debited_on, returned_on, line_id}], settled_on, settlement_minor, commission_minor (Dc), advances_recovered_minor
  (Da), advances: [{cause, amount_minor, open_minor, created_on}], unplanned: [{line_id, kind, amount_minor, on,
  paid_minor, advance_minor}], last_failure}`.
- `public.transfer_bookings(p_transfer_ids uuid[]) returns table (transfer_id, debited_on, returned_on, debit_line_id,
  return_line_id, unplanned_on)` (money staff; ≤ 500 ids; keyed).
- The client space reads `remittance_run.booked_on` with its embed (table grant, RLS rows: no new function).

---

## 4. Worker

6b-2a:
- `payments/debits.py`: `P0_REVIEWS` += `TRANSFER_UNKNOWN`; `unique_subset(amounts, target)` (the SQL twin's bounds,
  pure) for the Hypothesis oracle.
- `jobs/remittances.py` `_held_to`: the unplanned branch of §2.12 (parity test with `private.pending_item_deadlines`).
- `synth/camt053.py` + `cli.py`: `--debit-charge MINOR` (each individual debit booked for N + charge on one entry, the
  charge in its `Chrgs`), `--unflagged-returns` (returns written without a return code or reversal indicator, from the
  payee's IBAN), and `--csv` with the end-to-end column dropped (`expected_csv(bank_ids=False)` exists); round-trip
  tests with the parser.
6b-2b:
- `remittance/statement.py`, `statement_pdf.py`: fr-3 (§3.3).

---

## 5. Web (6b-2b unless marked; `apps/web/src`, `lib/database.types.ts` regenerated in each slice)

### 5.1 « Débits et retours » (`app/backoffice/encaissements/debits/`)
- `lib/payments/transfer-lines.ts` (new, pure): parse `transfer_line_options` / `transfer_line_preview`; the refusal
  labels (§2.10; **6b-2a** ships the map and `transferLineErrorCode`); the action labels; the effect sentences below;
  `offersTransferLineBooking(row)` (our lines, the payout and client-IBAN candidates).
- `actions.ts`: `previewTransferLine(formData)` (rpc `transfer_line_preview`) and `bookTransferLine(formData)` (rpc
  `book_transfer_line`: UUID key, the parts as the preview returned them, `expected_text`, the motif); authorisation in
  SQL; `revalidatePath` of the page, the run pages and « Virements ».
- `page.tsx` `LineActions`: for a line `offersTransferLineBooking`, read `transfer_line_options` and show one button per
  proposal; on a U line « Comptabiliser d'après le détail de la banque ». Sheets (`debit-actions.tsx`):
  - **« Débit d'un reversement »** / **« Débit d'un lot de reversements »**: « La banque a débité ce virement du cabinet :
    la ligne est comptabilisée comme son débit, comme l'import le fait quand la ligne porte sa référence. » Members
    table (lots): « Reversement », « Client », « Référence », « Montant », « Dans cette ligne » (« débit » / « second
    débit, hors reversement » / « non débité par cette ligne »). Effects per payout: « RV-… (MARTIN SAS) : 1 640,00 €
    débités le 05/11/2026 ; ses factures sont réglées par compensation (360,00 €) ; le reversement passe à « Débité ». »;
    late: « Ce débit est postérieur à la date limite d'exécution du 30/10/2026 : le dépassement du délai est enregistré. »;
    fee: « Frais bancaires de 1,20 € prélevés sur la même ligne, à la charge du cabinet. »; class N: « Cette ligne ne
    porte aucune référence : seul ce reversement en cours a ce montant vers ce compte. Vérifiez dans la banque avant de
    comptabiliser. » Button « Comptabiliser le débit ».
  - **« Virement hors reversement »**: « La banque a exécuté un virement vers MARTIN SAS hors de tout reversement en cours
    (virement annulé exécuté quand même, second débit d'un virement, ou virement saisi à la banque). Il est comptabilisé
    tel quel : le client a reçu cet argent. » Effects: P = A « 1 640,00 € déjà reçus par MARTIN SAS seront déduits de son
    prochain reversement (sommes du reversement RV-… annulé, encore à reverser) ; avance du cabinet : 0,00 €. »; 0 < P <
    A « 1 200,00 € … seront déduits … ; avance du cabinet de 440,00 € (ce que le client a reçu en plus de ce qui lui
    restait dû), à récupérer selon son mandat — ce recouvrement n'est pas encore géré dans Collectoo. »; P = 0 « Rien
    n'est déduit du prochain reversement de MARTIN SAS ; avance du cabinet de 1 640,00 € (le client a reçu ce montant
    sans qu'il lui soit dû), à récupérer selon son mandat — ce recouvrement n'est pas encore géré dans Collectoo. »;
    draft: « Le brouillon RV-… sera recalculé ; sa validation en cours, s'il y en a une, est interrompue. » Button
    « Comptabiliser le virement ».
  - **« Virement au compte propre »**: « Virement du compte dédié vers notre compte propre FR76 •••• 1234 sans ordre de
    Collectoo (ou exécuté après son annulation) : comptabilisé comme quote-part du cabinet virée au compte propre. »;
    « La quote-part du cabinet en attente sur le compte dédié baisse de 500,00 €. »; when it goes below zero: « Elle
    devient négative (−120,00 €) : le cabinet doit cette somme au compte dédié ; demandez un approvisionnement depuis le
    compte propre. »
  - **« Virement revenu »**: « La banque du bénéficiaire a renvoyé ce virement du cabinet : il est comptabilisé comme
    revenu, comme l'import le fait quand la banque le signale comme un retour. » Payout: « RV-… : 1 640,00 € de nouveau
    dus à MARTIN SAS, proposés dans un prochain reversement avec la date limite de leurs encaissements ; son compte de
    reversement FR76 •••• 1234 est bloqué jusqu'à son remplacement ou sa reconfirmation. »; sweep: « La quote-part de
    500,00 € revient sur le compte dédié : elle sera virée de nouveau au compte propre. »; unplanned: « Le virement hors
    reversement du 05/11/2026 (1 640,00 €) revient : l'avance du cabinet de 440,00 € est annulée et 1 200,00 € sont de
    nouveau dus à MARTIN SAS. »; fee: « Frais de la banque déduits du retour : 1,20 €, à la charge du cabinet. » Button
    « Comptabiliser le retour ».
  - **« Comptabiliser d'après le détail de la banque »** (U): « La banque a regroupé plusieurs opérations dans cette
    écriture sans en donner un détail exploitable. Si elle vous a donné ce détail, nommez nos virements qu'elle contient
    (débit ou retour) et ses frais : la somme doit faire exactement le montant de l'écriture. Si l'écriture contient
    aussi le paiement d'un débiteur, un remboursement ou un approvisionnement, elle ne peut pas être comptabilisée ici :
    prévenez le support. » Candidates with « débit » / « retour », a fee field, « Vérifier » (preview), then
    « Comptabiliser ».
  - Every sheet: « Motif (ce que montre le relevé ou la banque) », required; the preview's effects re-read on open; a
    refusal shown with its label.
- The P0 badge (`P0_DEBIT_REVIEWS`) unchanged (it already holds `transfer_unknown`).

### 5.2 Other pages
- Run page (`reversements/[id]/page.tsx`, reads `remittance_run_payout`): « Débité de notre compte le 03/11/2026 »;
  « Commission réglée par compensation le 03/11/2026 : 360,00 € » (D = Dc; when Da > 0 « Factures et avances réglées
  par compensation le … : … »); overrun advance « Avance du cabinet de 50,00 € au débit : le virement dépassait ce qui
  restait dû au client (une imputation annulée après la validation) ; à récupérer selon son mandat — ce recouvrement
  n'est pas encore géré dans Collectoo. »; returned banner « Virement revenu impayé le 05/11/2026 : 1 640,00 € de
  nouveau dus au client, proposés dans un prochain reversement ; son compte de reversement est bloqué jusqu'à son
  remplacement ou sa reconfirmation. » (+ « Reversé à nouveau par RV-… » once booked); unplanned « La banque a exécuté
  le virement de ce reversement une seconde fois le … (… ) : comptabilisé hors reversement, avance du cabinet de … » /
  « … exécuté après son annulation le … »; a draft requeued: « Brouillon recalculé : un virement hors reversement a été
  comptabilisé le … ».
- « Virements » list and file page (`lib/remittance/transfers.ts`, reads `transfer_bookings`): « Débité le jj/mm/aaaa »,
  « Revenu impayé le jj/mm/aaaa », « Annulé — exécuté par la banque le jj/mm/aaaa, hors reversement »; the sweep's
  status alike; the `servicer_funds_unswept` banner on the overview (« La quote-part du cabinet attend depuis plus de
  deux jours ouvrés sur le compte dédié sans virement au compte propre. »).
- Client space (`lib/remittance/documents.ts` `runStatusText(status, net, bookedOn)`): « Virement débité de notre compte
  le 03/11/2026 »; the returned texts (L2's) unchanged.
- « Contrôles » (`lib/payments/debits.ts` checks labels; **6b-2a** ships them): `transfer_unknown` « Débit portant une
  référence de virement du cabinet (RMT, SWP) ou un lot que Collectoo ne connaît pas : vérifiez dans la banque. »
  (P0); `double_payout_open` « Avance du cabinet après un virement exécuté hors reversement : à récupérer auprès du
  client — ce recouvrement n'est pas encore géré dans Collectoo. ».

### 5.3 Screenshots (mobile + desktop, `docs/screenshots/`, 6b-2b)
New: `m2c-debits-reversement` (« Débit d'un lot de reversements » on a partial batch line), `m2c-virement-hors-
reversement` (P = 0 and P = A sheets), `m2c-virement-revenu`. Retaken: `m2c-reversement-debite` (dates, commission
line), `m2c-virement-debite` (dates), `m2c-client-reversements` (debit date), `m2-checks` (new alerts).

---

## 6. Tests (written first; each slice red before its code)

### 6.1 pgTAP `036_transfer_line_ops` (6b-2a; 6b-2b appends group P)
Fixtures copied from 035's (servicer aa, accounts cf/c0, clients a1–a9, `pg_temp` helpers `run`, `gen`, `download`,
`stmt`, `as_user`); `run_payment_checks` asserted free of violations after each group (I8′, I12, I13, I14, I19, I20,
`bank_line_booked`).
- **A. Roles and request**: collector, read-only member, client admin, another servicer's admin, admin at aal1 →
  42501 (preview/options → null); empty motif → `a reason is required`; each `bad_request` case of §2.4.0; null
  `p_expected_text`.
- **B. Line state and replay**: `held_duplicate`, `already_booked` (a line the job booked), `already_linked`,
  `line_is_payment`; the same key and request → the same result, nothing posted twice; the same key, another request →
  command_replay's refusal; a new key on the booked line → `already_booked`.
- **C. Planned parts**: S08 `payout + fee` (remit:<t> N, settle:<run>, fee:<line> F, seqs 1–2, run and transfer booked,
  signed completeness); S08 without the fee part and S08b → `amount_differs`; S09 three members, one left out, the only
  subset → two payouts, the third `in_file` and its run `sent`; two members of equal amount → `batch_ambiguous`; a
  member of another PmtInf → `not_its_line`; S12 rule 3b booked; 3b for a re-issue (switch on in a subtransaction) →
  `not_its_line`; two candidates → `line_ambiguous`; another payee's IBAN → `not_its_line`; dated before execution →
  `before_execution`; a late ops payout writes its breach rows, an on-time one none; `transfer_cancelled`,
  `already_debited`, `not_handed_out`, `run_not_in_flight`, `transfer_differs`; **parity**: an ops `payout` part on a
  plain RMT line gives the same entries, lines and states as the job's booking of a twin line.
- **D. Unplanned payouts (Q4)**: S01 with A = P (run cancelled before download, its items re-reserved by c's draft):
  remittance A from x, pending −A, no advance, queue net −A, the draft requeued (job prepare, new token, `last_failure`
  code `unplanned_payout`), then the next run prepared and **approved** (no `items_changed`, no `balance_changed`), its
  gross = before − A; A > P (part of the items frozen in a later run): advance A − P, 4112[c] +(A − P), next run approved;
  S03 P = 0: advance A, queue net 0; P capped by what c is owed; two unplanned parts of one cancelled run in one call
  (Σ P ≤ pool); a later second unplanned booking on the same run counts the first's P (P₂ = 0); a draft queued for
  approval: the old token's approval returns `skipped`; `not_cancelled_nor_booked` for `ordered` and `in_file` x; S13:
  c's active and retired IBANs accepted (P = 0, advance A, source the line), an unknown IBAN `client_iban_mismatch`, an
  IBAN of two clients `client_ambiguous`, a reference-less line with a 3b candidate `payout_in_flight_matches`; S07 an
  unknown RMT-shaped id to c's IBAN booked as c's; S04 all members booked → unplanned × n with their advances; S05 live
  + re-executed → payout + unplanned; S02 (switch on): live + cancelled member → payout + unplanned, P from the
  cancelled member's run.
- **E. Sweeps**: S14 own IBAN, no sweep in flight → `servicer_sweep` to that own account; with a 3b sweep candidate →
  `sweep_in_flight_matches`, and `sweep(t)` books it; `own_account_unknown`; `sweep_file_pending`; S15 → unplanned
  sweep; 4679 in debit → `servicer_shortfall` at the next check.
- **F. Returns**: S16 an `own_transfer_in` with our SWP id and a `client_transfer_in` with our RMT id as original →
  reversal `return:<line>:<t>`, `payout_returned` +N held to the run line's date, payout account returned, alert;
  short with a fee part; short without → `amount_differs`; more → `return_differs`; `return_before_debit` (both
  causes); `already_returned`; S20 a lot of two booked payouts → two reversals on one line (seq 1–2, distinct keys); an
  ambiguous lot → `batch_ambiguous`; a fee on a lot → `fee_not_allowed`.
- **G. Unplanned returns (S27)**: S01's unplanned payout returned → payout_returned +A and client_advance_reversal
  −(A − P), net +P, the advance's `double_payout_open` gone; again → `already_returned`; an advance with a settlement
  (seeded in a subtransaction) → `advance_settled`; a client-only one by IBAN; `pending_item_deadlines` gives the +A item
  x's run's released lines' earliest date; the S03-then-return residual pinned: the job books it as the planned payout's
  return (Q12).
- **H. Unsplit (S21/S22)**: the round-5 netted credit (our return 4 198,40 € + our other payout's debit 328,00 €) →
  `payout_returned` + `payout`; two debits of ours (d03) → two payouts; `unsplit_count`; `unsplit_id_missing`; a
  debtor's credit inside → `parts_do_not_add_up`.
- **I. Compare and set**: the preview's text books; a pending change between them (an item of the pool frozen by
  another run's approval) → `split_changed`; a draft created in between → `split_changed`.
- **J. Reads**: `transfer_line_options` per class gives the proposal the tests above book (E cancelled → unplanned, B
  partial → members and parts, N → 3b, U → candidates only); the preview never raises; tenant isolation.
- **K. Guard**: as service_role, a `fee` on an RMT line alone fails completeness (LG001); an
  `unplanned_payout_returned` row not reversing an unplanned entry → check_violation; `payout` on a credit line of a line
  not unsplit → check_violation; `payout_returned` on `own_transfer_in` accepted.
- **L. Alerts and reviews**: `transfer_unknown` (P0), `double_payout_open`, `bank_line_unbooked`'s new members (after one
  business day, not before); every P0 alert gone once its line is booked; the M2b pass reviews a04 `own_transfer_line`.
- **M. Funds pass**: a return reviewed `return_before_debit`; ops book its debit (S09) → one `process_debits` message
  with `funds_after` queued.
- **N. Mutants to kill** (listed in the PR): uniqueness check removed (the equal-amount case books); P without `earlier`
  (second booking P₂ > 0); pending row −P instead of −A (the next approval refuses); draft requeue removed (the next run
  pays twice: its gross); `remit:line` key without the part index (two parts collide); allocation lock skipped (the
  concurrency test deadlocks or I14 breaks).
- **P. (6b-2b)**: `link_debit` `payout_candidate`, `client_payout_line`, `own_transfer_out_line`; `debit_queue` lists
  those lines « À classer », not « Frais ».

### 6.2 Worker
- Unit (6b-2a): `unique_subset` against brute force on ≤ 12 amounts (Hypothesis; equal amounts, the complement side,
  the bounds) — the oracle for SQL parity; `P0_REVIEWS` = the alerts' P0 codes (a test reading both).
- Hypothesis, `ledger_machine.py` (6b-2a): rules `book_payout`, `return_payout`, `book_sweep`, `return_sweep`,
  `unplanned_payout` (P by §2.6.1), `unplanned_return`; invariants I2′, I8′, I12, I13 (4670 never in debit), I14 (owed =
  pending + in flight), I19 (oracle bank), I20, P ∈ [0, min(A, owed, pool)], queue net −P per unplanned booking, and «
  over the run, the client receives its net collections less commission plus its open advances ».
- Integration (6b-2a, `test_transfer_line_ops_integration.py`, through the real import, jobs and command as an aal2
  session): §7's E1–E9 then `synth camt053 --mode twice` → the job reviews `transfer_debited_twice` → ops book the
  options' proposal → RV-3 unchanged; a run cancelled before download + its superseded file's late debit → P = A, c's
  draft requeued, prepare + approve jobs, Martin's check (received = collections − commission); `--mode partial` → ops
  book the proposal, the left-out member's own debit next day booked by the job; `--csv` without the end-to-end column →
  rule 3b; `--debit-charge 120` → payout + fee; `--unflagged-returns` → « Virement revenu », the schedule drafts the
  `payout_returned` run keeping its deadline. SQL parity: `private.unique_subset` = the Python twin on 200 examples;
  `_held_to` = `pending_item_deadlines` for an unplanned return.
- Concurrency (6b-2a, two connections, as 6b-1's): the command against `cancel_remittance_run`, `transfer_file_download`,
  the approval job on c's draft, `request_refund` on a late line's payment, and the funds pass on the same line — one
  waits, no 40P01, never booked twice. Mutant: the runs locked after the allocation lock → deadlock.
- Stateful (6b-2a, `test_transfer_line_machine_integration.py`): a bank model executing files individually, as batch
  lines, partially, late, twice, returning; ops book every line through the options' proposal; after each step every
  line is booked or reviewed, I9/I19/I20/I13/I14 clean, no transfer booked twice, LG008 never raised.
- Scale (6b-2a, `test_transfer_line_scale_integration.py`): a 200-member PmtInf line short of one member: options < 1 s,
  command < 3 s; 5,000 members short of one: options < 5 s (unique or `batch_ambiguous`), command < 60 s; read counts
  bounded per member (`pg_stat_xact_user_tables`, stale statistics as 6a/6b-1); `docs/benchmarks/remittances.md`.
- 6b-2b: renderer fr-3 per event and repaid state (pytest), golden PDF, `payload_version` refusal.

### 6.3 pgTAP `037_statement_suivi` (6b-2b)
RV-1 approved; its debit booked after K₁ → RV-2's payload lists `debited` with the debit date; a debit booked between
RV-2's K and its statement's drawing → not in RV-2, in RV-3; a return after K₂ held by RV-3 → `returned`, `here`; held
by no run → `pending`; a run cancelled before download → `cancelled`; then its late debit booked unplanned → the next
statement lists `executed_after_cancellation`; a double execution → `debited_again`; N = 0 runs and other clients'
runs never listed; another servicer isolated; keyed reads (`pg_stat_xact_user_tables`).

### 6.4 vitest
6b-2a: every `transfer line booking refused:` code in the migration has a label (`transferLineErrorCode`); every
`DECISION_LABEL` kind; the new checks labels; the S23 texts say « ne peut pas encore » and promise no screen.
6b-2b: effect sentences for P = A, 0 < P < A, P = 0, the draft, the fee, the late breach; options parsing (every class);
`offersTransferLineBooking`; no « écran à venir » left in `lib/**`; `runStatusText` with the date; the Virements
labels; the reworded notes (each mutant: the old words — killed).

### 6.5 E2E (6b-2b; `make e2e`, CI `e2e`)
- `remittances.spec.ts`: approve → generate → download → « Transmis » → a synthetic statement of the debit → the job →
  « Débité le … » on the run, « Virements » and the client space; a returned payout → « Revenu impayé » banner, a new
  draft, the client's text.
- `payments-debits.spec.ts`: a second debit (`--mode twice`) → « Prioritaire » → « Virement hors reversement » (P = 0
  sheet) → motif → « Traités »; a partial batch line → « Débit d'un lot de reversements » (members shown) → booked;
  screenshots of §5.3.

---

## 7. Docs
- **ADR-0014** « M2c-6b-2a » and « M2c-6b-2b »: the departures of §1.3; the parts model; the only-subset rule; P and its
  conservative direction; the draft requeue; the two unplanned return kinds; the residual Q12; « Suivi » as of K. Also
  correct the 6b-1 body's deviation « Round-7 SQL hints and 033 kept » (ADR-0014 l.534-540): round 3 M4 reworded those
  hints and 033's classifier expectation (l.961-976); what was left was the « écran à venir » wording, handled here.
- **COMPLIANCE**: add **OQ-82** (counsel): recovering an unplanned or double payout — what paid a cancelled run's own
  waiting items is netted as a negative item in the client's next run, the excess is the servicer's advance recovered
  only under a claw-back clause, otherwise by a repayment request (M2c-7); a manual payout to the client's IBAN with no
  transfer is all advance (Q8); ⚖️ C. civ. 1302-1, 1347, 1348-2, with OQ-38. Update **OQ-34** (Q2: S25 stays to 6b-3,
  the two entry options of §8 Q2 named), **OQ-36** (the unplanned return's item deadline, §2.12), **OQ-81 (b)** (open,
  6b-3), **OQ-83** (a batch line short of members is booked by ops when only one subset makes it; `batch_mixed` stays),
  **OQ-84** (unflagged returns, lot credits and unsplit entries booked by ops per §2.4; (i) closed by the reason
  `own_transfer_line`; (e) and the payments made of our credits stay; (j) unchanged), **CPCE-08** (an ops booking of a
  late debit writes its breach rows; the members a batch line left out get theirs from the nightly check).
- **DOMAIN**: « Virement hors reversement », « Débit d'un reversement (par l'équipe) », « Virement revenu (par
  l'équipe) », « Suivi de vos reversements précédents », « Avance du cabinet » (cause double paiement).
- **Design** `m2c-remittances.md` §9.7 (the unplanned payout as built, P), §10 item 5 (« Suivi » built as of K), §12
  (annotation), §21 (6b-2a/2b); **ROADMAP** M2c-6b rows; **ARCHITECTURE** §4 (new keyed probes); **benchmarks**;
  **PROGRESS** at every commit.

---

## 8. Founder questions
Answer « 1 ok, 2 b … ». 1–7 are `m2c-6b-plan.md` §5, still unanswered: 6b-2 uses each default and keeps it open.

1. Switch on cancellation after download in 6b-3 once `034` passes? **Default yes** (OQ-81 (a)). 6b-2 does not depend on it.
2. Our refund's RFD debit that cannot be linked (S25)? **Default: in 6b-3, four eyes, the line booked as the servicer's
   loss (`servicer_loss` +4679 X / −5120 X ‖ +6780 X / −4689 X) and the refund closed as executed.** Choose: (a) no
   cash_out — the payer's money stays on 4710, the loss is the whole line; (b) the refund's cash_out of what is still
   unallocated, the loss only the excess. Default (a); the refund request then carries the loss entry as its
   `cash_out_entry_id` (I20's refund rule and the M2b position read it; the build checks both). ⚖️ OQ-34.
3. A copy of an executed file for the records? **Default no** (OQ-81 (c)).
4. An unplanned or double payout: **default** — what paid the cancelled run's own waiting items is a negative item in the
   client's next run (netted with whatever that run holds; the draft is recalculated at once); the excess is an advance
   recovered only under the claw-back clause, otherwise by a repayment request (M2c-7). ⚖️ new OQ-82.
5. Batch lines we cannot split (several refunds; `BtchBookg false` ignored): **default not bookable in 6b**; ask the
   bank (OQ-83).
6. Unplanned bookings by one admin or ops manager at aal2 with a motif: **default one person**; four eyes only for 2.
7. A returned payout's breach row « bloqué : virement revenu impayé »: **default yes** (OQ-36).
8. *(new)* A debit to a client's payout IBAN that matches no order (S13): **default — all of it is an advance** (nothing
   deducted from the next run); alternative: count it as paid up to what the client is owed.
9. *(new)* A debit of a payout whose file we never handed out (S06): **default — in 6b-3, booked as its run's payout (the
   bank executed exactly that order) with its never-downloaded file superseded; until then P0**, ops find out with the
   bank how it got that order.
10. *(new, with OQ-84 (j))* The bank's charge on our transfer's own line (S08, a short return S16/S19): **default — no
    cap**; ops book it with the bank's detail in the motif.
11. *(new)* A bank entry kept unsplit holding our transfers (S21/S22): **default — ops may book it from the bank's detail
    when it shows only our transfers (and a charge)**, the parts adding up and matching our count; otherwise it waits
    (M2c-7, the bank).
12. *(new)* A payout executed twice, then one of the two sent back (S03 + return): **default — booked by the import as
    the payout's return** (the client is owed it again; the double-payment advance stays to recover; its payout
    account is blocked until reconfirmed); alternative: always left to ops.

---

## 9. Risks and how this plan prevents them
| Risk | Prevention |
|---|---|
| A batch line booked to the wrong members (or the wrong client) | the only subset over every member, whatever its status (§2.5), else `batch_ambiguous`; ops confirm, never compose |
| The next run pays the unplanned money again | pending row −A + advance trigger = net −P; P counts reserved items; c's draft requeued in the same transaction; 036 approves the next run with A = P, A > P, P = 0 |
| Holding back a client's money as « paid » | P only from the cancelled run's own waiting items, capped by A and by what c is owed, minus what earlier bookings took; every approximation toward a smaller P |
| A reference-less line booked to the wrong payout | rule 3b with uniqueness over every in-flight candidate of the account (`line_ambiguous`), the counterparty IBAN when present |
| A double payout hidden as a fee or an explanation | 6b-2b refuses both on payout candidates, client-IBAN debits and own-IBAN debits; P0 alerts until booked |
| Over-sweep | `sweep_file_pending`; `servicer_shortfall` P0 for a sweep already handed out |
| Regression in the job's reviewed re-check | `post_bank_bookings` and `bank_booking_post_rows` untouched in 6b-2a; parity test ops vs job; 035 and 015–034 re-run |
| Deadlock | the job's lock order, drafts in the runs step; two-connection tests per writer; mutant |
| Stale page, wrong split | `p_expected_text` compare-and-set (`split_changed`) |
| Texts promising what the code does not do | « écran à venir » reworded with the screen (6b-2b), withdrawn now where 6b-2 does not book (S23); vitest sweeps |
