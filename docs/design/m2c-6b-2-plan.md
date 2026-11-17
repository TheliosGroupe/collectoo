# M2c-6b-2 build plan — ops book our transfer lines, then the pages and the statement's « Suivi »

Refines `docs/design/m2c-6b-plan.md` (§1.2 row 6b-2, §2.3, §2.6, §2.7, §4.1–§4.4, §5, §6) for what M2c-6b-1 actually
built (PR #29, head `ab1a1f8`, eight review rounds). Every departure from that plan is in §1.3 with its reason.
Shape ids `S01`…`S28` are the inventory of the lines 6b-1 sent to « ops' booking in M2c-6b-2 » (§1.1).
Line numbers `l.NNNN` are `supabase/migrations/20261116090000_debit_bookings.sql` at `ab1a1f8` unless another file is
named; re-read them on `main` once PR #29 is merged.

**[critic]** Three critics reviewed the draft against `ab1a1f8`: money (F1–F17), legal and texts (L1–L18), and
concurrency, security and operability (CSO-1–CSO-12). Each finding was re-checked against the code. The real ones are
folded in below and marked « [critic] » with their id. The rest are in §12 with the reason for rejecting them. §12
lists every finding and where it went.

**[critic2]** Two critics reviewed this revision against `dd8c6fb` (`main` 0099a11 + the plan; PR #29 merged): money,
ledger and legal (ML-1–ML-12), and concurrency, security and operability (CSO2-1–CSO2-14). Each finding was re-checked
against the code at `dd8c6fb`. The real ones are folded in below and marked « [critic2] <id> »; §12.2 lists every
finding, where it went, and the parts rejected with why. No slice boundary moves; only the order of 2c and 2d is pinned
(CSO2-5).

**Precondition.** **[critic]** There are four branches, one PR each, in this order (§1.4):
- `m2c6b-2a`, from `main` once PR #29 is merged (if it is not, stack on its branch and rebase before the PR);
- `m2c6b-2b`, from `main` once 2a is merged;
- `m2c6b-2c`, after 2b;
- `m2c6b-2d`, **[critic2] CSO2-5** after 2c. It does not depend on 2c's code, but production applies migrations in the
  order they merge, and a migration older than the last one applied is refused (`supabase db push`: « Found local
  migration files to be inserted before the last migration on remote database »). The order is therefore pinned
  2a → 2b → 2c → 2d. Each slice's migration takes its timestamp when its PR is opened, later than every migration on
  `main`, and `lib/database.types.ts` is regenerated after rebasing on the slice merged before. 6b-2a adds a CI step
  to the `db` job that fails when a migration the branch adds sorts before the latest migration on `origin/main`.

The cancellation-after-download switch (`private.feature_switch` `downloaded_file_cancellation`) stays **OFF** in all
four; 6b-3 switches it on. Some tests need a cancelled member of a live downloaded file, or a payout cancelled after its
file was handed out (S01, S02, the S04 variants). They switch it on inside their own rolled-back subtransaction, as
034/035 do. pgTAP 033 and 034 are not edited.

**Hard rules this plan keeps** (CLAUDE.md):
- every amount comes from the ledger and the database's rules, in integer minor units;
- entries are double-entry and append-only, with corrections by reversal;
- RLS on every exposed table;
- bookings are written only by `SECURITY DEFINER` functions;
- the command carries an idempotency key;
- migrations are forward-only;
- copy is in French;
- no banking or legal rule is invented: each unknown below is a founder question (§10) or a COMPLIANCE open question
  (§9), with a default.

---

## 1. Scope, split and size

### 1.1 Every inventory shape: how it is booked, or why it stays

Classes (§3.3): E = our id; B = our lot; N = no reference; O = a foreign reference; E∅ = an RMT/SWP-shaped id or TF
PmtInfId naming nothing of ours; U = an entry the bank kept unsplit.

| Id | Shape (inventory) | Exit in 6b-2 | Parts (§3.4) | Slice |
|---|---|---|---|---|
| S01 | RMT debit of a payout cancelled after its file was handed out (switch off: only a file closed while the switch was on, so real cases arrive with 6b-3; the tests switch it on) | **booked** when x's run is cancelled or booked. **[critic2] ML-4** x's run still approved or sent (x cancelled alone on evidence, or re-issued as x') → **left** → 6b-3 (`run_still_live`: this debit is the run's own payout, S10's late-predecessor booking) | `unplanned_payout(x)` (+ `fee` on its own line) | 2b |
| S02 | batch line: live members + a late cancelled member | **booked** (switch on in tests only; real cases arrive with 6b-3), **[critic2] ML-4** only when the cancelled member's run is cancelled or booked | `payout` × live + `unplanned_payout` × cancelled | 2b |
| S03 | second debit of a booked payout by its RMT id | **booked**, P = 0 | `unplanned_payout(x)` | 2b |
| S03r | **[critic F2]** a debit of a **returned** payout (its file executed again; or a second execution booked after the return of the first) | **booked**, P = what its return left owed | `unplanned_payout(x)` | 2b |
| S04 | batch line whose members are all booked/returned | **booked**, P per member (returned: S03r) | `unplanned_payout` × n (`unplanned_sweep` for a sweep PmtInf) | 2b |
| S05 | batch line = live members' first debit + a booked member's second | **booked** | `payout` × live + `unplanned_payout` | 2b |
| S06 | debit of a payout never handed out (ordered, or file never downloaded) | **left** → 6b-3 (Q9); **[critic F13]** a client part matching it is refused `payout_not_handed_out_matches` | — | — |
| S07 | RMT/SWP-shaped id or TF PmtInfId no transfer of ours holds (E∅) | **[critic F13, L12]** **booked** as our transfer by rule 3b (counterparty IBAN required) when exactly one matches; else as the client's or own unplanned when the counterparty IBAN is a client's payout IBAN or ours and nothing of ours matches; else **left** (bank) | as rule 3b, `unplanned_payout(client)` / `unplanned_sweep()` | 2b |
| S08 | a transfer debited with the bank's charge on its **own** line (class E: N + F) | **booked**. **[critic2] ML-10** When the statement gives the entry's charges (`Chrgs`, stored at import), the fee must equal them; when it gives none, a fee equal to the amount of a transfer of ours on the account is refused (`fee_unexplained`). **[critic2] ML-6, CSO2-1** The ISO shape — entry N + F, one detail of ours with its own amount N, F in `Chrgs` — is kept unsplit by the parser (class U): booked there as the same parts when F = the stored charges (§3.4.12) | `payout(t)` + `fee` (also beside `sweep`, `unplanned_payout(x)`, `unplanned_sweep(x)`) | 2a stores, 2b |
| S08b | payout debit for less than N, other account or currency | **left** (bank's detail) | — | — |
| S09 | batch line short of a member | **booked** when the members executed are the only subset of the PmtInf making the line; **[critic CSO-3]** a PmtInf of more than 500 items is refused `lot_too_large` (support) | `payout` × named | 2b |
| S10 | payout debit whose run is not in flight with that transfer | **left** → 6b-3 | — | — |
| S11 | several refunds in one PmtInf line, or legacy payouts+refunds (`batch_mixed`) | **left** (Q5, OQ-83) | — | — |
| S12 | **[critic F9, F12, L12]** a debit without our reference (N: CSV; O: the bank's own id; E∅) | **booked** by rule 3b when exactly one candidate matches. Candidates: in-flight payouts and sweeps (**[critic2] ML-4** re-issues included), in-flight refunds, and cancelled or returned payouts whose bytes the bank holds (**[critic2] ML-8** a returned x is not one while its return item is held by the in-flight run whose payout is a candidate at the same amount and IBAN). Several → `line_ambiguous` (exit: §4.2) | `payout(t)` / `sweep(t)` / `unplanned_payout(x)`; a refund candidate: its M2b link | 2b; guards 2c |
| S13 | debit to a client's registered payout IBAN matching nothing of ours | **booked**, P = 0 (Q8). **[critic2] ML-11** Its flagged return (no reference of ours, from that IBAN) is proposed as its unplanned return | `unplanned_payout(client)` | 2b; guards 2c |
| S14 | debit to our own IBAN without SWP id nor TF PmtInfId | **booked** | `sweep(t)` (rule 3b) or `unplanned_sweep()` | 2b; explanation refused 2c |
| S15 | SWP debit of a cancelled sweep, or a second debit of a booked sweep | **booked** | `unplanned_sweep(x)` | 2b |
| S16 | our payout/sweep returned, unflagged (own/client credit kinds carrying our id) | **booked** at the transfer's exact amount; **[critic L2]** a short one stays (no fee on an unflagged credit, Q10) | `payout_returned(t)` / `sweep_returned(t)` | 2b |
| S17 | returns the job refuses (more than N, second return, unknown id, other account) | **left** (bank) | — | — |
| S18 | `return_before_debit` | no part: booked by the job once ops book its debit. **[critic CSO-11]** The command queues the funds pass whenever it books a payout or sweep part | — | 2b |
| S19 | short return of a line of its own (booked in full + fee) | unchanged (OQ-84 (j), Q10) | — | — |
| S20 | credit naming a handed-out lot of ours | **booked** for payout/sweep lots: unique subset of the lot's returnable members. **[critic F1]** Those are the members booked there and not returned, plus the members with an open unplanned booking, which take the unplanned return. Refund lots **left** (Q5); the M2b pass's `changed` gets its own reason | `payout_returned` / `unplanned_payout_returned` × members | 2b (reason 2a) |
| S21 | unsplit credit entry holding ours | **[critic F8, F7, L11]** **booked only from the details of ours the statement itself gives** (ids, directions, amounts stored at import, 2a) when they make the entry exactly **and [critic2] ML-5 every detail of the entry is ours** (the entry's detail count, and its `NbOfTxs` when given, stored at import). Anything else inside the entry keeps it unbooked, even when it nets to zero: a debtor's money, a chargeback, a charge, a refund, a top-up. So do a detail without its amount and a line imported before 2a (§1.2) | the stored details' parts; no fee but S08's (§3.4.12) | 2a stores, 2b books |
| S22 | unsplit debit entry holding ours | as S21; alert added | as S21 | 2a, 2b |
| S23 | payments made of our transfers coming back (imported before rounds 4/8) | **left** to M2c-7 (Q13); **[critic L10]** P0 alert `own_transfer_payment`; texts no longer promise a screen | — | 2a |
| S24 | TOP/RMT/SWP id only in a CSV label outside `/REF` | **left** to M2c-7 (Q13; no alert possible: nothing on the line marks it) | — | 2a texts |
| S25 | our refund's RFD debit that cannot be linked (OQ-81 (b), Q2) | **left** → 6b-3 with Q2's entries chosen | — | — |
| S26 | `changed` / `posting_failed` on our lines | retried in strict mode by the command | the underlying shape's | 2b |
| S27 | return of an unplanned payout or sweep | **booked** (new kinds). **[critic L3]** It must be a credit carrying x's id, or a bank-flagged return from the IBAN the payout went to (**[critic2] ML-11** proposed on N/O/E∅ too). An unreferenced credit from the client waits (Q13) | `unplanned_payout_returned` / `unplanned_sweep_returned` (+ `fee` on a flagged return) | 2b |
| S28 | **[critic F1, L5]** a return of a transfer that has an open unplanned booking (S03 / S01 / S03r, then one copy back) | the job reviews it `unplanned_payout_return` (2a); ops book it as the unplanned booking's return (Q12). **[critic2] ML-3** So does a return of a transfer whose second (or late) debit is on a statement but not booked yet: reviewed `return_debit_pending`, refused `debit_pending` until that debit is booked | `unplanned_payout_returned` | 2a, 2b |

### 1.2 Left for later, and why
- **6b-3**:
  - S06 and S10 need the late-predecessor machinery: booking a transfer as its run's payout while superseding a file
    never downloaded, `FOR UPDATE` on that file (m2c-6b-plan §3.1);
  - S25 needs Q2's entries decided;
  - the switch itself, and real S01/S02 cases;
  - **[critic2] ML-4** the late debit of a payout cancelled after download whose run is still approved or sent (x
    cancelled alone on evidence, or re-issued as x'): that run can no longer be cancelled (`transfer_already_debited`),
    and the debit is its payout's, booked with S10's late-predecessor machinery. 6b-2 refuses it `run_still_live`;
  - **[critic2] CSO2-4** the download re-check of a generated file's sweep also applies generation's D4 rule
    (`private.debited_cancelled_sweeps`: a cancelled sweep debited all the same forces the sweep to 0). It matters only
    with the switch on;
  - rewording « Annulé avant la remise de son virement à la banque » for a cancellation after download.
- **M2c-7**:
  - recovery of the `double_payout` advances (claw-back, repayment request, `advance_open`, write-off);
  - a client's repayment credit (`client_payment`, Q13);
  - a line-split model for an unsplit entry holding anything not ours: the S21/S22 residue, S23, S24.
- **The bank / founder #15**: S08b, S11 and S17, and an unsplit entry whose details lack amounts, need the bank's
  per-transaction detail (OQ-83, OQ-84). So does a line imported before 6b-2a, whose details Collectoo did not keep.

### 1.3 Departures from `m2c-6b-plan.md`, with why
1. **The command does not go through `private.post_bank_bookings(org, true)`** (plan §2.6).
   - That re-check belongs to the job and was reviewed in eight rounds. Ops' rules are wider (mixed parts, subsets, a
     fee beside a payout, reference-less lines, returns on own/client credit kinds, lot credits, unsplit lines), and
     each would have to be carved out of it.
   - 6b-2b adds its own rule function (`private.transfer_line_check`) with the same lock order. It posts the unplanned
     kinds and the returns itself, and hands the planned kinds (`payout`, `sweep`, `fee`) to
     `private.bank_booking_post_rows`: settlements, cover, breach rows, run booked, completeness.
   - **[critic F1, CSO-1]** Two redefinitions are needed after all:
     - `post_bank_bookings` (6b-2a) for one job rule (§2.3). Its own-line hint moves into
       `private.own_transfer_line_hint()`, so 6b-2c rewords it without copying the function a second time.
     - `bank_booking_post_rows` (6b-2b) for one expression: an ops payout's `remittance` entry never takes the motif as
       its reason (§3.12).
2. **Ops never pick a batch line's members.**
   - The database proposes the only subset of the PmtInf's members (live, booked, returned or cancelled) whose amounts
     make the line. It refuses `batch_ambiguous` when there are several subsets or the bound is passed (§3.5).
   - Plan rule 3 compared only with « other subsets of open members »: a re-executed booked member of the same amount
     could then be booked as the missing live one (S05).
   - **[critic F8]** Ops never name an unsplit entry's parts either. The statement's own details name them (stored at
     import, §2.2).
3. **Unplanned-payout eligibility** (plan §2.6: x cancelled, booked or returned, by its own id or
   `transfer_late_lines`):
   - widened to a batch line naming x's PmtInf in its file (S04/S05: `transfer_late_lines` reads only superseded or
     rejected files, l.2575-2586);
   - **[critic F12]** widened to a line without our reference by rule 3b, when x (cancelled or returned) is the only
     candidate;
   - narrowed by leaving x `ordered`/`in_file` (S06, S10) to 6b-3. Plan §2.3 said « ops unplanned » for S06 and §2.6
     refused it; the right booking is the run's own payout (§10 Q9).
4. **c's draft is re-prepared, not « sent back »** (plan §2.3 [critic]).
   - `private.remittance_back_to_draft` acts only on a draft queued for approval (20261112090000 l.1605-1616), and an
     unreserved −A row does not change the approval's item count (l.1637-1639).
   - 6b-2b requeues c's draft for a prepare under a new token. **[critic CSO-7]** The command does not clear it
     (§3.6.5).
5. **Returns of unplanned payouts are new kinds** (`unplanned_payout_returned`, `unplanned_sweep_returned`), not
   `payout_returned`:
   - the guard requires reversing `x.entry_id` (l.1671-1674);
   - `bank_line_booking_return_uq` allows one return per transfer (l.224-225);
   - I20 flags a return on a transfer not booked (l.2868-2871).
6. **[critic F1, L5] A double execution followed by a return is the second payout's return.**
   - The draft let the job book it as the planned payout's return, which pays the client a second time and leaves the
     advance open with no recovery before M2c-7. That breaks OQ-81's « slower money, never double money ».
   - Now the job reviews a return of a transfer that has an open unplanned booking (`unplanned_payout_return`, §2.3).
     Ops book it as the unplanned booking's return (§3.4.13): nothing is paid again and the advance is closed.
   - **[critic2] ML-3** The same holds before the second debit is booked. A return of a transfer that has a debit line
     on a statement not booked beyond its booked debit (`private.transfer_late_lines`) is reviewed
     `return_debit_pending`, never booked: booked as the planned return, its re-owed item could be paid by a run
     handed out before ops book that debit, whose P would then be 0.
   - This redefines the job's re-check and its worker twin (6b-2a). Founder Q12.
7. **« Suivi » lists the events of the client's earlier runs posted in (previous approved run's K, this K]**, not a
   state diff against stored payloads (plan §2.7).
   - One pending run per client (`remittance_run_pending_uq`, 20261112090000 l.100) means every earlier run is booked
     or cancelled at K, so « still in flight » cannot occur.
   - The new payload key `previous_payouts` replaces M2c-5's `follow_up` (current state, not as of K, l.4262-4275).
   - **[critic L7, L17]** Only approved runs are listed, and the window is keyed on runs, not on statements drawn
     asynchronously.
8. **[critic] Four PRs** instead of two (§1.4).
9. **P is attributed per item.**
   - P for a client debit with no transfer is 0 (S13). Q4's default defines « paid » only through a cancelled run's
     items. Founder question Q8.
   - **[critic F2, F3, F4, F5, L1]** Otherwise P is attributed per item: the items x was meant to pay (a cancelled
     run's released items, or a returned x's return item), net of their reversals, minus what earlier unplanned
     bookings already counted, capped by what the pending queue can net (§3.6.1).
   - **[critic2] ML-1** The items' cap is their **signed** net, summed before it is floored at 0: a cancelled run's
     released lines include negative items (a reversal, an earlier advance's pair), and a per-item floor let P net part
     of a double payout against unrelated collections.
   - Every excess is the servicer's advance. Q4 allows no hold-back without a clause.
10. **New mis-booking guards** the plan did not foresee (6b-2c, with the screen that replaces them).
    - « Frais bancaires » and « Classer sans comptabiliser » are refused on a debit without our reference that an
      in-flight transfer may be, and on a debit to a client's payout IBAN.
    - The explanation is refused on a debit to our own IBAN.
    - **[critic L8]** Each of these refusals, and each line no rule can attribute, would otherwise suppress an in-flight
      breach row for good. A bounded wait ends that suppression (§4.2, Q14).
    - **[critic2] ML-7** The bound applies only to a line that offers no booking containing that transfer. A line ops
      can book as that payout's debit keeps suppressing and raises `bank_line_unbooked`; its booking writes the true
      row at its own date. Otherwise every on-time debit of a reference-less feed would get a false breach row.
11. **`transfer_unknown` is P0 everywhere.** ADR-0014 « M2c-6b-1 » calls it P0 and the web ranks it so; the worker's
    `P0_REVIEWS` and the alerts did not (payments/debits.py l.325-327; l.3341-3350). **[critic L14]** This holds for
    both directions.
12. **A lot credit returning several members** uses one reversal key per transfer, `return:<line>:<transfer>`. The
    job's `return:<line>` allows one return per line.
13. **Texts.**
    - The « écran à venir » promises are kept where 6b-2 keeps them, and reworded in 6b-2c when the screen ships.
    - They are withdrawn now where 6b-2 does not book the shape: S23, and held duplicates read before round 4 (6b-2a).
    - **[critic L10]** COMPLIANCE OQ-84 (e), (h), round 8 T1, R3 and ADR-0014 l.1183 and l.1271 promised S23/S24 to
      6b-2. They are reworded to M2c-7 in 6b-2a.
14. **[critic CSO-2, F10, CSO-10] A generated file's sweep is re-checked at its first download** (§2.4).
    - The draft refused only an unplanned sweep while a file was `generated` (`sweep_file_pending`). Every part that
      debits 4679 lowers the servicer's share under a sweep already computed: an unplanned payout's advance, a fee, a
      planned payout's cover. So do the job's own covers and fees, which 6b-1 already posts.
    - `transfer_file_download` does not re-check the sweep (20261115090000 l.2088-2116), so the fix belongs there and
      the refusal is dropped.
15. **[critic CSO-3] The command's budget is the API's**: ≤ 4 s under the API's 8 s statement timeout
    (docs/benchmarks/remittances.md l.126). The job books a 5,000-member batch line in 31.3 s (l.444). Lots of more than
    500 items are refused `lot_too_large` and go to support. The 6b plan's « 5,000 members, command < 60 s » target is
    withdrawn.
    - **[critic2] CSO2-2** 500 is the starting value of one constant, `private.transfer_line_lot_cap()`, read by the
      parse, the options, the preview, the command and the label's test. The scale run sets it with 2× headroom under
      8 s; if the run misses, the cap is lowered, never the budget raised. `unique_subset` also gets a deterministic
      work bound (§2.5), since its partial-sum bound alone does not bound its run time.
16. **[critic L2, F7] A fee part only on our transfer's own line** (§3.4.10). The draft allowed it on unsplit,
    client-IBAN and own-IBAN lines, where any shortfall could be booked as the firm's bank charge (6270).
17. **[critic F11, L4] A reversed unplanned remittance's item is not monitored for R124-6 while the items its P paid
    are still waiting** (§3.12): they keep their own clocks (Q15), and its A − P is netted by the advance's reversal.
    **[critic2] ML-2** Once a run has frozen those items (netted by the −A row) their clocks ended at that run; the
    re-owed item is then held, like a planned return, to the earliest latest execution date of those items' lines,
    `blocked_reason` `payout_returned`.

### 1.4 Size estimate and split decision
Lines of non-test code, counted from the functions they copy (redefinitions are copied whole by house rule; their diff
against the source is small and reviewed as a diff):

| | **6b-2a** foundations | **6b-2b** ops command | **6b-2c** pages | **6b-2d** « Suivi » |
|---|---|---|---|---|
| SQL, new | ≈ 300 (schema 90, `unique_subset` 120, hint helper 20, download re-check 25, alerts 45) | ≈ 2,000 (rules 750, P and attribution 150, posting 320, command 150, locks 120, reads 350, helpers 160) | ≈ 260 (reads 150, guards 80, bounded wait 30) | ≈ 220 (events, natures, window) |
| SQL, redefinitions copied | ≈ 1,660 (`ingest_statement` 400, `post_bank_bookings` 432, `bank_booking_candidates` 172, `apply_bank_bookings` 40, `transfer_file_download` 115, `run_transfer_checks` 275, `apply_debit_decisions` 35, `assign_payment` 108, `resolve_duplicate` 78) | ≈ 420 (`bank_line_booking_guard` 106, `pending_item_deadlines` 95, `bank_booking_post_rows` 215) | ≈ 1,220 (`link_debit` 116, `debit_queue` 169, `post_debit_links` 343 and `release_own_credit` 100 hint only, `transfer_debit_may_be_seen` 38, `run_remittance_runs_checks` 370, `client_remittance_summary` 78) | ≈ 430 (`remittance_statement_build`) |
| Worker | ≈ 130 (parser details, staging, twin rule, `unique_subset`, P0 set) | ≈ 30 (`_held_to` parity) | — | ≈ 220 (renderer fr-3) |
| Web | ≈ 90 (review reason, download refusal, checks labels, S23 texts) | ≈ 150 (refusal and decision labels) | ≈ 1,100 (sheets, actions, `lib/payments/transfer-lines.ts`, run page, Virements, client space, rewording) | ≈ 20 |
| **Total** | **≈ 2,180** (≈ 520 new or changed) | **≈ 2,600** (≈ 2,180 new or changed) | **≈ 2,580** (≈ 1,360 new or changed) | **≈ 890** (≈ 460 new or changed) |

**[critic2]** The second critique adds about 90 lines to 6b-2a (detail count, charges, the pending-debit fact, the CI
order check), 200 to 6b-2b (signed cap, `run_still_live`, the S08-on-U rule, the fee check, held-to for the re-owed
item, the cap constant and work bound), 120 to 6b-2c (`private.transfer_line_offers`, the new proposal, texts) and 20 to
6b-2d. The split stands; 6b-2b is now ≈ 2,380 new or changed lines, still one cohesive review.

**Decision: split in four.** The whole is ≈ 8,250 lines (≈ 8,680 with [critic2]); each slice is shippable alone.
- **6b-2a** — foundations, job side:
  - the statement's own detail of an unsplit entry, stored at import;
  - the job reviews a return of a transfer that has an open unplanned booking;
  - a generated file's sweep is re-checked at its first download (fixing a 6b-1 gap);
  - `unique_subset`, the alerts, and the S23 texts.

  Nothing a user sees changes except labels, a download refusal and the S23 texts. The new rules are inert until 6b-2b
  creates unplanned bookings: pgTAP 036 seeds them.
- **6b-2b** — the ops command and its reads, pgTAP 037, worker parity, labels. Every « écran à venir » stays true
  because no screen ships.
- **6b-2c** — the pages, the mis-booking guards and their bounded wait, the hints reworded, the client space, E2E and
  screenshots.
- **6b-2d** — « Suivi » (fr-3) and pgTAP 038, on top of 6b-2b.

6b-2b is the one slice near 2,200 new lines. It is cohesive: the rules, P and the posting must be reviewed together.

pgTAP numbering: `036_transfer_line_foundations` (2a), `037_transfer_line_ops` (2b; 2c appends group P),
`038_statement_suivi` (2d). **6b-3's switch-on follow-ups become `039`** (m2c-6b-plan §3.2 says 038; updated with
6b-2a's docs). Migrations, in the pinned order (**[critic2] CSO2-5**): `20261117090000` (2a), `20261117100000` (2b),
`20261117110000` (2c), `20261117120000` (2d), as placeholders; each is renamed when its PR opens if `main` has a later
one by then. 6b-3's comes after 2d's.

---

## 2. 6b-2a — foundations: migration `20261117090000_transfer_line_foundations.sql`

Header (house rule): what is new, what is redefined and from which file, with settings and grants restated. The
switch stays off; 033/034 unchanged.

### 2.1 Schema
- `public.bank_line_booking`: kind check += `unplanned_payout_returned`, `unplanned_sweep_returned`. No row exists
  before 6b-2b; the job and the alerts read them by name.
- **[critic F14]** No new index. `bank_line_booking_transfer_idx (transfer_id) where transfer_id is not null` exists
  for every kind (20261111090000 l.2338). Creating it again would stop `supabase db reset`.
- `public.bank_debit_review.reason` check += three reasons:
  - `own_transfer_line` (the M2b pass's own reason, S20 / OQ-84 (i));
  - **[critic F1]** `unplanned_payout_return` (the job, §2.3);
  - **[critic2] ML-3** `return_debit_pending` (the job, §2.3).
- **[critic F8, L11]** `public.bank_transaction.unsplit_details jsonb` and `private.bank_import_stage.unsplit_details`.
  - The value is null, or an array of exactly `unsplit_ours` objects `{id, direction, amount_minor}`, in the file's
    order.
  - `id` is an id we issue (`^(RMT|SWP|RFD|TOP)[0-9A-F]{12}$`), `direction` is `debit` or `credit`, and `amount_minor`
    is digits as text, or null when the detail gives no amount (or gives it in another currency, CSO2-9).
  - Check: `unsplit_details is null or (unsplit_ours is not null and jsonb_array_length(unsplit_details) =
    unsplit_ours)`; the element shape is checked at import (§2.2).
  - Comment: the details of ours that the statement itself gives for an entry it kept unsplit.
- **[critic2] ML-5** `unsplit_detail_count smallint` and `unsplit_batch_count integer` on both tables: for an entry kept
  unsplit, how many `TxDtls` it has in all (ours or not) and its `Btch/NbOfTxs` (null when absent). Check:
  `unsplit_detail_count is null or (unsplit_ours is not null and unsplit_detail_count >= unsplit_ours)`; both null
  unless `unsplit_details` is set. Comment: what lets a booking tell an entry made only of our details from one that
  also holds others, even netting to zero.
- **[critic2] ML-6, ML-10, CSO2-1** `charges_minor bigint check (charges_minor > 0)` on both tables: the charges the
  statement itself records for the entry, for a line that is its entry's only line (unsplit, or of one detail). Read
  from `Ntry/Chrgs` and that one `TxDtls/Chrgs` (`Rcrd/Amt` from v04, `Amt` in v02), debit records in the account's
  currency included in the entry amount (`ChrgInclInd` absent or true); null when there are none, or when one record
  cannot be read that way. The ISO 20022 camt.053 message definition (`docs/reference/`) is checked at build for these
  paths; nothing is inferred beyond what it defines. CSV lines: null. Comment: the bank's own record of its charge,
  the only fee a booking takes without a third party's doubt.

### 2.2 The statement's own detail of an unsplit entry (S21/S22; [critic F8, L11])
- **Parser** (`payments/camt053.py`, the unsplit branch l.470-494). It already lists our details (`mine =
  _our_ids(details)`) and stores only their count. It now also records each one:
  - its id (own or original, as `_our_ids` reads it);
  - its direction (`_direction(d, entry.direction)`);
  - its own amount, **[critic2] CSO2-9, ML-6** read by the rule `split()` and `whole()` already use: the path is
    `Amt` when present, else `AmtDtls/TxAmt/Amt`; its `@Ccy` must be the statement's currency; otherwise null. (The
    draft's « `AmtDtls/TxAmt/Amt`, else `Amt` » was the reverse, without the currency check, so the stored detail
    could differ from what decided the entry was unsplit.)

  **[critic2] ML-5** It also records, for the same entry, `len(txs)` as `unsplit_detail_count` and the parsed
  `NbOfTxs` (the `batch` it already reads) as `unsplit_batch_count`. **[critic2] ML-6, ML-10** For a line that is its
  entry's only line it records `charges_minor` (§2.1).

  The `StatementLine` fields are `unsplit_details`, `unsplit_detail_count`, `unsplit_batch_count` and
  `charges_minor`. **[critic2] CSO2-9** `unsplit_details` is a `tuple[UnsplitDetail, ...] | None` of a frozen, slotted
  `UnsplitDetail(id, direction, amount_minor)`, so `StatementLine` (frozen, slotted) stays hashable. Nothing else
  changes: the count, the kinds, the original id.
- **Import.**
  - **[critic2] CSO2-9** The worker stages the columns with the line: `payments/statement.STAGE_COLUMNS` gains them,
    and `jobs/payments.stage()` writes `Jsonb([...])` (psycopg's `psycopg.types.json.Jsonb`, as `jobs/debits.py` does
    for the candidates) or null for `unsplit_details`. A bare tuple would be dumped as an array and the COPY into
    `jsonb` would fail every camt import holding such an entry.
  - `private.ingest_statement` (redefined from 20261116090000 l.5955) copies them and refuses a malformed one,
    `line_invalid`: a count mismatch, an id not ours, a bad direction or amount, details without `unsplit_ours`, a
    detail count below `unsplit_ours`, or a non-positive charge.
  - **[critic2] CSO2-8** On a re-import, a known line (same account and `dedup_key`) is still skipped. When both the
    stored and the staged `unsplit_details` are non-null and differ (ids, directions, amounts, in order), or the
    stored and staged detail counts or charges differ, the file is refused `entry_detail_differs`, as for an entry
    that comes back split another way (`bank_import_entry_known`, l.6135-6139): the bank's corrected statement is
    never silently ignored. A stored null (a line imported before 6b-2a) is neither compared nor filled, so
    re-importing an older file neither fails nor completes it.
- **Residual** (OQ-84 (f)): a line imported before 6b-2a has `unsplit_ours > 0` and no details. It cannot be booked
  here (§3.4.12).
- **Why.** An unsplit booking then rests on the bank's own file, kept on the line, not on one person's transcription
  (L11). Ops confirm; they never compose (F8).

### 2.3 The job: a return of a transfer that has an open unplanned booking ([critic F1, L5])
- **`private.post_bank_bookings`** (redefined from 20261116090000 l.1119):
  - `_bb` gains `tr_unplanned_open`: an `unplanned_payout` / `unplanned_sweep` booking of the transfer whose entry is
    not reversed (`bank_line_booking_transfer_idx`, then `ledger_entry_reversed_once_uq` on its entry, by key).
  - The return branch (l.1348-1370) gets one rule, right after `return_before_debit` (transfer still
    `ordered`/`in_file`) and before `already_returned`: `tr_unplanned_open` → `unplanned_payout_return`. This covers
    a booked or returned x re-executed (S03, S03r) and a cancelled x executed late (S01: until now `return_differs`).
  - **[critic2] ML-3** `_bb` also gains `tr_debit_pending`: the transfer has a debit line not booked beyond its booked
    debit (`exists (select 1 from private.transfer_late_lines(x))`: an unbooked, unlinked, non-payment debit carrying
    its id or naming its PmtInf in a superseded, rejected or — for a cancelled x — downloaded file, l.2546-2590, by key).
    Right after the `tr_unplanned_open` rule: `tr_debit_pending` → `return_debit_pending`. The job never books such a
    return: once D2 is booked it becomes the unplanned booking's return (§3.4.13), and the job's next pass reviews it
    `unplanned_payout_return`. Without this fact, a return arriving between D2's import and its booking was booked as
    the planned payout's return; its re-owed item could then be paid by a run handed out before ops book D2, whose P
    would be 0 (the item frozen, and §3.4.6 rule 7 silent once downloaded): the client paid twice.
  - The strict hint text comes from `private.own_transfer_line_hint('bank_booking')` (unchanged wording in 6b-2a).
- **`private.bank_booking_candidates`** (dropped and created from 20261116090000 l.595: two new columns): the return
  facts `unplanned_open` and **[critic2] ML-3** `debit_pending`, keyed the same way.
- **`private.apply_bank_bookings`** (from l.1551): a skipped row whose `why` is `unplanned_payout_return` or
  `return_debit_pending` is reviewed under that reason, not `changed`.
- **Worker twin** (`payments/debits.py`):
  - `TransferFact.unplanned_open` and **[critic2] ML-3** `TransferFact.debit_pending`, loaded by `jobs/debits.py`;
  - `_transfer_return` (l.545-585) has the same two rules at the same place.
- Why: a copy that comes back closes the second payout's advance first. Booked as the planned payout's return, it would
  pay the client again (§1.3 item 6). The first return after the unplanned booking is reversed is the planned payout's
  return, as today.

### 2.4 A generated file's sweep re-checked at its first download ([critic CSO-2, F10, CSO-10])
- **`public.transfer_file_download`** (redefined from 20261115090000 l.2054), generated branch (l.2088-2116). Beside the
  holds and the cash check, the file's `in_file` sweep S is compared with the servicer's share now. That share is read
  under the remit lock the function already holds, since every writer of 4679 holds it.
  - **Share**: −Σ `due_to_servicer` (4679) of the servicer and currency, minus Σ the other sweeps `ordered` or `in_file`
    (not this file's). This is `generate_transfer_file`'s own formula (20261116090000 l.355-367).
  - **S > share**: `v_blocked` gets `{transfer_id: S, kind: 'sweep', reason: 'sweep_exceeds_share', sweep_minor,
    share_minor}`. The file is refused `file_blocked` and superseded: the sweep is cancelled (sweeps are never
    re-queued), the payouts are ordered again, and the next file recomputes the sweep.
- **Coverage.** This covers every movement between generation and download:
  - the job's `payout_overrun` covers and bank fees (6b-1);
  - 6b-2b's advances and fees.

  A file in status `pending` is never served (`not_ready`); it is re-checked when it is downloaded as `generated`
  (CSO-10). A sweep already handed out may still over-sweep: 4679 then goes into debit and `servicer_shortfall` (P0,
  exists) asks for a top-up.
- **Web**: `lib/remittance/transfers.ts` blocked reasons += `sweep_exceeds_share`: « La quote-part du cabinet de ce
  fichier dépasse ce qui lui revient maintenant (une avance, des frais ou une couverture ont été comptabilisés depuis sa
  génération) : le fichier est remplacé, la quote-part sera recalculée. »
- **[critic2] CSO2-4** `refusalText('file_blocked')` (`lib/remittance/transfers.ts` l.1025-1026) says « ces virements
  restent hors du fichier tant que leur motif demeure ». That is false when the only blocked entry is the sweep: the
  sweep is cancelled and recomputed, and the payouts go back in. `downloadOutcome` already returns `blocked`, so the
  text is chosen from it: when every blocked entry is `sweep_exceeds_share`, « Le fichier n'a pas été servi et il est
  remplacé : seule la quote-part du cabinet a changé depuis sa génération. Régénérez-le maintenant : les reversements
  qu'il contenait y reviennent (leur date limite court toujours). »; otherwise today's text.

### 2.5 `private.unique_subset` (used by 6b-2b's lots)
`private.unique_subset(p_amounts bigint[], p_target bigint) returns integer[]` (immutable, parallel safe):
- Returns the 1-based indexes of the only subset summing to `p_target`, or null: none, several, or past the bounds.
- Method: a dynamic programme over partial sums, with a count capped at 2 and, for count 1, the path.
- It works on the smaller side, `t' = least(p_target, Σ − p_target)`. A subset makes t iff its complement makes Σ − t,
  so the counts are equal. It returns the complement when t' ≠ p_target. Amounts > t' are skipped.
- Bounds: past **10,000 partial sums** (as `private.amounts_make_up`, 20261115090000 l.1145) or 200,000 stored path
  entries → null.
- **[critic2] CSO2-2** Those two bounds do not bound the run time: when t' is below 10,000 minor units the set of sums
  saturates at t' + 1 and never trips them, and each of up to 500 items rebuilds and de-duplicates it (seconds in
  plpgsql, run by the options, the preview and the command). So:
  - a **work bound**: Σ over the items visited of the size of the set of sums ≤ **1,000,000**, else null;
  - more than `private.transfer_line_lot_cap()` amounts → null at once (the caller has already refused
    `lot_too_large`);
  - the items are visited in a **pinned order**, the order of the array given (the callers pass the PmtInf's items by
    `transfer_file_item.seq`, members by their seq), and the Python twin visits them in the same order, so both
    trip a bound at the same item.
- `private.transfer_line_lot_cap() returns integer` (immutable): 500, the one constant of §1.3 item 15.
- Grants (**[critic2] CSO2-11**): `revoke execute on function private.unique_subset(bigint[], bigint),
  private.transfer_line_lot_cap() from public, anon, authenticated` (PostgreSQL grants EXECUTE to PUBLIC by default);
  only the `SECURITY DEFINER` callers use them.

A Python twin `payments.debits.unique_subset`, with the same bounds, is the subject of the Hypothesis oracle (§8.2).

### 2.6 Alerts, reviews and texts
- **`private.apply_debit_decisions`** (20261111090000 l.3726): a skipped row whose `why` is `own_transfer_line` is
  reviewed `own_transfer_line`, not `changed` (S20's a04/a05, OQ-84 (i)).
- **`private.run_transfer_checks`** (20261116090000 l.3165). New alerts:
  - `transfer_unknown` (P0): the lines the job reviewed so, not booked nor linked. **[critic L14]** These are debits
    and credits;
  - `double_payout_open`: an advance of cause `double_payout`, open = amount − settlements, 0 once its entry is
    reversed;
  - **[critic L10]** `own_transfer_payment` (P0): a payment made of a line carrying our RMT/SWP id (own or original)
    or naming one of our lots — the flag `payment_queue` shows — that is not assigned and is older than one business
    day. Keyed as that flag is read. These are a client's returned payout sitting on 4710 with no R124-6 clock.

  Extended alerts:
  - `payout_returned` also fires for an `unplanned_payout_returned` booking, `sweep_returned` for an
    `unplanned_sweep_returned`;
  - `bank_line_unbooked` also counts, after one business day, each line not booked nor linked of these kinds: an
    unsplit debit holding ours (`batch_unsplit`, `unsplit_ours > 0`), a credit naming our lot, an own or client
    credit carrying our RMT/SWP id (S16), and a line reviewed `unplanned_payout_return` or **[critic2] ML-3**
    `return_debit_pending`. The inventory found that l.3393-3407 missed them.
- **[critic2] CSO2-14, ML-3** Review labels in 6b-2a and 6b-2b, while no screen books these lines (the command is
  callable through the API by an aal2 admin, which support may use, so the reviews can exist before 6b-2c):
  - `unplanned_payout_return`: « Retour d'un virement du cabinet (reversement ou quote-part) qui a aussi été exécuté
    hors de son ordre (virement annulé exécuté quand même, ou exécuté deux fois) : rien n'est comptabilisé
    automatiquement. Ce retour est celui du virement exécuté hors ordre, pas du reversement ni de la quote-part :
    prévenez le support. » One reason covers the payout and the sweep; the wording names both;
  - `return_debit_pending`: « Retour d'un virement du cabinet dont un autre débit (second débit, ou débit après
    annulation) figure sur un relevé sans être encore comptabilisé : rien n'est comptabilisé automatiquement. Ce débit
    se comptabilise d'abord ; prévenez le support. »

  6b-2c rewords both with the screen (§4.3).
- **Worker**: `P0_REVIEWS` += `TRANSFER_UNKNOWN`.
- **S23 texts** (Q13's default). `public.assign_payment` and `public.resolve_duplicate` (20261116090000 l.5564,
  l.5486) change their hint only:
  - « Ce paiement vient d'une ligne qui porte la référence de l'un de nos propres virements (reversement, quote-part
    du cabinet, lot de notre fichier) : c'est ce virement qui revient, pas le paiement d'un débiteur. Il ne s'affecte à
    aucun dossier, et Collectoo ne peut pas encore le comptabiliser comme le retour de ce virement (un paiement
    enregistré ne se défait pas ; prévu avec M2c-7) : prévenez le support. »
  - For the duplicate: « … Lue ainsi avant la correction de l'import, elle ne peut être ni libérée comme un paiement ni
    encore comptabilisée comme ce retour : elle reste dans « Doublons possibles ». Prévenez le support. »
  - Build check: whether « Libérer » can release such a held line as a `return`. If it can, the text says so instead.

  Their page twins change with them (6b-2a, vitest): `payment_own_transfer_line` and `duplicate_own_transfer_line`
  (`lib/boarding/forms.ts` l.621-626), and `OUR_TRANSFER_PAYMENT_NOTE` (`lib/payments/matching.ts` l.286-287).
  - « par l'équipe (écran à venir) » becomes « Collectoo ne peut pas encore le comptabiliser comme le retour de ce
    virement … prévenez le support ».
- **`private.own_transfer_line_hint(p_where text) returns text`**: the own-line hint text, one place per caller
  (`bank_booking`, and in 6b-2c `debit_link`, `own_credit`). 6b-2a returns today's wording. **[critic2] CSO2-11**
  Execute revoked from `public, anon, authenticated`.
- **[critic2] CSO2-5** CI (`.github/workflows/ci.yml`, job `db`): a step that fails when a migration file the branch
  adds sorts before the latest migration file on `origin/main` (`git diff --name-only --diff-filter=A origin/main...`
  on `supabase/migrations/`, compared by name).

---

## 3. 6b-2b — the ops command: migration `20261117100000_transfer_line_ops.sql`

### 3.1 Schema
- **[critic F4, F2, L1] `private.unplanned_paid_item`** records what each unplanned booking's P counted, item by item.
  - Columns: `booking_entry_id uuid not null` (the unplanned `remittance` entry), `ledger_entry_id uuid not null` (the
    item it counted), `organization_id`, `client_organization_id`, `currency`, `amount_minor bigint not null check
    (amount_minor > 0)`, `created_at`.
  - Keys: primary key `(booking_entry_id, ledger_entry_id)`; index `(ledger_entry_id)`.
  - Append-only (`refuse_change`, enabled always). It is written only by `private.transfer_line_post` (`SECURITY
    DEFINER`); private schema, never exposed.
  - **[critic2] CSO2-11** As house practice for private tables (`private.remittance_pending`, 20261111090000
    l.4166-4169): `alter table … enable row level security` with no policy, and `revoke all … from public, anon,
    authenticated, service_role`. Only the definer functions read or write it. No change-log trigger: like every
    private table it has none (only public core tables do), and being append-only each row is its own history.
  - An attribution counts while its booking entry is not reversed.
- `client_advance_cause_idx on public.client_advance (cause_entry_id)`: the advance of an unplanned booking, by key. The
  rules and the reads need it; no index exists (20261116090000 l.154-156).
- **[critic2] CSO2-13, ML-10** `bank_transfer_filed_amount_idx on public.bank_transfer (debtor_bank_account_id,
  amount_minor) where transfer_file_id is not null`: every transfer ever put in a file, by account and amount. Rule 3b
  probes it per line (§3.4.4), and so does the fee check (§3.4.10). The existing indexes do not serve it:
  `bank_transfer_debtor_idx` holds only `ordered`/`in_file`, `bank_transfer_cancelled_filed_idx` is led by the servicer
  and holds no amount.
- Nothing else is new:
  - `client_advance` already allows cause `double_payout`;
  - `private.remittance_pending` already allows kind `unplanned_payout` (20261111090000 l.1238);
  - `remittance_line.kind` already allows `unplanned_payout` (20261112090000 l.246);
  - the commission engine never commissions `LineKind.UNPLANNED_PAYOUT` (`remittance/commission.py` l.154-165).

### 3.2 The command
```
public.book_transfer_line(p_idempotency_key text, p_bank_transaction_id uuid, p_parts jsonb,
                          p_expected_text text, p_reason text) returns jsonb
  security definer, set search_path = '', set lock_timeout = '2s'
```
Plan §2.6 [critic]'s signature, unchanged. Steps:
1. **Role.** Read the line by key. `private.has_role(line.organization_id, array['admin','ops_manager'])` (aal2 for
   servicer staff), else `insufficient_privilege` « not allowed ». The same answer is given for a line that does not
   exist.
2. **Replay.**
   - **[critic CSO-12]** Take `pg_advisory_xact_lock(hashtext('cmd:book_transfer_line:' || key))` first, so a double
     tap waits for the first call and gets its stored result, never `already_booked`.
   - **[critic2] CSO2-6** A call may take up to 4 s, longer than the function's `lock_timeout` of 2 s. So the key lock
     is taken under `perform set_config('lock_timeout', '7s', true)`, then `set_config('lock_timeout', '2s', true)`
     restores the function's value for every later lock (the function's `SET` clause restores the caller's on exit).
     A second tap then waits for the first call (≤ 4 s) and returns its stored result.
   - Then normalise the request `{bank_transaction_id, parts (as given, amounts as text), expected_text, reason
     (trimmed)}` and call `private.command_replay('book_transfer_line', key, request)`.
   - A stored result is returned as is. The same key with another request gets command_replay's own refusal.
3. **Reason**: 1–2,000 characters, else `a reason is required` (check_violation, as every command).
4. **Parse** `p_parts` (§3.4.0), else `bad_request`; `p_expected_text` non-empty and ≤ 100,000 characters, else
   `bad_request`.
5. **[critic CSO-5] Tenant filter** (§3.4.1): every named id is checked against the line's servicer before any rule and
   before any lock.
6. **[critic CSO-3] Before the locks.**
   - Class B: the PmtInf's items (immutable) are counted (`lot_too_large` above `private.transfer_line_lot_cap()`,
     **[critic2] CSO2-3** by a keyed count before any other read of them) and `private.unique_subset` runs on their
     amounts in `seq` order (§3.5).
   - **[critic2] CSO2-3** Class U and lot credits: the stored details / the returnable members are counted the same
     way first; above the cap → `lot_too_large` (not `bad_request`).
   - Class N/O/E∅: the rule-3b candidates' keys are read (§3.4.4).
   - No search runs under the allocation lock.
7. **Locks**: `private.transfer_line_locks(line, parts)` (§3.8).
8. **Check**: `private.transfer_line_check(line, parts, strict => true)` under the locks.
   - It raises the first refusal (`transfer line booking refused: <code>`, check_violation).
   - It re-reads every status the subset or the candidates depended on: a change raises `split_changed`.
   - It fills `pg_temp._tl`: one row per part with its facts and its effects (P, its items, the advance, the client,
     the run).
9. **Compare and set**: `private.transfer_line_text()` (§3.9) ≠ `p_expected_text` → `split_changed`.
10. **Post**: `private.transfer_line_post(org)` (§3.6, §3.7). LG*, 22* and 23* raised inside become `posting_failed
    (<state>: <message>)`, as `post_bank_bookings` strict does (l.1484-1493).
11. **Drafts and the funds pass.**
    - Requeue the drafts locked in step 7.1 (§3.6.5).
    - **[critic CSO-11]** Whenever the call booked a `payout` or `sweep` part (planned or unplanned), queue the funds
      pass: `pgmq.send('payments', {"type": "process_debits", "organization_id": org, "funds_after": null})`, as
      `resolve_duplicate` queues it (l.5548). It is idempotent and cheap on a quiet account. It is S18's exit even when
      a concurrent pass reviewed the return `return_before_debit` after this call's check.
    - **[critic2] CSO2-7** Also whenever it booked `unplanned_payout_returned` or `unplanned_sweep_returned`. Reversing
      an unplanned booking changes what the job's rule (§2.3) decides for x's other return lines: one already reviewed
      `unplanned_payout_return` in the same pass is now the planned payout's return, which the job books. The funds
      pass re-reads reviewed lines (`bank_booking_candidates` excludes only booked, linked and released lines,
      l.616-640), so the queued pass books it at once instead of at the next import.
    - **[critic2] ML-3** Booking the pending debit D2 (an unplanned part, so already covered by the first rule) queues
      the pass that re-reviews x's return lines from `return_debit_pending` to `unplanned_payout_return`.
12. **Record**: `command_record`. Return `{bank_transaction_id, bookings: [{seq, kind, transfer_id, client_id,
    amount_minor, entry_id, paid_minor, advance_minor}], drafts_requeued: [run ids], funds_pass_queued,
    expected_text}`, amounts as text.

One person (founder Q6's default): no second approval. Grants: execute to `authenticated`; revoked from `public, anon`.

**[critic CSO-3] Budget.** The command takes ≤ 4 s at the largest size it accepts (500 items), under the API's
`statement_timeout = 8s`, as an aal2 API session. Above that it refuses `lot_too_large` (support). SQLSTATE 57014 gets
the label `timeout` (§3.10). The scale test records how long the allocation lock is held (§8.2).

### 3.3 Line classes (read under the lock; the first that applies)
- **U** — `unsplit_ours > 0`: an entry the bank kept unsplit holding a detail of ours (l.123).
- **E** — our id:
  - a debit whose `end_to_end_id` names a transfer of ours on the line's account;
  - a credit whose own or original id does.
- **B** — our lot: `end_to_end_id is null` and `payment_info_id` names a file of the line's account through
  `transfer_file_item.pmt_inf_id`.
  - Debit: our batch line, as the job reads it.
  - Credit: `private.names_our_lot`, a file downloaded or sent.
- **E∅** — an RMT/SWP-shaped id, or a TF PmtInfId, naming nothing of ours (S07).
- **N** — neither an end-to-end id nor a PmtInfId (a CSV feed without the reference column).
- **O** — anything else: a foreign end-to-end id or PmtInfId.

### 3.4 Part kinds — acceptance rules (evaluated in this order; the first failure is the refusal)

**3.4.0 Parse** (`bad_request`):
- `p_parts` is an array of **1 to `private.transfer_line_lot_cap()`** objects `{kind, transfer_id?, client_id?,
  returns_line_id?, amount}` (**[critic CSO-3]** the lot bound; **[critic2] CSO2-2** one constant, 500 to start);
- `amount ~ '^[0-9]{1,16}$'` and > 0;
- `kind` is one of the nine kinds;
- `transfer_id` is required for `payout`, `sweep`, `payout_returned` and `sweep_returned`;
- exactly one of `transfer_id` / `client_id` for `unplanned_payout` and `unplanned_payout_returned`;
- `unplanned_sweep` and `unplanned_sweep_returned` take a transfer or nothing;
- `returns_line_id` is required for the two unplanned return kinds and allowed nowhere else;
- no two parts share the same (kind, transfer_id, client_id, returns_line_id);
- at most one `fee`, and at most one part without a transfer. **[critic F15]** The fee now sits only beside a transfer
  part on its own line (§3.4.10), so the two rules never meet.

Part `n` is its 1-based position; it keys the entries.

**3.4.1 Tenant filter** ([critic CSO-5, F16]; before any lock or status rule, in the command and the preview alike):
- every `transfer_id` must be a `bank_transfer` of the line's servicer, and every `returns_line_id` a
  `bank_transaction` of the line's servicer, else `transfer_unknown`;
- every `client_id` must be a client of the servicer, else `client_unknown`.

The same code and the same `why` are given for an absent id and another servicer's. The key collection of §3.8 reads
only ids that passed, so no row of another servicer is ever locked. A transfer or line of the same servicer on another
bank account or currency is `transfer_differs` (each kind's rule below). The options, candidates and members never list
another servicer's rows.

**3.4.2 Line state** (any part):
- held duplicate → `held_duplicate`;
- a booking or an own-credit release on the line → `already_booked`;
- an M2b link → `already_linked`;
- a payment of the line → `line_is_payment`.
- **[critic F16]** debit parts (`payout`, `sweep`, `unplanned_payout`, `unplanned_sweep`) only on a debit of kind
  `transfer_out`, `other_debit` or `batch_unsplit`, as the job (l.1328-1329), else `not_a_transfer_line`. That
  excludes an RFD `refund_out` line, a direct debit and a payment's return.
- return parts only on a credit of kind `return`, `own_transfer_in` or `client_transfer_in`, else `not_a_return`;
  class U: per stored detail (§3.4.12).
- the signed Σ of the parts (debit parts −, return parts +, a fee −) ≠ the signed line (− for a debit, + for a credit)
  → `parts_do_not_add_up`.
- Shapes left are refused here by their class: a line holding a refund member (B with a refund in the PmtInf) →
  `batch_mixed`.

**3.4.3 `payout(t)`** — a planned payout's debit (S08, S09, S12, S26; the planned half of S02 and S05):
1. t of kind payout → `transfer_unknown`.
2. The line is a debit (U: per stored detail) → `wrong_direction`.
3. Identity → `not_its_line`:
   - E: `line.end_to_end_id = t.end_to_end_id`;
   - B: t is a member of the named PmtInf **in its current file** (`i.file_id = t.transfer_file_id`) and §3.5 holds;
   - N, O, E∅: t is rule 3b's only candidate (§3.4.4);
   - U: §3.4.12.
4. Status:
   - t `cancelled` → `transfer_cancelled`;
   - `booked`/`returned`, or a debit booking of t → `already_debited`;
   - not `in_file`, or its file never downloaded, or not downloaded/sent → `not_handed_out` (S06: 6b-3).
5. `t.debtor_bank_account_id` and currency = the line's → `transfer_differs`.
6. t's run approved or sent with `run.transfer_id = t` → else `run_not_in_flight` (S10: 6b-3).
7. `amount` = `t.amount_minor` → `amount_differs`. On E the line is t's amount, or t's amount + the `fee` part (S08,
   §3.4.10 (a) for the fee's own rule). A line below t's amount is `amount_differs` (S08b: left).

**3.4.4 Rule 3b — a debit carrying no reference of ours** ([critic F9, F12, F13, L12]; classes N, O, E∅). It is the
payout twin of round 7's refund rule (m2c-6b-plan §2.4 3b), with uniqueness over every transfer the line may be.

The line has an account b, a currency, an amount a, a date d and, when it has one, a counterparty IBAN k. Its
candidates are read by key, **[critic2] CSO2-13** driven from the line: one probe of `bank_transfer_filed_amount_idx`
(§3.1) on (b, a), then each transfer's status, file item, run and payee IBAN by key. It never derives a date range from
the transfers to scan the account's lines, so its cost does not grow with the account's history of returned payouts:
- (i) payouts and sweeps `in_file` in a downloaded or sent file of b:
  - **[critic2] ML-4** a re-issue included (the draft excluded `replaces_transfer_id is not null`, so a
    reference-less debit of x' found its cancelled original x as the « only candidate » and booked the run's one
    real payout as a double payout);
  - for a payout, its run approved or sent with it;
  - amount a;
  - their item's `execution_date` in that file ≤ d;
  - payee IBAN = k.
- (ii) **[critic F9]** refunds `in_file` in a downloaded or sent file of b, re-issuing none, amount a, execution date
  ≤ d, payee IBAN = k. Round 7's rule takes such a line as the refund (`refund_transfer_follow`, l.4713-4716).
- (iii) **[critic F12]** payouts `cancelled` or `returned` that were an item of a file of b downloaded at least once,
  amount a, that item's execution date ≤ d, payee IBAN = k: a late or second execution of bytes the bank holds. A
  booked payout re-executed is not a candidate: its unplanned P is 0, as the client part's, so the two bookings are
  the same money.
  - **[critic2] ML-4** A cancelled x stays a candidate whatever its run's status, so a debit that may be x or its
    re-issue x' has both and is `line_ambiguous`. When x is the only candidate and its run is still approved or sent,
    the part is refused `run_still_live` (§3.4.6 rule 4).
  - **[critic2] ML-8** A returned x is **not** a candidate while its return item (`x.return_entry_id`) is held by a
    live line of a run whose payout t2 is a (i) candidate of this line (same amount a, same IBAN k). That run is the
    re-payment of x's return, and with the IBAN reconfirmed it pays the same amount to the same account: without this
    rule every reference-less debit of it would be `line_ambiguous` forever. The line books `payout(t2)`. If it was in
    fact x executed again, t2's own debit arrives later, finds x as (iii) (t2 is booked then) and is booked as x's
    unplanned payout with P from x's return item as it stands: the end state is the same either way (R2 booked, one
    unplanned payout, the same advance).

« Payee IBAN = k » applies when the line has k. **On class O and E∅, k is required**: without it there is no candidate,
and no client or own part either. The verdict:
- **one candidate** → the line may be booked only as that one: (i) `payout(t)` / `sweep(t)`; (iii)
  `unplanned_payout(x)`; (ii) the refund's M2b link (`link_debit`, not this command);
- **several** → every part is refused `line_ambiguous` (the refund link too, 6b-2c; the exit is §4.2);
- **none** → only the client and own parts (§3.4.6, §3.4.8).

Class O and E∅ for (i) is **Q16's default**: a payout keyed by hand at the bank for an in-flight run carries the bank's
own id. No fee part on N, O or E∅ (§3.4.10).

**3.4.5 `sweep(t)`** — the same rules for kind `sweep` (no run rule 6):
- E by its SWP id;
- B by its PmtInf (a sweep is alone in its PmtInf since 6b-1, l.276+);
- N, O and E∅ by rule 3b (S14 when a sweep is in flight).

**3.4.6 `unplanned_payout(x)` / `unplanned_payout(client c)`** — money that left for a client outside its run (S01–S05,
S03r, S07, S12, S13).
- With a transfer x:
  1. x of kind payout → `transfer_unknown`.
  2. The line is a debit (U: per stored detail) → `wrong_direction`.
  3. Identity → `not_its_line`:
     - E: `line.end_to_end_id = x.end_to_end_id`;
     - B: x is an item of the named PmtInf in that file (whatever x's current file) and §3.5 holds;
     - N, O, E∅: **[critic F12]** x is rule 3b's only candidate, as (iii);
     - U: §3.4.12.
  4. x is `cancelled`, `booked` or `returned`, else `not_cancelled_nor_booked` (x `ordered`/`in_file`: S06/S10, 6b-3).
     **[critic2] ML-4** A cancelled x is accepted only when its run (`x.run_id`) is `cancelled` or `booked`. With the
     run still `approved` or `sent` (x cancelled alone by `confirm_transfer_cancellation`, 20261116090000
     l.5015-5077, which leaves the run as it is; or x re-issued as x' by `transfer_file_release`, 20261115090000
     l.1693-1713, which moves `run.transfer_id` to x'), this debit is that run's single real payout, and the run can no
     longer be cancelled once it is on a statement (`transfer_already_debited`, l.5143-5148). Booked here, `items(x)`
     would be empty (no released line), P = 0, and the client paid once would be shown owing the whole amount, the
     run's items frozen for good. Refused `run_still_live` (detail: the run's number); left to 6b-3 with S10's
     late-predecessor booking (§1.2).
  5. Account and currency → `transfer_differs`.
  6. `amount` = `x.amount_minor` → `amount_differs` (E: the line is A, or A + the fee part).
  7. **[critic F6]** x is cancelled or returned, and an item of x's pool (§3.6.1) is held by a line of c's approved or
     sent run whose payout is still `ordered` or in a file never downloaded (`pending`, `generated`) →
     `client_run_cancellable` (detail: that run's number). That run can still be cancelled
     (`cancel_remittance_run`, l.5122-5141): cancelled first, its items come back to the queue and this debit is netted
     against them (P = A) instead of being advanced and then paid a second time by that run.
  - Effects: client c = `x.client_organization_id`, A = x's amount, P = §3.6.1, advance = A − P.
- With a client c (no transfer):
  1. c a client of the servicer (§3.4.1) → `client_unknown`.
  2. The line is a debit of class N, O or E∅ → else `not_its_line`.
  3. `line.counterparty_iban` = the IBAN of a confirmed payout account of c (`client_payout_account` with
     `confirmed_at` not null, status `active`, `returned` or `retired`, the line's currency) → `client_iban_mismatch`.
     The IBAN also registered for **another client of the same servicer** → `client_ambiguous` (**[critic CSO-5]**: a
     client of two servicers says nothing to either).
  4. **[critic F13, F12, L12] On every class**:
     - rule 3b finds a candidate of kind (i) or (ii) → `payout_in_flight_matches`;
     - it finds a candidate of kind (iii) → `cancelled_payout_matches`;
     - c has a live payout **not handed out** (ordered, or `in_file` in a file never downloaded) of the line's amount to
       that IBAN → `payout_not_handed_out_matches` (S06: the bank holds bytes we never served, or ops keyed it; 6b-3).
  5. `amount` = the line → `amount_differs` (no fee: §3.4.10).
  - Effects: A = amount, **P = 0** (Q8), advance = A; the entry's source is the line.

**3.4.7 `unplanned_sweep(x)`** — a sweep's late or second debit (S15, S04 for a sweep PmtInf): as 3.4.6 with kind sweep
(rules 1–6). Effects: a `servicer_sweep` of A to `x.creditor_bank_account_id`.

**3.4.8 `unplanned_sweep()`** (no transfer) — a debit to our own IBAN we did not order (S14, S07):
1. The line is a debit of class N, O or E∅ → `not_its_line`.
2. `line.counterparty_iban` = an active `bank_account` of the servicer with `purpose = 'own'`, in the line's currency →
   `own_account_unknown`.
3. **[critic F13]** On every class: a rule-3b candidate → `sweep_in_flight_matches` for a sweep,
   `payout_in_flight_matches` otherwise.
4. `amount` = the line → `amount_differs`.

**[critic CSO-2, F10]** The draft's `sweep_file_pending` refusal is dropped: the first download re-checks the sweep
against the share (§2.4).

**3.4.9 Effects shared by unplanned sweeps**: 4679 may go into debit (`servicer_shortfall`, P0, exists).

**3.4.10 `fee`** ([critic L2, F7, F15]; no transfer). A fee part is allowed in three places only:
- (a) on a **class-E debit**, beside the part of the transfer that line names by its own id (`payout(t)`, `sweep(t)`,
  `unplanned_payout(x)`, `unplanned_sweep(x)`), when the line exceeds that transfer's amount: the bank's charge on its
  own line (S08);
- (b) on a **class-E credit of kind `return`** (the bank flagged it), beside that transfer's return part
  (`payout_returned`, `sweep_returned`, or x's unplanned return), when the line is short of the amount;
- (c) **[critic2] ML-6, CSO2-1** on a **class-U debit** whose entry holds exactly one detail in all, ours, of the
  entry's direction, at the transfer's exact amount (`unsplit_detail_count = unsplit_ours = 1`, `unsplit_batch_count`
  null or 1): the ISO shape of S08, where `Ntry/Amt` is N + F and the detail's `TxAmt` is N. The fee is line − detail,
  and it must equal the stored `charges_minor`; with no stored charges the line stays (`unsplit_detail_missing`). The
  draft refused every fee on U, so the commonest camt.053 form of S08 was never bookable (`parts_do_not_add_up`),
  while its RMT id kept suppressing t's breach row.

**[critic2] ML-10** On (a) and (b) the line is one entry the parser read as one transaction, but a `TxDtls` without
an amount is read as the whole entry whatever it holds (`whole()`, camt053.py l.406-421). So:
- when the line has `charges_minor`, the fee must equal it, else `amount_differs`;
- when it has none (CSV, or no `Chrgs`), a fee equal to the amount of any transfer of ours on the line's account
  that was put in a file (the line's own transfer included: a double debit in one entry; in flight, booked, cancelled
  or returned, by `bank_transfer_filed_amount_idx`) is refused `fee_unexplained`. Such a « fee » is far more likely
  our transfer again than a charge, and booking it to 6270 would hide a double payment or another client's payout;
- otherwise the fee is accepted with no cap (Q10), and the sheet says « Le relevé n'indique pas de frais pour cette
  ligne : l'écart n'est pas justifié par le relevé. Vérifiez dans la banque avant de comptabiliser. »

Everywhere else it is refused `fee_not_allowed`: U (but (c)), B, N, O, E∅, own and client credits. There the
difference cannot be told apart from a third party's movement (a chargeback, a payment return, money to or from a
client), and booking it to 6270 would hide it. A fee alone stays `link_debit` « Frais bancaires ».

**3.4.11 `payout_returned(t)` / `sweep_returned(t)`** — a return the job did not book (S16, S20, U):
1. t of kind payout / sweep → `transfer_unknown`.
2. The line is a credit (U: per stored detail) → `wrong_direction`.
3. Line kind (§3.4.2) → `not_a_return`.
4. Identity → `not_its_line`:
   - E: the line's original id (else its own) = `t.end_to_end_id`;
   - B (lot credit): t is a returnable member of the named PmtInf (§3.5) and §3.5 holds;
   - U: §3.4.12;
   - N/O: refused.
5. Status:
   - t `ordered`/`in_file` → `return_before_debit`;
   - **[critic F1]** t has an `unplanned_payout` / `unplanned_sweep` booking whose entry is not reversed →
     `unplanned_open` (book the unplanned booking's return: §3.4.13);
   - **[critic2] ML-3** t has a debit line not booked beyond its booked debit (`private.transfer_late_lines(t)`, as
     the job's fact, §2.3) → `debit_pending` (detail: that line's id). Book that debit first (`unplanned_payout(t)`);
     this return is then its return;
   - `returned` or a return booking → `already_returned`;
   - `cancelled` → `transfer_cancelled` (its late debit is an unplanned payout: book `unplanned_payout_returned`);
   - `booked` without its debit booking → `return_differs`.
6. Account and currency → `transfer_differs`.
7. Line date ≥ t's debit entry date → `return_before_debit`.
8. Amount:
   - `amount` = t's amount;
   - on an E credit of kind `return`, the line is t's amount, or t's amount − the fee part;
   - on an own or client credit, exactly t's amount (**[critic L2]** no fee: a short unflagged return stays) →
     `amount_differs`;
   - a line above t's amount → `return_differs`;
   - on B, no fee part (`fee_not_allowed`).

**3.4.12 Unsplit lines (class U, S21/S22)** ([critic F8, F7, L11, L2]). The parts come from the statement's own
details (§2.2), never from ops:
- `line.unsplit_details` null (imported before 6b-2a), or a detail without its amount → `unsplit_detail_missing`;
- **[critic2] ML-5** the entry holds a detail that is not ours (`unsplit_detail_count` ≠ `unsplit_ours`), or its
  `NbOfTxs` is given and differs (`unsplit_batch_count` not null and ≠ `unsplit_detail_count`) →
  `unsplit_not_bookable`. A line imported before 6b-2a has no count and is already refused above. The draft relied on
  the signed Σ alone, which is fooled when the other details net to zero: our payout −1 640 beside a debtor's +250 and
  a third party's −250 makes the entry exactly, and the debtor's payment would never have been recorded;
- a detail carrying our refund's RFD or our top-up's TOP id, or one id twice → `unsplit_not_bookable` (refunds are
  M2b's, top-ups M2c-1's; the same transfer debited and returned in one entry is not expressible);
- the transfer parts are **exactly one per stored detail**, else `unsplit_parts_differ`. Each is:
  - the transfer whose `end_to_end_id` is the detail's id, **[critic2] CSO2-10** looked up by
    (`organization_id` = the line's, `end_to_end_id`) and then required to have the line's account as its debtor
    account (a debit detail) or as the account it went from (a credit detail). `end_to_end_id` is unique across
    servicers (20261111090000 l.1460) and a detail id is bank-supplied data, so a lookup by id alone could show
    another servicer's transfer. A foreign id, an unknown RMT/SWP-shaped id, or our transfer on another account give
    `unsplit_not_bookable` with the same `why` and no part listed, and §3.8 never collects or locks such a row;
  - at the detail's amount;
  - of the kind its direction and the transfer's state give. A debit gives `payout(t)` for a live t and
    `unplanned_payout(x)` for a cancelled, booked or returned x (sweeps alike). A credit gives `payout_returned(t)` /
    `sweep_returned(t)`, or x's unplanned return while x has an open unplanned booking.
- no fee part (`fee_not_allowed`, §3.4.10), but **[critic2] ML-6** the S08 shape of §3.4.10 (c): one detail in all,
  ours, at its transfer's exact amount, the fee = line − detail = the stored charges;
- each part keeps its own status, account, run and amount rules (4–8 of its kind; the amount is the transfer's exactly);
- the signed Σ rule of §3.4.2: the details of ours (and S08's fee) must make the entry. With the count rule above, the
  entry holds nothing but our details. **A movement of a third party inside an entry is never booked here, even when
  it nets to zero or a fee would make it add up**: the line stays (M2c-7, the bank; §1.2).
- **[critic2] CSO2-3** more stored details than `private.transfer_line_lot_cap()` → `lot_too_large`, checked first.

The options propose exactly that set (§3.11). Ops confirm it with a motif; there is nothing to compose.

**3.4.13 `unplanned_payout_returned(x | client c, returns_line_id)` / `unplanned_sweep_returned`** (S27, S28):
1. `returns_line_id`:
   - a debit line of the line's servicer (§3.4.1), bank account and currency → else `transfer_differs`;
   - holding an `unplanned_payout` (`unplanned_sweep`) booking of that transfer (or, without a transfer, of client c:
     its entry's client) → else `transfer_unknown`.
2. That booking's entry is not reversed (`ledger_entry_reversed_once_uq`) → `already_returned`.
3. This line is a credit of kind `return`, `own_transfer_in` or `client_transfer_in` (§3.4.2). **[critic L3]** Identity
   → `not_its_line`:
   - class E by x's id (own or original);
   - or a credit of **kind `return`** (the bank flagged it) whose counterparty IBAN is the IBAN the unplanned payout
     went to (`x.payee_iban`, or the debit line's counterparty for a client part);
   - an own or client credit carrying none of our references is refused. It may be the client paying the advance back
     (design §7.3 and §12: a `client_payment`, M2c-7) and waits (Q13).
4. **[critic F1]** When x has several open unplanned bookings, the one named must be the one with the largest advance
   (ties: the earliest line), else `return_differs`. The copy that comes back closes an advance before anything is
   owed again; the options propose that one.
5. Line date ≥ the unplanned entry's date → `return_before_debit`.
6. Its `double_payout` advance (if any) has no `commission_settlement` (`document_kind = 'advance'`) →
   `advance_settled` (M2c-7's claw-back would have used part of it).
7. Amount: `amount` = A. On an E credit of kind `return` the line is A, or A − the fee part; otherwise exactly A →
   `amount_differs`.

The payout account (x's run's, or c's of that IBAN) goes `active → returned`. The line carries our id or is the bank's
own return; an unreferenced credit never gets this far.

### 3.5 Batch lines and lots: the only subset
- **Universe M (debit)**: every item of the named PmtInf in its file (`transfer_file_item` where `pmt_inf_id` = the
  line's and the file is of the line's account), whatever the member's status:
  - live (`in_file` there);
  - left (`booked`/`returned` there);
  - cancelled (returned seen or not).

  One kind only: a refund in M → `batch_mixed`. A file never downloaded → `not_handed_out` (6b-3).
- **Universe M (lot credit)**, **[critic F1]**: the PmtInf's members booked there and not returned, and its members
  with an open unplanned booking, one element per member at its amount.
  - The subset's member takes `unplanned_payout_returned` (`unplanned_sweep_returned`) while it has an open unplanned
    booking (§3.4.13 rule 4 names which), else `payout_returned` (`sweep_returned`).
  - Two copies of one member returned in one credit cannot be expressed: such a credit makes no unique subset and stays.
- **Bound** (**[critic CSO-3]**): a PmtInf of more than `private.transfer_line_lot_cap()` items (500) →
  `lot_too_large`. **[critic2] CSO2-3** It is a keyed count, taken first, before the subset and before any read per
  member, in the options, the preview and the command alike; for a lot credit the count is of its returnable members.
- **Rule**:
  - the named parts' transfers ⊆ M, else `not_its_line`;
  - their amounts add up to the line (§3.4.2);
  - exactly one subset of M has amounts making the line (`private.unique_subset`), else `batch_ambiguous`.

  In a debit's subset, live members take `payout`, left and cancelled ones `unplanned_payout` (`unplanned_sweep`).
- **[critic CSO-3] When.**
  - A debit lot's items never change, so `unique_subset` runs before the locks (§3.2 step 6), on the items in
    `transfer_file_item.seq` order (**[critic2] CSO2-2**, the twin's order). Under the locks only the members'
    statuses are re-read: a member's kind or rule changing raises `split_changed` or its refusal.
  - A lot credit's universe depends on statuses. It is computed before the locks on the statuses then read, and
    re-computed under the locks only when one of them changed (`split_changed` if the subset or a kind changed).
- **The options read proposes that subset** (§3.11). Ops confirm it; they never compose a batch line.

### 3.6 Unplanned payouts: P, the pending row, the advance, the items, the draft
**3.6.1 P** (Q4's default, OQ-82) — **[critic F2, F3, F4, F5, L1]**: what the late or second payout paid of the items
x was meant to pay that are still owed and still waiting.
```
items(x)  = x cancelled: the ledger entries of x's run's released lines
                         (remittance_line where run_id = x.run_id and released)
            x returned:  x.return_entry_id (its payout_returned item: the client is owed x's amount again)
            x booked and never returned, or a client part (Q8): none → P = 0
eligible  = the items of items(x) with a row in private.remittance_pending (reserved by a draft or not: an item is in
            the queue or in exactly one live line, so an item frozen by a live run is never counted)
            -- [critic2] ML-1: less the pool's unplanned_payout rows (−A of an earlier unplanned booking) and their
            -- double_payout advance rows: the attributions below already count what those bookings netted
net(i)    = Σ remittance_pending.amount_minor of i and of every pending entry in i's reversal chain
            (ledger_entry.reverses_entry_id = i, then that entry, …, each by key through
            ledger_entry_reversed_once_uq; the 4670 trigger queues each reversal as its own row,
            20261111090000 l.1281-1299) — signed: a negative item (an allocation_reversal, a client_advance
            reversal) stays negative
paid(i)   = Σ private.unplanned_paid_item.amount_minor of i whose booking entry is not reversed
            + what earlier parts of this call attributed to i
cap(x)    = greatest(0, Σ over eligible i of net(i) − Σ over eligible i of paid(i))   -- [critic2] ML-1: signed sum,
                                                                                   -- floored once, not per item
left(i)   = greatest(0, net(i) − paid(i))                     -- what each positive item can still take
queue(c)  = greatest(0, Σ private.remittance_pending.amount_minor of (c, currency), reserved or not)
            − the P of earlier parts of this call for c            -- under the allocation lock
P         = greatest(0, least(A, queue(c), cap(x)))
attribute P over the eligible items with left(i) > 0 in (posted_at, ledger_entry_id) order, each up to left(i):
            one private.unplanned_paid_item row per item it touches  (P ≤ cap(x) ≤ Σ left(i), so P always fits)
```
**[critic2] ML-1** The draft floored `net(i)` at 0 item by item and summed only the positive items. A cancelled run's
released lines are re-queued signed (`cancel_remittance_run`, 20261112090000 l.2122-2126), so the pool routinely holds
negative items: an `allocation_reversal`, the `client_advance` +X paired with it by a 6b-1 `payout_overrun` cover
(`bank_booking_post_rows` step 4). Example: R1 holds a +1 000, r −300 (b bounced after R0's approval) and v +300 (R0's
cover); R1 is cancelled after download; a bounces (−1 000) and n +2 000 arrives; x (1 000) is executed late. The
draft's Σ left was 0 + 0 + 300 = 300, so P = 300 netted the double payout against n, a collection unrelated to x. The
signed net of x's items is 0 + (−300) + 300 = 0, so P = 0 and the advance is 1 000, as F3's rule wants.

What this guarantees:
- **P ≤ A**.
- **P ≤ what the queue can net.** The netting happens only in the pending queue, never in a run already approved or
  sent. So the in-flight run's own booking never needs a `payout_overrun` cover for the double payout's excess, which
  stays a `double_payout` advance (F5).
- **P ≤ the signed net still owed of the items x was meant to pay, across every unplanned booking** (**[critic2]
  ML-1**: signed, reversal chains and negative items included).
  - An item released by two cancelled runs is counted once (F4).
  - An item reversed since its run was cancelled counts net of its reversal (F3).
  - A negative item of the pool lowers the cap: what the client owes back on x's items is not owed to it.
  - A returned x's re-execution pays its return item, so the client is not paid that item a second time (F2).
- **Every excess is the servicer's advance.** Q4 and founder #7 allow no hold-back without a claw-back clause (design
  §13.1, OQ-38).

The draft's sentence « an item released by two cancelled runs may be counted by both pools — the owed cap bounds it … »
is withdrawn, because it was false (L1), and so is the matching §11 risk row.

Residual, recorded in OQ-82 (L1): an item P counted whose payment is reversed afterwards leaves the client's queue net
negative. That is netted against later collections, as any reversal of an item not yet remitted is today. M2c-7's
`cover_remitted_reversals` keys on booked runs and will not see it.

**3.6.2 The pending row** (plan §2.3 [critic], kept):
- one `private.remittance_pending` row per unplanned payout part: `ledger_entry_id` = its `remittance` entry, kind
  `unplanned_payout`, amount **−A**, `posted_at` = the entry's, `draft_run_id` null;
- the 4670 trigger skips `remittance` entries (20261111090000 l.1286-1299); the advance's own posting queues
  `client_advance` +(A − P) through the trigger;
- net in the queue: −P. I14 holds (owed falls by P, pending by P);
- `remittance_line_insert_guard` accepts the next run's −A line (its entry's 4670 posting).

**3.6.3 The advance**: when A − P > 0, a `client_advance` entry and row:
- cause `double_payout`, `cause_entry_id` = the remittance entry;
- `bank_transaction_id` = the line, `transfer_id` = x or null, `mandate_id` null;
- posted after the remittance, so LG008 holds at `private.ledger_check_now()`.

**3.6.4 The items**: one `private.unplanned_paid_item` row per item P was attributed to (§3.1), in the same transaction.
- An `unplanned_payout_returned` reverses the remittance, so its rows stop counting: those items are owed again, which
  is the +P the return re-queues, and a later late execution may count them.
- The rows also serve « Suivi » and the statement's late cause (§5).

**3.6.5 The draft** ([critic CSO-6, CSO-7, CSO-12]). For each client of an unplanned payout part or an unplanned
return, its live run (at most one, `remittance_run_pending_uq`) was locked in step 1 of §3.8.
- **Draft** → `private.remittance_draft_requeue(run)`:
  - reserve the client's unreserved pending items;
  - then set `job = 'prepare'`, a new `job_token`, `job_queued_at`, `known_at = clock_timestamp()`, `service_to`;
  - set `prepared_at`, `inputs_hash` and `line_count` null, and recount `item_count`;
  - set `requested_execution_date` and `late_reason` null, as `remittance_back_to_draft` does (20261112090000
    l.1605-1616);
  - set **`last_failure` null**, as `refresh_remittance_run` does. A requeue is not a failure, and the web words any
    `last_failure` of step `prepare` as « Préparation échouée … « Actualiser » la relance » (`lib/remittance/runs.ts`
    l.163-166);
  - `version + 1`, and `pgmq.send('remittances', {type: 'prepare', run_id, token})`.
- **The prepared draft is not cleared here.** `remittance_prepare_begin` clears it under the run lock when the new
  token's job starts (20261112090000 l.1068-1080), and the approval refuses `job = 'prepare'`. Clearing a 50,000-line
  draft under both servicer-wide locks would hold off the allocation job and every approval (refresh clears before the
  allocation lock for that reason, review perf#3, l.963-966).
- An approval or prepare in flight finds another token and does nothing (`status: skipped`, 20261114090000 l.811).
- A draft found under the locks that step 1 did not lock → `split_changed`. It is never locked late:
  `refresh_remittance_run` holds that row and waits for the allocation lock.
- **Approved or sent**: rule 7 of §3.4.6 decides (`client_run_cancellable`); otherwise nothing. Its items are frozen,
  and P counted only what was still waiting.
- **[critic2] ML-9** The preview and the booking result carry, per unplanned part, which bound set P: `p_bound` ∈
  `amount` (P = A), `items` (cap(x)), `queue` (queue(c)), `none` (P = 0 by Q8 or no items). The sheet (§7.3) and the
  statement (§5) word the advance from it, never from a guess.
- The run page says why the gross changed from durable data, not from `last_failure`: the unplanned items the draft
  holds (6b-2c, §4.4).

### 3.7 Entries posted (all at the line's booking date; + debit / − credit)
| Part | Entry (type) | Lines | Idempotency key | Source | State changes |
|---|---|---|---|---|---|
| `payout(t)` | `remittance`; `client_settlement`; cover `client_advance` (`payout_overrun`) if 4670[c] > 0 | +4670[c] N / −5120 N; +4670[c] D / −4679 D ‖ +4689 D / −4111[c] Dc / −4112[c] Da ‖ +44574 v / −44571 v; +4679 X / −4670[c] X ‖ +4112[c] X / −4689 X | `remit:<t>`, `settle:<run>`, `adv:payout:<t>` | bank_transfer t; remittance_run; client_advance | via `bank_booking_post_rows`: t booked (`entry_id`), run booked (`booked_on`), breach row per positive live line with `latest_execution_date` < date (`payout_returned` lines « bloqué »), the line's review deleted |
| `sweep(t)` | `servicer_sweep` | +4679 S / −5120 S ‖ +5122[t.creditor] S / −4689 S | `sweep:<t>` | bank_transfer t | t booked |
| `fee` | `bank_fee` | +4679 F / −5120 F ‖ +6270 F / −4689 F | `fee:<line>` | bank_transaction | — |
| `unplanned_payout(x)` | `remittance` | +4670[c] A / −5120 A | `remit:line:<line>:<n>` | bank_transfer x | pending row −A; `unplanned_paid_item` rows; x unchanged (cancelled stays cancelled, `bank_transfer_guard`) |
| … its advance (A − P > 0) | `client_advance` | +4679 (A−P) / −4670[c] (A−P) ‖ +4112[c] (A−P) / −4689 (A−P) | `adv:line:<line>:<n>` | client_advance row | trigger queues `client_advance` +(A−P) |
| `unplanned_payout(c)` | `remittance` (+ advance A) | as above | `remit:line:<line>:<n>`, `adv:line:<line>:<n>` | bank_transaction line | as above, P = 0 |
| `unplanned_sweep(x)` / `()` | `servicer_sweep` | +4679 S / −5120 S ‖ +5122[x.creditor or the own account of the counterparty] S / −4689 S | `sweep:line:<line>:<n>` | bank_transfer x / bank_transaction | 4679 may go into debit (`servicer_shortfall`) |
| `payout_returned(t)` | reversal of `t.entry_id` (`private.ledger_reverse`) | +5120 N / −4670[c] N | `return:<line>:<t>` | — | trigger queues `payout_returned` +N; t returned (`return_entry_id`); the run's payout account `active → returned` (only while active) |
| `sweep_returned(t)` | reversal of `t.entry_id` | +5120 S / −4679 S ‖ +4689 S / −5122 S | `return:<line>:<t>` | — | t returned |
| `unplanned_payout_returned` | reversal of the unplanned `remittance`; reversal of its advance | +5120 A / −4670[c] A; −4679 X / +4670[c] X ‖ −4112[c] X / +4689 X | `return:<line>:<n>`, `return:adv:<line>:<n>` | — | trigger queues `payout_returned` +A and `client_advance_reversal` −(A−P): net +P; its `unplanned_paid_item` rows stop counting; payout account (x's run's, or c's of that IBAN) `active → returned` |
| `unplanned_sweep_returned` | reversal of the unplanned `servicer_sweep` | +5120 S / −4679 S ‖ +4689 S / −5122 S | `return:<line>:<n>` | — | — |

**Entry reasons** — fixed French text, never ops' motif.

**[critic CSO-1]** A ledger entry's reason is readable by the client's whole-client members for `remittance`,
`client_advance` and `reversal` entries (policy `ledger_entry_read`, 20261111090000 l.1409-1413; SELECT on every column,
20261108170000 l.800-801). The motif stays on `bank_line_booking.reason`, which only staff read (20261111090000
l.4174-4175). The reasons, worded for the mechanism rather than its legal qualification (**[critic L13]**):
- planned `payout` part: the job's (null), through `bank_booking_post_rows` redefined (§3.12);
- unplanned remittance: « Virement exécuté hors reversement (relevé du jj/mm/aaaa) »;
- its advance: « Virement hors reversement : avance du cabinet »;
- unplanned sweep: « Virement au compte propre hors ordre de Collectoo (relevé du …) »;
- planned return: the job's, « Virement de reversement revenu impayé (relevé du …) »;
- unplanned return: « Virement hors reversement revenu (relevé du …) »;
- its advance's reversal: « Avance du cabinet annulée : virement hors reversement revenu (relevé du …) ».

**`private.transfer_line_post(org)`**, in this order (one transaction, the command's):
1. The unplanned parts and the returns, posted by this function itself:
   - the unplanned remittances and sweeps (one `ledger_post_set`);
   - their advances (one `ledger_post_set` + `client_advance` rows);
   - the pending rows and the `unplanned_paid_item` rows;
   - the returns and unplanned returns (`ledger_reverse`, one per part, few);
   - the bookings of these parts (seq 1..k on the line: `max(seq) + row_number() over (partition by line order by n)`);
   - the transfers `returned` with `return_entry_id` (by the array of their ids, keyed as l.1015-1020), and the payout
     accounts returned.
2. The planned parts (`payout`, `sweep`, `fee`):
   - `private.bank_booking_begin()`, then their rows into `_bank_booking`: method `ops`, `decided_by = auth.uid()`,
     the motif (→ `bank_line_booking.reason` only, CSO-1);
   - `pg_temp._bb` built with **exactly the columns `private.post_bank_bookings` builds** (its select list as
     redefined in 6b-2a, copied; `book_minor` = the part's amount);
   - then `private.bank_booking_post_rows(org)` (§3.12). It numbers its bookings after step 1's, posts settlements,
     covers and breach rows, books runs, deletes the line's review, runs `ledger_check_now()` and checks the line booked
     whole.

   Only these kinds enter `_bank_booking`. Its `unique nulls not distinct (bank_transaction_id, transfer_id)` (l.487)
   admits one transfer-less row per line: the `fee` (at most one per line, §3.4.0). The transfer-less unplanned parts
   stay in step 1. pgTAP 037 checks that the two `_bb` builds have the same columns in the same order.
3. Without planned parts:
   - delete the line's review and run `private.ledger_check_now()`;
   - check the line's signed completeness (`private.bank_line_cash_moved` = the signed line, else LG001);
   - `set constraints public.bank_line_booking_complete immediate`, then `deferred`.

### 3.8 Locks — the job's order (l.1102-1118), plus the drafts
`private.transfer_line_locks(p_line uuid, p_parts jsonb)` first collects the keys without locks, reading only ids that
passed §3.4.1 ([critic CSO-5]):
- the transfers named;
- every member of a class-B line's PmtInf;
- every rule-3b candidate of a class N/O/E∅ line;
- the transfers of the unplanned bookings an unplanned return names.

Then it locks, each set in id order:
1. runs `FOR UPDATE`:
   - the transfers' runs;
   - the **live run (draft, approved or sent) of every client of an unplanned part or unplanned return**, read by
     `remittance_run_pending_uq`'s key and re-read under the lock (§3.6.5; F6's rule reads it);
2. `client_payout_account` `FOR NO KEY UPDATE`: the accounts a return marks `returned`;
3. `bank_account` `FOR SHARE`: the line's, the transfers' debtor and creditor accounts, and the own account of the
   counterparty IBAN;
4. `payment` `FOR KEY SHARE`: the payments of the payout parts' runs' lines late at this date (6b-1 concurrency-2,
   l.1153-1185);
5. `pg_advisory_xact_lock(hashtext('payments:' || org))`: always, since every part but a sweep's or a fee moves 4670;
6. `bank_transaction` `FOR NO KEY UPDATE`: the line and the debit lines `returns_line_id` names;
7. `pg_advisory_xact_lock(hashtext('remit:' || org))`;
8. `transfer_file` `FOR SHARE`: the transfers' current files, the PmtInf's file, and the file of the live run's payout
   (F6); **[critic2] ML-4** the run of a cancelled x named by an unplanned part is locked in step 1 with the
   transfers' runs, so `run_still_live` is read under the lock;
9. `bank_transfer` `FOR UPDATE`: every key transfer (all members of a PmtInf, booked or not).

The rules are then read under these locks. Anything stale between the options read and the command gives
`split_changed` or a rule's refusal, never a wrong booking. The funds pass takes the same order, so the job and the
command serialise on the line: the job re-checks `booked` and skips it, and `apply_bank_bookings` writes no review on a
booked line (l.1574-1586).

What runs before the locks (**[critic CSO-3]**): the tenant filter, a debit lot's item count and subset, and the key
collection. What never runs under the locks is a search whose size grows with the lot.

### 3.9 Compare and set, idempotency, replay
- `private.transfer_line_text()`: the parts in order, each `kind:transfer_or_client:amount:P:advance:returns_line`,
  joined by `;`, then `|drafts:` and the draft run ids to requeue. The options read (§3.11) and the preview compute it
  with the same function on the same rules. The command recomputes it under the locks; any difference →
  `split_changed`.
- Replay: `command_replay`/`command_record` on (`book_transfer_line`, key, request), after the key's advisory lock
  (§3.2 step 2). A second call with a new key on the same line → `already_booked`. The entries' keys
  (`remit:line:<line>:<n>`, …) cannot be reused: a line is booked once.
- The funds job: a line ops booked leaves `private.bank_booking_candidates` (booked lines excluded) for good.

### 3.10 Refusal codes and French labels
Raised as `transfer line booking refused: <code>` (check_violation). They are mapped in `lib/payments/transfer-lines.ts`
(6b-2b), and every code is tested present.

| Code | Label |
|---|---|
| `bad_request` | « La demande est incomplète ou mal formée : rouvrez la ligne et recommencez. » |
| `held_duplicate` | « Cette ligne est retenue comme doublon possible : traitez-la d'abord dans « Doublons possibles ». » |
| `already_booked` | « Cette ligne est déjà comptabilisée. » |
| `already_linked` | « Cette ligne est déjà rattachée ou classée. » |
| `line_is_payment` | « Cette ligne a été enregistrée comme le paiement d'un débiteur : elle ne peut pas être comptabilisée ici. Prévenez le support. » |
| `parts_do_not_add_up` | « Les montants choisis ne font pas exactement le montant de la ligne. » |
| `not_a_transfer_line` | **[critic F16]** « Cette ligne n'est pas un virement émis (c'est un remboursement, un prélèvement ou le retour d'un paiement) : elle ne se comptabilise pas ainsi. » |
| `transfer_unknown` | « Ce virement n'est pas un virement du cabinet sur ce compte. » |
| `wrong_direction` | « Ce virement ne peut pas être comptabilisé sur une ligne de ce sens (débit ou crédit). » |
| `not_its_line` | « Cette ligne ne porte ni la référence de ce virement, ni celle de son lot dans son fichier, et rien ne permet de dire que c'est lui. » |
| `transfer_cancelled` | « Ce virement est annulé : son débit se comptabilise comme « Virement hors reversement ». » |
| `already_debited` | « Ce virement est déjà débité : un second débit se comptabilise comme « Virement hors reversement ». » |
| `not_handed_out` | **[critic L15]** « Ce virement n'a jamais été remis à la banque (aucun fichier téléchargé) : ce débit ne peut pas encore être comptabilisé. Vérifiez dans la banque d'où vient cet ordre et prévenez le support. » |
| `transfer_differs` | « Ce virement est d'un autre compte ou d'une autre devise que la ligne. » |
| `run_not_in_flight` | « Le reversement de ce virement n'est plus en cours : ce débit ne peut pas encore être comptabilisé comme le sien. Prévenez le support. » |
| `amount_differs` | « Le montant ne correspond pas à celui du virement. » |
| `line_ambiguous` | « Plusieurs virements du cabinet (reversement, quote-part, remboursement, ou virement annulé que la banque a pu exécuter) ont ce montant vers ce compte : sans notre référence sur la ligne, impossible de savoir lequel la banque a exécuté. Demandez le détail à la banque. » |
| `batch_ambiguous` | « Plusieurs combinaisons des virements de ce lot font le montant de la ligne : demandez à la banque le détail du lot. » |
| `lot_too_large` | **[critic CSO-3]** « Ce lot compte trop de virements pour être comptabilisé depuis cet écran : prévenez le support. » **[critic2] CSO2-3** Also given for an unsplit entry or a lot credit above the cap; the label says « Ce lot ou cette écriture compte trop de virements … » |
| `batch_mixed` | « Ce lot contient des remboursements ou des virements de natures différentes : il ne peut pas être comptabilisé ici. Demandez le détail à la banque. » |
| `not_cancelled_nor_booked` | **[critic L15]** « Ce virement n'est ni annulé, ni débité, ni revenu : comptabilisez la ligne comme « Débit d'un reversement » ; si ce virement n'a jamais été remis à la banque, prévenez le support. » |
| `run_still_live` | **[critic2] ML-4** « Ce virement a été annulé, mais son reversement est toujours en cours : ce débit est le paiement de ce reversement, pas un virement hors reversement. Il ne peut pas encore être comptabilisé ; ne faites pas annuler ce reversement et prévenez le support. » (the page adds the run's number from the detail) |
| `debit_pending` | **[critic2] ML-3** « Un autre débit de ce virement (second débit, ou débit après annulation) figure sur un relevé sans être encore comptabilisé : comptabilisez-le d'abord ; ce retour sera alors celui du virement hors reversement, et rien ne sera reversé deux fois. » |
| `fee_unexplained` | **[critic2] ML-10** « L'écart entre la ligne et le virement a le montant d'un virement du cabinet, et le relevé n'indique aucun frais : ce n'est sans doute pas des frais (virement débité deux fois, ou un autre virement dans la même écriture). Demandez le détail à la banque. » |
| `client_run_cancellable` | **[critic F6]** « Les sommes que ce virement a payées sont dans un reversement de ce client validé mais pas encore remis à la banque : faites d'abord annuler ce reversement par un administrateur (ces sommes reviennent en attente et ce débit en sera déduit), puis recommencez. » (the page adds the run's number from the detail) |
| `client_unknown` | « Ce client n'est pas un client du cabinet. » |
| `client_iban_mismatch` | « Le compte crédité n'est pas un compte de reversement enregistré de ce client. » |
| `client_ambiguous` | « Ce compte de reversement est enregistré pour plusieurs clients du cabinet : prévenez le support. » |
| `payout_in_flight_matches` | « Un virement du cabinet en cours de ce montant vers ce compte (reversement, quote-part ou remboursement) peut être ce débit : comptabilisez-le comme son débit (« Débit d'un reversement »), ou rattachez-le au remboursement. » |
| `cancelled_payout_matches` | **[critic F12]** « Un virement annulé ou revenu de ce montant vers ce compte a pu être exécuté par la banque : comptabilisez ce débit comme son « Virement hors reversement ». » |
| `payout_not_handed_out_matches` | **[critic F13]** « Un reversement de ce client de ce montant n'a jamais été remis à la banque (pas encore dans un fichier téléchargé) : ce débit ne peut pas encore être comptabilisé. Vérifiez dans la banque d'où vient cet ordre et prévenez le support. » |
| `own_account_unknown` | « Le compte crédité n'est pas l'un de nos comptes propres enregistrés. » |
| `sweep_in_flight_matches` | « Une quote-part du cabinet en cours de ce montant peut être ce débit : comptabilisez-la comme son débit. » |
| `fee_not_allowed` | **[critic L2, L15]** « Des frais bancaires ne se comptabilisent ici que sur la ligne même d'un virement du cabinet (son débit, ou son retour signalé par la banque) : ailleurs, ils ne se distinguent pas de l'argent d'un tiers. » |
| `not_a_return` | « Cette ligne n'est pas un crédit qui revient. » |
| `return_before_debit` | « Le débit de ce virement n'est pas comptabilisé, ou il est daté d'après ce retour. » |
| `unplanned_open` | **[critic F1]** « Ce virement a aussi été exécuté hors reversement, et ce second virement n'est pas revenu : ce retour se comptabilise comme le sien (« Virement revenu », virement hors reversement), pour que rien ne soit reversé deux fois. » |
| `already_returned` | « Ce virement est déjà revenu. » |
| `return_differs` | « Ce retour ne correspond pas au virement (montant supérieur, virement sans débit comptabilisé, ou autre virement hors reversement à annuler d'abord). » |
| `advance_settled` | « L'avance liée à ce virement a déjà été en partie récupérée : ce retour ne peut pas être comptabilisé ici. Prévenez le support. » |
| `unsplit_detail_missing` | **[critic F8]** « Le relevé ne détaille pas assez cette écriture (un montant ou les frais de la banque manquent, ou la ligne a été importée avant que Collectoo garde ce détail) : elle ne peut pas être comptabilisée ici. Demandez le détail à la banque et prévenez le support. » (**[critic2] ML-6** « ou les frais ») |
| `unsplit_not_bookable` | **[critic2] ML-5, CSO2-10** « Cette écriture contient autre chose que des virements du cabinet sur ce compte (le paiement d'un débiteur, un autre débit, un remboursement ou un approvisionnement du cabinet), ou deux fois le même virement : elle ne peut pas être comptabilisée ici. Demandez le détail à la banque et prévenez le support. » |
| `unsplit_parts_differ` | « Les virements nommés ne sont pas exactement ceux que le relevé détaille dans cette écriture, à leurs montants. » |
| `split_changed` | « La situation a changé depuis l'affichage (sommes en attente, brouillon, virements) : rouvrez la ligne pour voir la nouvelle répartition. » |
| `posting_failed` | « La comptabilisation a été refusée par les contrôles du grand livre : rien n'est enregistré. Prévenez le support. » |

« not allowed » and « a reason is required » keep their existing labels. Two SQLSTATEs get codes of their own:
- the lock timeout (55P03, `lock_timeout 2s`): **[critic2] CSO2-6** most waits are not on the line but on the
  servicer-wide `payments:` or `remit:` lock, held by an allocation chunk (8–9 s per 10k) or an approval job (7.9 s at
  50k). The command catches 55P03 and re-raises it with the step it was waiting at:
  - `busy` (the line, its runs, its transfers, its files): « Cette ligne ou un virement qu'elle concerne est en
    cours de traitement : réessayez dans un instant. »;
  - `allocation_busy` (the `payments:` or `remit:` advisory lock): « Une imputation ou une validation de reversements
    est en cours pour ce cabinet : réessayez dans quelques secondes. », as the existing `allocation_busy` hint says;
- **[critic CSO-3]** the statement timeout (57014): `timeout`, « La comptabilisation a pris trop de temps et n'a rien
  enregistré : réessayez ; si cela se répète, prévenez le support. »

### 3.11 Reads (6b-2b, used by 6b-2c's pages)
Both reads are `SECURITY DEFINER`:
- money staff of the line's servicer only (`private.money_staff_org_ids()`); another servicer's line, a client member or
  a collector gets null;
- volatile (they build temporary tables, `on commit drop`);
- keyed: no sequential scan of `bank_transfer`, `bank_transaction` or `transfer_file_item` (`enable_seqscan = off`
  where 6b-1 sets it).

**[critic CSO-4]** Each is read for **one line**, when ops open that line's sheet (a server action), never once per row
of a list (§4.1: the list carries a cheap `bookable_as`).

- **`public.transfer_line_options(p_bank_transaction_id uuid) returns jsonb`**: `{class, kind, direction, amount_minor,
  unsplit_ours, proposals: [{action, parts: [{kind, transfer_id, client_id, returns_line_id, amount_minor,
  end_to_end_id, run_id, run_number, client_name, status}], preview}], members: [{transfer_id, kind, status,
  amount_minor, run_number, client_name, end_to_end_id, in_proposal}], refusal}`. Proposals per class:
  - E debit:
    - t live → `payout(t)`;
    - t cancelled, booked or returned → `unplanned_payout(t)` (`unplanned_sweep`) with its P;
    - a `fee` part only when the line exceeds the transfer (§3.4.10 (a)).
  - E credit:
    - t booked with no open unplanned booking → `payout_returned(t)`, with a `fee` part only on a kind-`return` line
      short of N;
    - **[critic F1]** t with an open unplanned booking → only `unplanned_payout_returned` with `returns_line_id` =
      that booking's line (the largest advance, §3.4.13).
  - B debit: the unique subset (§3.5), or `refusal: batch_ambiguous` with `members`. **[critic2] CSO2-3** Above the cap:
    `{refusal: 'lot_too_large', member_count}` with no `members`, answered from the keyed count before any subset or
    per-member read; `members` is never longer than 50 (the sheet says « … et N autres »).
  - B credit: the unique subset of returnable members (§3.5); above the cap, as B debit.
  - **[critic F9, F12, F13]** N, O, E∅ debit:
    - the one rule-3b candidate as its part;
    - with no candidate, the client by IBAN (`unplanned_payout(c)`), else our own IBAN (`unplanned_sweep()`);
    - else `refusal` (`line_ambiguous`, or the matching refusal of §3.4.6 rule 4), or nothing.
    - **[critic2] ML-4** a cancelled x whose run is still approved or sent: `refusal: run_still_live`, no proposal.
  - **[critic2] ML-3** E credit (or lot credit) of a transfer with a pending debit line: `refusal: debit_pending`, and
    the proposal shown is that debit line's own proposal (a link to open it), never the return.
  - **[critic2] ML-11** N, O, E∅ credit of **kind `return`** (bank-flagged, no reference of ours): the unplanned return
    of the open unplanned booking whose payout went to the line's counterparty IBAN at the line's exact amount
    (`x.payee_iban`, or the debit line's counterparty for a client part), the largest advance first (ties: the earliest
    line), as §3.4.13 rule 4; no fee (§3.4.10). This is the only route back for a client part (S13, S07), which never
    carries our id; without it the advance stayed open « à récupérer auprès du client » although the money came back.
    No open booking matches → no proposal.
  - **[critic L3]** own or client credit without our id: no proposal (Q13).
  - **[critic F8]** U: the stored details' parts (§3.4.12), or `refusal` (`unsplit_detail_missing`,
    `unsplit_not_bookable`, `parts_do_not_add_up`, **[critic2] CSO2-3** `lot_too_large` above the cap, checked
    first). There is no candidates list to compose from. **[critic2] CSO2-10** A detail naming nothing of the line's
    servicer and account is never shown (no id, run or client name of another servicer in the JSON).
  - **[critic2] ML-10** E debit with a fee part and no stored charges: the proposal carries `fee_unexplained: false`
    and the sheet's sentence « Le relevé n'indique pas de frais … » (§3.4.10); with `fee_unexplained`, no proposal.

  `action` ∈ `payout` (« Débit d'un reversement »), `lot` (« Débit d'un lot de reversements », mixed planned and
  unplanned), `unplanned_payout` (« Virement hors reversement »), `unplanned_sweep` (« Virement au compte propre »),
  `returned` (« Virement revenu »), `detail` (U).
- **`public.transfer_line_preview(p_bank_transaction_id uuid, p_parts jsonb) returns jsonb`**: `{ok, why, parts: [{…,
  paid_minor, advance_minor, p_bound, late}], drafts: [{run_id, number}], supersedes_file, expected_text}`.
  - **[critic2] ML-9** `p_bound` per unplanned part (§3.6.5).
  - **[critic2] CSO2-4** `supersedes_file`: `{file_id, number}` when the booking lowers 4679 (an unplanned payout's
    advance, a fee, an unplanned sweep, a planned payout's `payout_overrun` cover) and a `generated` file of the
    servicer holds a sweep that would then exceed the share (§2.4's formula, read with the booking's effect); else
    null. The sheets say the file will be replaced only then.
  - It runs the same `transfer_line_check` with `strict => false`: it never raises a refusal and returns `why`, takes
    no lock, and filters tenants first (§3.4.1).
  - `late` means the payout part's run has a positive live line whose `latest_execution_date` < the line's date (a
    breach row will be written).

### 3.12 Redefinitions in 6b-2b (each copied from the file named; only the stated change)
- **`private.bank_line_booking_guard`** (20261116090000 l.1591). Each kind is allowed on these lines and entries:

  | Kind | Lines and entries it is now allowed on |
  |---|---|
  | `fee` | a debit of kind `transfer_out` or `batch_unsplit` (S08 on a class-E line of those kinds), as on `other_debit`; on a credit only of kind `return`, as today |
  | `payout_returned`, `sweep_returned` | also own/client credit kinds (S16) |
  | planned and return kinds | either direction on a line with `unsplit_ours > 0` |
  | `unplanned_payout_returned`, `unplanned_sweep_returned` (new) | entry `reversal` whose reversed entry is the entry of an `unplanned_payout` (`unplanned_sweep`) booking of the same transfer (or of none), on a credit of kind `return`, `own_transfer_in` or `client_transfer_in` |

  Still one keyed lookup per row.
- **`private.pending_item_deadlines`** (20261116090000 l.3848) and the worker's `_held_to` (`jobs/remittances.py`
  l.595, parity). **[critic F11, L4]** The `payout_returned` branch (l.3880-3900) is kept only for a transfer's own
  planned remittance: `and bt.entry_id = re.id`.
  - The item of a reversed **unplanned** remittance is not monitored while the items its P paid are still pending: no
    deadline, as an advance's. Those items kept their own clocks throughout (Q15's default), and its A − P is netted
    by the advance's reversal.
  - So an S03 returned (P = 0, net 0) writes no breach row « bloqué : virement revenu impayé », raises no
    `remittance_due_critical` and needs no late reason.
  - **[critic2] ML-2** When the unplanned remittance has `unplanned_paid_item` rows whose items are no longer pending
    (frozen in a live or booked `remittance_line`, the −A row netting them: their clocks ended at that run), the
    re-owed item is held like a planned return: a third branch, reached by key (the reversal → the reversed
    remittance → its `unplanned_paid_item` rows by `booking_entry_id` → each item's live `remittance_line` by
    `ledger_entry_id`), takes the line with the earliest `latest_execution_date`, its E, mandate and terms version
    exactly as the planned branch reads them. The nightly check writes its breach row with `blocked_reason`
    `payout_returned`, the schedule drafts it, and the next approval needs a late reason. Without it: x booked and
    returned (ρ +1 640), re-executed (P = A on ρ), c's net-0 draft approved late and booked at approval (N = 0,
    20261112090000 l.1887-1891), then the second copy returned too — the client was owed 1 640 of collections past
    their deadline with no breach row, no alert and no scheduled run. Reachable with the switch off.
  - Parity: `_held_to` (`jobs/remittances.py` l.595) gets the same third branch; the parity test covers it.
  - The draft's « released lines included » rule is withdrawn. Recorded in OQ-36 and CPCE-08.
  - Note for 6b-3: a late predecessor booked as its run's payout keeps `entry_id` null (m2c-6b-plan §3.1). Its return
    must then be keyed by its `payout` booking's entry instead.
- **`private.bank_booking_post_rows`** (20261116090000 l.858). **[critic CSO-1]** A `payout` row's `remittance` entry
  reason is null (the job's), whatever `b.reason`. `b.reason` still goes to `bank_line_booking.reason`. This departs
  from §1.3 item 1's « unchanged »; parity with the job's entries is pinned by pgTAP 037 C.
- **[critic2] ML-2** `private.pending_item_deadlines` reads `private.unplanned_paid_item` (by its primary key's
  leading column, `booking_entry_id`) for the third branch above; the function is `SECURITY DEFINER`, so the table's
  revoked grants (§3.1) do not stop it.

### 3.13 How a booked line leaves « À classer »
- Every « À classer » branch of `public.debit_queue` already excludes a line with a booking (l.2416-2431), and the review
  row is deleted by the posting.
- `cancelled_transfer_debited`, `transfer_debited_twice`, `transfer_not_handed_out`, `transfer_unknown` and
  `bank_line_unbooked` exclude booked lines, and so does `transfer_late_lines` (l.2563-2591). The P0 alert of a
  cancelled transfer's late debit stops once it is booked.
- A transfer held `already_debited` (`transfer_hold_reason`, which reads the debit whether booked or not) stays held:
  the booking does not release it. With the switch off no re-issue exists; 6b-3 decides its fate.
- The line appears in « Traités » with `decision` = its bookings' kinds joined by `+` (l.2468). The labels (6b-2b,
  `lib/payments/debits.ts` `DECISION_LABEL`):
  - `payout`: « Débit d'un reversement »;
  - `sweep`: « Débit de la quote-part du cabinet »;
  - `unplanned_payout`: « Virement hors reversement »;
  - `unplanned_sweep`: « Virement au compte propre »;
  - `payout_returned`: « Reversement revenu »;
  - `sweep_returned`: « Quote-part revenue »;
  - `unplanned_payout_returned`: « Virement hors reversement revenu »;
  - `unplanned_sweep_returned`: « Virement au compte propre revenu »;
  - `fee`: « Frais bancaires ».

---

## 4. 6b-2c — pages: migration `20261117110000_transfer_line_pages.sql`

### 4.1 Mis-booking guards (with the screen that replaces them)
- **`public.link_debit`** (20261111090000 l.3290):
  - `fee` and `explained` are refused `payout_candidate` on a debit of class N, O or E∅ that has a rule-3b candidate
    (§3.4.4);
  - **[critic F9]** the refund link on such a line is refused `payout_candidate` when a rule-3b candidate other than
    that refund exists;
  - all three are refused `client_payout_line` on a debit whose counterparty is a client's confirmed payout IBAN;
  - `explained` is refused `own_transfer_out_line` on a `transfer_out` debit to our own IBAN (S14: money from client
    funds to our account is booked, never explained; I9).

  Labels (**[critic L8]** the first no longer promises a debit that may never come):
  - `payout_candidate`: « Cette ligne a le montant d'un virement du cabinet en cours (reversement, quote-part ou
    remboursement) et ne porte pas sa référence : comptabilisez-la comme son débit si c'est lui ; sinon, demandez le
    détail à la banque. »
  - `client_payout_line`: « Ce débit va vers un compte de reversement d'un client : il se comptabilise comme
    « Virement hors reversement » (ou comme le débit de son reversement en cours). »
  - `own_transfer_out_line`: « Un virement vers notre compte propre se comptabilise (« Virement au compte propre »),
    il ne se classe pas sans comptabiliser. »
- **`public.debit_queue`** (20261116090000 l.2336, same signature; **[critic CSO-4]**). Each row gets a cheap
  **`bookable_as`**, computed by key with no search:
  - `e` (our id), `b` (our lot), `n` (a rule-3b candidate key, a client's payout IBAN or our own IBAN), `u` (stored
    details), or null.

  The page reads `transfer_line_options` only when ops open that line's sheet. « Frais » leaves out the lines with `n`.
  « À classer » lists them with `review_reason` `payout_amount_match` (candidates: the transfers) or
  `client_payout_iban` (the client). **[critic2] CSO2-13** They are found from the lines, never from the transfers:
  for each unbooked reference-less debit of the queue (bounded by the queue's own page), one probe of
  `bank_transfer_filed_amount_idx` on (account, amount), then the payee IBAN and execution date by key — the same
  probe as rule 3b's (§3.4.4). The draft keyed from the account's transfers to its lines by date range, as
  `transfer_debit_may_be_seen` does for one in-flight transfer; for a returned payout of a year ago that range is
  every line of the account since. Labels:
  - `payout_amount_match`: « Débit sans notre référence du montant d'un virement du cabinet en cours (ou annulé que la
    banque a pu exécuter) : s'il s'agit de ce virement, comptabilisez-le comme son débit. »
  - `client_payout_iban`: « Débit vers le compte de reversement d'un client, sans référence du cabinet : virement hors
    reversement (ou débit d'un reversement en cours sans sa référence). »

### 4.2 [critic L8] The end of a suppression
`private.transfer_debit_may_be_seen` (redefined from 20261116090000 l.3440) suppresses an in-flight payout's R124-6
breach row while an unbooked, unlinked line could be its debit. Its own header gives the exit: « classified as something
else, the next nightly check writes it ». 6b-2c removes that exit for a reference-less line of an in-flight amount
(§4.1). Some lines never had one, or have no booking either:
- our batch and RMT lines (`own_transfer_line`);
- `line_ambiguous` and `batch_ambiguous` lines;
- an unsplit entry's residue;
- S08b.

Each would suppress the breach rows of every payout it may be, forever. The fix:
- **[critic2] ML-7 Which lines are bounded.** The draft bounded every line the helper counts. That includes our RMT
  and batch lines and every reference-less line with a single rule-3b candidate, all of which ops can book. On a
  reference-less feed (class N: a CSV without the end-to-end column) the job books no payout debit at all (it needs
  the end-to-end id or a batch line, l.1328-1333), so every payout not booked by ops within five business days would
  get a permanent breach row although the bank debited it on time. The row is append-only and unique per item, it is
  the servicer's R124-6 record (CPCE-08) and raises the `remittance_deadline_breached` violation at every check
  (20261116090000 l.3663), and it would also block the true row if the debit had in fact been late. Now:
  - a new `private.transfer_line_offers(p_line uuid, p_transfer uuid) returns boolean` (stable, keyed) says whether
    the line offers a booking containing that transfer, by the rules of §3.4 restricted to it: an E line carrying
    its id at its amount or above in its account and currency (with a fee the stored charges allow); an N/O/E∅ line
    of which it is rule 3b's only candidate (and not `run_still_live`); a B line whose unique subset holds it
    (`unique_subset` on the PmtInf's items, ≤ the cap, else no); a U line whose stored details are bookable (§3.4.12)
    and name it. It shares those rules' helpers with `transfer_line_check`, so the two cannot drift; pgTAP checks
    that it is true exactly when the options read has a proposal containing the transfer;
  - a line that **offers** the transfer keeps suppressing without a bound. It raises `bank_line_unbooked` after one
    business day (6b-2c extends that alert to a reference-less debit with a rule-3b candidate: P0 when the candidate's
    latest execution date has passed). Its booking writes the true row at its own date (`bank_booking_post_rows`): a
    breach only if it was late;
  - a line that **does not** offer it (`line_ambiguous`, `batch_ambiguous`, `lot_too_large`, `batch_mixed`, the
    `unsplit_*` refusals, `fee_unexplained`, S08b, a line below the amount) counts only while it is younger than
    **five business days** (Q14's default; its booking date against today, `private.business_days_between`).
  - The helper is called once per overdue (run, latest execution date) by the nightly check (l.3527-3534), so the
    subset runs at most once per such line and night.
- **The breach row.** After that, `private.run_remittance_runs_checks` (redefined from 20261116090000 l.3478) writes the
  in-flight item's breach row with `blocked_reason` `debit_unbooked` (« bloqué : débit possible non comptabilisé »).
  The check `remittance_deadline_breach_blocked_reason_check` += `debit_unbooked`.
- If ops later book that line as the payout's on-time debit (possible only once the bank's detail resolves it), the
  row stays (append-only, unique per item), and its reason says why it was written: the line could not be
  attributed for five business days.
- The alternative (Q14 b): a four-eyes classification « ce débit n'est pas celui de ce reversement », with the bank's
  detail as motif, which the helper then ignores. A « levée » row clearing a breach once such a line is booked on
  time was considered and not chosen: the register would hold a false breach for days, the violation would fire
  meanwhile, and every reader of the breach rows would have to learn to read the clearing.
- Recorded in CPCE-08 and OQ-83.

### 4.3 Hints and texts reworded now that the screen exists
- **SQL hint text.** `private.own_transfer_line_hint` (§2.6) now gives, for every caller:
  - « Cette ligne est un débit ou un retour de nos propres virements (reversement, quote-part du cabinet, lot de notre
    fichier) : elle se comptabilise depuis le relevé, automatiquement à l'import ou par l'équipe dans « Débits et
    retours » (débit d'un reversement, virement hors reversement, virement au compte propre, virement revenu) ;
    **[critic L15]** sinon elle attend le détail de la banque : prévenez le support. Elle ne se rattache pas à un
    paiement et ne se classe pas sans comptabilisation. »

  `private.post_debit_links` (l.2113-2115) and `public.release_own_credit` (l.4636-4638) are copied whole, hint only,
  to call it. `post_bank_bookings` already does (6b-2a). `release_own_credit`: « … sinon par l'équipe dans « Débits et
  retours » (« Virement revenu »), ou il attend le détail de la banque. Il ne devient jamais le paiement d'un débiteur
  ni un approvisionnement. »
- **Web** (`lib/boarding/forms.ts`, `lib/payments/debits.ts`; vitest `debits.test.ts` l.1467, 1502 and
  `transfers.test.ts` l.1243, 1268 follow):
  - `PAYOUT_BOOKED_WHEN`: « automatiquement à l'import quand la ligne porte sa référence RMT ou celle de son lot ;
    sinon l'équipe la comptabilise dans « Débits et retours » (« Débit d'un reversement ») ». `FILE_BOOKED_WHEN` says
    the same for the sweep (« Débit de la quote-part du cabinet »).
  - `own_transfer_line`, `own_credit_own_transfer_line`: « … par l'équipe dans « Débits et retours » …, sinon elle
    attend le détail de la banque ».
  - `OUR_TRANSFER_CREDIT_NOTE`: « Crédit portant la référence de l'un de nos virements (reversement ou quote-part du
    cabinet) : c'est ce virement qui revient, sans que la banque l'ait signalé comme un retour. Comptabilisez-le avec
    « Virement revenu » pour son montant exact (s'il est inférieur, demandez le détail à la banque) ; il ne devient ni
    le paiement d'un débiteur ni un approvisionnement. »
  - `OUR_LOT_CREDIT_NOTE`, `OUR_LOT_FOREIGN_E2E_NOTE`, `OUR_LOT_OWN_CREDIT_NOTE`: « … c'est ce lot, ou des virements de
    ce lot, qui reviennent. « Virement revenu » propose les virements du lot dont les montants font seuls celui de la
    ligne ; sinon, demandez à la banque le détail du retour et prévenez le support. » `OUR_LOT_REFUND_BACK_NOTE` is
    unchanged.
  - `UNSPLIT_OURS_NOTE`: « … son montant est celui de toute l'écriture, rien n'est comptabilisé automatiquement. Si le
    relevé détaille nos virements dans cette écriture et qu'ils en font exactement le montant, « Comptabiliser
    d'après le détail du relevé » les propose ; sinon (le paiement d'un débiteur, des frais, un remboursement ou un
    approvisionnement dans l'écriture, ou un détail incomplet), elle ne peut pas être comptabilisée ici : demandez le
    détail à la banque et prévenez le support. »
  - `DEBIT_REVIEW` (debit words; the credit words follow):
    - `cancelled_transfer_debited`: « … Rien n'est comptabilisé : vérifiez dans la banque, puis comptabilisez-le comme
      « Virement hors reversement » (risque de double paiement). » **[critic2] ML-4** The sentence is conditional on
      the row's run status, which `debit_queue` already joins: when the cancelled transfer's run is still approved or
      sent, « … Rien n'est comptabilisé : le reversement de ce virement est toujours en cours, ce débit est donc son
      paiement ; il ne peut pas encore être comptabilisé. Ne faites pas annuler ce reversement et prévenez le
      support. »
    - `transfer_debited_twice`: « … la banque l'a peut-être exécuté deux fois. Vérifiez avec la banque, puis
      comptabilisez ce second débit comme « Virement hors reversement ». »
    - `batch_partial`: « Lot débité pour un autre montant que ses virements en cours (un virement manque, a été rejeté,
      ou un virement déjà débité l'a été de nouveau) : « Débit d'un lot » le comptabilise si une seule combinaison de
      ses virements fait ce montant ; sinon, demandez le détail à la banque. »
    - `transfer_differs`: « … si la banque a prélevé ses frais sur la même ligne, comptabilisez-la comme « Débit d'un
      reversement » et frais ; sinon, vérifiez dans la banque. »
    - `own_transfer_out`: « Virement émis vers l'un de nos comptes sans ordre de Collectoo : comptabilisez-le comme
      « Virement au compte propre » après vérification dans la banque. »
    - `own_transfer_line` (M2b pass): 6b-2a's wording is kept.
    - **[critic F1]** `unplanned_payout_return` (credit words; **[critic2] CSO2-14** 2a and 2b keep the « prévenez le
      support » wording of §2.6, since « Virement revenu » exists only from 2c): « Retour d'un virement du cabinet
      (reversement ou quote-part) qui a aussi été exécuté hors de son ordre (virement annulé exécuté quand même, ou
      exécuté deux fois) : rien n'est comptabilisé automatiquement. Comptabilisez-le avec « Virement revenu » : c'est
      le retour du virement exécuté hors ordre. » A vitest kills 2a's « prévenez le support » words here;
    - **[critic2] ML-3** `return_debit_pending`: « … Comptabilisez d'abord ce débit (« Virement hors reversement ») ;
      ce retour se comptabilisera ensuite avec « Virement revenu ». »

### 4.4 Reads for the run page, « Virements » and the client space ([critic CSO-9, CSO-6, L6])
- **`public.remittance_run_payout(p_run_id uuid) returns jsonb`**:
  - null unless `run.organization_id = any(private.money_staff_org_ids())`, which excludes a client member, a collector
    and another servicer's staff;
  - returns `{transfers: [{id, status, end_to_end_id, debited_on, returned_on, line_id}], settled_on,
    settlement_minor, commission_minor (Dc), advances_recovered_minor (Da), advances: [{cause, amount_minor,
    open_minor, created_on}], unplanned: [{line_id, kind, amount_minor, on, paid_minor, advance_minor}],
    draft_unplanned: [...]}`;
  - `draft_unplanned` lists, for a draft, the `unplanned_payout` pending items it holds (`draft_run_id` = the run):
    the durable reason its gross changed (CSO-6).
- **`public.transfer_bookings(p_transfer_ids uuid[]) returns table (transfer_id, debited_on, returned_on, debit_line_id,
  return_line_id, unplanned_on)`**: ≤ 500 ids; keyed; only rows whose `bank_transfer.organization_id =
  any(private.money_staff_org_ids())`. Other ids are ignored, with nothing said about them.
- **`public.client_remittance_summary`** (redefined from 20261116090000 l.4416; **[critic L6]**) gains `unplanned_runs:
  [{run_id, executed_on}]`: the client's cancelled runs **[critic2] ML-12** any of whose transfers has an unplanned
  booking, with that booking's date. « Any of its transfers » is the run's chain: `run.transfer_id`, then each
  `replaces_transfer_id`, by key (the same set as `bank_transfer.run_id = run`). After a re-issue `run.transfer_id`
  names x' (`transfer_file_release` l.1712) while the bank may execute the old x; keyed on `run.transfer_id` alone the
  client space kept « Annulé avant la remise de son virement à la banque », which is false. Same rights as today
  (whole-client members). `remittance_run_payout` and `transfer_bookings` read the chain the same way.
- The client space reads `remittance_run.booked_on` with its embed (table grant, RLS rows: no new function).

---

## 5. 6b-2d — « Suivi »: migration `20261117120000_statement_suivi.sql`

`private.remittance_statement_build` (from 20261116090000 l.3988) and `releve-reversement-fr-3`.

**The payload** drops `follow_up` and adds **`previous_payouts`**: the events of the client's **earlier approved runs**
of the currency (**[critic L7]**: `approved_at` not null, so a draft discarded with an RV number is never listed; N > 0)
posted in the window.
- **[critic L17]** The window starts at the `known_at` of the client's previous approved run of the currency (`known_at
  < r.known_at`; −∞ for none), not at its statement, which the documents job draws asynchronously. It ends at this
  run's K (`r.known_at`).
- Time is read per ADR-0012: `ledger_entry.posted_at` and `remittance_run.cancelled_at` against K. The dates shown are
  effective dates.
- One entry per event, ordered by its date then the run number:
  - `debited`: the run's transfer's (or chain's) planned debit booking — `{run_number, amount_minor, end_to_end_id, on:
    debit date}`;
  - `returned`: its return booking — `{…, debited_on, on: return date, repaid: 'here' | 'run' | 'pending', repaid_by}`.
    `here` when this run holds its `payout_returned` item, `run` when a run approved by K holds it (`repaid_by` its
    number), else `pending`;
  - `cancelled`: the run cancelled (`cancelled_at` in the window) — `{…, on}`;
  - `executed_after_cancellation` / `debited_again`: an unplanned booking of one of the run's transfers posted in the
    window (x cancelled / booked or returned) — `{…, unplanned_minor, advance_minor, p_bound, on, here}`. `here` when
    this run holds that entry's −A line. A run with both a `cancelled` and an `executed_after_cancellation` event in
    one window gets the latter only. **[critic2] ML-12** « One of the run's transfers » is any transfer of its chain
    (§4.4), not only `run.transfer_id`: after a re-issue the bank may execute the old x. **[critic2] ML-9**
    `p_bound` is read from the booking (§3.6.5) so the advance clause is worded by what set P;
  - **[critic L4]** `unplanned_returned`: the return of such an unplanned booking — `{…, executed_on, on, owed_minor
    (P), here}`;
  - **[critic L16]** `executed_outside`: an unplanned payout to the client with no transfer (S13, S07) posted in the
    window — `{amount_minor, advance_minor, iban_last4, on, here}`.
- **[critic L4] Nature.** A line of kind `payout_returned` whose reversed remittance is an unplanned one (read by key:
  the reversal's `reverses_entry_id` → a remittance that is not its transfer's `entry_id`) carries `unplanned: true`.
  Its nature is « Virement exécuté hors reversement revenu », not « Virement revenu impayé — reversé à nouveau ».
- **[critic L9] Late cause.** A line whose item has an `unplanned_paid_item` row of an unreversed booking takes
  `late_cause` `paid_by_unplanned`, with that booking's date: « versé le jj/mm/aaaa par un virement exécuté hors
  reversement ». The date tells whether it was in time (Q15's default keeps the item's own clock).
  - **[critic2] ML-9** As the rest of « Suivi » (L17), « unreversed » is read as of K: the booking's entry is posted
    at or before `r.known_at` and has no reversal posted at or before it (by `ledger_entry_reversed_once_uq`, then
    the reversal's `posted_at`).
  - The payload carries the attributed amount (`paid_by_unplanned_minor`, Σ of the item's rows of such bookings). When
    it covers the line, « versé le … par un virement exécuté hors reversement »; when it covers part of it, « dont
    1 200,00 € versés le … par un virement exécuté hors reversement ». The draft said the whole line was paid so even
    when the attribution covered part of it.

**Renderer** (`remittance/statement.py`): `_previous_payouts` in place of `_follow_up`; `TEMPLATE_VERSION =
"releve-reversement-fr-3"`; `TEMPLATE_VERSIONS` = fr-3 only, since stored statements are never re-rendered; a payload
with `follow_up` is refused `payload_version`; `NATURE` += the unplanned return; `LATE_CAUSE` += `paid_by_unplanned`.
French:
- `debited`: « Reversement RV-… : virement de 1 640,00 € (référence RMT…) débité de notre compte dédié le
  03/11/2026. »
- `returned`:
  - `here`: « Reversement RV-… : virement de 1 640,00 € débité le 03/11/2026, revenu impayé le 05/11/2026 ; son montant
    figure dans le présent reversement (« Virement revenu impayé — reversé à nouveau »). »
  - `run`: « … ; reversé à nouveau par le reversement RV-2026-000003. »
  - `pending`: « … ; son montant vous sera reversé par un prochain reversement. »
- `cancelled`: « Reversement RV-… annulé le 03/11/2026, avant que son virement soit remis à la banque. » This is true
  while the cancellation after download is off: no file of a cancelled run's payout was ever closed after download
  (S01's real cases arrive with 6b-3, which rewords it). M2c-5's « virement annulé avant son exécution » is dropped.
- `executed_after_cancellation`: « Reversement RV-… annulé le 03/11/2026 : la banque a néanmoins exécuté son virement
  de 1 640,00 € le 05/11/2026 ; ce montant, que vous avez reçu, figure dans le présent reversement (« Virement exécuté
  hors reversement ») ». **[critic F17, L16]** When `advance_minor` > 0 it adds « , et « Avance du cabinet » pour la
  part qui n'a pas pu être déduite de vos sommes en attente (440,00 €) », then by `p_bound` (**[critic2] ML-9**: P
  is also capped by the queue and by earlier attributions, so the draft's « la part qui dépassait les sommes de ce
  reversement encore à vous reverser » was false when those caps bound):
  - `items` or `none`: « : elle dépassait ce qui restait à vous reverser des sommes de ce reversement »;
  - `queue`: « : vos sommes en attente à cette date ne permettaient pas d'en déduire davantage »;
  - `amount`: no advance, no clause.

  It ends « . » (not `here`: « … ; il sera pris en compte dans un prochain reversement. »).
- `debited_again` (**[critic L13]**): « Reversement RV-… : la banque a exécuté son virement une seconde fois le
  05/11/2026 (1 640,00 €) ; ce second virement, que vous avez reçu, figure dans le présent reversement (« Virement
  exécuté hors reversement » » + (advance > 0: « , et « Avance du cabinet » pour ce second virement (1 640,00 €) ») +
  « ). » (not `here`: as above).
- `unplanned_returned`: « Le virement de 1 640,00 € exécuté hors reversement le 05/11/2026 est revenu le 10/11/2026 :
  l'avance du cabinet correspondante est annulée » + (P > 0: « et 1 200,00 € vous sont de nouveau dus ») + (`here`:
  « ; voir « Virement exécuté hors reversement revenu » dans le présent reversement ») + « . »
- `executed_outside`: « Virement de 1 640,00 € vers votre compte FR76 •••• 1234 le 05/11/2026, exécuté hors de tout
  reversement : il figure dans le présent reversement (« Virement exécuté hors reversement » et « Avance du cabinet ») »
  (not `here`: « … ; il sera pris en compte dans un prochain reversement »).
- none: « Rien à signaler sur vos reversements précédents depuis le relevé RV-… (encaissements connus au jj/mm/aaaa
  hh:mm). » A first statement says « Aucun reversement précédent à suivre. »

What else changes:
- The CSV is unchanged (lines only); its `nature` column takes the new nature.
- The renderer version is unchanged; the template version changes. The golden PDF is regenerated.
- Read cost: the client's runs by `remittance_run_client_idx`, their transfers by run, bookings by
  `bank_line_booking_transfer_idx` (**[critic F14]** it exists), entries by key, `unplanned_paid_item` by
  `ledger_entry_id`.

---

## 6. Worker

- **6b-2a**:
  - `payments/camt053.py`: the unsplit details, the detail count and `NbOfTxs`, the charges (§2.2);
  - **[critic2] CSO2-9** staging is `jobs/payments.stage()` over `payments/statement.STAGE_COLUMNS` (the draft named
    a `jobs/statements` that does not exist): the new columns, `Jsonb([...])` for the details; `StatementLine` gains
    `unsplit_details: tuple[UnsplitDetail, ...] | None` (a frozen, slotted dataclass), `unsplit_detail_count`,
    `unsplit_batch_count`, `charges_minor`;
  - `payments/debits.py`: `TransferFact.unplanned_open`, **[critic2] ML-3** `TransferFact.debit_pending`, and the
    `_transfer_return` rules (§2.3);
  - `jobs/debits.py`: the facts loaded;
  - `P0_REVIEWS` += `TRANSFER_UNKNOWN`;
  - `unique_subset(amounts, target)` (the SQL twin's bounds, **[critic2] CSO2-2** work bound and visiting order, pure);
  - `synth/camt053.py` + `cli.py`:
    - `--unsplit-details` (entries kept unsplit, with details carrying amounts or not; **[critic2] ML-5** with or
      without a detail not ours, netting to zero or not);
    - `--debit-charge MINOR` (each individual debit booked for N + charge on one entry, the charge in its `Chrgs`).
      **[critic2] ML-6, CSO2-1** By default it writes the ISO shape: the detail's `AmtDtls/TxAmt/Amt` = N and
      `Ntry/Amt` = N + charge, which the parser keeps unsplit (class U); `--debit-charge-no-detail-amount` writes the
      detail without an amount (class E);
    - `--unflagged-returns` (returns written without a return code or reversal indicator, from the payee's IBAN);
    - `--csv` with the end-to-end column dropped (`expected_csv(bank_ids=False)` exists);
    - round-trip tests with the parser.
- **6b-2b**: `jobs/remittances.py` `_held_to`, the change of §3.12, **[critic2] ML-2** its third branch (the re-owed
  item of an unplanned remittance whose items were frozen) included (parity test with `private.pending_item_deadlines`).
- **6b-2d**: `remittance/statement.py`, `statement_pdf.py`: fr-3 (§5).

---

## 7. Web (`apps/web/src`, `lib/database.types.ts` regenerated in each slice)

### 7.1 6b-2a
- Labels:
  - review reasons `unplanned_payout_return` and **[critic2] ML-3** `return_debit_pending`, with **[critic2]
    CSO2-14** §2.6's « prévenez le support » wording (no « Virement revenu » before 2c);
  - `sweep_exceeds_share` (§2.4), and **[critic2] CSO2-4** the sweep-only `file_blocked` text;
  - checks `own_transfer_payment` (P0): « Paiement créé à partir d'un de nos virements revenus (il porte la référence
    d'un reversement, d'une quote-part du cabinet ou d'un lot de nos fichiers) : ces sommes ne sont reversées à
    personne tant qu'il n'est pas traité. Ne l'affectez pas, ne le remboursez pas, prévenez le support. »;
  - checks `transfer_unknown` (P0, **[critic L14]** both directions): « Ligne (débit ou crédit) portant une référence de
    virement du cabinet (RMT, SWP) ou un lot que Collectoo ne connaît pas : vérifiez dans la banque. »;
  - checks `double_payout_open`: « Avance du cabinet après un virement exécuté hors reversement : à récupérer auprès
    du client — ce recouvrement n'est pas encore géré dans Collectoo. ».
- The S23 texts (§2.6).

### 7.2 6b-2b
`lib/payments/transfer-lines.ts` (new, pure): the refusal labels of §3.10 and `transferLineErrorCode` (55P03 → `busy`,
57014 → `timeout`; **[critic2] CSO2-6** the re-raised `allocation_busy` → its own label), and `DECISION_LABEL` += the new
kinds.

### 7.3 6b-2c — « Débits et retours » (`app/backoffice/encaissements/debits/`)
- **`lib/payments/transfer-lines.ts`** grows:
  - parsing of `transfer_line_options` / `transfer_line_preview`;
  - the action labels and the effect sentences below;
  - `offersTransferLineBooking(row)`, which reads the row's `bookable_as` (**[critic CSO-4]**).
- **`actions.ts`**:
  - `transferLineOptions(lineId)`: rpc `transfer_line_options`, read when a sheet opens, never while the list renders;
  - `previewTransferLine(formData)`: rpc `transfer_line_preview`;
  - `bookTransferLine(formData)`: rpc `book_transfer_line`, with a UUID key, the parts as the preview returned them,
    `expected_text` and the motif;
  - authorisation stays in SQL; `revalidatePath` of the page, the run pages and « Virements ». A double submit with the
    same key returns the first result (§3.2 step 2).
- **`page.tsx` `LineActions`**: a line whose `bookable_as` is set shows « Comptabiliser… ». The sheet loads the options
  and shows one button per proposal; on a U line the button is « Comptabiliser d'après le détail du relevé ». The
  options are never read per row (today's `debit_link_options` `Promise.all`, l.166-180, is not extended).
- Sheets (`debit-actions.tsx`):
  - **« Débit d'un reversement »** / **« Débit d'un lot de reversements »**:
    - intro: « La banque a débité ce virement du cabinet : la ligne est comptabilisée comme son débit, comme l'import le
      fait quand la ligne porte sa référence. »;
    - members table (lots): « Reversement », « Client », « Référence », « Montant », « Dans cette ligne » (« débit » /
      « second débit, hors reversement » / « non débité par cette ligne »);
    - effects per payout: « RV-… (MARTIN SAS) : 1 640,00 € débités le 05/11/2026 ; ses factures sont réglées par
      compensation (360,00 €) ; le reversement passe à « Débité ». »;
    - late: « Ce débit est postérieur à la date limite d'exécution du 30/10/2026 : le dépassement du délai est
      enregistré. »;
    - fee (class E, and U in the S08 shape): « Frais bancaires de 1,20 € prélevés sur la même ligne, à la charge du
      cabinet. » + **[critic2] ML-10** « (frais indiqués par le relevé) » when they equal the stored charges, else « Le
      relevé n'indique pas de frais pour cette ligne : l'écart n'est pas justifié par le relevé. Vérifiez dans la
      banque avant de comptabiliser. »;
    - **[critic2] CSO2-4** when `supersedes_file` is set (a cover or fee lowers the share under a generated file's
      sweep): « Le fichier FT-… pas encore téléchargé sera remplacé à son téléchargement : sa quote-part dépasserait
      alors ce qui revient au cabinet. »;
    - classes N/O/E∅: « Cette ligne ne porte pas notre référence : seul ce virement du cabinet (en cours, ou annulé que
      la banque a pu exécuter) a ce montant vers ce compte. Vérifiez dans la banque avant de comptabiliser. »;
    - button « Comptabiliser le débit ».
  - **« Virement hors reversement »**:
    - intro: « La banque a exécuté un virement vers MARTIN SAS hors de tout reversement en cours (virement annulé
      exécuté quand même, second débit d'un virement, ou virement saisi à la banque). Il est comptabilisé tel quel : le
      client a reçu cet argent. »;
    - effects, by P (**[critic L13]** they word the mechanism, not a qualification):
      - P = A: « 1 640,00 € déjà reçus par MARTIN SAS seront déduits de son prochain reversement (sommes du reversement
        RV-… annulé — ou du virement revenu — encore à reverser) ; avance du cabinet : 0,00 €. »;
      - 0 < P < A: « 1 200,00 € déjà reçus par MARTIN SAS seront déduits de son prochain reversement (…) ; avance du
        cabinet de 440,00 € pour le reste, à récupérer selon son mandat — ce recouvrement n'est pas encore géré dans
        Collectoo. » **[critic2] ML-9** « pour le reste » is followed by why, from `p_bound`: `items` « (le reste
        dépasse ce qui reste dû au client sur ces sommes) », `queue` « (les sommes en attente du client ne permettent
        pas d'en déduire davantage) »;
      - P = 0: « Rien n'est déduit du prochain reversement de MARTIN SAS ; avance du cabinet de 1 640,00 € : ce virement
        n'est rattaché à aucune somme en attente de ce client, à récupérer selon son mandat — ce recouvrement n'est pas
        encore géré dans Collectoo. »;
    - draft: « Le brouillon RV-… sera recalculé ; sa validation en cours, s'il y en a une, est interrompue. »;
    - **[critic F6]** `client_run_cancellable`: the refusal with the run's number and a link to it;
    - **[critic2] ML-4** `run_still_live`: the refusal with the run's number; no button;
    - **[critic2] CSO2-4** the « fichier remplacé » sentence above when `supersedes_file` is set (an advance A − P > 0
      lowers the share);
    - button « Comptabiliser le virement ».
  - **« Virement au compte propre »**:
    - intro: « Virement du compte dédié vers notre compte propre FR76 •••• 1234 sans ordre de Collectoo (ou exécuté
      après son annulation) : comptabilisé comme quote-part du cabinet virée au compte propre. »;
    - « La quote-part du cabinet en attente sur le compte dédié baisse de 500,00 €. »;
    - when it goes below zero: « Elle devient négative (−120,00 €) : le cabinet doit cette somme au compte dédié ;
      demandez un approvisionnement depuis le compte propre. »;
    - **[critic2] CSO2-4** only when `supersedes_file` is set (the draft said it whenever a generated file held a
      sweep, even when the share still covered it): « Le fichier FT-… pas encore téléchargé sera remplacé à son
      téléchargement : sa quote-part dépasserait alors ce qui revient au cabinet. »
  - **« Virement revenu »**:
    - intro: « La banque du bénéficiaire a renvoyé ce virement du cabinet : il est comptabilisé comme revenu, comme
      l'import le fait quand la banque le signale comme un retour. »;
    - payout: « RV-… : 1 640,00 € de nouveau dus à MARTIN SAS, proposés dans un prochain reversement avec la date
      limite de leurs encaissements ; son compte de reversement FR76 •••• 1234 est bloqué jusqu'à son remplacement ou
      sa reconfirmation. »;
    - sweep: « La quote-part de 500,00 € revient sur le compte dédié : elle sera virée de nouveau au compte propre. »;
    - unplanned (**[critic L3]** the block is said whenever it applies): « Le virement hors reversement du 05/11/2026
      (1 640,00 €) revient : l'avance du cabinet de 440,00 € est annulée et 1 200,00 € sont de nouveau dus à MARTIN
      SAS ; son compte de reversement FR76 •••• 1234 est bloqué jusqu'à son remplacement ou sa reconfirmation. »
      (P = 0: « … l'avance du cabinet de 1 640,00 € est annulée ; rien n'est de nouveau dû … »);
    - fee (a flagged return only): « Frais de la banque déduits du retour : 1,20 €, à la charge du cabinet. » (+ the
      ML-10 sentence as for a debit);
    - **[critic2] ML-11** a flagged return without our reference (N/O/E∅): « La banque signale ce crédit comme un
      retour, sans notre référence, depuis le compte vers lequel le virement hors reversement du 05/11/2026
      (1 640,00 €) est parti : il est comptabilisé comme son retour. Vérifiez dans la banque avant de comptabiliser. »;
    - **[critic2] ML-3** `debit_pending`: the refusal and a link to the pending debit's line;
    - button « Comptabiliser le retour ».
  - **« Comptabiliser d'après le détail du relevé »** (U, **[critic F8]**):
    - intro: « La banque a regroupé plusieurs opérations dans cette écriture. Le relevé détaille nos virements qu'elle
      contient : s'ils en font exactement le montant, ils sont comptabilisés chacun (débit ou retour). »;
    - the stored details, read-only, with their effects;
    - a refusal shown with its label;
    - « Vérifier » (preview), then « Comptabiliser ».
  - Every sheet: « Motif (ce que montre le relevé ou la banque) », required; the preview's effects are re-read on open; a
    refusal is shown with its label.
- The P0 badge (`P0_DEBIT_REVIEWS`) is unchanged: it already holds `transfer_unknown`.

### 7.4 6b-2c — other pages
- **Run page** (`reversements/[id]/page.tsx`, reads `remittance_run_payout`):
  - « Débité de notre compte le 03/11/2026 »;
  - « Commission réglée par compensation le 03/11/2026 : 360,00 € » (D = Dc); when Da > 0, « Factures et avances
    réglées par compensation le … : … »;
  - overrun advance: « Avance du cabinet de 50,00 € au débit : le virement dépassait ce qui restait dû au client (une
    imputation annulée après la validation) ; à récupérer selon son mandat — ce recouvrement n'est pas encore géré dans
    Collectoo. »;
  - returned banner: « Virement revenu impayé le 05/11/2026 : 1 640,00 € de nouveau dus au client, proposés dans un
    prochain reversement ; son compte de reversement est bloqué jusqu'à son remplacement ou sa reconfirmation. » (+
    « Reversé à nouveau par RV-… » once booked);
  - unplanned: « La banque a exécuté le virement de ce reversement une seconde fois le … (…) : comptabilisé hors
    reversement, avance du cabinet de … » / « … exécuté après son annulation le … »;
  - **[critic CSO-6]** a draft holding unplanned items, from `draft_unplanned`: « Ce brouillon déduit 1 640,00 € déjà
    reçus par le client : virement exécuté hors reversement le 05/11/2026 (relevé du …). » The draft shows
    « Préparation en cours » while it is re-prepared, never « Préparation échouée ».
- **« Virements »** list and file page (`lib/remittance/transfers.ts`, reads `transfer_bookings`):
  - « Débité le jj/mm/aaaa », « Revenu impayé le jj/mm/aaaa », « Annulé — exécuté par la banque le jj/mm/aaaa, hors
    reversement »;
  - the sweep's status alike;
  - the `servicer_funds_unswept` banner on the overview: « La quote-part du cabinet attend depuis plus de deux jours
    ouvrés sur le compte dédié sans virement au compte propre. »
- **Client space** (`lib/remittance/documents.ts`, **[critic L6]**): `runStatusText(status, net, bookedOn,
  unplannedOn)`.
  - « Virement débité de notre compte le 03/11/2026 »;
  - cancelled: « Annulé avant la remise de son virement à la banque » (switch off; 6b-3 rewords it);
  - cancelled with an unplanned booking (`unplanned_runs`, **[critic2] ML-12** keyed on any transfer of the run's
    chain): « Annulé — la banque a néanmoins exécuté son virement le 05/11/2026 (voir le relevé suivant) »;
  - the returned texts (L2's) are unchanged.

### 7.5 6b-2c — screenshots (mobile + desktop, `docs/screenshots/`)
New:
- `m2c-debits-reversement`: « Débit d'un lot de reversements » on a partial batch line;
- `m2c-virement-hors-reversement`: the P = 0 and P = A sheets;
- `m2c-virement-revenu`;
- `m2c-debits-detail-releve`: an unsplit line booked from the statement's detail.

Retaken:
- `m2c-reversement-debite` (dates, commission line, the draft's unplanned note);
- `m2c-virement-debite` (dates);
- `m2c-client-reversements` (debit date, the cancelled-run text);
- `m2-checks` (new alerts).

---

## 8. Tests (written first; each slice red before its code)

### 8.1 pgTAP
Fixtures are copied from 035's: servicer aa, accounts cf/c0, clients a1–a9, and the `pg_temp` helpers `run`, `gen`,
`download`, `stmt`, `as_user`. `run_payment_checks` is asserted free of violations after each group: I8′, I12, I13, I14,
I19, I20, `bank_line_booked`.

**`036_transfer_line_foundations` (6b-2a):**
- **A. Unsplit details at import** (F8):
  - the round-5 netted credit and d03, staged with details, are stored in the file's order with directions and amounts;
  - a count mismatch, an id not ours, a bad amount, or details without `unsplit_ours` → `line_invalid`;
  - a re-import of the same file leaves a stored line untouched.
  - **[critic2] ML-5** the detail count and `NbOfTxs` are stored (an entry with our detail and two others: count 3,
    `unsplit_ours` 1); a detail count below `unsplit_ours` → `line_invalid`;
  - **[critic2] ML-6, ML-10** `charges_minor` stored for a one-line entry with `Chrgs`, null without; a non-positive
    one → `line_invalid`;
  - **[critic2] CSO2-8** re-imports: the same details → skipped; different details (another id, direction or
    amount), detail count or charges for a known line → `entry_detail_differs`; a stored null with staged details →
    skipped, and the line is not filled.
- **B. The job's return rule** (F1, L5). **[critic2] CSO2-12** An unplanned booking of booked x is seeded as postgres
  by a `pg_temp` helper posting what 6b-2b posts for S03 (P = 0): the remittance entry, the booking, the −A pending
  row, **and the `double_payout` advance** (its entry, its `client_advance` row, the +(A − P) pending row through the
  trigger). Without the advance, 4670[c] goes into debit: LG008 at `ledger_check_now`, and I13/I14 flagged by the
  group's own `run_payment_checks` assertion. 037 D checks that the command's rows for S03 equal the helper's.
  - A flagged return of x → reviewed `unplanned_payout_return`; nothing booked; x stays booked; the queue unchanged.
  - The seeded unplanned entry reversed → the next return books `payout_returned(x)` as today.
  - A cancelled x with an open unplanned booking → `unplanned_payout_return`, not `return_differs`.
  - Mutant « open-unplanned check removed » → the return books, and the client's queue shows the amount owed again
    (the next run would pay twice).
  - **[critic2] ML-3** x booked; a second debit D2 of x imported and reviewed `transfer_debited_twice`, left unbooked;
    then a flagged return of x → reviewed `return_debit_pending`; nothing booked; x stays booked; no `payout_returned`
    item queued; the payout account stays active. A cancelled x with its late debit unbooked, then its return → the
    same. Mutant « pending-debit fact removed » → the return books `payout_returned(x)` and queues +N.
- **C. The sweep at first download** (CSO-2, F10):
  - generate with sweep S, then a `payout_overrun` cover posted as the job posts it, lowering the share below S → the
    download refuses `file_blocked` with `sweep_exceeds_share`, the file is superseded, the sweep cancelled and the
    payouts `ordered`; regenerating gives the share;
  - **[critic2] CSO2-4** after that refusal: the payouts are `ordered` with their `requested_execution_date` unchanged,
    their runs still `approved`, and a same-day regeneration before the account's cut-off needs no late
    reason;
  - the same with a bank fee posted in between;
  - a share still ≥ S → served;
  - a file in status `pending` → `not_ready` (CSO-10);
  - mutant « re-check removed » → served with S > share.
- **D. `unique_subset`**: equal amounts → null; the complement side; past each bound → null; a unique subset → its
  indexes. **[critic2] CSO2-2** The worst saturating input (500 amounts of 5–90 €, t' = 8 000) trips the work bound
  and returns null in < 0.5 s; more amounts than the cap → null at once.
- **[critic2] CSO2-11 Privileges**: `has_function_privilege` false for `anon` and `authenticated` on
  `private.unique_subset`, `private.transfer_line_lot_cap` and `private.own_transfer_line_hint`.
- **E. Alerts** (L10, L14):
  - `transfer_unknown` P0 on a debit and on a credit;
  - `double_payout_open` on a seeded `double_payout` advance, gone once its entry is reversed;
  - `bank_line_unbooked`'s new members after one business day, not before;
  - `own_transfer_payment` P0 on a payment made of an RMT credit before round 4 (seeded), not before one business day,
    gone once the payment is no longer unassigned;
  - the M2b pass reviews a04 `own_transfer_line`.
- **F. Texts**: the hints of `assign_payment` and `resolve_duplicate` say « ne peut pas encore » and promise no screen.
- **[critic2] CSO2-5 CI**: the migration-order step is exercised once on a scratch branch adding a migration dated
  before `origin/main`'s latest (it fails), and passes on the slice's own branch.

**`037_transfer_line_ops` (6b-2b; 6b-2c appends group P):**
- **A. Roles, request, tenants**:
  - a collector, a read-only member, a client admin, another servicer's admin, and an admin at aal1 → 42501;
    preview/options → null;
  - an empty motif → `a reason is required`; each `bad_request` case of §3.4.0 (501 parts included); a null
    `p_expected_text`;
  - **[critic CSO-5]** A's line with B's `transfer_id`, `client_id` and `returns_line_id` → `transfer_unknown` /
    `client_unknown`, with a `why` identical to an absent id's in the preview and the command;
  - options' candidates and members never list B's rows;
  - `client_ambiguous` only for two clients of the same servicer;
  - **[critic2] CSO2-10** a U line of A whose stored detail carries B's RMT id, and one whose detail carries an
    RMT-shaped id naming nothing: identical options and preview answers (`unsplit_not_bookable`, same `why`), nothing
    of B in the JSON, and no lock on B's rows (`pg_locks` from a second connection);
  - **[critic2] CSO2-11** `private.unplanned_paid_item`: `has_table_privilege` false for `anon`, `authenticated` and
    `service_role`; an insert as `service_role` is refused.
- **B. Line state and replay**:
  - `held_duplicate`, `already_booked` (a line the job booked), `already_linked`, `line_is_payment`;
  - the same key and request → the same result, nothing posted twice; the same key with another request →
    command_replay's refusal; a new key on the booked line → `already_booked`;
  - **[critic F16]** a client part on an RFD `refund_out` line → `not_a_transfer_line`.
- **C. Planned parts**:
  - S08 `payout + fee` on its E line: remit:<t> N, settle:<run>, fee:<line> F, seqs 1–2, run and transfer booked,
    signed completeness. S08 without the fee part and S08b → `amount_differs`;
  - **[critic2] ML-6, CSO2-1** S08 in the ISO shape (U: one detail, ours, `TxAmt` N, entry N + F, `Chrgs` F) → the
    same parts and entries as on E; `Chrgs` absent → `unsplit_detail_missing`; `Chrgs` ≠ F → `amount_differs`. Mutant:
    the S08-on-U rule removed (the line is `parts_do_not_add_up`);
  - **[critic2] ML-10** E line with `charges_minor` and a fee part of another amount → `amount_differs`; E line
    without charges, of 3 280 for t (1 640) → the fee part of 1 640 → `fee_unexplained` and no proposal; the same with
    the excess equal to another payout of the account (in flight or booked) → `fee_unexplained`; an excess of 1,20 €
    without charges → booked, the sheet's « pas justifié par le relevé » flag set. Mutant: the check removed;
  - **[critic L2, F7]** `fee_not_allowed` on B, N, O, E∅, U and on own/client credits. Each critic scenario is refused:
    `unplanned_payout(c)` 40 + fee 1 600; `payout_returned(t)` 1 640 + fee 1 590 on a 50 € client credit. Mutant: the
    fee rule widened back;
  - S09: three members, one left out, the only subset → two payouts, the third `in_file` and its run `sent`. Two members
    of equal amount → `batch_ambiguous`; a member of another PmtInf → `not_its_line`; 501 items → `lot_too_large`;
  - S12, rule 3b:
    - one payout candidate → booked;
    - **[critic F9]** plus a refund in flight of the same amount and payee → `line_ambiguous`;
    - **[critic F12]** plus a cancelled payout of the account (switch on) → `line_ambiguous`;
    - **[critic2] ML-4** a re-issue x' in flight and its cancelled original x, same amount and IBAN (switch on in a
      subtransaction) → `line_ambiguous` (the draft gave `not_its_line` for x' and the « only candidate » x); x alone
      as the candidate while its run is still sent → `run_still_live`; another payee's IBAN → `not_its_line`; dated
      before execution → `not_its_line`;
    - **[critic2] ML-8** CSV: x (1 640) returned (MS03), the client's IBAN reconfirmed, R2 drafted for x's return item
      alone, t2 (1 640, same IBAN) downloaded; t2's reference-less debit → `payout(t2)`, not `line_ambiguous`. A later
      second line of 1 640 → x as (iii), P from x's return item as it then stands (0: booked in R2), advance 1 640.
      Mutant: the (iii) exclusion removed;
    - **[critic L12]** class O with the client's IBAN and one candidate → `payout(t)`; class O without an IBAN →
      `not_its_line`;
  - a late ops payout writes its breach rows, an on-time one none; `transfer_cancelled`, `already_debited`,
    `not_handed_out`, `run_not_in_flight`, `transfer_differs`;
  - **[critic CSO-1]** as `admin@martin.test`, the ops-booked payout's `remittance` entry reason is null (the job's); as
    `admin@lilas.test`, no row; the motif only in `bank_line_booking`;
  - **parity**: an ops `payout` part on a plain RMT line gives the same entries, lines, reasons and states as the job's
    booking of a twin line.
- **D. Unplanned payouts (Q4)**:
  - S01 with A = P (switch on: its file handed out, then the run cancelled; its items re-reserved by c's draft):
    remittance A from x, pending −A, no advance, queue net −A, `unplanned_paid_item` rows = the items. The draft is
    requeued (job prepare, new token, **`last_failure` null**, `requested_execution_date` and `late_reason` null, **its
    draft rows still there until `remittance_prepare_begin`**, CSO-6/CSO-7). The next run is then prepared and
    **approved** (no `items_changed`, no `balance_changed`), its gross = before − A;
  - A > P (part of the items frozen in a booked run): advance A − P, 4112[c] +(A − P), the next run approved;
  - S03, P = 0: advance A, queue net 0;
  - **[critic F2]** S03r: x booked, returned, then re-executed → P = A (its return item), no advance, c's draft
    requeued and the next run approved with the item netted. Mutant « P = 0 for a returned x » → the next run pays
    twice;
  - **[critic F3]** an item reversed after its run's cancellation → P = 0, advance A. Mutant « pool not net of
    reversals »;
  - **[critic2] ML-1** a pool holding an `allocation_reversal` / `payout_overrun`-advance pair (r −300, v +300) and a
    positive item a (+1 000) reversed after the cancellation, with an unrelated n +2 000 queued → P = 0, advance
    1 000, n still fully owed. Mutant « net floored per item » (P = 300). A pool holding an earlier unplanned −A row
    and its advance → those rows excluded, the earlier attributions counted once;
  - **[critic F4, L1]** two cancelled runs sharing an item, both files executed late → P₁ = 1 000, P₂ = 0, advance
    1 000. Mutant « earlier per run only »;
  - **[critic F5]** an in-flight run plus a negative pending item → P = the queue's net (200), advance 800 of cause
    `double_payout`, then no `payout_overrun` at the in-flight run's booking. Mutant « owed cap »;
  - **[critic F6]** the items frozen in an approved run whose payout is `ordered` → `client_run_cancellable`; after an
    admin cancels it → P = A. Mutant « rule removed » → that run pays twice;
  - **[critic2] ML-4** (switch on) x cancelled alone on evidence while R1 stays sent, then x's late RMT debit →
    `run_still_live` (and `cancel_remittance_run` on R1 refuses `transfer_already_debited`); the same after a file
    cancellation re-issued x as x' → `run_still_live`; after R1 is cancelled first → booked with P. Mutant: the run
    status rule removed (P = 0, advance A for the run's one real payout);
  - **[critic2] CSO2-12** S03: the command's rows (entry types, keys, pending kinds, the advance's cause) equal 036 B's
    seed helper's;
  - **[critic F12]** class N, the late execution of a cancelled x with a downloaded file → `unplanned_payout(x)` with
    P; the client part → `cancelled_payout_matches`;
  - **[critic F13, L12]** the client part on class O and E∅ with an in-flight payout of c of that amount to that IBAN →
    `payout_in_flight_matches`; with an `ordered` one → `payout_not_handed_out_matches`;
  - two unplanned parts of one cancelled run in one call (Σ P ≤ the items' net); a later second unplanned booking on
    the same run counts the first's items (P₂ = 0);
  - a draft queued for approval: the old token's approval returns `skipped`; `not_cancelled_nor_booked` for `ordered`
    and `in_file` x;
  - S13: c's active and retired IBANs accepted (P = 0, advance A, source the line), an unknown IBAN
    `client_iban_mismatch`, an IBAN of two clients `client_ambiguous`;
  - S07: an unknown RMT-shaped id to c's IBAN booked as c's when nothing of ours matches;
  - S04: all members booked → unplanned × n with their advances. S05: live + re-executed → payout + unplanned. S02
    (switch on): live + cancelled member → payout + unplanned, P from the cancelled member's run;
  - in each case: P ≤ A, P ≤ the queue's net, P ≤ the items' net (the Hypothesis invariant's SQL twin, §8.2).
- **E. Sweeps**:
  - S14 own IBAN, no sweep in flight → `servicer_sweep` to that own account; with a 3b sweep candidate (every class) →
    `sweep_in_flight_matches`, and `sweep(t)` books it;
  - `own_account_unknown`; S15 → unplanned sweep; 4679 in debit → `servicer_shortfall` at the next check;
  - **[critic CSO-2, F10]** a generated file holding a sweep, then an advance-bearing unplanned payout → the download
    supersedes the file (2a's re-check end to end).
- **F. Returns**:
  - S16, an `own_transfer_in` with our SWP id and a `client_transfer_in` with our RMT id as original, at the exact
    amount → reversal `return:<line>:<t>`, `payout_returned` +N held to the run line's date, payout account returned,
    alert;
  - **[critic L2]** S16 short → `amount_differs` (no fee on an unflagged credit); a kind-`return` line short with a fee
    part → booked; more → `return_differs`;
  - `return_before_debit` (both causes); `already_returned`;
  - **[critic F1]** a return of t with an open unplanned booking → `unplanned_open`;
  - **[critic2] ML-3** a return of t whose second debit D2 is imported and unbooked → `debit_pending`; the options
    propose D2's booking; once D2 is booked unplanned, the return books `unplanned_payout_returned` and nothing is
    re-owed;
  - S20: a lot of two booked payouts → two reversals on one line (seq 1–2, distinct keys); an ambiguous lot →
    `batch_ambiguous`; a fee on a lot → `fee_not_allowed`;
  - **[critic F1]** the lot variant: a (1 000, client A) and b (700, client B), both booked and both re-executed and
    booked unplanned; a 700 credit naming the lot → b's `unplanned_payout_returned`; B is owed nothing again.
- **G. Unplanned returns (S27, S28)**:
  - S01's unplanned payout returned → `payout_returned` +A and `client_advance_reversal` −(A − P), net +P; its
    `unplanned_paid_item` rows stop counting; `double_payout_open` gone; again → `already_returned`;
  - **[critic F1, L5]** S03 then one copy back: the job reviewed it (`unplanned_payout_return`); ops book
    `unplanned_payout_returned` → the queue net 0, the advance closed, the next run pays nothing again. This inverts the
    draft's « residual pinned »;
  - **[critic F11, L4]** with P = 0: no breach row, no `remittance_due_critical`, no draft from the schedule, no late
    reason at the next approval; `pending_item_deadlines` gives the +A item no deadline. With P = A, the items keep
    their own deadlines and the +A item has none while they are pending;
  - **[critic2] ML-2** P = A (x booked, returned, re-executed: P on its return item ρ), then c's net-0 draft approved
    with a late reason and booked at approval, then the second copy returned → the +A item is held to ρ's line date
    (`pending_item_deadlines` and `_held_to` agree), the nightly check writes its breach row `payout_returned`, the
    schedule drafts it. Mutant: the third branch removed (no deadline, no row);
  - **[critic L3]** an unreferenced `client_transfer_in` of A from the client's IBAN → `not_its_line`; a kind-`return`
    credit from that IBAN → booked;
  - **[critic2] ML-11** an S13 client part (P = 0, advance A) and its flagged return without our reference from that
    IBAN (class N and O) → the options propose its unplanned return, which books; `double_payout_open` gone;
  - two open unplanned bookings of x: only the one with the largest advance is accepted (`return_differs` otherwise);
  - an advance with a settlement (seeded in a subtransaction) → `advance_settled`; a client-only one by a kind-`return`
    line from its IBAN.
- **H. Unsplit (S21/S22)** ([critic F8, F7, L11]):
  - the round-5 netted credit with stored details → `payout_returned(t1)` 4 198,40 + `payout(t2)` 328,00, proposed and
    booked;
  - d03 → the two stored payouts; naming t3 + t4 instead → `unsplit_parts_differ`. Mutant « identity by count only »;
  - our return beside a payer's chargeback (credit) → `parts_do_not_add_up`, and with a fee part → `fee_not_allowed`;
  - our payout beside a chargeback in a debit entry → refused;
  - a line imported before 6b-2a (details null) → `unsplit_detail_missing`; a detail without its amount →
    `unsplit_detail_missing`; an RFD detail → `unsplit_not_bookable`;
  - **[critic2] ML-5** a debit entry of −1 640 holding our RMT t −1 640, a debtor's +250 and a third party's −250
    (our detail alone makes the entry) → `unsplit_not_bookable`, no proposal; `NbOfTxs` 3 with two details given →
    `unsplit_not_bookable`. Mutant: the count check removed (it books payout(t));
  - **[critic2] CSO2-3** a U line with 501 stored details → `lot_too_large` (options, preview and command).
- **I. Compare and set**:
  - the preview's text books;
  - a pending change between them (an item frozen by another run's approval) → `split_changed`;
  - a draft created in between → `split_changed`;
  - **[critic CSO-12]** a draft found under the locks that step 1 did not lock → `split_changed`, never locked late.
- **J. Reads**:
  - `transfer_line_options` per class gives the proposal the tests above book: E cancelled → unplanned; E credit with an
    open unplanned booking → only the unplanned return; B partial → members and parts; N → 3b; U → the stored details;
    an own/client credit without our id → nothing;
  - the preview never raises; tenant isolation.
- **K. Guard** (as service_role):
  - a `fee` on an RMT line alone fails completeness (LG001);
  - an `unplanned_payout_returned` row not reversing an unplanned entry → check_violation;
  - `payout` on a credit line of a line not unsplit → check_violation;
  - `payout_returned` on `own_transfer_in` accepted.
- **L. Alerts and reviews**: every P0 alert is gone once its line is booked.
- **M. Funds pass** (**[critic CSO-11]**): any call booking a payout or sweep part queues one `process_debits` message
  with `funds_after` null; **[critic2] CSO2-7** so does a call booking `unplanned_payout_returned` or
  `unplanned_sweep_returned`; a call booking only planned returns queues none. Two return lines of x in one pass, both
  reviewed `unplanned_payout_return`; ops book the first as the unplanned return; the queued pass books the second as
  `payout_returned(x)`.
- **N. Mutants to kill** (listed in the PR):
  - uniqueness check removed (the equal-amount case books);
  - refunds dropped from rule 3b's candidates (F9);
  - attribution removed (F4: P₂ > 0);
  - reversals ignored (F3);
  - owed cap in place of the queue's (F5);
  - P = 0 for a returned x (F2);
  - `client_run_cancellable` removed (F6);
  - `unplanned_open` removed (F1);
  - fee rule widened (L2);
  - unsplit identity by count only (F8);
  - pending row −P instead of −A (the next approval refuses);
  - draft requeue removed (the next run pays twice: its gross);
  - `remit:line` key without the part index (two parts collide);
  - the motif as the entry reason (CSO-1);
  - the tenant filter after the status rules (CSO-5);
  - **[critic2]** net floored per item (ML-1); the third held-to branch removed (ML-2); the pending-debit fact
    removed, job and command (ML-3); `run_still_live` removed (ML-4); the U count check removed (ML-5); the S08-on-U
    rule removed (ML-6); the (iii) exclusion of a re-paid returned x removed (ML-8); the fee check removed (ML-10);
    the U lookup by `end_to_end_id` alone (CSO2-10).
- **P. (6b-2c)**:
  - `link_debit` `payout_candidate` (fee, explanation and, **[critic F9]**, the refund link when another candidate
    exists), `client_payout_line`, `own_transfer_out_line`;
  - `debit_queue` lists those lines « À classer », not « Frais », with `bookable_as`;
  - **[critic L8]** an ambiguous N line and a `batch_ambiguous` line suppress the in-flight breach row for five business
    days, then the row is written with `debit_unbooked`;
  - **[critic2] ML-7** a single-candidate N line dated on t's latest execution date, booked by ops on business day 7 →
    no breach row ever (it suppressed throughout, and its booking is on time); the same line dated after the date →
    the row written at its booking, not by the nightly check; a single-candidate N line left unbooked raises
    `bank_line_unbooked` after one business day. `private.transfer_line_offers` is true exactly when
    `transfer_line_options` has a proposal containing the transfer (every class). Mutant: the bound applied to every
    line (the false row);
  - **[critic2] CSO2-13** with 5 000 returned payouts on the account and a 2 000-row queue, « À classer » keyed reads
    are bounded per line (`pg_stat_xact_user_tables`);
  - **[critic2] ML-12** (switch on) a file cancelled after download re-issues x as x', the run is then cancelled, and
    the bank executes x late, booked unplanned → `unplanned_runs` lists the run;
  - **[critic CSO-9]** `remittance_run_payout` and `transfer_bookings`: another servicer's admin, a client admin, a
    collector and an aal1 admin get null / no rows; a mix of own and foreign ids returns only the own ones;
  - `client_remittance_summary`'s `unplanned_runs` for whole-client members only.

**`038_statement_suivi` (6b-2d):**
- RV-1 is approved and its debit booked after K₁ → RV-2's payload lists `debited` with the debit date. A debit booked
  between RV-2's K and its statement's drawing is not in RV-2 but in RV-3.
- A return after K₂ held by RV-3 → `returned`, `here`; held by no run → `pending`.
- A run cancelled before download → `cancelled`. Its late debit then booked unplanned (switch on) → the next statement
  lists `executed_after_cancellation`, with `advance_minor` when P < A (**[critic F17]**). A double execution →
  `debited_again`.
- **[critic L4]** `unplanned_returned` with the line's unplanned nature. **[critic L16]** `executed_outside` for an S13
  booking.
- **[critic L9]** `late_cause` `paid_by_unplanned` on a line covered by an unplanned booking.
- **[critic2] ML-9** `paid_by_unplanned_minor` on a line covered in part (« dont … versés le … »); an unplanned booking
  reversed after K still counts at K, one reversed before K does not; the advance clause per `p_bound` (`items`,
  `queue`), and the queue-bound case (all 1 640 of the run still owed, P = 440 by the queue) never says the advance
  « dépassait les sommes de ce reversement ».
- **[critic2] ML-12** (switch on) a run whose x was re-issued as x', then cancelled, x executed late and booked
  unplanned → `executed_after_cancellation`, not `cancelled`.
- **[critic L7]** a prepared draft discarded with its RV number is never listed.
- **[critic L17]** a previous approved run whose statement is not drawn yet still bounds the window; its own statement,
  drawn later, does not repeat this window's events.
- N = 0 runs and other clients' runs are never listed; another servicer is isolated; reads are keyed
  (`pg_stat_xact_user_tables`).

### 8.2 Worker
- **Unit (6b-2a)**:
  - parser: unsplit details recorded with ids, directions and amounts (absent → None); a whole-entry detail still a line
    of its own; parity with the ingest's shape check;
  - **[critic2] CSO2-9** a v08 detail with `Amt` 1 640,00 EUR and `AmtDtls/TxAmt` 1 600,00 USD → the stored amount is
    164 000 (`Amt` first, as `split()`/`whole()`); a detail whose only amount is in another currency → None;
    `StatementLine` stays hashable; `stage()` writes `Jsonb` (a unit test on the row it builds);
  - **[critic2] ML-5, ML-6** the detail count and `NbOfTxs`; `charges_minor` from `Ntry/Chrgs` and `TxDtls/Chrgs`
    (v02 and v08 shapes; a credit record, another currency or `ChrgInclInd` false → not counted, or null as §2.1
    says);
  - `unique_subset` against brute force on ≤ 12 amounts (Hypothesis: equal amounts, the complement side, the bounds).
    It is the oracle for SQL parity. **[critic2] CSO2-2** Also near the bound (13–20 amounts, where 2^n crosses
    10 000) and on saturating inputs: the null-or-indexes answer and the index at which a bound trips are compared
    with the SQL twin;
  - `P0_REVIEWS` = the alerts' P0 codes (a test reading both);
  - `_transfer_return` with `unplanned_open` → `unplanned_payout_return`, and **[critic2] ML-3** with `debit_pending`
    → `return_debit_pending`, never a booking (Hypothesis on `decide_line`).
- **[critic2] CSO2-12 Integration (6b-2a)**, `test_transfer_line_foundations_integration.py`: with a seeded unplanned
  booking (036 B's helper), the real `process_debits` job reviews a flagged return `unplanned_payout_return` and books
  nothing, both when the fact is fresh and when it is stale (the booking seeded between the candidates read and
  `apply_bank_bookings`: the SQL re-check reviews it). The same for a pending second debit (ML-3).
- **Hypothesis, `ledger_machine.py` (6b-2b)**:
  - rules: `book_payout`, `return_payout` (with and without an open unplanned booking), `book_sweep`, `return_sweep`,
    `unplanned_payout` (P by §3.6.1), `unplanned_return`, `reverse_item` (an allocation reversed after a cancellation),
    `cancel_run`;
  - invariants: I2′, I8′, I12, I13 (4670 never in debit), I14 (owed = pending + in flight), I19 (oracle bank), I20;
  - **[critic F3]** P ≤ min(A, the queue's net, the net still owed of x's items); Σ attribution per item ≤ its net;
    the queue moves by −P per unplanned booking. **[critic2] ML-1** « The net still owed » is the signed sum over x's
    pending pool items (negative items and reversal chains included, unplanned rows and their advances excluded),
    less the live attributions, floored once; the model's rules include `reverse_item` on a negative item's pair
    (`payout_overrun` cover) so the per-item floor is reachable;
  - « over the run, the client receives its net collections less commission plus its open advances »;
  - **[critic F1, F2]** never more than the client is owed plus its open advances after any return.
- **Integration (6b-2b, `test_transfer_line_ops_integration.py`)**, through the real import, jobs and command as an aal2
  session:
  - §7's E1–E9, then `synth camt053 --mode twice` → the job reviews `transfer_debited_twice` → ops book the options'
    proposal → RV-3 unchanged;
  - **[critic F1]** then `--return` of one copy → the job reviews `unplanned_payout_return`; ops book the proposal →
    nothing re-owed, the advance closed;
  - **[critic2] CSO2-7** then both copies returned on one statement → both reviewed; ops book one as the unplanned
    return; the queued funds pass books the other as `payout_returned(x)`, and the schedule drafts its run;
  - **[critic2] ML-3** a `--mode twice` statement left unbooked, then a `--return` of one copy → reviewed
    `return_debit_pending`, nothing booked; ops book the second debit, then the return → nothing re-owed;
  - (switch on) a run cancelled after its file was handed out, plus its file's late debit → P = A, c's draft requeued,
    prepare + approve jobs, Martin's check (received = collections − commission);
  - `--mode partial` → ops book the proposal; the left-out member's own debit next day is booked by the job;
  - `--csv` without the end-to-end column → rule 3b; **[critic F12]** a cancelled payout's late execution on that CSV
    → `unplanned_payout(x)` with P;
  - `--debit-charge 120` → payout + fee. **[critic2] ML-6, CSO2-1** Through the real parser, in the ISO shape (detail
    `TxAmt` N, entry N + 120, `Chrgs` 120): class U, the S08-on-U proposal books payout + fee; with
    `--debit-charge-no-detail-amount`: class E, the same parts; the ISO shape with `Chrgs` dropped → refused
    `unsplit_detail_missing`, the line stays unbooked with that reason;
  - `--unflagged-returns` → « Virement revenu » at the exact amount; the schedule drafts the `payout_returned` run
    keeping its deadline;
  - `--unsplit-details` → the U proposal booked; without amounts → refused;
  - SQL parity: `private.unique_subset` = the Python twin on 200 examples; `_held_to` = `pending_item_deadlines` for a
    planned and an unplanned return.
- **Concurrency (6b-2b, two connections, as 6b-1's; [critic CSO-8, CSO-5, CSO-12])**. In each pair one call waits or is
  refused, no 40P01 occurs, the line is booked once, and I9/I14/I19/I20 stay clean. The command is run against:
  - `cancel_remittance_run`;
  - `transfer_file_download`;
  - `generate_transfer_file` with a sweep;
  - `refresh_remittance_run`, `discard_remittance_run` and the prepare job on c's draft (including record_draft's
    40001 after a new token);
  - `approve_remittance_runs` (`busy`) and the approval job on c's draft;
  - `request_refund` on a late line's payment;
  - `link_debit` « Frais bancaires » and « Classer sans comptabiliser » on the same S12 line;
  - two `book_transfer_line` calls naming one transfer on two lines (an E line and a rule-3b N line; a lot credit and an
    E credit);
  - the M2b pass (`post_debit_links` holding payment `FOR UPDATE`) against a payout part's `FOR KEY SHARE`;
  - `confirm_payout_account` and `retire_payout_account` against `payout_returned` and `unplanned_payout_returned`;
  - the funds pass on the same line;
  - the same key submitted twice at once → both get the first result; **[critic2] CSO2-6** also when the first call is
    slow (a 450-member lot, or `pg_sleep` in a test hook beyond 2 s): the second waits on the key lock under its 7 s
    timeout and returns the first call's result, never `busy`;
  - **[critic2] CSO2-6** a call waiting on the `payments:` lock held by an allocation chunk → `allocation_busy`, not
    `busy`;
  - A's command naming B's ids → no lock on B's rows (`pg_locks` read from the second connection).

  Mutants:
  - runs locked after the allocation lock → deadlock;
  - the draft locked after the allocation lock → deadlock with `refresh_remittance_run`;
  - the line not locked → booked twice.
- **Stateful (6b-2b, `test_transfer_line_machine_integration.py`)**: a bank model executes files individually, as batch
  lines, partially, late, twice and returning, with unflagged and unsplit returns. Ops book every line through the
  options' proposal. After each step: every line is booked or reviewed; I9/I19/I20/I13/I14 are clean; no transfer is
  booked twice; LG008 is never raised; the client never receives more than it is owed plus its open advances.
- **Scale (6b-2b, `test_transfer_line_scale_integration.py`; [critic CSO-3])**, run as an aal2 API session with
  `statement_timeout = 8s`:
  - a 200-member PmtInf line short of one member: options < 1 s, command < 1 s;
  - 500 members: options < 2 s, command ≤ 4 s, and the time the allocation lock is held recorded;
  - 501 → `lot_too_large` at once;
  - **[critic2] CSO2-2** the worst saturating input (500 small payouts, short of one 80 € member): `unique_subset`
    < 0.5 s (its work bound), the command ≤ 4 s; the cap `private.transfer_line_lot_cap()` is then set with 2×
    headroom under 8 s from these runs, and lowered if they miss;
  - **[critic2] CSO2-3** options on the 5 000-member line of the payout scale fixture (one member short): < 0.5 s,
    `unique_subset` never called (`pg_stat_user_functions`), `lot_too_large` with `member_count` and no member list;
  - a requeue of a 50,000-item draft (the remittance scale fixture): command ≤ 4 s, the allocation lock held < 1 s (no
    clear under it);
  - the « À classer » tab with a 2,000-member lot line renders in < 2 s and never calls options;
  - read counts bounded per member (`pg_stat_xact_user_tables`, stale statistics as 6a/6b-1);
  - written up in `docs/benchmarks/remittances.md`.
- **6b-2d**: renderer fr-3 per event, repaid state and advance clause (pytest); golden PDF; `payload_version` refusal.

### 8.3 vitest
- **6b-2a**:
  - every new label;
  - the S23 texts say « ne peut pas encore » and promise no screen;
  - `transfer_unknown`'s check label names both directions (L14);
  - **[critic2] CSO2-14** `unplanned_payout_return` and `return_debit_pending` name no « Virement revenu » and say
    « prévenez le support »;
  - **[critic2] CSO2-4** `file_blocked` with only `sweep_exceeds_share` blocked → the sweep-only text (« les
    reversements qu'il contenait y reviennent »); with a payout blocked too → today's text.
- **6b-2b**:
  - every `transfer line booking refused:` code in the migration has a label (`transferLineErrorCode`);
  - 55P03 → `busy`, 57014 → `timeout`, **[critic2] CSO2-6** the re-raised `allocation_busy` → its label;
  - every `DECISION_LABEL` kind.
- **6b-2c**:
  - effect sentences for P = A, 0 < P < A and P = 0, the draft, the fee, the late breach, the unplanned return's block
    (L3), `client_run_cancellable` with its number;
  - options parsing (every class);
  - `offersTransferLineBooking` from `bookable_as`;
  - no « écran à venir » left in `lib/**`;
  - `runStatusText` with the date and the cancelled-run texts (L6);
  - a requeued draft shows « Préparation en cours », never « Préparation échouée » (CSO-6);
  - the Virements labels;
  - the reworded notes: for each, the mutant carrying the old words is killed;
  - L15's labels: S06 / ordered transfers;
  - **[critic2]** the advance's reason by `p_bound` (ML-9); the fee sentence with and without stored charges (ML-10);
    the flagged-return-without-reference sentence (ML-11); `cancelled_transfer_debited` worded by the run's status
    (ML-4); the « fichier remplacé » sentence only with `supersedes_file` (CSO2-4); `lot_too_large` with
    `member_count` and at most 50 members (CSO2-3); 2c's rewording of `unplanned_payout_return` kills 2a's words
    (CSO2-14).

### 8.4 E2E (6b-2c; `make e2e`, CI `e2e`)
- `remittances.spec.ts`:
  - approve → generate → download → « Transmis » → a synthetic statement of the debit → the job → « Débité le … » on
    the run, « Virements » and the client space;
  - a returned payout → « Revenu impayé » banner, a new draft, the client's text.
- `payments-debits.spec.ts`:
  - a second debit (`--mode twice`) → « Prioritaire » → « Virement hors reversement » (P = 0 sheet) → motif →
    « Traités »;
  - one copy returned → « Virement revenu » proposes the unplanned return;
  - a partial batch line → « Débit d'un lot de reversements » (members shown) → booked;
  - an unsplit entry with details → « Comptabiliser d'après le détail du relevé »;
  - the screenshots of §7.5.

---

## 9. Docs
- **ADR-0014** « M2c-6b-2a » … « M2c-6b-2d »:
  - the departures of §1.3: the parts model; the only-subset rule; rule 3b with every candidate kind; the fee rule; the
    stored unsplit details;
  - P per item (attribution, reversals, the queue cap) and its conservative direction;
  - the draft requeue without a clear; the two unplanned return kinds; the job's review of a double payout's return
    (Q12); the download's sweep re-check; the command's budget and lot bound; « Suivi » as of K, approved runs only;
  - a correction to the 6b-1 body's deviation « Round-7 SQL hints and 033 kept » (ADR-0014 l.534-540). Round 3 M4
    reworded those hints and 033's classifier expectation (l.961-976); what was left was the « écran à venir » wording,
    handled here;
  - **[critic L10]** (6b-2a) reword l.1183 and l.1271: S24 and R3 are left to M2c-7, not 6b-2.
- **COMPLIANCE**:
  - add **OQ-82** (counsel): recovering an unplanned or double payout.
    - The netting: what paid the items the late payout was meant to pay, still owed, is netted as a negative item in
      the client's next run. That is a cancelled run's items, or a returned payout's item, net of their reversals,
      counted once across bookings.
    - The rest is the servicer's advance, recovered only under a claw-back clause, otherwise by a repayment request
      (M2c-7). A manual payout to the client's IBAN with no transfer is all advance (Q8).
    - **[critic L1]** « P ne dépasse jamais ce qui restait dû au client sur les sommes que ce virement devait payer ; le
      surplus est une avance (pas de retenue sans clause) ».
    - **[critic2] ML-1** « Ce qui restait dû » is the signed net of those sums: what the client owes back on them (a
      payment reversed, an earlier advance) lowers it. The draft's per-item floor let a double payout be netted
      against unrelated collections, a hold-back without a clause.
    - The residual of §3.6.1: an item P counted, reversed afterwards, nets against later collections. M2c-7's
      `cover_remitted_reversals` keys on booked runs.
    - ⚖️ C. civ. 1302-1, 1347, 1348-2, with OQ-38.
  - add **OQ-85** (accountant) **[critic L11]**: the supporting document of ledger entries split out of one bank entry.
    Default: the statement's own per-transaction details, kept on the line at import (§2.2), with the motif; an entry
    whose detail is not in the statement is not split in Collectoo (it waits for M2c-7 and the bank). **[critic2]
    ML-5** Only an entry every detail of which is ours is split (the detail count kept at import); one holding anything
    else, even netting to zero, is not. **[critic2] ML-6** The bank's charge split out of one entry rests on the
    statement's own `Chrgs` record, kept at import.
  - update **OQ-34**: Q2, S25 stays to 6b-3, with the two entry options of §10 Q2 named.
  - update **OQ-36**, **[critic F11, L4, L9]**:
    - a reversed unplanned remittance's item has no deadline while the items its P paid are still pending;
      **[critic2] ML-2** once a run froze them, it is held to their earliest line date, `payout_returned`;
    - the items an unplanned P paid keep their own deadlines (Q15's default: a breach may be recorded although the
      client had the money at the unplanned debit's date; the statement says when it was paid);
    - the `debit_unbooked` blocked reason (Q14).
  - update **OQ-81 (b)**: open, 6b-3.
  - update **OQ-83**: a batch line short of members is booked by ops when only one subset makes it; `batch_mixed` stays;
    **[critic L8]** an ambiguous line stops suppressing breach rows after five business days; **[critic2] ML-7** a line
    ops can book as the payout's debit keeps suppressing, with its alert.
  - update **OQ-84**:
    - unflagged returns booked by ops at their exact amount (a short one stays: Q10); lot credits and unsplit entries
      booked per §3.4;
    - (f): unsplit entries booked only from the statement's own details; lines imported before 6b-2a stay;
    - (i) closed by the reason `own_transfer_line`;
    - **[critic L10]** (e), (h), round 8 T1 and R3 reworded: the payments made of our credits, and our ids only in a CSV
      label, wait for M2c-7 (Q13), the former with the P0 alert `own_transfer_payment`;
    - (j) **[critic2] ML-6, ML-10** reworded: a charge on our transfer's own line is booked as the firm's fee when it
      equals the statement's `Chrgs`, or, with none recorded, when it is not the amount of one of our transfers; the
      ISO shape (one detail of ours at N, the entry N + F) is booked from the stored charge only. A short line of its own
      (S19) unchanged.
  - update **CPCE-08**:
    - an ops booking of a late debit writes its breach rows;
    - the members a batch line left out get theirs from the nightly check;
    - **[critic L9, L8, L10]** the date rule of Q15; the bounded suppression of Q14; S23's money has no R124-6 clock
      until M2c-7 (P0 alert);
    - **[critic2] ML-7** the bound applies only to lines no rule can book as that payout's debit; **[critic2] ML-2**
      the re-owed item of an unplanned payout returned after a run froze what it paid is held to those items' date.
- **DOMAIN**: « Virement hors reversement », « Débit d'un reversement (par l'équipe) », « Virement revenu (par
  l'équipe) », « Détail du relevé (écriture non détaillée) », « Suivi de vos reversements précédents », « Avance du
  cabinet » (cause double paiement).
- **Design** `m2c-remittances.md`:
  - §9.7: the unplanned payout as built, P;
  - §10 item 5: « Suivi » built as of K;
  - §12: annotation;
  - §21: 6b-2a…2d.
- **m2c-6b-plan.md** §3.2: 6b-3's follow-ups become pgTAP `039`.
- **ROADMAP**: the M2c-6b rows. **ARCHITECTURE** §4: the new keyed probes. **Benchmarks**. **PROGRESS** at every
  commit.

---

## 10. Founder questions
**[critic L18]** Each question is in plain French, with a default (a) and an alternative (b). The technical detail
stays in this file (the § named). The chat report gives this file's path and the questions as numbered lines: one line
for 1–7 (« 1–7 : défauts du plan 6b, inchangés »), then one line per new question. The answer is « 1 ok, 8 b … ».
Questions 1–7 are `m2c-6b-plan.md` §5's, still unanswered: 6b-2 uses each default and keeps it open.

1. **Annulation d'un fichier après téléchargement, en 6b-3** (OQ-81 (a)). a (défaut) : oui, une fois le test 034 passé.
   b : non, et les virements refusés restent « en cours » au-delà du mois R124-6.
2. **Remboursement débité qu'on ne peut pas rattacher** (S25, OQ-34). a (défaut) : en 6b-3, à quatre yeux, toute la
   ligne est une perte du cabinet, et l'argent du payeur reste en attente. b : la sortie du remboursement est
   comptabilisée sur ce qui reste non imputé, et la perte ne porte que sur l'excédent.
3. **Copie d'un fichier déjà exécuté** (OQ-81 (c)). a (défaut) : non, on garde l'empreinte, le contenu et le journal. b :
   oui, téléchargeable pour archive.
4. **Virement exécuté hors reversement** (§3.6.1, OQ-82). a (défaut) : ce qu'il a payé des sommes encore dues (d'un
   reversement annulé, ou d'un virement revenu) est déduit du prochain reversement ; « encore dues » se compte net de
   ce que le client doit rendre sur ces mêmes sommes (un paiement annulé depuis, une avance) **[critic2 ML-1]** ; le
   reste est une avance du cabinet, récupérée seulement par la clause de reprise, sinon par une demande de
   remboursement (M2c-7). b : tout le montant est déduit du prochain reversement (une compensation, à valider par
   l'avocat).
5. **Lignes groupées impossibles à détailler** (plusieurs remboursements, ou une banque qui ignore la demande de
   détail ; OQ-83). a (défaut) : non comptabilisables en 6b, et on demande le détail à la banque. b : en M2c-7,
   comptabilisées par l'équipe d'après le détail de la banque, pièce jointe et seconde validation.
6. **Qui comptabilise ces lignes.** a (défaut) : une personne (administrateur ou responsable des opérations, double
   authentification, motif). b : deux personnes pour tout virement hors reversement et toute écriture regroupée.
7. **Virement revenu impayé et délai R124-6** (OQ-36). a (défaut) : les sommes gardent leur date limite, et un
   dépassement est enregistré « bloqué : virement revenu impayé ». b : comme un dépassement ordinaire.
8. **Débit vers le compte d'un client sans aucune de nos références** (S13). a (défaut) : tout est avance du cabinet,
   rien n'est déduit. b : déduit jusqu'à ce qui reste dû au client.
9. **Débit d'un virement dont le fichier n'a jamais été téléchargé** (S06). a (défaut) : en 6b-3, comptabilisé comme
   le virement de son reversement, et l'ancien fichier est remplacé ; d'ici là, alerte prioritaire, et l'équipe
   vérifie avec la banque. b : virement hors reversement.
10. **Frais de la banque sur nos virements** (§3.4.10, OQ-84 (j)). a (défaut) : seulement sur la propre ligne du virement
    (son débit, ou son retour signalé par la banque), à la charge du cabinet ; égaux aux frais que le relevé indique
    quand il en indique, et, sinon, sans plafond sauf s'ils ont le montant de l'un de nos virements (alors la ligne
    attend le détail de la banque) **[critic2 ML-10]** ; la forme habituelle du relevé (le virement à son montant, la
    ligne augmentée des frais indiqués) est comptabilisée de même **[critic2 ML-6]** ; ailleurs, la ligne attend le
    détail de la banque. b : un plafond que vous fixez, avec une seconde validation au-delà.
11. **Écriture de la banque qui regroupe nos virements** (S21/S22, §3.4.12). a (défaut) : comptabilisée d'après le
    détail que le relevé lui-même donne (gardé à l'import), seulement si toutes les opérations de l'écriture sont nos
    virements (**[critic2 ML-5]** même quand les autres s'annulent entre elles) et en font exactement le montant ;
    sinon elle attend (banque, M2c-7). b : aussi d'après un détail envoyé par la banque, joint et validé par une
    seconde personne.
12. **Virement exécuté deux fois, puis l'un revient** (S28). a (défaut) : l'équipe le comptabilise comme le retour du
    second virement ; rien n'est reversé de nouveau, et l'avance est annulée. b : l'import le comptabilise comme le
    retour du reversement ; le client est payé une seconde fois, nous doit l'avance, et son compte de reversement est
    bloqué.
13. **Notre argent revenu que Collectoo ne sait pas encore comptabiliser.** Trois cas : un crédit venant du compte du
    client, sans notre référence, du montant d'un virement hors reversement ; un paiement déjà créé à partir d'un de nos
    virements revenus ; notre référence seulement dans un libellé CSV (S23, S24, S27). a (défaut) : il attend M2c-7 (un
    remboursement du client, ou le retour défait), avec une alerte prioritaire pour le paiement, et l'équipe prévient le
    support. b : comptabilisé comme retour dès 6b-2, le crédit du client par son IBAN, le paiement défait par le
    support.
14. **Débit que Collectoo ne peut attribuer à aucun virement précis** (§4.2) : sans référence avec plusieurs virements
    possibles, lot dont plusieurs combinaisons font le montant, écriture regroupée non détaillée, débit inférieur au
    virement. **[critic2 ML-7]** Une ligne que l'équipe peut comptabiliser comme le débit de ce virement n'est pas
    concernée : elle reste en attente avec une alerte, et sa comptabilisation enregistre le dépassement seulement s'il
    a eu lieu. a (défaut) : après 5 jours ouvrés, le dépassement de délai des virements concernés est enregistré
    « bloqué : débit possible non comptabilisé ». b : deux personnes classent la ligne « ce n'est pas ce virement »,
    avec le détail de la banque.
15. **Sommes payées par un virement exécuté hors reversement : quelle date pour le délai R124-6 ?** (OQ-36). a
    (défaut) : elles gardent leur date limite ; un dépassement peut alors être enregistré alors que le client avait
    l'argent, et le relevé dit à quelle date il a été versé. b : elles sont payées à la date de ce virement, et un
    dépassement est enregistré à ce moment-là s'il était déjà tard.
16. **Virement saisi à la main à la banque pour un reversement en cours** (§3.4.4). a (défaut) : comptabilisé comme le
    virement de ce reversement (même montant, IBAN du client exigé, seul candidat). b : virement hors reversement, en
    avance du cabinet.

**[critic2]** No new question: each second-critique fix either follows from a default already asked (Q4, Q10, Q11,
Q12, Q14, Q15, worded above where they changed) or leaves a shape to 6b-3 (`run_still_live`) without a choice to make.
The chat report says « 4, 10, 11, 14 : précisés (2e relecture) ».

---

## 11. Risks and how this plan prevents them
| Risk | Prevention |
|---|---|
| A batch line booked to the wrong members (or the wrong client) | the only subset over every member, whatever its status (§3.5), else `batch_ambiguous`; ops confirm, never compose |
| **[critic F8]** An unsplit entry booked to transfers it does not hold | its parts are the statement's own stored details, at their amounts; a line without them is never booked |
| The next run pays the unplanned money again | pending row −A + advance trigger = net −P; P counts reserved items; c's draft requeued in the same transaction; **[critic F6]** a cancellable approved run holding the items is cancelled first; 037 approves the next run with A = P, A > P, P = 0 |
| **[critic F1, F2]** A double payout's return, or a returned payout's re-execution, paying the client twice | the job reviews a return of a transfer with an open unplanned booking, and ops book the unplanned booking's return; P of a returned x counts its return item |
| **[critic F3, F4, F5, L1]** An overpayment netted against unrelated collections (hold-back without a clause) | P per item, net of reversals, counted once across bookings, capped by the queue's net; every excess is an advance; **[critic2] ML-1** the items' cap is their signed net, floored once |
| **[critic2] ML-3, ML-4** A return or a late debit booked before the line that decides it | a return waits while a second debit is unbooked (`return_debit_pending` / `debit_pending`); a cancelled x's late debit is never an unplanned payout while its run is live (`run_still_live`) |
| **[critic2] ML-5, ML-6, ML-10** A third party's movement or our own transfer booked inside one of our entries | an unsplit entry is booked only when every detail is ours (count stored); a fee equals the statement's `Chrgs`, or is refused when it is the amount of one of our transfers |
| **[critic2] ML-2, ML-7** R124-6 clocks lost or false breach rows | the re-owed item of an unplanned return is held to the frozen items' date; the five-day bound only for lines no rule can book as the payout's debit |
| A reference-less line booked to the wrong transfer | **[critic F9, F12]** rule 3b's uniqueness over in-flight payouts, sweeps, refunds and executable cancelled or returned payouts (`line_ambiguous`), with the counterparty IBAN when present and required on O/E∅; the client and own parts refused while any candidate exists, on every class (**[critic F13]**) |
| **[critic L2, F7]** A third party's movement booked as the firm's bank charge | a fee part only on our transfer's own line (its debit, or its flagged return) |
| A double payout hidden as a fee or an explanation | 6b-2c refuses both on payout candidates, client-IBAN debits and own-IBAN debits; P0 alerts until booked |
| **[critic L8]** An in-flight breach suppressed for good by a line nobody can book | five business days, then the breach row « bloqué : débit possible non comptabilisé » (Q14) |
| **[critic F11, L4]** False R124-6 breach rows after an unplanned return | the reversed unplanned remittance's item is never monitored; the items its P paid keep their clocks |
| **[critic CSO-2, F10]** Over-sweep | the first download re-checks the file's sweep against the share and supersedes it; `servicer_shortfall` P0 for a sweep already handed out |
| **[critic CSO-1]** Ops' motif read by a client (another client's name, internal notes) | entry reasons fixed; the motif only on `bank_line_booking`, staff only |
| **[critic CSO-5]** One servicer probing or locking another's rows | the tenant filter before any rule or lock; the same answer for absent and foreign ids |
| **[critic CSO-3, CSO-4]** Timeouts, the allocation lock held for seconds, a list page that cannot render | ≤ 4 s at 500 items, `lot_too_large` beyond; the subset before the locks; options per line opened, never per row; **[critic2] CSO2-2, CSO2-3, CSO2-13** the subset's work bound, the cap checked first by keyed count, rule 3b driven from the lines |
| **[critic2] CSO2-5** A slice's migration refused or skipped on production | the order 2a → 2b → 2c → 2d pinned, timestamps set at PR time, a CI step against `origin/main` |
| Regression in the job's reviewed re-check | `post_bank_bookings` redefined in 6b-2a for one rule, its twin with it (parity, Hypothesis); `bank_booking_post_rows` for one expression; parity test ops vs job; 035 and 015–034 re-run |
| Deadlock | the job's lock order, drafts in the runs step; drafts locked late refused; two-connection tests per writer (**[critic CSO-8]**); mutants |
| Stale page, wrong split | `p_expected_text` compare-and-set (`split_changed`) |
| Texts promising what the code does not do | « écran à venir » reworded with the screen (6b-2c), withdrawn now where 6b-2 does not book (S23, S24: **[critic L10]**); client-space and « Suivi » texts true of what was executed (**[critic L6, L7, L13]**); vitest sweeps |

---

## 12. The critics' findings: where each went

### 12.1 First critique (against `ab1a1f8`)

Folded findings are marked « [critic] » in the sections named. **Rejected** ones carry the reason.

| Id | Disposition |
|---|---|
| F1 | Folded: §1.3 item 6, §2.3 (job + twin, 2a), §3.4.11 `unplanned_open`, §3.4.13 rule 4, §3.5 lot credits, §3.11, Q12, 036 B, 037 F/G, mutant |
| F2 | Folded: S03r, §3.6.1 items of a returned x, 037 D, mutant |
| F3 | Folded: §3.6.1 net of reversals, 037 D, Hypothesis invariant, mutant |
| F4 | Folded: `private.unplanned_paid_item` (§3.1, §3.6.4), §3.6.1, 037 D, mutant |
| F5 | Folded: §3.6.1 queue cap in place of the owed cap, 037 D, mutant |
| F6 | Folded: §3.4.6 rule 7 `client_run_cancellable`, §3.8 step 1 and 8, 037 D, mutant |
| F7 | Folded: §3.4.10, §3.4.12 (no fee on U; a third party's movement never booked), 037 C/H, mutant |
| F8 | Folded: §2.1–§2.2 stored details (primary proposal), §3.4.12, 037 H, mutant. Its fallback (unique subset over candidates + four eyes) is not needed |
| F9 | Folded: §3.4.4 (ii), §4.1 refund link refused, 037 C, mutant |
| F10 | Folded through CSO-2 (a): the download re-check (§2.4) in place of a wider `sweep_file_pending` |
| F11 | Folded: §3.12 `pending_item_deadlines` / `_held_to`, OQ-36, 037 G |
| F12 | Folded: §3.4.4 (iii), §3.4.6 x by rule 3b, `cancelled_payout_matches`, 037 D, integration CSV |
| F13 | Folded: §3.4.6 rule 4 and §3.4.8 rule 3 on every class, `payout_not_handed_out_matches`, 037 D |
| F14 | Folded: §2.1 (no new index; it exists), §5 read cost |
| F15 | **Rejected (superseded by L2):** the fee is now allowed only beside a transfer part on that transfer's own line, so it never meets a transfer-less part, and « at most one part without a transfer » stays true |
| F16 | Folded: §3.4.1 (`returns_line_id` of the servicer, account, currency), §3.4.2 `not_a_transfer_line`, 037 B |
| F17 | Folded: §5 the advance clause, 038, renderer tests |
| L1 | Folded with F3/F4/F5: §3.6.1, the false sentence and risk row withdrawn, OQ-82 (wording and the M2c-7 residual). « Keep the owed cap as a second bound »: replaced by the queue cap, which is tighter (queue ≤ owed by I14) |
| L2 | Folded: §3.4.10, §3.4.11 rule 8, Q10 reworded, 037 C. **Rejected in part:** « the options never propose a fee ». They propose one only on a class-E line, the one place a fee is allowed: the line is one transaction carrying our id, so its difference with the transfer can only be the bank's charge on it. Ops still confirm with a motif, and the sheet says « à la charge du cabinet » |
| L3 | Folded: §3.4.13 rule 3, §3.11 (no proposal), the sheet's block sentence, Q13, 037 G. **Rejected in part:** « mark the payout account returned only on kind `return`, never on a `client_transfer_in` ». An own or client credit carrying our id (S16) is the payee's bank sending our transfer back unflagged. The classifier keeps the client IBAN's kind before our id (`bank_line_refined_kind`, l.5395-5406), so these returns arrive as `client_transfer_in`, and blocking the account is as prudent there as for a flagged return. The unreferenced credit the finding describes is now refused before any block |
| L4 | Folded: §3.12 (no deadline), §5 the nature and the `unplanned_returned` event, OQ-36/CPCE-08, 037 G, 038 |
| L5 | Folded with F1 (Q12 flipped) |
| L6 | Folded: §4.4 `unplanned_runs`, §7.4 `runStatusText`, vitest, screenshot retaken |
| L7 | Folded: §5 approved runs only, 038 |
| L8 | Folded: §4.2 bounded wait + `debit_unbooked`, §4.1 label, Q14, CPCE-08/OQ-83, 037 P |
| L9 | Folded: Q15 (default: own clocks), §5 `paid_by_unplanned`, CPCE-08/OQ-36, 038 |
| L10 | Folded: S23/S24 rows, §2.6 alert and texts, Q13, OQ-84/R3/ADR rewording in 6b-2a, CPCE-08 |
| L11 | Folded: stored details (§2.2), Q11 reworded, OQ-85 for the accountant, Q6 mentions U. **Rejected in part:** « a stored upload or a second approver for U ». The bank's detail is now the statement's own data kept on the line at import, not a transcription, and anything else stays unbooked. Q11 (b) offers the upload and second approver for details outside the statement |
| L12 | Folded: §3.4.4 rule 3b on O/E∅ (IBAN required), §3.4.6 rule 4 on every class, Q16, 037 C/D |
| L13 | Folded: §3.7 entry reasons, §7.3 sheets, §5 `debited_again` |
| L14 | Folded: §2.6, §7.1 label for both directions, vitest |
| L15 | Folded: §3.10 `not_cancelled_nor_booked`, `not_handed_out`, `fee_not_allowed`; §4.3 hint suffix; vitest |
| L16 | Folded: §5 advance clause and `executed_outside`, 038, golden PDF |
| L17 | Folded: §5 window on the previous approved run, the « encaissements connus au » wording, 038 |
| L18 | Folded: §10 (a/b in plain French, the chat format); the questions raised in L3, L8, L9, L10, L11 and L12 added (Q13–Q16; L11 in Q11) |
| CSO-1 | Folded: §3.7 entry reasons, §3.12 `bank_booking_post_rows`, 037 C, mutant |
| CSO-2 | Folded: option (a), §2.4 (6b-2a), 036 C, 037 E |
| CSO-3 | Folded: §1.3 item 15, §3.2 budget and step 6, §3.5 bound and timing, `lot_too_large`, `timeout`, §8.2 scale. Of its two remedies, the refusal is chosen rather than a worker job: lots of more than 500 partially executed are rare, and support handles them |
| CSO-4 | Folded: §3.11, §4.1 `bookable_as`, §7.3, scale check |
| CSO-5 | Folded: §3.4.1, §3.8 key collection, `client_ambiguous` per servicer, 037 A, concurrency `pg_locks` check, mutant |
| CSO-6 | Folded: §3.6.5 `last_failure` null, §4.4 `draft_unplanned`, §7.4, vitest |
| CSO-7 | Folded: §3.6.5 (no clear; the reset fields), scale test |
| CSO-8 | Folded: §8.2 concurrency pairs and mutants |
| CSO-9 | Folded: §4.4 isolation, 037 P |
| CSO-10 | Folded through CSO-2 (a): a `pending` file is never served and is re-checked when downloaded (036 C) |
| CSO-11 | Folded: §3.2 step 11, 037 M |
| CSO-12 | Folded: §3.2 step 2 advisory lock, §3.6.5 drafts locked late refused, 037 I, concurrency |

### 12.2 Second critique (against `dd8c6fb`)

Folded findings are marked « [critic2] <id> » in the sections named. Each was re-checked against the code at `dd8c6fb`
(the line numbers quoted are that commit's). **Rejected** parts carry the reason. ML-6 and CSO2-1 are one defect, seen
by both critics; they are folded together.

| Id | Disposition |
|---|---|
| ML-1 | Folded: §3.6.1 (eligible excludes unplanned rows and their advances; `net(i)` signed; `cap(x)` floored once; attribution over positive items), §1.3 item 9, OQ-82, Q4, 037 D case + mutant, Hypothesis invariant. Confirmed: `cancel_remittance_run` re-queues `l.amount_minor` signed (20261112090000 l.2122-2126) |
| ML-2 | Folded: §3.12 third branch of `pending_item_deadlines` / `_held_to` by `unplanned_paid_item`, §1.3 item 17, OQ-36, CPCE-08, §6, 037 G case + mutant, parity. Confirmed: the `payout_returned` branch keys only by the transfer's run lines (20261116090000 l.3874-3910), and an N = 0 run is booked at approval (20261112090000 l.1887-1891); reachable with the switch off |
| ML-3 | Folded: §2.3 job fact `tr_debit_pending` (`private.transfer_late_lines`, which returns an unbooked RMT debit of a booked x, l.2546-2590) → review `return_debit_pending`, its twin; §3.4.11 rule 5 `debit_pending`; §3.11 options; §2.1 reason; §2.6/§4.3/§7.1 labels; 036 B + mutant, 037 F, integration. A new reason, not `unplanned_payout_return`, because no unplanned booking exists yet and that label would be untrue |
| ML-4 | Folded: §3.4.6 rule 4 `run_still_live` (x cancelled is accepted only when its run is cancelled or booked), §3.4.4 (i) includes re-issues and (iii) keeps the cancelled original, so x/x' is `line_ambiguous`; S01/S02 rows, §1.2 (6b-3), §3.10, §3.11, §4.3 conditional `cancelled_transfer_debited`, §7.3, 037 C/D + mutant. Confirmed: `confirm_transfer_cancellation` leaves the run (l.5015-5077), `transfer_file_release` moves `run.transfer_id` (20261115090000 l.1693-1713), `cancel_remittance_run` then refuses `transfer_already_debited` (l.5143-5148). Switch-on only, but built and tested now |
| ML-5 | Folded: §2.1 `unsplit_detail_count`, `unsplit_batch_count`; §2.2 parser and ingest; §3.4.12 count rule → `unsplit_not_bookable`; S21 row, OQ-85, Q11, §3.10 label, 036 A, 037 H + mutant, synth. Confirmed: the parser has every detail (`details = txs`, camt053.py l.359-380) and `split()` returns None on mixed directions, so such an entry is unsplit with `unsplit_ours = 1` |
| ML-6 | Folded with CSO2-1: §2.1 `charges_minor`, §2.2 detail amount by the parser's own priority, §3.4.10 (c) S08 on U (one detail in all, ours, at N; fee = line − detail = stored charges, required), §3.4.12, S08 row, OQ-84 (j), OQ-85, Q10, synth ISO shape by default, 037 C + mutant, integration through the real parser. Confirmed: `partial_ours` keeps such an entry unsplit (camt053.py l.359-371, `whole()` l.405-420). **Rejected in part:** « the fee must equal Chrgs *when it is given* » (absent allowed). On U the fee is booked only from the stored charges: with nothing recorded, the difference between the entry and its one detail is not the statement's word for a charge (CSO2-1 (a)'s stricter choice; F8/L11: ops compose nothing). The line stays `unsplit_detail_missing` |
| ML-7 | Folded: §4.2 `private.transfer_line_offers` (the bound only for lines that offer no booking containing the transfer; those that do keep suppressing and raise `bank_line_unbooked`), §1.3 item 10, Q14 reworded, CPCE-08, OQ-83, 037 P + mutant. Of the two remedies the first is chosen; the « levée » row is rejected with its reason in §4.2. Confirmed: the job books no reference-less payout debit (l.1328-1333) and the bound would have applied to every line `transfer_debit_may_be_seen` counts (l.3440-3471) |
| ML-8 | Folded: §3.4.4 (iii) exclusion of a returned x while its return item is held by a live line of a run whose payout is a (i) candidate at the same amount and IBAN; S12 row, 037 C + mutant. Of the two remedies the exclusion is chosen: a time window would be a banking rule nobody has given |
| ML-9 | Folded: `p_bound` (§3.6.5, §3.11 preview, §5 payload), the advance clause worded by it (§5) and the 0 < P < A sheet (§7.3); `paid_by_unplanned_minor` with « dont … » for a partial attribution; reversal read as of K (§5); 038, vitest. **Rejected in part:** a single mechanism wording alone (« la part qui n'a pas pu être déduite … ») is kept as the lead, but the cause is added from `p_bound`, since the client is owed the reason |
| ML-10 | Folded: §3.4.10 (charges equal when stored; `fee_unexplained` when none are stored and the fee is the amount of one of our filed transfers, the line's own included), `bank_transfer_filed_amount_idx` (§3.1), §3.10, §3.11, §7.3 sentence, OQ-84 (j), Q10 (b) kept as the founder's cap, 037 C + mutant. Confirmed: `whole()` returns True for a detail without an amount (camt053.py l.414-415) |
| ML-11 | Folded: §3.11 N/O/E∅ credit of kind `return` proposes the unplanned return of the open booking to that IBAN at that amount (largest advance first), S13/S27 rows, §7.3 sentence, 037 G. The rules of §3.4.13 already accepted it; only the proposal was missing |
| ML-12 | Folded: §4.4 `unplanned_runs` (and `remittance_run_payout`, `transfer_bookings`) and §5 `executed_after_cancellation` keyed on the run's transfer chain (`run.transfer_id`, then `replaces_transfer_id`, by key: the set `bank_transfer.run_id = run`, with no new index, since `bank_transfer_run_uq` excludes cancelled rows), §7.4, 037 P, 038. Switch-on only |
| CSO2-1 | Folded with ML-6 (option (a)); its test points (037 H/C, integration with the detail amount written, the variant without it) are in 037 C and §8.2 |
| CSO2-2 | Folded: §2.5 work bound (Σ set sizes ≤ 1,000,000), pinned visiting order, `private.transfer_line_lot_cap()`; §1.3 item 15 (cap set from the scale run, lowered if missed); §3.4.0, §3.5; 036 D timing, Hypothesis parity near the bound and at the tripping index, scale worst case |
| CSO2-3 | Folded: §3.2 step 6, §3.5, §3.4.12 (cap first by keyed count for B, lot credits and U; `lot_too_large`, not `bad_request`), §3.11 (`member_count`, at most 50 members), §3.10 label, 037 H (501 details), scale (5,000-member options, `unique_subset` never called) |
| CSO2-4 | Folded: §2.4 sweep-only `file_blocked` text (from `blocked`), §3.11 `supersedes_file`, §7.3 sentences only when it is set, §1.2 (6b-3 adds `debited_cancelled_sweeps` to the download re-check), 036 C asserts (payouts `ordered` with their dates, runs approved, same-day regeneration without a late reason), vitest. Confirmed: the text at `lib/remittance/transfers.ts` l.1025-1026 |
| CSO2-5 | Folded: Precondition and §1.4 (order pinned 2a → 2b → 2c → 2d; timestamps at PR time; types regenerated after rebase), §2.6 CI step in the `db` job, 036 test of the step. No slice boundary moves; 2d now waits for 2c |
| CSO2-6 | Folded: §3.2 step 2 (key lock under a local 7 s `lock_timeout`, restored to 2 s), §3.10 (`busy` / `allocation_busy` split by the step waited at), §7.2, vitest, concurrency (slow first call; allocation chunk) |
| CSO2-7 | Folded: §3.2 step 11 (also after `unplanned_payout_returned` / `unplanned_sweep_returned`), 037 M rewritten, integration. Confirmed: `bank_booking_candidates` re-reads reviewed lines (l.616-640) |
| CSO2-8 | Folded: §2.2 re-import compares stored and staged details, detail counts and charges → `entry_detail_differs`; a stored null is neither compared nor filled; 036 A. Confirmed: `_bi_known` compares direction, amount and date only (l.6114-6124) |
| CSO2-9 | Folded: §2.2 and §6 (detail amount by the parser's priority with the currency check; `tuple[UnsplitDetail, ...]`; `Jsonb` in `jobs/payments.stage()`; `STAGE_COLUMNS`; the non-existent `jobs/statements` corrected), §8.2 unit tests. **Rejected in part:** « `bench.staging_digest` must handle the new field ». `staging_digest` is the boarding stage's (`boarding/stage.py`, called from `bench.py` l.56-81 on boarding files), not the statements', so a statement field never reaches it |
| CSO2-10 | Folded: §3.4.12 lookup by (`organization_id`, `end_to_end_id`) then the line's account, one refusal and `why` for foreign, unknown or other-account ids, never collected or locked; §3.11; 037 A (`pg_locks`) + mutant. Confirmed: `end_to_end_id` is unique across servicers (20261111090000 l.1460) |
| CSO2-11 | Folded: §3.1 (RLS enabled, all privileges revoked from `public, anon, authenticated, service_role`, no change-log trigger: private tables have none, and the table is append-only), §2.5/§2.6 execute revoked on `unique_subset`, `transfer_line_lot_cap`, `own_transfer_line_hint`; 036 and 037 A privilege tests. Confirmed against `private.remittance_pending` (20261111090000 l.4166-4169) |
| CSO2-12 | Folded: 036 B seed helper posts the `double_payout` advance; 037 D parity of the command's rows with the helper's; a 2a worker integration test of the real job (fresh and stale fact) |
| CSO2-13 | Folded: §3.1 `bank_transfer_filed_amount_idx`, §3.4.4 candidates driven from the line, §4.1 « À classer » from the lines, 037 P read bound. Confirmed: no index serves (account, amount) for cancelled or returned transfers (`bank_transfer_cancelled_filed_idx` is (organization, account), l.249-250) |
| CSO2-14 | Folded: §2.6 2a/2b labels (« prévenez le support », both payout and sweep named), §4.3 2c's rewording with a vitest killing 2a's words, §7.1, vitest. One review reason is kept for payout and sweep; the label names both rather than adding `unplanned_sweep_return` |
