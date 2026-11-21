# M2c-7 plan — returns after remittance and close-out

Status: build plan for M2c-7, the last M2c slice (design `docs/design/m2c-remittances.md` §21 row « M2c-7 »). Nothing
here is built. It refines design §13 and §21 with what M2c-6b built; every departure says why (§1.3). Base: `1440178`
(main after PR #40, M2c-6b-3b part 3). The design says « no real remittance before M2c-7 is merged »: §8.6 says what
that gate still needs once M2c-7 is merged.

**The cancellation-after-download switch** (`private.feature_switch` `downloaded_file_cancellation`) is OFF and waits for
the founder (6b-3 plan §8 Q1, default: on). M2c-7 never writes it. Every rule below is specified, and tested, with the
switch off and on (§2.4). Tests that need it on call `private.switch_on()` inside a rolled-back test, as pgTAP 033, 034
and 039–042 do, or use the switch-on E2E project.

**Sources read** (the three inventories of this plan's workflow, and): design §0–§9.9, §10–§13, §15–§21, §23–§24; the
6b plans (`m2c-6b-plan.md` §1.3, `m2c-6b-2-plan.md` §1.2, §3.4.13, §3.6, §9, §10, `m2c-6b-3-plan.md` §2 E, §8);
`m3-calculation.md` §10 #7; COMPLIANCE CPCE-02/03/07/08, OQ-25, OQ-34…41, OQ-82, OQ-84, OQ-85; ADR-0014 (Decision,
M2c-4, M2c-5b, M2c-6b passages on advances, LG008, top-ups); PROGRESS known limits; `docs/benchmarks/remittances.md`.
Code at `1440178`: the latest definition of every function named here was found by indexing every
`create or replace function` of the 39 migrations (the last one wins). The definitions this plan redefines:

| Function | Latest definition | Lines |
|---|---|---|
| `public.reverse_allocation` | `20261109190000_payment_allocation.sql:1079` | 76 |
| `private.debit_post_rows` | `20261110120000_debits_refunds.sql:549` | 140 |
| `private.ledger_check_now` | `20261111090000_remittance_funds.sql:1335` | 10 |
| `private.document_open` | `20261112090000_remittance_runs.sql:1715` | 18 |
| `private.approve_remittance_run` | `20261114090000_manual_credit_note.sql:786` | 161 |
| `private.remittance_approval_refusal` | `20261114090000_manual_credit_note.sql:688` | 97 |
| `private.remittance_payout_blockers` | `20261115090000_transfers_files.sql:900` | 31 |
| `private.run_remittance_checks` | `20261115090000_transfers_files.sql:3710` | 11 |
| `private.remittance_statement_build` | `20261117120000_statement_suivi.sql:363` | 446 |
| `public.assign_payment`, `public.resolve_duplicate` | `20261117090000_transfer_line_foundations.sql:2097`, `:2212` | 107, 77 |
| `public.transfer_file_download` | `20261118090000_switch_on_prerequisites.sql:2296` | 159 |
| `private.transfer_line_post` | `20261118100000_switch_on_prerequisites_2.sql:2163` | 173 |
| `private.run_payment_checks` | `20261118100000_switch_on_prerequisites_2.sql:3310` | 566 |
| `private.bank_booking_post_rows` | `20261121090000_switch_on_prerequisites_4.sql:808` | 276 |
| `private.gate_assignments` | `20261109190000_payment_allocation.sql:506` | — |
| `private.payout_court_appointed`, `public.record_client_status_event`, `public.propose_payout_account` | `20261111120000_identities_terms.sql:1062`, `:1076`, `:742` | — |
| `private.bank_line_refined_kind` | `20261116090000_debit_bookings.sql:5419` | — |

House rules kept (ADR-0014): a redefinition copies the latest body whole, changes only what this plan says, restates
its settings and grants, and its header names the file and line it redefines from. Every helper that reads by key does
it whatever the statistics (`set enable_seqscan = off` on the SECURITY DEFINER helper, keyed lateral reads, `offset 0`
fences where a hash over a scan could be priced lower). Commands: SECURITY DEFINER, `has_role` (staff roles need aal2,
`private.has_role`), idempotency key + request hash (`private.command_replay` / `command_record`), compare and set on
what the page showed, `lock_timeout 2s`, lock order **row locks → allocation lock `payments:<org>` → remit lock
`remit:<org>` → invoice counter** (`private.remittance_command_locks(org, true)` takes the two advisory locks), French
refusal hints. Amounts are integer minor units, text in JSON; no float anywhere.

---

## 0. Decisions in one page

1. **« Remitted » means a live `remittance_line` in a run whose status is `booked`** (design §13 #1), whatever happened
   to its payout afterwards. A payout that came back keeps its run booked and re-queues a `payout_returned` item (+N):
   the client is owed N again, a new claim. A reversal of one of that run's lines is then covered too: netting it against
   the re-owed N would be a set-off of two claims, which the design allows only under a clause (§1.3 D1 answers the
   inventory's « booked vs paid » question).
2. **One target per reversal.** For a reversal R of an `allocation` or `forward` entry E, the cover it needs is
   T(R) = E's line amount when E has a live line in a booked run; otherwise Σ of E's live `unplanned_paid_item` rows
   (what an unplanned payout's P paid of E, OQ-82's residual, reachable only with the switch on); otherwise 0. What
   covers it is C(R) = Σ live `client_advance` rows of cause `remitted_reversal` and `cause_entry_id` = R. **Invariant
   I23: C(R) = T(R) for every reversal, at every commit** — a new deferred constraint trigger, SQLSTATE **`LG009`**,
   stronger than design §13 #2 (LG008 alone cannot see a reversal netted against the client's other collections).
3. **Covered at the reversal and at the booking.** Paths that reverse an item call `private.cover_remitted_reversals`
   in the same transaction (advance dated at the reversal's effective date). A reversal posted while its line sat in an
   approved or sent run (design §13 #3: no advance then) is covered **when that run is booked**, at the debit date, by
   `private.cover_booked_run_reversals`, before the `payout_overrun` cover (which it mostly replaces). No reversal of a
   remitted item is ever netted against the client's other collections.
4. **Claw-back** (7b) wires the advances into the settlement plan that already supports them; an advance belongs to a
   mandate (the line's for `remitted_reversal`; the payout's single mandate for the other causes, else none: repayment
   request only).
5. **Recovery without a clause** (7c): a deterministic French letter « Demande de remboursement d'avance » (no LLM,
   amounts from the ledger, not an invoice), client payments to the own account (`client_payment_own`) or the dedicated
   account (`client_payment_dedicated`), refunds of credit-note excess (`client_refund_own`); an admin write-off (7b).
6. **Client status effects** (7d): a payee confirmed after the event by a second servicer admin lifts the payout block
   for death, guardianship (tutelle), curatorship (new kind, our rule) and mandate end; set-off stops after a
   mandate-ending event and in liquidation; the opening of a proceeding is the earliest of `proceeding_opened` and
   `liquidation`, and a claim is pre-opening by the earliest date it can be said to be born (conservative default);
   claims to declare are alerted with their deadline; payments after the end are held for ops.
7. **Top-ups** (7e) are ordered automatically each hour for max(0, Σ4679 + Σ sweeps ordered or in a file − Σ top-ups
   ordered or in a file) (design §13 #4), can be filed in an own-account pain.001, and shortfall periods are logged.
8. **Close-out** (7f): the full property machine (switch off and on), the 50k close-out volume run, the nightly
   `run_payment_checks` hardened (PROGRESS known limit), and the docs (COMPLIANCE, ADR-0014 final, ARCHITECTURE §8–9).

---

## 1. Scope

### 1.1 What M2c-7 delivers (inventory item → slice)

| Inventory | What | Slice |
|---|---|---|
| D01, CRR-1, RP-1…RP-3 | `cover_remitted_reversals` in every reversal path (`reverse_allocation`, M2b returns full/partial, OQ-34 loss link), at-booking cover, LG009 | 7a |
| D02, CHK-1, LG8-1 | nightly `remitted_reversal_uncovered` (violation), I18 advance leg `advance_ledger` (violation) | 7a |
| D04 (alert), ADV-1 | `advance_open` (> 30 days, every cause) | 7a (details enriched 7b, 7c, 7d) |
| D10, RP-5, OQ-82 residual | cover of items an unplanned payout paid, released when that payout comes back | 7a |
| D18 | `private.entry_remitted` predicate and `private.remitted_cover_gap` for M3c-2 | 7a |
| D03, CLAW-1 | claw-back (`take_adv`) wired: facts, `document_open` for advances, approval re-check, mandate of an advance | 7b |
| D07, WO-1 | `write_off_advance` (admin, motif, evidence) | 7b |
| D17 (part) | chip « Avance à récupérer », page « Avances » | 7b |
| D04 (letter), REQ-1 | « Demande de remboursement d'avance » letter, command, document, client space | 7c |
| D05, PAY-1, S27 (Q13) | `record_client_payment` (own account), `book_client_payment_line` (dedicated account) | 7c |
| D06, RFD-1 | `record_client_refund` | 7c |
| D09, STAT-1, LEX-07…LEX-12, LEX-24…LEX-27 | payee after the event, set-off and claims in proceedings, mandate end | 7d |
| D08, TOP-1 | automatic top-ups, own-account file, shortfall log | 7e |
| D11, D12 (S23, S24) | S24 recognition; S23 tripwire and texts | 7e |
| D14, PROP-1 | full property machine | 7f |
| D15, SCALE-1 | 50k close-out volume run, `run_payment_checks` hardening | 7f |
| D16, TEST-PIN | pgTAP 043–047, §7 example from 12/11 end to end, pins flipped | 7a–7f |
| D19, DOCS-1, D20 | docs close-out; go-live gate recorded | each slice; 7f |

### 1.2 Left out, to whom, and why

| Item | Left to | Why |
|---|---|---|
| `reverse_servicer_entry` (fee, loss, advance reversal by admin; design §16) | a later slice, on need | Not in §21's M2c-7 row. A fee or loss moves 5120 and must hang on a bank line (`bank_line_booking`, I9); a reversal without a line breaks I9, and a booking is append-only. A refunded fee is a credit line ops book as such; a wrong booking goes to support. No M2c-7 flow needs it: an advance whose cause is undone is reversed by its own path (unplanned return, §3.2.8). |
| Line-split model for unsplit entries holding anything not ours (S21/S22 residue, D13) | the bank (OQ-83, OQ-85), founder 6b-2 Q5/Q11 | Defaults (a) keep such lines waiting for the bank's detail. Built only if the founder picks (b). |
| Net cover per M3 restatement (m3 §10 #7 (a)) | M3c-2 | No restatement exists. M2c-7 exposes `private.entry_remitted` and `private.remitted_cover_gap`; M3c-2 redefines the gap for a restatement group (§3.2.1, §8.6). |
| Payee postal address in pain.001 for non-EEA SEPA (D21, OQ-79) | the bank, counsel | Only if required. |
| Seizure served on the servicer as tiers saisi (LEX-16) | counsel, founder Q12 | Not in the design. Default: Ops row; ops retire the client's payout IBAN (blocks payouts) and call counsel. |
| Consignation at the CDC for money with no payee (LEX-24, C. civ. 1345-1) | counsel (OQ-93) | A legal exit to confirm first; breach alerts keep the money visible. |
| Letter 1345 past D-5 (design §3.1) | M4 | Template « later » in the design; no channel before M4. |
| Interest on advances or on late remittance | counsel (OQ-38, OQ-95) | C. civ. 2001 / 1996: rights or duties to confirm; none computed (design §1, founder #7). |
| Email delivery of letters, statements, invoices | M4 / M7 | No channel (design §1). Documents in the client space and by post. |
| A statement template that details each recovered advance (date, cause) | later | The fr-3 statement already prints « Remboursement d'une avance du cabinet : … » per advance settled and the claw-back clause in its header (`statement.py:392`, `:542`); the advance's own line « Avance du cabinet » appears in the run that carried it. True as is; a richer row needs `remittance_statement_build` (446 lines) for wording only. 7d redefines it anyway (mandate end) and may add the date then (§6.2.8). |

### 1.3 Departures from design §13 and §21, with why

- **D1 Booked, not paid.** Design §13 #1 says « booked »; the inventory asked whether « paid and stayed paid »
  (`private.remittance_chain_paid`) should be the key. Booked: a payout that came back re-queues its net as a new item the
  client is owed; netting a reversal of one of its lines against that item is a set-off of two claims (the servicer owes
  N again; the client owes back what was reversed). Without a claw-back clause the client is paid N and asked to repay
  the advance. The key is also simpler and stable: a booked run never returns to another status.
- **D2 Reversals of lines of approved or sent runs are covered at the booking** (design §13 #3 said « the next run nets
  it as a negative line; if the payout still goes out, the booking-time cover posts the advance »). The 6b-1 cover
  (`payout_overrun`, `bank_booking_post_rows` step 4) fires only when the client's whole 4670 would go into debit: with
  other collections pending, the payout pays the reversed item and the next run nets it against them — the silent
  compensation §13 #1 excludes. The new at-booking cover keys on each reversed line and comes first; `payout_overrun`
  stays as the backstop of LG008.
- **D3 A commit-time check (LG009), not only LG008 and the nightly.** LG008 sees only a client's whole 4670; a forgotten
  cover nets silently while other collections wait. LG009 fails the commit (or `private.ledger_check_now()` inside a
  call) whenever C(R) ≠ T(R). Cost: one deferred keyed check per reversal and per run booked (§8.3 bounds).
- **D4 OQ-82's residual is closed** (6b-2 plan §3.6.1 left it: « M2c-7's cover … keys on booked runs and will not see
  it »). With the switch on, an item a late execution's P paid and that is reversed afterwards would net against later
  collections; T(R) counts those live attributions, and the unplanned return releases the cover.
- **D5 Top-ups are ordered by an hourly job**, not inside every path that posts an advance or a fee: one place, outside
  the debit job's chunks, idempotent by its formula. Same-day target kept (hourly). `client_advance.top_up_transfer_id`
  stays null: a top-up covers the servicer's whole debit to the account (advances, fees, losses together), not one
  advance; the shortfall log records each period instead (§7.2).
- **D6 `payout_overrun` and `double_payout_open` alerts stay** beside the new `advance_open` (their SQL lives in
  `run_transfer_checks`, 404 lines, unchanged); only their texts change. `advance_open` takes every cause after 30 days.
- **D7 `servicer_shortfall` keeps its formula until 7f** (it lives in `run_payment_checks`, 566 lines, which 7f
  redefines anyway for its `enable_seqscan = off` known limit). The automatic ordering uses §13 #4's formula from 7e.
- **D8 Write-off evidence is an uploaded document** (`ledger_entry_fund_source` requires `source_type 'document'` for
  `advance_write_off`), like client events, not a generated decision record.
- **D9 After a mandate-ending event, nothing is set off** (no netting, no claw-back): the clauses are part of the mandate
  that ended (founder Q9). Design §13 #9 did not say.
- **D10 S23 gets no undo path.** Payments made of our returned transfers could only be created before 6b-1 rounds 4/8
  (2026-11-16/17); no real payout existed then (the gate), so production holds none (founder Q16 confirms). The P0 alert
  `own_transfer_payment` stays as a tripwire; the texts stop promising M2c-7.
- **D11 pgTAP numbering**: design §18's `021_returns_after_remittance` collides with `021_remittance_runs`; M2c-7 uses
  043–047 (next free after 042).

### 1.4 Split, order, size

| PR | Content | Non-test lines (est.) | Tests (est.) |
|---|---|---|---|
| **7a** Remitted reversals covered | cover functions, LG009, wiring into `reverse_allocation`, `debit_post_rows`, `bank_booking_post_rows`, `approve_remittance_run` (N = 0), `transfer_line_post` (unplanned return); nightly `remitted_reversal_uncovered`, `advance_ledger`, `advance_open`; « Couvrir »; texts | ≈ 2,000 (migration ≈ 1,550 of which ≈ 830 redefinition copy) | pgTAP 043 (≈ 50), worker integration, vitest, E2E |
| **7b** Claw-back and write-off | advances in the plan, `document_open` for advances, mandate of an advance, `write_off_advance`, page « Avances », chip | ≈ 1,200 | pgTAP 044, §7.2 RV-3 end to end, Hypothesis |
| **7c** Client settlements | `record_client_payment`, `book_client_payment_line`, `record_client_refund`, repayment request (table, command, letter, job) | ≈ 1,700 | pgTAP 045, letter goldens, §7.3 variants |
| **7d** Client status effects | payee after the event, curatorship, set-off rules in proceedings and after the end, claims to declare, payouts after a liquidation, allocation hold after the end, statement block | ≈ 1,900 (446 statement copy) | pgTAP 046, integration |
| **7e** Top-ups and our references | hourly top-ups, shortfall log, own-account file, S24 recognition, S23 texts | ≈ 1,300 | pgTAP 047, parser parity |
| **7f** Close-out | property machine (off and on), 50k close-out, `run_payment_checks` hardening + §13 #4 shortfall, docs, gate | ≈ 650 code + ≈ 900 docs | machine, scale |

Total ≈ 8,750 non-test lines (≈ 2,100 of them copied redefinitions) and ≈ 900 doc lines; ≈ 10,000 test lines.

**Order, and why.**
1. **7a first**: it closes the money hole that gates real remittances (silent netting of a remitted reversal) and
   creates the advances everything after recovers. LG009 makes every later reversal path safe by construction.
2. **7b**: the standard mandate carries the claw-back clause (§7 Martin), so most advances are recovered by it; small
   and reviewable alone; finishes §7.2 end to end.
3. **7c**: needs `advance_open` / `document_open` for advances (7b) and the in-flight refusal pattern; closes the « due
   invoice never settled » and « refund owed never paid » holes.
4. **7d**: changes the plan's set-off rules (7b) and adds refusals to 7c's commands; its legal defaults need the most
   founder and counsel answers, so it comes after the money paths it constrains.
5. **7e**: independent of 7c/7d (different files: top-ups, transfer files, the statement parser); may be built in
   parallel with 7d. Lowest money risk: manual top-ups (`request_top_up`) and `servicer_shortfall` already work.
6. **7f last**: the machine needs every rule; the 50k run times the final code; docs close M2c.

Each PR follows CLAUDE.md: plan → tests (seen failing) → code → run; mutants; review lenses; `scale` paths touched
(7a returns and bookings, 7b prepare/approval, 7f) dispatch CI on the branch before merging.

---

## 2. Shared definitions

### 2.1 Remitted, target, cover (I23)

```
remitted(E)    = the live line of item entry E (remittance_line where ledger_entry_id = E and not released;
                 remittance_line_live_uq) whose run has status 'booked'                      -- at most one row
T(R)           = for R a reversal (entry_type 'reversal') of E with E.entry_type in ('allocation', 'forward'):
                   remitted(E).amount_minor                                   if remitted(E) exists
                   Σ unplanned_paid_item.amount_minor of E whose booking_entry_id is not reversed   otherwise
                   (unplanned_paid_item ledger_entry_id index, 20261117100000:55; reversed: ledger_entry_reversed_once_uq)
                 0 for any other reversal
C(R)           = Σ client_advance.amount_minor where cause = 'remitted_reversal' and cause_entry_id = R
                 and its entry is not reversed                               (client_advance_cause_idx, 20261117100000:66)
gap(R)         = T(R) − C(R)
I23            : gap(R) = 0 for every reversal, at every commit (LG009) and every night (remitted_reversal_uncovered)
```

- remittance_line.amount_minor equals E's 4670 posting negated (its guard), so T is « the reversed 4670 amount ».
- An advance is posted for gap > 0 only. An advance is reversed (released) only when gap < 0, which happens only when an
  unplanned booking that attributed E is reversed (its return, §3.2.8) and E is in no booked run.
- Mandate of a cover advance: remitted(E).mandate_id; else the mandate of E's file
  (`portfolio.mandate_id` of E.portfolio_id, NOT NULL since M1); null for a forward on no file.
- Date: the reversal's effective date when covered at the reversal (R may be back-dated: « Désimputer » reverses at the
  allocation's own date, `reverse_allocation`; dating the advance there keeps 4670 out of debit at every date, not only
  in total); the debit date when covered at the booking.
- Keys: `adv:<R>` at the reversal; `adv:<R>:<run>` at the booking; `adv:<R>:rel:<line>` for a re-post after a release;
  `return:rr:<line>:<advance>` for a release's reversal. Derived from existing rows only (design §5.2).
- Reason (an entry the client's whole-client members read): « Encaissement déjà reversé puis annulé : avance du
  cabinet » (fixed text; ops' motif never).

### 2.2 Locks and transactions
Every path that posts a cover already holds the allocation lock (`ledger_reverse` takes it) and gets the remit lock
from `private.ledger_post_set` (4679 lines; `20261111090000`, ledger_post_set takes `remit:` for 4679 writers). Order
stays allocation → remit → counter. `reverse_allocation` (lock_timeout 2s) may now wait for the remit lock (a file
generation holds it for its duration): its refusal on timeout is « Opération en cours sur les virements : réessayez
dans un instant » (web mapping of SQLSTATE 55P03 for this command).

### 2.3 The money each slice may move (shapes are M2c-1's, `20261111090000:455-484`, unchanged)

| Entry | Lines | Posted by (slice) |
|---|---|---|
| `client_advance` (cause `remitted_reversal`) | +4679 A / −4670[c] A ‖ +4112[c] A / −4689 A | cover functions (7a) |
| its reversal (release) | the negated lines | `remitted_cover_release` (7a) |
| `client_settlement` with Da | +4670[c] D / −4679 D ‖ +4689 D / −4111[c] Dc / −4112[c] Da ‖ VAT pair | existing posters, now with advances (7b) |
| `advance_write_off` | +6780 W / −4112[c] W | `write_off_advance` (7b) |
| `client_payment_own` | +5122[own] P / −4111[c] / −4112[c] ‖ +44574 v / −44571 v | `record_client_payment` (7c) |
| `client_payment_dedicated` | +5120[b] P / −4679 P ‖ +4689 P / −4111[c] / −4112[c] ‖ VAT pair | `book_client_payment_line` (7c) |
| `client_refund_own` | +4111[c] R / −5122[own] R | `record_client_refund` (7c) |
| `servicer_top_up` | unchanged (booked from its credit) | 7e only orders it |

### 2.4 The switch, off and on
- **Off (today):** a run whose payout is in a downloaded file is never cancelled; its lines stay live and the run ends
  booked (or stays sent). `unplanned_paid_item` rows arise only from S03r (a returned payout executed again), whose
  items are `payout_returned` entries (reversals; never reversed again): T(R) via attributions is unreachable.
- **On:** a run's payout cancelled after download releases its lines (never booked: no cover); a late execution books
  an unplanned payout whose P attributes the released items (D4: their later reversal is covered, the unplanned return
  releases it); a late predecessor books its still-live run through `bank_booking_post_rows` (at-booking cover).
- No M2c-7 migration writes `private.feature_switch`. Each pgTAP file of M2c-7 runs its switch-on cases after
  `private.switch_on()` inside its own transaction (rolled back), and a guard test asserts the switch is off at the end.

---

## 3. 7a — Remitted reversals covered everywhere, and the backstop

Branch `m2c7a`. Migration `supabase/migrations/20261122090000_remitted_reversal_cover.sql` (forward-only; the timestamp
is after the last merged migration when the PR opens). Closes D01, D02, D10's residual, D18, part of D04.

### 3.1 Schema
- No new table. `client_advance` unchanged (cause `remitted_reversal` allowed since `20261116090000:146`).
- New SQLSTATE **`LG009`** « remitted reversal not covered » (Python `RemittedReversalUncoveredError` in
  `worker/src/collectoo_worker/ledger/model.py`, `ERRORS_BY_SQLSTATE`).
- Two deferrable, initially deferred constraint triggers, `enable always`:
  - `ledger_entry_remitted_cover` after insert on `public.ledger_entry` for each row
    `when (new.entry_type = 'reversal')` → `private.remitted_cover_check()`;
  - `remittance_run_booked_cover` after update on `public.remittance_run` for each row
    `when (new.status = 'booked' and old.status is distinct from 'booked')` → `private.run_booked_cover_check()`.

### 3.2 Functions

All `private.*` below: SECURITY DEFINER, `set search_path = ''`, `set enable_seqscan = off`, EXECUTE revoked from
public, anon and authenticated (granted to service_role where the worker calls them).

**3.2.1 `private.entry_remitted(p_entry_id uuid) returns table (run_id uuid, run_number text, amount_minor bigint,
mandate_id uuid, booked_on date)`** (stable). The live line of `p_entry_id` (by `remittance_line_live_uq`) joined to its
run by key, `status = 'booked'`. The predicate M3c-2 calls (m3 §10 #7 (e)).

**3.2.2 `private.remitted_cover_target(p_reversal_id uuid) returns bigint`, `private.remitted_cover_held(p_reversal_id
uuid) returns bigint`, `private.remitted_cover_gap(p_reversal_id uuid) returns bigint`** (stable): §2.1 exactly; T is
0 for a reversal of anything but an `allocation` or a `forward`. M3c-2 redefines `remitted_cover_target` for a
restatement group (net of the re-posted allocation), never the other two.

**3.2.3 `private.remitted_cover_begin()`** creates `pg_temp._rcv (n integer primary key, reversal_id uuid,
organization_id uuid, client_organization_id uuid, currency char(3), mandate_id uuid, amount_minor bigint check (> 0),
on_date date, idem_key text, advance_id uuid default gen_random_uuid())` on commit drop.
**`private.remitted_cover_post()`** posts its rows: `private.ledger_post_set_begin()`, one `client_advance` entry per row
(+4679 / −4670[c] / +4112[c] / −4689, `source_type 'client_advance'`, `source_id` = advance_id, key = idem_key,
`client_organization_id`, reason §2.1), at most 2,000 rows per `ledger_post_set` call (the transition-table bound of
`post_run_settlements`, `20261116090000:767`); then one insert of `client_advance` (`cause 'remitted_reversal'`,
`cause_entry_id` = reversal_id, `entry_id`, `mandate_id`, `currency`, `amount_minor`) for the entries created (a
replayed key creates nothing and inserts nothing). Returns the count posted.

**3.2.4 `private.cover_remitted_reversals(p_reversal_ids uuid[]) returns integer`** — at the reversal. For each distinct
id (`ledger_entry` by key, its reversed entry by key), gap > 0 → one `_rcv` row: amount gap, `on_date` = the reversal's
effective date, key `adv:<R>`, mandate §2.1. Then `remitted_cover_post()`. Set-based: one call per command or per debit
chunk, never one per row.

**3.2.5 `private.cover_booked_run_reversals(p_run_ids uuid[], p_dates date[]) returns integer`** — at the booking of
those runs. Callers book them in the same transaction, before or after this call: the amounts come from the lines, not
from the run's status. For each run, its live lines of kind `allocation` or `forward` (by the primary key prefix
`run_id`), each line's entry's reversal R by `ledger_entry_reversed_once_uq`; amount = `line.amount_minor −
remitted_cover_held(R)` when > 0; `on_date` = the run's date; key `adv:<R>:<run>`. Then `remitted_cover_post()`.

**3.2.6 `private.remitted_cover_check()`** (constraint trigger function on `ledger_entry`): for `new` (a reversal),
`gap(new.id) <> 0` → raise `LG009` « ledger: reversal % of an entry remitted to client % is not covered by an advance
(gap %) ». Also, when `new` reverses an unplanned booking (`unplanned_paid_item.booking_entry_id` =
`new.reverses_entry_id`), every item it attributed that has a reversal R must have gap(R) = 0 (the release ran).
**`private.run_booked_cover_check()`** (on `remittance_run`): any live `allocation`/`forward` line of the run whose
entry has a reversal R with gap(R) ≠ 0 → `LG009`. Both read by key.

**3.2.7 `private.ledger_check_now()`** redefined (from `20261111090000:1335`): `set constraints
public.ledger_entry_balanced, private.client_payable_in_credit, public.ledger_entry_remitted_cover,
public.remittance_run_booked_cover immediate;` then `deferred`. The debit job's per-link retry, `link_debit` (strict
mode: « debit link refused: posting_failed (LG009: …) ») and `book_transfer_line` then raise it inside their call.

**3.2.8 `private.remitted_cover_release(p_booking_entry_id uuid, p_line_id uuid, p_on date) returns integer`** —
called by `transfer_line_post` right after it reverses an unplanned booking (`ub_entry`). For each item E the booking
attributed (`unplanned_paid_item` by `booking_entry_id`) that has a reversal R with gap(R) < 0:
1. the live cover advances of R, newest first; if one has a `commission_settlement` (claw-back, payment, write-off:
   7b/7c) → raise « transfer line refused: advance_settled » (6b-2's refusal for the `double_payout` advance,
   `m2c-6b-2-plan.md` §3.4.13 rule 6; same web text);
2. `private.ledger_reverse(advance.entry_id, 'return:rr:' || p_line_id || ':' || advance.id, 'Avance du cabinet
   annulée : le virement hors reversement qui avait payé cet encaissement est revenu (relevé du JJ/MM/AAAA)', p_on)`
   until C(R) ≤ T(R);
3. if then C(R) < T(R) (several bookings attributed E), one `_rcv` row for T − C, key `adv:<R>:rel:<line>`, posted.

The advance rows stay (append-only); C(R) counts only advances whose entry is not reversed.

**3.2.9 `public.cover_remitted_reversal(p_idempotency_key text, p_reversal_id uuid, p_expected_gap_text text) returns
jsonb`** — « Couvrir » on « Contrôles » (design §17): an admin of the reversal's servicer at aal2. Replay + request
hash. Locks: `remittance_command_locks(org, true)`. Refusals (`check_violation`, « remitted cover refused: <code> »):
`nothing_to_cover` (gap = 0), `gap_changed` (gap ≠ expected), `over_covered` (gap < 0: support). Posts through
`cover_remitted_reversals(array[R])`, then `ledger_check_now()`. Returns `{advance_id, entry_id, amount_minor}`.

**3.2.10 `public.allocation_remitted(p_payment_id uuid) returns jsonb`** — read for the « Désimputer » and « Retour »
sheets: money staff of the payment's servicer (`has_role(admin, ops_manager)`); for each live `allocation`/`forward`
entry of the payment that `entry_remitted` finds: `{entry_id, account_id, run_number, booked_on, amount_minor}`.

**3.2.11 `private.run_advance_checks(p_check_run_id uuid, p_organization_id uuid, p_today date default null)`** — one
statement per check into `payment_check_result` (§3.4). **`private.run_remittance_checks`** redefined (from
`20261115090000:3710`, 11 lines) to also call it.

**3.2.12 Redefinitions** (whole copies, the change only):
- `public.reverse_allocation` (from `20261109190000:1079`): after the loop, `perform private.cover_remitted_reversals
  (v_reversals); perform private.ledger_check_now();`; its result gains `advances` (`[{advance_id, amount_minor}]`).
- `private.debit_post_rows` (from `20261110120000:549`): step 1 collects every reversal it posts (`v_revs uuid[]`), then
  `perform private.cover_remitted_reversals(v_revs)` before step 2. Its caller `private.post_debit_links` (both modes,
  then `ledger_check_now`) is unchanged: a refused link (LG009, LG008) still becomes `posting_failed` in the job's mode
  and « debit link refused » in ops' strict mode. Partial returns: M2b-6 reverses every allocation and forward of the
  payment, so each remitted one is covered in full; the part ops re-allocate later is a new item (founder Q1).
- `private.bank_booking_post_rows` (from `20261121090000:808`): between step (3) (settlements) and step (4) (overrun
  cover): `perform private.cover_booked_run_reversals(<payout rows' tr_run in ord order>, <their line_date>)`. Step (4)
  reads the balances after these covers: an overrun advance arises only for what no reversed line explains.
- `private.approve_remittance_run` (from `20261114090000:786`): in the N = 0 branch, after `post_run_settlement`:
  `perform private.cover_booked_run_reversals(array[r.id], array[v_today]);`.
- `private.transfer_line_post` (from `20261118100000:2163`): in the unplanned-return branch, after the reversal of
  `ub_entry` (and of `ub_adv_entry`): `perform private.remitted_cover_release(v_ret.ub_entry, l.id, l.booking_date);`.

No other path reverses an `allocation` or a `forward` today (`ledger_reverse`'s callers are `bank_booking_post_rows`,
`debit_post_rows`, `transfer_line_post` and `reverse_allocation`; `unassign_payment` refuses an allocated payment;
`apply_credit_note` posts `netting`, no 4670). LG009 refuses any new path that forgets (M3 re-runs, M5 chargebacks).

### 3.3 Ledger effect on the §7 example from 12/11 (design §7.2)
P1's return through the debit job, one transaction: R(E2) +200 000 4670[Martin] / −200 000 4710 at 12/11; the
`cash_out`; **A1** +200 000 4679 / −200 000 4670[Martin] ‖ +200 000 4112[Martin] / −200 000 4689 at 12/11, key
`adv:<R(E2)>`, mandate MAND-MARTIN. 4670[Martin] = −300 000 (P6 owed in full). Queue: E10 +300 000, R(E2) −200 000,
A1 +200 000. The top-up (7e; until then `request_top_up` by hand) brings 4679 back to 0. RV-3 before 7b (claw-back not
wired): gross 300 000, refund 36 000, take 54 000, N = 282 000, D = 18 000, 4112[Martin] = 200 000 open — design §7.3's
first variant. After 7b: N = 82 000, D = 218 000 (§4).

### 3.4 Nightly checks and alerts (`private.run_advance_checks`)

| Code | Severity | Subject | Rule | Stops when |
|---|---|---|---|---|
| `remitted_reversal_uncovered` | violation | `ledger_entry` (R) | gap(R) ≠ 0, over the reversals of the live `allocation`/`forward` lines of the servicer's booked runs and of the items with `unplanned_paid_item` rows; amount = gap; details `{client_id, reversed_entry_id, run_id, target, held}` | covered (« Couvrir ») |
| `advance_ledger` | violation | `client` | per (client, currency): Σ over its advances whose entry is not reversed of (amount − Σ settlements `document_kind 'advance'`) ≠ Σ 4112[c] postings (I18's advance half, design §5.4) | consistent |
| `advance_open` | alert | `client_advance` | open > 0 and created more than 30 days before today (Paris); amount = open; `oldest_days`; details `{client_id, cause, mandate_id, created_on}` (7b adds `recovery`, 7c `requested_on`, 7d leaves out pre-opening advances of clients in a proceeding) | open = 0 or its entry reversed |

Reads: the servicer's booked runs, their lines by `run_id`, each reversal by `ledger_entry_reversed_once_uq`, advances
by `client_advance_cause_idx`, settlements by `commission_settlement_document_idx`, 4112 by the few
`client_advance_receivable` accounts: one materialized CTE per input, keyed laterals (`offset 0`), as
`run_transfer_checks` does. Bounds §8.3. The existing alerts keep their SQL; their texts change (§3.7).

### 3.5 RLS and tenant isolation
No new table. New read `allocation_remitted`: money staff of the payment's servicer, « not allowed » otherwise. Cover
entries are `client_advance` entries: the client's whole-client members read them (6b policy); restricted users and
collectors do not. pgTAP 043 asserts: client A never reads B's advance; restricted viewers and collectors read none;
`authenticated` cannot execute `cover_remitted_reversals`, `cover_booked_run_reversals`, `remitted_cover_release`,
`remitted_cover_post`, nor insert into `client_advance`.

### 3.6 Worker
- `ledger/model.py`: `RemittedReversalUncoveredError` (LG009).
- `jobs/debits.py`: a link refused LG009 is `posting_failed`, as LG008 (the SQL sends it to review with its detail).
- The prepare is unchanged: advance items already exist (`client_advance`, basis 0, no deadline, design §9.2).

### 3.7 Web (French copy)
- `lib/payments/debits.ts` CHECK_LABEL:
  - `remitted_reversal_uncovered`: « Annulation d'un encaissement déjà reversé sans avance du cabinet » / « Un
    encaissement déjà versé au client a été annulé sans que le cabinet en fasse l'avance : la somme serait déduite des
    autres encaissements du client, une compensation qu'aucune clause ne permet. « Couvrir » enregistre l'avance. »
  - `advance_ledger`: « Avances du cabinet ≠ compte des avances » / « Pour ce client, les avances non récupérées ne
    valent pas le solde du compte des avances à récupérer (I18). »
  - `advance_open`: « Avance du cabinet non récupérée depuis plus de 30 jours » / « Le cabinet a avancé cette somme au
    client (encaissement repris après reversement, reversement au-delà du dû, virement hors reversement). Elle n'est pas
    encore récupérée. » (7b and 7c add how it is recovered.)
  - `payout_overrun` help: « Un reversement débité dépassait ce qui restait dû au client : le cabinet lui a avancé la
    différence. »; `double_payout_open` help: « Avance du cabinet après un virement exécuté hors reversement. » (« ce
    recouvrement n'est pas encore géré » goes; 7b adds the recovery sentence.)
- LG009 in the error mappers (`lib/payments/transfer-lines.ts` `transferLineErrorCode`, the debit-link mapper):
  « L'encaissement avait déjà été reversé au client : l'avance du cabinet n'a pas pu être enregistrée. Réessayez ; si
  cela continue, prévenez le support. » 55P03 on « Désimputer »: « Opération en cours sur les virements : réessayez dans
  un instant. »
- « Désimputer » sheet, when `allocation_remitted` lists the entry: « Déjà reversé au client (reversement RV-…, débité le
  JJ/MM/AAAA). En désimputant, le cabinet lui en fait l'avance (X €) : la somme n'est pas déduite de ses autres
  encaissements. Elle sera récupérée selon son mandat. » Toast: « Imputation annulée ; avance du cabinet de X €
  enregistrée. »
- « Débits et retours », a return of such a payment: « Paiement déjà reversé au client (RV-…) : au retour, le cabinet lui
  avance X €. »
- « Contrôles »: « Couvrir » on `remitted_reversal_uncovered` (admins): « Enregistrer l'avance du cabinet de X € au
  client Y pour l'annulation du JJ/MM/AAAA »; refusals `nothing_to_cover` « Rien à couvrir : l'avance existe déjà. »,
  `gap_changed` « Le montant a changé : rechargez la page. », `over_covered` « L'avance dépasse l'encaissement annulé :
  prévenez le support. »
- Screenshots (mobile + desktop): `m2c7-desimputer-deja-reverse`, `m2c7-controles-couvrir`; `m2c-controles` retaken.

### 3.8 Switch
As §2.4. With it on: the late predecessor's booking (6b-3a-2 E, through `bank_booking_post_rows`) covers its run's
reversed lines; a release (3.2.8) needs an unplanned booking, so a cancellation after download.

### 3.9 Tests (written first, seen failing)

**pgTAP `supabase/tests/043_remitted_reversal_cover.test.sql`** (≈ 50; fixtures as 035/037: a servicer, Martin and
Lilas, their mandates, runs built through `approve_remittance_run` and booked through `post_bank_bookings`):
1. `reverse_allocation` of an allocation in a booked run → one advance (cause, `cause_entry_id` = R, amount = line,
   mandate = line's, date = R's date, key `adv:<R>`); the queue holds R −A and A1 +A; the client's other pending
   items unchanged; the result lists the advance.
2. Same with nothing else pending → no LG008, no `payout_overrun`.
3. A pending (unremitted) allocation reversed → no advance; the queue nets the pair.
4. An allocation in a draft, approved or sent run reversed → no advance; its payout then booked → advance
   `adv:<R>:<run>` at the debit date; **no** `payout_overrun`; the booked-run check clean.
5. An N = 0 run with a reversed line, booked at approval → advance at the approval date.
6. An M2b return in ops' strict mode (`link_debit 'return'`) of a payment with an allocation and a forward in a booked
   run → two advances; a partial return → every remitted entry covered in full.
7. The job's mode (`apply_debit_decisions`), a chunk of three returns, one of a remitted payment → its advance, the other
   two posted; a planted raw reversal in the chunk → that link `posting_failed` (LG009).
8. « Retour au-delà du paiement » (`link_debit 'loss'`) of a remitted payment → the M2b part covered + `servicer_loss`.
9. A raw `private.ledger_reverse` of a remitted allocation → `private.ledger_check_now()` throws LG009.
10. A run set booked with a reversed line and no cover (direct update in a subtransaction) → LG009 at
    `ledger_check_now()`.
11. Switch on: a cancelled run's item attributed by an unplanned booking (P), then reversed → advance = the attribution;
    the unplanned return (`book_transfer_line … unplanned_payout_returned`) → the cover reversed (`return:rr:…`), queue
    and 4670 as without the pair; two bookings attributing one item, one returned → re-post of the remainder; a cover
    with a settlement (planted) → « transfer line refused: advance_settled », nothing booked.
12. Switch on: a late predecessor booked as its run's payout with a reversed line → at-booking cover.
13. Idempotency and roles: `reverse_allocation` replayed → one advance; `cover_remitted_reversal` on a covered reversal →
    `nothing_to_cover`; stale expected gap → `gap_changed`; an ops manager or aal1 → not allowed.
14. Nightly: every case leaves `remitted_reversal_uncovered` and `advance_ledger` empty; a planted raw reversal (inside
    the test's transaction, never committed) → one violation with its gap; a planted settlement on an advance →
    `advance_ledger`; `advance_open` with `p_today` = created + 31 → one alert, + 30 → none.
15. RLS (§3.5).
16. Pins of today's behaviour, flipped and justified in the ADR: 017 l.293–305 stays (a raw reversal of an entry in no
    run: LG008 still guards it); 037 `d_f5` and `d_ml1_signed` raw-reverse a booked run's line — each keeps its purpose
    by making the queue's negative item a reversal of a line of a run **in flight** (no cover then, §13 #3) and asserts
    the at-booking cover when that run is booked (`d_f5`: queue_before 31 000, P 31 000, advances
    `double_payout:10000` then `remitted_reversal:10000` at R2's booking, queue_end 10 000). Every other assertion of
    the suites that reverses a booked run's item raw goes through a covering path or expects LG009; none is deleted.

**Worker.** Integration `tests/test_remitted_reversal_integration.py` (db job, the real debit job, synthetic camt.053
from `synth camt053 --debits-of`): §7 from 12/11 — P1's return line → A1 in the same transaction as the return; the
positions table at 12/11 (5120 107 500 = the bank, 4679 +200 000, 4670 Martin −300 000); RV-3 prepared: gross 300 000,
N 282 000, D 18 000 (until 7b). Flip `tests/test_remittance_runs_integration.py::
test_the_worked_example_continues_a_credit_note_on_a_settled_invoice` (l.459): « without the advance » → with it (gross
300 000, refund 36 000, net 282 000), its docstring saying why. Concurrency (two connections): « Désimputer » of a
remitted allocation against `generate_transfer_file` and against the client's approval job → no deadlock, one waits, no
double cover. `tests/ledger_machine.py`: the `reverse` rule may mark an entry remitted; the oracle expects an advance
after a covering reversal and LG009 after a raw one (entry level; the full machine is 7f).

**vitest**: the three checks' labels, the two reworded helps, the LG009 and 55P03 mappings, the « Désimputer » and
return sentences (with and without remitted entries), « Couvrir » refusals. **E2E** (desktop + mobile): « Désimputer » a
remitted allocation → the sheet says it, the advance shows on the client's run page, « Contrôles » shows no violation.

**Mutants** (each killed by a named test): cover keyed on any live line, booked or not → cases 3/4; advance dated today
→ case 1; the `cover_booked_run_reversals` call removed from `bank_booking_post_rows` → case 4 and `d_f5`; from the
N = 0 branch → case 5; T counting attributions when the item is in a booked run → case 11 (item then booked); check
`gap > 0` instead of `<> 0` → case 11 (release skipped); release not called → case 11 (LG009 at the return);
`ledger_check_now` without the new constraints → cases 7, 9; the nightly's `not exists` inverted → case 14;
`advance_open` at ≥ 30 days → case 14 boundary.

### 3.10 Docs (7a)
ADR-0014 « M2c-7a » (D1–D4, LG009, the pins flipped); COMPLIANCE CPCE-02 (« Until M2c-7's advance … » replaced by the
built rule), OQ-38 (partial return default), OQ-82 (residual closed); DOMAIN « Avance de couverture » (cause
`remitted_reversal` posted), LG009; design §13 annotated « As built (7a) »; benchmarks (§8.3 rows 1–2); PROGRESS.

---

## 4. 7b — Claw-back and write-off

Branch `m2c7b`. Migration `20261123090000_advance_recovery.sql`. Closes D03, D07, part of D17.

### 4.1 Functions
**4.1.1 `private.advance_open(p_advance_id uuid) returns bigint`** (stable): 0 when the advance's entry is reversed;
else `amount_minor − Σ commission_settlement.amount_minor` (`document_kind 'advance'`, `document_id` = id; every kind:
compensation, payment_own, payment_dedicated, write_off).

**4.1.2 `private.advance_mandate(p_advance_id uuid) returns uuid`** (stable): `client_advance.mandate_id` when set
(`remitted_reversal`, 7a); for `payout_overrun` and `double_payout` with a `transfer_id`, the only `mandate_id` of the
lines (released or not) of that transfer's run when there is exactly one, else null; null for a client part with no
transfer (6b-2 S13). A null mandate is never clawed back (`settlement.py` takes nothing for `NO_MANDATE`): repayment
request only (founder Q2). No back-fill: the stack holds no advance (probe), and the helper derives the mandate.

**4.1.3 `private.advance_born_on(p_advance_id uuid) returns date`** (stable): least(the advance entry's effective date;
for `remitted_reversal`, the `booked_on` of the run that holds the reversed entry's line). 7b filters by it as invoices
are filtered by their issue date today; 7d changes the opening and the invoices' criterion (§6).

**4.1.4 `private.document_open`** redefined (from `20261112090000:1715`): when no `commission_invoice` has the id and a
`client_advance` has, `advance_open(id)`. `remittance_approval_refusal`'s `documents_changed` re-check then covers a
planned advance settle (the inventory's « stale advance settle passes » gap).

**4.1.5 `private.commission_settlement_advance_guard()`** — statement trigger after insert on
`public.commission_settlement`, `enable always`: for `document_kind 'advance'` rows, the document is a `client_advance`
of the row's client, its entry not reversed, Σ settlements ≤ amount (« commission settlement: an advance settled beyond
its amount »). Defence in depth for every poster (run settlements, 7c's payments, write-offs).

**4.1.6 `public.write_off_advance(p_idempotency_key text, p_advance_id uuid, p_amount_text text, p_expected_open_text
text, p_reason text, p_evidence_document_id uuid) returns jsonb`** — « Passer en perte ». An **admin** of the advance's
servicer at aal2 (design §5.2). Replay + request hash; reason 1–2,000 characters (kept in the command record, staff
only); amount through `private.euros_to_minor`. Locks: `remittance_command_locks(org, true)`. Refusals (« advance
write-off refused: <code> »): `not_open`, `amount_exceeds_open`, `open_changed` (open ≠ expected), `in_flight` (an
approved or sent run's `settlement_plan.settles` takes this advance: its payout's debit settles it), `evidence_required`
(`private.client_document_of(evidence, client, 'advance_write_off_evidence')`), `bad_amount`. Posts
`advance_write_off` (+6780 W / −4112[c] W; `source_type 'document'`, `source_id` the evidence — D8; key
`awo:<idempotency key>`; date Paris today; reason « Avance passée en perte (décision du JJ/MM/AAAA) ») and one
`commission_settlement (document_kind 'advance', kind 'write_off', amount W, vat 0, settled_on today)`. Never reversed
(`LG003`). Returns `{entry_id, open_after_minor}`.

**4.1.7 `public.client_advances(p_organization_id uuid, p_client uuid default null, p_open_only boolean default true,
p_after jsonb default null, p_limit integer default 50) returns jsonb`** — the « Avances » page: money staff; per
advance: client, currency, cause, created_on, cause date (the reversal's or the debit's), amount, recovered by kind,
open, mandate reference, `recovery` (`clawback` when `advance_mandate` has a claw-back clause in its terms in force
today; `request` otherwise; `request_several_mandates` for a null mandate), the approved or sent run whose plan takes
it; keyset-paged by (created_at, id).

**4.1.8 `private.run_advance_checks`** redefined (from 7a): `advance_open.details.recovery`.

`ledger_entry_type` label of `advance_write_off`: « Avance passée en perte » (staff-only book; LEX-28: never « abandon »
or « remise » toward the client).

### 4.2 Worker (the prepare)
- `jobs/remittances.py` facts: `open_advances` — `select a.id, private.advance_mandate(a.id), a.cause,
  private.advance_born_on(a.id), private.advance_open(a.id) from public.client_advance a where
  a.client_organization_id = %s and a.currency = %s` (`client_advance_client_idx`), kept when open > 0; in
  `inputs_hash` (id, open, mandate; sorted).
- `remittance/run.py` `_plan`: `advances = [OpenDocument(id, mandate or NO_MANDATE, (born_on ordinal, created order),
  open, 0, nettable)]`, `nettable = opening is None or born_on >= opening`; `plan(gross, invoices, refunds, advances,
  credits, clauses)` replaces `[]` (`run.py:598`). Invoices are taken first, then advances (`settlement._takes`). Each
  advance `Settle` carries `open_before` (checked at approval through `document_open`).
- `post_run_settlement(s)` unchanged: `document_kind 'advance'`, kind `compensation`, −4112 Da (built in M2c-4/6b-1).
- Statement unchanged (§1.2); its goldens gain a run that recovers an advance.

### 4.3 Web
- `/backoffice/reversements/avances` (a tab « Avances » of Reversements): « Client · Date · Origine · Avancé · Récupéré ·
  Reste · Récupération »; origins « Paiement repris après reversement (dossier …) », « Reversement au-delà du dû »,
  « Virement hors reversement »; recovery « Reprise sur les prochains reversements (art. 7.4 du mandat) », « Demande de
  remboursement (pas de clause de reprise) », « Demande de remboursement (plusieurs mandats) »; « Reprise par RV-… en
  cours ». Action « Passer en perte » (admins).
- Sheet « Passer une avance en perte »: « Montant (€) », « Motif », « Pièce justificative »; effect « Le cabinet
  enregistre une perte de X € (compte 6780). Collectoo ne réclame plus cette somme au client (ni reprise, ni demande de
  remboursement) ; rien ne lui est envoyé : ce n'est pas une remise de dette. Irréversible. » Refusals:
  `amount_exceeds_open` « Le montant dépasse ce qui reste à récupérer (X €). », `open_changed` « L'avance a changé depuis
  l'affichage : rechargez la page. », `in_flight` « Cette avance est reprise par le reversement RV-… en cours : attendez
  son débit. », `not_open` « Cette avance est déjà récupérée. », `evidence_required` « Joignez la pièce
  justificative. », `bad_amount` « Montant invalide (en euros, deux décimales au plus). » (Founder Q5.)
- Client space `/client/reversements` (whole-client members; `client_advance` RLS already allows them): « Avances du
  cabinet à rembourser : X € » with each advance's date and origin, and « reprise sur vos prochains reversements (art. …
  du mandat) » or « une demande de remboursement vous sera adressée ».
- Reversements card chip (design §17 #1): « Avance à récupérer 2 000,00 € »; run page note (`lib/remittance/runs.ts`
  l.372–379, every cause): « Avance du cabinet du JJ/MM/AAAA (paiement repris par la banque) : 2 000,00 €, déduite de ce
  reversement par compensation (clause de reprise, art. 7.4 du mandat) » or « … à récupérer par une demande de
  remboursement (pas de clause de reprise) ».
- Texts made true: `debits.ts` `advance_open`, `payout_overrun`, `double_payout_open` gain « Avec une clause de reprise,
  elle est déduite des prochains reversements du client ; sinon elle reste à récupérer (page « Avances »). Un
  administrateur peut la passer en perte. » (7c replaces « elle reste à récupérer » by « une demande de remboursement
  lui est adressée »); `transfer-lines.ts:105-106` `advance_settled` « Cette avance a déjà été en partie récupérée : ce
  retour ne peut pas être comptabilisé dans Collectoo ; prévenez le support. »; `:490` NOT_YET_RECOVERED reworded;
  `terms.ts:246` (« reprises sur les reversements suivants ») now true.
- Screenshots: `m2c7-avances`, `m2c7-avance-perte`; `m2c-reversements`, `m2c-reversement` retaken.

### 4.4 Switch
Claw-back reads open advances whatever their cause; with the switch on, `double_payout` advances arise more often and
are recovered the same way. A return of their unplanned booking after part was clawed back stays refused
`advance_settled` (6b-2's rule, now reachable): the line waits in « Débits et retours » with `bank_line_unbooked`;
known limit, support's exit (§10 note).

### 4.5 Tests
**pgTAP `044_advance_recovery.test.sql`** (≈ 35): `advance_open` after a compensation, a write-off, a reversal;
`document_open(advance)`; `advance_mandate` (the line's; a one-mandate run; two mandates → null; client part → null);
approval sent back `documents_changed` when an advance was written off between prepare and approval; a planned advance
settle posted at the payout's debit (`commission_settlement` compensation, −4112 Da); `write_off_advance` (admin yes,
ops manager no, aal1 no; amount rules; compare and set; in flight; evidence; replay; LG003 on its reversal; I18 clean);
the settlement guard (planted over-settlement refused); `client_advances` staff only; the evidence kind's RLS.

**Worker.** Unit: `run._plan` passes advances (mandate, nettable); `inputs_hash` changes with an advance's open.
Hypothesis (extends `test_settlement.py`): the plan never takes an advance beyond its open, never one of `NO_MANDATE`,
never from another mandate's gross; N + D = gross. Integration — **§7.2 end to end from 12/11**
(`test_remitted_reversal_integration.py` continued): RV-3 N 82 000, D 218 000; E11 +82 000 4670 / −82 000 5120; E12
+218 000 4670 / −218 000 4679 ‖ +218 000 4689 / −18 000 4111 / −200 000 4112 ‖ +9 000 44574 / −9 000 44571; E13
sweep 218 000; the positions table row by row (12/11 → 18/11); the servicer fund at the end (5122 +114 864, 7060
−95 720, 44571 −19 144, 4111, 4112, 4689, 44574 = 0); Martin received 246 000. The 7a RV-3 assertions flip to these.
**vitest**: advances labels and recovery modes, write-off sheet and refusals, the chip. **E2E**: « Avances », a
write-off by an admin (mobile + desktop).
**Mutants**: advances passed as `[]` → RV-3; `nettable` ignored → proceeding case; `document_open`'s advance branch
removed → approval case; the guard's `<=` → `<` → planted case; write-off allowed to ops managers → role case.

### 4.6 Docs (7b)
ADR-0014 « M2c-7b »; COMPLIANCE OQ-38 (claw-back built: clause only, the mandate rule), new OQ-88 (write-off,
accountant); DOMAIN « Avance passée en perte », « Reprise des avances »; PROGRESS.

---

## 5. 7c — Client settlements: payments, refunds, repayment request

Branch `m2c7c`. Migration `20261124090000_client_settlements.sql`. Closes D04 (letter), D05, D06, S27 (6b-2 Q13).

### 5.1 Schema
- `public.advance_repayment_request (id, organization_id, client_organization_id, currency, number text, issue_date,
  total_minor bigint > 0, payload jsonb, payload_sha256, template_version, renderer_version null, document_id null →
  document, pdf_sha256 null, issued_by, created_at, unique (organization_id, number))`. Number `DRA-AAAA-NNNNNN`
  (unique, not gapless: design §3.2 #4), the run numbers' mechanism. Append-only but for `document_id`, `pdf_sha256`,
  `renderer_version` set once from null (`private.refuse_change`-style guard with that exception, `enable always`).
- `public.advance_repayment_request_item (request_id, advance_id, open_minor bigint > 0, primary key (request_id,
  advance_id))`, append-only; index `(advance_id)`.
- RLS on both: money staff of the servicer; the client's whole-client members (`private.client_whole_org_ids()`) read
  their own (design §6.2's rule for client documents; OQ-48). Collectors and restricted users: none. The documents read
  policy (the client-document kinds list, `20261113090000` l.1561) gains `advance_repayment_request_pdf`.
- Evidence kinds accepted by `private.client_document_of`: `client_payment_evidence`, `client_refund_evidence` (and 7b's
  `advance_write_off_evidence`): the upload action of « Événements du client » reused.

### 5.2 Functions
**5.2.1 `public.client_open_documents(p_client_organization_id uuid, p_currency char(3)) returns jsonb`** — money staff:
open invoices (number, issue_date, due_date, settlement netted/due, TTC, open, pending VAT), open advances (cause,
created_on, open, mandate, recovery), refunds owed (credit notes with `document_open` > 0), each with `in_flight_run`
(an approved or sent run whose plan settles it) and `before_opening` (§5.2.2); and the default order (§5.2.3).

**5.2.2 `private.document_before_opening(p_document_id uuid, p_on date) returns boolean`** — 7c's criterion is today's:
an invoice issued, or an advance born (`advance_born_on`), before the client's `proceeding_opened` date on or before
`p_on`. 7d redefines it (§6).

**5.2.3 `private.client_settlement_plan(p_client uuid, p_currency char(3), p_amount bigint, p_documents uuid[], p_on
date) returns table (ord int, document_kind text, document_id uuid, amount_minor bigint, vat_moved_minor bigint)`** —
pure SQL over the open documents. Named documents: in the order given, each up to its open part. None named: the
default order (not a legal rule; founder Q4, OQ-89): (1) invoices due on or before `p_on`, by (due_date, year, seq);
(2) advances by (born_on, created_at, id); (3) the other invoices by (due_date nulls last, year, seq). Credit notes are
never paid by the client. VAT moved per invoice part: R(pending × part / open), all of it when the part closes the
invoice (`settlement.vat_part`, the plan's rule). Raises `exceeds_open` when `p_amount` > Σ open considered. Its Python
twin `remittance.client_payments.plan_client_payment` (pure, `Decimal`-free: integers), property-tested for parity.

**5.2.4 `public.record_client_payment(p_idempotency_key text, p_client_organization_id uuid, p_currency char(3),
p_amount_text text, p_value_date date, p_evidence_document_id uuid, p_documents uuid[], p_expected_open_text text,
p_reason text) returns jsonb`** — « Règlement du client » received on the own account (design §7.3, §16). Admins and
ops managers at aal2. Replay + request hash. Checks and refusals (« client payment refused: <code> »): `bad_amount`
(`private.euros_to_minor`, > 0); `bad_date` (value date after today); `evidence_required`; `no_own_account`
(`servicer_billing_settings.own_bank_account_id` active, purpose `own`, same currency); `not_open` (a named document
with nothing open, or another client's); `in_flight` (a document an approved or sent run settles: wait for its debit);
`before_opening` (§5.2.2); `open_changed` (Σ open considered ≠ expected); `exceeds_open`. Locks:
`remittance_command_locks(org, true)` (the plans of approved runs are read under the locks approvals take). Posts
`client_payment_own`: +5122[own] P (the own account's ledger account) / −4111[c] Σ invoice parts / −4112[c] Σ advance
parts / +44574 v / −44571 v (VAT lines only when v > 0); `source_type 'document'`, `source_id` the evidence; key
`cpay:<idempotency key>`; date the value date (OQ-37, OQ-90); reason « Règlement du client par virement sur le compte
du cabinet (valeur JJ/MM/AAAA) ». One `commission_settlement` per part (kind `payment_own`, `vat_moved_minor`,
`settled_on` = value date). Returns `{entry_id, settled: [{document_kind, document_id, number, amount_minor,
vat_moved_minor}]}`.

**5.2.5 `public.book_client_payment_line(p_idempotency_key text, p_bank_transaction_id uuid, p_documents uuid[],
p_expected_open_text text, p_reason text) returns jsonb`** — a client's credit on the dedicated account that pays the
servicer (design §12 `client_transfer_in` → `client_payment_dedicated`; 6b-2 S27). Admins and ops managers at aal2. The
line: a credit of kind `client_transfer_in` on an active `client_funds` account of the servicer, neither linked
(`bank_debit_link`) nor booked (`bank_line_booking`), carrying no reference of ours (`private.names_our_transfer`, our
lots, a `TOP` id) — refusals `not_a_client_credit`, `line_booked`, `our_reference`; the client = the servicer's client
whose payout account carries the counterparty IBAN (`ambiguous_client` when several). The whole line is the amount;
plan and refusals as 5.2.4 (`exceeds_open`: « … le surplus resterait sur le compte dédié : prévenez le support »).
Locks: the line `for update` (the line lock both the funds pass and the M2b links take), then
`remittance_command_locks(org, true)` (4679 writer). Posts `client_payment_dedicated` (+5120[b] P / −4679 P ‖ +4689 P /
−4111 / −4112 ‖ VAT pair; `source_type 'bank_transaction'`; key `cpayd:<line>`; date the line's booking date), one
`bank_line_booking` (kind `client_payment`, the entry, amount P, method `ops`, the motif), the line's review deleted
(`client_credit`), the settlements (kind `payment_dedicated`), then `ledger_check_now()`. The servicer's share on
4679 grows by P: the next file's sweep takes it (S = −Σ4679 − sweeps in flight, unchanged). The posting guard
(`private.bank_line_booking_guard`, `20261121090000:641`) already pre-shapes this kind (inventory PAY-1): a test proves
it; any gap is a redefinition named in the PR.

**5.2.6 `public.record_client_refund(p_idempotency_key text, p_credit_note_id uuid, p_amount_text text, p_paid_on
date, p_evidence_document_id uuid, p_expected_owed_text text, p_reason text) returns jsonb`** — a credit note's excess
paid by the servicer's own transfer (design §14.1, §16; `credit_refund_owed`). Admins and ops managers at aal2. Owed =
`document_open(credit note)`. Refusals (« client refund refused: <code> »): `nothing_owed`, `amount_exceeds_owed`,
`owed_changed`, `in_flight` (an approved or sent run's plan pays it as `refund`), `bad_date`, `evidence_required`,
`no_own_account`. Locks as 5.2.4. Posts `client_refund_own` (+4111[c] R / −5122[own] R; `source_type 'document'` the
evidence; key `crfd:<idempotency key>`; date `p_paid_on`) and `commission_settlement (document_kind 'credit_note',
document_id, kind 'refund', amount R, vat 0, settled_on p_paid_on)` — `document_open` already counts it
(`20261112090000:1715`), so `credit_refund_owed` stops. Recorded after the fact on proof (founder Q7; own-account
statements are not imported, design R12).

**5.2.7 `public.request_advance_repayment(p_idempotency_key text, p_client_organization_id uuid, p_currency char(3),
p_advance_ids uuid[], p_expected_total_text text) returns jsonb`** — « Demander le remboursement » (design §7.3, §13 #5).
Admins and ops managers at aal2. Each advance of that client and currency: open (`not_open`), not in flight
(`in_flight`), not before the opening (`before_opening`), not in another request of the last 30 days
(`recently_requested`: a reminder after 30 days is a new request); total = Σ open = expected (`total_changed`); an own
account (`no_own_account`) and a complete servicer billing identity (`identity_incomplete`). Inserts the request (its
payload from `private.advance_repayment_payload(request)`: canonical jsonb, amounts as text, no payer data) and its
items; queues `{type: 'repayment_request', request_id}` on `remittances`. Returns `{request_id, number}`.
**`private.repayment_request_document_done(p_request_id uuid, p_document_id uuid, p_pdf_sha256 text, p_renderer
text)`** (worker; the stored bytes hash to it) sets the document once.

**5.2.8 `private.run_advance_checks`** redefined (from 7b): `advance_open.details.requested_on` (last request);
`repayment_request_document_missing` (alert, a request without its document after 1 hour).

### 5.3 The letter « Demande de remboursement d'avance » (template `demande-remboursement-avance-fr-1`)
Deterministic PDF (reportlab pinned, invariant mode, DejaVu Sans, no clock), SHA-256 stored; payload built in SQL; no
LLM, every amount and date from the ledger and the advances. Not an R124-4 letter (the servicer's own claim on its
mandant, LEX-03) and not an invoice (no VAT line).

```
[Bloc émetteur : dénomination, forme, capital, RCS et ville du greffe, SIREN, siège — billing_identity (R123-237/238)]
[Mandant : dénomination, adresse de facturation]
Le JJ/MM/AAAA
Objet : Demande de remboursement d'avances — référence DRA-2026-000001
Mandat : MAND-MARTIN-2026 du JJ/MM/AAAA

Madame, Monsieur,

Dans le cadre du mandat de recouvrement amiable que vous nous avez confié, nous avons avancé pour votre compte,
sur nos fonds propres, les sommes ci-dessous, afin qu'aucune somme revenant à un autre mandant ne serve à les couvrir.

Date        Origine                                                                  Avancé   Déjà remboursé  Reste dû
12/11/2026  Encaissement du 12/10/2026 (dossier F-103…), reversé le 03/11/2026        2 000,00 €        0,00 €  2 000,00 €
            (relevé RV-2026-000001), puis repris par la banque du payeur le 12/11/2026
…
Total à rembourser : 2 000,00 €

Nous vous remercions de bien vouloir nous rembourser cette somme par virement sur notre compte :
titulaire [titulaire du compte propre], IBAN [IBAN du compte propre], en indiquant la référence DRA-2026-000001.

Ce document n'est pas une facture.

Veuillez agréer, Madame, Monsieur, l'expression de nos salutations distinguées.
[Dénomination du cabinet]
```
Origins by cause (deterministic from the rows): `remitted_reversal` by its reversal's key prefix — `return:` « … puis
repris par la banque du payeur le … », `unalloc:` « … puis annulé le … (imputation corrigée) »; `payout_overrun`
« Reversement RV-… débité le … pour un montant supérieur à ce qui vous restait dû »; `double_payout` « Virement
exécuté par notre banque hors de tout reversement le … (référence RMT…), au-delà de ce qui vous restait dû ». No legal
article, no interest, no penalty, no due date, no formal notice (founder Q6; OQ-95 asks counsel: 1999 or 1302-1,
1302-3 al. 2, 1352-7, 2001). Delivery: the client space (« Documents ») and post by ops (no email before M4/M7).

### 5.4 Worker
- `remittance/client_payments.py` (pure twin of 5.2.3) and its parity test.
- `remittance/repayment_request.py`: renderer + golden; `jobs/remittances.py` handler `repayment_request` (upload to the
  `documents` bucket at `repayment-requests/<servicer>/<request>.pdf`, then `repayment_request_document_done`; a failed
  attempt removes what it uploaded, as the documents job does).

### 5.5 Web
- Client page `/backoffice/clients/[id]/reversement`, section « Ce que le client doit au cabinet » (`client_open_documents`):
  invoices, advances, refunds owed; actions « Enregistrer un règlement » (compte propre), « Demander le remboursement »
  (advances), « Enregistrer le remboursement » on a refund owed.
- Sheet « Enregistrer un règlement du client »: « Montant reçu (€) », « Date de valeur », « Preuve du virement »,
  « Documents réglés » (default « dans l'ordre : factures échues, avances, autres factures »), live effect « FC-2026-000004 :
  36,00 € réglés (dont TVA 6,00 € devenue exigible) ; avance du 12/11/2026 : 200,00 € remboursés ». Refusals in French
  per code: `exceeds_open` « Le règlement dépasse ce que le client doit sur ces documents (X €) : enregistrez au plus ce
  montant ; Collectoo n'enregistre pas le surplus, à lui rembourser. », `in_flight` « Ce document est déjà réglé par le
  reversement RV-… en cours : attendez son débit. », `before_opening` (7c text) « Document antérieur à l'ouverture de la
  procédure du client : son paiement n'est pas enregistré ; prenez l'avis de l'avocat (OQ-92). », `open_changed`,
  `no_own_account` « Aucun compte propre n'est enregistré (Paramètres › Facturation). », `evidence_required`.
- « Débits et retours », a `client_transfer_in` line: new action « Règlement d'une facture ou d'une avance du cabinet »
  beside « Paiement relayé par le client »; effect « La somme revient au cabinet : elle sera virée sur son compte
  propre avec la prochaine quote-part. » The review text `client_credit` (`debits.ts:154`) becomes « Virement reçu du
  compte de reversement d'un client : règlement d'une facture ou d'une avance du cabinet (« Règlement du client »), ou
  paiement d'un débiteur que le client relaie (il devient alors un paiement à affecter). »
- Credit-note page: « Enregistrer le remboursement » (sheet « Montant remboursé (€) », « Date du virement », « Preuve »);
  `credit_refund_owed` help (`debits.ts:1050-1053`) « … sinon, remboursez-le par virement depuis le compte propre et
  enregistrez-le (« Enregistrer le remboursement » sur l'avoir). »
- « Avances » (7b): « Demander le remboursement » (select advances of one client, sheet with the total and « La lettre
  est déposée dans l'espace du client ; imprimez-la pour un envoi postal »); column « Demandé le ».
- Client space « Documents »: « Demande de remboursement d'avances DRA-… du JJ/MM/AAAA » (download).
- Refusals (French, per code; « … refused: <code> » mapped in `lib/remittance/settlements.ts`):

  | Code | Text |
  |---|---|
  | `not_a_client_credit` | « Ce crédit ne vient pas du compte de reversement d'un client : utilisez une autre action. » |
  | `line_booked` | « Cette ligne est déjà comptabilisée. » |
  | `our_reference` | « Cette ligne porte la référence de l'un de nos virements : c'est ce virement qui revient. » |
  | `ambiguous_client` | « Cet IBAN est le compte de reversement de plusieurs clients : prévenez le support. » |
  | `not_open` | « Ce document (ou cette avance) n'a plus rien à régler. » |
  | `nothing_owed` | « Cet avoir ne doit plus rien au client. » |
  | `amount_exceeds_owed` | « Le montant dépasse ce que l'avoir doit encore au client (X €). » |
  | `owed_changed`, `open_changed`, `total_changed` | « Les montants ont changé depuis l'affichage : rechargez la page. » |
  | `in_flight` | « Déjà réglé par le reversement RV-… en cours : attendez son débit. » |
  | `recently_requested` | « Une demande a déjà été adressée pour cette avance le JJ/MM/AAAA : une relance est possible 30 jours après. » |
  | `identity_incomplete` | « L'identité de facturation du cabinet est incomplète (Paramètres › Facturation). » |
  | `bad_date` | « La date ne peut pas être dans le futur. » |
- Texts now true: `terms.ts:246-248`, `credit-notes.ts:207-211`, `invoice.py:286-291`, the advance helps (« sinon, une
  demande de remboursement lui est adressée »).
- Screenshots: `m2c7-reglement-client`, `m2c7-reglement-compte-dedie`, `m2c7-remboursement-avoir`,
  `m2c7-demande-remboursement`, `m2c7-client-documents`.

### 5.6 Switch
No dependency: these commands read approved and sent runs' plans; with the switch on, a run cancelled after download
releases its plan and its documents stop being in flight.

### 5.7 Tests
**pgTAP `045_client_settlements.test.sql`** (≈ 45): `record_client_payment` — the shape posted (each line), VAT moved
pro rata and in full on the closing part, the default order (a due invoice, an advance, a not-due invoice), a named
order, every refusal, replay and hash conflict, roles and aal2, 4111 = open invoices and 4112 = open advances after
(I18 clean); `book_client_payment_line` — kinds refused (a debtor credit, an own credit, a line carrying our RMT id),
I9/I19 clean, `bank_line_booking`, the review gone, the next file's sweep includes P; `record_client_refund` —
`credit_refund_owed` stops, partial refund, in flight; `request_advance_repayment` — items, payload (amounts as text,
no payer), `recently_requested`, RLS (client A's members read their request, B's do not, restricted none); the advance
guard of 7b refuses an over-settlement by a payment.

**Worker.** Unit: the letter's text snapshot and golden PDF hash (every origin); `plan_client_payment` vs
`client_settlement_plan` parity by Hypothesis (random documents, amounts, orders); integration — design §7.3: (i) no
claw-back clause for Martin: RV-3 N = 282 000, a request DRA for 200 000 with its PDF stored, then
`record_client_payment` 200 000 → 4112[Martin] = 0, `advance_open` silent; (ii) no netting clause: FC-1 `due`, Martin
pays it to the own account → 44574 → 44571 moved, `invoice_overdue` silent; (iii) the same payment received on the
dedicated account → `book_client_payment_line`, then swept. **vitest**: sheets, effects, refusals, the reworded texts.
**E2E**: record a client payment and a refund; the client downloads its repayment request (mobile + desktop).
**Mutants**: default order advances-first → order case; VAT moved on the open part instead of pro rata → VAT case;
`in_flight` check removed → in-flight case; the 30-day request window off by one → boundary case; `book_client_payment_line`
accepting an own credit → refused-kind case.

### 5.8 Docs (7c)
ADR-0014 « M2c-7c »; COMPLIANCE: CPCE-02 (client payments received on the dedicated account, OQ-35), CPCE-07 (a client's
payment to the servicer gets no R124-6 receipt: not a debtor payment, LEX-05 (d)), FAC-05 (refund owed paid), new OQ-89
(imputation of an undesignated client payment, C. civ. 1342-10 and 1347-4), OQ-90 (evidence of own-account payments and
refunds, VAT date), OQ-95 (letter wording); DOMAIN « Règlement du client », « Demande de remboursement d'avance »; PROGRESS.

---

## 6. 7d — Client status effects

Branch `m2c7d`. Migration `20261125090000_client_status_effects.sql`. Closes D09 and the legal inventory's LEX-07,
LEX-08 (wording), LEX-09 (liquidation), LEX-10, LEX-11, LEX-12, LEX-21, LEX-24 (tutelle payee), LEX-25, LEX-26, LEX-27.
Every rule here the law does not fix is a default with its question (§10, §11); texts never present our rule as law.

### 6.1 Schema
- `client_status_event.kind` += `curatorship` (« Curatelle ou autre mesure de protection »: a payout hold by our rule,
  no end of mandate — C. civ. 2003 names only « la tutelle des majeurs », LEX-25) and `claims_declared` (the
  declaration of the servicer's pre-opening claims, with its evidence: it ends `claims_to_declare`).
- `client_status_event.publication_date date null`, check (null, or kind in (`proceeding_opened`, `liquidation`) and
  ≥ effective_date) — the BODACC publication from which the two months of R622-24 run (LEX-11).
- `client_payout_account.kind` += `estate` (« Succession — compte du notaire ou des héritiers ») and `guardian`
  (« Tuteur »).
- `payment.review_reason` += `client_mandate_ended`.
- `private.remittance_draft` += `set_off_barred text null` (what the prepare assumed; checked at approval).
- Index `remittance_line_repricing (invoice_id) where invoice_id is not null` if absent (the invoices' birth date read).

### 6.2 Functions
**6.2.1 `public.record_client_status_event`** dropped and recreated (from `20261111120000:1076`) with
`p_publication_date date default null` last; same roles (admin, aal2); new refusals: `claims_declared_without_proceeding`,
`bad_publication_date`. Grants restated; the web caller updated in the same PR.

**6.2.2 `private.client_opening_date(p_client uuid, p_on date) returns date`** — the earliest effective date of a
`proceeding_opened` **or** `liquidation` event on or before `p_on` (LEX-07 (2): L641-3 al. 1 applies L622-7 I to
liquidation; today a client recorded only in liquidation has no opening, `jobs/remittances.py:558-560`,
`20261114090000:725-726`).

**6.2.3 `private.client_end_event(p_client uuid, p_on date)`** — the earliest `death`, `guardianship` or
`mandate_ended` event on or before `p_on` (C. civ. 2003), with its `recorded_at` (LEX-27: acts before the servicer knew
are valid; nothing is undone for them).

**6.2.4 `private.document_born_on(p_document_id uuid) returns date`** — the earliest date the claim can be said to be
born (default, OQ-92): an invoice → least(issue_date, the earliest `encaissement_date` of the lines it charges, by
`remittance_line_invoice_idx` and the repricings), a corrective invoice with no line → least(issue_date, service_from);
an advance → `advance_born_on` (7b).

**6.2.5 `private.document_before_opening`** redefined (from 7c): `document_born_on(doc) < client_opening_date(client,
p_on)`.

**6.2.6 `private.client_set_off_barred(p_client uuid, p_on date) returns text`** — `liquidation` when a liquidation is
recorded on or before `p_on` (founder Q11: nothing is set off, pre- or post-judgment, LEX-09; invoices and advances are
claimed and declared); `mandate_ended` when `client_end_event` exists (founder Q9: the netting and claw-back clauses
belonged to the mandate that ended); null otherwise. A credit note still corrects its invoice (a price correction, not
a set-off: 289 I 5).

**6.2.7 Payee after the event.** `private.payout_court_appointed` redefined (same name, callers unchanged): staff only
also for kinds `estate`, `guardian`, and for a client with a `death`, `guardianship`, `curatorship` or `mandate_ended`
event (its own users no longer confirm, reject or retire its payout accounts). `public.propose_payout_account`
redefined (from `20261111120000:742`): `p_kind` in (`client`, `court_appointed`, `estate`, `guardian`); `estate` needs a
recorded death, `guardian` a guardianship or curatorship. `private.remittance_payout_blockers` redefined (from
`20261115090000:900`): the blocking event is the latest (by `recorded_at`) of `liquidation`, `death`, `guardianship`,
`curatorship`, `mandate_ended` effective on or before `p_on`; it is lifted when the active payout account was confirmed
after that event's `recorded_at`, via `second_admin`, and is of the kind it needs — liquidation → `court_appointed`
(built), death → `estate`, guardianship → `guardian` (C. civ. 1342-2 al. 3: payment to an incapable creditor is not
valid unless it profited), curatorship → `client` or `guardian`, mandate end → `client` (re-confirmed by a second
admin). Codes unchanged (`client_status:<kind>`); `proceeding_opened` blocks nothing (L622-13 I al. 2: the contract goes
on; design §13 #9). Founder Q8, OQ-41, OQ-94.

**6.2.8 After a mandate-ending event.**
- `private.gate_assignments` redefined (from `20261109190000:506`): a payment of a file of a client with an end event
  dated on or before the payment's booking date is held `client_mandate_ended` (never allocated automatically: the
  servicer's « pouvoir de recevoir » lapsed, R124-3; LEX-02). Ops forward it to the client's confirmed payee or refund
  the payer (design §13 #9, founder Q10; OQ-93). `public.forward_payment` accepts reason `mandate_ended` for such a
  payment (redefinition: its reason list and the notification « Reversement sans imputation : paiement reçu après la fin
  du mandat »); the schedule has no forward key for it, so its commission is nil.
- The statement: `private.remittance_statement_build` redefined (from `20261117120000:363`) — payload key
  `mandate_end {kind, effective_date, payee_kind}` when an end event is effective by K; template
  `releve-reversement-fr-4` (renderer accepts fr-3 and fr-4; fr-3 statements keep their bytes) adds the block « Fin du
  mandat » (§6.4) to every statement of such a client — the « final statement » of design §13 #9 is the first of them
  (no separate run kind: later collections forwarded after the end still need statements, C. civ. 1993). While there,
  each advance settled gets its date (the §1.2 note).

**6.2.9 Proceedings.**
- `private.remittance_approval_refusal` redefined (from `20261114090000:688`): the opening read through
  `client_opening_date`; `client_status_changed` also when `client_set_off_barred` differs from the draft's
  `set_off_barred`.
- Payments out after a liquidation (LEX-12, L641-9 I « à partir de sa date »): see `payout_after_liquidation` (§6.3).

**6.2.10 `private.run_advance_checks`** redefined (from 7c): `advance_open` leaves out advances `before_opening` of a
client in a proceeding or liquidation; new checks §6.3.

### 6.3 Nightly checks and alerts

| Code | Severity | Subject | Rule | Stops when |
|---|---|---|---|---|
| `claims_to_declare` | alert (P0 in the web from 15 days before the deadline) | `client` | a client with a `proceeding_opened` or `liquidation` event and open invoices or advances born before the opening; details: opening, publication date, deadline = publication + 2 months (R622-24; « date de publication à saisir » without it), the documents and their open amounts (from the ledger) | a `claims_declared` event dated on or after the opening, or nothing pre-opening left open |
| `payout_after_liquidation` | alert (P0) | `bank_transfer` | a payout of a client in liquidation to an account that is not its confirmed `court_appointed` one, `in_file` with a requested date on or after the judgment's date, or booked with a debit on or after it; details `cancellable` = `public.cancellation_after_download()` | in file: when booked or cancelled; booked: for the 30 days after the event's recording |

The web words both, never as law beyond the read texts: « payé au client après le jugement de liquidation (ses droits
sont exercés par le liquidateur depuis sa date, art. L641-9 C. com.) ». With the switch **off** a payout in a downloaded
file cannot be cancelled in Collectoo: the text sends ops to the bank; **on**, to the two-step cancellation.

### 6.4 Worker and texts
- Facts: `proceeding_opened_on` → `client_opening_date`; each open invoice's `born_on` (`document_born_on`);
  `set_off_barred`. `run._plan`: an invoice or advance is nettable only when `set_off_barred` is null and (no opening,
  or born_on ≥ opening) — replaces `issue_date >= opening` (`run.py:562-564`; LEX-07 (1)); the comment says « règle du
  cabinet, prudence (OQ-41, OQ-92) », not L622-7's rule (LEX-07 (4)).
- Statement fr-4 block « Fin du mandat »: « Le mandat a pris fin le JJ/MM/AAAA (décès du mandant / tutelle / fin du
  mandat). Ce relevé rend compte des sommes encaissées pour votre compte. Les sommes reçues après cette date sont
  reversées sans commission, ou restituées à leurs payeurs, au cas par cas. Ce que vous devez au cabinet (factures,
  avances) figure dans la position ci-dessous ; il n'est plus déduit des reversements. Les reversements sont faits sur
  le compte confirmé de [la succession / votre tuteur / vous]. » (Recipient of the account: founder Q8, OQ-93, LEX-21.)
- Web: `terms.ts` EVENT_KIND `guardianship` « Tutelle » (was « Tutelle ou curatelle », LEX-25), `curatorship`
  « Curatelle ou autre mesure de protection (règle du cabinet) », `claims_declared` « Créances du cabinet déclarées au
  mandataire judiciaire (ou au liquidateur) »; the event form gains « Date de publication au BODACC » for proceedings;
  `runs.ts` blocker labels with their exit — « Décès du client : confirmez le compte du notaire ou des héritiers (second
  administrateur) », « Client sous tutelle : confirmez le compte du tuteur (second administrateur) », « Curatelle (règle
  du cabinet) : confirmez le compte de reversement (second administrateur) », « Mandat terminé : confirmez à nouveau le
  compte du client (second administrateur) »; the payout-account form's kinds; the paragraph of
  `clients/[id]/reversement/page.tsx:728-735` rewritten to list what the code does (blocks and their exits; no set-off
  after the end or in liquidation, règle du cabinet; pre-opening documents not set off and to declare); the payment
  review label « Reçu après la fin du mandat du client : à reverser au client (ou à son bénéficiaire) ou à restituer au
  payeur »; check labels `claims_to_declare` « Créances du cabinet à déclarer » / « Factures et avances nées avant
  l'ouverture de la procédure du client : à déclarer au mandataire judiciaire (au liquidateur en liquidation) avant le
  JJ/MM/AAAA (deux mois après la publication au BODACC, art. R622-24 C. com.). », `payout_after_liquidation` « Reversement
  au client après sa liquidation ».
- Refusals (French): `claims_declared_without_proceeding` « Aucune procédure collective n'est enregistrée pour ce
  client. »; `bad_publication_date` « La date de publication ne peut précéder le jugement ni être dans le futur. »;
  `estate_without_death` « Un compte de succession suppose un décès enregistré. »; `guardian_without_guardianship`
  « Un compte de tuteur suppose une tutelle ou une curatelle enregistrée. »; 7c's `before_opening` reworded « Créance
  née avant l'ouverture de la procédure du client (règle du cabinet : la date la plus ancienne retenue) : elle n'est ni
  compensée ni réclamée ici ; elle est à déclarer. »
- Screenshots: `m2c7-evenement-client`, `m2c7-beneficiaire-succession`, `m2c7-controles-creances-a-declarer`,
  `m2c7-paiement-apres-fin-mandat`.

### 6.5 Switch
Blockers and set-off rules do not read it. `payout_after_liquidation` words the exit by it (§6.3).

### 6.6 Tests
**pgTAP `046_client_status_effects.test.sql`** (≈ 45): per event kind, the blocker with no payee, with the wrong kind,
with a confirmation before the event, by the client's own user (refused), then lifted by the right kind confirmed after
by a second admin; curatorship blocks payouts but not the confirmation gate; a liquidation-only client has an opening;
an invoice issued after the opening for collections before it is not set off (the old criterion's mutant); an advance
born before the opening is not taken; liquidation and after-end plans set nothing off (credit notes still apply);
approval sent back `client_status_changed` when the bar changes after prepare; a payment after the end held
`client_mandate_ended`, forwarded with reason `mandate_ended` at nil commission; `claims_to_declare` with and without
publication date, the deadline, stopped by `claims_declared`; `payout_after_liquidation` in file (switch off: not
cancellable; switch on: cancellable) and booked; 7c's commands refuse `before_opening` with the new criterion;
`record_client_status_event` new refusals and replay. **Worker**: unit (`_plan` nettable rules), golden fr-4 statement,
integration (a client in proceeding between two runs; a death then the estate's account confirmed, the run approved).
**vitest**: every label and text above. **E2E**: record a death, confirm the estate's IBAN as a second admin, approve.
**Mutants**: opening from `proceeding_opened` only → liquidation case; `issue_date` criterion → born-on case; blocker
lifted by any kind → wrong-kind case; confirmation before the event accepted → timing case; gate hold off → after-end
case.

### 6.7 Docs (7d)
ADR-0014 « M2c-7d »; COMPLIANCE CPCE-03 (mandate end read by the allocation gate; payee), CPCE-08 (blocked payee, after
the end), MAND-02 (end of mandate), PROC-01 (client in proceeding), OQ-41 (connexité, C. civ. 1348-1; birth date;
payees), new OQ-91 (seizure), OQ-92 (birth of the claim), OQ-93 (after the end), OQ-94 (curatelle); design §3.1 row
2003 reworded (only revocation, renunciation, death and tutelle end the mandate; proceedings do not: L622-13 I,
L641-11-1 I) and §9.6 last bullet; DOMAIN; PROGRESS.

---

## 7. 7e — Top-ups, the own-account file, our references in CSV labels

Branch `m2c7e`. Migration `20261126090000_top_ups_and_bank_residues.sql`. Closes D08, D11, D12. May be built in
parallel with 7d (disjoint files).

### 7.1 Top-ups ordered automatically (design §13 #4)
- **`private.top_up_needed(p_org uuid, p_currency char(3)) returns bigint`** = greatest(0, Σ4679 postings of the
  servicer and currency + Σ sweeps `ordered` or `in_file` − Σ top-ups `ordered` or `in_file`). When 4679 holds the
  servicer's money awaiting the sweep (Σ4679 < 0), an advance or a fee just reduces it, with no top-up (ops critique
  #16).
- **`private.order_due_top_ups(p_org uuid default null) returns integer`** — every servicer (or one), each in its own
  exception block: per active `client_funds` account (one per currency, founder #14), under
  `remittance_command_locks(org, true)`, needed > 0 and an active own account named in `servicer_billing_settings`
  → one `bank_transfer` kind `top_up` as `request_top_up` builds it (debtor own, creditor dedicated, payee the
  servicer's legal name, `TOP…` id, `remittance_info` « APPROVISIONNEMENT COMPTE DEDIE TOP… », requested today,
  `ordered_by` null, reason « Approvisionnement automatique : le cabinet doit X € au compte dédié (avances, frais,
  pertes) »). Idempotent by its formula (an ordered top-up lowers what is needed). It never cancels an order: ops may
  have typed it at their bank already. A failure records `top_up_order_failed` (alert, next nightly).
- pg_cron `servicer-top-ups` `37 * * * *` → `select private.order_due_top_ups()` (hourly: same-day target; any amount
  above zero, founder Q3).
- **Shortfall log** (C. civ. 1996, OQ-38 « durations logged »): `private.servicer_shortfall_period (id,
  organization_id, currency, opened_at, closed_at null, peak_minor)`, updated by the hourly job: opened when Σ4679 > 0
  (the servicer owes the account: other clients' money covers it meanwhile), peak kept, closed when ≤ 0.
  `public.servicer_shortfall_periods(p_organization_id uuid, p_limit integer default 50)` (money staff) lists them with
  the advances, fees and losses posted inside each.
- Nightly (`run_advance_checks` redefined): `top_up_account_missing` (alert) when needed > 0 and no own account.
  `servicer_shortfall` keeps its formula until 7f (D7); the web ranks it and `top_up_pending` P0.

### 7.2 The own-account top-up file
- **`public.generate_top_up_file(p_idempotency_key text, p_own_bank_account_id uuid) returns jsonb`** — admins and ops
  managers at aal2; an active own account in EUR (`not_an_own_account`, `not_eur`); one live top-up file per own account
  (a generated one not downloaded is superseded, new MsgId); its items: every `ordered` top-up of that debtor
  (`nothing_to_file`); ReqdExctnDt today before the account's cut-off (`servicer_billing_settings.bank_cutoff`), else the
  next business day; **no cash check** (the own account's statements are not imported, design R12), no sweep, no
  per-client cap. The existing `transfer_file {file}` job writes it (Dbtr = the own account; the writer takes the
  debtor from the file). Lock order: the account row, `remittance_command_locks`, then files and transfers.
- **`public.transfer_file_download`** redefined (from `20261118090000:2296`): a file whose debtor is an own account skips
  the cash and sweep re-checks; the hash check, the download log, the second-download warning and `file_executed` (a
  credit of one of its `TOP` ids seen) stay.
- **`public.cancel_top_up_file(p_idempotency_key text, p_file_id uuid, p_reason text)`** — before or after download,
  **whatever the switch**: a top-up executed after its cancellation only adds the servicer's own money to the dedicated
  account (booked as an own credit with no order, then swept back); no client is paid twice, which is what the switch
  guards. Its top-ups not booked → cancelled; the file superseded or rejected; the next hourly order re-orders what is
  still needed. Refusal `nothing_to_cancel`.
- Founder Q14: build it, unless the servicer's bank takes no file on the own account (then ops keep typing the `TOP` id).

### 7.3 Our references in a CSV label (S24) and S23
- **S24** (`m2c-6b-2-plan.md` §1.1, OQ-84 (e)/(h)): `payments.statement.refine_kind` (Python) and its SQL twin
  `private.bank_line_refined_kind` (redefined from `20261116090000:5419`) read, on a **CSV** line whose end-to-end
  column is empty or absent, a whole token `^(RMT|SWP|TOP)[0-9A-F]{12}$` in the label as a candidate reference; the SQL
  ingest keeps it only when it is the `end_to_end_id` of a transfer of that bank account (`bank_transfer.end_to_end_id`
  is unique; `RFD` references keep M2b's own refund link), then stores it (`end_to_end_id` for a debit, `original_end_to_end_id` for a credit) with
  `bank_transaction.reference_from_label = true` (new nullable column, shown to ops). The 6b paths then book or review
  it as any line carrying our id. Founder Q15.
- **S23** (D10 of §1.3): no undo path. `public.assign_payment` and `public.resolve_duplicate` redefined (from
  `20261117090000:2097`, `:2212`) for their hint only: « … Il ne s'affecte à aucun dossier, et Collectoo ne le
  comptabilise pas comme le retour de ce virement (un paiement enregistré ne se défait pas) : prévenez le support. »;
  `forms.ts:664-669`, `matching.ts:286-287` alike. The P0 alert `own_transfer_payment` stays as the tripwire. pgTAP
  035:2861 and 036:1645 updated to the new hint (justified in the ADR).

### 7.4 Web
« Virements », section « Approvisionnements du compte dédié »: the `TOP` orders (date, amount, reference, « commandé
automatiquement » or by whom, status), « Générer le fichier (compte propre) », « Télécharger », « Annuler le fichier »
(sheet: « Les approvisionnements non comptabilisés de ce fichier sont annulés ; Collectoo recommande ce qui reste dû
dans l'heure. Si la banque l'exécute quand même, la somme revient au cabinet avec la prochaine quote-part. »).
« Contrôles » « Réapprovisionner » on `servicer_shortfall` opens that section. « Comptes bancaires »: « Périodes où le
cabinet devait de l'argent au compte dédié » (« Du 12/11/2026 14:37 au 13/11/2026 10:37 — jusqu'à 2 000,00 € »).
Texts: `servicer_shortfall` « … Collectoo commande un approvisionnement chaque heure (référence TOP…, page
Virements) : exécutez-le depuis le compte propre, à la main ou par le fichier. »; `top_up_pending` unchanged, P0;
`top_up_account_missing` « Le cabinet doit de l'argent au compte dédié mais aucun compte propre n'est enregistré
(Paramètres › Facturation) : aucun approvisionnement ne peut être commandé. » Refusals: `not_an_own_account` « Ce
compte n'est pas un compte propre actif du cabinet. », `not_eur` « Seuls les virements en euros sont pris en
charge. », `nothing_to_file` « Aucun approvisionnement à mettre dans un fichier. », `nothing_to_cancel` « Ce fichier n'a
plus d'approvisionnement à annuler. »
Screenshots: `m2c7-approvisionnements`, `m2c7-periodes-decouvert`, `m2c-virements` retaken.

### 7.5 Tests
**pgTAP `047_top_ups_and_bank_residues.test.sql`** (≈ 35): `top_up_needed` with an advance; with a sweep in a file
(advance + sweep); with a top-up ordered (the rest); with servicer money on 4679 larger than the advance (none); the
hourly order twice → one order; no own account → alert; shortfall period opened at the advance, closed by the top-up's
booking (`servicer_top_up` from its credit); the top-up file (items, no cash check, download, superseded, cancelled after
download with the switch off, then its late credit booked as an own credit with no order and swept); S24 ingest (a
label carrying a real id of the account → stored and booked as the return; a look-alike id → ignored); the S23 hint.
**Worker**: parser S24 cases (CSV presets) and Python/SQL parity on generated labels (Hypothesis); the job writing an
own-account file (golden pain.001 bytes, XSD xfail as today). **vitest**, **E2E** (approvisionnements: generate,
download, cancel). **Mutants**: sweeps term dropped → sweep case; top-ups ordered not subtracted → twice case; cash
check kept for own files → generation case; S24 existence check dropped → look-alike case.

### 7.6 Docs (7e)
ADR-0014 « M2c-7e »; COMPLIANCE CPCE-02 (top-ups automatic), OQ-35 (top-ups and client repayments landing on the
dedicated account; R124-7 1°), OQ-38 (durations logged), OQ-84 (e)/(h) (S24 rule; S23 tripwire); benchmarks; PROGRESS.

---

## 8. 7f — Property machine, 50k close-out, hardening, docs close-out

Branch `m2c7f`. Migration `20261127090000_close_out_hardening.sql`.

### 8.1 Hardening
`private.run_payment_checks` redefined (from `20261118100000:3310`): `set enable_seqscan = off` (PROGRESS known limit,
PR #40 CI round: under forged statistics it read `refund_request` and `bank_transfer` by scans), and `servicer_shortfall`
= `private.top_up_needed` per currency (§13 #4's formula with the sweeps in flight). Every read keyed; a db-job test
forges statistics (as PR #40's) and bounds its reads.

### 8.2 The full property machine (design §18 « M2-12 » row)
`worker/tests/test_close_out_machine_integration.py` (needs `make up`): a Hypothesis `RuleBasedStateMachine` against
Postgres through the real commands and jobs (aal2 API sessions, the debit job, the remittances jobs, the hourly top-up,
the nightly checks with `p_today` advanced), and an oracle (`ledger_machine.py` extended with the two funds, runs,
advances and settlements). Two classes: switch **off**, and switch **on** (`private.switch_on()` in its fixture, the
switch-on stack of the E2E project).

- **World**: one servicer, own account, dedicated account; Martin (two mandates: one with netting + claw-back, one
  with netting only), Lilas (netting, no claw-back), Durand (no netting).
- **Rules** (each a no-op when it does not apply): collect (a statement credit, matched, allocated); forward; reverse an
  allocation (« Désimputer », remitted or not); return a payment (full or partial, by statement debit through the job);
  refund to the payer (requested, in a file, debited); prepare and approve a run; cancel before download; generate,
  download and mark sent a file; the bank debits a payout (own line or batch line); the bank returns a payout; a bank
  fee; the hourly top-up and its credit; the sweep (in the next file) and its debit; a client payment to the own account
  and on the dedicated account; a refund of a credit note's excess; a repayment request; a write-off; a manual credit
  note; a client event (proceeding opened; mandate ended then payee confirmed). Switch on adds: cancel a payout after
  download (two people, evidence statements), the bank executes it late (unplanned, P), late predecessor, its return.
- **Invariants after every step** (the nightly checks run, zero violations): I2′/I12 (`fund_mirror`,
  `own_fund_identity`), I8′ (`client_money_identity`), I13 (`client_payable_debit`: 4670 never in debit), I14/I15
  (`remittance_completeness`, `remittance_item_twice`), I16, I18 (`settlement_ledger` and `advance_ledger`), I19
  (`bank_cash_identity`), I20, I23 (`remitted_reversal_uncovered`). Oracle checks:
  - **each client's money is only theirs**: for each client, what it received (payouts debited − returned) = Σ its
    items remitted − commission set off − advances recovered + refunds paid with payouts, and its 4670 = −(its pending
    items + its runs in flight);
  - **no remitted reversal nets**: after any reversal of a remitted item, the client's queue total is unchanged by the
    pair (R and its advance);
  - **every advance** is recovered (settled), open and alerted after 30 days (`advance_open` with `p_today` + 31), or
    written off; never settled beyond its amount;
  - VAT: 44574 = Σ pending VAT of open documents; 44571 moved only by settlements.
- **At quiescence** (every file executed and booked, every top-up credited, the last sweep debited): 5120 = the bank's
  closing balance; −Σ4679 = settled commission (and client payments on the dedicated account) not yet swept = 0 after
  the last sweep.
- Settings: `max_examples` 25 × `stateful_step_count` 40 per class in CI's db job; 200 × 60 in a nightly-style manual
  dispatch; the seed printed; failing examples kept in the Hypothesis database for the PR.

### 8.3 The 50k close-out volume run (design §19; CLAUDE.md scale rule)
`worker/tests/test_close_out_scale_integration.py`, in CI's `scale-payouts` job (founder Q13; `scale` is at 27.6 of 30
min), stale statistics (reset, then import, as the 6a/6b files). Bounds (each asserted, then measured in
`docs/benchmarks/remittances.md`):

| Step | Volume | Bound |
|---|---|---|
| 1. covers at the reversal | a statement of 1,000 returns (2 %) of payments of a booked 50k-line run, one debit-job chunk | chunk < 60 s; the cover statement (`cover_remitted_reversals`, 1,000 reversals) < 2 s; reads keyed (`pg_stat_xact` deltas ≤ 20 per reversal) |
| 2. deferred LG009 checks | the 1,000 reversals at commit | < 0.5 s |
| 3. covers at the booking | a 50k-line run with 1,000 lines reversed in flight, its payout booked | `cover_booked_run_reversals` < 3 s |
| 4. nightly | 50k booked lines + 1,000 covers | `run_advance_checks` < 2 s; the whole nightly within today's 5–6 s + 2 s |
| 5. claw-back run | 50k new collections + 1,000 open advances under claw-back | prepare ≤ 10.6 s × 1.1, approval ≤ 6.1 s × 1.1 (M2c-4's measures), its settlement at the debit < 2 s (1,000 settlement rows) |
| 6. client payments | 1,000 `record_client_payment` calls | each < 200 ms |
| 7. top-ups | `order_due_top_ups` over 100 servicers | < 2 s |

CI: the branch of each slice touching a timed path dispatches CI (`workflow_dispatch`) and merges only once `scale` and
`scale-payouts` are green; a red volume run on main is fixed before the next slice.

### 8.4 Docs close-out (design §21 M2c-7 docs list)
- **COMPLIANCE** (§11): CPCE-02/03/07/08 final; new MAND-01/02/03, FAC-06 (Ops: 289 VII 1° documented controls), PROC-01;
  OQ-25/34/35/36/37/38/41/45/82/84/85 updated; OQ-88…96 added.
- **ADR-0014**: status line « … returns after remittance and close-out in M2c-7 (7a–7f) »; « M2c-7 » sections; the
  interim passages (l.30, l.54, l.163, l.167, l.185) marked superseded.
- **ARCHITECTURE** §8 (l.255–290): the chart of accounts and postings rewritten to the two funds (5120/4710/4670/4679 ‖
  5122/4111/4112/44571/44574/4689/7060/6270/6780), the remittance and settlement entries, fees booked, the property
  formula (I8′, I19); §9: the debit job's bookings and covers, the nightly checks; l.322 (« remittance + statement net of
  commission ») reworded: netting only under a clause.
- **DOMAIN**: « Avance au mandant … (M2c-7) » and its causes as built; LG009; « Règlement du client »; « Demande de
  remboursement d'avance »; « Avance passée en perte »; « Créances à déclarer »; payee kinds.
- **CALCULATION_RULES**: §7 notes the claw-back's place in the plan (invoices first, then advances; per mandate; nothing
  after a mandate end or in liquidation).
- **Design**: §3.2 #12 reworded (the SHA-256 is one control inside the documented procedure of 289 VII 1°, LEX-29);
  §13 and §21 annotated « As built (M2c-7) ».
- **ROADMAP** M2c rows closed; **benchmarks** (§8.3); **PROGRESS**: the gate (§8.6).

### 8.5 Tests and mutants (7f)
The machine (§8.2) and the volume file (§8.3) are the tests; the hardening has its forged-statistics db-job test (fails
on the old body). Mutants: the machine must kill, at least, the seven money mutants of §9 replayed on the final code
(cover off, at-booking cover off, claw-back off, VAT pro rata off, payee kind ignored, top-up sweeps term off, LG009
trigger dropped).

### 8.6 The go-live gate after M2c-7
Merging 7f lifts the design's code gate (« no real remittance before M2c-7 »). PROGRESS and ROADMAP record what remains
before a first real remittance, none of it code: the R124-2 declaration to the procureur and the dedicated account
(CPCE-01/02, Ops; R124-7 1°); counsel's answer to OQ-45 (CMF L314-1, L521-2); the bank's guide and a real statement with
our debits (founder #15; OQ-79/80/81/83/84); the founder's answer on the switch (6b-3 Q1); M3 re-runs before go-live
(design R7; m3 §10 #9), and M3c-2's restatement cover (§1.2).

---

## 9. Money rules and the test that pins each

| # | Rule | Pinned by |
|---|---|---|
| 1 | A reversal of a remitted item is advanced in full, the same transaction, at the reversal's date | 043 cases 1, 6; integration §7 12/11 |
| 2 | A reversal of an item in a run in flight is advanced when that run is booked, at the debit date, before any overrun cover | 043 case 4, 5; 037 `d_f5` rework |
| 3 | No reversal of a remitted item ever nets against the client's other collections | machine oracle « queue unchanged by the pair »; 043 case 1 |
| 4 | A forgotten cover fails at commit (LG009), and the nightly finds any gap | 043 cases 9, 10, 14 |
| 5 | An item an unplanned payout paid is covered for that part when reversed; the cover goes when that payout comes back; never when it was partly recovered | 043 case 11 |
| 6 | 4670[c] never in debit (I13) | 017 (raw reversal), machine |
| 7 | Advances are clawed back only under the mandate's clause, only from that mandate's money, invoices first | 044; Hypothesis `test_settlement`; §7.2 integration |
| 8 | A null-mandate advance is never clawed back | 044 `advance_mandate`; Hypothesis |
| 9 | An advance settled since the prepare sends the run back | 044 `documents_changed` |
| 10 | Σ open advances = 4112[c] (I18) | 043 case 14; machine |
| 11 | A write-off is admin-only, ≤ open, never reversed, settles the advance | 044 |
| 12 | A client payment settles in the named order, else due invoices → advances → other invoices; VAT moves pro rata | 045; parity Hypothesis |
| 13 | Nothing in flight is settled twice | 045 `in_flight`; 044 write-off `in_flight` |
| 14 | A client's credit on the dedicated account becomes the servicer's share and is swept | 045; machine quiescence |
| 15 | A refund owed is paid once, from the own account, on proof | 045 |
| 16 | A payout after death, tutelle, curatelle or mandate end goes only to the payee of the right kind confirmed after the event by a second admin | 046 |
| 17 | Nothing is set off in liquidation or after a mandate end; pre-opening claims are never set off (birth by the earliest date) | 046; worker unit `_plan` |
| 18 | Payments after the end are held and forwarded without commission | 046 |
| 19 | Top-up = max(0, Σ4679 + sweeps in flight − top-ups ordered), ordered once | 047; 7f `servicer_shortfall` |
| 20 | 5120 = the bank at quiescence; −Σ4679 = the share not yet swept | machine |
| 21 | Amounts are integers end to end; letters and statements print only ledger amounts | goldens (letter, statement fr-4); vitest amounts as text |

---

## 10. Founder questions (« 1 ok, 2 b … »; every default is what the plan builds; each stays open until answered)

1. **Retour partiel d'un paiement déjà reversé.** a (défaut) : le cabinet avance tout ce qui avait été reversé ; la
   part réimputée ensuite est due au client à nouveau (aucune compensation sans clause). b : la part réimputée est
   déduite de l'avance (compensation : avis de l'avocat).
2. **Avance liée à un virement qui couvrait plusieurs mandats** (reversement au-delà du dû, virement hors reversement).
   a : reprise seulement si un seul mandat ; sinon demande de remboursement. b : reprise sur le mandat le plus
   représenté.
3. **Approvisionnement automatique.** a : chaque heure, du montant exact dû au compte dédié, même petit. b : un seuil
   (par ex. 50 €) ou une fois par jour.
4. **Règlement du client sans facture désignée.** a : factures échues (plus anciennes d'abord), puis avances, puis
   factures non échues ; un montant supérieur à ce qu'il doit est refusé. b : avances d'abord.
5. **Avance passée en perte.** a : administrateur seulement, motif et pièce ; Collectoo cesse de la réclamer ; rien
   n'est envoyé au client (ce n'est pas une remise de dette). b : une lettre au client (remise : avocat).
6. **Demande de remboursement d'avance.** a : lettre neutre, sans article de loi, sans intérêts ni pénalités ni date
   limite, à payer sur le compte du cabinet ; alerte après 30 jours. b : texte validé d'abord par l'avocat (7c attend).
7. **Remboursement d'un avoir hors reversement.** a : l'équipe vire depuis le compte propre puis l'enregistre avec la
   preuve. b : dans le fichier d'approvisionnement, si votre banque l'accepte.
8. **Après un décès, une tutelle, une curatelle ou une fin de mandat.** a : reversements seulement sur le compte confirmé
   par un second administrateur du cabinet : notaire ou héritiers (décès), tuteur (tutelle), client ou tuteur
   (curatelle), client lui-même (fin de mandat). b : autre règle (avocat).
9. **Après la fin du mandat.** a : plus aucune compensation ni reprise ; factures dues, avances réclamées par lettre.
   b : les clauses continuent pour ce qui est né avant la fin (avocat).
10. **Paiements reçus après la fin du mandat.** a : mis en attente ; l'équipe les reverse sans commission au client (ou à
    son bénéficiaire) ou les restitue au payeur. b : restitution au payeur par défaut.
11. **Client en liquidation.** a : rien n'est compensé, avant ou après le jugement ; reversement brut au liquidateur ;
    factures et avances réclamées et déclarées. b : compenser ce qui est né après le jugement si le liquidateur poursuit
    le mandat.
12. **Saisie entre nos mains des sommes dues à un client.** a : pas construite en M2c-7 ; l'équipe retire l'IBAN du
    client (cela bloque ses reversements) et appelle l'avocat. b : un événement « saisie » qui bloque, dans 7d.
13. **Tests de volume M2c-7.** a : dans le job « scale-payouts » (environ 8 min de plus à chaque push sur main). b : un
    job à part.
14. **Fichier d'approvisionnement du compte propre.** a : le construire (7e). b : ne pas le construire (votre banque
    n'accepte pas de fichier sur ce compte) ; l'équipe saisit le virement TOP à la main.
15. **Notre référence seulement dans le libellé d'un relevé CSV.** a : reconnue quand le libellé porte la référence
    complète de l'un de nos virements de ce compte. b : attendre la colonne de la banque.
16. **Production.** a : aucun reversement réel n'a été émis depuis la production (les paiements faits de nos virements
    revenus n'existent donc pas). b : il y en a eu : dites-le, il faut alors un chemin pour les défaire.

The 6b-2 plan's questions 1–16 and the 6b-3 plan's 1–6 keep their defaults; 6b-2 Q13 is answered by Q15 and §5.2.5
(a client's repayment credit is a client payment) and by D10 (S23). Known limit with no question: an unplanned return
after part of its advance was recovered stays refused `advance_settled` (support), as since 6b-2.

---

## 11. COMPLIANCE entries (texts quoted from the legal inventory's reading on LibreJustice, 2026-11-21)

**Update**
- **CPCE-02**: the cover (7a: every reversal of a remitted entry advanced the same day; I23 at commit, LG009; nightly
  `remitted_reversal_uncovered`); top-ups ordered hourly (7e); client payments received on the dedicated account and
  swept (7c); the « Until M2c-7 » sentence goes.
- **CPCE-03**: claw-back only from the clause (R124-3 4° « conditions de reversement »); the mandate's end read by the
  allocation gate (R124-3 « pouvoir de recevoir pour son compte »).
- **CPCE-07**: a client's payment to the servicer gets no receipt: not a debtor's payment (R124-1 « pour le compte
  d'autrui »); a product choice.
- **CPCE-08**: blocked payees after an event keep their breach clock and alerts (LEX-05 (c)); after the end, payments
  held for ops.
- **OQ-25**: no hold-back; advances built and recovered (7a–7c).
- **OQ-34**: cite C. civ. 2000 (« Le mandant doit aussi indemniser le mandataire des pertes … sans imprudence qui lui
  soit imputable ») as a right the servicer does not use (default unchanged).
- **OQ-35**: add client repayments landing on the dedicated account and automatic top-ups; R124-7 1° makes a breach of
  R124-2's obligations a 5th-class contravention, so this is a penal-risk question.
- **OQ-36**: does R124-6's month keep running after the end of the mandate, and with no identified payee? (LEX-05).
- **OQ-37/OQ-38**: add C. civ. 1347-2 (« les obligations de restitution d'un dépôt … ne sont compensables que si le
  créancier y consent »: the strongest text behind the clause-only default), 1302-3 al. 2 (restitution « peut être
  réduite si le paiement procède d'une faute »), 1352-7 (interest « à compter du jour de la demande » for a recipient in
  good faith), 2001 (« L'intérêt des avances faites par le mandataire lui est dû par le mandant, à dater du jour des
  avances constatées »: a right not used); partial return default (Q1).
- **OQ-41**: connexité (C. civ. 1348-1 al. 1); the birth date of the claim; payees per event (Q8); proceedings do not
  end the mandate (L622-13 I, L641-11-1 I « Nonobstant toute disposition légale »).
- **OQ-45**: still a go-live gate after M2c-7 (§8.6).
- **OQ-82**: the residual is closed (7a); recovery built (7b, 7c).
- **OQ-84** (e)/(h): S24 rule (7e); S23 tripwire, no undo (D10). **OQ-85**: unchanged (the bank).

**Add**
- **MAND-01** (C. civ. 1993): « rendre compte de sa gestion, et faire raison au mandant de tout ce qu'il a reçu … quand
  même ce qu'il aurait reçu n'eût point été dû au mandant » — enforcement: statements (M2c-5, fr-4 block after the end),
  « Sommes reçues … et non reversées » (OQ-40). Recipient after the end: OQ-93.
- **MAND-02** (C. civ. 2003–2009): causes of the end (« la révocation …, la renonciation …, la mort, la tutelle des
  majeurs ou la déconfiture »); notification date (2006, 2007); « ce qu'il a fait dans cette ignorance est valide »
  (2008); good-faith third parties (2009); proceedings excepted (L622-13 I, L641-11-1 I). Enforcement: 7d.
- **MAND-03** (C. civ. 1999–2001): the mandant's obligations (advances, losses, interest) — the servicer's rights, and
  which the product does not use (no interest, losses borne by the servicer: founder #8). Worded as waivers, never as law.
- **PROC-01** (client in a collective proceeding): L622-7 I (« interdiction de payer toute créance née antérieurement au
  jugement d'ouverture, à l'exception du paiement par compensation de créances connexes »), III (annulable within three
  years); L622-24 and R622-24 (declaration « dans un délai de deux mois à compter de la publication du jugement
  d'ouverture au Bulletin officiel des annonces civiles et commerciales »); L622-26; L641-3; L641-9 I (« à partir de sa
  date … exercés … par le liquidateur »); L622-17 I, L641-13 I (post-opening claims). Enforcement: 7d (set-off rules,
  `claims_to_declare`, payees, `payout_after_liquidation`); Ops: the declaration itself.
- **FAC-06** (Ops; CGI 289 V and VII 1°, BOFiP BOI-TVA-DECLA-30-20-30-20 §90, §180, §190): « des contrôles documentés et
  permanents … une piste d'audit fiable »; the written procedure (who controls, when, how) from the triggering event to
  the invoice, including credit notes and the settlements of 7b/7c; kept and updated « à chaque changement ».
- **OQ-88** (accountant): an advance passed as a loss (6780): irrecoverable debt or abandonment for the servicer's
  taxable result; supporting document (C. com. R123-174 al. 2).
- **OQ-89** (counsel, accountant): imputation of a client payment without designation (C. civ. 1342-10 « d'abord sur les
  dettes échues ; parmi celles-ci, sur les dettes que le débiteur avait le plus d'intérêt d'acquitter »; 1347-4). Default
  Q4.
- **OQ-90** (accountant): the proof of a payment to, or a refund from, the own account; the VAT exigibility date of a
  client payment (CGI 269 2 c, the value date by default).
- **OQ-91** (counsel): a seizure served on the servicer as tiers saisi (CPCE L211-2, L211-3; C. civ. 1347-7, 1348-1
  al. 3). Default Q12.
- **OQ-92** (counsel): when the commission and the advance are « nées » for L622-7 I (encaissement, period end, issue,
  advance); whether set-off of post-opening commission needs L622-17 I / L641-13 I and the liquidator's decision.
  Default: the earliest date; nothing set off in liquidation.
- **OQ-93** (counsel): after the end of the mandate — to whom the account is rendered (heirs, notary, tutor,
  liquidator); payments received afterwards forwarded or restored (2005, 1342-2 al. 2, 1993); consignation of money with
  no payee (1345-1); the knowledge date (2008). Default Q10.
- **OQ-94** (counsel): curatelle, habilitation familiale, sauvegarde de justice (not named by 2003). Default: a payout
  hold by our rule.
- **OQ-95** (counsel): the repayment request's basis and wording (1999 or 1302-1; 1302-3 al. 2; 1352-7; 2001); whether a
  formal notice is useful. Default Q6.
- **OQ-96** (accountant): does the documented procedure of 289 VII 1° also cover the settlements (compensations, client
  payments and refunds) that feed CGI 290 A's payment data?

**Close**: none fully: OQ-82's residual part is closed inside the row.

---

## 12. Risks
- **R-a LG009 cost at volume** (one deferred check per reversal and per booked run): bounded in §8.3 rows 2–3; fallback
  — keep the commit check on runs only and rely on the nightly for single reversals (a decision recorded in the ADR).
- **R-b Redefinitions of long functions** (≈ 2,100 copied lines, `bank_booking_post_rows` and the statement build
  among them): copy the latest body, diff it against its source in the PR (the « only the change » rule), re-run
  033–042 and every integration file.
- **R-c The at-booking cover changes 6b's assertions** (037 `d_f5`, `d_ml1_signed`): flipped deliberately, each in the
  ADR, purpose kept.
- **R-d Legal defaults** (7d) wait for counsel; the texts say « règle du cabinet » where the law is not the source.
- **R-e Scale CI time** (`scale-payouts` + ~8 min; Q13).
- **R-f A top-up typed by ops and ordered again by the hour** (`request_top_up` takes no remit lock): over-funding with
  the servicer's own money, swept back; accepted.

---

## Appendix — inventory items not taken, and where they went
- D13 (line split) → the bank / founder 6b-2 Q5, Q11. D21 (payee address) → the bank / counsel (OQ-79).
- RP-4 (paths that do not reverse 4670): checked, nothing to do.
- Design §15 `payee_changed` and `document_missing`: not M2c-7's (no slice named them; `remittance_document_missing`
  exists); left to a later ops slice.
- LEX-30 (payment services) → OQ-45, a go-live gate (§8.6). LEX-06, LEX-04, LEX-20: nothing new to build.
