# M2c-6b plan — debits booked from the statement, then « switch on cancellation after download »

Sources read (branch `m6a-fix6`, now on main as PR #28): ROADMAP M2c-6b block; design
`docs/design/m2c-remittances.md` §0, §5, §6.1, §7, §9.1–§9.9, §10 (« Suivi »), §11–§13, §15–§21; ADR-0014 (M2c-1 « Bank
lines booked in the funds », M2c-6a + review rounds 1–6); COMPLIANCE OQ-79/80/81; migrations `20261110120000_debits_refunds`,
`20261111090000_remittance_funds`, `20261112090000_remittance_runs`, `20261113090000`, `20261114090000`,
`20261115090000_transfers_files`; pgTAP `033`, `034`; worker `payments/debits.py`, `jobs/debits.py`; web `lib/**`.

**Precondition.** Start from `main` once M2c-6a (`m6a-fix6`) **and its round 7 (`m6a-fix7`: run guard on sent files,
refusal texts of `refund_transfer_follow`)** are merged. If round 7 changes `private.refund_transfer_follow`, the payout
rule of §2.4 below must copy its final wording. Branches `m2c6b-1`, `m2c6b-2`, `m2c6b-3`; one PR each; never `main`.
**[critic]** Round 7 is committed on `m6a-fix7` (aeafc47): `refund_transfer_follow` now also accepts a line carrying
neither an end-to-end id nor a PmtInfId while the transfer re-issues none (a CSV feed). The payout twin is §2.4 rule 3b.
Round 7's hints and texts say a payout's or the sweep's debit « ne peut pas encore être comptabilisé »; they are reworded
in **6b-1** (§4.2). Every line number below is m6a-fix6's: re-read them on main. An adversarial critique was applied to this plan; its changes are marked « [critic] ».

---

## 1. Scope and split

### 1.1 What M2c-6b must deliver (ROADMAP M2c-6b; design §21 row M2c-6; ADR-0014 « Left for M2c-6b »)
- Book from imported statements: payouts (`remittance` + `client_settlement` + booking-time cover), batch debits by
  PmtInfId, sweeps, returned payouts (+ charges on return), returned sweeps, unplanned payouts (late debit of a cancelled
  transfer, double execution), `cancelled_transfer_debited` covering batch lines (`transfer_debited_before`'s rule), runs
  sent → booked; refunds keep M2b's RFD link (a single-refund batch line linked automatically).
- I9, I19 (with payouts and sweeps), I20 `transfer_booked_once`, §15 alerts tied to these bookings.
- The client statement's « Suivi de vos reversements précédents » (§10 item 5).
- §7 worked example end to end with synthetic camt.053 **through E9 and the §7.3 variants** (see 1.3).
- Then switch `private.feature_switch` `downloaded_file_cancellation` **on by migration**, DoD: pgTAP `034` passes with
  its `todo()` lines removed (scenarios may gain bookings, never lose an assertion), `033` turned into the switch-on test,
  the switch-off texts reworded, OQ-81 closed with the founder.

### 1.2 Split (each ≤ ~2,000 lines, design §21; order 6b-1 → 6b-2 → 6b-3)
| PR | Content | Acceptance criteria |
|---|---|---|
| **6b-1** Bookings core | migration `20261116090000_debit_bookings.sql`; automatic bookings (RMT/SWP lines, batch lines, returns, charges on return, single-refund batch line), booking-time cover (`client_advance` table), runs booked, breach rows, PmtInf grouping by kind, review reasons incl. `cancelled_transfer_debited`/`transfer_debited_twice`, I19 signed, I20, new alerts; worker debit job (**[critic]** funds pass in its own transaction, §2.5); `synth camt053 --debits-of`; web labels (codes, statuses) **[critic]** + round 7's « pas encore comptabilisé » texts and SQL hints reworded (§4.2) + `m2c-reversements` screenshots retaken (mobile + desktop: « Débité » is a UI change) | pgTAP `035`; §7 example E1–E9 + §7.3 variants end to end (integration); I9/I19/I20/I13/I14 clean after each step; a double debit and a debit of a cancelled transfer are never auto-booked; Hypothesis on `decide_bookings` + ledger machine rules; 028–034 and M2b/M2c suites green (034 todo still todo); scale (§1.4) |
| **6b-2** Ops bookings, pages, « Suivi » | migration `20261117090000_transfer_line_ops.sql`: `public.book_transfer_line` (batch split, unplanned payout/sweep, manual returns), reads for pages, `remittance_statement_build` + template `releve-reversement-fr-3`; « Débits et retours », « Virements », run page, client space texts; E2E + screenshots | pgTAP `036`; E2E debit → « Débité » on run/Virements/client space; unplanned payout leaves the next run correct (no double pay); statement « Suivi » golden PDF; vitest labels sweep |
| **6b-3** Switch on | migration `20261118090000_switch_on_cancellation.sql`: SW2/SW3 fix, G1c alert, late-predecessor booking, release rules with booked runs, switch on; texts reworded; 033 inverted; OQ-81 closed | `034` with no `todo()` (DoD); `033` = switch-on test with a switch-off subtransaction keeping the round-5/6 gates killed; new mutants killed; founder answer to Q1 recorded |

Why three: 6b-1 is the money path and must be reviewed alone (M2c-6a needed 6 rounds on less); 6b-3 changes a
founder-level safety decision and needs Q1 answered — if its review drags, bookings still ship; 6b-3 needs 6b-2's ops
booking of a late debit (the exit for `cancelled_transfer_debited` once cancellations exist).

### 1.3 Left for M2c-7 or later (why)
- `private.cover_remitted_reversals()` in every reversal path + nightly `remitted_reversal_uncovered` (§13 #1–2): it
  rewrites every M2b reversal path (post_debit_links, reverse_allocation…) and deserves its own review; until then a
  remitted reversal fails closed (`LG008`) or nets (ADR-0014 M2c-1 consequence), and **no real remittance before M2c-7**
  (design §21). Hence §7 from 12/11 (A1, T1, RV-3 claw-back) is asserted in M2c-7; 6b-1's test pins today's behaviour
  and is marked to flip.
- Claw-back (`take_adv`: the prepare still passes `advances=[]`, `remittance/run.py:577`), repayment request,
  `advance_open`, write-off, client payments/refunds (`client_payment_own/_dedicated`, `client_refund_own`,
  `record_client_refund`), client status effects (L622-7, L641-9), automatic top-ups and the own-account top-up file
  (6b keeps M2c-1's manual `request_top_up` + its credit booking), full property machine, 50k close-out.
- Linking a batch line that holds several refunds (Q5); a copy of an executed file (Q3); simplifying the evidence rules
  (§3.3); bank APIs/pain.002 (design §1).

### 1.4 Scale targets (design §19; `docs/benchmarks/remittances.md`)
Debit job: 200 RMT/SWP lines ≈ 1 s; 5,000 payouts' debits (M2c-6a's 5,000-transfer file, one line each and as 1 batch
line) booked in chunks, each chunk < 60 s, total < 120 s; nightly checks with 5,000 booked transfers + 50 cancelled
< 5 s; CI `scale`: the 50k-line run end to end now ends with its payout debit booked (one line) — prepare, approve,
documents, file, **debit**; stale statistics (as 6a: reset then import), every probe keyed (ARCHITECTURE §4).

---

## 2. Data and SQL (6b-1 unless marked)

All redefinitions restate settings and grants; each header names the file it redefines from (house rule).

### 2.1 Schema
- **`public.client_advance`** (design §6.1): `id, organization_id, client_organization_id, mandate_id null, currency,
  amount_minor > 0, cause text check (cause in ('remitted_reversal','payout_overrun','double_payout')), cause_entry_id →
  ledger_entry, entry_id unique → ledger_entry, bank_transaction_id null, transfer_id null, top_up_transfer_id null,
  created_at`. Append-only (refuse_change trigger, enabled always); guard: entry is a `client_advance` entry of that
  client whose 4112 line = amount; RLS: money staff; client members with whole-client access (`private.client_whole_org_ids()`,
  §6.2). It is the `source_type 'client_advance'` the M2c-1 entry type already requires.
- **`bank_line_booking`** (M2c-1): kind check += `unplanned_sweep`, `sweep_returned`. **[critic]** Two partial unique
  indexes on `(transfer_id)`, because one index over both kinds makes a payout's return booking raise 23505:
  - `bank_line_booking_debit_uq` where kind in ('payout','sweep','top_up');
  - `bank_line_booking_return_uq` where kind in ('payout_returned','sweep_returned').

  This is I20: a transfer is booked once and returned once; the unplanned kinds may repeat. **[critic]** The `seq` check
  is widened from ≤ 100 to `integer` ≥ 1: the scale target's 5,000-member batch line needs it.
- **`bank_debit_review.reason`** check += `cancelled_transfer_debited, transfer_debited_twice, transfer_not_handed_out,
  transfer_unknown, transfer_differs, run_not_in_flight, batch_partial, batch_mixed, return_differs,
  return_before_debit` (keep `own_transfer_out` for a debit to our own IBAN without our id).
- **`remittance_deadline_breach.blocked_reason`** += `payout_returned` (Q7).
- Indexes: `bank_transfer (organization_id, debtor_bank_account_id) where status = 'cancelled' and transfer_file_id is
  not null` (the alerts' source); `bank_transaction (bank_account_id, (coalesce(original_end_to_end_id, end_to_end_id)))
  where direction='credit'` only if `bank_transaction_return_e2e_idx` cannot serve the return lookup (check the plan).
  **[critic]** Two partial indexes for the candidate scan's new branches, so stale statistics never make a chunk read
  every payer line of the servicer (read counts asserted in the scale test):
  - `bank_transaction (organization_id, booking_date, id) where direction = 'debit' and end_to_end_id is null and
    payment_info_id is not null`;
  - `… where direction = 'credit' and kind = 'return'`.
- **PmtInf grouping** (`public.generate_transfer_file`, redefined from `20261115090000`): `grp = case kind when 'payout'
  then 1 when 'refund' then 2 else 3 end` (sweep last). A batch line is then one kind: payouts, refunds or the sweep.
  Files with payouts + sweep keep `-1`/`-2` (028's assertion); refund-only files keep `-1` (030 D3, 034 G2). Only files
  mixing payouts and refunds renumber: fix PmtInf **references** in 028–034 fixtures if any fail, never an assertion's
  meaning; list each in the PR.

### 2.2 Line kinds the funds pass reads (`private.bank_booking_candidates`, redefined from `20261111090000`)
Added beside fees and top-ups:
- (a) `transfer_out` debits: an RMT/SWP id, or a debit to an own IBAN.
- (b) **batch lines**. **[critic]** Defined by direction `debit`, `end_to_end_id is null` and a `payment_info_id ~
  '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$'` naming a file of the line's own account. The kind is any of `other_debit`,
  `batch_unsplit` and `transfer_out`:
  - the parser keeps a debit entry with `Btch/NbOfTxs > 1` and no `TxDtls` as `batch_unsplit` (camt053.py l.343–352);
  - 034's fixtures make batch lines `transfer_out` with no id;
  - a one-transaction PmtInf to our own IBAN (the sweep) is `transfer_out` by IBAN;
  - 6a's evidence helpers do not read the kind.

  The PmtInf match is tried before the own-IBAN rule (a), so a sweep's batch line is never `own_transfer_out`. There is
  no classification change, so the `payments.statement.classify` parity is untouched. The fee rule never takes such a
  line.
- (c) credits `return` whose `coalesce(original_end_to_end_id, end_to_end_id) ~ '^(RMT|SWP)[0-9A-F]{12}$'`.

**[critic]** A batch line whose PmtInf holds exactly one live member, a refund, is **not** a funds candidate.
`private.debit_candidates` proposes it, with the refund request found through `transfer_file_item` → `refund_request.
transfer_id`, and the M2b pass links it. No second `post_debit_links` runs in the funds transaction (lock order, §2.5). The
`post_debit_links` refund rule then also accepts the line kind `batch_unsplit`; it refuses it today (`not_a_refund`). One row per (line, transfer fact): e2e lines → the transfer by `end_to_end_id` (unique);
batch lines → `transfer_file_item` by `pmt_inf_id` (`transfer_file_item_pmt_inf_idx`) → its file (account, status,
`download_count`) → each member held by the file (`t.transfer_file_id = i.file_id`, as 6a reads); returns → the transfer
by its original id. Facts: transfer kind/status/amount/currency/debtor account/run id/`replaces_transfer_id`; run
status/`transfer_id`/net/settlement; file status/download count; `transfer_debited_before` and `batch_debit_may_hold`
flags for cancelled members. Keyed laterals with `offset 0` only.
`private.debit_candidates` (from `20261111090000`): exclude credits whose original id is ours (RMT/SWP) — the funds
pass books them.

### 2.3 Entries per bank-line kind (design §12 table; §5.2 shapes; + debit / − credit; date = the line's booking date)
| Line | Rule | Entries (keys) | State changes |
|---|---|---|---|
| debit, e2e = RMT of transfer t | **auto** iff t payout `in_file`, its file `download_count > 0` and status downloaded/sent, same debtor account, amount and currency, its run approved/sent with `run.transfer_id = t`, no planned booking of t | `remittance` +4670[c] N / −5120[b] N (`remit:<t>`, source bank_transfer t); `client_settlement` from `run.settlement_plan` via `private.post_run_settlement(run, plan, date)` (`settle:<run>`: +4670[c] D / −4679 D ‖ +4689 D / −4111[c] Dc / −4112[c] Da ‖ +44574 v / −44571 v); then if `client_payable_balance` of (c, cur) > 0: `client_advance` cause `payout_overrun` X = that balance (`adv:payout:<t>`: +4679 X / −4670[c] X ‖ +4112[c] X / −4689 X) | booking (kind payout, transfer t, entry remit); t `booked`, `entry_id`; run `booked`, `booked_on`; breach row per positive line with `latest_execution_date` < date (on conflict do nothing); alert `payout_overrun` when X > 0 |
| debit, e2e = SWP of sweep t | auto iff t `in_file`, file downloaded/sent, same account/amount | `servicer_sweep` +4679 S / −5120[b] S ‖ +5122[own = t.creditor] S / −4689 S (`sweep:<t>`) | t booked |
| batch line (no e2e) of PmtInf P | auto iff P's file downloaded/sent, members U = in_file non-empty, **no cancelled member** (returned ones excepted), Σ U = line, U one kind; payouts: each as row 1 (all checks); sweep: row 2; **one refund alone**: M2b refund link (kind refund, method auto) through `private.post_debit_links` (`refund_transfer_follow` already accepts its own PmtInf in its current file), **[critic]** decided by the M2b pass (`debit_candidates`), never by the funds pass (§2.2, §2.5) | one entry set per member, n bookings on the line (seq 1..n) | as rows 1/2 |
| credit `return`, original id = RMT of booked t | auto iff line ≤ N | `private.ledger_reverse(t.entry_id, 'return:<line>', motif, date)` (+5120 N / −4670[c] N; the 4670 trigger inserts pending `payout_returned` +N); if line < N: `bank_fee` N − line (+4679 / −5120 ‖ +6270 / −4689, `fee:<line>`) on the same credit line | t `returned`, `return_entry_id`; run stays `booked` (settlement stays, §9.7); the run's payout account `active → returned` (blocks: `payout_account_returned`); alert `payout_returned` (P0); the hourly schedule drafts (trigger `payout_returned`, exists) |
| credit `return`, original id = SWP of booked sweep | auto iff line ≤ S | reverse `servicer_sweep` (+5120 / −4679 ‖ +4689 / −5122); difference as fee | sweep `returned`; alert `sweep_returned` (P0) |
| own_transfer_in with TOP id | auto (M2c-1, unchanged) | `servicer_top_up` | |
| RMT/SWP of a **cancelled** transfer; batch line that `batch_debit_may_hold` a cancelled member | **never auto**: review `cancelled_transfer_debited` + P0 check | ops (6b-2/6b-3, §2.6) | — |
| RMT/SWP of a booked/returned transfer; batch line whose members are all booked | never auto: `transfer_debited_twice` (P0) | ops: unplanned | — |
| id of an `ordered` transfer or one in a file never downloaded; **[critic]** a batch line whose PmtInfId is of a file never downloaded | never auto: `transfer_not_handed_out` (P0: the bank has bytes we never served) | ops unplanned (**[critic]** never « explained », §2.4 rule 5) | — |
| unknown RMT-like id / amount, account or currency differs / run not approved-sent | `transfer_unknown` / `transfer_differs` / `run_not_in_flight` | ops | — |
| batch line, Σ U ≠ line (no cancelled member) | `batch_partial` (ops split, 6b-2) | | |
| batch line of several refunds, or legacy payouts+refunds PmtInf | `batch_mixed` (not bookable in 6b, Q5) | | |
| return > N, or of a transfer still in_file | `return_differs` / `return_before_debit` | ops | |
| CHRG/FEES other_debit; loss; interest | M2c-1 as today | | |

Unplanned kinds (ops, 6b-2): **unplanned_payout** of transfer x (or of client c for a debit to c's registered payout
IBAN without our id): `remittance` +4670[c] A / −5120 A (`remit:line:<line>:<seq>`, source bank_transfer x or the
line).

- **[critic] The pending row.** `private.remittance_pending` gets one row, kind `unplanned_payout`, amount **−A**: the
  entry's own 4670 posting, as the trigger computes it for every other item. `ledger_entry_id` is that entry; the trigger
  skips `remittance` entries (design §5.5). Do not write −P:
  - the advance's own 4670 posting already queues +(A − P) through the trigger, so −P would leave A − 2P in the queue
    (I14 broken);
  - `remittance_line_insert_guard` would refuse the next run's line (amount ≠ its entry's 4670 posting);
  - P = 0 would hit `amount_minor <> 0`.

  The net in the queue is −A + (A − P) = −P.
- **The advance.** A `client_advance` with cause `double_payout` for A − P (`adv:line:<line>:<seq>`).
- **P (Q4's default).** What the late payout paid of x's cancelled run's released items still pending, **[critic]**
  whether a draft reserved them or not (an earlier « unreserved » made P = 0 and the whole A an advance, while the draft
  paid the items again). P is capped by A and by what c is owed. P = 0 for a double execution of a booked payout.
- **[critic] c's draft.** The booking itself sends c's draft back to draft in the same transaction
  (`private.remittance_back_to_draft`, `balance_changed`). Do not rely on the approval cap: it refuses only when the
  draft's gross exceeds −4670, so a client with other collections would pass it and be paid twice.
- **[critic] Returning an unplanned payout.** It is never automatic. The ops return (§2.6) reverses the unplanned
  `remittance` and its `double_payout` advance in one transaction. The advance's reversal queues `client_advance_reversal`
  −(A − P) against the `payout_returned` +A, so the net is +P: what the cancelled run's items are owed again.
- **unplanned_sweep** of sweep x, or of a debit to an own IBAN: a `servicer_sweep` (`sweep:line:<line>:<seq>`). 4679 may
  go into debit, which raises `servicer_shortfall` (exists, P0).

Shapes are already in `ledger_entry_verify` (M2c-1); `ledger_post_set` derives clients and takes allocation → remit.

### 2.4 Matching rules (exact)
1. **Own id first**: a line carrying an e2e id is matched only to the transfer owning that id (unique). A re-issue is
   never booked by its predecessor's id — the payout twin of G2 (ADR-0014 round 4/6, OQ-80 (n)) holds by construction.
2. **Batch**: a line's PmtInfId names exactly one file (`<file number>-<n>`); only that file's own items count; auto only
   with no cancelled member, all members live, Σ exact, one kind; otherwise review (never "best subset").
3. **Ops split** (6b-2, kind `payout` with transfer ids): the named transfers are members of the line's PmtInf **in their
   current file** (`transfer_file_item.pmt_inf_id` where `t.transfer_file_id = i.file_id`), all in_file, runs live, Σ =
   line, and no other subset of the PmtInf's open members makes up the line (`private.amounts_make_up`; else
   `batch_ambiguous`). A predecessor file's PmtInf, another file's or another id → `not_its_line`
   (`reissue_in_downloaded_file` when the transfer is in a downloaded or sent file, the refund rule's wording).
3b. **[critic] A reference-less line, ops only** (the payout twin of round 7's refund rule, aeafc47). The line carries
    neither an end-to-end id nor a PmtInfId: a CSV feed. Ops may book it as transfer t's `payout` part only when:
    - t re-issues none (`replaces_transfer_id` null);
    - t is `in_file` in a downloaded or sent file of the line's account;
    - the amount is t's;
    - the line's date is on or after t's execution date;
    - t's run is approved or sent.

    Never automatic. Without it, a CSV-fed account could never book a payout.
4. **Order**: lines in (booking_date, id); per chunk a transfer is taken once (`decide_bookings`' `taken` set, as top-ups);
   a second line for the same transfer → `transfer_debited_twice`; debits of a day before its credits (a same-day
   return after its debit).
5. **[critic] Never explained.** A debit line carrying our RMT/SWP id, or a PmtInfId of our files, is `not_explainable`
   in `post_debit_links`, as refund_out is today. Only a booking (or an M2b link) resolves it. Today `link_debit` kind
   `explained` is accepted on `transfer_out`, and `transfer_late_lines` would count an explained line as resolved: one
   person's motif would silence `cancelled_transfer_debited` for money that left.

### 2.5 Functions (6b-1)
- `private.bank_booking_begin` (from `20261111090000`): `_bank_booking (ord pk, bank_transaction_id, transfer_id, kind
  check in ('fee','top_up','loss','payout','sweep','payout_returned','sweep_returned','unplanned_payout',
  'unplanned_sweep'), amount_minor, client_organization_id, method, decided_by, reason, unique (bank_transaction_id,
  transfer_id))`; `_booking_review` unchanged.
- `private.post_bank_bookings` (from `20261111090000`): **lock order** (ADR-0014 M2c-6a order plus M2b's): runs of the
  transfers `FOR UPDATE` (id order) → bank accounts `FOR SHARE` → `payments:<org>` (allocation) → bank lines `FOR NO
  KEY UPDATE` → `remit:<org>` → files `FOR SHARE` → transfers `FOR UPDATE` (id order). (Top-ups move after the remit lock:
  `cancel_top_up` holds only the row, so no new cycle.) Re-check every row under the locks with the §2.3 rules; strict
  (ops) raises the first refusal, job sends refused rows to `_booking_skipped` (reason `changed`), posting refusals to
  `_booking_failed` (`posting_failed`), one bad line never stops the others (existing pattern).
  - **[critic] The order is reachable only in a fresh transaction.** Today `run_process_debits` runs the M2b pass first,
    and its `post_debit_links` takes `payments:<org>` (an xact lock) before the funds pass. The funds pass would then
    hold the allocation lock while it waits for a run row. Several writers hold that run row and then wait for the
    allocation lock: `transfer_file_download`, `cancel_remittance_run`, `request_transfer_cancellation` and
    `confirm_transfer_cancellation`. That is a deadlock.
  - **[critic] So the funds pass runs in its own transaction.** The first message runs the M2b pass and sends
    `{"type": "process_debits", "funds_after": null}`; the existing code already skips the M2b pass when that key is
    present. The funds transaction then takes `debits:<org>` and the order above.
  - **[critic] The payout accounts.** The `client_payout_account` rows a return marks `returned` are locked `FOR NO KEY
    UPDATE` right after the runs. The update applies only while the row is still `active`: a retired one stays retired,
    since the guard refuses retired → returned.
  - **[critic] Locks of every PmtInf member.** On a batch line, every member of the PmtInf, booked or not, is locked
    `FOR UPDATE` and re-read, so a concurrent cancellation of a member is seen under the lock.
  - **[critic] The fallback is per line.** When the chunk's post fails, each **line**, with all its bookings, is tried
    alone; never each row alone. A batch member alone fails completeness, which would mark every multi-booking line
    `posting_failed`.
- `private.bank_booking_post_rows` (from `20261111090000`): post remittances/sweeps/fees/reversals; per booked payout
  `post_run_settlement`, then the cover; insert bookings, `client_advance` rows, pending rows (unplanned); update
  transfers (booked/returned, entry ids), runs (booked, booked_on), payout accounts (returned), breach rows; delete the
  lines' reviews; `private.ledger_check_now()`; `set constraints bank_line_booking_complete immediate`.
  - **[critic] seq.** `seq` = the line's existing max + `row_number() over (partition by bank_transaction_id order by
    ord)`. Today's scalar `max(seq)+1` gives every booking of a line in one INSERT the same seq, so a batch line or a
    return with a fee raises 23505.
  - **[critic] The settlements are set-based.** Post the remittances first and keep their ids. Then post every booked
    run's `client_settlement` in one `ledger_post_set` call, with the `commission_settlement` rows set-based (a new
    `private.post_run_settlements(run ids, date)`, with a parity test against `post_run_settlement` on each §2.3 shape),
    then the covers. One call per run rebuilds `_lps_*` and runs `ledger_post_set` 5,000 times inside the one
    transaction that a 5,000-member batch line needs: it cannot meet < 60 s.
- `private.bank_line_booking_guard` (from `20261111090000`): per kind — payout/unplanned_payout: transfer kind payout,
  debtor = line account, entry `remittance` (source the transfer, or the line when none); sweep/unplanned_sweep: kind
  sweep, entry `servicer_sweep`; payout_returned/sweep_returned: credit `return` line, entry `reversal` reversing the
  transfer's entry; fee allowed on a credit `return` line only beside a returned booking of that line (checked at
  commit); a line linked by M2b may carry only a `loss` (as today) — the single-refund batch line is an M2b link, no
  booking.
- `private.bank_line_booking_check` (from `20261111090000`): **signed** — Σ over the line's bookings of their entries'
  5120 postings + Σ M2b links' 5120 postings = (credit ? +amount : −amount). (Today's unsigned sum fails the return
  with charges.) **[critic]** It is still one deferred row trigger, but it checks only when the row is the line's
  highest seq (a keyed max). Otherwise 5,000 bookings on one line give 5,000 checks of 5,000 rows. `post_rows` also checks
  its lines set-based before `set constraints … immediate`.
- `private.apply_bank_bookings`: ~~also posts the single-refund batch links~~ **[critic]** posts no M2b link. A
  single-refund batch line is the M2b pass's (§2.2), so `post_debit_links` never runs a second time after the
  allocation lock. Doing so would lock payment and refund rows after it, the reverse of `request_refund`.
- `private.pending_item_deadlines` (from `20261112090000`) and the prepare's facts (`jobs/remittances.py`
  `load_facts`): a `payout_returned` item takes the earliest `deadline`/`latest_execution_date` of the returned run's
  positive live lines (reversal → reversed `remittance` → source transfer → run → `remittance_line`), design §9.2.
- `private.transfer_late_lines(p_transfer uuid) returns setof uuid`: the unresolved lines (not booked, linked or
  released; **[critic]** an « explained » line is not resolved, and §2.4 rule 5 refuses explaining such lines) of the
  paying account that carry the e2e id of the transfer or of its replaces chain, or are
  batch lines that `batch_debit_may_hold` it per `transfer_debited_before`'s two branches (file superseded/rejected:
  any line; cancelled alone out of a live file: lines after `next_business_day(item.execution_date)`). Keyed as
  `transfer_debited_before`.
- `private.run_payment_checks` (from `20261112090000`, one statement, one snapshot):
  - `bank_cash_identity` (I19): `booked_lines_minor` = Σ 5120 postings of booking entries (signed), not booking amount ×
    direction;
  - new `bank_line_booked` (violation): per line, the deferred check's nightly twin;
  - new `transfer_booked_once` (I20, violation), with these rules:
    - a transfer with more than one debit booking, or more than one return booking;
    - `booked` without exactly one planned booking whose entry = `bank_transfer.entry_id`;
    - `returned` without its returned booking;
    - a run `booked` with N > 0 whose transfer is neither booked nor returned. A late-predecessor booking in 6b-3
      counts its predecessor: a cancelled x with a `payout` booking, §3.1.

    **[critic]** These rules are checked per kind. Payout, sweep and top_up go through `bank_line_booking`. A refund
    goes through its request: `refund_request.cash_out_entry_id = entry_id`, `bounce_entry_id = return_entry_id`, one
    M2b link. Refund transfers are booked and bounced by the M2b RFD link, not by `bank_line_booking`: a uniform rule
    flags every executed refund.
  - I8′, I12, I13, I14, I15, I16 unchanged (they now see real bookings).
- `private.run_transfer_checks` (from `20261115090000`), alerts: `cancelled_transfer_debited` (P0; one row per line
  returned by `transfer_late_lines` over the account's cancelled payouts/refunds/sweeps that were in a downloaded file —
  amount = line amount, subject `bank_transaction`, details {transfer_ids, kinds, run_ids, refund_request_ids,
  pmt_inf_id}); `transfer_debited_twice` (P0); `transfer_not_handed_out` (P0); `payout_returned` and `sweep_returned`
  (P0 while the returned item waits / the share is not re-swept); `payout_overrun` (an advance posted at a booking, until
  M2c-7's `advance_open`); `bank_line_unbooked` (our transfer_out/batch/return lines in review > 1 business day: an I9
  gap); `servicer_funds_unswept` (−Σ4679 > 0 > 2 business days with no sweep ordered or in a file; design §13 #8);
  `top_up_pending` (> 1 business day). `transfer_not_debited` and `remittance_payout_not_executed` stay (booked rows
  leave them by status).
- Web reads touched in 6b-1 only for codes/statuses: `public.debit_queue` (new reasons with candidates).
- **[critic] `private.run_remittance_runs_checks`.** This is the M2c-5b body (20261114090000), renamed by 6a
  (20261115090000 l.3677); the breach rows are written there, and it is redefined:
  - its `inflight_breach` writes an item's row only once the paying account's statements cover the latest execution
    date (`private.statement_covers`) without the payout's debit; before that, the alert only. The table is
    append-only and unique per item, and « paid » now means the bank's debit date, often imported a day later. Writing
    at `latest_exec < today` would leave a permanent false breach for a payout made on time;
  - `waiting_breach` sets `blocked_reason = 'payout_returned'` for a returned payout's item (Q7).
- **[critic] `public.accounting_export_entries`** (from 20261113090000). Its `source_ref` also gives:
  - the RMT/SWP id for `bank_transfer` sources;
  - the line's bank reference for `bank_transaction` sources;
  - the cause for `client_advance` sources.

  Today it resolves only invoices and runs, so the new entries would be exported with no document (R123-174).

### 2.6 Ops command (6b-2) — `public.book_transfer_line(p_idempotency_key text, p_bank_transaction_id uuid, p_kind text, p_transfer_ids uuid[], p_client_id uuid, p_reason text)`
Admin or ops manager at aal2, `command_replay`/`command_record`, reason required (≤ 2,000), `lock_timeout 2s`,
`post_bank_bookings(org, true)`. Kinds: `payout` (batch split, §2.4 rule 3), `unplanned_payout` (one payout transfer
cancelled, booked or returned, and the line carries its own id or `transfer_late_lines(x)` contains the line; or
`p_client_id` when the line's counterparty IBAN is a registered payout IBAN of that client), `unplanned_sweep` (cancelled
or booked sweep under the same rule; or no transfer when the counterparty is a registered own IBAN), `payout_returned` /
`sweep_returned` (a return the job refused: identified by ops, line ≤ amount). Refusals (`check_violation`, French
labels): `line_not_ours, already_booked, already_linked, transfer_unknown, not_its_line, reissue_in_downloaded_file,
batch_ambiguous, amount_differs, run_not_in_flight, not_cancelled_nor_booked, posting_failed (LG…)`. Not chosen:
extending `link_debit` (its 7-argument signature has no transfer list; dropping it breaks M2b callers).
- **[critic] Parts.** The signature is `(p_idempotency_key, p_bank_transaction_id, p_parts jsonb, p_expected_text text,
  p_reason text)`. `p_parts` is a list `[{kind, transfer_id | client_id, amount_text}]` summing to the line. Each part
  is checked by its own kind's rule, all in one transaction. Completeness requires a whole line to be booked at once,
  and some lines need several kinds:
  - one batch line holding a live payout and a late cancelled one: `payout` + `unplanned_payout`;
  - a re-executed booked member plus another member's first execution;
  - a payout debited with the bank's charge on the same line: `payout` + `fee`.

  With one kind per call, these lines have no exit.
- **[critic] Compare and set.** `p_expected_text` is the split the page showed, P and the advance (Q4): they depend on
  the pending queue at commit. A different split refuses `split_changed`.
- **[critic] Returns.** `payout_returned` of an unplanned payout also reverses its `double_payout` advance (§2.3). A
  `payout_returned` of a late predecessor (6b-3) reverses its `remit:<x>` entry; x stays `cancelled` (§3.1).
- **[critic] Locks.** A part that supersedes a generated file (6b-3) locks that file `FOR UPDATE`, not `FOR SHARE`.

### 2.7 Statement « Suivi » (6b-2)
`private.remittance_statement_build` (from `20261114090000`) adds `previous_payouts`: the client's earlier runs (same
currency, N > 0) whose payout state **at K** differs from what the previous statement reported — booked (`remittance`
entry posted_at ≤ K: « débité de notre compte dédié le jj/mm/aaaa »), returned (reversal posted ≤ K: « revenu impayé le
… : reproposé » when this run carries its `payout_returned` line), or still in flight (« ordonné le …, exécution demandée
le …, pas encore débité »). As of K only (ADR-0012). PDF template `releve-reversement-fr-3`; CSV unchanged (lines only);
golden PDF hash regenerated; stored statements never rebuilt.

---

## 3. Switching on cancellation after download (6b-3)

### 3.1 What makes `034`'s TODO tests pass
**SW2/SW3 (second sweep after a cancelled sweep debited late).** New `private.sweep_after_debited_cancelled(p_sweep
uuid) returns boolean`: t is a sweep `ordered|in_file`, and some sweep c of the same paying account was cancelled
**before t was created** (`c.cancelled_at < t.created_at`), was in a file downloaded at least once,
`private.transfer_debited_before(c.id)` is true, and no booking of c's late debit was decided before t was created (`not
exists bank_line_booking b where b.transfer_id = c.id and b.decided_at < t.created_at`: once ops booked c's debit, sweeps
computed afterwards are right). Then:
- `private.transfer_hold_reason`: for `kind = 'sweep'` return `cancelled_sweep_debited` when it holds (today it returns
  null for every sweep);
- `public.transfer_file_download`, generated branch: re-check `kind in ('payout','refund','sweep')` → SW3: `file_blocked`
  with a `cancelled_sweep_debited` row, `transfer_file_release(…, 'superseded')` cancels S2 (sweeps are cancelled, never
  re-queued) ✓ `f2_after = superseded`, `s2_after = cancelled`;
- downloaded/sent branch: `holds_debited_transfer` also when an in-file sweep of the file satisfies it (the elsif stays
  before `file_executed`) → SW2 ✓;
- `private.run_transfer_checks`: a `transfer_already_debited` branch for such sweeps (details kind `sweep`, status of the
  sweep) → SW2 `["sweep 12000 in_file"]` ✓;
- `private.debited_cancelled_sweeps`: drop a cancelled sweep whose late debit is booked (`unplanned_sweep` booking), so
  generation proposes sweeps again from the booked 4679.

**G1c (refused payout executed late as a batch line after its run was cancelled).**
- `cancelled_transfer_debited` (6b-1, §2.5) already covers batch lines through `transfer_late_lines` → `[164000]` ✓.
- `run_transfer_checks`' G1 branch is no longer keyed on live runs and waiting refunds: source = cancelled payouts and
  refunds that were in a file downloaded at least once (the new partial index), **with no re-issue** (`not exists x where
  x.replaces_transfer_id = t.id` — the chain's live end is alerted by the existing `in_file`/`ordered` branch; this keeps
  034 G2's exact `["refund 5000 in_file"]`), `transfer_debited_before(t)`, and `transfer_late_lines(t)` non-empty (silent
  once ops booked or explained the line). Sweeps stay in their own branch (no duplicate rows) → `["payout 164000
  cancelled"]` ✓.

**Other changes needed once the switch is on** (no 034 case, but double-payment paths):
- `private.transfer_file_release` (whole downloaded file cancelled): a payout whose run is already `booked` (late
  predecessor, below) or a refund no longer `requested` is cancelled, **not re-issued**; runs go back to `approved` only
  with a transfer ordered (exists).
- Late predecessor (`book_transfer_line` kind `payout` on cancelled x): allowed only if x's run is approved/sent, its live
  transfer y replaces x (chain) and y is **not** in a downloaded or sent file (else `reissue_in_downloaded_file` — the G2
  rule); y (ordered, or in a pending/generated file superseded first) is cancelled; the run is booked with x's debit
  (`remit:<x>`, `settle:<run>`). Otherwise ops use `unplanned_payout`; a later debit of y is then booked as the run's
  payout (the client paid twice, recovered per Q4).
  **[critic] State model, no guard changes.**
  - x stays `cancelled` with `entry_id` null: `bank_transfer_guard` keeps `cancelled` terminal, and
    `bank_transfer_booked` / `bank_transfer_cancelled` forbid an entry on a cancelled transfer.
  - x's debit is recorded only by its `payout` booking. Its entry is `remit:<x>`, with source bank_transfer x.
  - The run is `booked`, and `run.transfer_id` stays y, cancelled: `remittance_run_guard` lets it move only to a
    re-issue.
  - Every reader of « t is booked » takes a cancelled transfer with a `payout` booking and no return booking as booked:
    I20, the pages (« Débité — virement annulé, exécuté en retard »), `pending_item_deadlines`, the « Suivi ».
  - A return of x is never automatic. Ops book it as `payout_returned` (§2.6), and x stays cancelled.
  - The live end of the chain is never handed out, but an intermediate re-issue may have been (in a downloaded file
    cancelled since). Its own late debit is then `cancelled_transfer_debited` → unplanned.
  - pgTAP 038: that return; I20 clean; the mutant « exemption removed » is killed.
- Switch: last statement of the migration `update private.feature_switch set enabled = true, note = 'M2c-6b: debits
  booked from the statements (ADR-0014 M2c-6b)' where key = 'downloaded_file_cancellation';` (no public writer; switching
  off again = a one-line forward migration, documented in ADR).

**[integration of M2c-6a]** A fourth prerequisite was added at M2c-6a's merge: **H-PAY** (`034`, todo). A first refund's
downloaded file cancelled whole, that refund cancelled, a second refund of the same payment (re-issuing none) in a
downloaded file: the old file's late reference-less line must not execute the second refund. Round 7's reference-less
rule (« re-issues none ») must also look for an earlier transfer of the payment — or, coarser, of the account — in a
downloaded file cancelled since (the round-7 verifier's candidate). Also new at merge: `transfer_file_download` refuses
`file_executed` while one of the file's transfers is booked or returned (N5).

### 3.2 Tests for the switch
- `034`: remove the three `todo()` lines; scenarios may add bookings (e.g. run the funds booking on G1c's first
  statement: the sweep's batch line books, Lilas' 419 840 line stays `batch_partial`); every assertion kept.
- `033` → switch-on test: with the switch as the migration leaves it (on), the five commands follow the evidence rules
  (refuse without evidence, act with it and four eyes, nothing changed on refusal); a subtransaction turns it off and
  re-asserts every round-5/6 gate (`bank_booking_required` ×5, both guards, run guard as postgres and service_role,
  `payout_in_downloaded_file`, `in_downloaded_file`), so the 26 round-5/6 mutants stay killed; `file_executed` and G2's
  refund rule asserted both ways.
- New `038_switch_on_followups`: late predecessor booking (allowed, `reissue_in_downloaded_file`), release with a booked
  run, sweep proposals resume after an `unplanned_sweep` booking, S3 created after that booking not held.
  **[critic]** It also covers:
  - the return of a late predecessor;
  - one batch line booked as `payout` + `unplanned_payout` parts (§2.6);
  - G1c's 583 840 variant: Lilas live and Martin late in one line.
- **[critic] 028–032 still switch it on in their own transaction.** If 6b-3's new sweep hold or the re-keyed G1 alert
  changes an outcome there, the ADR justifies the assertion's change. It is never edited silently (house rule R3).
- Mutants (each killed): SW `<` → `>`, booked-before-creation exclusion removed, sweep kind dropped from the generated
  re-check, G1 branch re-keyed on live runs, chain-end exclusion removed (034 G2 exact), switch flipped back.

### 3.3 Do booked debits simplify the evidence rules?
**No rule is removed in 6b.** The evidence decides about the *absence* of a later debit (OQ-80); bookings are positive
facts. They help in two places only: (1) a member booked by its own line is known to have left (already read as
`transfer_own_debit_seen`); (2) a batch line fully booked to other members cannot also hold this one — this would relax
`batch_debit_may_hold`/`batch_ambiguous` (fewer stuck payouts) but is a **relaxation** of a rule six review rounds
narrowed: defer until a real statement with batch lines (R5, founder #15). Also considered and not done: requiring every
debit line touching the file to be resolved before a cancellation (subsumed by D3/E2/G1 today; would force fixture
bookings across 028–032).

### 3.4 Turn it on in 6b-3? Recommendation: **yes, in 6b-3, after 6b-1 and 6b-2 are merged.**
Risk accepted: a bank executing a cancelled file after the D+1 window (OQ-80) and after its re-issue is now *detected
and booked* (P0 `cancelled_transfer_debited`, unplanned payout, held re-issue), the client overpaid and recovered (Q4),
never another client's money (`LG008` + advance cover); a refund paid twice is the servicer's loss; a sweep twice shows
as `servicer_shortfall`. Risk removed: refused payouts and never-uploaded files stuck « en cours » past R124-6's month
(CPCE-08, OQ-81). Gates kept: no real remittance before M2c-7 (§21); the bank's answer on its latest debit day for a file
dated D before the first live payout (OQ-80, founder #15).

---

## 4. Worker, web, tests, docs

### 4.1 Worker
- `payments/debits.py`: `TransferFact` (id, kind, status, amount, currency, debtor account, run status, run transfer id,
  file status, download count, pmt_inf_id, current file, debited_before, may_hold); `FundsLine` + `end_to_end_id`,
  `original_end_to_end_id`, `payment_info_id`, `facts: tuple[TransferFact, ...]`; `Booking` + `transfer_ids`, kinds of
  §2.3; `decide_booking` with §2.3/§2.4 (pure, no DB); review constants; `OWN_TRANSFER_OUT` only for own-IBAN debits.
- `jobs/debits.py` `_process_funds_lines`: group rows per line, COPY one `_bank_booking` row per (line, transfer), then
  `apply_bank_bookings`; docstring step 4 updated; chunking unchanged.
  - **[critic]** `run_process_debits` runs the funds pass in its own transaction (§2.5): the first message runs the M2b
    pass and sends `funds_after: null`.
  - **[critic]** The single-refund batch link is decided by the M2b pass (`debit_candidates` → `decide_all`), not here.
  - **[critic]** A batch line is never split across chunks: the chunk limit counts lines, not bookings.
- `jobs/remittances.py` / `remittance/run.py`: deadlines of `payout_returned` lines (§2.5).
- `synth/camt053.py` + `synth/cli.py`: `synth camt053 --debits-of <pain.001> [--mode individual|batch|partial|late|twice]
  [--return RMT…] [--charges 1500] [--fee 1200]` (design §16), from the writer's own parse (`pain001.py`), deterministic;
  pytest round-trip with the camt.053 parser. **[critic]** `--mode batch` writes the realistic shapes:
  - `Btch/PmtInfId` with `NbOfTxs > 1` and no `TxDtls`, which the parser reads `batch_unsplit`;
  - one `TxDtls` per transaction with its EndToEndId, which the parser splits into e2e lines carrying the PmtInfId.

  Both go through the real parser into the job, not hand-made rows.
- `remittance/statement.py`, `statement_pdf.py` (6b-2): « Suivi » section, template fr-3, renderer version bump.

### 4.2 Web (`apps/web/src`; regenerate `lib/database.types.ts`)
- 6b-1 (labels only): `lib/payments/debits.ts` (review reasons above, P0 order), `lib/payments/funds.ts` or the checks
  labels (new codes), `lib/remittance/transfers.ts` statuses booked « Débité le … », returned « Revenu impayé le … ».
- 6b-2: « Débits et retours » (`app/backoffice/encaissements/debits/page.tsx`, `debit-actions.tsx`): actions « Débit
  d'un reversement » (split, shows the PmtInf's members and the ambiguity refusal), « Virement hors reversement »
  (effect sheet: « 1 640,00 € déjà reçus par MARTIN SAS seront déduits de son prochain reversement ; avance de 0,00 € »),
  « Virement au compte propre », « Virement revenu »; « Virements » list and file page (booked/returned per transfer,
  the sweep booked, `servicer_funds_unswept`); run page (`reversements/[id]`): « Débité le … », « Commission réglée par
  compensation le … », overrun advance, returned banner; client space (`client/reversements`, `lib/remittance/
  documents.ts`, `client-space.ts`): « Virement débité de notre compte le … », « Virement revenu impayé le … : un
  nouveau reversement vous est proposé »; « Contrôles » labels.
- **[critic] Moved to 6b-1, the same PR as the bookings.** Round 7 (aeafc47) writes that a payout's and the sweep's
  debit « ne peut pas encore être comptabilisé ». That becomes false the day 6b-1 merges. The texts are:
  - the SQL hints of `cancel_transfer_file`, the four cancellation commands and `cancel_remittance_run` (switch-off
    branch; redefined in 6b-1 with only the hint changed, settings and grants restated, and 033's hint assertions
    updated);
  - `lib/boarding/forms.ts` (394, 446, 480, 490 on m6a-fix7);
  - `lib/remittance/credit-notes.ts` 96/99 and its test;
  - `lib/remittance/transfers.ts` (header and the payout texts).

  6b-3 keeps only the switch-on rewording.
- Texts true once payouts are booked (**[critic]** 6b-1, was 6b-2): `reversements/virements/page.tsx:263` and `lib/remittance/transfers.ts:331,
  367` (« Rien n'est comptabilisé avant le débit sur le relevé » → « Le débit est comptabilisé à l'import du relevé (sa
  référence RMT/SWP, ou la ligne groupée de son lot) »); `encaissements/debits/page.tsx:132-134`;
  `encaissements/paiements/[id]/page.tsx:156`, `refund-actions.tsx:50`; `lib/remittance/credit-notes.ts:96,99` and
  `lib/boarding/forms.ts:405,407` (« attend que son débit soit lu sur le relevé » → « … soit comptabilisé à l'import du
  relevé »; test `credit-notes.test.ts:84`).
- Texts written for the switch off, reworded for on (6b-3, the pages read `cancellation_after_download`):
  `lib/boarding/forms.ts:295,394,446,478,485,488`; `lib/remittance/transfers.ts:702,708`; `lib/payments/debits.ts:645`;
  `reversements/[id]/page.tsx:235-238`; SQL hints in the redefined functions; extend round 5's vitest sweep to the on
  variants (no « pas encore disponible », no « ne peut pas être annulé d'ici là »).
- Screenshots (mobile + desktop, `docs/screenshots/`): 6b-2 `m2c-debits-reversement`, `m2c-virement-hors-reversement`,
  `m2c-virement-debite`, `m2c-reversement-debite`, `m2c-client-reversements` (retaken), `m2-checks` (retaken); 6b-3
  `m2c-virement-telecharge` (retaken: cancellation offered), `m2c-annulation-fichier`.

### 4.3 Tests
- **pgTAP `035_debit_bookings`** (6b-1): each §2.3 row (entries, keys, dates, sources), run sent→booked + breach rows,
  cover → no `LG008`, cover removed → `LG008` (job: `posting_failed`), I20 index (second planned booking 23505), signed
  completeness (return with charges), generation PmtInf by kind, single-refund batch auto-link, every review reason,
  G2-payout (old id, predecessor PmtInf, foreign PmtInf never book the re-issue — switch on in the test transaction),
  `cancelled_transfer_debited` for an e2e and a batch line, I19/I9/I14 after bookings, `client_advance` RLS (staff,
  clients A/B, restricted viewer, collector) and 42501 on direct writes, the lock order (a second session holding the
  allocation lock: the job waits, no deadlock). **[critic]** 035 also covers:
  - a payout's return booking after its debit booking (the two I20 indexes);
  - a batch line of 3 members and a return with a fee (seq 1..n, no 23505);
  - a chunk with one refused line and one batch line: the batch line booked, the refused one `posting_failed`;
  - batch lines of kinds `batch_unsplit` and `transfer_out` (no id) booked; a sweep's batch line to the own IBAN not
    `own_transfer_out`;
  - I20 clean with executed and bounced file-mode refunds;
  - `explained` refused on an RMT line and on a batch line;
  - no in-flight breach row before the statements cover latest_exec, then on-time and late debits;
  - the payout account `returned` only when it was `active`.
- **pgTAP `036_transfer_line_ops`** (6b-2): every kind and refusal of `book_transfer_line`, idempotency/replay, unplanned
  pending item + advance split (Q4), drafts back to draft, 42501 per role. **[critic]** It also covers:
  - the split with A = P, A > P and P = 0, each followed by the next run's **approval** (the line guard and I14:
    −P instead of −A shows only when A ≠ P);
  - the items reserved by a draft still counted in P;
  - mixed parts on one line;
  - a reference-less line: booked for a non-re-issue, refused for a re-issue;
  - `split_changed`;
  - the return of an unplanned payout (its advance reversed, net +P). **`037_statement_suivi`**: the section as of K.
- **034 / 033 / 038** (6b-3, §3.2). Re-run 015, 016–027, 028–032 unchanged.
- **Hypothesis**: `test_debits.py` properties on `decide_bookings` (a transfer in at most one auto booking; auto only with
  all §2.3 conditions; any line with a cancelled member or id → review, never booked; batch auto only on exact Σ with one
  kind; deterministic under the (date, id) order). `ledger_machine.py` rules `book_payout` (remittance + settlement + cover),
  `return_payout`, `book_sweep`, `return_sweep`, `unplanned_payout`; invariants I2′, I8′, I12, I13, I19 (oracle bank),
  I20; and the oracle's −Σ4679 = settled commission not yet swept at quiescence.
- **Integration** (`worker/tests/`): `test_debit_bookings_integration.py` — §7 E1–E9 through the real jobs and the
  synthetic camt.053 of the real pain.001 (positions table rows 21/10, 03/11, 04/11 asserted; 5120 = bank; I8′ = 0),
  variants §7.3 (payout returned 05/11 → `payout_returned` item 164 000 with RV-1's deadline, account returned, draft
  proposed; return with charges; fee 30/11), batch mode, partial batch → review, double debit → `transfer_debited_twice`,
  payout overrun → advance; the 12/11 return pinned as today's behaviour (flip in M2c-7). Concurrency (two connections):
  the job vs `transfer_file_download`, `generate_transfer_file`, `cancel_remittance_run` (switch on) — one wins, no
  deadlock, no double booking. **[critic]** The job's statement also carries return or refund lines, so that the M2b
  pass takes the allocation lock first. The other side re-downloads the booked run's file, or cancels its run, holding
  that run row: today's single-transaction job deadlocks there. A `request_refund` on a payment of the single-refund
  batch line runs alongside. `test_debit_bookings_machine_integration.py`: a stateful bank model (execute file
  individually/batch/partial/late/twice, return) against Postgres; after each step every bank line is booked or in
  review, I9/I19/I20, `LG008` never raised by a booking, no transfer booked twice.
- **E2E** (`make e2e`): extend `remittances` (approve → generate → download → « Transmis » → import synthetic debits →
  job → « Débité » on run, Virements and client space; a returned payout → « Revenu impayé » + new draft) and
  `payments-debits` (an unplanned payout booked from « Débits et retours »); CI e2e already starts the payments and
  remittances queues.
- **Scale** (§1.4): extend `test_transfer_files_scale_integration.py` (5,000 debits booked, nightly checks timed,
  `pg_stat_xact_user_tables` reads bounded per transfer) and `test_remittance_scale_integration.py` (the run's debit).

### 4.4 Docs
ADR-0014 sections « M2c-6b: debits booked from the statement » (6b-1/6b-2) and « Switch on » (6b-3) with the decisions
(batch lines stay `other_debit`; PmtInf by kind; signed booking check; `book_transfer_line`; late-predecessor rule;
unplanned split of Q4); design §9.7 (switch on), §12 (annotations), §15, §21 (6b split), §10 (« Suivi » built);
COMPLIANCE CPCE-02, CPCE-08 (a refused payout no longer waits for good), SEPA-01, OQ-80 (residual after switch on),
OQ-81 closed, new OQ-82 (Q4, counsel), OQ-83 (Q5, bank), OQ-34 (refund executed after a return, Q2); DOMAIN (booking
kinds, unplanned payout, returned payout, « Suivi », advance cause); ARCHITECTURE §4 (new keyed probes), §8–9 postings;
`docs/benchmarks/remittances.md`; ROADMAP (6b-1/2/3 rows); PROGRESS at every commit.

---

## 5. Founder questions (only what the design leaves open; answer « 1 ok, 2 b … »)
1. **Switch on cancellation after download in 6b-3** (OQ-81 (a))? Default **yes**, by its migration once `034` passes;
   residual risk §3.4. ⚖️ R124-6 al. 2 (one month, CPCE-08): staying off keeps refused payouts « en cours » past the month.
2. **A refund whose RFD debit cannot be linked** (`before_previous_return`, OQ-81 (b)): default — ops book that line as
   the servicer's loss (`servicer_loss`, founder #8) by four eyes and the refund closes as executed by it.
   **[critic]** Name the entries before asking:
   - the payer's money stays in 4710 (the refund posts no cash_out), or the refund's cash_out is posted and the loss
     covers only the excess;
   - which `cash_out_entry_id` the request then carries (its trigger and the M2b position read it). ⚖️ OQ-34 (who
   bears a payer paid twice) stays open for counsel.
3. **A copy of an executed file for the records** (OQ-81 (c))? Default **no download**: the page keeps its SHA-256, items
   and download log; the bank keeps the file.
4. **Recovering an unplanned or double payout.** Default: the part that paid the cancelled run's own items still waiting is
   marked paid (a negative item — a payment, not a set-off); any excess (e.g. the bank executing a booked payout twice) is
   an advance recovered only under the claw-back clause, otherwise by a repayment request (M2c-7), as founder #7.
   (Design §9.7 nets the whole amount against the next run.) ⚖️ set-off of a restitution claim, C. civ. 1302-1, 1347,
   1348-2, OQ-38 — new COMPLIANCE OQ-82 for counsel. **[critic]** Say it plainly to the founder. The « paid » part is a
   negative item netted in c's next run, whatever that run holds; c's draft is sent back at once. Treating it as « a
   payment, not a set-off » of the exact items would mean taking those items out of the queue, which the plan does not
   build.
5. **Batch lines we cannot split** (several refunds in one line; the bank ignoring `BtchBookg false`): default — not
   bookable in 6b; ops ask the bank for the per-transaction detail, the refunds stay « en cours » (never refunded twice);
   ask the bank whether it honours `BtchBookg false` (founder #15, R5; OQ-83).
6. **Unplanned bookings**: one admin or ops manager at aal2 with a motif (the database checks the line carries that
   transfer's reference or can hold it)? Default **one person**; four eyes only for Q2's loss.
7. **A returned payout and R124-6**: default — the re-proposed item keeps its lines' deadline (§9.2), the breach row is
   recorded « bloqué : virement revenu impayé » (`blocked_reason = 'payout_returned'`) rather than a plain breach.
   ⚖️ reading of R124-6 (OQ-36) for counsel.

---

## 6. Risks and how the plan prevents them
| Risk | Prevention |
|---|---|
| Double payment: a file uploaded twice | M2c-6a's download log, warning, `file_executed`, `holds_debited_transfer` (kept, extended to sweeps in 6b-3); a second debit is `transfer_debited_twice`, never auto (I20) |
| Double payment: a cancelled file executed late (switch on) | re-issues under fresh ids (E1); own-id matching so an old id never books the re-issue (§2.4.1, G2 twin); `transfer_debited_before` holds re-issues (`already_debited`, `holds_debited_transfer`); `cancelled_transfer_debited` P0 on e2e **and batch** lines; late-predecessor booking only when the re-issue is not handed out; unplanned booking + held re-issue otherwise; recovery Q4 |
| Double sweep (SW2/SW3) | sweep held at first download and refused at re-download when created after a cancelled sweep later debited (§3.1); no sweep while such a debit is unbooked; booked sweeps only from booked settlements (§11); `servicer_shortfall` P0 |
| Batch line misattributed | auto only with all members live, none cancelled, exact Σ, one kind; ops split refused when another subset fits (`batch_ambiguous`) or the PmtInf is not the transfer's current one; PmtInf grouped by kind |
| Double booking of a line or transfer | line rows `FOR NO KEY UPDATE` + re-check under locks; keys `remit:`, `sweep:`, `settle:<run>`, `adv:payout:`, `return:`, `fee:`; `bank_transfer.entry_id` unique; `bank_line_booking_planned_uq`; signed deferred completeness check; nightly I20 and `bank_line_booked` |
| Another client's money used (overrun, unplanned) | booking-time cover advance before commit; `LG008` deferred check and `ledger_check_now()` inside the job (refused line → `posting_failed`, never a partial booking); I13 nightly |
| Next run pays again after an unplanned payout | negative pending item in the same transaction; client drafts sent back (`balance_changed`); I14 nightly |
| Stuck payout | switch on (6b-3); every unbooked line of ours in review with a P0/`bank_line_unbooked` alert; `transfer_not_debited`, `remittance_payout_not_executed`; returned payout re-proposed at once (schedule trigger) with its deadline; Q5's residual named |
| Deadlock / lock waits | one order everywhere: runs → payout accounts → bank accounts → allocation → bank lines → remit → files → transfers → invoice counter; **[critic]** the funds pass in its own transaction (the M2b pass took the allocation lock first); no second `post_debit_links` after the allocation lock; concurrency integration tests with M2b lines in the same job |
| **[critic]** Wrong queue or stuck next run after an unplanned payout | pending row −A (the entry's 4670 posting), advance +(A − P) from the trigger; 036 approves the next run with A ≠ P and P = 0 |
| **[critic]** A return booking refused, multi-booking lines failing | two I20 indexes (debit, return); seq by row_number; fallback per line; completeness checked on the line's last seq |
| **[critic]** A P0 hidden without a booking | our RMT/SWP and PmtInf lines `not_explainable`; `transfer_late_lines` ignores explanations |
| **[critic]** False R124-6 breach rows | in-flight breach written only once the statements cover latest_exec without the debit |
| Plans that depend on statistics | keyed laterals `offset 0`, `enable_seqscan = off` where 6a uses it, scale run after reset with stale stats, read counts asserted |
| Wrong VAT date | settlement dated at the debit (`post_run_settlement(…, line date)`, OQ-37 default) |
| Regressions in reviewed code (R3) | redefinitions only, copied from the named latest file; 015–034 re-run; mutants listed per PR |
