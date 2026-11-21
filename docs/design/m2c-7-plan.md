# M2c-7 plan — returns after remittance and close-out

Status: build plan for M2c-7, the last M2c slice (design `docs/design/m2c-remittances.md` §21 row « M2c-7 »). Nothing
here is built. It refines design §13 and §21 with what M2c-6b built; every departure says why (§1.3). Base: `1440178`
(main after PR #40, M2c-6b-3b part 3). The design says « no real remittance before M2c-7 is merged »: §8.6 says what
that gate still needs once M2c-7 is merged.

**[critic] Revision 1.** Three critics (money, legal, ops) read the draft against the code at `1440178` and the texts
on LibreJustice (versions in force 2026-11-21). Every finding was checked against the code; the ones that hold are
folded in and the changed parts carry « [critic] » with the finding's id (M7-MONEY-n, Ln, Fn). Appendix B lists what
was not taken, with why. The largest changes: a same-run pair is never « remitted » (§2.1); covers are dated no earlier
than the payout they cover and client texts print posting dates (§2.1, §5.3); an advance a run is about to take back
cannot be released or reversed under it (§3.2.8, §3.2.13); client money above what is open is booked as a credit owed
back, never refused (§5.2.9); the client's status is re-read at the debit (§6.2.11); the payees after a death or a
protection measure follow C. civ. 427 and 1309 (§6.2.7); our references read from a CSV label never book alone (§7.3);
top-ups in an own-account file are booked (§7.2); 7e now follows 7d (§1.4).

**[check 1] Revision 2 (completeness check).** A completeness critic listed 14 gaps (1 blocker, 5 major, 8 minor). Each
was checked against the code at `1440178` (latest definition of every function, by indexing every `create or replace`)
and, for the legal one, against C. civ. 440, 467, 472 and 473 on LibreJustice (versions in force since 2009-01-01, read
2026-11-21). All 14 hold; the changed parts carry « [check 1] ». The largest: the debit-time withholding now has a
mechanism the ledger accepts — the barred settlement posted and reversed in one transaction, one narrow exception to
`LG003` plus a commit-time check that it was reversed (§6.2.11 (a)); the client-payment books (419, 7714) and their
shapes, which M2c-1's checks refused (§5.0, §2.3 corrected); the client-event facts that need writing after the event
move to append-only side tables (`client_status_event` refuses every UPDATE, §6.1); the own-account top-up file passes
the two file and transfer guards that refused it (§7.2); a credit whose label cites our reference is held under its own
kind with three exits, never a payment (§7.3); `paid_on` follows a payout paid again by a later run and states an
N = 0 run's settlement honestly (§3.2.1); a curatelle's letters go to the client with a copy to the curator (§6.2.12).
Three slices became seven PRs to stay under ~2,500 non-test lines each: 7c → 7c-1, 7c-2; 7d → 7d-1, 7d-2, 7d-3; 7e →
7e-1, 7e-2 (§1.4). Founder questions Q4, Q8, Q15, Q17 changed and Q21 is new (§10); Appendix B lists the options not
taken.

**[check 2] Revision 3 (second completeness check).** A completeness critic listed 6 gaps (1 major, 5 minor) in
revision 2. Each was checked against the code at `1440178` (the latest definition of every function it names, by
indexing every `create or replace` / `create function`; line numbers confirmed) and holds; the changed parts carry
« [check 2] ». The largest: the kind `label_reference` ran into five guards and readers the plan neither redefined nor
listed — the bank-line booking guard refused its return and client-payment bookings, the two release guards refused
exit (c), the debit job's candidates never fetched it (so it never reached review) and the chain events never counted
its return (so a payout that came back through exit (a) still read « versé ») — all five are now redefined, and 7e is
split into three PRs to carry them (7e-2 held and reviewed, 7e-3 the three exits, §1.4, §7.3). Also: `run_settled_on`
reads the chain's returns from the bookings, not from `bank_transfer.return_entry_id`, which a late predecessor never
gets (§3.2.1); a withheld settlement makes a draft at the next hourly schedule under its own trigger (§6.2.11 (a) 8);
`epc_name_key` uses the writer's spellings (« Bœuf » → `BOEUF`, §6.2.7); the full pass of the advance checks has a
signature and an admin command (§3.2.11); a release names its seizure, and the declared items move into 7d-1 (§6.1).
Founder questions Q12, Q15 and Q19 are reworded (§10); Appendix B lists the options not taken.

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

[check 1] The table names every function, trigger function, constraint and policy M2c-7 redefines, with its slice; the
line counts are measured (`create or replace` to its closing `$$;`). A function a slice redefines again after an earlier
M2c-7 slice is copied from that slice's merged body (« from 7x »), never from the file below.

| Function (slice) | Latest definition at `1440178` | Lines |
|---|---|---|
| `public.reverse_allocation` (7a) | `20261109190000_payment_allocation.sql:1079` | 76 |
| `private.debit_post_rows` (7a) | `20261110120000_debits_refunds.sql:549` | 140 |
| `private.ledger_check_now` (7a; [check 1] 7d-2 from 7a) | `20261111090000_remittance_funds.sql:1335` | 10 |
| `private.document_open` (7b) | `20261112090000_remittance_runs.sql:1715` | 18 |
| `private.approve_remittance_run` (7a) | `20261114090000_manual_credit_note.sql:786` | 161 |
| `private.remittance_approval_refusal` (7c-2; 7d-2 from 7c-2) | `20261114090000_manual_credit_note.sql:688` | 94 |
| `private.remittance_payout_blockers` (7d-1) | `20261115090000_transfers_files.sql:900` | 31 |
| `private.run_remittance_checks` (7a) | `20261115090000_transfers_files.sql:3710` | 11 |
| `private.remittance_statement_build` (7d-3) | `20261117120000_statement_suivi.sql:363` | 447 |
| `public.assign_payment`, `public.resolve_duplicate` (7e-1, S23 hint) | `20261117090000_transfer_line_foundations.sql:2097`, `:2212` | 107, 77 |
| `public.transfer_file_download` (7e-1) | `20261118090000_switch_on_prerequisites.sql:2296` | 159 |
| `private.transfer_line_post` (7a) | `20261118100000_switch_on_prerequisites_2.sql:2163` | 173 |
| `private.run_payment_checks` (7f) | `20261118100000_switch_on_prerequisites_2.sql:3310` | 566 |
| `private.bank_booking_post_rows` (7a) | `20261121090000_switch_on_prerequisites_4.sql:808` | 276 |
| `private.gate_assignments` (7d-1) | `20261109190000_payment_allocation.sql:506` | 78 |
| `private.payout_court_appointed`, `public.record_client_status_event`, `public.propose_payout_account` (7d-1) | `20261111120000_identities_terms.sql:1062`, `:1076`, `:742` | 11, 55, 77 |
| [check 1] `private.bank_line_refined_kind` (7e-2): the eight-argument classifier, and the six-argument wrapper the draft named | `20261116090000_debit_bookings.sql:5384`; wrapper `:5419` | 32; 12 |
| [critic] `public.remittance_run_payout` (7a) | `20261118100000_switch_on_prerequisites_2.sql:4380` | 128 |
| [critic] `private.transfer_line_check` (7b; [check 1] [check 2] 7e-3 from 7b) | `20261119090000_switch_on_prerequisites_3.sql:739` | 801 |
| [critic] `public.register_client_document`, `private.can_read_client_document(_object)` (7b, 7c-1, 7c-2, 7d-1) | `20261111120000_identities_terms.sql:579`, `:543`, `:555` | 50, —, — |
| [critic] `private.can_read_remittance_document_object` and its policies (7c-2) | `20261113090000_remittance_documents.sql:1552`, `:1565`, `:1569` | — |
| [check 1] `private.remittance_line_insert_guard` (7b only: the advance mandate check, §4.1.9; 7d-2 needs no change, §6.2.11) | `20261113090000_remittance_documents.sql:1860` | 34 |
| [critic] `private.ledger_posting_client_payable` (7d-2) | `20261111090000_remittance_funds.sql:1252` | 51 |
| [critic] `private.post_run_settlements` (7d-2) | `20261116090000_debit_bookings.sql:767` | 79 |
| [critic] `private.transfer_hold_reason` (7d-2) | `20261118090000_switch_on_prerequisites.sql:2461` | 82 |
| [critic] `private.run_remittance_runs_checks` (7d-3, `invoice_overdue`) | `20261121120000_switch_on_prerequisites_5.sql:195` | 559 |
| [critic] `private.bank_booking_recheck` (7e-1, filed top-ups) and its worker twin `payments/debits.py` `decide_line` (7e-1, 7e-2) | `20261119090000_switch_on_prerequisites_3.sql:2062`; `debits.py:697` (`:732-737` top-ups) | 358 |
| [check 1] `public.forward_payment` (7d-1, reason `mandate_ended`) | `20261109190000_payment_allocation.sql:1161` | 108 |
| [check 1] `private.ledger_entry_guard` (7d-2, the barred-settlement exception to LG003) | `20261111090000_remittance_funds.sql:233` | 54 |
| [check 1] `private.ledger_entry_verify` (7c-1, shapes with 419 and 7714) | `20261111090000_remittance_funds.sql:295` | 264 |
| [check 1] `private.ledger_post_set` (7c-1, the two books in its book lists) | `20261111090000_remittance_funds.sql:889` | 316 |
| [check 1] constraint `ledger_account_shape` (7c-1) | `20261111090000_remittance_funds.sql:161` | 24 |
| [check 1] policy `ledger_account_read` and `public.ledger_balance` (7c-1) | `20261111090000_remittance_funds.sql:1394`, `:1416` | 12, 26 |
| [check 1] `public.accounting_export_entries` (7c-1: its servicer-fund book list) | `20261116090000_debit_bookings.sql:4494` | 80 |
| [check 1] constraints `remittance_pending_kind_check`, `remittance_line_kind_check` (7d-2) | `20261111090000_remittance_funds.sql:1237`; `20261112090000_remittance_runs.sql:245` | — |
| [check 1] `private.pending_item_deadlines` (7d-2) | `20261118100000_switch_on_prerequisites_2.sql:2775` | 126 |
| [check 1] `private.client_status_event_guard` (7d-1: new kinds, `qualified_at`; [check 2] `refers_to_event_id`) | `20261111120000_identities_terms.sql:1031` | 18 |
| [check 1] `private.transfer_file_guard` (7e-1) | `20261115090000_transfers_files.sql:559` | 57 |
| [check 1] `private.bank_transfer_guard` (7e-1) | `20261115090000_transfers_files.sql:742` | 92 |
| [check 1] `public.cancel_top_up` (7e-1: an `in_file` top-up of an own-account file) | `20261111090000_remittance_funds.sql:1621` | 35 |
| [check 1] constraint `bank_debit_review_reason_check` (7e-1 `top_up_cancelled_credit`; 7e-2 `label_reference`) | `20261117090000_transfer_line_foundations.sql:52` | — |
| [check 1] `private.ingest_statement` (7e-2) | `20261117100000_transfer_line_ops.sql:2749` | 441 |
| [check 1] `private.stage_refined_kinds`, `private.held_line_kind` (7e-2) | `20261116090000_debit_bookings.sql:5435`, `:5460` | 22, 22 |
| [check 1] constraints `bank_transaction_kind_check`, `bank_transaction_kind`, `bank_line_held_kind_kind_check`, `bank_duplicate_resolution_released_kind_check`, index `bank_transaction_own_idx` (7e-2) | `20261111090000_remittance_funds.sql:1804-1825` | — |
| [check 1] `private.transfer_line_class`, `private.transfer_line_pre`, `private.transfer_line_bookable_as` ([check 2] 7e-3, with exit (a)) | `20261117100000_transfer_line_ops.sql:124`; `20261117113000_transfer_line_pages_fixes.sql:59`; `20261117110000_transfer_line_pages.sql:2076` | 34, 95, 47 |
| [check 1] `public.debit_queue` (7e-2: lists `label_reference` lines) | `20261117110000_transfer_line_pages.sql:2323` | 188 |
| [check 1] `public.release_own_credit` ([check 2] 7e-3: exit (c) of a label reference) | `20261117110000_transfer_line_pages.sql:3128` | 83 |
| [check 2] `private.bank_line_booking_guard` (7e-3: a return of exactly the transfer the label names, and a client payment, on a `label_reference` line) | `20261121090000_switch_on_prerequisites_4.sql:641` | 155 |
| [check 2] `private.bank_own_credit_release_guard`, `private.payment_insert_guard` (7e-3: exit (c) on a `label_reference` line) | `20261111120000_identities_terms.sql:2497`, `:2591` | 30, 27 |
| [check 2] `private.bank_booking_candidates` (7e-2: the job fetches `label_reference` lines, as read or released) | `20261117090000_transfer_line_foundations.sql:882` (the `create function` after its `drop`, l.881; not `20261111090000:2786` nor `20261116090000:595`) | 167 |
| [check 2] `private.remittance_chain_events` (7e-3: a return booked on a line whose label names the transfer counts) | `20261118100000_switch_on_prerequisites_2.sql:164` | 101 |
| [check 2] `private.remittance_schedule_candidates` (7d-2: a waiting `settlement_withheld` item; dropped and recreated, one column more) and constraint `remittance_run_trigger_check` (7d-2: trigger `settlement_withheld`) | `20261112090000_remittance_runs.sql:2421`; the column check at `:44` | 28; — |
| [check 2] `private.run_remittance_checks` (7a: also passes `p_full`, §3.2.11) | `20261115090000_transfers_files.sql:3710` (its 7a row near the top of this table; one redefinition, not two) | 11 |
| [check 1] M2c-7's own functions redefined by a later slice: `private.run_advance_checks` (7a → 7b, 7c-1, 7c-2, 7d-1, 7d-2, 7d-3, 7e-1), `private.document_client_payable` (7c-1 → 7d-2), `public.book_client_payment_line` (7c-1 → [check 2] 7e-3), `public.request_advance_repayment` and `private.advance_repayment_payload` (7c-2 → 7d-1, 7d-2), `private.document_before_opening` (7c-1 → 7d-2), [check 2] `public.record_client_status_event` (7d-1 only: the declared items move into 7d-1, §6.1, so 7d-3 does not redefine it) | their slice's merged migration | — |

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
   to its payout afterwards, **and whose reversal is not a live line of that same run** ([critic] M7-MONEY-1, F1: a
   collection and its reversal frozen in one run net to 0 there and were never paid out, `commission.py`
   `_same_run_pairs`). A payout that came back keeps its run booked and re-queues a `payout_returned` item (+N). A
   reversal of one of that run's lines is then covered too (§1.3 D1). [critic] M7-MONEY-8, L5: whether that netting
   would be a set-off at all is put to the founder (Q17) and counsel (OQ-97); until they answer, no text says the client
   received a payout that came back (« reversé le » only from `remittance_run_paid_on`), and no repayment is requested
   for such an advance before the payout is paid again (`payout_not_received`).
2. **One target per reversal.** For a reversal R of an `allocation` or `forward` entry E, the cover it needs is
   T(R) = E's line amount when E is remitted (#1); otherwise Σ of E's live `unplanned_paid_item` rows (what an
   unplanned payout's P paid of E, OQ-82's residual, reachable only with the switch on); otherwise 0. What covers it is
   C(R) = Σ live `client_advance` rows of cause `remitted_reversal` and `cause_entry_id` = R. **Invariant I23: C(R) =
   T(R) for every reversal, at every commit** — a new deferred constraint trigger, SQLSTATE **`LG009`**, stronger than
   design §13 #2 (LG008 alone cannot see a reversal netted against the client's other collections).
3. **Covered at the reversal and at the booking.** Paths that reverse an item call `private.cover_remitted_reversals`
   in the same transaction. A reversal posted while its line sat in an approved or sent run (design §13 #3: no advance
   then) is covered **when that run is booked**, by `private.cover_booked_run_reversals`, before the `payout_overrun`
   cover (which it replaces). [critic] M7-MONEY-9, L3, F3: a cover is dated greatest(R's effective date, the date of
   the payout it covers), never before that payout; client-facing texts print the dates things were recorded. No
   reversal of a remitted item is ever netted against the client's other collections.
4. **Claw-back** (7b) wires the advances into the settlement plan that already supports them; an advance belongs to a
   mandate (the line's for `remitted_reversal`; the payout's single mandate for the other causes, set at insert, else
   none: repayment request only), and [critic] M7-MONEY-7 its queue items count in that mandate's money. [critic]
   M7-MONEY-2, F2: an advance an approved or sent run is taking back is never reversed or released under it.
5. **Recovery without a clause** (7c): a deterministic French letter « Demande de remboursement d'avance » (no LLM,
   amounts from the ledger, not an invoice), only for advances no claw-back clause recovers ([critic] M7-MONEY-3, L7),
   client payments to the own account (`client_payment_own`) or the dedicated account (`client_payment_dedicated`),
   refunds of credit-note excess (`client_refund_own`); an admin write-off (7b). [critic] M7-MONEY-10, L7, L21: money a
   client sends beyond what is open (or for a document a run already settled, or for a pre-opening claim) is booked as
   a **credit owed back** to it (`client_credit`), refunded on proof, never left off the books. [critic] L16: the
   client designates what it pays; otherwise the default order applies, which ops cannot change.
6. **Client status effects** (7d): a payee confirmed after **each** event by a second servicer admin, of the strictest
   kind those events require ([critic] F16), lifts the payout block — after a death the notary's account (or one all
   the heirs designate), with its evidence ([critic] L10, C. civ. 1309); after a tutelle or curatelle an account **in the
   client's name** run by the tutor or curator, with the judgment ([critic] L2, C. civ. 427 al. 5); after a mandate end
   the client's account re-confirmed. Set-off stops after a mandate-ending event, in liquidation and while a seizure
   stands ([critic] L14); while a proceeding stands no advance is taken or requested ([critic] L4, L622-7 I second
   sentence); the run's own new invoice follows the same rule ([critic] L1); the client's status is re-read at the
   debit and a set-off barred by then is withheld and given back ([critic] M7-MONEY-5; [check 1] posted and reversed
   in one transaction, the only exception to LG003, §6.2.11). Claims to declare are alerted per document with their
   deadline; payments after the end are held for ops; letters go to whoever now acts for the client ([critic] L12;
   [check 1] after a curatelle the client itself, with a copy to the curator: C. civ. 440 al. 1, 467 al. 3).
7. **Top-ups** (7e, after 7d: [critic] F12) are ordered automatically each hour, one servicer per transaction ([critic]
   F8), for max(0, Σ4679 + Σ sweeps ordered or in a file − Σ top-ups ordered or in a file) (design §13 #4), can be filed
   in an own-account pain.001 whose credits book ([critic] M7-MONEY-4), and shortfall periods are logged. Our references
   read from a CSV label are proposed to ops, never booked alone ([critic] M7-MONEY-6; [check 1] such a credit is held
   under its own kind `label_reference` — never a payment, never a return — until ops take one of three exits, §7.3).
8. **Close-out** (7f): the full property machine (switch off and on) within a stated CI budget ([critic] F15), the 50k
   close-out volume run, the nightly `run_payment_checks` hardened (PROGRESS known limit), and the docs (COMPLIANCE,
   ADR-0014 final, ARCHITECTURE §8–9). The go-live gate also waits for FAC-06's written procedure and OQ-44's answer
   ([critic] L15).

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
| [critic] M7-MONEY-1/F1, M7-MONEY-9/L3/F3, F5, F6, F10, F18 | pair-aware target, cover dates, at-booking covers on the run page, LG009 on a cover's reversal, advance mandate at insert, idempotent temp table | 7a |
| [critic] M7-MONEY-2/F2, M7-MONEY-7, F11 | in-flight advances never released, advance items in their mandate's money, evidence kinds' RLS | 7b |
| [critic] M7-MONEY-3/L7, M7-MONEY-10, L6, L16, L21, F7, M7-MONEY-12 | requests vs claw-back, client credit owed back, letter wording, designation, lock order, confirmed IBANs | 7c |
| [critic] M7-MONEY-5, L1, L2, L4, L8–L14, L17, L20, F16 | debit-time bar, run's own invoice, payees, advances in proceedings, declarations, overdue, letters' recipient, seizure | 7d |
| [critic] M7-MONEY-4, M7-MONEY-6, F8, F13 | filed top-ups booked, label references to review, per-servicer job, top-up file kind check | 7e |
| [critic] M7-MONEY-11, F15, F17, L15 | oracle, CI budget, baselines, gate | 7f |
| [check 1] gap 6 (`paid_on`), gap 13 (unplanned payout in an N = 0 run) | `run_settled_on`, `entry_remitted.paid_how`, case 5f | 7a |
| [check 1] gaps 2, 8, 11 | books 419 and 7714 with their shapes; one `client_credit` per cause; the default order skips what the client may not pay | 7c-1 |
| [check 1] gap 6 (requests) | N = 0 and re-paid advances requestable; set-off wording | 7c-2 |
| [check 1] gaps 3, 7, 10 | side tables for representatives and qualifications; curatelle addressee and copy; holder-name rule | 7d-1 |
| [check 1] gap 1 | the barred settlement posted and reversed (LG003 exception, commit check, `settlement_withheld` everywhere) | 7d-2 |
| [check 1] gap 9 | `liquidation_payout_disposition` | 7d-3 |
| [check 1] gaps 4, 12 | file and transfer guards for own-account files; `book_top_up_credit`; `cancel_top_up` of a filed top-up | 7e-1 |
| [check 1] gap 5 | kind `label_reference`, its import, its three exits | 7e-2, [check 2] 7e-3 |
| [check 1] gap 14 | the redefinition table and the sizes | header, §1.4 |
| [check 2] gaps 2, 5 | `run_settled_on` rule 3 from the bookings (a late predecessor's return); `p_full` signature, `request_full_advance_check` and its request table | 7a |
| [check 2] gaps 4, 6 | `epc_name_key` on the writer's spellings; `refers_to_event_id` and « standing »; `claims_declared_item` moved in | 7d-1 |
| [check 2] gap 3 | `remittance_schedule_candidates`, trigger `settlement_withheld` | 7d-2 |
| [check 2] gap 1 (3) | `bank_booking_candidates` + `decide_line`: a `label_reference` line reaches review | 7e-2 |
| [check 2] gap 1 (1), (2), (4) | the booking guard, the two release guards, the chain events; the exits moved here | 7e-3 |

### 1.2 Left out, to whom, and why

| Item | Left to | Why |
|---|---|---|
| `reverse_servicer_entry` (fee, loss, advance reversal by admin; design §16) | a later slice, on need | Not in §21's M2c-7 row. A fee or loss moves 5120 and must hang on a bank line (`bank_line_booking`, I9); a reversal without a line breaks I9, and a booking is append-only. A refunded fee is a credit line ops book as such; a wrong booking goes to support. No M2c-7 flow needs it: an advance whose cause is undone is reversed by its own path (unplanned return, §3.2.8). |
| Line-split model for unsplit entries holding anything not ours (S21/S22 residue, D13) | the bank (OQ-83, OQ-85), founder 6b-2 Q5/Q11 | Defaults (a) keep such lines waiting for the bank's detail. Built only if the founder picks (b). |
| Net cover per M3 restatement (m3 §10 #7 (a)) | M3c-2 | No restatement exists. M2c-7 exposes `private.entry_remitted` and `private.remitted_cover_gap`; M3c-2 redefines the gap for a restatement group (§3.2.1, §8.6). |
| Payee postal address in pain.001 for non-EEA SEPA (D21, OQ-79) | the bank, counsel | Only if required. |
| Seizure served on the servicer as tiers saisi (LEX-16): the declaration to the bailiff and the payment to the seizing creditor | counsel, founder Q12 | [critic] L14: no longer « left out » as a whole. Retiring the IBAN does not stop an N = 0 run from setting off (`remittance_approval_refusal` reads the blockers only when N > 0, `20261114090000:732`), against CPCE L211-2 (« attribution immédiate ») and C. civ. 1347-7. 7d adds the event pair `seizure` / `seizure_released` that blocks payouts and set-off whatever N (§6.2.6); the declaration and the payment to the creditor stay Ops (COMPLIANCE row, §11). |
| Consignation at the CDC for money with no payee (LEX-24, C. civ. 1345-1) | counsel (OQ-93) | A legal exit to confirm first; breach alerts keep the money visible. |
| Letter 1345 past D-5 (design §3.1) | M4 | Template « later » in the design; no channel before M4. |
| Interest on advances or on late remittance | counsel (OQ-38, OQ-95) | C. civ. 2001 / 1996: rights or duties to confirm; none computed (design §1, founder #7). |
| Email delivery of letters, statements, invoices | M4 / M7 | No channel (design §1). Documents in the client space and by post. |
| A statement template that details each recovered advance (date, cause) | later | The fr-3 statement already prints « Remboursement d'une avance du cabinet : … » per advance settled and the claw-back clause in its header (`statement.py:392`, `:542`); the advance's own line « Avance du cabinet » appears in the run that carried it. True as is; a richer row needs `remittance_statement_build` (446 lines) for wording only. 7d redefines it anyway (mandate end) and may add the date then (§6.2.8). |

### 1.3 Departures from design §13 and §21, with why

- **D1 Booked, not paid.** Design §13 #1 says « booked »; the inventory asked whether « paid and stayed paid »
  (`private.remittance_chain_paid`) should be the key. Booked: the key is stable (a booked run never returns to another
  status), so I23 has one value per reversal for ever. [critic] M7-MONEY-8, L5: the draft said netting a reversal
  against the re-queued `payout_returned` item « is a set-off of two claims » and cited nothing. That is not settled:
  the re-queued item may be the same remittance duty, reduced when its collection is undone (C. civ. 1993), not a
  second claim. The plan keeps « booked » as the conservative build (no netting without a clause, I23 stable) and puts
  the question to the founder (Q17, default a: keep) and to counsel (OQ-97). Its cost is stated there: for a client
  without a claw-back clause whose payout came back, the next run pays the whole re-queued N and the advance is owed.
  Three things change now: (1) the letter, the client space and the « Désimputer » sheet say « reversé le … » only for a
  run whose payout was paid and stayed paid (`private.remittance_run_paid_on`, `20261118100000:482`); otherwise
  « reversement revenu, à verser de nouveau »; (2) `request_advance_repayment` refuses `payout_not_received` while the
  advance's run payout came back and is not paid again (`private.remittance_chain_paid`, `20261118100000:276`); (3) 043
  pins the case (§3.9 case 17).
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
- **D12 [critic] M7-MONEY-1, F1. A same-run pair is not remitted.** A collection and its reversal both pending at a
  prepare become two lines of one run (`commission.py:1085` `_same_run_pairs`; `run.py` header « A paired line »); they
  net to 0 in that run, so nothing of E reached the client. T(R) is 0 for them (unless an unplanned payout paid E: the
  attribution). The draft's case 5 (« an N = 0 run with a reversed line, booked at approval → advance ») encoded the
  bug; the worker test `test_a_run_whose_collection_was_undone_in_it_is_booked_at_once`
  (`test_remittance_runs_integration.py:261`) stays unchanged and kills the mutant.
- **D13 [critic] M7-MONEY-9, L3, F3. Dates.** `reverse_allocation` reverses at the allocation's own date
  (`ledger_reverse` with no date, `20261111090000:809`: `coalesce(p_effective_date, v_target.effective_date)`). Dating
  the cover there put the advance weeks before the payout it covers (4112, 4679 and 4689 in debit for a period with no
  shortfall; `advance_born_on` pulled back; the letter's « puis annulé le 12/10 » after « reversé le 03/11 »). The cover
  is dated greatest(R's effective date, the covered payout's date) — that keeps 4670[c] out of debit at every date and
  never precedes the payout — and every client-facing text prints recorded dates (the Paris date of `posted_at`).
- **D14 [critic] M7-MONEY-6. A reference read from a CSV label never books alone** (§7.3): it can name a transfer the
  client is quoting, not one coming back.

### 1.4 Split, order, size

| PR | Content | Non-test lines (est.) | Tests (est.) |
|---|---|---|---|
| **7a** Remitted reversals covered | cover functions (pair-aware, dated after the payout), LG009 (incl. a cover's reversal), wiring into `reverse_allocation`, `debit_post_rows`, `bank_booking_post_rows`, `approve_remittance_run` (N = 0), `transfer_line_post` (unplanned return; advance mandate at insert); `remittance_run_payout`; nightly `remitted_reversal_uncovered` (delta-driven), `advance_ledger`, `advance_open`; « Couvrir »; texts; [check 1] `run_settled_on` and `paid_how`; [check 2] `p_full` with `request_full_advance_check` and its request table | ≈ 2,400 (migration ≈ 1,930 of which ≈ 960 redefinition copy) [critic] [check 1] [check 2] | pgTAP 043 (≈ 70), worker integration and two-session tests, vitest, E2E |
| **7b** Claw-back and write-off | advances in the plan **with their mandate's money**, `document_open` for advances, in-flight advances never reversed (`transfer_line_check`, 802-line copy), `write_off_advance`, evidence kinds' RLS, page « Avances », chip; [check 1] the line insert guard's advance-mandate check (34-line copy) | ≈ 2,230 [critic] [check 1] | pgTAP 044, §7.2 RV-3 end to end through `run._plan`, Hypothesis |
| [check 1] **7c-1** Client payments and refunds | books 419 / 7714 and the shapes that admit them (`ledger_entry_verify`, `ledger_post_set`, account shape, read policy, `ledger_balance`, accounting export: ≈ 720 copied lines), `client_credit` (one per cause), write-off recovery, `client_open_documents`, the plan and its default order (twins), `record_client_payment`, `book_client_payment_line`, `record_client_refund`, evidence kinds, `client_credit_ledger` / `written_off_recovery_ledger` | ≈ 1,950 | pgTAP 045 (shapes, payments, refunds) |
| [check 1] **7c-2** Repayment request | request tables, `request_advance_repayment`, withdrawal, payload, letter and its job, approval re-check of requested advances (`remittance_approval_refusal`, 94-line copy), document RLS | ≈ 1,150 | pgTAP 045b, letter goldens, §7.3 variants |
| [check 1] **7d-1** Payees, events, recipients | event kinds and columns, the representative and qualification side tables, `record_client_status_event`, `set_client_representative`, `qualify_protection_event`, payout kinds `estate` / `protected_adult` with authority and holder rule, blockers (strictest of every event), seizure pair, `client_addressee` (curatelle copy), the request's recipient, after-end hold (`gate_assignments`, `forward_payment`); [check 2] `refers_to_event_id` (a release names its seizure), `claims_declared` with `claims_declared_item` (moved from 7d-3), `epc_name_key` on the writer's spellings | ≈ 1,640 (≈ 690 copies) | pgTAP 046a |
| [check 1] **7d-2** Set-off bars at approval and at the debit | opening, birth, bar and nettable functions, the run's own invoice, `remittance_approval_refusal`, `transfer_hold_reason`, `post_run_settlements` with the barred settlement posted and reversed (`ledger_entry_guard`, commit check, `ledger_check_now`, 4670 trigger, kinds, `pending_item_deadlines`, worker kind), `document_client_payable`, `in_proceeding`, `set_off_after_bar`; [check 2] `remittance_schedule_candidates` (28-line copy) and the trigger `settlement_withheld` | ≈ 1,500 (≈ 680 copies) | pgTAP 046b, integration through the debit job |
| [check 1] **7d-3** Declarations, liquidation, statement | [check 2] `claims_to_declare` (reading 7d-1's declared items), `post_opening_unpaid`, `payout_after_liquidation` and `liquidation_payout_disposition`, `invoice_overdue` (559-line copy), statement fr-4 (447-line copy + renderer) | ≈ 1,555 (≈ 1,000 copies) | pgTAP 046c, goldens |
| [check 1] **7e-1** Top-ups (after 7d-3) | hourly top-up job, shortfall log, own-account file (file, item and transfer guards, download, cancel), filed top-ups booked (`bank_booking_recheck` + `decide_line`), `book_top_up_credit`, `cancel_top_up` of a filed top-up, S23 texts | ≈ 1,650 (≈ 950 copies) | pgTAP 047a |
| [check 1] [check 2] **7e-2** Our references in CSV labels: held and reviewed | kind `label_reference` (twins, parser, stage helpers, ingest, kind constraints), [check 2] `bank_booking_candidates` (167-line copy) and `decide_line` so the job sends it to review `label_reference`, `debit_queue` | ≈ 1,150 (≈ 880 copies) | pgTAP 047b, parser parity |
| [check 2] **7e-3** Our references in CSV labels: the three exits | exit (a) (`transfer_line_check` 801-line copy from 7b and its class / pre / bookable helpers, `bank_line_booking_guard` 155, `remittance_chain_events` 101), exit (b) (`book_client_payment_line` from 7c-1), exit (c) (`release_own_credit`, `bank_own_credit_release_guard`, `payment_insert_guard`), the three actions on the page | ≈ 1,750 (≈ 1,500 copies) | pgTAP 047c |
| **7f** Close-out | property machine (off and on), 50k close-out, `run_payment_checks` hardening + §13 #4 shortfall, docs, gate | ≈ 650 code + ≈ 950 docs | machine, scale |

[check 1] [check 2] Total ≈ 17,600 non-test lines (≈ 9,000 of them copied redefinitions) and ≈ 950 doc lines; ≈ 15,500
test lines. The draft's ≈ 11,900 left out the copies the gaps add (the ledger's shape and book lists, the file and
transfer guards, the import and the transfer-line helpers, the deadline and queue functions). [check 2] Eleven PRs, each
under ~2,500 non-test lines and each shippable alone: 7c, 7d and 7e are split as above (the draft's optional 7d split is
now three PRs because the withholding and the declarations each carry a long copy). [check 2] 7e is now three PRs:
revision 2's 7e-2 (≈ 2,400) plus the five copies the second check adds (≈ 480 lines) came to ≈ 2,880, so the kind and
its review (7e-2) and its three exits (7e-3) are built apart. The guard copy is made once, in 7e-3, with both its arms.
**7e-2 alone is safe**: a credit citing our reference is held in review with no exit until 7e-3 (never a payment,
never booked); no real `RMT` or `SWP` reference exists before M2c-7 is merged (design: « no real remittance before
M2c-7 »), so in production only a `TOP` cited from a non-own IBAN could wait, in review. The largest PR is now 7a
(≈ 2,400).

**Order, and why.**
1. **7a first**: it closes the money hole that gates real remittances (silent netting of a remitted reversal) and
   creates the advances everything after recovers. LG009 makes every later reversal path safe by construction.
2. **7b**: the standard mandate carries the claw-back clause (§7 Martin), so most advances are recovered by it; small
   and reviewable alone; finishes §7.2 end to end.
3. **7c-1, then 7c-2** [check 1]: need `advance_open` / `document_open` for advances (7b) and the in-flight refusal
   pattern; 7c-1 closes the « due invoice never settled » and « refund owed never paid » holes, 7c-2 the « advance with
   no clause never recovered » one.
4. **7d-1, 7d-2, 7d-3** [check 1]: change the plan's set-off rules (7b) and add refusals to 7c's commands; their legal
   defaults need the most founder and counsel answers, so they come after the money paths they constrain. 7d-2 needs
   7d-1's events and side tables; 7d-3's statement block prints 7d-2's withheld item.
5. **7e-1, then 7e-2, then 7e-3 ([check 2]), after 7d-3** ([critic] F12): every 7d slice and 7e-1 redefine
   `private.run_advance_checks` (7d adds `claims_to_declare` and the liquidation checks, 7e-1
   `top_up_account_missing`), and they touch `debits.ts` CHECK_LABEL, COMPLIANCE and ADR-0014; under the whole-copy
   rule the second to merge would silently drop the other's checks. Built in sequence. [check 1] [check 2] 7e-2
   redefines `bank_debit_review_reason_check` and `decide_line` after 7e-1; 7e-3 redefines `transfer_line_check` from
   7b's body and `book_client_payment_line` from 7c-1's. Lowest money risk: manual top-ups (`request_top_up`) and
   `servicer_shortfall` already work.
6. **7f last**: the machine needs every rule; the 50k run times the final code; docs close M2c.

Each PR follows CLAUDE.md: plan → tests (seen failing) → code → run; mutants; review lenses; `scale` paths touched
(7a returns and bookings, 7b prepare/approval, [check 1] 7c-1 the posting path (`ledger_post_set`), 7d-2 bookings,
7e-1 transfer files and bookings, 7e-2 import and the debit job's candidates, [check 2] 7e-3 the booking guard and
the chain events the nightly reads, 7f) dispatch CI on the branch before merging. [critic]
F12: every slice takes its migration timestamp when its PR opens (after the latest on main, as CI checks), and 043
asserts the full list of check codes `run_advance_checks` emits, which each later slice extends: a dropped check fails.

---

## 2. Shared definitions

### 2.1 Remitted, target, cover (I23)

```
line(E)        = the live line of item entry E (remittance_line where ledger_entry_id = E and not released;
                 remittance_line_live_uq), with its run X                                    -- at most one row
remitted(E, R) = line(E) exists, X.status = 'booked', and R has no live line in X            -- [critic] M7-MONEY-1, F1
                 (R's own live line by remittance_line_live_uq on R; a same-run pair nets to 0 in X: never paid out)
T(R)           = for R a reversal (entry_type 'reversal') of E with E.entry_type in ('allocation', 'forward'):
                   line(E).amount_minor                                       if remitted(E, R)
                   Σ unplanned_paid_item.amount_minor of E whose booking_entry_id is not reversed   otherwise
                   (unplanned_paid_item ledger_entry_id index, 20261117100000:55; reversed: ledger_entry_reversed_once_uq)
                 0 for any other reversal
C(R)           = Σ client_advance.amount_minor where cause = 'remitted_reversal' and cause_entry_id = R
                 and its entry is not reversed                               (client_advance_cause_idx, 20261117100000:66)
gap(R)         = T(R) − C(R)
I23            : gap(R) = 0 for every reversal, at every commit (LG009) and every night (remitted_reversal_uncovered)
```

- remittance_line.amount_minor equals E's 4670 posting negated (its guard), so T is « the reversed 4670 amount ».
- [critic] M7-MONEY-1: the pair rule holds in every place T is read — `remitted_cover_target`,
  `cover_remitted_reversals`, `cover_booked_run_reversals` (a line whose reversal is a live line of the same run is
  skipped), `run_booked_cover_check`, the nightly and « Couvrir ». With the switch on, a pair booked in run Y after an
  unplanned payout U attributed E keeps T = the attribution (not the line), so U's later return releases the cover.
- An advance is posted for gap > 0 only. An advance is reversed (released) only when gap < 0, which happens only when an
  unplanned booking that attributed E is reversed (its return, §3.2.8) and E is not remitted.
- Mandate of a cover advance: line(E).mandate_id; else the mandate of E's file
  (`portfolio.mandate_id` of E.portfolio_id, NOT NULL since M1); null for a forward on no file.
- **Date [critic] M7-MONEY-9, L3, F3**: greatest(R's effective date, the date of the payout it covers): X.booked_on for
  a remitted line (at the reversal and at the booking alike), the latest attributing unplanned booking's line date for
  an attribution. R may be back-dated (« Désimputer » reverses at the allocation's own date: `ledger_reverse` with no
  date, `20261111090000:809`); the draft dated the advance there, before the payout, so 4112/4679/4689 showed an advance
  for a period with no shortfall and the letter printed « reversé le 03/11 … puis annulé le 12/10 ». With this date,
  4670[c] is out of debit at every date (before the payout E and R cancel; from it, the payout and the advance do) and
  the advance never precedes the payout. `advance_born_on` (7b) reads this date.
- **Dates on client-facing texts** (letter, client space, run page note, statement): the date things were recorded —
  the Paris date of `ledger_entry.posted_at` of R and of the advance, a bank line's booking date for a return — never
  an effective date; effective dates serve balances only.
- Keys: `adv:<R>` at the reversal; `adv:<R>:<run>` at the booking; `adv:<R>:rel:<line>` for a re-post after a release;
  `adv:<R>:cov:<idempotency key>` for « Couvrir » ([critic] F18: `adv:<R>` may already exist, reversed by a release);
  `return:rr:<line>:<advance>` for a release's reversal. Derived from existing rows only (design §5.2).
- Reason (an entry the client's whole-client members read): « Encaissement déjà reversé puis annulé : avance du
  cabinet » (fixed text; ops' motif never).

### 2.2 Locks and transactions
Every path that posts a cover already holds the allocation lock (`ledger_reverse` takes it) and gets the remit lock
from `private.ledger_post_set` (4679 lines; `20261111090000`, ledger_post_set takes `remit:` for 4679 writers). Order
stays allocation → remit → counter. `reverse_allocation` (lock_timeout 2s) may now wait for the remit lock (a file
generation holds it for its duration): its refusal on timeout is « Opération en cours sur les virements : réessayez
dans un instant » (web mapping of SQLSTATE 55P03 for this command).
[critic] F7: a command on a **bank line** follows the funds pass's order (`post_debit_links`, `20261117110000:2824`;
`post_bank_bookings`, `20261119090000:2129`): allocation lock `payments:<org>` → the line `for no key update` → remit
lock `remit:<org>`, the facts re-read after the locks. 7c's `book_client_payment_line` takes them in that order (not
`remittance_command_locks` after the line).

### 2.3 The money each slice may move ([check 1] shapes are M2c-1's, `20261111090000:455-484`, **except** `client_payment_own`, `client_payment_dedicated` and `client_refund_own`, which 7c-1 widens: §5.0)

[check 1] The draft called these shapes « unchanged »; they are not. M2c-1's I3′ (`private.ledger_entry_verify`,
`20261111090000:470-482`) requires `n_com + n_adv ≥ 1` for both client payments and exactly one 4111 debit for
`client_refund_own`, and neither `public.ledger_book` nor the three types' `allowed_books` list a 419 or 7714 book: a
payment that is all surplus, a payment with a recovery, and the refund of a client credit would each be refused
`LG001`. 7c-1 adds the two books and widens the three shapes (§5.0); the rows below are the shapes after 7c-1.

| Entry | Lines | Posted by (slice) |
|---|---|---|
| `client_advance` (cause `remitted_reversal`) | +4679 A / −4670[c] A ‖ +4112[c] A / −4689 A | cover functions (7a) |
| its reversal (release) | the negated lines | `remitted_cover_release` (7a) |
| `client_settlement` with Da | +4670[c] D / −4679 D ‖ +4689 D / −4111[c] Dc / −4112[c] Da ‖ VAT pair | existing posters, now with advances (7b) |
| `advance_write_off` | +6780 W / −4112[c] W | `write_off_advance` (7b) |
| `client_payment_own` | +5122[own] P / −4111[c] / −4112[c] / −419[c] surplus / −7714 recovery ‖ +44574 v / −44571 v | `record_client_payment` (7c) |
| `client_payment_dedicated` | +5120[b] P / −4679 P ‖ +4689 P / −4111[c] / −4112[c] / −419[c] surplus / −7714 recovery ‖ VAT pair | `book_client_payment_line` (7c) |
| `client_refund_own` | +4111[c] R (credit note) or +419[c] R (client credit) / −5122[own] R | `record_client_refund` (7c) |
| [critic] `client_settlement` `settle:<run>:barred` and its reversal | a settlement's barred part, posted and reversed at once; the reversal queues a `settlement_withheld` item (+W). [check 1] Possible only through the one exception 7d-2 adds to `LG003` (§6.2.11 (a)) | `post_run_settlements` at the debit (7d-2) |
| `servicer_top_up` | unchanged (booked from its credit; [critic] also when its transfer is `in_file` of an own-account file) | 7e orders and files it |

[critic] M7-MONEY-10: « 419[c] » is a new servicer-fund book `client_credit_owed` (PCG class 419 « Clients
créditeurs », the exact account per the accountant, OQ-98) for client money owed back; « 7714 » is a new book
`written_off_recovered` (recovery of an advance passed as a loss; PCG 7714 « Rentrées sur créances amorties » proposed,
OQ-88). No account number is fixed here without the accountant. [check 1] `ledger_book.account_number` is NOT NULL
unique, so the rows carry `419` and `7714` as Collectoo's labels (as every book's number is, `20261111090000:51`:
« The numbers are our labels; the accountant maps them »); the accounting export prints them and the accountant maps
them (OQ-88, OQ-98).

### 2.4 The switch, off and on
- **Off (today):** a run whose payout is in a downloaded file is never cancelled; its lines stay live and the run ends
  booked (or stays sent). `unplanned_paid_item` rows arise only from S03r (a returned payout executed again), whose
  items are `payout_returned` entries (reversals; never reversed again): T(R) via attributions is unreachable.
- **On:** a run's payout cancelled after download releases its lines (never booked: no cover); a late execution books
  an unplanned payout whose P attributes the released items (D4: their later reversal is covered, the unplanned return
  releases it); a late predecessor books its still-live run through `bank_booking_post_rows` (at-booking cover).
- No M2c-7 migration writes `private.feature_switch`. Each pgTAP file of M2c-7 runs its switch-on cases after
  `private.switch_on()` inside its own transaction (rolled back), and a guard test asserts the switch is off at the end.
- [critic] What the switch changes in M2c-7's new rules, each tested both ways: the pair rule with an attribution
  (043 case 5e); the release and the unplanned return refused while a run takes the advance (044); the debit-time bar and
  the hold before download (046: switch off → the downloaded payout is debited and the barred part withheld; switch on
  → the two-step cancellation is offered too); `cancel_top_up_file` never touches a payout file whatever the switch
  (047). [check 2] With it on, a late predecessor booked as its run's payout keeps `cancelled` and no
  `return_entry_id` when it comes back (`transfer_line_post`, `20261118100000:2285-2290`): `run_settled_on` follows its
  return through the bookings (043 case 17 (d)).

---

## 3. 7a — Remitted reversals covered everywhere, and the backstop

Branch `m2c7a`. Migration `supabase/migrations/20261122090000_remitted_reversal_cover.sql` (forward-only; the timestamp
is after the last merged migration when the PR opens). Closes D01, D02, D10's residual, D18, part of D04.

### 3.1 Schema
- [check 2] One new table, `private.advance_full_check_request` (§3.2.11: an admin's request for the full pass, taken
  by the next check run). `client_advance` unchanged (cause `remitted_reversal` allowed since `20261116090000:146`).
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

**3.2.1 `private.entry_remitted(p_entry_id uuid, p_reversal_id uuid default null) returns table (run_id uuid,
run_number text, amount_minor bigint, mandate_id uuid, booked_on date, paid_on date)`** (stable). The live line of
`p_entry_id` (by `remittance_line_live_uq`) joined to its run by key, `status = 'booked'`, and [critic] M7-MONEY-1 no row
when `p_reversal_id` has a live line in that same run. The predicate M3c-2 calls (m3 §10 #7 (e)). [check 1] It also
returns `paid_how text` and `paid_run_number text`, and `paid_on`, `paid_how`, `paid_run_number` come from
`private.run_settled_on(run)` below — not from `private.remittance_run_paid_on` alone, which reads only the run's own
transfer chain (`20261118100000:482`, `private.transfer_chain`): the draft's `paid_on` stayed null for ever for (a) a run
whose payout came back and whose re-queued `payout_returned` item was paid by a later run (another transfer, not a
re-issue: 043 case 17 contradicted it), and (b) an N = 0 run (no transfer).

**[check 1] `private.run_settled_on(p_run_id uuid) returns table (on_date date, how text, run_number text)`** (stable,
SECURITY DEFINER, `enable_seqscan = off`, EXECUTE revoked; keyed reads only; recursion bounded at depth 10, deeper →
no row and the nightly `advance_open` details say `settled_on_depth`):
1. the run not `booked` → no row;
2. a run with a transfer: `private.remittance_run_paid_on(run)` not null → `(that date, 'paid', its number)`;
3. a run with a transfer whose chain stayed unpaid: each `payout_returned` reversal of the chain has a live line
   (`remittance_line_live_uq`) in a booked run Y → `run_settled_on(Y)`; when every one has a row, the latest date with
   Y's `how` and number; else no row. [check 2] The chain's reversals are the `entry_id` of the `bank_line_booking`
   rows of kind `payout_returned` whose `transfer_id` is in `private.transfer_chain(run.transfer_id)` (keyed: the chain,
   then `bank_line_booking_transfer_idx` per transfer, `20261111090000:2338`) — **not** `bank_transfer.return_entry_id`:
   with the switch on, a late predecessor booked as the run's payout stays `cancelled` when it comes back, its
   `return_entry_id` null (`transfer_line_post`, `and x.status <> 'cancelled'`, `20261118100000:2290`; the constraint
   `bank_transfer_returned`, `20261111090000:1481`, ties the column to status `returned`), so the draft's read found no
   reversal and `paid_on` stayed null after a later run had paid the re-queued item (requests refused, the text « revenu,
   à verser de nouveau » after the money was paid again);
4. an N = 0 run (no transfer: booked at approval): its live `unplanned_payout` lines whose booking entry was reversed
   (the unplanned payout came back; `ledger_entry_reversed_once_uq`) are followed as in 3 through the reversal's live
   line; when none came back → `(run.booked_on, 'set_off', its number)` if `settlement_minor > 0`, else `(run.booked_on,
   'netted', its number)` (the lines netted to 0: an unplanned payout's −P row paid them, switch on).

`paid_on` null ⇔ the client has not received the item (`payout_not_received`, §5.2.7). The texts (letter, client space,
« Désimputer », run note) word it by `paid_how`: `paid` « versé le JJ/MM/AAAA (relevé RV-…) » (through a later run:
« versé le JJ/MM/AAAA (relevé RV-Y, après le retour du virement du relevé RV-X) »); `set_off` « réglé par compensation
dans le relevé RV-… du JJ/MM/AAAA (aucun virement) »; `netted` « compris dans le relevé RV-… du JJ/MM/AAAA (montant net
nul, aucun virement) »; null « compris dans le reversement RV-… (revenu, à verser de nouveau) ». Never « versé » for an
N = 0 run.

**3.2.2 `private.remitted_cover_target(p_reversal_id uuid) returns bigint`, `private.remitted_cover_held(p_reversal_id
uuid) returns bigint`, `private.remitted_cover_gap(p_reversal_id uuid) returns bigint`** (stable): §2.1 exactly; T is
0 for a reversal of anything but an `allocation` or a `forward`. M3c-2 redefines `remitted_cover_target` for a
restatement group (net of the re-posted allocation), never the other two.

**3.2.3 `private.remitted_cover_begin()`** creates `pg_temp._rcv (n integer primary key, reversal_id uuid,
organization_id uuid, client_organization_id uuid, currency char(3), mandate_id uuid, amount_minor bigint check (> 0),
on_date date, idem_key text, transfer_id uuid, bank_transaction_id uuid, advance_id uuid default gen_random_uuid())` on
commit drop; [critic] F18 idempotent within a transaction (`drop table if exists pg_temp._rcv` first, as
`ledger_post_set_begin` does with `_lps_*`): the debit job's per-link retries, the chunk loop and a release followed by
a re-post call it several times in one transaction.
**`private.remitted_cover_post()`** posts its rows: `private.ledger_post_set_begin()`, one `client_advance` entry per row
(+4679 / −4670[c] / +4112[c] / −4689, `source_type 'client_advance'`, `source_id` = advance_id, key = idem_key,
`client_organization_id`, reason §2.1), at most 2,000 rows per `ledger_post_set` call (the transition-table bound of
`post_run_settlements`, `20261116090000:767`); then one insert of `client_advance` (`cause 'remitted_reversal'`,
`cause_entry_id` = reversal_id, `entry_id`, `mandate_id`, `currency`, `amount_minor`, `transfer_id`,
`bank_transaction_id`) for the entries created (a replayed key creates nothing and inserts nothing). Returns the count
posted.

**3.2.4 `private.cover_remitted_reversals(p_reversal_ids uuid[]) returns integer`** — at the reversal. For each distinct
id (`ledger_entry` by key, its reversed entry by key), gap > 0 → one `_rcv` row: amount gap, `on_date` per §2.1 [critic]
(greatest of R's effective date and the covered payout's date), key `adv:<R>`, mandate §2.1. Then
`remitted_cover_post()`. Set-based: one call per command or per debit chunk, never one per row.

**3.2.5 `private.cover_booked_run_reversals(p_run_ids uuid[], p_dates date[], p_transfer_ids uuid[] default null,
p_line_ids uuid[] default null) returns integer`** — at the booking of those runs. Callers book them in the same
transaction, before or after this call: the amounts come from the lines, not from the run's status. For each run, its
live lines of kind `allocation` or `forward` (by the primary key prefix `run_id`), each line's entry's reversal R by
`ledger_entry_reversed_once_uq`, **[critic] M7-MONEY-1 skipping R when R itself has a live line in the same run** (a
same-run pair); amount = `line.amount_minor − remitted_cover_held(R)` when > 0; `on_date` = greatest(R's effective
date, the run's date); key `adv:<R>:<run>`; [critic] F5 `transfer_id` = the run's payout transfer and
`bank_transaction_id` = the debit line (null for an N = 0 run booked at approval). Then `remitted_cover_post()`.

**3.2.6 `private.remitted_cover_check()`** (constraint trigger function on `ledger_entry`): for `new` (a reversal),
`gap(new.id) <> 0` → raise `LG009` « ledger: reversal % of an entry remitted to client % is not covered by an advance
(gap %) ». Also, when `new` reverses an unplanned booking (`unplanned_paid_item.booking_entry_id` =
`new.reverses_entry_id`), every item it attributed that has a reversal R must have gap(R) = 0 (the release ran).
[critic] F6: and when `new` reverses the entry of a `client_advance` of cause `remitted_reversal`, gap(that advance's
`cause_entry_id`) must be 0 at check time (a cover reversed by any path but the release, which re-posts or reaches
T, is refused: lowering C(R) is the other way to break I23).
**`private.run_booked_cover_check()`** (on `remittance_run`): any live `allocation`/`forward` line of the run whose
entry has a reversal R, **not itself a live line of that run** [critic], with gap(R) ≠ 0 → `LG009`. Both read by key.

**3.2.7 `private.ledger_check_now()`** redefined (from `20261111090000:1335`): `set constraints
public.ledger_entry_balanced, private.client_payable_in_credit, public.ledger_entry_remitted_cover,
public.remittance_run_booked_cover immediate;` then `deferred`. The debit job's per-link retry, `link_debit` (strict
mode: « debit link refused: posting_failed (LG009: …) ») and `book_transfer_line` then raise it inside their call.

**3.2.8 `private.remitted_cover_release(p_booking_entry_id uuid, p_line_id uuid, p_on date) returns integer`** —
called by `transfer_line_post` right after it reverses an unplanned booking (`ub_entry`). For each item E the booking
attributed (`unplanned_paid_item` by `booking_entry_id`) that has a reversal R with gap(R) < 0:
1. the live cover advances of R, newest first; if one has a `commission_settlement` (claw-back, payment, write-off:
   7b/7c) → raise « transfer line refused: advance_settled » (6b-2's refusal for the `double_payout` advance,
   `m2c-6b-2-plan.md` §3.4.13 rule 6; same web text); [critic] M7-MONEY-2, F2: if an approved or sent run's
   `settlement_plan.settles` names one (`private.advance_in_flight_run`, §3.2.13; its settlement is posted only at that
   run's debit by `post_run_settlements`, `20261116090000:767`, which never re-checks the advance) → raise « transfer
   line refused: advance_in_flight » (the line waits; after the run's debit the refusal becomes `advance_settled`).
   Built in 7a (no plan takes an advance before 7b, so it is silent until then, and correct by construction);
2. `private.ledger_reverse(advance.entry_id, 'return:rr:' || p_line_id || ':' || advance.id, 'Avance du cabinet
   annulée : le virement hors reversement qui avait payé cet encaissement est revenu (relevé du JJ/MM/AAAA)', p_on)`
   until C(R) ≤ T(R);
3. if then C(R) < T(R) (several bookings attributed E), one `_rcv` row for T − C, key `adv:<R>:rel:<line>`, posted.

The advance rows stay (append-only); C(R) counts only advances whose entry is not reversed.

**3.2.9 `public.cover_remitted_reversal(p_idempotency_key text, p_reversal_id uuid, p_expected_gap_text text) returns
jsonb`** — « Couvrir » on « Contrôles » (design §17): an admin of the reversal's servicer at aal2. Replay + request
hash. Locks: `remittance_command_locks(org, true)`. Refusals (`check_violation`, « remitted cover refused: <code> »):
`nothing_to_cover` (gap = 0), `gap_changed` (gap ≠ expected), `over_covered` (gap < 0: support). Posts one `_rcv` row
for the gap with key `adv:<R>:cov:<idempotency key>` ([critic] F18: `adv:<R>` may exist already, reversed by a release —
re-using it would replay the reversed entry or raise LG004), then `ledger_check_now()`. Returns `{advance_id, entry_id,
amount_minor}`.

**3.2.10 `public.allocation_remitted(p_payment_id uuid) returns jsonb`** — read for the « Désimputer » and « Retour »
sheets: money staff of the payment's servicer (`has_role(admin, ops_manager)`); for each live `allocation`/`forward`
entry of the payment that `entry_remitted` finds: `{entry_id, account_id, run_number, booked_on, amount_minor}`
([check 1] and `paid_on`, `paid_how`, `paid_run_number`, §3.2.1).

**3.2.11 `private.run_advance_checks(p_check_run_id uuid, p_organization_id uuid, p_today date default null, p_full
boolean default false)`** — one statement per check into `payment_check_result` (§3.4); [check 2] `p_full` widens
`remitted_reversal_uncovered` from the delta window to every booked run (§3.4); every other check ignores it. Later
slices redefine it with this signature (`create or replace`). **`private.run_remittance_checks`** redefined (from
`20261115090000:3710`, 11 lines; same signature `(uuid, uuid, date)`, so `run_payment_checks`' calls with two
arguments, `20261118100000:3865`, stay as they are) to also call it with **`p_full` = the Paris date the checks hold
the books to (`coalesce(p_today, private.paris_today())`) is the 1st of a month, or
`private.advance_full_check_take(p_organization_id, p_check_run_id)`** returns true.
- [check 2] **On demand: `public.request_full_advance_check(p_idempotency_key text, p_organization_id uuid) returns
  jsonb`** — « Vérification complète des avances » on « Contrôles »: admins of that servicer
  (`private.has_role(org, array['admin'])`, aal2 for staff); replay + request hash (`private.command_replay` /
  `command_record`, command `request_full_advance_check`). Refusal (« advance check refused: <code> »,
  `check_violation`): `already_requested` (an open request of the servicer: the partial unique index below, so two
  admins at once get one row and one refusal). Inserts the request, then queues the ordinary checks job
  (`pgmq.send('payments', {type: 'invariants', organization_id})`, as `public.request_payment_checks`,
  `20261110120000:1903`), and returns `{request_id, queued: true}`. The full pass therefore runs inside an ordinary,
  complete check run — the one « Contrôles » shows (it reads the latest `payment_check_run`) — never in a run of its own
  that would hide the other checks.
- [check 2] **`private.advance_full_check_request (id uuid pk default gen_random_uuid(), organization_id uuid not null →
  organization, requested_by uuid not null → app_user, requested_at timestamptz not null default clock_timestamp(),
  run_id uuid null → payment_check_run, taken_at timestamptz null)`**; partial unique index `(organization_id) where
  run_id is null`; RLS on with no policy, every privilege revoked from `public`, `anon`, `authenticated` (as
  `private.remittance_schedule_failure`, `20261112090000:2453`); a row guard (`enable always`): only `run_id` and
  `taken_at` may change, once, from null, to a run of the same servicer; `private.refuse_change` on delete and
  truncate; the change log (`private.log_change`: who asked). **`private.advance_full_check_take(p_organization_id
  uuid, p_check_run_id uuid) returns boolean`** (SECURITY DEFINER, EXECUTE revoked): `update … set run_id =
  p_check_run_id, taken_at = clock_timestamp() where organization_id = p_organization_id and run_id is null returning
  true` — a check run that fails rolls the take back with it, so the request waits for the next run.

**3.2.12 Redefinitions** (whole copies, the change only):
- `public.reverse_allocation` (from `20261109190000:1079`): after the loop, `perform private.cover_remitted_reversals
  (v_reversals); perform private.ledger_check_now();`; its result gains `advances` (`[{advance_id, amount_minor}]`).
- `private.debit_post_rows` (from `20261110120000:549`): step 1 collects every reversal it posts (`v_revs uuid[]`), then
  `perform private.cover_remitted_reversals(v_revs)` before step 2. Its caller `private.post_debit_links` (both modes,
  then `ledger_check_now`) is unchanged: a refused link (LG009, LG008) still becomes `posting_failed` in the job's mode
  and « debit link refused » in ops' strict mode. Partial returns: M2b-6 reverses every allocation and forward of the
  payment, so each remitted one is covered in full; the part ops re-allocate later is a new item (founder Q1).
- `private.bank_booking_post_rows` (from `20261121090000:808`): between step (3) (settlements) and step (4) (overrun
  cover): `perform private.cover_booked_run_reversals(<payout rows' tr_run in ord order>, <their line_date>, <their
  transfer>, <their line>)`. Step (4) reads the balances after these covers: an overrun advance arises only for what no
  reversed line explains. [critic] F10: step (4)'s `payout_overrun` advance gets `mandate_id` = the single mandate of
  that run's lines (computed once per run, keyed by the run's line primary key prefix), else null.
- `private.approve_remittance_run` (from `20261114090000:786`): in the N = 0 branch, after `post_run_settlement`:
  `perform private.cover_booked_run_reversals(array[r.id], array[v_today]);` (a same-run pair inside it posts nothing:
  [critic] M7-MONEY-1).
- `private.transfer_line_post` (from `20261118100000:2163`): in the unplanned-return branch, after the reversal of
  `ub_entry` (and of `ub_adv_entry`): `perform private.remitted_cover_release(v_ret.ub_entry, l.id, l.booking_date);`.
  [critic] F10: the `double_payout` advance it posts gets `mandate_id` = the single mandate of the lines (released or
  not) of that transfer's run, computed once, else null.
- [critic] F5 `public.remittance_run_payout` (from `20261118100000:4380`, 128 lines; added to the size table): its
  `advances` list reads, by `client_advance_transfer_idx`, the advances of causes `payout_overrun` **and**
  `remitted_reversal` posted at this chain's debit (`transfer_id` = a transfer of the chain), with their cause; the run
  page note (`runs.ts:376`) words each by cause (§3.7).

**3.2.13 [critic] M7-MONEY-2, F2 `private.advance_in_flight_run(p_advance_id uuid) returns table (run_id uuid,
run_number text)`** (stable): the approved or sent run of the advance's client and currency whose
`settlement_plan -> 'settles'` names the advance (`kind 'advance'`, `document_id`); runs read by
`(client_organization_id, currency)` and status (a handful), their plans' `settles` scanned in memory. Every path that
reverses, releases, writes off, pays or requests an advance calls it: `remitted_cover_release` (7a),
`transfer_line_check`'s `double_payout` rule (7b), `write_off_advance` (7b), 7c's commands.

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
| `remitted_reversal_uncovered` | violation | `ledger_entry` (R) | gap(R) ≠ 0 (pair-aware T, §2.1), over [critic] F9 the reversals posted since the last completed check run of the servicer (less one day of overlap), the reversals of the live lines of the runs booked since then, the reversals of items with `unplanned_paid_item` rows booked or reversed since then, and the reversals listed uncovered by the previous run; with `p_full` ([check 2] the check run of the 1st of each month, Paris, and the next check run after an admin's `request_full_advance_check`, §3.2.11) every booked run; amount = gap; details `{client_id, reversed_entry_id, run_id, target, held}` | covered (« Couvrir ») |
| `advance_ledger` | violation | `client` | per (client, currency): Σ over its advances whose entry is not reversed of (amount − Σ settlements `document_kind 'advance'`) ≠ Σ 4112[c] postings (I18's advance half, design §5.4) | consistent |
| `advance_open` | alert | `client_advance` | open > 0 and created more than 30 days before today (Paris); amount = open; `oldest_days`; details `{client_id, cause, mandate_id, created_on}` (7b adds `recovery`, 7c `requested_on`, 7d leaves out pre-opening advances of clients in a proceeding) | open = 0 or its entry reversed |

Reads: [critic] F9 the day's reversals by a new partial index `ledger_entry_reversal_posted_idx (organization_id,
posted_at) where entry_type = 'reversal'` (no `(organization_id, entry_type)` index exists, `20261108170000:146-151`),
the runs booked since by `remittance_run (organization_id, booked_on)` (index added if absent), their lines by
`run_id`, each reversal by `ledger_entry_reversed_once_uq`, advances by `client_advance_cause_idx`, settlements by
`commission_settlement_document_idx`, 4112 by the few `client_advance_receivable` accounts: one materialized CTE per
input, keyed laterals (`offset 0`), as `run_transfer_checks` does. The nightly's cost follows the day's activity, not the
whole history (LG009 already holds I23 at every commit; the nightly is the backstop, and the monthly full pass catches
anything a bug let through). Bounds §8.3. The existing alerts keep their SQL; their texts change (§3.7).

### 3.5 RLS and tenant isolation
[check 2] One new table, private (§3.2.11). New read `allocation_remitted`: money staff of the payment's servicer,
« not allowed » otherwise. Cover entries are `client_advance` entries: the client's whole-client members read them (6b
policy); restricted users and collectors do not. pgTAP 043 asserts: client A never reads B's advance; restricted viewers
and collectors read none; `authenticated` cannot execute `cover_remitted_reversals`, `cover_booked_run_reversals`,
`remitted_cover_release`, `remitted_cover_post`, [check 2] `run_advance_checks`, `advance_full_check_take`, nor insert
into `client_advance`; [check 2] (019-style) `private.advance_full_check_request` has RLS on, and `anon` and
`authenticated` can neither select, insert, update nor delete it; `authenticated` may execute
`request_full_advance_check`, which refuses « not allowed » to an ops manager, to an admin at aal1 and to another
servicer's admin, and writes nothing then.

### 3.6 Worker
- `ledger/model.py`: `RemittedReversalUncoveredError` (LG009).
- `jobs/debits.py`: a link refused LG009 is `posting_failed`, as LG008 (the SQL sends it to review with its detail).
- The prepare is unchanged: advance items already exist (`client_advance`, basis 0, no deadline, design §9.2).

### 3.7 Web (French copy)
- `lib/payments/debits.ts` CHECK_LABEL:
  - `remitted_reversal_uncovered`: « Annulation d'un encaissement déjà reversé sans avance du cabinet » / « Un
    encaissement déjà versé au client a été annulé sans que le cabinet en fasse l'avance : la somme serait déduite des
    autres encaissements du client, une compensation faite sans l'avance ni la clause qui la prévoit. « Couvrir »
    enregistre l'avance. » ([critic] L19 (a): the draft's « qu'aucune clause ne permet » was false under a claw-back
    clause.)
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
  encaissements. » [critic] L19 (d): the draft's « Elle sera récupérée selon son mandat » goes until 7b builds a
  recovery (7b adds the sentence). [critic] L5: when the run's payout came back and is not paid again (`paid_on` null),
  the first sentence reads « Compris dans le reversement RV-… (revenu, à verser de nouveau) ». [check 1] The first
  sentence follows `paid_how` (§3.2.1): `set_off` « Déjà réglé au client par compensation dans le relevé RV-… du
  JJ/MM/AAAA » and `netted` « Déjà compris dans le relevé RV-… du JJ/MM/AAAA (montant net nul) », never « débité ».
  Toast: « Imputation annulée ; avance du cabinet de X € enregistrée. »
- [critic] L19 (b), F5: the run page note (`lib/remittance/runs.ts` l.372–379) is worded per cause from
  `remittance_run_payout.advances`: `remitted_reversal` « Avance du cabinet enregistrée le JJ/MM/AAAA : encaissement de
  ce reversement annulé ou repris (X €) »; `payout_overrun` « … reversement débité au-delà de ce qui restait dû »;
  `double_payout` « … virement exécuté hors reversement ». Dates are recording dates (§2.1).
- « Débits et retours », a return of such a payment: « Paiement déjà reversé au client (RV-…) : au retour, le cabinet lui
  avance X €. »
- « Contrôles »: « Couvrir » on `remitted_reversal_uncovered` (admins): « Enregistrer l'avance du cabinet de X € au
  client Y pour l'annulation du JJ/MM/AAAA »; refusals `nothing_to_cover` « Rien à couvrir : l'avance existe déjà. »,
  `gap_changed` « Le montant a changé : rechargez la page. », `over_covered` « L'avance dépasse l'encaissement annulé :
  prévenez le support. »
- [check 2] « Contrôles », admins: « Vérification complète des avances » (`request_full_advance_check`), help « Les
  contrôles de chaque nuit relisent les annulations récentes ; le 1er du mois, ils relisent tous les reversements
  débités. Ce bouton lance cette relecture complète avec les contrôles, maintenant. »; toast « Vérification complète
  demandée : elle passe avec les contrôles lancés maintenant. »; refusal `already_requested` « Une vérification
  complète est déjà demandée : elle passe avec les prochains contrôles. »
- Screenshots (mobile + desktop): `m2c7-desimputer-deja-reverse`, `m2c7-controles-couvrir`; `m2c-controles` retaken.

### 3.8 Switch
As §2.4. With it on: the late predecessor's booking (6b-3a-2 E, through `bank_booking_post_rows`) covers its run's
reversed lines; a release (3.2.8) needs an unplanned booking, so a cancellation after download.

### 3.9 Tests (written first, seen failing)

**pgTAP `supabase/tests/043_remitted_reversal_cover.test.sql`** (≈ 70; fixtures as 035/037: a servicer, Martin and
Lilas, their mandates, runs built through `approve_remittance_run` and booked through `post_bank_bookings`):
1. `reverse_allocation` of an allocation in a booked run → one advance (cause, `cause_entry_id` = R, amount = line,
   mandate = line's, key `adv:<R>`); the queue holds R −A and A1 +A; the client's other pending items unchanged; the
   result lists the advance. [critic] F3: **dated greatest(R's date, the run's `booked_on`)** — with a back-dated
   « Désimputer » (allocation 12/10, run debited 03/11, reversal on 20/11: R dated 12/10, advance dated 03/11), and
   4670[c], 4679, 4112[c] read at 31/10 show no advance; a reversal after the payout keeps R's date.
2. Same with nothing else pending → no LG008, no `payout_overrun`.
3. A pending (unremitted) allocation reversed → no advance; the queue nets the pair.
4. An allocation in a draft, approved or sent run reversed → no advance; its payout then booked → advance
   `adv:<R>:<run>` at the debit date, carrying the payout's `transfer_id` and debit line ([critic] F5); **no**
   `payout_overrun`; the booked-run check clean; `remittance_run_payout(run).advances` lists it (cause
   `remitted_reversal`).
5. [critic] M7-MONEY-1, F1 (replaces the draft's case 5, which encoded the bug): **5a** a same-run pair (E and R both
   pending at the prepare) in an N = 0 run booked at approval → no advance, no LG009; **5b** the same pair in a run with
   other lines whose payout is booked by the debit job → no advance for E, no LG009; **5c** a run cancelled before
   download (E released), R posted, the next run carrying the pair, booked → no advance; **5d** a line reversed after its
   in-flight run's approval (R in no run), the run then booked → advance (the at-booking rule still holds); **5e**
   switch on: a pair plus an unplanned attribution of E (T = the attribution, covered), then U returned → the cover
   released, no advance left, no LG009; **5f** [check 1] switch on, Q17's default (a): X's payout cancelled after
   download (E released), U executed late and its −A `unplanned_payout` row attributes E, the next run Y holds E (+A)
   and U's row (−A) → N = 0, booked at approval; then R(E) → E is remitted in Y, T = A, cover A1 = A (`adv:<R>`); then U
   returned → U's reversal re-queues +A, A1 stays (T unchanged, no release), no LG009; the queue holds +A (the client is
   paid A again) and A1 is open; `entry_remitted(E).paid_on` null until the re-queued +A is paid (§3.2.1 rule 4), so a
   request is refused `payout_not_received` until then; with a claw-back clause the next run takes A1 from the +A
   (net 0), without one the client is paid A and asked for A once paid (Q17, OQ-97).
6. An M2b return in ops' strict mode (`link_debit 'return'`) of a payment with an allocation and a forward in a booked
   run → two advances; a partial return → every remitted entry covered in full.
7. The job's mode (`apply_debit_decisions`), a chunk of three returns, one of a remitted payment → its advance, the other
   two posted; a planted raw reversal in the chunk → that link `posting_failed` (LG009); [critic] F18 two remitted
   returns in one chunk and a retry in the same transaction → `_rcv` begun three times, no « already exists ».
8. « Retour au-delà du paiement » (`link_debit 'loss'`) of a remitted payment → the M2b part covered + `servicer_loss`.
9. A raw `private.ledger_reverse` of a remitted allocation → `private.ledger_check_now()` throws LG009.
10. A run set booked with a reversed line and no cover (direct update in a subtransaction) → LG009 at
    `ledger_check_now()`; [critic] the same with a same-run pair → no LG009.
11. Switch on: a cancelled run's item attributed by an unplanned booking (P), then reversed → advance = the attribution;
    the unplanned return (`book_transfer_line … unplanned_payout_returned`) → the cover reversed (`return:rr:…`), queue
    and 4670 as without the pair; two bookings attributing one item, one returned → re-post of the remainder; a cover
    with a settlement (planted) → « transfer line refused: advance_settled », nothing booked; [critic] M7-MONEY-2 a cover
    named by an approved run's planted `settlement_plan.settles` → « transfer line refused: advance_in_flight », nothing
    booked.
12. Switch on: a late predecessor booked as its run's payout with a reversed line → at-booking cover.
13. Idempotency and roles: `reverse_allocation` replayed → one advance; `cover_remitted_reversal` on a covered reversal →
    `nothing_to_cover`; stale expected gap → `gap_changed`; an ops manager or aal1 → not allowed; [critic] F18 after a
    release left a gap (planted), « Couvrir » posts under `adv:<R>:cov:<key>` and the gap closes.
14. Nightly: every case leaves `remitted_reversal_uncovered` and `advance_ledger` empty; a planted raw reversal (inside
    the test's transaction, never committed) → one violation with its gap; a planted settlement on an advance →
    `advance_ledger`; `advance_open` with `p_today` = created + 31 → one alert, + 30 → none; [critic] F9 a planted gap on
    a reversal posted 40 days before the last clean run is not read by the delta pass and is found by `p_full`; the
    reversal listed uncovered yesterday is re-read today. [check 2] `run_remittance_checks` with `p_today` = 2026-12-01
    passes `p_full` (the old gap found), with 2026-12-02 does not (not found); `request_full_advance_check` by an admin
    at aal2 → one request row and one queued `invariants` message; the next `run_payment_checks` of that servicer takes
    it (`run_id` set to that run, `taken_at` set) and finds the old gap, the run after it does not take it again; a
    replay of the request → the same result, one row; a second request while one is open → `already_requested`; an ops
    manager, an admin at aal1, another servicer's admin → « not allowed », no row; a check run that raises after the
    take (planted, in a subtransaction) → the request still open; a raw update of a taken request's `run_id`, and a
    delete → refused by its guard.
15. RLS (§3.5); [check 2] the request table's and the new functions' grants (019-style).
16. Pins of today's behaviour, flipped and justified in the ADR. [critic] F4: the list below was drawn from the suites
    at `1440178`; the builder first runs every suite (pgTAP 017–042 and every worker integration file) against a
    prototype of the 7a migration and completes the list before writing the tests, each flip with its file, line, new
    value and reason in the ADR; none is deleted or weakened:
    - 017 l.293–305 stays (a raw reversal of an entry in no run: LG008 still guards it);
    - 037 `d_f5` (l.2169) and `d_ml1_signed` (l.2329) raw-reverse a booked run's line — each keeps its purpose by making
      the queue's negative item a reversal of a line of a run **in flight** (no cover then, §13 #3) and asserts the
      at-booking cover when that run is booked (`d_f5`: queue_before 31 000, P 31 000, advances `double_payout:10000`
      then `remitted_reversal:10000` at R2's booking, queue_end 10 000);
    - 035 §5 (l.1411–1449, run r8, « Petit's collection reversed after the approval ») and its RLS rows (l.1543–1556):
      cause `payout_overrun` → `remitted_reversal`, same amount;
    - 037b `d_ml1_cover` (l.1472–1547): `['payout_overrun:3000']` → `['remitted_reversal:3000']`, `r0_page` lists it;
    - 040 F5b (l.1319–1343): `[["payout_overrun", true]]` → `[["remitted_reversal", true]]` on the run page;
    - 023 l.492ff (`reverse_allocation` in booked r1): r5's draft gains the +300 000 cover item;
    - worker `test_remittance_runs_integration.py` around l.550, `test_remittance_documents_integration.py:540`,
      `test_manual_credit_note_integration.py:112` (a reversal of a booked run's allocation): the next run's gross gains
      the advance item; `test_remittance_runs_integration.py:261` (same-run pair) stays **unchanged**.
    Every other assertion of the suites that reverses a booked run's item raw goes through a covering path or expects
    LG009. **The overrun backstop after 7a**: every 4670 debit at a booking now comes from a reversed line of the booked
    runs, which the at-booking cover meets first, so step (4) is believed unreachable; it stays as LG008's guarded
    backstop and keeps one test: a planted raw 4670 debit (a forged posting inside the test's transaction) before a
    booking → `payout_overrun` advance of that amount.
17. [critic] M7-MONEY-8, L5 (D1): RV-1 booked, its payout returned (account `returned`, +N re-queued), then P1 returned
    → A1 posted (D1 kept) and `entry_remitted(E).paid_on` null; after the re-queued item is paid in RV-2, `paid_on` =
    RV-2's debit date. [check 1] (a) `paid_how = 'paid'`, `paid_run_number` RV-2 (rule 3 of §3.2.1; the draft's
    `remittance_run_paid_on(RV-1)` stays null for ever); RV-2 itself returned too → null again, then paid by RV-3 → RV-3's
    date (depth 2); (b) an N = 0 run with D > 0 holding E → `paid_on` = its `booked_on`, `paid_how = 'set_off'`; with
    D = 0 (switch on, an unplanned −P row) → `netted`; (c) the re-queued item still in a draft or an approved run →
    null; (d) [check 2] switch on: RV-1's payout T1 cancelled after download and re-issued as T2, T1 executed late and
    booked as RV-1's payout (late predecessor: T1 stays `cancelled`, T2 cancelled), then T1 returned (its
    `payout_returned` booking; T1's `return_entry_id` stays null), +N re-queued and paid by RV-2 → `paid_on` = RV-2's
    debit date, `paid_how = 'paid'`, `paid_run_number` RV-2; before RV-2's debit → null and a request refused
    `payout_not_received`.
18. [critic] F6: a raw `private.ledger_reverse` of a `remitted_reversal` cover's entry → LG009 at `ledger_check_now()`;
    the release (case 11) is not refused.
19. [critic] F12: the full list of check codes `run_advance_checks` emits equals the expected set (extended by each
    later slice).

**Worker.** Integration `tests/test_remitted_reversal_integration.py` (db job, the real debit job, synthetic camt.053
from `synth camt053 --debits-of`): §7 from 12/11 — P1's return line → A1 in the same transaction as the return; the
positions table at 12/11 (5120 107 500 = the bank, 4679 +200 000, 4670 Martin −300 000); RV-3 prepared: gross 300 000,
N 282 000, D 18 000 (until 7b). Flip `tests/test_remittance_runs_integration.py::
test_the_worked_example_continues_a_credit_note_on_a_settled_invoice` (l.459): « without the advance » → with it (gross
300 000, refund 36 000, net 282 000), its docstring saying why. **Concurrency (two connections)** — « Désimputer » of a
remitted allocation against `generate_transfer_file` and against the client's approval job → no deadlock, one waits, no
double cover; [critic] F14 `reverse_allocation` and `link_debit 'return'` of a line of run X against
`post_bank_bookings` of X's payout, in both orders (each session pausing after its first lock, as 6b-1's deadlock tests
do) → exactly one advance (`adv:<R>` or `adv:<R>:<X>`), no LG009; « Couvrir » against the at-booking cover of the same R
→ one advance. `tests/ledger_machine.py`: the `reverse` rule may mark an entry remitted; the oracle expects an advance
after a covering reversal and LG009 after a raw one (entry level; the full machine is 7f).

**vitest**: the three checks' labels, the two reworded helps, the LG009 and 55P03 mappings, the « Désimputer » and
return sentences (with and without remitted entries, and with a payout that came back; [check 1] one per `paid_how`,
none saying « versé » or « débité » for `set_off` or `netted`), the run page note per cause,
« Couvrir » refusals. **E2E** (desktop + mobile): « Désimputer » a remitted allocation → the sheet says it, the advance
shows on the client's run page, « Contrôles » shows no violation.

**Mutants** (each killed by a named test): cover keyed on any live line, booked or not → cases 3/4; [critic] the
same-run exclusion dropped → cases 5a–5c and the worker test l.261; advance dated at R's effective date → case 1
(back-dated); advance dated today → case 1; the `cover_booked_run_reversals` call removed from `bank_booking_post_rows`
→ case 4 and `d_f5`; T counting attributions when the item is remitted → case 11 (item then booked); check `gap > 0`
instead of `<> 0` → case 11 (release skipped); release not called → case 11 (LG009 at the return); the release's
in-flight test removed → case 11; the cover-reversal branch of `remitted_cover_check` removed → case 18;
`ledger_check_now` without the new constraints → cases 7, 9; [check 1] `paid_on` read from `remittance_run_paid_on`
only → case 17 (a), (b); [check 2] rule 3 reading the chain's `bank_transfer.return_entry_id` → case 17 (d);
`run_remittance_checks` passing `p_full` false always → case 14 (the 1st of the month and the request); the take
without `run_id is null` (a request taken by every run) → case 14 « the run after it »; the N = 0 branch worded
`paid` → case 17 (b) and the vitest wording; the unplanned-return branch of rule 4 dropped → case 5f; the nightly's `not exists` inverted → case 14; the delta
window without its overlap → case 14; `advance_open` at ≥ 30 days → case 14 boundary; `remittance_run_payout` reading
`payout_overrun` only → case 4; a cover statement reading the lines before `payments:<org>` is taken → the F14
two-session test.

### 3.10 Docs (7a)
ADR-0014 « M2c-7a » (D1–D4, D12, D13, LG009, the pins flipped with file, line and reason; [check 2] the full pass and
its request table); COMPLIANCE CPCE-02
(« Until M2c-7's advance … » replaced by the built rule), OQ-38 (partial return default), OQ-82 (residual closed), new
OQ-97 (D1, [critic]); DOMAIN « Avance de couverture » (cause `remitted_reversal` posted; a same-run pair is not remitted;
its date), LG009; design §13 annotated « As built (7a) »; benchmarks (§8.3 rows 1–2); PROGRESS.

---

## 4. 7b — Claw-back and write-off

Branch `m2c7b`. Migration `<timestamp at PR open>_advance_recovery.sql` ([critic] F12). Closes D03, D07, part of D17.

### 4.1 Functions
**4.1.1 `private.advance_open(p_advance_id uuid) returns bigint`** (stable): 0 when the advance's entry is reversed;
else `amount_minor − Σ commission_settlement.amount_minor` (`document_kind 'advance'`, `document_id` = id; every kind:
compensation, payment_own, payment_dedicated, write_off).

**4.1.2 `private.advance_mandate(p_advance_id uuid) returns uuid`** (stable): [critic] F10 `client_advance.mandate_id`,
which 7a sets at insert for every cause (the line's for `remitted_reversal`; the single mandate of the payout's run
for `payout_overrun` and `double_payout`, computed once by the poster); null otherwise (a client part with no
transfer, 6b-2 S13; a run of several mandates). The draft derived it from the run's lines on every read (O(run lines)
per advance, per prepare, page row and nightly). A null mandate is never clawed back (`settlement.py` takes nothing for
`NO_MANDATE`): repayment request only (founder Q2). No back-fill: the stack holds no advance (probe); an advance posted
before 7a with a null mandate stays « request only ».

**4.1.3 `private.advance_born_on(p_advance_id uuid) returns date`** (stable): the advance entry's effective date —
[critic] F3 since 7a dates a cover no earlier than the payout it covers, that date is already the earliest the claim
can be born; the draft's least(…, `booked_on`) is no longer needed. 7b filters by it as invoices are filtered by their
issue date today; 7d changes the opening and the criteria (§6).

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
write-off refused: <code> »): `not_open`, `amount_exceeds_open`, `open_changed` (open ≠ expected), `in_flight`
(`private.advance_in_flight_run`, §3.2.13: its payout's debit settles it), `evidence_required`
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

**4.1.9 [critic] M7-MONEY-7 — an advance's queue items count in its mandate's money.** Today the prepare's facts give
an item `coalesce(e.account_id, p.account_id)` (`jobs/remittances.py:321-328`): a `client_advance` entry has neither, so
its +A item lands in `NO_MANDATE` gross while R(E)'s −A stays in mandate M (`run.py:552-556` sums gross by the line's
mandate, `run.py:330-332` takes it from the file). `settlement._takes` caps `take_adv` at M's room
(`settlement.py:262-277`), so through the real prepare RV-3 would give N 200 000 and D 100 000 with 118 000 of A1
left open, not the design's 82 000 / 218 000 (the draft's unit test fed `{'M': 300 000}`, not what `_plan` builds).
Change: the facts query reads, for `client_advance` and `client_advance_reversal` items, the advance's `mandate_id`
(`client_advance` by `entry_id` — the reversal's by its `reverses_entry_id`), and `_plan`/`priced()` use it as the
line's mandate (no file, no commission, no deadline, as today); `remittance_line.mandate_id` is written from it.
[check 1] The line insert guard's latest body (`private.remittance_line_insert_guard`,
`20261113090000_remittance_documents.sql:1860`, 34 lines) checks the run's scope and the 4670 amount only, never
`mandate_id`; 7b redefines it to add one check: a line of kind `client_advance` or `client_advance_reversal` carries
`mandate_id` = its advance's `client_advance.mandate_id` (by `entry_id`, or by the reversed entry for a reversal;
null with null), « remittance line %: an advance item outside its advance's mandate » (`check_violation`). An advance
with a null mandate stays in `NO_MANDATE` gross, paid gross and never netted (its +A item and the request recover it).

**4.1.10 [critic] M7-MONEY-2, F2 `private.transfer_line_check`** redefined (from `20261119090000:739`, 802 lines; in
7b's size): its `double_payout` rule (`20261119090000:1421-1424`, which reads only `commission_settlement`) also refuses
`advance_in_flight` when `private.advance_in_flight_run` names the advance; `transfer-lines.ts` maps it (§4.3). From 7b a
plan can take a `double_payout` advance, and `post_run_settlements` posts its Da at the payout's debit without
re-checking the advance: an unplanned return booked in between would reverse the advance and the debit would then
post −4112 against nothing (or, under 4.1.5's guard, fail and leave 5120 ≠ bank).

**4.1.11 [critic] F11 Evidence kinds.** `public.register_client_document` accepts only `payout_rib`,
`mandate_document`, `client_status_evidence` (`20261111120000:604`); the restrictive `document_client_money_scope` and
`private.can_read_client_document(_object)` list the same three. 7b redefines the three functions and recreates the
policy with `advance_write_off_evidence` (readable by money staff only: never by the client's members, restricted
viewers or collectors); 7c adds `client_payment_evidence`, `client_refund_evidence`, `payment_designation_evidence`
the same way, 7d `payout_authority_evidence`. pgTAP per kind: staff yes; client admin, restricted viewer, collector and
another tenant no.

`ledger_entry_type` label of `advance_write_off`: « Avance passée en perte » (staff-only book; LEX-28: never « abandon »
or « remise » toward the client).

### 4.2 Worker (the prepare)
- `jobs/remittances.py` facts: `open_advances` — `select a.id, a.mandate_id, a.cause,
  private.advance_born_on(a.id), private.advance_open(a.id) from public.client_advance a where
  a.client_organization_id = %s and a.currency = %s` (`client_advance_client_idx`), kept when open > 0; in
  `inputs_hash` (id, open, mandate; sorted). [critic] The item facts carry the advance's mandate for advance items
  (4.1.9).
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
  l.372–379, [critic] L19 (b) worded per cause as in §3.7, never « paiement repris par la banque » for a « Désimputer »,
  an overrun or a double payout): « Avance du cabinet enregistrée le JJ/MM/AAAA (<cause>) : 2 000,00 €, déduite de ce
  reversement par compensation (clause de reprise, art. 7.4 du mandat) » or « … à récupérer par une demande de
  remboursement (pas de clause de reprise) ». The « Désimputer » sheet regains, per the advance's recovery, « Elle sera
  reprise sur ses prochains reversements (art. … du mandat) » or « Une demande de remboursement pourra lui être
  adressée » ([critic] L19 (d)).
- `transfer-lines.ts`: `advance_in_flight` « Cette avance est reprise par le reversement RV-… en cours : ce retour sera
  comptabilisable après son débit (il sera alors refusé comme avance déjà récupérée : prévenez le support). »
  ([critic] F2).
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
known limit, support's exit (§10 note). [critic] F2: while an approved or sent run plans to take it, the return is
refused `advance_in_flight` (switch off and on alike: a `double_payout` advance arises with the switch off, from a
returned payout executed again), and so is a release of a `remitted_reversal` cover (switch on).

### 4.5 Tests
**pgTAP `044_advance_recovery.test.sql`** (≈ 35): `advance_open` after a compensation, a write-off, a reversal;
`document_open(advance)`; `advance_mandate` (the line's; a one-mandate run; two mandates → null; client part → null);
approval sent back `documents_changed` when an advance was written off between prepare and approval; a planned advance
settle posted at the payout's debit (`commission_settlement` compensation, −4112 Da); `write_off_advance` (admin yes,
ops manager no, aal1 no; amount rules; compare and set; in flight; evidence; replay; LG003 on its reversal; I18 clean);
the settlement guard (planted over-settlement refused); `client_advances` staff only; the evidence kind's RLS (each
role, 4.1.11). [critic] M7-MONEY-2, F2, with the switch off and on: a `double_payout` advance taken by an approved run,
then its unplanned return → refused `advance_in_flight`, nothing booked; after the run's debit → `advance_settled`; the
same for a `remitted_reversal` cover's release (switch on). [critic] M7-MONEY-7: the advance item's line carries the
advance's mandate; a null-mandate advance's line has none; [check 1] a planted line of an advance item with another
mandate → refused by the insert guard (mutant: the guard's new check removed).

**Worker.** Unit: `run._plan` passes advances (mandate, nettable); `inputs_hash` changes with an advance's open.
[critic] M7-MONEY-7: the unit, Hypothesis and integration tests go through `run._plan` with the facts **as loaded**
(an advance item with no account, its mandate from the advance), never `settlement.plan` alone.
Hypothesis (extends `test_settlement.py`): the plan never takes an advance beyond its open, never one of `NO_MANDATE`,
never from another mandate's gross; N + D = gross. Integration — **§7.2 end to end from 12/11**
(`test_remitted_reversal_integration.py` continued): RV-3 N 82 000, D 218 000; E11 +82 000 4670 / −82 000 5120; E12
+218 000 4670 / −218 000 4679 ‖ +218 000 4689 / −18 000 4111 / −200 000 4112 ‖ +9 000 44574 / −9 000 44571; E13
sweep 218 000; the positions table row by row (12/11 → 18/11); the servicer fund at the end (5122 +114 864, 7060
−95 720, 44571 −19 144, 4111, 4112, 4689, 44574 = 0); Martin received 246 000. The 7a RV-3 assertions flip to these.
**vitest**: advances labels and recovery modes, write-off sheet and refusals, the chip. **E2E**: « Avances », a
write-off by an admin (mobile + desktop).
**Mutants**: advances passed as `[]` → RV-3; `nettable` ignored → proceeding case; `document_open`'s advance branch
removed → approval case; the guard's `<=` → `<` → planted case; write-off allowed to ops managers → role case; [critic]
the advance item's mandate dropped (`NO_MANDATE`) → RV-3 (N 200 000 instead of 82 000); `transfer_line_check`'s
in-flight test removed → the in-flight case; a new evidence kind left out of the restrictive policy → its RLS case.

### 4.6 Docs (7b)
ADR-0014 « M2c-7b »; COMPLIANCE OQ-38 (claw-back built: clause only, the mandate rule), new OQ-88 (write-off,
accountant); DOMAIN « Avance passée en perte », « Reprise des avances »; PROGRESS.

---

## 5. 7c — Client settlements: payments, refunds, repayment request

Branch `m2c7c`. Migration `<timestamp at PR open>_client_settlements.sql` ([critic] F12). Closes D04 (letter), D05, D06, S27 (6b-2 Q13).

[check 1] **Two PRs.** **7c-1** (branch `m2c7c-1`, migration `<timestamp>_client_payments.sql`): §5.0, the
`client_credit` and recovery tables of §5.1, §5.2.1–§5.2.6, the checks of §5.2.8 that concern them, §5.5 but the
request, 045 parts (b)–(f), (i). **7c-2** (branch `m2c7c-2`, migration `<timestamp>_repayment_requests.sql`): the
request tables of §5.1, §5.2.7, `repayment_request_document_missing`, §5.3, §5.4's letter and job, the request's web,
045b parts (a), (g), (h). Each ships alone; 7c-2 merges after 7c-1.

### 5.0 [check 1] The books and shapes 7c-1 adds (gap 2; the draft's §2.3 « unchanged » was wrong)
At `1440178` the posting of §2.3's three client-money types is refused: `public.ledger_book` has no 419 or 7714 row;
the three types' `allowed_books` (`20261111090000:75-103`) do not list them; `private.ledger_post_set` and the
`ledger_account_shape` check list books by name and refuse any other (`else false`); and the I3′ shapes
(`private.ledger_entry_verify`, `20261111090000:470-482`) require `n_com + n_adv ≥ 1` for both client payments and one
4111 debit for `client_refund_own`. 7c-1's migration, in this order:
1. **Books** — `insert into public.ledger_book (code, account_number, label_fr, dimension, money_of, normal_side,
   client_visible)`: `('client_credit_owed', '419', 'Mandants — sommes à leur rembourser', 'client', 'servicer', -1,
   false)` and `('written_off_recovered', '7714', 'Rentrées sur avances passées en perte', 'pooled', 'servicer', -1,
   false)` (numbers are Collectoo's labels: OQ-88, OQ-98).
2. **Types** — `allowed_books` of `client_payment_own` and `client_payment_dedicated` gain both books;
   `client_refund_own` gains `client_credit_owed`; `advance_write_off`'s label becomes « Avance passée en perte »
   (LEX-28, §4.1).
3. **Account shape** — constraint `ledger_account_shape` recreated (from `20261111090000:161`): `client_credit_owed`
   joins the per-client books (client set, nothing else), `written_off_recovered` the pooled ones.
4. **`private.ledger_post_set`** redefined (whole copy from `20261111090000:889`, 316 lines): `client_credit_owed`
   joins the per-client book lists (the line's client, l.924; the given-client rule, l.953; the client check, l.1020),
   both books join the servicer-fund closure list (l.1064). Nothing else changes.
5. **`private.ledger_entry_verify`** redefined (whole copy from `20261111090000:295`, 264 lines): two counts
   `n_cco`/`d_cco` (419) and `n_rec`/`d_rec` (7714); `client_payment_own` = `n_own = 1, d_own = 1, n_com ≤ 1, d_com = 0,
   n_adv ≤ 1, d_adv = 0, n_cco ≤ 1, d_cco = 0, n_rec ≤ 1, d_rec = 0, n_com + n_adv + n_cco + n_rec ≥ 1`, VAT pair as
   today, `n = 1 + n_com + n_adv + n_cco + n_rec + n_vatp + n_vatc`; `client_payment_dedicated` the same with its
   three fund lines (`n = 3 + …`); `client_refund_own` = `n = 2, n_own = 1, d_own = 0` and exactly one of (`n_com = 1,
   d_com = 1`) or (`n_cco = 1, d_cco = 1`); no other type may touch either book (their `allowed_books` already refuse
   it). I2′ needs no change (it reads `money_of`).
6. **Reads** — policy `ledger_account_read` and `public.ledger_balance` (from `20261111090000:1394`, `:1416`) list both
   books for money staff; `public.accounting_export_entries` (from `20261116090000:4494`, 80 lines) adds both to its
   servicer-fund book list (otherwise the export of a client payment would not balance).
7. **Identities** (nightly, `run_advance_checks` from 7b's body): `client_credit_ledger` (violation, subject `client`):
   Σ open parts of its `client_credit` rows = −Σ its 419 postings; `written_off_recovery_ledger` (violation, subject
   `servicer`): Σ `advance_write_off_recovery.amount_minor` = −Σ 7714 postings. 043 case 19's list gains both.

### 5.1 Schema
- `public.advance_repayment_request (id, organization_id, client_organization_id, currency, number text, issue_date,
  total_minor bigint > 0, payload jsonb, payload_sha256, template_version, renderer_version null, document_id null →
  document, pdf_sha256 null, issued_by, created_at, withdrawn_at null, withdrawn_by null, unique (organization_id,
  number))`. Number `DRA-AAAA-NNNNNN` (unique, not gapless: design §3.2 #4), the run numbers' mechanism. Append-only but
  for `document_id`, `pdf_sha256`, `renderer_version` and [critic] `withdrawn_at`/`withdrawn_by`, each set once from null
  (`private.refuse_change`-style guard with that exception, `enable always`).
- `public.advance_repayment_request_item (request_id, advance_id, open_minor bigint > 0, primary key (request_id,
  advance_id))`, append-only; index `(advance_id)`. An advance is **requested** while an item of a request not withdrawn
  names it and it is open.
- [critic] M7-MONEY-10, L7, L21 `public.client_credit (id, organization_id, client_organization_id, currency, cause text
  check (cause in ('overpayment', 'procedure')), amount_minor bigint > 0, entry_id → ledger_entry, payment_entry_id
  → ledger_entry (the payment it came from), [check 1] details jsonb null (cause `procedure`: the pre-opening documents
  the client named and the part it meant for each, amounts as text), created_at, unique (entry_id, cause))` — [check 1]
  at most one row per cause per payment (the draft's `entry_id unique` refused a payment with both a `procedure` part and
  an `overpayment` surplus; the entry's single −419 line is their sum) — client money the servicer owes back: what a client paid
  beyond what was open (including a document a run had already settled), or a payment of a pre-opening claim by a
  client in a proceeding, held for the procedure (L622-7 I, III). Its open part = amount − Σ its refunds
  (`commission_settlement` rows of `document_kind 'client_credit'`, kind `refund`; the kind list gains it). Append-only.
- [critic] M7-MONEY-10 `public.advance_write_off_recovery (advance_id, entry_id unique, amount_minor bigint > 0,
  created_at)`, append-only; a guard keeps Σ per advance ≤ its written-off amount.
- [critic] F18: each new table has RLS on, every privilege revoked from `anon`/`authenticated` but the read policies
  below, the change-log trigger (`private.log_change`, as `client_advance`), and a pgTAP tenant-isolation case.
- RLS: money staff of the servicer; the client's whole-client members (`private.client_whole_org_ids()`) read their own
  requests (design §6.2's rule for client documents; OQ-48) and their own `client_credit` rows (what the servicer owes
  them); collectors and restricted users: none. [critic] F11: the request PDF is readable by the client admin and money
  staff: `advance_repayment_request_pdf` joins the client-document kinds of `document_remittance_scope`
  (`20261113090000:1569`), `private.can_read_remittance_document_object` and the storage policy
  `remittance_document_object_read` (`20261113090000:1565`) gains the path `repayment-requests/%` — each redefined.
- Evidence kinds (registered through the redefined `register_client_document`, §4.1.11, readable by money staff only):
  `client_payment_evidence`, `client_refund_evidence`, [critic] L16 `payment_designation_evidence` (the client's letter or
  transfer reference naming what it pays); the upload action of « Événements du client » reused.

### 5.2 Functions
**5.2.1 `public.client_open_documents(p_client_organization_id uuid, p_currency char(3)) returns jsonb`** — money staff:
open invoices (number, issue_date, due_date, settlement netted/due, TTC, open, pending VAT), open advances (cause,
created_on, open, mandate, recovery, requested), written-off advances (written off, recovered), refunds owed (credit
notes with `document_open` > 0) and [critic] client credits owed back (cause, open), each with `in_flight_run`
(`private.advance_in_flight_run` or its invoice twin) and `before_opening` (§5.2.2); and the default order (§5.2.3).

**5.2.2 `private.document_before_opening(p_document_id uuid, p_on date) returns boolean`** — 7c's criterion is today's:
an invoice issued, or an advance born (`advance_born_on`), before the client's `proceeding_opened` date on or before
`p_on`. 7d redefines it (§6).
**[check 1] `private.document_client_payable(p_document_id uuid, p_on date) returns boolean`** (gap 11) — whether the
client may pay this document to the servicer on `p_on`: 7c-1, `not document_before_opening(doc, p_on)` (L622-7 I al.
1, first sentence: no payment of a claim born before the opening); 7d-2 redefines it to also return false for an
advance while a `proceeding_opened` or `liquidation` of the client stands (L622-7 I al. 1, second sentence, the
default of §6.2.6 and Q18). It is **not** `document_nettable`: a mandate end or a seizure bars the servicer's set-off,
never the client's own payment.

**5.2.3 `private.client_settlement_plan(p_client uuid, p_currency char(3), p_amount bigint, p_documents uuid[], p_on
date) returns table (ord int, document_kind text, document_id uuid, amount_minor bigint, vat_moved_minor bigint)`** —
pure SQL over the open documents. Named documents (only with the client's designation, [critic] L16, §5.2.4): in the
order given, each up to its open part. None named: the default order, our reading of C. civ. 1342-10 al. 2 (« d'abord
sur les dettes échues ; parmi celles-ci, sur les dettes que le débiteur avait le plus d'intérêt d'acquitter. A égalité
d'intérêt, l'imputation se fait sur la plus ancienne ») — founder Q4, OQ-89: (1) invoices due on or before `p_on`, by
(due_date, year, seq) (they bear the L441-10 penalties); (2) advances by (born_on, created_at, id); (3) the other
invoices by (due_date nulls last, year, seq). Credit notes are never paid by the client. VAT moved per invoice part:
R(pending × part / open), all of it when the part closes the invoice (`settlement.vat_part`, the plan's rule).
[critic] M7-MONEY-10: what exceeds Σ open considered is returned as one last row `document_kind 'client_credit'`
(the surplus), never an error. [check 1] (gap 11) The default order **skips** every document
`document_client_payable(doc, p_on)` refuses: a client in a proceeding paying with no designation pays its
post-opening invoices first, never a pre-opening one. Only a document the client **designates** that is not payable
becomes a `client_credit` part of cause `procedure` (one row per payment, `details` naming the documents); the surplus
is of cause `procedure` too while the client has a standing `proceeding_opened` or `liquidation` (the money may be
meant for the procedure: the P0 alert lets ops and counsel decide), else `overpayment`. The rows returned carry the
cause. Its Python twin `remittance.client_payments.plan_client_payment` (pure, integers), property-tested for parity
(the payable flag is an input of both).

**5.2.4 `public.record_client_payment(p_idempotency_key text, p_client_organization_id uuid, p_currency char(3),
p_amount_text text, p_value_date date, p_evidence_document_id uuid, p_documents uuid[], p_designation_document_id uuid,
p_recover_written_off uuid[], p_expected_open_text text, p_reason text) returns jsonb`** — « Règlement du client »
received on the own account (design §7.3, §16). Admins and ops managers at aal2. Replay + request hash. Checks and
refusals (« client payment refused: <code> »): `bad_amount` (`private.euros_to_minor`, > 0); `bad_date` (value date
after today); `evidence_required`; `no_own_account` (`servicer_billing_settings.own_bank_account_id` active, purpose
`own`, same currency); [critic] L16 `designation_evidence_required` (`p_documents` given without
`p_designation_document_id`, a `payment_designation_evidence` of that client: ops never choose which debt a payment
settles — C. civ. 1342-10 al. 1 gives the choice to the debtor); `not_open` (a named document with nothing open, or
another client's — hint: record it without naming documents, the money becomes a credit owed back); `in_flight` (a
named document an approved or sent run settles: wait for its debit; with no document named, documents in flight are
skipped by the default order); `open_changed` (Σ open considered ≠ expected). [critic] M7-MONEY-10: no `exceeds_open`
refusal — the surplus becomes a `client_credit` (cause `overpayment`); [critic] L21: a pre-opening document (§5.2.2) is
not refused — the part the client meant for it becomes a `client_credit` of cause `procedure` (held for the procedure,
alerted, OQ-92); [critic] M7-MONEY-10: `p_recover_written_off` names written-off advances whose recovery the client's
payment designates, each up to its written-off amount not yet recovered (`written_off_recovery`). Locks:
`remittance_command_locks(org, true)` (the plans of approved runs are read under the locks approvals take). Posts
`client_payment_own`: +5122[own] P (the own account's ledger account) / −4111[c] Σ invoice parts / −4112[c] Σ advance
parts / −419[c] Σ credit parts / −7714 Σ recoveries / +44574 v / −44571 v (VAT lines only when v > 0); `source_type
'document'`, `source_id` the evidence; key `cpay:<idempotency key>`; date the value date (OQ-37, OQ-90); reason
« Règlement du client par virement sur le compte du cabinet (valeur JJ/MM/AAAA) ». One `commission_settlement` per
document part (kind `payment_own`, `vat_moved_minor`, `settled_on` = value date), [check 1] one `client_credit` per
cause (at most two: `procedure`, `overpayment`; their sum is the −419 line), one `advance_write_off_recovery` per
recovery. Returns `{entry_id, settled: [{document_kind, document_id, number,
amount_minor, vat_moved_minor}], credit_minor}`.

**5.2.5 `public.book_client_payment_line(p_idempotency_key text, p_bank_transaction_id uuid, p_documents uuid[],
p_designation_document_id uuid, p_recover_written_off uuid[], p_expected_open_text text, p_reason text) returns
jsonb`** — a client's credit on the dedicated account that pays the servicer (design §12 `client_transfer_in` →
`client_payment_dedicated`; 6b-2 S27). Admins and ops managers at aal2. The line: a credit of kind `client_transfer_in`
on an active `client_funds` account of the servicer, neither linked (`bank_debit_link`) nor booked
(`bank_line_booking`), carrying no reference of ours (`private.names_our_transfer`, our lots, a `TOP` id, [critic] nor a
reference read from its label, §7.3) — refusals `not_a_client_credit`, `line_booked`, `our_reference`; the client =
the servicer's client whose **confirmed** payout account carries the counterparty IBAN ([critic] M7-MONEY-12: accounts
with `confirmed_at` not null — active, returned or retired — exactly as `private.registered_client_ibans`; a proposed
or rejected account never attributes a credit) (`ambiguous_client` when several clients). The whole line is the amount;
the plan, designation and refusals as 5.2.4; a label naming document numbers of that client (« FC-2026-000004 »,
« DRA-2026-000001 ») counts as the client's designation ([critic] L16). [critic] F7 locks, in the funds pass's order:
`payments:<org>`, then the line `for no key update`, the line re-read (neither linked nor booked), then `remit:<org>`.
Posts `client_payment_dedicated` (+5120[b] P / −4679 P ‖ +4689 P / −4111 / −4112 / −419[c] surplus / −7714 recoveries
‖ VAT pair; `source_type 'bank_transaction'`; key `cpayd:<line>`; date the line's booking date), one
`bank_line_booking` (kind `client_payment`, the entry, amount P, method `ops`, the motif), the line's review deleted
(`client_credit`), the settlements (kind `payment_dedicated`), the credits and recoveries, then `ledger_check_now()`.
The servicer's share on 4679 grows by P: the next file's sweep takes it (S = −Σ4679 − sweeps in flight, unchanged),
and a surplus credit is then refunded from the own account (5.2.6). The posting guard
(`private.bank_line_booking_guard`, `20261121090000:641`) already pre-shapes this kind (inventory PAY-1): a test proves
it; any gap is a redefinition named in the PR. [check 1] [check 2] 7e-3 redefines this command (from 7c-1's body)
for a line of kind `label_reference` (§7.3, exit (b)), and the guard's `client_payment` arm with it (its kind list is
`client_transfer_in` only, `20261121090000:784-787`); in 7c-1 the line must be `client_transfer_in`.

**5.2.6 `public.record_client_refund(p_idempotency_key text, p_document_id uuid, p_amount_text text, p_paid_on date,
p_evidence_document_id uuid, p_expected_owed_text text, p_reason text) returns jsonb`** — what the servicer owes back,
paid by its own transfer: a credit note's excess (design §14.1, §16; `credit_refund_owed`) or [critic] a
`client_credit` (owed back to the client; cause `procedure`: to the administrator, mandataire or liquidator, named in
the evidence). Admins and ops managers at aal2. Owed = `document_open` (credit note) or the credit's open part.
Refusals (« client refund refused: <code> »): `nothing_owed`, `amount_exceeds_owed`, `owed_changed`, `in_flight` (an
approved or sent run's plan pays the credit note as `refund`), `bad_date`, `evidence_required`, `no_own_account`. Locks
as 5.2.4. Posts `client_refund_own` (+4111[c] R for a credit note, +419[c] R for a client credit / −5122[own] R;
`source_type 'document'` the evidence; key `crfd:<idempotency key>`; date `p_paid_on`) and `commission_settlement
(document_kind 'credit_note' or 'client_credit', document_id, kind 'refund', amount R, vat 0, settled_on p_paid_on)` —
`document_open` already counts it for credit notes (`20261112090000:1715`), so `credit_refund_owed` stops. Recorded
after the fact on proof (founder Q7; own-account statements are not imported, design R12).

**5.2.7 `public.request_advance_repayment(p_idempotency_key text, p_client_organization_id uuid, p_currency char(3),
p_advance_ids uuid[], p_expected_total_text text) returns jsonb`** — « Demander le remboursement » (design §7.3, §13 #5).
Admins and ops managers at aal2. Locks `remittance_command_locks(org, true)`. Each advance of that client and currency:
open (`not_open`), not in flight (`in_flight`), not before the opening (`before_opening`), not in another request of the
last 30 days (`recently_requested`: a reminder after 30 days is a new request), [critic] M7-MONEY-3, L7 not recovered by
a claw-back clause (`clawback_applies`: its mandate has a claw-back clause in the terms in force today and set-off is
not barred — the next run takes it; asking the client too would make it pay twice), [critic] M7-MONEY-8, L5 not an
advance whose covered run's payout came back and is not paid again (`payout_not_received`: the client has not received
it; [check 1] exactly when `entry_remitted(E).paid_on` is null, §3.2.1 — an advance of an N = 0 run, or of a run whose
returned payout a later run paid, is requestable); total = Σ open = expected (`total_changed`); an own account (`no_own_account`) and a complete servicer billing
identity (`identity_incomplete`); [critic] L12 `recipient_unknown` while the client has a `death`, `guardianship`,
`liquidation` or `mandate_ended` event (7c sends nothing then; 7d narrows it to « no representative recorded »,
§6.2.12). Inserts the request (its payload from `private.advance_repayment_payload(request)`: canonical jsonb, amounts
as text, no payer data) and its items; queues `{type: 'repayment_request', request_id}` on `remittances`. Returns
`{request_id, number}`.
**[critic] M7-MONEY-3 — a requested advance is never also clawed back.** The prepare's facts mark an advance
`requested` (an item of a request not withdrawn) and `_plan` makes it non-nettable; it is in `inputs_hash`. The
approval re-checks it: `private.remittance_approval_refusal` redefined (from `20261114090000:688`, 97 lines; 7d
redefines it again from this body) returns `documents_changed` when a planned advance settle names an advance
requested after the draft was prepared. This covers terms that gain a claw-back clause after a request.
**[critic] `public.withdraw_advance_repayment_request(p_idempotency_key text, p_request_id uuid, p_reason text)`** —
admins and ops managers at aal2: sets `withdrawn_at` once (« repayment request refused: already_withdrawn »); its
advances can then be clawed back again or requested anew. No automatic expiry (founder Q20). The client space shows
« Demande retirée le JJ/MM/AAAA ».
**`private.repayment_request_document_done(p_request_id uuid, p_document_id uuid, p_pdf_sha256 text, p_renderer
text)`** (worker; the stored bytes hash to it) sets the document once.

**5.2.8 `private.run_advance_checks`** redefined (from 7b): `advance_open.details.requested_on` (last request);
`repayment_request_document_missing` (alert, a request without its document after 1 hour); [critic] `client_credit_owed`
(alert: a `client_credit` with an open part more than 15 days old; P0 for cause `procedure`); [check 1] the two
ledger identities of §5.0 (7) (`client_credit_ledger`, `written_off_recovery_ledger`, violations); [critic] the
check-code list asserted by 043 case 19 gains them.

### 5.3 The letter « Demande de remboursement d'avance » (template `demande-remboursement-avance-fr-1`)
Deterministic PDF (reportlab pinned, invariant mode, DejaVu Sans, no clock), SHA-256 stored; payload built in SQL; no
LLM, every amount and date from the ledger and the advances. Not an R124-4 letter (the servicer's own claim on its
mandant, LEX-03) and not an invoice (no VAT line). [critic] L6: the opening states facts per cause, with no
characterisation (no « avance pour votre compte », no purpose clause: OQ-95 leaves the legal basis to counsel); the
mandate is on each row; [critic] L3, M7-MONEY-9: the dates are recording dates and each origin follows the real order
of events; [critic] M7-MONEY-6: the letter prints only the DRA and run numbers, never an RMT, SWP or TOP id (a client
quoting one in a transfer label could make a bank line look like our transfer coming back).

```
[Bloc émetteur : dénomination, forme, capital, RCS et ville du greffe, SIREN, siège — billing_identity (R123-237/238)]
[Destinataire : le mandant (dénomination, adresse de facturation), ou après un événement la personne qui agit pour
 lui, §6.2.12 ; [check 1] sous curatelle : le mandant lui-même, puis « Copie : [nom], curateur, [adresse] »]
Le JJ/MM/AAAA
Objet : Demande de remboursement — référence DRA-2026-000001

Madame, Monsieur,

Les sommes ci-dessous vous ont été versées au-delà de ce qui vous revenait. Elles restent à rembourser au cabinet.

Date        Mandat               Origine                                              Versé      Déjà remboursé  Reste dû
20/11/2026  MAND-MARTIN-2026     Encaissement du 12/10/2026 (dossier F-103…),        2 000,00 €        0,00 €  2 000,00 €
                                 versé le 03/11/2026 (relevé RV-2026-000001), puis
                                 repris par la banque du payeur le 12/11/2026
…
Total à rembourser : 2 000,00 €

Nous vous remercions de bien vouloir nous rembourser cette somme par virement sur notre compte :
titulaire [titulaire du compte propre], IBAN [IBAN du compte propre], en indiquant la référence DRA-2026-000001.

Ce document n'est pas une facture.

Veuillez agréer, Madame, Monsieur, l'expression de nos salutations distinguées.
[Dénomination du cabinet]
```
« Date » is the Paris date the advance was recorded; « Mandat » is the advance's mandate or « plusieurs mandats »
(null mandate). Origins by cause, deterministic from the rows, each date a recording date, in the real order:
- `remitted_reversal`, reversal recorded **after** the covered payout's debit: `return:` « Encaissement du … (dossier
  …), versé le … (relevé RV-…), puis repris par la banque du payeur le … »; `unalloc:` « …, versé le … (relevé RV-…),
  puis annulé le … (imputation corrigée) »;
- reversal recorded **while** the run was in flight (at-booking cover): « Encaissement du … (dossier …), repris par la
  banque du payeur le … (ou : imputation annulée le …) alors que le reversement RV-… était en cours, puis versé le … »;
- [critic] M7-MONEY-9 a partial bank return (the M2b return took back part of the payment but every allocation was
  reversed): « paiement repris en partie par la banque (X €) ; imputation annulée en entier (Y €) » in place of
  « repris par la banque du payeur »;
- [critic] L5: « versé le … » only when `entry_remitted(E).paid_on` is set (the request refuses `payout_not_received`
  otherwise, so the letter never states a payout that came back as received); [check 1] and only when `paid_how` is
  `paid` (« versé le JJ/MM/AAAA (relevé RV-…) », or « … (relevé RV-Y, après le retour du virement du relevé RV-X) »
  through a later run); `set_off` prints « réglé par compensation dans le relevé RV-… du JJ/MM/AAAA », `netted`
  « compris dans le relevé RV-… du JJ/MM/AAAA (montant net nul) » — never « versé » for an N = 0 run;
- `payout_overrun` « Reversement RV-… versé le … pour un montant supérieur à ce qui vous restait dû »;
- `double_payout` « Virement exécuté par notre banque le … en plus du reversement RV-… (ou : hors de tout reversement),
  au-delà de ce qui vous restait dû » — no RMT reference.
No legal article, no interest, no penalty, no due date, no formal notice (founder Q6; OQ-95 asks counsel: 1999 or
1302-1, 1302-3 al. 2, 1352-7, 2001). Delivery: the client space (« Documents ») and post by ops (no email before M4/M7).

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
  [critic] L16 « Le client a-t-il désigné ce qu'il règle ? » — « Non : ordre par défaut (factures échues, avances,
  autres factures) » or « Oui : documents désignés par le client » with « Pièce de la désignation (référence du
  virement ou courrier) » and the documents in the client's order; live effect « FC-2026-000004 : 36,00 € réglés (dont
  TVA 6,00 € devenue exigible) ; avance du 12/11/2026 : 200,00 € remboursés ; [critic] trop-perçu de 5,00 € à rembourser
  au client ». Refusals in French per code: `designation_evidence_required` « Joignez la pièce où le client désigne ce
  qu'il règle ; sinon l'ordre par défaut s'applique. », `in_flight` « Ce document est déjà réglé par le reversement RV-…
  en cours : attendez son débit, ou enregistrez le règlement sans désigner de document. », `not_open` « Ce document (ou
  cette avance) n'a plus rien à régler : enregistrez le règlement sans le désigner ; la somme sera inscrite en trop-perçu
  à rembourser. », `open_changed`, `no_own_account` « Aucun compte propre n'est enregistré (Paramètres › Facturation). »,
  `evidence_required`. [critic] L21: a pre-opening document's part shows « Créance antérieure à l'ouverture de la
  procédure du client : la somme n'est pas imputée ; elle est inscrite comme à rendre à la procédure (avis de l'avocat,
  OQ-92). » [critic] M7-MONEY-10: a written-off advance the client says it repays: « Avance passée en perte le … :
  remboursement enregistré en recette (compte proposé 7714, OQ-88). »
- [critic] « Trop-perçus à rembourser » in the section « Ce que le client doit au cabinet » (and, in the client space,
  « Sommes que le cabinet vous doit : X € (trop-perçu du JJ/MM/AAAA) »), each with « Enregistrer le remboursement ».
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
  | [critic] `clawback_applies` | « Cette avance est reprise sur les prochains reversements du client (art. … du mandat) : une demande la ferait payer deux fois. » |
  | [critic] `payout_not_received` | « Le reversement RV-… est revenu et n'a pas encore été versé de nouveau : le client n'a pas reçu cette somme. » |
  | [critic] `recipient_unknown` | « Un événement (décès, tutelle, liquidation, fin de mandat) est enregistré : indiquez d'abord qui agit pour le client. » |
  | [critic] `already_withdrawn` | « Cette demande est déjà retirée. » |
- [critic] « Avances »: « Retirer la demande » on a requested advance (sheet: « La demande DRA-… est retirée : l'avance
  pourra être reprise ou demandée de nouveau. »); the client space shows « Demande retirée le JJ/MM/AAAA ».
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
guard of 7b refuses an over-settlement by a payment. [critic] Added: (a) M7-MONEY-3, L7 — a request for an advance under
a claw-back clause → `clawback_applies`; a request sent (no clause), then the terms gain a claw-back clause, then a
prepare → the advance not taken; a draft prepared before a request then approved → `documents_changed`; withdrawal →
taken by the next run; (b) M7-MONEY-10 — a payment of 36 500 for 36 000 open (own and dedicated) → 36 000 settled,
`client_credit` 500, I9/I19/I18 clean, `client_credit_owed` after 15 days, `record_client_refund` of the credit stops
it; a payment for an advance a run already clawed back → whole amount a credit owed back; a repayment of a written-off
advance → `written_off_recovered`, capped at the written-off amount; (c) L21 — a client in a proceeding pays a
pre-opening invoice → `client_credit` cause `procedure`, P0 alert, the invoice still open; (d) L16 — `p_documents`
without designation → refused; a dedicated line labelled « FC-2026-000004 » → the designation accepted; (e) M7-MONEY-12
— a credit from an IBAN on a **rejected** proposal of Lilas and on Martin's confirmed account → Martin, not
`ambiguous_client`; (f) F7 — two sessions: `book_client_payment_line` against `link_debit` on the same line, both
orders → no deadlock, exactly one booking; (g) M7-MONEY-8, L5 — `payout_not_received`; (h) F11 — the DRA PDF readable by
Martin's admin and money staff, not by Lilas, restricted viewers or collectors; storage path `repayment-requests/…`;
(i) F18 — the new tables' tenant isolation and change log.
[check 1] The file splits with the PRs: **045** (7c-1: (b)–(f), (i), the payments, refunds and the cases below) and
**045b** (7c-2: the requests, (a), (g), (h)). Added:
- (j) gap 2, shapes (045): a payment wholly a credit (no document open: −419 only) posts and passes I3′; a payment with
  a recovery (−7714 only, and −4112 + −7714) posts; the refund of a client credit (+419 / −5122) posts; malformed shapes
  refused `LG001` at `ledger_check_now` — a client payment with a debit on 419, two 419 lines, a 7714 line on a
  `client_settlement`, a refund with both +4111 and +419; `client_credit_ledger` and `written_off_recovery_ledger` empty
  after each, and a planted 419 posting without its row → `client_credit_ledger`; the accounting export of a payment
  with a surplus balances (Σ debit = Σ credit) and lists account 419; `ledger_account_read` gives the 419 account to
  money staff only.
- (k) gap 8 (045): one payment with a designated pre-opening invoice part **and** a surplus → two `client_credit`
  rows (`procedure`, `overpayment`) on one entry, one −419 line equal to their sum; a replay creates none; a planted
  second row of the same cause on the entry → unique violation.
- (l) gap 11 (045, and 046b for advances): a client in a proceeding opened 15/11 with FC-3 (issued 02/11, due) and
  FC-5 (issued 20/11, due), a payment of FC-5's amount with no designation → FC-5 settled, FC-3 untouched, no
  `client_credit`; a larger payment → FC-5 settled and the rest a `procedure` credit (not `overpayment`); a designated
  payment of FC-3 → all `procedure`, FC-3 still open; (046b, after 7d-2) an advance of that client skipped by the
  default order whatever its birth date.
- (m) gap 6 (045b): `request_advance_repayment` accepts an advance whose covered run is N = 0 (booked at approval with
  D > 0) and an advance whose run's payout came back and was paid by RV-2; refuses `payout_not_received` while the
  re-queued item sits in a draft; the payload's origin rows say « réglé par compensation dans le relevé RV-… » and
  « versé le … (relevé RV-2, après le retour du virement du relevé RV-1) » (golden letter rows).

**Worker.** Unit: the letter's text snapshot and golden PDF hash (every origin, [critic] L3/M7-MONEY-9: a remitted
« Désimputer » of a back-dated allocation, an at-booking cover — reversal before the payout —, a partial bank return,
each cause with its factual sentence, a multi-mandate request with « plusieurs mandats », no RMT/SWP/TOP id anywhere;
[check 1] an origin per `paid_how` (paid, paid through a later run, set off, netted); 7d-1 adds a DRA with two
addressees, the client and « Copie : …, curateur »);
`plan_client_payment` vs
`client_settlement_plan` parity by Hypothesis (random documents, amounts, orders); integration — design §7.3: (i) no
claw-back clause for Martin: RV-3 N = 282 000, a request DRA for 200 000 with its PDF stored, then
`record_client_payment` 200 000 → 4112[Martin] = 0, `advance_open` silent; (ii) no netting clause: FC-1 `due`, Martin
pays it to the own account → 44574 → 44571 moved, `invoice_overdue` silent; (iii) the same payment received on the
dedicated account → `book_client_payment_line`, then swept. **vitest**: sheets, effects, refusals, the reworded texts.
**E2E**: record a client payment and a refund; the client downloads its repayment request (mobile + desktop).
**Mutants**: default order advances-first → order case; VAT moved on the open part instead of pro rata → VAT case;
`in_flight` check removed → in-flight case; the 30-day request window off by one → boundary case; `book_client_payment_line`
accepting an own credit → refused-kind case; [critic] `clawback_applies` removed → (a); the `requested` flag ignored by
`_plan` → (a); the surplus refused instead of credited → (b); a rejected account matched → (e); `remit:` before the
line lock → (f); [check 1] the shapes' `n_cco`/`n_rec` terms dropped from `n` → (j); `d_cco = 0` dropped → (j) (a debit
on 419 in a payment accepted); `client_refund_own` accepting both lines → (j); 419 missing from `ledger_post_set`'s
closure list → (j) (LG001 « leaves a fund open »); the export's book list without 419 → (j); `client_credit` keyed on
`entry_id` alone → (k); the default order ignoring `document_client_payable` → (l); the surplus always `overpayment` →
(l); `payout_not_received` read from `remittance_run_paid_on` → (m).

### 5.8 Docs (7c)
ADR-0014 « M2c-7c »; COMPLIANCE: CPCE-02 (client payments received on the dedicated account, OQ-35), CPCE-07 (a client's
payment to the servicer gets no R124-6 receipt: not a debtor payment, LEX-05 (d)), FAC-05 (refund owed paid), new OQ-89
(imputation of a client payment: the client designates, C. civ. 1342-10 al. 1; our default order as the reading of al.
2; 1347-4), OQ-90 (evidence of own-account payments and refunds, VAT date), OQ-95 (letter wording), [critic] OQ-98
(the account of client credits owed back, PCG class 419; a pre-opening payment held for the procedure); OQ-88 gains
the recovery of a written-off advance; DOMAIN « Règlement du client », « Demande de remboursement d'avance »,
« Trop-perçu à rembourser »; PROGRESS.

---

## 6. 7d — Client status effects

Branch `m2c7d` (or `m2c7d-1` / `m2c7d-2`, §1.4). Migration `<timestamp at PR open>_client_status_effects.sql`. Closes D09
and the legal inventory's LEX-07, LEX-08 (wording), LEX-09 (liquidation), LEX-10, LEX-11, LEX-12, LEX-16 (in part),
LEX-21, LEX-24 (tutelle payee), LEX-25, LEX-26, LEX-27. Every rule here the law does not fix is a default with its
question (§10, §11); texts never present our rule as law.

[check 1] **Three PRs, in this order, each shippable alone:** **7d-1** (`m2c7d-1`, `<timestamp>_client_events.sql`):
§6.1 but the withheld kind and the disposition table ([check 2] `claims_declared_item` is now 7d-1's, with the kind
`claims_declared` and `p_declared`: `record_client_status_event` is then dropped and recreated once, not again in
7d-3); §6.2.1, §6.2.3, §6.2.7, §6.2.8's gate and forward, §6.2.12, §6.2.13; `protection_event_to_qualify`,
`seizure_standing`; pgTAP 046a. **7d-2**
(`m2c7d-2`, `<timestamp>_set_off_bars.sql`): §6.2.2, §6.2.4–§6.2.6, §6.2.9, §6.2.11 with the withheld kind and every
redefinition it needs, the worker's `_plan`/`_documents`, `document_client_payable`, `in_proceeding`,
`set_off_after_bar`, [check 2] `remittance_schedule_candidates` and the trigger `settlement_withheld`; pgTAP 046b.
**7d-3** (`m2c7d-3`, `<timestamp>_declarations_statement.sql`): `claims_to_declare` ([check 2] reading the declared
items 7d-1 records), `post_opening_unpaid`, `payout_after_liquidation` with
`liquidation_payout_disposition`, §6.2.10's `invoice_overdue`, §6.2.8's statement fr-4; pgTAP 046c.

### 6.1 Schema
- `client_status_event.kind` += `curatorship` (« Curatelle ou autre mesure de protection »: a payout hold by our rule,
  no end of mandate — C. civ. 2003 names only « la tutelle des majeurs », LEX-25), `claims_declared` (the declaration
  of the servicer's claims, with its evidence), [critic] L14 `seizure` (« Saisie entre les mains du cabinet » — a
  saisie-attribution served on the servicer as tiers saisi for sums it owes the client) and `seizure_released`
  (« Mainlevée ou paiement des causes de la saisie »; refers to its `seizure` event).
- [check 2] (gap 6) **`client_status_event.refers_to_event_id uuid null references public.client_status_event (id)`**,
  added by DDL (existing rows null), with `check ((kind = 'seizure_released') = (refers_to_event_id is not null))` and
  the partial unique index `client_status_event_release_uq (refers_to_event_id) where kind = 'seizure_released'` (one
  release per seizure, race-safe: two admins releasing the same seizure get one row and a `unique_violation`, mapped to
  `release_without_seizure`). `private.client_status_event_guard` (redefined in 7d-1 anyway) also checks, for a
  `seizure_released`: the event it names is a `seizure` of the same client and servicer, effective on or before the
  release (« client event: a release names a seizure of the client, on or before it », `check_violation`). A seizure
  **stands on date d** when its effective date is ≤ d and no `seizure_released` naming it is effective on or before d;
  `private.client_seizures_standing(p_client uuid, p_on date) returns setof uuid` (stable, keyed by
  `client_status_event_client_idx`, then the release index per seizure) is the one place that reads it — the blockers
  (§6.2.7), `payout_court_appointed`, the set-off bar (§6.2.6), the approval (§6.2.9) and `seizure_standing` (§6.3).
  Before, a release « referring to its seizure » had no column to refer with, so « standing » could not be computed
  per seizure (two seizures, one released, read as none or both).
- `client_status_event.publication_date date null`, check (null, or kind in (`proceeding_opened`, `liquidation`) and
  ≥ effective_date) — the BODACC publication from which R622-24's two months run (LEX-11).
- [check 1] **`client_status_event` stays append-only.** Its statement-level `private.refuse_change` trigger refuses
  every UPDATE, DELETE and TRUNCATE (`client_status_event_append_only`, `20261111120000_identities_terms.sql:1052-1054`),
  so the draft's `representative` « set once » later and `qualified_at` / `superseded_by` set on existing rows could
  never be written. Facts that arrive after the event go to two append-only side tables instead; the event row is
  only ever inserted. 7d-1 adds:
  - `public.client_status_event_representative (id uuid pk, organization_id, client_organization_id, event_id →
    client_status_event, representative jsonb not null check (shape: `{role: 'notary' | 'heirs' | 'tutor' | 'curator'
    | 'liquidator' | 'administrator', name 1–140, address_lines 1–4 of 1–70}`), evidence_document_id → document (kind
    `client_status_evidence` or `payout_authority_evidence` of that client), recorded_by, recorded_at)`; index `(event_id, recorded_at desc)`; the representative
    in force for an event is its latest row (a correction is a new row, the history kept). Written at the event by
    `record_client_status_event` (`p_representative`) or later by `public.set_client_representative(p_idempotency_key,
    p_event_id, p_representative jsonb, p_evidence_document_id)` — admins at aal2; refusals (« client representative
    refused: <code> »): `not_an_event_with_representative` (kind not `death`, `guardianship`, `curatorship`,
    `liquidation`, `proceeding_opened`), `bad_representative` (shape), `role_mismatch` (tutor only for guardianship,
    curator only for curatorship, notary or heirs only for death, liquidator only for liquidation, administrator only
    for proceeding_opened), `evidence_required`.
  - `public.client_status_event_qualification (event_id uuid pk → client_status_event, organization_id,
    client_organization_id, kind text check (kind in ('guardianship', 'curatorship')), curatorship_event_id uuid null →
    client_status_event, evidence_document_id → document, recorded_by, recorded_at)` — one row per old `guardianship`
    row (§6.2.13).
  - Both: RLS on, every privilege revoked from `anon` and `authenticated` but a select policy for money staff of the
    servicer (`private.money_staff_org_ids()`; the representative's name and address are personal data: never the
    client's users, restricted viewers or collectors), `private.refuse_change` statement trigger (append-only,
    `enable always`), the change-log trigger (`private.log_change`), and pgTAP 046a isolation cases (servicer B reads
    none of A's rows; a client admin, a restricted viewer and a collector read none; `authenticated` cannot insert).
- [critic] L17, [check 1] `client_status_event.qualified_at timestamptz null`, added by DDL **without a default** (the
  existing rows stay null: an `add column … default now()` would fill them), then `alter column qualified_at set
  default now()` so every row recorded from 7d-1 on carries it; `private.client_status_event_guard` (redefined from
  `20261111120000:1031`, 18 lines) refuses an insert with `qualified_at` null. A `guardianship` row counts as a tutelle
  when `qualified_at` is set or its qualification row says `guardianship`; it no longer counts when its qualification
  says `curatorship` (the curatorship event recorded then counts instead). The helper
  `private.client_event_effective(p_event_id) returns text` (the kind it counts as, or null) is the one place every
  reader (§6.2.3, §6.2.7, §6.2.12, the nightly) reads this. The existing `guardianship` rows (entered under the label
  « Tutelle ou curatelle », `terms.ts:109`) keep today's payout hold until ops qualify them (§6.2.13).
- [critic] L8 `public.claims_declared_item (event_id → client_status_event, document_kind text check (in ('invoice',
  'advance')), document_id uuid, amount_minor bigint > 0, primary key (event_id, document_kind, document_id))`,
  append-only, RLS (money staff), change log, pgTAP isolation ([critic] F18): which documents a declaration covers.
  [check 2] Built in **7d-1** with the kind `claims_declared` and `record_client_status_event`'s `p_declared` (it was
  in 7d-3 while the kind and its items were written in 7d-1: 7d-1 had nowhere to store them); written only by that
  command, in the event's transaction; `organization_id` and `client_organization_id` columns added for the select
  policy (money staff of the servicer, as the side tables) and checked by an insert guard against the event's. 7d-1
  records declarations; 7d-3's `claims_to_declare` reads them (046a proves the rows, 046c the alert).
- `client_payout_account.kind` += [critic] L10 `estate` (« Succession — compte du notaire, ou compte désigné par tous les
  héritiers ») and [critic] L2 `protected_adult` (« Compte du majeur protégé, à son nom (géré par son tuteur ou
  curateur) ») — **not** the draft's « Tuteur »: C. civ. 427 al. 5 (read 2026-11-21, version 2020-01-01): « Les
  opérations bancaires d'encaissement, de paiement et de gestion patrimoniale effectuées au nom et pour le compte de la
  personne protégée sont réalisées exclusivement au moyen des comptes ouverts au nom de celle-ci. »
- [critic] L2, L10 `client_payout_account.authority_document_id uuid null → document` (kind
  `payout_authority_evidence`, money staff only, §4.1.11): the second document that proves who may receive —
  the notary's attestation, the acte de notoriété or a designation signed by every heir (`estate`); the judgment naming
  the tutor or curator (`protected_adult`); the judgment naming the liquidator (`court_appointed`, from 7d on).
- `payment.review_reason` += `client_mandate_ended`.
- `private.remittance_draft` += `set_off_barred text null` and [critic] `opening_on date null` (what the prepare
  assumed; checked at approval and before download).
- [critic] M7-MONEY-5 `remittance_pending.kind` and `remittance_line.kind` += `settlement_withheld`; the 4670 queue
  trigger `private.ledger_posting_client_payable` (from `20261111090000:1252`, 50 lines) maps a reversal of a
  `client_settlement` to it. [check 1] 7d-2; the constraints are `remittance_pending_kind_check`
  (`20261111090000:1237`) and `remittance_line_kind_check` (`20261112090000:245`), dropped and recreated with the new
  kind; every other place that knows the item kinds is listed in §6.2.11 (a).
- [check 1] (gap 9, 7d-3) `public.liquidation_payout_disposition (id uuid pk, organization_id, client_organization_id,
  transfer_id uuid not null unique → bank_transfer, kind text not null check (kind in ('ratified',
  'repaid_to_liquidator')), evidence_document_id uuid not null → document (kind `client_status_evidence`), note text
  check (1–2,000), recorded_by, recorded_at)` — what became of a payout made to the client after its liquidation
  (L11, OQ-99). Append-only (`private.refuse_change`, `enable always`), RLS (select: money staff of the servicer; no
  client user — the liquidation and its disposition are staff matters until counsel answers OQ-99), privileges revoked,
  change log, pgTAP 046c isolation. Written only by `public.record_liquidation_payout_disposition` (§6.3).
- Index `remittance_line_repricing (invoice_id) where invoice_id is not null` if absent (the invoices' birth date read).

### 6.2 Functions
**6.2.1 `public.record_client_status_event`** dropped and recreated (from `20261111120000:1076`) with
`p_publication_date date default null, p_representative jsonb default null, p_refers_to uuid default null`,
[check 2] `p_declared jsonb default null` last; same roles (admin, aal2); new refusals:
`claims_declared_without_proceeding`, `bad_publication_date`, [critic] `release_without_seizure` (`seizure_released`
naming no standing `seizure` of the client). `claims_declared` takes its items (`p_declared jsonb`: the documents and
amounts, each an invoice or advance of the client; refused `not_declarable` otherwise). [check 2] `p_refers_to` is
required for `seizure_released` and stored in `refers_to_event_id`: refused `release_without_seizure` when it is null,
names no `seizure` of this client, names one effective after the release, or names one already released (checked
under the `payout_accounts:` advisory lock the command already takes, `20261111120000:1120`; the partial unique index
is the backstop and its `unique_violation` is mapped to the same code); given for any other kind → refused
`refers_to_not_allowed`. `p_declared` is required for `claims_declared` and refused for any other kind
(`not_declarable`); its items are inserted into `claims_declared_item` in the same transaction. [check 1]
`p_representative` inserts the event's first `client_status_event_representative` row in the same transaction (its evidence the event's, kind `client_status_evidence`; refusals as
`set_client_representative`'s); the event row itself is never updated. Grants restated; the web caller updated in the
same PR. [critic] L20: the form says, for a
`mandate_ended` event, « Date d'effet : pour une révocation, le jour où elle a été notifiée au cabinet (la désignation
d'un nouveau mandataire vaut révocation « à compter du jour où elle a été notifiée », art. 2006 C. civ.) ; pour une
renonciation du cabinet, le jour où elle a été notifiée au client (art. 2007 C. civ.) » (texts read 2026-11-21).

**6.2.2 `private.client_opening_date(p_client uuid, p_on date) returns date`** — the earliest effective date of a
`proceeding_opened` **or** `liquidation` event on or before `p_on` (LEX-07 (2): L641-3 al. 1 applies L622-7 I to
liquidation; today a client recorded only in liquidation has no opening, `jobs/remittances.py:558-560`,
`20261114090000:725-726`).

**6.2.3 `private.client_end_event(p_client uuid, p_on date)`** — the earliest `death`, qualified `guardianship` or
`mandate_ended` event on or before `p_on` (C. civ. 2003), with its `recorded_at` (LEX-27: acts before the servicer knew
are valid; nothing is undone for them). [check 1] « Qualified » through `private.client_event_effective` (§6.1): an
old `guardianship` row not yet qualified, or qualified as a curatelle, is not an end event.

**6.2.4 `private.document_born_on(p_document_id uuid) returns date`** — the earliest date the claim can be said to be
born (default, OQ-92): an invoice → least(issue_date, the earliest `encaissement_date` of the lines it charges, by
`remittance_line_invoice_idx` and the repricings), a corrective invoice with no line → least(issue_date, service_from);
an advance → `advance_born_on` (7b). [critic] L1: the prepare computes the same for **the run's own new invoice** before
it exists: the earliest `encaissement_date` of the mandate's lines it charges (`_plan`, §6.4).

**6.2.5 `private.document_before_opening`** redefined (from 7c; [check 1] 7c-1's body, in 7d-2): `document_born_on(doc) < client_opening_date(client,
p_on)`.

**6.2.6 `private.client_set_off_barred(p_client uuid, p_on date, p_kind text) returns text`** — why nothing of kind
`p_kind` (`invoice` or `advance`) may be set off on `p_on`, else null:
- `liquidation` when a liquidation is recorded on or before `p_on` (founder Q11: nothing is set off, pre- or
  post-judgment, LEX-09; invoices and advances are declared);
- `mandate_ended` when `client_end_event` exists (founder Q9: the netting and claw-back clauses belonged to the mandate
  that ended);
- [critic] L14 `seizure` while a `seizure` event stands on `p_on` ([check 2] `private.client_seizures_standing(p_client,
  p_on)` not empty: no `seizure_released` naming it effective by then, §6.1): CPCE L211-2 al. 1
  (read 2026-11-21): « L'acte de saisie emporte, à concurrence des sommes pour lesquelles elle est pratiquée,
  attribution immédiate au profit du saisissant de la créance saisie, disponible entre les mains du tiers », and C. civ.
  1347-7: « La compensation ne préjudicie pas aux droits acquis par des tiers. »;
- [critic] L4 `proceeding` for **advances** while a `proceeding_opened` stands (founder Q18): L622-7 I al. 1, second
  sentence (read 2026-11-21, version 2021-10-01): « Il emporte également, de plein droit, interdiction de payer toute
  créance née après le jugement d'ouverture, non mentionnée au I de l'article L. 622-17. » — L622-17 I covers claims born
  « pour les besoins du déroulement de la procédure ou de la période d'observation, ou en contrepartie d'une prestation
  fournie au débiteur pendant cette période »; repaying an advance is not on its face such a claim, so none is taken or
  requested whatever its birth date (conservative default, OQ-92; `request_advance_repayment` is redefined to refuse
  `in_proceeding` « Client en procédure collective : l'avance n'est ni reprise ni demandée ; elle est à déclarer. »).
  Commission invoices born after the opening stay
  nettable (they pay a service given during the period; OQ-92 asks counsel);
- null otherwise. A credit note still corrects its invoice: the servicer's policy is that a price correction is not a
  set-off ([critic] L19 (e): not presented as what CGI 289 I 5 says).
`private.document_nettable(p_document_id uuid, p_on date) returns boolean` = no bar for its kind and (no opening or
born_on ≥ opening).

**6.2.7 Payee after the event.** `private.payout_court_appointed` redefined (same name, callers unchanged): staff only
also for kinds `estate`, `protected_adult`, and for a client with a `death`, `guardianship`, `curatorship` or
`mandate_ended` event, or [check 2] a `seizure` standing today (`client_seizures_standing(client, paris_today())`, §6.1)
(its own users no longer confirm, reject or retire its payout accounts).
`public.propose_payout_account` redefined (from `20261111120000:742`): `p_kind` in (`client`, `court_appointed`,
`estate`, `protected_adult`) and `p_authority_document_id`; refusals `estate_without_death`,
`protected_adult_without_measure` (no guardianship or curatorship), [critic] `authority_evidence_required` (estate,
protected_adult, court_appointed without the authority document), [critic] L2 `holder_not_client` (`protected_adult`
whose holder is not the client). [check 1] (gap 10) The draft's « compared as the payee-name checks of 6a compare
names — `public.payee_name_check` » named a table (the bank's payee-verification results, guard at
`20261115090000:628`), not a comparison. The rule: **`private.epc_name_key(p_name text) returns text`** (immutable,
new, 7d-1) = the name as the pain.001 writer spells it. [check 2] (gap 4) Not `private.epc_name_empty`'s map
(`20261115090000:1321`): that map is one letter per character (œ→o, æ→a, ß→s, þ→t; its comment: « one letter for the
emptiness test »), while the writer's `_SPELLED` (`remittance/pain001.py:61`) spells œ→oe, æ→ae, ß→ss, þ→th — so the
revision-2 key gave `BOUF SARL` for « Bœuf SARL » where the writer sends `BOEUF SARL`, its parity test failed on any
such name, and its own case « Œuvre d'Élan » = « OEUVRE D ELAN » could not pass. The key, in both twins, step by step
as `pain001.epc_text` does it:
  1. `_SPELLED` applied: the eight multi-letter spellings by a `replace` chain (œ→oe, Œ→OE, æ→ae, Æ→AE, ß→ss, ẞ→SS,
     þ→th, Þ→TH), then one `translate` for the rest of the map (ø Ø đ Đ ð Ð ł Ł ı, the four apostrophes, the four
     dashes, the two no-break spaces);
  2. `normalize(…, nfkd)`, then the combining marks of U+0300–U+036F dropped except U+034F (the only one of that block
     whose combining class is 0, so the writer keeps it): `regexp_replace(s, '[\u0300-\u034E\u0350-\u036F]', '',
     'g')`;
  3. step 1 again (the writer translates before and after NFKD);
  4. **null** when any character outside Basic Latin is left (another script, or a mark outside that block): such a
     name is not compared, so the account needs the explanation below — never a false match;
  5. upper-cased, every run of characters outside `[A-Z0-9]` one space, trimmed (no length cut).
Its Python twin `remittance.pain001.name_key(name) -> str | None` follows the same five steps with `_SPELLED`. Two
properties (Hypothesis): parity of the twins on generated text (every `_SPELLED` key, Latin-1 and Latin Extended-A
letters, the marks of the block and U+034F, punctuation, any Unicode); and, whenever `name_key(n)` is not null, it
equals `epc_text(n, len(n) * 3)` upper-cased with the same collapse — the name the writer sends, before its length
cut. Probed on the local stack (read-only, 2026-11-21): steps 1, 2 and 5 give `BOEUF D ELAN SARL` for « Bœuf d'Élan –
SARL ». The account passes when `epc_name_key(holder_name) = epc_name_key(organization.legal_name)` of the client,
both not null. Otherwise the proposal must carry
`p_holder_attestation text` (1–500 characters, why the RIB reads otherwise, e.g. « RIB au nom de M. Jean DUPONT,
majeur protégé ; tuteur : UDAF ») — stored on the account (`client_payout_account.holder_attestation text null`, set
at insert, never changed) and shown side by side with both names to the second admin who confirms; without it,
`holder_not_client`. The tutor's or curator's own account therefore never passes silently (C. civ. 427 al. 5); a
title or word order the bank prints differently passes only with the explanation and the second admin's eye. The
same comparison is shown for `estate` (no refusal: the notary's account is in the office's name). `propose_payout_
account` gains the trailing `p_holder_attestation text default null` (dropped and recreated with the new parameters;
grants restated; web caller updated).
[critic] F16 `private.remittance_payout_blockers` redefined (from `20261115090000:900`): **every** blocking event
effective on or before `p_on` (`liquidation`, `death`, qualified or not `guardianship` — [check 1] one qualified as a
curatelle counts as its `curatorship` event —, `curatorship`, `mandate_ended`, a standing `seizure`) states the payee it
requires, and the block lifts only when the active payout account satisfies
all of them — of the strictest kind they require (estate > protected_adult > court_appointed > client; a liquidation
requires court_appointed whatever else), confirmed via `second_admin` after the `recorded_at` of each, with its
authority document; a standing `seizure` blocks whatever the account. The draft read only the latest event (by
`recorded_at`): a `mandate_ended` recorded after a tutelle would have let the client's own account through. Mapping:
liquidation → `court_appointed` (built); death → `estate` (founder Q8: default the notary's account, or one all the
heirs designate; C. civ. 1309 al. 2: « Chacun des créanciers n'a droit qu'à sa part de la créance commune »);
guardianship and curatorship → `protected_adult` (C. civ. 427 al. 5; 1342-2 al. 3); mandate end → `client`
(re-confirmed by a second admin). Codes unchanged (`client_status:<kind>`); `proceeding_opened` blocks nothing (L622-13
I al. 2: the contract goes on; design §13 #9). Founder Q8, OQ-41, OQ-93, OQ-94.

**6.2.8 After a mandate-ending event.**
- `private.gate_assignments` redefined (from `20261109190000:506`): a payment of a file of a client with an end event
  dated on or before the payment's booking date is held `client_mandate_ended` (never allocated automatically: the
  servicer's « pouvoir de recevoir » lapsed, R124-3; LEX-02). Ops forward it to the client's confirmed payee or refund
  the payer (design §13 #9, founder Q10; OQ-93). `public.forward_payment` accepts reason `mandate_ended` for such a
  payment (redefinition: [check 1] whole copy from `20261109190000_payment_allocation.sql:1161`, 108 lines, in 7d-1's
  size; its reason list and the notification « Reversement sans imputation : paiement reçu après la fin du mandat »);
  the schedule has no forward key for it, so its commission is nil. [check 1] The statement redefinition below is
  7d-3's; until 7d-3 merges, fr-3 statements stay as they are (7d-1 adds no block).
- The statement: `private.remittance_statement_build` redefined (from `20261117120000:363`) — payload key
  `mandate_end {kind, effective_date, recorded_on, payee_kind}` when an end event is effective by K; template
  `releve-reversement-fr-4` (renderer accepts fr-3 and fr-4; fr-3 statements keep their bytes) adds the block « Fin du
  mandat » (§6.4) to every statement of such a client — the « final statement » of design §13 #9 is the first of them
  (no separate run kind: later collections forwarded after the end still need statements, C. civ. 1993); [critic] L12
  its addressee is the event's representative when recorded; [critic] M7-MONEY-5 its rows include a
  `settlement_withheld` item (« Compensation retenue sur RV-… et rendue : … »). While there, each advance settled gets
  its date (the §1.2 note).

**6.2.9 Proceedings and seizures at approval.**
- `private.remittance_approval_refusal` redefined (from 7c's body; [check 1] 7c-2's, in 7d-2): the opening read through `client_opening_date`;
  `client_status_changed` also when `client_set_off_barred` (either kind) or the opening differs from the draft's
  `set_off_barred` / `opening_on`; [critic] L14 a standing `seizure` returns `payout_blocked:client_status:seizure`
  **whatever N** — the blockers are read today only when `net_minor > 0` (`20261114090000:732`), so an N = 0 run would
  set off sums a seizure attributed to the creditor.
- Payments out after a liquidation (LEX-12, L641-9 I « à partir de sa date »): see `payout_after_liquidation` (§6.3).

**6.2.10 `private.run_advance_checks`** redefined (from 7c; [check 1] in each of 7d-1, 7d-2, 7d-3, each from the previous slice's body): [critic] L4 `advance_open` leaves out every advance of a
client in a proceeding or liquidation (they are listed to declare); new checks §6.3. [critic] L9
`private.run_remittance_runs_checks` redefined (from `20261121120000:195`, ≈ 560 lines; in 7d's size): `invoice_overdue`
leaves out invoices of a client in liquidation, and invoices born before the opening of a client in a proceeding (they
are listed to declare, never dunned: L622-7 I, L622-21); its help is reworded (§6.4).

**6.2.11 [critic] M7-MONEY-5 — the client's status re-read at the debit.** The plan's set-offs are frozen at approval
and posted only at the payout's debit by `private.post_run_settlements` (`20261116090000:767`), from the frozen plan,
with no re-read: a judgment, a death or a seizure recorded between approval and debit (or effective before the
approval but recorded after it, the BODACC learned late) leaves the set-off posted after the bar.
- (a) **At the debit.** `private.post_run_settlements` redefined (79 lines): for each run, the plan's settles barred at
  the posting date (`private.document_nettable(doc, on)` false, with the events recorded by then) are posted in a second
  entry `settle:<run>:barred` with **no** `commission_settlement` row, and that entry is reversed at once
  (`return:barred:<run>`, reason « Compensation retenue : <procédure collective / liquidation / fin du mandat / saisie>
  depuis le JJ/MM/AAAA (règle du cabinet) »); the 4670 trigger queues the reversal as a `settlement_withheld` item (+W),
  which the next run pays like a `payout_returned` item (no file, no commission, outside every mandate's gross, held to
  the run's earliest line date). The allowed settles post as today (`settle:<run>`). The documents stay open (to
  declare, or due). The N = 0 approval needs nothing new: it reads the bar the same day it posts. Switch off and on
  alike (the payout itself is already at the bank).

  **[check 1] The mechanism, and every redefinition it needs (gap 1, the blocker).** As the draft wrote it, (a) could
  not run: the latest `private.ledger_entry_guard` (`20261111090000_remittance_funds.sql:233`, lines 258–265) refuses
  any reversal of a `client_settlement` with `LG003` (« a settlement survives a returned payout »), and the draft
  redefined neither the guard nor anything else. Of the two mechanisms possible — (i) post the barred part and reverse
  it under one narrow exception to that rule, or (ii) post nothing and insert a `settlement_withheld` pending row keyed
  on the payout's `remittance` entry — 7d-2 builds **(i)**: the withheld item stays what every item is, the −Σ4670 of
  its own ledger entry, so the line insert guard, the queue trigger, I14 and the item's ledger trail need no special
  case; (ii) would put in the queue a row whose entry's 4670 posting is +N, not −W, and every reader of items (the line
  guard's amount rule, the worker's facts, the nightly) would need an exception (Appendix B). In order:
  1. **Amounts.** For run r debited on d: the barred settles are those of kind `invoice` or `advance` whose document
     `document_nettable(doc, d)` refuses; a `refund` settle (a credit note paid with the payout: the servicer paying,
     not setting off) is never barred. Wc = Σ barred invoice parts, Wa = Σ barred advance parts, Wv = Σ their
     `vat_moved`, W = Wc + Wa. The allowed entry posts D − W, Dc − Wc, Da − Wa, v − Wv and the allowed settles'
     `commission_settlement` rows. If the allowed part would be ≤ 0 while settles remain (a refund at least as large as
     the allowed invoices), the whole plan is withheld (W = D, no allowed entry): never a zero or negative settlement.
  2. **The barred entry** `settle:<run>:barred` (`client_settlement`, source the run, date d): +4670[c] W / −4679 W ‖
     +4689 W / −4111[c] Wc / −4112[c] Wa ‖ +44574 Wv / −44571 Wv — the shape of §2.3, checked by I3′ as any settlement;
     then `private.ledger_reverse(barred, 'return:barred:' || run, <reason>, d)`.
  3. **`private.ledger_entry_guard`** redefined (whole copy from `20261111090000:233`, 54 lines), one exception in the
     LG003 type rule only: a new entry whose `idempotency_key` = `'return:barred:' || x` reversing a `client_settlement`
     whose key = `'settle:' || x || ':barred'`, x the same run id, same organization. Every other reversal of a
     `client_settlement`, a commission document or a write-off still raises LG003; the guard's other rules (tenant,
     scope, line count, date) are unchanged and apply to it.
  4. **Commit-time check** `ledger_entry_barred_reversed`: a deferrable, initially deferred constraint trigger, `enable
     always`, after insert on `public.ledger_entry` for each row `when (new.entry_type = 'client_settlement' and
     new.idempotency_key like 'settle:%:barred')` → `private.barred_settlement_check()`: LG003 « ledger: barred
     settlement % not reversed in its transaction » unless its reversal (by `ledger_entry_reversed_once_uq`) exists.
     So a barred settlement exists only with its reversal, robust to the debit job's savepoints (no reliance on `xmin`
     or `posted_at`, which is `clock_timestamp()`). **`private.ledger_check_now`** redefined (from 7a's body, 10 lines):
     the new constraint joins its immediate/deferred pair.
  5. **Queue.** `private.ledger_posting_client_payable` (from `20261111090000:1252`, 51 lines): the reversal's kind case
     gains `when 'client_settlement' then 'settlement_withheld'`; the constraints `remittance_pending_kind_check`
     (`20261111090000:1237`) and `remittance_line_kind_check` (`20261112090000:245`) gain the kind.
  6. **Line insert guard: no change.** `private.remittance_line_insert_guard` (latest `20261113090000:1860`, 7b's body)
     reads no kind; the withheld line's amount is −Σ4670 of the reversal, as for any item (a 046b case proves the line
     inserts).
  7. **Deadline.** `private.pending_item_deadlines` (from `20261118100000:2775`, 126 lines): a `settlement_withheld`
     item is held to the R124-6 date of the run it was withheld from — reversal → reversed settlement (`source_id` = the
     run) → that run's positive, live, dated line with the earliest `latest_execution_date`, its terms and delay, as
     `payout_returned` follows its transfer's run. A breach is recorded as for any late item, with **no** blocked
     reason (`remittance_deadline_breach_blocked_reason_check`, latest `20261117110000_transfer_line_pages.sql:58-60`,
     unchanged): the delay is the servicer's own withholding, not an outside cause, and the row says so honestly.
  8. **Worker.** `remittance/commission.py` `LineKind.SETTLEMENT_WITHHELD`, in `NEVER_COMMISSIONED`; `remittance/run.py`
     keeps it outside every mandate's gross (`NO_MANDATE`, never netted, as `PAYOUT_RETURNED`, `run.py:286`, `:353`,
     `:555`) and holds its deadline like `PAYOUT_RETURNED`; `jobs/remittances.py` `HELD_TO_SQL` (l.597) gains the
     settlement branch (twin of rule 7, parity test); `remittance/statement.py` `NATURE` (l.47) gains « Compensation
     retenue au débit, rendue » so a run carrying W renders under fr-3 (7d-3's fr-4 adds the explanation row).
  8b. **[check 2] (gap 3) The schedule.** Revision 2 said `_schedule_trigger` (`jobs/remittances.py:220`) « treats a
     waiting `settlement_withheld` like a `payout_returned` »; that function sees no kinds — it gets one boolean the
     SQL computes, `bool_or(q.kind = 'payout_returned')` in `private.remittance_schedule_candidates`
     (`20261112090000:2421-2448`). Built instead:
     - `private.remittance_schedule_candidates` **dropped and recreated** (whole copy from `20261112090000:2421`, 28
       lines; same settings; grants restated as at `:3544`, `:3559`) with one more column last, `settlement_withheld
       boolean` = `bool_or(q.kind = 'settlement_withheld')` over the same unreserved items (`draft_run_id is null`);
       `payout_returned` unchanged. Its `latest_execution_dates` already carry the withheld item's date through
       `pending_item_deadlines` (rule 7).
     - The run's trigger text **`settlement_withheld`**: the inline check of `remittance_run.trigger`
       (`20261112090000:44`, constraint `remittance_run_trigger_check`) dropped and recreated with it; a withheld
       item is not a payout that came back, and the run page would otherwise say « Virement revenu »
       (`runs.ts` `TRIGGER_LABEL`). Label « Compensation retenue à rendre ».
     - Worker: the candidates' rows unpack the new column; `_schedule_trigger(terms, payout_returned,
       settlement_withheld, latest, today, business, cal)` returns `payout_returned` first, then `settlement_withheld`,
       then `schedule`, then `deadline` — a withheld item alone makes a draft at the next hourly schedule (`7 * * * *`),
       on any day (a business day is not required, as for a returned payout): W is held to the R124-6 date of the run
       it was withheld from (rule 7), which may already be near. Unit test of `_schedule_trigger` (each order, the
       Hypothesis property of the scheduler extended with the flag) and the integration test below.
  9. **Unchanged, proven by tests:** I14 `remittance_completeness` (−4670 = pending + in flight: W sits in pending), I18
     (`settlement_ledger`: the barred 4111 lines net to 0; no `commission_settlement` row), `vat_pending_ledger`, I13.
- (b) **Before download.** `private.transfer_hold_reason` redefined (from `20261118090000:2461`): a payout whose run's
  draft `set_off_barred`/`opening_on` differs from today's is held `client_status_changed` — no file is generated or
  downloaded with it; ops cancel the run (before download: always possible) and prepare again. Downloaded: with the
  switch on the two-step cancellation is offered; off, the debit comes and (a) withholds.
- (c) **After the debit.** Nightly P0 `set_off_after_bar` (§6.3): settlements posted on or after a bar's effective date
  that took a document barred at that date — for events recorded after the debit, which (a) could not see.

**6.2.12 [critic] L12 — who receives letters and statements.** `private.client_addressee(p_client uuid, p_on date)`
[check 1] `returns table (role text, name text, address_lines text[], copy boolean)`: after a death, a qualified
guardianship or a liquidation, the event's representative in force (latest `client_status_event_representative` row:
the notary or heirs, the tutor — C. civ. 473 al. 1 (version 2009-01-01, read 2026-11-21): « le tuteur la représente
dans tous les actes de la vie civile » —, the liquidator, L641-9 I), one row, `copy` false; [check 1] after a
**curatorship**, the client itself at its billing address (`copy` false) **and** the curator (`copy` true): a curator
assists, it does not represent — C. civ. 440 al. 1 (« La personne qui, sans être hors d'état d'agir elle-même, a
besoin … d'être assistée ou contrôlée d'une manière continue dans les actes importants de la vie civile peut être placée
en curatelle »), 467 al. 3 (« A peine de nullité, toute signification faite à cette dernière l'est également au
curateur »). 467 al. 3 governs significations; none of our letters or statements is one, so the copy to the curator
is our rule by analogy (OQ-94), never presented as required by law; else the client at its billing address.
`request_advance_repayment` refuses `recipient_unknown` while a death, a qualified guardianship or a liquidation has no
representative recorded, or a curatorship has no curator recorded (7c-2's blanket refusal narrowed, 7d-1); the
statement build (7d-3) and the DRA payload (7d-1, `private.advance_repayment_payload` redefined from 7c-2) take the
addressees from it: the letter prints the addressee block, then « Copie : [nom], curateur, [adresse] » (golden DRA with
two addressees, 7d-1).

**6.2.13 [critic] L17 — qualifying the old « Tutelle ou curatelle » rows.**
`public.qualify_protection_event(p_idempotency_key, p_event_id, p_kind text check (in ('guardianship',
'curatorship')), p_evidence_document_id)` — admins at aal2, once per `guardianship` row recorded before 7d-1
(`qualified_at` null). [check 1] It writes no UPDATE (the event table is append-only, §6.1): it inserts the row's
`client_status_event_qualification` (`kind`, evidence) and, for a curatelle, records a `curatorship` event (same
client, effective date and evidence; `qualified_at` set at insert) whose id it stores in `curatorship_event_id`; from
then the old row counts as that kind through `private.client_event_effective`. Refusals (« protection qualification
refused: <code> »): `not_an_old_guardianship` (« Seuls les événements « Tutelle ou curatelle » enregistrés avant cette
version sont à préciser. »), `already_qualified` (« Cet événement est déjà précisé. »), `evidence_required` (« Joignez
le jugement. »). Until then the row keeps today's effect (payouts held) and the alert `protection_event_to_qualify`
lists it; no mandate-end effect, no fr-4 block.

### 6.3 Nightly checks and alerts

| Code | Severity | Subject | Rule | Stops when |
|---|---|---|---|---|
| `claims_to_declare` | alert (P0 in the web from 15 days before the deadline) | `client_advance` / `commission_invoice` (one row per document, [critic] L8) | a client with a `proceeding_opened` or `liquidation` event; each open invoice or advance born before the opening, or [critic] L4 any open advance (post-opening advances are outside L622-17 I by default, so declared under L622-24 al. 6), not in a `claims_declared_item`; details: opening, publication date, deadline = publication + 2 months for pre-opening claims (R622-24; « date de publication à saisir » without it), exigibility + 2 months for post-opening ones (L622-24 al. 6: « Les délais courent à compter de la date d'exigibilité de la créance »; exigibility = the advance's date by default, OQ-92), its open amount (from the ledger) | the document in a `claims_declared_item`, or nothing open |
| [critic] L8 `post_opening_unpaid` | alert | `commission_invoice` | an invoice of a client in a proceeding, born on or after the opening, unpaid at its due date; text quotes L622-17 IV (« Les créances impayées perdent le privilège … si elles n'ont pas été portées à la connaissance de l'administrateur et, à défaut, du mandataire judiciaire … dans le délai d'un an à compter de la fin de la période d'observation »); no deadline computed (the end of the observation period is not modelled; OQ-92) | paid, or ops record that it was brought to the administrator's knowledge (a `claims_declared` event naming it) |
| `payout_after_liquidation` | alert (P0) | `bank_transfer` | a payout of a client in liquidation to an account that is not its confirmed `court_appointed` one, `in_file` with a requested date on or after the judgment's date, or booked with a debit on or after it; details `cancellable` = `public.cancellation_after_download()` | in file: when booked or cancelled; booked: [critic] L11 when ops record its disposition — `public.record_liquidation_payout_disposition(p_idempotency_key, p_transfer_id, p_kind 'ratified' | 'repaid_to_liquidator', p_evidence_document_id, [check 1] p_note)` (admins, aal2) — never by elapsed time; [check 1] the check reads `liquidation_payout_disposition` by its unique `transfer_id` (§6.1): a row stops it |
| [critic] M7-MONEY-5 `set_off_after_bar` | alert (P0) | `client_settlement` entry | a run settlement posted on or after the effective date of a bar (opening, liquidation, end, seizure) that took a document barred at that date (for events recorded after the debit); amounts from the ledger (`commission_settlement` rows) | ops record the outcome (counsel's answer: kept, or the amount given back through a `client_credit` of cause `procedure`) |
| [critic] L17 `protection_event_to_qualify` | alert | `client_status_event` | a `guardianship` row with `qualified_at` null | qualified |
| [critic] L14 `seizure_standing` | alert (P0 for 15 days, then alert) | `client_status_event` | a `seizure` with no release ([check 2] no `seizure_released` naming it by `refers_to_event_id`, §6.1; one row per standing seizure); text: the declaration to the bailiff and the payment of the causes are made by ops and counsel (CPCE L211-3, R211-4, R211-5, per the legal inventory; Ops row §11) | released |

The web words them, never as law beyond the read texts: « payé au client après le jugement de liquidation (ses droits
sont exercés par le liquidateur depuis sa date, art. L641-9 C. com.) ». With the switch **off** a payout in a downloaded
file cannot be cancelled in Collectoo: the text sends ops to the bank; **on**, to the two-step cancellation.

### 6.4 Worker and texts
- Facts: `proceeding_opened_on` → `client_opening_date`; each open invoice's `born_on` (`document_born_on`);
  `set_off_barred` per kind; the opening. `run._plan`: an invoice or advance is nettable only when `document_nettable`
  holds — replaces `issue_date >= opening` (`run.py:562-564`; LEX-07 (1)); the comment says « règle du cabinet,
  prudence (OQ-41, OQ-92) », not L622-7's rule (LEX-07 (4)). [critic] L1: **the run's own new invoice** (appended in
  `_plan` as `OpenDocument(new_invoice_ref(mandate), …)`, nettable by default, `settlement.py:70`) and its corrective
  invoices get the same rule, with born_on = the earliest `encaissement_date` of the lines they charge. `_documents`
  (`run.py:461`) issues a non-nettable invoice with a true payment line, never « par compensation »: `settlement 'due'`
  to the own account with the L441-10 term of the terms (`invoice_payment_days`) when the bar is `mandate_ended`; for a
  pre-opening invoice, a liquidation or a seizure, `settlement 'due'` with the payment line « Créance née avant
  l'ouverture de la procédure collective du client (jugement du JJ/MM/AAAA) : à déclarer au mandataire judiciaire (au
  liquidateur en liquidation) ; ni payée ni compensée hors de la procédure » (seizure: « Compensation suspendue : saisie
  entre les mains du cabinet du JJ/MM/AAAA ») — exact wording for counsel (OQ-92 extended), and `invoice_overdue` leaves
  them out (§6.2.10).
- Statement fr-4 block « Fin du mandat » ([critic] L13: worded around the date the servicer learned of the event, C.
  civ. 2008): « Le mandat a pris fin le JJ/MM/AAAA (décès du mandant / tutelle / fin du mandat) ; le cabinet en a été
  informé le JJ/MM/AAAA. Ce relevé rend compte des sommes encaissées pour votre compte. Les sommes reçues jusqu'au
  JJ/MM/AAAA (information du cabinet) ont été traitées selon le mandat. Les sommes reçues après cette date sont
  reversées sans commission, ou restituées à leurs payeurs, au cas par cas. Ce que vous devez au cabinet (factures,
  avances) figure dans la position ci-dessous ; depuis le JJ/MM/AAAA (information du cabinet), il n'est plus déduit
  des reversements. Les reversements sont faits sur le compte confirmé de [la succession : compte du notaire ou désigné
  par les héritiers / la personne protégée, géré par son tuteur / vous]. » (Recipient: founder Q8, OQ-93, LEX-21.)
- Web: `terms.ts` EVENT_KIND `guardianship` « Tutelle » (was « Tutelle ou curatelle », LEX-25; old rows qualified first,
  §6.2.13), `curatorship` « Curatelle ou autre mesure de protection (règle du cabinet) », `claims_declared` « Créances
  du cabinet déclarées au mandataire judiciaire (ou au liquidateur) », [critic] `seizure` « Saisie entre les mains du
  cabinet », `seizure_released` « Mainlevée de la saisie »; the event form gains « Date de publication au BODACC » for
  proceedings, « Personne qui agit pour le client » (notary, heirs, tutor, curator, liquidator, administrator; name and
  address) and the notification hint (§6.2.1); `runs.ts` blocker labels with their exit — « Décès du client :
  confirmez le compte du notaire, ou celui que tous les héritiers désignent, avec la pièce (second administrateur) »,
  « Client sous tutelle ou curatelle : confirmez un compte à son nom géré par son tuteur ou curateur, avec le jugement
  (second administrateur) », « Mandat terminé : confirmez à nouveau le compte du client (second administrateur) »,
  « Saisie entre les mains du cabinet : ni reversement ni compensation jusqu'à la mainlevée » [critic]; the
  payout-account form's kinds and the authority document; the paragraph of `clients/[id]/reversement/page.tsx:728-735`
  rewritten to list what the code does (blocks and their exits; no set-off after the end, in liquidation or under a
  seizure, règle du cabinet; pre-opening documents and every advance of a client in a proceeding not set off and to
  declare); the payment review label « Reçu après la fin du mandat du client : à reverser au client (ou à son
  bénéficiaire) ou à restituer au payeur »; check labels `claims_to_declare` « Créance du cabinet à déclarer » /
  « Facture ou avance à déclarer au mandataire judiciaire (au liquidateur en liquidation) avant le JJ/MM/AAAA (deux mois
  après la publication au BODACC, art. R622-24 C. com. ; pour une créance née après le jugement, deux mois après son
  exigibilité, art. L622-24 C. com.). », `payout_after_liquidation` « Reversement au client après sa liquidation »,
  `set_off_after_bar` « Compensation passée après une procédure, une fin de mandat ou une saisie », `post_opening_unpaid`,
  `protection_event_to_qualify` « Tutelle ou curatelle à préciser », `seizure_standing`; [check 2] the run trigger
  label `settlement_withheld` « Compensation retenue à rendre » (`runs.ts` `TRIGGER_LABEL`, 7d-2); [critic] L9 `invoice_overdue`
  help « … Préparez le reversement du client ou vérifiez son règlement (les factures d'un client en procédure collective
  nées avant le jugement, et celles d'un client en liquidation, ne sont pas listées ici : elles sont à déclarer). »;
  [critic] L19 (c) the client space's recovery sentence per advance: « reprise sur vos prochains reversements (art. … du
  mandat) », « une demande de remboursement vous sera adressée », or after an event « ni reprise ni demandée : déclarée
  à la procédure » / « plus déduite des reversements depuis la fin du mandat ».
- Refusals (French): `claims_declared_without_proceeding` « Aucune procédure collective n'est enregistrée pour ce
  client. »; `bad_publication_date` « La date de publication ne peut précéder le jugement ni être dans le futur. »;
  `estate_without_death` « Un compte de succession suppose un décès enregistré. »; `protected_adult_without_measure`
  « Un compte de majeur protégé suppose une tutelle ou une curatelle enregistrée. »; [critic] `holder_not_client`
  « Le compte doit être au nom du client (art. 427 C. civ.) : le tuteur ou le curateur le fait fonctionner. »;
  `authority_evidence_required` « Joignez la pièce qui désigne qui peut recevoir (attestation du notaire ou désignation
  par tous les héritiers, jugement nommant le tuteur, le curateur ou le liquidateur). »; `release_without_seizure`
  [check 2] « Désignez la saisie levée : une saisie de ce client encore en cours, antérieure à la mainlevée. » (the
  form lists the client's standing seizures by date; « Aucune saisie en cours n'est enregistrée pour ce client. » when
  it has none); [check 2] `refers_to_not_allowed` « Seule une mainlevée désigne un autre événement : la saisie qu'elle
  lève. »; [check 2] `not_declarable` « Déclarez seulement des factures ou des avances de ce client, chacune pour un
  montant positif, avec une déclaration de créances. »; 7c's `before_opening` reworded « Créance née avant
  l'ouverture de la procédure du client (règle du cabinet : la date la plus ancienne retenue) : elle n'est ni compensée
  ni réclamée ici ; elle est à déclarer. »
- [check 1] Refusals added by the gaps, mapped in `lib/remittance/terms.ts` beside `EVENT_KIND` (« … refused: <code> »):

  | Code (command) | Text |
  |---|---|
  | `holder_not_client` (`propose_payout_account`, gap 10: names differ and no explanation) | « Le titulaire du RIB (X) n'a pas le nom du client (Y). Le compte doit être au nom du client (art. 427 C. civ.) ; si le RIB l'écrit autrement, expliquez pourquoi : un second administrateur vérifiera. » |
  | `not_an_event_with_representative` (`set_client_representative`) | « Cet événement ne désigne personne qui agisse pour le client. » |
  | `bad_representative` | « Indiquez le rôle, le nom et l'adresse (quatre lignes au plus). » |
  | `role_mismatch` | « Ce rôle ne correspond pas à l'événement (tuteur pour une tutelle, curateur pour une curatelle, notaire ou héritiers pour un décès, liquidateur pour une liquidation, administrateur pour une procédure). » |
  | `evidence_required` (`set_client_representative`, `qualify_protection_event`, `record_liquidation_payout_disposition`) | « Joignez la pièce justificative. » |
  | `not_an_old_guardianship`, `already_qualified` (`qualify_protection_event`) | §6.2.13 |
  | `already_disposed` (`record_liquidation_payout_disposition`, gap 9) | « Une suite est déjà enregistrée pour ce reversement. » |
  | `not_after_liquidation` (idem) | « Ce virement n'est pas un reversement fait au client après sa liquidation : rien à enregistrer. » |
  | `bad_kind` (idem) | « Choisissez : ratifié par le liquidateur, ou somme reversée au liquidateur. » |
  | `in_proceeding` (`request_advance_repayment`, 7d-2) | « Client en procédure collective : l'avance n'est ni reprise ni demandée ; elle est à déclarer. » |
  | `recipient_unknown` (narrowed, 7d-1) | « Indiquez d'abord qui agit pour le client (notaire, tuteur, curateur ou liquidateur) : la lettre lui est adressée, ou en copie au curateur. » |
- Screenshots: `m2c7-evenement-client`, `m2c7-beneficiaire-succession`, `m2c7-controles-creances-a-declarer`,
  `m2c7-paiement-apres-fin-mandat`, [critic] `m2c7-saisie`.

### 6.5 Switch
Blockers and set-off rules do not read it. `payout_after_liquidation` and the hold of §6.2.11 (b) word the exit by it
(§6.3); the debit-time withholding (§6.2.11 (a)) is the same switch off and on.

### 6.6 Tests
**pgTAP `046_client_status_effects.test.sql`** (≈ 70): per event kind, the blocker with no payee, with the wrong kind,
with a confirmation before the event, by the client's own user (refused), then lifted by the right kind confirmed after
by a second admin with its authority document; curatorship blocks payouts but not the confirmation gate; a
liquidation-only client has an opening; an invoice issued after the opening for collections before it is not set off
(the old criterion's mutant); an advance born before the opening is not taken; liquidation and after-end plans set
nothing off (credit notes still apply); approval sent back `client_status_changed` when the bar changes after prepare; a
payment after the end held `client_mandate_ended`, forwarded with reason `mandate_ended` at nil commission;
`claims_to_declare` with and without publication date, the deadline, stopped per document by `claims_declared`;
`payout_after_liquidation` in file (switch off: not cancellable; switch on: cancellable) and booked; 7c's commands refuse
`before_opening` with the new criterion; `record_client_status_event` new refusals and replay. [critic] Added:
- L1: RJ opened 15/11, RV-5 approved 20/11 charging collections of 02/11–14/11 → its new invoice is not set off, issued
  `due` with the procedure payment line, never « par compensation »; a death recorded with a netting clause → the new
  invoice `due` with its L441-10 term; `invoice_overdue` silent for the first, firing for the second after its date.
- L2: a `protected_adult` account whose holder is the tutor → `holder_not_client`; without the judgment →
  `authority_evidence_required`; held in the client's name with the judgment, confirmed by a second admin → lifted.
- L4: RJ opened 01/12, an advance born 05/12 → not taken by a claw-back run, `request_advance_repayment` refused
  `in_proceeding`, listed in `claims_to_declare` with deadline exigibility + 2 months,
  `advance_open` silent.
- L8: a declaration naming FC-3 only, then an advance born later (pre-opening) → listed alone; `post_opening_unpaid`.
- L9: a pre-opening invoice past its due date → no `invoice_overdue`.
- L10: an `estate` account without the authority document → refused; with the notary's attestation → lifted.
- L11: `payout_after_liquidation` booked stays after 30 days; a disposition recorded → stops.
- L12: a DRA after a tutelle with no representative → `recipient_unknown`; with the tutor recorded → the payload's
  addressee is the tutor; the fr-4 statement's addressee likewise.
- L13: a death on 01/12 recorded 10/12, RV-11 approved 08/12 → the fr-4 block states both dates (golden).
- L14: a seizure standing, an N = 0 run → approval refused `payout_blocked:client_status:seizure`; nothing set off;
  released → approval passes.
- L17: an old `guardianship` row (qualified_at null) → no fr-4 block, payouts held, `protection_event_to_qualify`;
  qualified as curatelle → the curatorship effects only.
- F16: guardianship recorded 01/12, then mandate_ended 05/12 → a `client` account re-confirmed after 05/12 does **not**
  lift; a `protected_adult` account with the judgment does.
- M7-MONEY-5, switch off and on: RV-7 approved 01/12 (plan nets FC-6 and takes A2), downloaded, the judgment
  (effective 02/12) recorded before the debit is booked on 03/12 → the debit posts `settle:<run>` without the barred
  takes, `settle:<run>:barred` and its reversal, a `settlement_withheld` item of W, FC-6 and A2 still open; the next
  run pays W; before download the payout is held `client_status_changed`; an event recorded after the debit →
  `set_off_after_bar` lists the settlement with its amounts.

[check 1] The file splits with the PRs: **046a** (7d-1: blockers, payees, events, representatives, qualifications,
recipients, after-end hold; L2, L10, L12, L14's blocker, L17, F16; [check 2] the release link and « standing », the
declared items, `epc_name_key`'s spellings), **046b** (7d-2: bars, approval, hold, the withholding; L1, L4, MONEY-5;
[check 2] the withheld item's schedule), **046c** (7d-3: the declarations' alert, liquidation, `invoice_overdue`,
fr-4; L8, L9, L11, L13).
Added:
- **Gap 1 (046b), the withholding through the ledger, switch off and on.** (i) RV-7's debit with FC-6 (pre-opening,
  barred) and FC-8 (post-opening, allowed): two entries `settle:<RV-7>` (FC-8's part, its `commission_settlement`) and
  `settle:<RV-7>:barred` + `return:barred:<RV-7>` (W = FC-6's part, no `commission_settlement`); the ledger after the
  debit, line by line (4670[c] −W, 4111[c] = FC-6 open + …, 44574/44571 back to their pre-debit values for FC-6's
  VAT); `remittance_pending` holds one `settlement_withheld` item of +W whose entry is the reversal;
  `remittance_completeness` (I14), `settlement_ledger` (I18), `vat_pending_ledger`, `client_payable_debit` (I13) empty;
  (ii) the whole plan barred → only the barred pair, W = D; (iii) a refund settle larger than the allowed invoices →
  the whole plan withheld (no zero or negative entry); (iv) the next run's prepare carries W as a line of kind
  `settlement_withheld` (the line insert guard accepts it unchanged), outside every mandate's gross, no commission,
  deadline = RV-7's earliest line's latest execution date (`pending_item_deadlines`), and its debit pays W; a breach
  after that date has no blocked reason; (v) **LG003 still raised** for every other settlement reversal, each in its
  own subtransaction: a raw `ledger_reverse` of `settle:<RV-7>`; a reversal of `settle:<RV-7>:barred` under any other
  key; a `return:barred:<RV-7>` key reversing `settle:<RV-7>`; a `return:barred:<RV-9>` reversing
  `settle:<RV-7>:barred`; a commission invoice and a write-off reversed; (vi) a barred settlement posted without its
  reversal (planted) → LG003 at `ledger_check_now()` (the commit check).
- **Gap 3 (046a).** `set_client_representative` writes a row; a second call writes a newer row and
  `client_addressee` returns it; the event row is unchanged (`xmin` and every column compared); a direct UPDATE of
  `client_status_event` still raises (`refuse_change`); `qualify_protection_event` inserts its row and, for a curatelle,
  the `curatorship` event, and `client_event_effective` answers `curatorship` for the old row; a second qualification
  → `already_qualified`; the two side tables' isolation (servicer B, a client admin, a restricted viewer, a collector
  read nothing; `authenticated` cannot insert, update or delete) and their change-log rows; a row recorded after 7d-1
  carries `qualified_at`, an insert with it null is refused, the rows from before keep null.
- **Gap 7 (046a).** A curatorship with a curator recorded → `client_addressee` returns the client (`copy` false) and
  the curator (`copy` true); the DRA payload has both (golden PDF with « Copie : …, curateur »); a curatorship without a
  curator → `recipient_unknown`; a qualified guardianship → the tutor alone.
- **Gap 9 (046c).** `record_liquidation_payout_disposition`: admin at aal2 only; `not_after_liquidation` for a payout
  booked before the judgment, for a payout to the confirmed `court_appointed` account and for a sweep; `evidence_required`;
  `bad_kind`; a second call → `already_disposed`; replay returns the first result; `payout_after_liquidation` listed
  before, gone after; RLS and change log of the table.
- **Gap 10 (046a), boundary cases of `epc_name_key`.** Equal (accepted without explanation): « Société Martin » vs
  « SOCIETE  MARTIN », « Jean-Luc Dupont » vs « JEAN LUC DUPONT », « Œuvre d'Élan » vs « OEUVRE D ELAN ». Different
  (refused `holder_not_client` without explanation, accepted with one, the explanation shown on the confirmation):
  « M. Jean Dupont » vs « Jean Dupont », « Dupont Jean » vs « Jean Dupont », the tutor's name; an explanation of 0 or
  501 characters → refused; Python/SQL parity of the key (Hypothesis).
- **Gap 11 (046b).** After 7d-2, an advance of a client in a proceeding is skipped by `client_settlement_plan`'s
  default order (whatever its birth date); a designated payment of it → a `procedure` credit.
- **[check 2] Gap 4 of check 2 (046a), `epc_name_key` on the writer's spellings.** « Bœuf SARL » vs « BOEUF SARL »
  accepted without explanation, both keys `BOEUF SARL` in SQL and in Python (pinned literal); « Æther » → `AETHER`,
  « Straße » → `STRASSE`, « Þór » → `THOR`; « Œuvre d'Élan » vs « OEUVRE D ELAN » (revision 2's case, now passing);
  a holder name in Cyrillic → key null → `holder_not_client` without explanation, accepted with one; U+034F inside a
  name → null in both twins. Hypothesis: twin parity on generated text, and the writer property (§6.2.7).
- **[check 2] Gap 6 of check 2 (046a), the release and « standing ».** A `seizure_released` naming a standing seizure
  of the client → recorded, `refers_to_event_id` set, the seizure stands until the release's effective date and not
  from it (`client_seizures_standing` on the day before and on the day); two seizures, one released → the blockers and
  `seizure_standing` still list the other, `remittance_approval_refusal` still refuses (7d-2's 046b re-runs it);
  `release_without_seizure` for no `p_refers_to`, a seizure of another client, a seizure effective after the release,
  a `death` event named, and a seizure already released (the second of two calls; and two sessions releasing the same
  seizure at once → one row, the other refused, the unique index's `unique_violation` mapped to the code);
  `refers_to_not_allowed` for `p_refers_to` on a `death`; a raw insert of a `seizure_released` with
  `refers_to_event_id` null, or of a `death` with it set → `check_violation` (the column check); a raw insert naming
  a seizure of another client → the guard's `check_violation`; a raw second release of one seizure → `unique_violation`.
  **Declared items (moved from 7d-3):** `record_client_status_event('claims_declared', …, p_declared)` writes one
  `claims_declared_item` per document with its amount; `claims_declared_without_proceeding` with no proceeding;
  `not_declarable` for a credit note, another client's invoice, an amount ≤ 0, or `p_declared` on a `death`; replay
  → one event, the same items; the item table's isolation (servicer B, a client admin, a restricted viewer, a
  collector read none; `authenticated` cannot insert, update or delete), append-only, change log. 046c then reads the
  same rows through `claims_to_declare` (the L8 case).
- **[check 2] Gap 3 of check 2 (046b), the schedule.** A `settlement_withheld` item alone (nothing else pending for
  the client) → `remittance_schedule_candidates` returns `settlement_withheld` true and `payout_returned` false, and the
  schedule job (`run_schedule`, integration) creates a draft with trigger `settlement_withheld` at its next run, on a
  Saturday too; with a `payout_returned` item also waiting → trigger `payout_returned`; the constraint accepts the new
  trigger and still refuses an unknown one; the run page labels it « Compensation retenue à rendre ».

**Worker**: unit (`_plan` nettable rules incl. the new invoice; `_documents` payment lines), golden fr-4 statement
(with the recorded date, the representative and a withheld row), golden invoices (procedure line, after-end line),
integration (a client in proceeding between two runs; a death then the estate's account confirmed, the run approved;
the debit-time withholding through the real debit job). **vitest**: every label and text above. **E2E**: record a
death with the notary as representative, confirm the notary's IBAN with the attestation as a second admin, approve.
**Mutants**: opening from `proceeding_opened` only → liquidation case; `issue_date` criterion → born-on case; the new
invoice nettable by default → L1 case; blocker lifted by any kind → wrong-kind case; latest event only → F16 case;
confirmation before the event accepted → timing case; gate hold off → after-end case; N > 0 condition kept for the
seizure → L14 case; the debit-time re-read removed → MONEY-5 case; advances in a proceeding nettable after the opening
→ L4 case; holder check removed → L2 case. [check 1] The guard's exception widened to any `return:barred:%` key →
gap 1 (v) third case; the run-id match dropped → (v) fourth case; the exception extended to commission documents →
(v) fifth case; the commit check removed → (vi); the 4670 trigger's new branch removed → (i) (I14 violation, W not in
pending); `pending_item_deadlines` without the settlement branch → (iv) (no deadline); the refund settle treated as
barrable → (iii); `client_addressee` returning the curator alone for a curatelle → gap 7; the side tables' select
policy opened to client members → gap 3 isolation; `epc_name_key` without the accent map → « Œuvre d'Élan »; without
the space collapse → « SOCIETE  MARTIN »; `already_disposed` dropped → gap 9 second call. [check 2] `epc_name_key` on
`epc_name_empty`'s one-letter map → « Bœuf SARL »; without the null rule (non-Latin left as is or spaced) → the
Cyrillic case; the second `_SPELLED` pass dropped → the parity property; `client_seizures_standing` ignoring the
release's date → the day-before case; the release check without `refers_to_event_id` (any release lifts every
seizure) → the two-seizures case; the partial unique index dropped → the two-session release case;
`remittance_schedule_candidates` without the new column (or `_schedule_trigger` ignoring it) → the « withheld item
alone » case; `settlement_withheld` ranked before `payout_returned` → the « both waiting » case.

### 6.7 Docs (7d)
ADR-0014 « M2c-7d » (incl. the qualification of old guardianship rows, L17; [check 2] a release names its seizure,
the trigger `settlement_withheld`, `epc_name_key`'s spellings); COMPLIANCE CPCE-03 (mandate end read by the
allocation gate; payee; [critic] L20 a note for M4: the send guardrail reads `client_status_event`, `public.mandate`
has no end state), CPCE-08 (blocked payee, after the end), MAND-02 (end of mandate; [critic] C. civ. 427, 473 for the
payee and the recipient), PROC-01 (client in proceeding), new Ops row « Saisie entre les mains du cabinet » [critic]
L14, OQ-41 (connexité, C. civ. 1348-1; birth date; payees), new OQ-91 (seizure), OQ-92 (birth of the claim; [critic]
advances in a proceeding; post-opening declarations; provisional declaration under L622-24 al. 4 « déclarées sur la
base d'une évaluation »; L641-13 III; the invoice's procedure wording; a set-off approved before the judgment and
posted after), OQ-93 (after the end; [critic] heirs' shares, C. civ. 1309), OQ-94 (curatelle; [critic] C. civ. 427 al.
5), [critic] OQ-99 (a payout made to the client after its liquidation: discharge, ratification, statements owed to the
liquidator, access of the client's users — LEX-12); design §3.1 row 2003 reworded (only revocation, renunciation, death
and tutelle end the mandate; proceedings do not: L622-13 I, L641-11-1 I) and §9.6 last bullet; DOMAIN; PROGRESS.

---

## 7. 7e — Top-ups, the own-account file, our references in CSV labels

Branch `m2c7e`. Migration `<timestamp at PR open>_top_ups_and_bank_residues.sql`. Closes D08, D11, D12. [critic] F12:
built **after** 7d (both redefine `run_advance_checks`, `debits.ts` CHECK_LABEL, COMPLIANCE and ADR-0014), from 7d's
merged bodies.

[check 1] [check 2] **Three PRs.** **7e-1** (`m2c7e-1`, `<timestamp>_top_ups.sql`): §7.1, §7.2 (with the guards
below), S23's texts, pgTAP 047a. **7e-2** (`m2c7e-2`, `<timestamp>_label_references.sql`): §7.3's S24 up to the review
— the kind, its import, the job's candidates and `decide_line`, `debit_queue` — pgTAP 047b. **7e-3** (`m2c7e-3`,
`<timestamp>_label_reference_exits.sql`): §7.3's three exits with every guard and reader they need, pgTAP 047c. 7e-2
merges after 7e-1 (`decide_line` and `bank_debit_review_reason_check` are redefined by both), 7e-3 after 7e-2 (§1.4:
7e-2 alone holds such a credit in review, never as a payment).

### 7.1 Top-ups ordered automatically (design §13 #4)
- **`private.top_up_needed(p_org uuid, p_currency char(3)) returns bigint`** = greatest(0, Σ4679 postings of the
  servicer and currency + Σ sweeps `ordered` or `in_file` − Σ top-ups `ordered` or `in_file`). When 4679 holds the
  servicer's money awaiting the sweep (Σ4679 < 0), an advance or a fee just reduces it, with no top-up (ops critique
  #16). [critic] M7-MONEY-4: a filed top-up leaves the formula when its credit is booked (7.2), so none stays
  subtracted for ever.
- **[critic] F8 — one servicer per transaction.** The draft's `private.order_due_top_ups()` looped over every servicer
  in one cron transaction: advisory locks taken in a completed exception block are held to the top-level commit, so a
  wait on one servicer kept every earlier servicer's `payments:` and `remit:` locks (their « Désimputer », debit job
  and approvals then fail or queue). Instead pg_cron `servicer-top-ups` `37 * * * *` →
  `select private.queue_top_ups()` queues one `{type: 'top_ups', organization_id}` job per servicer with an active
  `client_funds` account (the `remittances-schedule` pattern, `20261112090000:2417`); the worker runs
  **`private.order_due_top_up(p_org uuid) returns integer`** in its own transaction per servicer: `set local
  lock_timeout = '2s'`, `remittance_command_locks(org, true)`; on 55P03 the servicer is skipped until the next hour (the
  job records a miss; `top_up_order_failed` after three consecutive misses or any other error). Per active
  `client_funds` account (one per currency, founder #14), needed > 0 and an active own account named in
  `servicer_billing_settings` → one `bank_transfer` kind `top_up` as `request_top_up` builds it (debtor own, creditor
  dedicated, payee the servicer's legal name, `TOP…` id, `remittance_info` « APPROVISIONNEMENT COMPTE DEDIE TOP… »,
  requested today, `ordered_by` null, reason « Approvisionnement automatique : le cabinet doit X € au compte dédié
  (avances, frais, pertes) »). Idempotent by its formula (an ordered top-up lowers what is needed). It never cancels an
  order: ops may have typed it at their bank already. Any amount above zero (founder Q3).
- **Shortfall log** (C. civ. 1996, OQ-38 « durations logged »): `private.servicer_shortfall_period (id,
  organization_id, currency, opened_at, closed_at null, peak_minor)`, updated by the hourly job: opened when Σ4679 > 0
  (the servicer owes the account: other clients' money covers it meanwhile), peak kept, closed when ≤ 0.
  `public.servicer_shortfall_periods(p_organization_id uuid, p_limit integer default 50)` (money staff) lists them with
  the advances, fees and losses posted inside each. [critic] F18: RLS on, privileges revoked, change log, pgTAP
  isolation.
- Nightly (`run_advance_checks` redefined from 7d's body): `top_up_account_missing` (alert) when needed > 0 and no own
  account. `servicer_shortfall` keeps its formula until 7f (D7); the web ranks it and `top_up_pending` P0.

### 7.2 The own-account top-up file
- **`public.generate_top_up_file(p_idempotency_key text, p_own_bank_account_id uuid) returns jsonb`** — admins and ops
  managers at aal2; an active own account in EUR (`not_an_own_account`, `not_eur`); one live top-up file per own account
  (a generated one not downloaded is superseded, new MsgId); its items: every `ordered` top-up of that debtor
  (`nothing_to_file`); ReqdExctnDt today before the account's cut-off (`servicer_billing_settings.bank_cutoff`), else the
  next business day; **no cash check** (the own account's statements are not imported, design R12), no sweep, no
  per-client cap. The existing `transfer_file {file}` job writes it (Dbtr = the own account; the writer takes the
  debtor from the file). Lock order: the account row, `remittance_command_locks`, then files and transfers.
- **[check 1] The guards that refused it (gap 4).** At `1440178` the own-account file cannot exist:
  `private.transfer_file_guard` (`20261115090000_transfers_files.sql:559`, 57 lines) requires on INSERT a debtor that is
  an active `client_funds` account (l.568–571) and, while the switch is off, refuses `superseded` or `rejected` on a
  downloaded or sent file (l.607–612); `private.bank_transfer_guard` (`20261115090000:742`, 92 lines) refuses `in_file →
  ordered | cancelled` for a transfer of a downloaded file while the switch is off (l.824–830). So the draft's
  `generate_top_up_file` could not insert and `cancel_top_up_file` « after download, whatever the switch » was
  refused. 7e-1 redefines both (whole copies), each with one exemption, and adds one guard so that the exemption can
  only ever cover top-ups:
  - `transfer_file_guard`: on INSERT, the debtor is an active `client_funds` account **or an active own account
    (`purpose = 'own'`) of the file's servicer** (same IBAN rule); the fail-closed rule on close is skipped **only**
    when the file's debtor is an own account. Every other rule unchanged.
  - `bank_transfer_guard`: the fail-closed rule on leaving a downloaded file is skipped **only** for `kind = 'top_up'`
    whose file's debtor is an own account. Every other rule unchanged (payouts, refunds and sweeps stay fail-closed).
  - New `private.transfer_file_item_guard()` (statement trigger after insert on `public.transfer_file_item`, `enable
    always`; the item table had none): an item of a file whose debtor is an own account names a `top_up` transfer of
    that debtor; an item of a `client_funds` file never names a `top_up` (« transfer file item: a top-up only in an
    own-account file, and only top-ups there », `check_violation`). With it, « debtor is an own account » means « holds
    only top-ups », which is what the two exemptions rely on.
  033's fail-closed tests stay unchanged for payout and refund files (they must pass as they are).
- **[check 1] `public.cancel_top_up`** redefined (from `20261111090000:1621`, 35 lines): also cancels a top-up
  `in_file` of an own-account file (allowed by the exemption above), so a single filed `TOP` whose credit was booked
  without it can be closed without cancelling its whole file; its refusal « the top-up is no longer pending » is mapped
  « Cet approvisionnement n'est plus en attente (comptabilisé ou annulé). ».
- **`public.transfer_file_download`** redefined (from `20261118090000:2296`): a file whose debtor is an own account skips
  the cash and sweep re-checks; the hash check, the download log, the second-download warning and `file_executed` (a
  credit of one of its `TOP` ids seen) stay.
- **[critic] M7-MONEY-4 — the credit of a filed top-up books.** Filing puts a top-up `in_file`, but both twins book a
  top-up credit only from `ordered`: the debit job (`payments/debits.py:732-737` → `TOP_UP_DIFFERS`) and the SQL
  re-check `private.bank_booking_recheck` (`20261119090000:2062`; its `transfer_not_pending` rule at `:2257`). 7e
  redefines both, the same way: a credit naming a `TOP` id
  books as `servicer_top_up` when its transfer is `ordered`, **or `in_file` of an own-account file of the same
  servicer** (the file's debtor is that servicer's own account; same amount and currency; creditor = the line's
  account); the booking sets the transfer `booked` and, when every top-up of the file is booked, closes the file's
  executed state. The SQL's `names_our_lot` / `TF-` rules stay aimed at the dedicated account's own lots (a top-up
  file's lot is the own account's, never the dedicated account's: a test proves the credit is not refused
  `own_transfer_line`). The re-check is redefined as a whole copy (from `20261119090000:2062`, ≈ 360 lines; in 7e's
  size).
- **[critic] M7-MONEY-4 — the late credit of a cancelled top-up.** Both twins send a credit naming a `cancelled`
  top-up to review `top_up_cancelled_credit` (« Approvisionnement annulé puis exécuté par la banque ») with one exit,
  « Comptabiliser comme approvisionnement »: [check 1] `public.link_debit(…, 'own_credit', …)` (latest
  `20261117110000_transfer_line_pages.sql:2518`; the draft's « `book_own_credit` » does not exist) as `servicer_top_up`
  with **no** transfer (the servicer's own money, swept back by the next file). [critic] An ops booking of a top-up
  credit that names no `TOP` id is offered the open (`ordered` or `in_file`) top-ups of the same amount and, when ops
  pick one, books it (so no top-up stays `in_file` for ever); with none picked it books without transfer, as today.
  [check 1] (gap 12) The pick is a new command, `link_debit` keeping its signature:
  **`public.book_top_up_credit(p_idempotency_key text, p_bank_transaction_id uuid, p_transfer_id uuid, p_reason text)
  returns jsonb`** — admins and ops managers at aal2; replay + request hash; locks as `link_debit`'s top-up branch; the
  line an `own_transfer_in` credit neither linked nor booked whose end-to-end id names no `TOP` (that one books itself
  through the funds pass); the transfer a `top_up` of the line's servicer, `ordered` or `in_file` of an own-account
  file, of the line's amount and currency, its creditor the line's account; then one `_bank_booking` row (kind `top_up`,
  that transfer) through `private.post_bank_bookings(org, true)` (whose re-check 7e-1 widens to `in_file`). Refusals
  (« top-up credit refused: <code> »): `not_an_own_credit` « Ce crédit n'est pas un virement reçu du compte propre. »,
  `line_booked` « Cette ligne est déjà comptabilisée. », `carries_top_up_id` « Ce crédit porte déjà sa référence TOP… :
  il est comptabilisé automatiquement. », `top_up_not_open` « Cet approvisionnement est déjà comptabilisé ou annulé. »,
  `amount_differs` « Le montant ou le compte ne correspond pas à cet approvisionnement. ». When the credit was booked
  **without** its `TOP` (no pick), the `TOP` stays `ordered` or `in_file` and `top_up_needed` keeps subtracting it:
  its exit is `cancel_top_up` (either status, above) — the `top_up_pending` P0 help says so (§7.4).
- **`public.cancel_top_up_file(p_idempotency_key text, p_file_id uuid, p_reason text)`** — before or after download,
  **whatever the switch**: a top-up executed after its cancellation only adds the servicer's own money to the dedicated
  account (booked as above, then swept back); no client is paid twice, which is what the switch guards. Its top-ups not
  booked → cancelled; the file superseded or rejected; the next hourly order re-orders what is still needed. Refusals
  `nothing_to_cancel`, [critic] F13 **`not_a_top_up_file`** (the file's debtor is not an active own account of the
  servicer, or any item is not a `top_up`: a payout file must never pass through here — `transfer_file_release(…,
  'superseded')` returns a file's payouts to the queue, so a downloaded payout file cancelled this way with the switch
  off would pay twice). Lock order: the file row, `remittance_command_locks`, then transfers, as
  `generate_transfer_file`. [check 1] It cancels the file's `in_file` top-ups itself (in_file → cancelled) and closes
  the file through `private.transfer_file_release` (latest `20261118100000:4663`; it touches only sweeps, payouts and
  refunds, none of which an own-account file holds), both allowed with the switch off only by the exemptions above;
  `not_a_top_up_file` is checked first, so a payout file never reaches either.
- Founder Q14: build it, unless the servicer's bank takes no file on the own account (then ops keep typing the `TOP` id).

### 7.3 Our references in a CSV label (S24) and S23
- **S24** (`m2c-6b-2-plan.md` §1.1, OQ-84 (e)/(h)): `payments.statement.refine_kind` (Python) and its SQL twin
  `private.bank_line_refined_kind` (redefined from `20261116090000:5419`) read, on a **CSV** line whose end-to-end
  column is empty or absent, a whole token `^(RMT|SWP|TOP)[0-9A-F]{12}$` in the label as a candidate reference; the SQL
  ingest keeps it only when it is the `end_to_end_id` of a transfer of that bank account (`bank_transfer.end_to_end_id`
  is unique; `RFD` references keep M2b's own refund link). [critic] M7-MONEY-6: **it never books alone.** The candidate
  is stored in a new column `bank_transaction.reference_from_label text` — never in `end_to_end_id` or
  `original_end_to_end_id`, so `refine_kind`'s `names_our_transfer` → `return`, `decide_line`'s `_transfer_return`
  (`payments/debits.py:660-693`, which books any amount ≤ the transfer with the rest as a bank fee) and the SQL
  `not_a_fee` rule (`20261119090000:2227-2232`) never read it. A line with a candidate goes to review
  `label_reference` (« Le libellé cite notre virement RMT… : est-ce ce virement qui revient ? »), the candidate shown;
  ops confirm through the existing links: a confirmed return must **equal** the transfer's amount (no bank fee for a
  difference; a partial amount stays in review); a client quoting our reference in a repayment is a client payment
  (7c), a coded bank charge naming our payout is a fee. Founder Q15.

  **[check 1] Held under its own kind, and its three exits (gap 5).** As drafted, the candidate was kept apart from
  `end_to_end_id` but the line's kind was untouched: a credit from an unregistered IBAN stays `debtor_credit`, and
  `private.ingest_statement` (latest `20261117100000_transfer_line_ops.sql:2749`, its step 4 « one payment per credit a
  debtor paid », body l.≈ 294) creates a debtor payment from it — S23 again, with no undo (D10) — and the « client
  payment » exit was refused by `book_client_payment_line`'s own `our_reference` rule. 7e-2 makes such a line a kind of
  its own:
  - **Kind `label_reference`** — a credit that would otherwise be `debtor_credit` or `client_transfer_in` and carries a
    kept candidate. Held: never a payment (no `payment`, no `cash_in` at import), never booked by the debit job, never a
    return by itself. DDL: `bank_transaction_kind_check` and `bank_transaction_kind` (credit list),
    `bank_line_held_kind_kind_check`, `bank_duplicate_resolution_released_kind_check` (`20261111090000:1804-1825`) and
    the import's own kind list gain it; `bank_transaction_own_idx` is recreated with it (the job's and the queue's
    reads); `bank_transaction.reference_from_label text null check (~ '^(RMT|SWP|TOP)[0-9A-F]{12}$')` and the same
    column on `private.bank_import_stage`; `bank_debit_review_reason_check` gains `label_reference`.
  - **Both twins.** The parser (`payments/statement` CSV presets) sets the stage's `reference_from_label` from a whole
    label token, only when the end-to-end column is empty or absent. `payments.statement.refine_kind` and
    `private.bank_line_refined_kind` gain a ninth argument `p_reference_from_label` (the eight-argument form at
    `20261116090000:5384` becomes a wrapper passing null, as the six-argument one at `:5419` already is): a credit whose
    base kind is `debtor_credit` and which is not refined to `own_transfer_in`, `client_transfer_in` or `return`
    becomes `label_reference` when the argument is set; a `client_transfer_in` with it also becomes `label_reference`;
    debits are unchanged (a coded charge naming our payout stays `other_debit` and books as a fee). Parity test on
    generated labels and kinds (Hypothesis). `private.stage_refined_kinds` and `private.held_line_kind` (from
    `20261116090000:5435`, `:5460`) pass the column.
  - **`private.ingest_statement`** redefined (whole copy from `20261117100000:2749`, 441 lines): before the
    refinement, a stage candidate is kept only when it is the `end_to_end_id` of a transfer of this account (by the
    unique `bank_transfer.end_to_end_id`: a payout or sweep whose debtor, or a top-up whose creditor, is the statement's
    account), else nulled (a look-alike is ignored); `reference_from_label` copied to `bank_transaction`; the payment
    step keeps `n.kind in ('debtor_credit', 'batch_unsplit')`, so a `label_reference` line gets no payment (a 047b
    case asserts no `payment` row and no `cash_in` posting for it).
  - **The job** (7e-2). `decide_line` (worker) sends a `label_reference` line to review `label_reference` and never
    books it. The SQL re-check (`bank_booking_recheck`, 7e-1's body) needs no change: its kind rules already refuse a
    top-up, a fee or a loss booked on such a line (`not_an_own_credit`, `not_a_fee`, the loss rule's direction); a 047b
    case proves each. [check 2] (gap 1 (3)) Revision 2 stopped there, and the job would never have seen the line: the
    job decides only what `private.bank_booking_candidates` hands it (latest: the `create function` at
    `20261117090000_transfer_line_foundations.sql:882`, after its `drop` at l.881), whose first branch fetches kinds
    `transfer_out`, `own_transfer_in`, `client_transfer_in` (l.910) and whose held-duplicate branch fetches lines
    released as those kinds or as a flagged return (l.949-953); the others are fixed patterns (TF- lot debits, flagged
    `return` credits under our id, coded charges, unsplit entries). So no review row, and 047b's « the debit job leaves
    it in review » could not pass. 7e-2 redefines it (**whole copy from `20261117090000:882`, 167 lines**; same
    signature and return columns, so `create or replace`; settings and grants restated as at l.2302-2306): both kind
    lists gain `label_reference` — the first branch (a line imported so) and the held-duplicate branch (a held line
    `resolve_duplicate` released as `label_reference`: it books no payment for that kind, `20261117090000:2273`, and
    the line must still reach review). The line comes with no transfer (no role matches its kind: `f` reads only end-
    to-end ids); `decide_line` reviews it before any other credit rule (`_funds_review(line, LABEL_REFERENCE)`), and
    `apply_bank_bookings` writes the review as for any other (`20261117090000:1500-1535`). Not chosen: the ingest
    writing the review row itself (Appendix B).
  - **Exit (a), a return of exactly that transfer** ([check 2] 7e-3) — through `public.book_transfer_line` with one
    return part naming the candidate's transfer: `private.transfer_line_check` redefined (whole copy from **7b's** body,
    801 lines + the rules below; in 7e-3's size) admits a `label_reference` credit as a return line (beside `return`,
    `own_transfer_in`, `client_transfer_in`) only for the transfer its `reference_from_label` names
    (`label_reference_transfer`) and only for exactly that transfer's amount, with no fee part
    (`label_reference_amount`); `private.transfer_line_class` (from `20261117100000:124`, 34 lines),
    `private.transfer_line_pre` (from `20261117113000:59`, 95 lines) and `private.transfer_line_bookable_as` (from
    `20261117110000:2076`, 47 lines) give such a line the class `l` whose only returnable transfer is the candidate's.
    A payout (`RMT`) or a sweep (`SWP`) only: a `TOP` candidate has no return exit (a top-up arrives from the own
    account as `own_transfer_in`, never `label_reference`; a credit citing a `TOP` from another IBAN is a client's or a
    debtor's payment).
    [check 2] (gap 1 (1)) The booking `transfer_line_post` then inserts is refused at `1440178`:
    **`private.bank_line_booking_guard`** (latest `20261121090000_switch_on_prerequisites_4.sql:641`) admits
    `payout_returned` and `sweep_returned` (l.743-760), `unplanned_payout_returned` and `unplanned_sweep_returned`
    (l.763-783) only on kinds `return`, `own_transfer_in`, `client_transfer_in` (or an unsplit line), and
    `client_payment` only on `client_transfer_in` (l.784-787). 7e-3 redefines it (**whole copy from
    `20261121090000:641`, 155 lines**; no earlier M2c-7 slice redefines it — if one does, from that slice's body;
    settings `enable_hashjoin/mergejoin/seqscan = off` and the trigger's grants restated), its lateral read gaining the
    line's `reference_from_label` and the booking transfer's `end_to_end_id` (by key, as `tr_kind` is): the four return
    arms also admit a `label_reference` credit (as read, or a held duplicate released as one — the guard's
    `case when t.kind = 'suspected_duplicate' then r.released_kind`) **only when `n.transfer_id` is not null and that
    transfer's `end_to_end_id` = the line's `reference_from_label`**, every other condition of the arm unchanged (so an
    `unplanned_*_returned` booking with no transfer, or naming a run-mate payout, stays refused on such a line); the
    `client_payment` arm admits `kind in ('client_transfer_in', 'label_reference')`, nothing else changed (exit (b)).
    [check 2] (gap 1 (4)) Once booked, the return must count: **`private.remittance_chain_events`** (latest
    `20261118100000_switch_on_prerequisites_2.sql:164`) counts a return only by our id in the line's end-to-end or
    original end-to-end id, an unsplit detail, or a lot credit of its PmtInf booked as its return (l.236-258); a CSV
    `label_reference` line carries none of them, so after exit (a) `remittance_run_paid_on` still answered the
    execution date, 7a's `run_settled_on` rule 2 answered `paid`, `entry_remitted.paid_on` was not null for a payout
    that came back, `request_advance_repayment` stopped refusing `payout_not_received` and the letter printed « versé
    le » — what D1/L5 forbid. 7e-3 redefines it (**whole copy from `20261118100000:164`, 101 lines**; same signature,
    settings and grants, `20261118100000:5136`): its third return branch (the credits booked `payout_returned` or
    `unplanned_payout_returned` for this transfer, read by `bank_line_booking_transfer_idx`) counts such a credit when
    it carries no end-to-end id **and** either names a lot of this transfer (unchanged) **or** its
    `reference_from_label` = the transfer's `end_to_end_id`. Only a booked line counts: a `label_reference` line in
    review is never counted (it may be the client's payment, D14). `remittance_chain_paid`, `remittance_run_paid_on`,
    `run_settled_on` and the nightly's booked branch read the events and need no change.
    `private.transfer_return_seen` (`20261115090000:1042`, the bank's `return` flag as evidence before any booking)
    is unchanged: an unflagged return is not evidence there today either.
  - **Exit (b), a client's payment** ([check 2] 7e-3) — `public.book_client_payment_line` redefined (from 7c-1's
    body; dropped and recreated with a trailing `p_client_organization_id uuid default null`, grants restated, web
    caller updated; its `client_payment` booking passes the guard's widened arm above):
    a `label_reference` line is accepted, its label reference ignored, with the client ops name (`client_required`
    when absent; `client_mismatch` when the line's IBAN is another client's confirmed payout IBAN); for a
    `client_transfer_in` line the parameter must be null or the IBAN's client. The other `our_reference` rules
    (end-to-end, original, lot, `TOP`) are unchanged.
  - **Exit (c), a debtor's payment** ([check 2] 7e-3) — `public.release_own_credit` redefined (from
    `20261117110000:3128`, 83 lines): accepts a `label_reference` line (beside `own_transfer_in`,
    `client_transfer_in`) and creates its payment as it does today (`bank_own_credit_release` row, payment, `cash_in`),
    the payment's note « Paiement d'un débiteur citant notre référence (vérifié par l'équipe) ». [check 2] Its payer:
    today `case v_kind when 'client_transfer_in' then 'Versement relayé par le client' else 'Versement relayé par le
    cabinet'` (l.3202-3203), which would name the servicer as the payer of a debtor's credit; for `label_reference`,
    « Versement relayé par le client » with no IBAN when the line's counterparty IBAN is a confirmed payout IBAN of a
    client (`private.registered_client_ibans`), else the line's own counterparty name and IBAN (as `resolve_duplicate`
    books a released debtor credit, `20261117090000:2274-2276`), so a later refund goes to the payer. [check 2] (gap 1
    (2)) The two statement guards refused it at `1440178`: **`private.bank_own_credit_release_guard`** (latest
    `20261111120000_identities_terms.sql:2497`: the release row's line must be `own_transfer_in` or
    `client_transfer_in`, as read or released, l.2514-2516) and **`private.payment_insert_guard`** (latest
    `20261111120000:2591`: a payment's line must be `debtor_credit` or `batch_unsplit`, or `own_transfer_in` /
    `client_transfer_in` with a release row, l.2604-2610). 7e-3 redefines both (**whole copies, 30 and 27 lines**;
    settings and triggers unchanged, each header naming its source line), each kind list gaining `label_reference`
    in the same position — for the payment guard only in the release branch (a `label_reference` line is a payment
    only with its `bank_own_credit_release` row; the ingest's own payment step, `n.kind in ('debtor_credit',
    'batch_unsplit')`, never makes one). Every exit deletes the line's `label_reference` review.
  - **`public.debit_queue`** redefined (7e-2; from `20261117110000:2323`, 188 lines): lists `label_reference` lines in
    « À classer » beside `own_transfer_in` and `client_transfer_in` (its l.≈ 76 kind list), with the candidate and its
    transfer (number, amount, run).
- **S23** (D10 of §1.3): no undo path. `public.assign_payment` and `public.resolve_duplicate` redefined (from
  `20261117090000:2097`, `:2212`) for their hint only: « … Il ne s'affecte à aucun dossier, et Collectoo ne le
  comptabilise pas comme le retour de ce virement (un paiement enregistré ne se défait pas) : prévenez le support. »;
  `forms.ts:664-669`, `matching.ts:286-287` alike. The P0 alert `own_transfer_payment` stays as the tripwire. pgTAP
  035:2861 and 036:1645 updated to the new hint (justified in the ADR). [check 1] S23's texts ship in 7e-1.

### 7.4 Web
« Virements », section « Approvisionnements du compte dédié »: the `TOP` orders (date, amount, reference, « commandé
automatiquement » or by whom, status), « Générer le fichier (compte propre) », « Télécharger », « Annuler le fichier »
(sheet: « Les approvisionnements non comptabilisés de ce fichier sont annulés ; Collectoo recommande ce qui reste dû
dans l'heure. Si la banque l'exécute quand même, la somme arrive sur le compte dédié : comptabilisez-la comme
approvisionnement (« Débits et retours ») ; elle revient au cabinet avec la prochaine quote-part. »).
« Contrôles » « Réapprovisionner » on `servicer_shortfall` opens that section. « Comptes bancaires »: « Périodes où le
cabinet devait de l'argent au compte dédié » (« Du 12/11/2026 14:37 au 13/11/2026 10:37 — jusqu'à 2 000,00 € »).
Texts: `servicer_shortfall` « … Collectoo commande un approvisionnement chaque heure (référence TOP…, page
Virements) : exécutez-le depuis le compte propre, à la main ou par le fichier. »; `top_up_pending` P0, [check 1] its
help (`debits.ts:1336-1339`) gains the exit (gap 12): « … Si son crédit est arrivé sans la référence TOP et a été
comptabilisé sans elle, rattachez-le à cet approvisionnement (« Rattacher à TOP… » sur la ligne) ou, s'il est déjà
comptabilisé, annulez cet approvisionnement (« Annuler ») : sinon Collectoo croit l'approvisionnement encore attendu
et commande trop peu. »; « Débits et retours », an `own_transfer_in` credit with no `TOP` id: action « Rattacher à
TOP… » (the open top-ups of the same amount; `book_top_up_credit`) beside « Comptabiliser comme approvisionnement »;
[check 1] (gap 5) a `label_reference` line in « À classer »: « Le libellé cite notre virement RMT… (reversement RV-…,
X €) : est-ce ce virement qui revient ? » — [check 2] in 7e-2 with no action and the line « La ligne reste en attente :
ni paiement ni retour tant qu'elle n'est pas classée. » (true of 7e-2: no command accepts the kind yet); 7e-3 replaces
that line with three actions — « Oui, c'est son retour » (« Comptabiliser… » prefilled
with the return of exactly X €; refusals `label_reference_transfer` « Seul le virement cité dans le libellé peut revenir
sur cette ligne. », `label_reference_amount` « Le montant n'est pas exactement celui du virement cité : ce n'est pas son
retour. Choisissez « Règlement du client » ou « Paiement d'un débiteur ». »), « Règlement du client » (the client payment
sheet with « Client qui rembourse » — `client_required` « Indiquez le client qui rembourse : le compte émetteur n'est
pas un compte de reversement confirmé. », `client_mismatch` « Ce crédit vient du compte de reversement confirmé d'un
autre client. »), « Paiement d'un débiteur » (`release_own_credit`; « Le crédit devient un paiement à affecter ; notre
référence citée dans le libellé est ignorée. »);
`top_up_account_missing` « Le cabinet doit de l'argent au compte dédié mais aucun compte propre n'est enregistré
(Paramètres › Facturation) : aucun approvisionnement ne peut être commandé. »; [critic] review texts
`top_up_cancelled_credit` and `label_reference` (7.2, 7.3). Refusals: `not_an_own_account` « Ce compte n'est pas un
compte propre actif du cabinet. », `not_eur` « Seuls les virements en euros sont pris en charge. », `nothing_to_file`
« Aucun approvisionnement à mettre dans un fichier. », `nothing_to_cancel` « Ce fichier n'a plus d'approvisionnement à
annuler. », [critic] `not_a_top_up_file` « Ce fichier n'est pas un fichier d'approvisionnement : utilisez l'annulation
des reversements. »
Screenshots: `m2c7-approvisionnements`, `m2c7-periodes-decouvert`, `m2c-virements` retaken.

### 7.5 Tests
**pgTAP `047_top_ups_and_bank_residues.test.sql`** (≈ 50): `top_up_needed` with an advance; with a sweep in a file
(advance + sweep); with a top-up ordered (the rest); with servicer money on 4679 larger than the advance (none); the
hourly order twice → one order; no own account → alert; shortfall period opened at the advance, closed by the top-up's
booking (`servicer_top_up` from its credit); the top-up file (items, no cash check, download, superseded); [critic]
M7-MONEY-4: a filed (`in_file`) top-up's credit booked by the funds pass and by the SQL re-check, the transfer
`booked`, the shortfall period closed, `top_up_needed` back to 0; cancelled after download with the switch off, then its
late credit → review `top_up_cancelled_credit`, booked by ops without transfer, swept; an ops booking with no `TOP` id
picking the open top-up → it is `booked`; [critic] F13: `cancel_top_up_file` on a downloaded payout file with the switch
off → `not_a_top_up_file`, nothing changed; on a mixed or unknown file → refused; [critic] M7-MONEY-6: S24 ingest (a
label carrying a real id of the account → stored in `reference_from_label`, the line in review, never booked by the
job; a look-alike id → ignored); a client's partial repayment from an unregistered IBAN quoting an RMT → review, no
`payout_returned`, no fee; a coded fee labelled with an RMT → booked as a fee; ops confirming a return of the
transfer's exact amount → booked; of a smaller amount → refused; the S23 hint. [critic] F8 two sessions: org B's remit
lock held, the hourly job for org A completes and A's `reverse_allocation` completes within its 2 s; B skipped, then
ordered at the next run.
[check 1] [check 2] The file splits with the PRs: **047a** (7e-1: top-ups, the file, the guards, S23), **047b** (7e-2:
the kind held and reviewed) and **047c** (7e-3: the three exits). Added:
- **Gap 4 (047a).** Inserting an own-account top-up file is accepted (`transfer_file_guard`); a downloaded top-up file
  is cancelled with the switch **off** (`cancel_top_up_file`: its top-ups `in_file → cancelled`, the file superseded),
  then its late credit → `top_up_cancelled_credit`, booked without transfer; with the switch off, under the same calls,
  a downloaded **payout** file stays refused by both guards (raw `update … set status = 'superseded'` on the file and
  `… set status = 'cancelled'` on its transfer, each in a subtransaction: `check_violation` with the fail-closed
  message); an own-account file item naming a payout, and a `client_funds` file item naming a top-up → refused by the
  new item guard; 033 unchanged and green.
- **Gap 12 (047a).** A top-up credit with no `TOP` id booked without transfer (`link_debit 'own_credit'`) → the TOP
  stays `ordered`, `top_up_needed` = the true need − T (under-ordered); `cancel_top_up` → `top_up_needed` correct
  again; the same with the TOP `in_file` of an own-account file → `cancel_top_up` accepted; `book_top_up_credit` on
  another such credit picking an `in_file` TOP → booked, the TOP `booked`; its five refusals; replay.
- **Gap 5 (047b, 7e-2).** Import of a CSV credit from an unregistered IBAN whose label cites a real RMT of the
  account → kind `label_reference`, `reference_from_label` set, **no `payment` row and no `cash_in` posting** for it;
  the debit job leaves it in review `label_reference` (no booking); a credit from Martin's confirmed IBAN citing it →
  `label_reference` too; a look-alike id or an id of another account → `debtor_credit` (a payment, as today) with no
  candidate; the re-check refuses a top-up, a fee and a loss on such a line; `debit_queue` lists it; a held duplicate
  of such a line released → `held_line_kind` reads `label_reference`. [check 2] (gap 1 (3)) **The job reaches it**:
  `bank_booking_candidates` returns the imported line (kind `label_reference`, no transfer) and, after
  `resolve_duplicate` releases a held one as `label_reference` (no payment booked), that line too; the real debit job
  (`apply_bank_bookings`) then writes one `bank_debit_review` row of reason `label_reference` for each, and none for a
  `debtor_credit` line (unchanged: the candidates still never return one); a line already released, linked or booked
  is not returned; in 7e-2 every command that could act on the line refuses it (`release_own_credit`
  `not_own_credit`, `book_transfer_line`'s check, 7c-1's `book_client_payment_line` `not_a_client_credit`), so it
  waits in review.
- **[check 2] Gap 1 (047c, 7e-3), the three exits end to end.** Exit (a): `book_transfer_line` with the return of
  exactly the transfer's amount → `payout_returned` booked (the redefined `bank_line_booking_guard` admits it), the
  run's account `returned`, +N re-queued; a smaller amount or a fee part → `label_reference_amount`; another transfer
  → `label_reference_transfer`; the same on a held duplicate released as `label_reference` → booked; a sweep (`SWP`)
  candidate → `sweep_returned` booked. Exit (b): `book_client_payment_line` with `p_client_organization_id` →
  `client_payment_dedicated` posted and its `client_payment` booking admitted, `client_required` without it,
  `client_mismatch` with another client than the IBAN's. Exit (c): `release_own_credit` → a `bank_own_credit_release`
  row and a payment of the line (both statement guards admit them), its `cash_in`; its payer the line's counterparty
  (unregistered IBAN), or « Versement relayé par le client » with no IBAN (a client's confirmed IBAN). After each exit
  the review is gone and the other two exits are refused (`line_booked`, `already_linked`, `already_booked`).
  **The guards still refuse** (each a raw insert in a subtransaction, service role, the entry posted to match):
  `bank_line_booking_guard` — a `payout_returned` booking on a `label_reference` line naming a transfer other than
  its `reference_from_label` (`check_violation`), an `unplanned_payout_returned` with no transfer on such a line, a
  `fee`, a `top_up` and a `loss` on such a line, a `client_payment` on a `debtor_credit` line;
  `bank_own_credit_release_guard` — a release row on a `debtor_credit` line and on a debit; `payment_insert_guard` — a
  `payment` on a `label_reference` line with no release row. **The return counts** (gap 1 (4)): after exit (a),
  `remittance_chain_paid(run.transfer_id)` gives `paid_on` null and `returned` true, `remittance_run_paid_on(run)`
  null, `entry_remitted(E).paid_on` null for a collection E of that run whose reversal was covered (7a), and
  `request_advance_repayment` for that advance → `payout_not_received`; the letter payload and the client space say
  « revenu, à verser de nouveau »; then RV-2 pays the re-queued +N → `paid_on` = RV-2's debit date (rule 3 of
  §3.2.1) and the request passes; before exit (a) — the line still in review — `paid_on` stays the execution date
  (an unbooked label reference never counts, D14).
**Mutants ([check 2]).** `bank_booking_candidates` without the new kind in either branch → 047b « the job reaches it »
(imported, released); the guard's return arms admitting `label_reference` without the transfer-reference match → 047c
« another transfer » raw insert; the arm admitting it with no transfer → the `unplanned_payout_returned` raw insert;
the `client_payment` arm unchanged → exit (b) (refused by the guard); either release guard unchanged → exit (c); the
payment guard admitting `label_reference` without the release row → the raw `payment` insert;
`remittance_chain_events` without the label branch → « the return counts » (`paid_on` = execution date,
`payout_not_received` not raised); the branch counting unbooked lines → « before exit (a) »; `release_own_credit`'s
payer left as « relayé par le cabinet » → exit (c)'s payer case.
**Mutants (gaps).** Either guard's exemption without the own-account condition → killed by 033's fail-closed cases
(payout file superseded, payout cancelled out of a downloaded file) and gap 4's payout-file case; the item guard
removed → gap 4's mixed-item cases; `book_top_up_credit` accepting a cancelled TOP → gap 12 refusal; the ingest's
kind override removed → gap 5 « no payment row »; the candidate existence check removed → look-alike case; the exact
amount rule removed → `label_reference_amount` case; `book_client_payment_line` ignoring `p_client_organization_id`
for a client IBAN → `client_mismatch` case.
**Worker**: parser S24 cases (CSV presets) and Python/SQL parity on generated labels (Hypothesis); [critic]
`decide_line` parity and Hypothesis on `transfer_status` ∈ {`ordered`, `in_file`, `cancelled`} for top-up credits and on
`reference_from_label`; [check 1] `refine_kind` / `bank_line_refined_kind` parity with the ninth argument (every base
kind × direction × candidate present or not); [check 2] `decide_line` on a `label_reference` line → review
`label_reference` whatever its other facts (unit, and Hypothesis over the generated `FundsLine` facts); an integration
test importing the CSV of gap 5 through the real import job and the debit job ([check 2] the review row written by the
job itself, not planted); the job writing an own-account file (golden pain.001 bytes, XSD xfail as today); the `top_ups`
job (per servicer, skip on lock timeout). **vitest**, **E2E** (approvisionnements: generate, download, cancel).
**Mutants**: sweeps term dropped → sweep case; top-ups ordered not subtracted → twice case; cash check kept for own
files → generation case; S24 existence check dropped → look-alike case; [critic] `ordered` only kept for top-up
credits → filed-top-up case (both twins); the label reference written to `original_end_to_end_id` → partial repayment
case; the file kind check removed → F13 case; one transaction for all servicers → F8 case.

### 7.6 Docs (7e)
ADR-0014 « M2c-7e » ([check 2] the five guards and readers the kind needed, and why 7e is three PRs); COMPLIANCE CPCE-02 (top-ups automatic), OQ-35 (top-ups and client repayments landing on the
dedicated account; R124-7 1°), OQ-38 (durations logged), OQ-84 (e)/(h) (S24 rule: proposed, never booked alone; S23
tripwire); benchmarks; PROGRESS.

---

## 8. 7f — Property machine, 50k close-out, hardening, docs close-out

Branch `m2c7f`. Migration `<timestamp at PR open>_close_out_hardening.sql` ([critic] F12).

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
  note; a client event (proceeding opened; mandate ended then payee confirmed; [critic] a seizure and its release; an
  event recorded between approval and debit); [critic] a collection and its reversal both pending before a prepare (a
  same-run pair); an overpayment and its refund; a repayment request and its withdrawal; [check 1] a CSV credit citing
  our reference in its label and one of its three exits; a filed top-up booked without its `TOP`, then cancelled;
  [check 2] the oracle reads « the client was paid » through `run_settled_on` (a return through exit (a) counts as a
  return), and a withheld settlement's next run is due at the next hourly schedule.
  Switch on adds: cancel a payout
  after download (two people, evidence statements), the bank executes it late (unplanned, P), late predecessor, its
  return ([check 2] `paid_on` followed through its `payout_returned` booking).
- **Invariants after every step** (the nightly checks run, zero violations): I2′/I12 (`fund_mirror`,
  `own_fund_identity`), I8′ (`client_money_identity`), I13 (`client_payable_debit`: 4670 never in debit), I14/I15
  (`remittance_completeness`, `remittance_item_twice`), I16, I18 (`settlement_ledger` and `advance_ledger`), I19
  (`bank_cash_identity`), I20, I23 (`remitted_reversal_uncovered`). [critic] M7-MONEY-1: the oracle computes what it
  expects from **its own model** of runs, lines, payouts and reversals — never from `remitted_cover_target` or any SQL
  helper it is checking. Oracle checks:
  - **each client's money is only theirs**: for each client, what it received (payouts debited − returned) = Σ its
    items remitted − commission set off − advances recovered + refunds paid with payouts, and its 4670 = −(its pending
    items + its runs in flight);
  - **expected advances**: the model lists, for each reversal R of E, E's remitted state (its line in a booked run with
    R not a line of that run — the model's own pair rule —, or the attributions of an unplanned payout) and expects
    exactly that cover (amount, date ≥ the payout's), and none for a same-run pair;
  - **no remitted reversal nets**: after any reversal of a remitted item, the client's queue total is unchanged by the
    pair (R and its advance);
  - **every advance** is recovered (settled), open and alerted after 30 days (`advance_open` with `p_today` + 31), or
    written off; never settled beyond its amount; never both requested and taken by a run;
  - [critic] M7-MONEY-11 VAT: 44574 = Σ pending VAT of open documents; 44571 = Σ VAT moved by settlements and client
    payments − the VAT credit notes take back from VAT already due (the design's v₂, e.g. §7.2 C4 posts +6 000 on 44571),
    per document — the draft's « 44571 moved only by settlements » contradicted the design;
  - [critic] M7-MONEY-10: every client credit owed back is refunded or open and alerted; no money received is off the
    ledger (Σ own-account receipts in the model = the 5122 postings);
  - [critic] M7-MONEY-5: no settlement posted on or after a bar's effective date takes a barred document unless
    `set_off_after_bar` lists it.
- **At quiescence** (every file executed and booked, every top-up credited, the last sweep debited): 5120 = the bank's
  closing balance; −Σ4679 = settled commission (and client payments on the dedicated account) not yet swept = 0 after
  the last sweep.
- [critic] F15 Settings and budget. The db job's timeout is 30 min and a PR run bills about 18 min (PROGRESS, founder
  2026-11-17 Actions-minutes decision); a step through real jobs plus the nightly costs about 0.5–1.5 s. So: in the PR
  `db` job, 2 classes × 8 examples × 20 steps, with cheap per-step invariant SQL (I13, I14, I18, I23 by key over the
  rows the step touched) and the full nightly at the end of each example — a budget of **≤ 6 min**, measured in 7f
  and written in `docs/benchmarks/remittances.md`; the PR fails if the measured time exceeds it by 25 %. 25 × 40 and
  200 × 60 run in the dispatch/main volume job. The seed printed; failing examples kept in the Hypothesis database for
  the PR. The switch-on class asserts the switch is off before, flips it in a fixture with `try/finally`, asserts it off
  at the end (as `switch-on.spec.ts` does), and runs serially, last, so a crashed example never leaves it on for
  another integration file.

### 8.3 The 50k close-out volume run (design §19; CLAUDE.md scale rule)
`worker/tests/test_close_out_scale_integration.py`, in CI's `scale-payouts` job (founder Q13; `scale` is at 27.6 of 30
min), stale statistics (reset, then import, as the 6a/6b files). Bounds (each asserted, then measured in
`docs/benchmarks/remittances.md`):

| Step | Volume | Bound |
|---|---|---|
| 1. covers at the reversal | a statement of 1,000 returns (2 %) of payments of a booked 50k-line run, one debit-job chunk | chunk < 60 s; the cover statement (`cover_remitted_reversals`, 1,000 reversals) < 2 s; reads keyed (`pg_stat_xact` deltas ≤ 20 per reversal) |
| 2. deferred LG009 checks | the 1,000 reversals at commit | < 0.5 s |
| 3. covers at the booking | a 50k-line run with 1,000 lines reversed in flight, its payout booked | `cover_booked_run_reversals` < 3 s |
| 4. nightly [critic] F9, F17 | 10 booked 50k-line runs (history) + 1,000 reversals of the day + 1,000 covers | `run_advance_checks` delta pass < 0.5 s and its reads independent of the number of booked runs (`pg_stat_xact` deltas with 1 and with 10 booked runs within 10 %); the `p_full` pass < 8 s; the whole nightly's increase measured in the same job and order before and after 7a's checks ≤ 2 s (not « today's 5–6 s », which is the `scale` job's; `scale-payouts` already runs 13.4 s with held chains, benchmarks l.1493–1496) |
| 5. claw-back run [critic] F10 | 50k new collections + 1,000 open advances under claw-back, of which 200 `payout_overrun` advances on 50k-line runs | prepare ≤ 10.6 s × 1.1, approval ≤ 6.1 s × 1.1 (M2c-4's measures), its settlement at the debit < 2 s (1,000 settlement rows); the « Avances » page < 300 ms |
| 6. client payments | 1,000 `record_client_payment` calls | each < 200 ms |
| 7. top-ups [critic] F8 | the `top_ups` job over 100 servicers, one transaction each | < 2 s in all; with one servicer's remit lock held, the others complete and it is skipped |
| [critic] F17 8. the existing funds pass after 7a | the 5,000-payout funds-pass chunk of `scale-payouts` (24.0 s today) with the at-booking cover and the per-row run trigger | ≤ 24 s × 1.1; if not, the run trigger becomes a statement-level trigger on a transition table (one check per statement) |

CI: the branch of each slice touching a timed path dispatches CI (`workflow_dispatch`) and merges only once `scale` and
`scale-payouts` are green; a red volume run on main is fixed before the next slice.

### 8.4 Docs close-out (design §21 M2c-7 docs list)
- **COMPLIANCE** (§11): CPCE-02/03/07/08 final; new MAND-01/02/03, FAC-06 (Ops: 289 VII 1° documented controls), PROC-01;
  OQ-25/34/35/36/37/38/41/45/82/84/85 updated; OQ-88…99 added; the seizure Ops row [critic].
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
on the old body). Mutants: the machine must kill, at least, the money mutants of §9 replayed on the final code (cover
off, at-booking cover off, claw-back off, VAT pro rata off, payee kind ignored, top-up sweeps term off, LG009 trigger
dropped, and [critic] the same-run exclusion dropped, the in-flight refusal dropped, the advance item's mandate dropped,
the requested flag ignored, the surplus refused, the debit-time re-read removed; [check 1] the LG003 exception
widened to any `return:barred:%` key, the 4670 trigger's `settlement_withheld` branch removed, the shapes' 419 term
dropped, the import's `label_reference` override removed, `paid_on` read from `remittance_run_paid_on` alone;
[check 2] the chain events' label branch removed, rule 3 of `run_settled_on` read from `bank_transfer.return_entry_id`).

### 8.6 The go-live gate after M2c-7
Merging 7f lifts the design's code gate (« no real remittance before M2c-7 »). PROGRESS and ROADMAP record what remains
before a first real remittance, none of it code: the R124-2 declaration to the procureur and the dedicated account
(CPCE-01/02, Ops; R124-7 1°); counsel's answer to OQ-45 (CMF L314-1, L521-2); the bank's guide and a real statement with
our debits (founder #15; OQ-79/80/81/83/84); the founder's answer on the switch (6b-3 Q1); M3 re-runs before go-live
(design R7; m3 §10 #9), and M3c-2's restatement cover (§1.2). [critic] L15, two invoice obligations that start with the
first real invoice: **FAC-06**'s written procedure under CGI 289 VII 1° (who controls what, when, how, from the
triggering event to the invoice, credit notes and the settlements of 7b/7c — BOFiP BOI-TVA-DECLA-30-20-30-20 §190:
built « au moment de la mise en place de la piste d'audit »), written by Ops with the accountant; and **OQ-44**'s answer
(the servicer's category for e-invoicing: PDF invoices remain lawful for its issuer only within the dates OQ-44 records
— accountant). Both are recorded in PROGRESS and ROADMAP as gates before the first real remittance; the founder's
answers to Q17–Q21 ([check 1] Q21 added) and the counsel questions OQ-92/93/94/97 that 7d's defaults wait on are
listed beside them.

---

## 9. Money rules and the test that pins each

| # | Rule | Pinned by |
|---|---|---|
| 1 | A reversal of a remitted item is advanced in full, the same transaction, dated no earlier than the payout it covers [critic] | 043 cases 1, 6; integration §7 12/11 |
| 2 | A reversal of an item in a run in flight is advanced when that run is booked, at the debit date, before any overrun cover | 043 cases 4, 5d; 037 `d_f5` rework |
| 2a | [critic] A collection undone in its own run (a same-run pair) is never advanced, LG009 silent | 043 cases 5a–5c, 10; worker test l.261 unchanged; machine |
| 3 | No reversal of a remitted item ever nets against the client's other collections | machine oracle « queue unchanged by the pair »; 043 case 1 |
| 4 | A forgotten cover fails at commit (LG009), and so does a cover reversed outside the release [critic]; the nightly finds any gap | 043 cases 9, 10, 14, 18 |
| 5 | An item an unplanned payout paid is covered for that part when reversed; the cover goes when that payout comes back; never when it was partly recovered, nor while a run is taking it back [critic] | 043 cases 5e, 11; 044 in-flight |
| 6 | 4670[c] never in debit (I13) | 017 (raw reversal), machine |
| 7 | Advances are clawed back only under the mandate's clause, only from that mandate's money (their own items counted in it [critic]), invoices first | 044; Hypothesis `test_settlement` through `run._plan`; §7.2 integration |
| 8 | A null-mandate advance is never clawed back | 044 `advance_mandate`; Hypothesis |
| 9 | An advance settled or requested [critic] since the prepare sends the run back | 044 `documents_changed`; 045 (a) |
| 10 | Σ open advances = 4112[c] (I18) | 043 case 14; machine |
| 11 | A write-off is admin-only, ≤ open, never reversed, settles the advance; a later repayment is booked as a recovery [critic] | 044; 045 (b) |
| 12 | A client payment settles what the client designated (with its evidence), else due invoices → advances → other invoices; VAT moves pro rata; what exceeds the open is a credit owed back [critic] | 045; parity Hypothesis |
| 13 | Nothing in flight is settled twice; an advance is never both requested and clawed back [critic] | 045 `in_flight`, (a); 044 write-off `in_flight` |
| 14 | A client's credit on the dedicated account becomes the servicer's share and is swept | 045; machine quiescence |
| 15 | A refund owed (credit note or client credit [critic]) is paid once, from the own account, on proof | 045 |
| 16 | A payout after death, tutelle, curatelle, mandate end or under a seizure goes only to a payee satisfying **every** event's requirement [critic], confirmed after each by a second admin, with its authority document; under a tutelle or curatelle, an account in the client's name [critic] | 046 |
| 17 | Nothing is set off in liquidation, after a mandate end or under a seizure; no advance is taken or requested while a proceeding stands; pre-opening claims — the run's own new invoice included — are never set off; a bar recorded before the debit withholds the barred set-off, one recorded after is alerted [critic] | 046; worker unit `_plan` |
| 18 | Payments after the end are held and forwarded without commission | 046 |
| 19 | Top-up = max(0, Σ4679 + sweeps in flight − top-ups ordered or filed), ordered once per servicer per hour in its own transaction; a filed top-up's credit books [critic] | 047; 7f `servicer_shortfall` |
| 20 | 5120 = the bank at quiescence; −Σ4679 = the share not yet swept | machine |
| 21 | Amounts are integers end to end; letters and statements print only ledger amounts, recorded dates [critic] and no RMT/SWP/TOP id [critic] | goldens (letter, statement fr-4); vitest amounts as text |
| 22 | [critic] A reference read from a CSV label never books a line by itself; [check 1] such a credit is never a payment or a return until ops choose an exit, and a return only for exactly the transfer's amount; [check 2] the job sends it to review, every guard admits only its exits, and a return so booked counts as the transfer's return everywhere (`paid_on`, texts, requests) | 047b gap 5; 047c gap 1; parser parity |
| 23 | [check 1] A barred set-off exists in the ledger only with its reversal, in the same transaction; no other settlement, commission document or write-off is ever reversed (LG003) | 046b gap 1 (v), (vi) |
| 24 | [check 1] A client's payment never pays a document the client may not pay (pre-opening; an advance while a proceeding stands) unless it designates it, and then the money is held for the procedure | 045 (l); 046b gap 11 |
| 25 | [check 1] Money owed back and recoveries balance: Σ open client credits = −Σ419, Σ recoveries of written-off advances = −Σ7714 | 045 (j); nightly `client_credit_ledger`, `written_off_recovery_ledger` |
| 26 | [check 1] Every text says « versé » only for a run whose payout was paid and stayed paid (or a later run that paid it); an N = 0 run is « réglé par compensation » or « compris … montant net nul » | 043 case 17 ([check 2] (d): a late predecessor's return); 045b (m); [check 2] 047c « the return counts »; goldens |
| 27 | [check 2] Money withheld at the debit goes back to the client in a run prepared within the hour, under its own trigger | 046b gap 3 of check 2; worker `_schedule_trigger` unit |

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
4. **Règlement du client.** [critic] a : il règle ce qu'il désigne (pièce jointe) ; sinon factures échues, puis
   avances, puis autres factures ; le surplus est inscrit en trop-perçu à lui rembourser ; [check 1] client en
   procédure : jamais une créance d'avant le jugement ni une avance, la somme est mise de côté pour la procédure.
   b : avances d'abord.
5. **Avance passée en perte.** a : administrateur seulement, motif et pièce ; Collectoo cesse de la réclamer ; rien
   n'est envoyé au client (ce n'est pas une remise de dette) ; un remboursement ultérieur est encaissé en recette.
   b : une lettre au client (remise : avocat).
6. **Demande de remboursement d'avance.** [critic] a : lettre factuelle (« versées au-delà de ce qui vous revenait »),
   sans article de loi, sans intérêts ni pénalités ni date limite, à payer sur le compte du cabinet ; jamais pour une
   avance que la clause de reprise récupère ; alerte après 30 jours. b : texte validé d'abord par l'avocat (7c attend).
7. **Remboursement d'un avoir ou d'un trop-perçu hors reversement.** a : l'équipe vire depuis le compte propre puis
   l'enregistre avec la preuve. b : dans le fichier d'approvisionnement, si votre banque l'accepte.
8. **Bénéficiaire après un événement.** [critic] a : décès → compte du notaire (ou désigné par tous les héritiers),
   avec la pièce ; tutelle ou curatelle → compte au nom du client géré par le tuteur ou curateur, jugement joint (art.
   427 C. civ.) ; fin de mandat → compte du client reconfirmé ; toujours par un second administrateur, et chaque
   événement doit être satisfait ; [check 1] courriers : au tuteur (tutelle) ; au client avec copie au curateur
   (curatelle). b : autre règle (avocat).
9. **Après la fin du mandat.** a : plus aucune compensation ni reprise ; factures dues, avances réclamées par lettre.
   b : les clauses continuent pour ce qui est né avant la fin (avocat).
10. **Paiements reçus après la fin du mandat.** a : mis en attente ; l'équipe les reverse sans commission au client (ou à
    son bénéficiaire) ou les restitue au payeur. b : restitution au payeur par défaut.
11. **Client en liquidation.** a : rien n'est compensé, avant ou après le jugement ; reversement brut au liquidateur ;
    factures et avances déclarées. b : compenser ce qui est né après le jugement si le liquidateur poursuit le mandat.
12. **Saisie entre nos mains des sommes dues à un client.** [critic] a : un événement « saisie » bloque reversements et
    compensations (même à 0 €) jusqu'à la mainlevée enregistrée ; [check 2] chaque mainlevée désigne la saisie qu'elle
    lève (deux saisies : il en faut deux) ; déclaration à l'huissier et paiement par l'équipe et l'avocat. b : rien de
    construit ; l'équipe retient à la main.
13. **Tests de volume M2c-7.** a : dans le job « scale-payouts » (environ 8 min de plus à chaque push sur main). b : un
    job à part.
14. **Fichier d'approvisionnement du compte propre.** a : le construire (7e). b : ne pas le construire (votre banque
    n'accepte pas de fichier sur ce compte) ; l'équipe saisit le virement TOP à la main.
15. **Notre référence seulement dans le libellé d'un relevé CSV.** [critic] a : proposée à l'équipe, qui confirme ;
    jamais comptabilisée seule ; [check 1] la ligne est mise de côté (ni paiement ni retour) jusqu'au choix : retour
    de ce virement (montant exact), règlement du client, ou paiement d'un débiteur ; [check 2] un retour ainsi
    confirmé compte partout comme le retour du virement (plus de « versé » ; à verser de nouveau). b : ignorée ;
    attendre la colonne de la banque.
16. **Production.** a : aucun reversement réel n'a été émis depuis la production (les paiements faits de nos virements
    revenus n'existent donc pas). b : il y en a eu : dites-le, il faut alors un chemin pour les défaire.
17. [critic] **Reversement revenu, puis un de ses encaissements annulé.** a : avance du cabinet comme pour tout
    encaissement reversé ; reprise par la clause, sinon demande une fois la somme versée de nouveau. b : imputer
    l'annulation sur la somme revenue (pas d'avance ; avis de l'avocat, OQ-97). [check 1] Même règle quand c'est un
    virement hors reversement (exécuté tard) qui a payé l'encaissement puis est revenu.
18. [critic] **Avances d'un client en procédure collective.** a : ni reprises ni demandées tant que la procédure court ;
    déclarées au mandataire. b : reprendre celles nées après le jugement (avocat).
19. [critic] **Jugement, décès ou saisie entre la validation et le débit.** a : la compensation prévue est retenue au
    débit et rendue au client au reversement suivant ; [check 2] ce reversement est préparé dans l'heure, comme après
    un virement revenu ; les factures restent ouvertes (à déclarer ou dues). b : la compensation est maintenue (décidée
    avant ; avocat).
20. [critic] **Demande de remboursement sans réponse.** a : pas d'expiration ; l'équipe peut la retirer, la reprise
    reprend alors. b : retrait automatique après 60 jours.
21. [check 1] **Compte d'un majeur protégé dont le RIB n'a pas exactement le nom du client** (« M. », ordre des
    noms…). a : accepté seulement avec une explication écrite, vérifiée par le second administrateur ; jamais le
    compte du tuteur ou du curateur. b : refusé tant que le nom n'est pas identique.

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
  allocation gate (R124-3 « pouvoir de recevoir pour son compte »); [critic] L20 a note for M4: `public.mandate` has no
  end state, so the row's « guardrail blocks sends when the mandate is expired/revoked » must read
  `client_status_event` (`private.client_end_event`).
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
  majeurs ou la déconfiture »); notification date (2006: « à compter du jour où elle a été notifiée à celui-ci »; 2007:
  « en notifiant au mandant sa renonciation »); « ce qu'il a fait dans cette ignorance est valide » (2008); good-faith
  third parties (2009); proceedings excepted (L622-13 I, L641-11-1 I). [critic] L2, L12: the payee and the recipient
  after a protection measure — C. civ. 427 al. 5 (« Les opérations bancaires d'encaissement, de paiement et de gestion
  patrimoniale effectuées au nom et pour le compte de la personne protégée sont réalisées exclusivement au moyen des
  comptes ouverts au nom de celle-ci ») and [check 1] (read 2026-11-21, versions in force since 2009-01-01) 473 al. 1
  (« Sous réserve des cas où la loi ou l'usage autorise la personne en tutelle à agir elle-même, le tuteur la
  représente dans tous les actes de la vie civile. »), 440 al. 1 (curatelle: a person who, « sans être hors d'état
  d'agir elle-même, a besoin … d'être assistée ou contrôlée d'une manière continue dans les actes importants de la vie
  civile »), 467 al. 3 (« A peine de nullité, toute signification faite à cette dernière l'est également au
  curateur. ») and 472 al. 1 (curatelle renforcée: « le curateur perçoit seul les revenus de la personne en curatelle
  sur un compte ouvert au nom de cette dernière »). Hence: after a tutelle letters go to the tutor; after a curatelle
  to the client, with a copy to the curator — a rule of the servicer by analogy with 467 al. 3, which governs
  significations, not letters (OQ-94); payouts in either case to an account in the client's name. Enforcement: 7d-1.
- **MAND-03** (C. civ. 1999–2001): the mandant's obligations (advances, losses, interest) — the servicer's rights, and
  which the product does not use (no interest, losses borne by the servicer: founder #8). Worded as waivers, never as law.
- **PROC-01** (client in a collective proceeding): [critic] L4, L18 — L622-7 I al. 1 in full (version 2021-10-01, read
  2026-11-21): « Le jugement ouvrant la procédure emporte, de plein droit, interdiction de payer toute créance née
  antérieurement au jugement d'ouverture, à l'exception du paiement par compensation de créances connexes. Il emporte
  également, de plein droit, interdiction de payer toute créance née après le jugement d'ouverture, non mentionnée au I
  de l'article L. 622-17. »; III (« Tout acte ou tout paiement passé en violation des dispositions du présent article est
  annulé à la demande de tout intéressé ou du ministère public, présentée dans un délai de trois ans … »); L622-17 I
  (« Les créances nées régulièrement après le jugement d'ouverture pour les besoins du déroulement de la procédure ou de
  la période d'observation, ou en contrepartie d'une prestation fournie au débiteur pendant cette période, sont payées à
  leur échéance. ») and IV (privilege lost unless « portées à la connaissance de l'administrateur … dans le délai d'un an
  à compter de la fin de la période d'observation »); L622-24 al. 1 and al. 6 (« Les créances nées régulièrement après le
  jugement d'ouverture, autres que celles mentionnées au I de l'article L. 622-17 sont soumises aux dispositions du
  présent article. Les délais courent à compter de la date d'exigibilité de la créance. ») and al. 4 (« Celles dont le
  montant n'est pas encore définitivement fixé sont déclarées sur la base d'une évaluation »); R622-24 al. 1 verbatim
  (version 2014-07-02): « Le délai de déclaration fixé en application de l'article L. 622-26 est de deux mois à compter de
  la publication du jugement d'ouverture au Bulletin officiel des annonces civiles et commerciales. »; L622-26; L641-3;
  L641-9 I (« à partir de sa date … exercés … par le liquidateur »); L641-13 I and III (post-opening claims in
  liquidation; to read verbatim when the row is written). Enforcement: 7d (set-off rules incl. advances and the run's
  own invoice, the debit-time withholding, `claims_to_declare` per document, `post_opening_unpaid`, payees,
  `payout_after_liquidation` until disposition); Ops: the declaration itself.
- **[critic] L14 Ops — seizure served on the servicer as tiers saisi**: CPCE L211-2 al. 1 (read 2026-11-21): « L'acte
  de saisie emporte, à concurrence des sommes pour lesquelles elle est pratiquée, attribution immédiate au profit du
  saisissant de la créance saisie, disponible entre les mains du tiers ainsi que de tous ses accessoires. Il rend le
  tiers personnellement débiteur des causes de la saisie dans la limite de son obligation. »; C. civ. 1347-7 (« La
  compensation ne préjudicie pas aux droits acquis par des tiers. »); L211-3, R211-4, R211-5 (the tiers saisi's
  declaration and the sanction; per the legal inventory, to quote verbatim when the row is written). Enforcement: 7d
  event `seizure` (payouts and set-off blocked whatever N, P0 alert); Ops: the declaration to the bailiff and the
  payment of the causes, with counsel.
- **FAC-06** (Ops; CGI 289 V and VII 1°, BOFiP BOI-TVA-DECLA-30-20-30-20 §90, §180, §190): « des contrôles documentés et
  permanents … une piste d'audit fiable »; the written procedure (who controls, when, how) from the triggering event to
  the invoice, including credit notes and the settlements of 7b/7c; kept and updated « à chaque changement ».
  [critic] L15: a go-live gate (§8.6), with OQ-44.
- **OQ-88** (accountant): an advance passed as a loss (6780): irrecoverable debt or abandonment for the servicer's
  taxable result; supporting document (C. com. R123-174 al. 2); [critic] M7-MONEY-10 the account of a later recovery
  (default `written_off_recovered`, PCG 7714 proposed).
- **OQ-89** (counsel, accountant): imputation of a client payment. [critic] L16: C. civ. 1342-10 al. 1 (« Le débiteur
  de plusieurs dettes peut indiquer, lorsqu'il paie, celle qu'il entend acquitter. ») — the client designates, with
  evidence kept; al. 2 without designation (« d'abord sur les dettes échues ; parmi celles-ci, sur les dettes que le
  débiteur avait le plus d'intérêt d'acquitter. A égalité d'intérêt, l'imputation se fait sur la plus ancienne ; toutes
  choses égales, elle se fait proportionnellement. »); is an advance « échue » before a request? 1347-4. Default Q4.
- **OQ-90** (accountant): the proof of a payment to, or a refund from, the own account; the VAT exigibility date of a
  client payment (CGI 269 2 c, the value date by default).
- **OQ-91** (counsel): a seizure served on the servicer as tiers saisi (CPCE L211-2, L211-3; C. civ. 1347-7, 1348-1
  al. 3). Default Q12 ([critic] now the `seizure` event).
- **OQ-92** (counsel): when the commission and the advance are « nées » for L622-7 I (encaissement, period end, issue,
  advance); whether set-off of post-opening commission needs L622-17 I / L641-13 I and the liquidator's decision;
  [critic] L4 whether an advance's repayment is ever an L622-17 I claim (default: no — not taken, not requested,
  declared from its exigibility); L8 declaring future advances « sur la base d'une évaluation » (L622-24 al. 4) and the
  L622-17 IV / L641-13 III information deadlines (not computed: the end of the observation period and the liquidation's
  publication are not modelled); L1 the wording of a pre-opening invoice's payment line; M7-MONEY-5 whether a set-off
  approved before the judgment and posted after it is a pre-opening set-off (default: withheld); L21 a client in a
  proceeding that pays a pre-opening invoice (default: held as a credit for the procedure). Default: the earliest date;
  nothing set off in liquidation.
- **OQ-93** (counsel): after the end of the mandate — to whom the account is rendered (heirs, notary, tutor,
  liquidator); payments received afterwards forwarded or restored (2005, 1342-2 al. 2, 1993); consignation of money with
  no payee (1345-1); the knowledge date (2008). [critic] L10: after a death, the heirs' shares — C. civ. 1309 al. 1–2
  (« La division a lieu également entre leurs successeurs … Chacun des créanciers n'a droit qu'à sa part de la créance
  commune ») — default: the notary's account, or one designated by every heir, with the evidence of quality. Default
  Q10.
- **OQ-94** (counsel): curatelle, habilitation familiale, sauvegarde de justice (not named by 2003). Default: a payout
  hold by our rule; [critic] L2 payee: an account in the client's name (C. civ. 427 al. 5). [check 1] Recipient: under
  a curatelle the client acts itself with the curator's assistance (C. civ. 440 al. 1); our letters and statements go
  to the client with a copy to the curator, by analogy with 467 al. 3 (« A peine de nullité, toute signification faite
  à cette dernière l'est également au curateur »), which governs significations. Is the copy enough, and is a
  repayment request or a statement ever to be served formally? A RIB whose holder name differs from the client's is
  accepted only with an explanation checked by a second admin (Q21): is that enough evidence that the account is
  « ouvert au nom » of the protected person (427 al. 5)?
- **OQ-95** (counsel): the repayment request's basis and wording (1999 or 1302-1; 1302-3 al. 2; 1352-7; 2001); whether a
  formal notice is useful. Default Q6 ([critic] L6: a factual letter that takes no side).
- **OQ-96** (accountant): does the documented procedure of 289 VII 1° also cover the settlements (compensations, client
  payments and refunds) that feed CGI 290 A's payment data?
- **[critic] OQ-97** (counsel; M7-MONEY-8, L5): a payout that came back is re-queued for the client; one of its
  collections is then undone. Is netting the undone collection against the re-queued sum a set-off (a clause needed,
  1347-2) or the same remittance duty reduced (1993)? Scenario: RV-1 (164 000) debited 03/11, back 05/11 (IBAN closed);
  P1 returned 12/11; without a claw-back clause the plan pays the whole 164 000 to the new IBAN and asks Martin to repay
  2 000. Default Q17 a (advance, conservative); b nets it. [check 1] Second path, switch on: X's payout cancelled after
  download, executed late as an unplanned payout U whose −A row paid collection E; the next run Y holds E (+A) and U's
  row (−A), N = 0; E is then reversed (cover A, T = the line since E is remitted in Y) and U comes back (+A
  re-queued, the cover stays): the client is paid A again and owes A (clawed back with a clause, else requested once
  paid). Same question, same default (043 case 5f).
- **[critic] OQ-98** (accountant; M7-MONEY-10, L21): the account of client money owed back (an overpayment, a payment
  for a document already settled, a pre-opening payment held for the procedure) — PCG class 419 « Clients créditeurs »
  proposed; its presentation in the accounting export. [check 1] Until answered the book carries Collectoo's label
  `419` (and `7714` for OQ-88), mapped by the accountant.
- **[critic] OQ-99** (counsel; L11, LEX-12): a payout made to the client's own IBAN on or after its liquidation judgment
  (L641-9 I): does it discharge the servicer (1342-2 al. 2: ratification, or profit to the creditor)? Are statements and
  invoices owed to the liquidator from then on, and may the client's own users still read them? Default: the P0 alert
  stays until ops record a ratification or a payment to the liquidator; documents stay readable by the client's users
  (unchanged) until counsel answers. [check 1] The record is `liquidation_payout_disposition` (append-only, staff
  only, its evidence kept; §6.1).

**Close**: none fully: OQ-82's residual part is closed inside the row.

---

## 12. Risks
- **R-a LG009 cost at volume** (one deferred check per reversal and per booked run): bounded in §8.3 rows 2–3 and
  [critic] row 8 (the existing 5,000-payout funds pass); fallback — a statement-level run trigger on a transition table,
  then the commit check on runs only with the nightly for single reversals (a decision recorded in the ADR).
- **R-b Redefinitions of long functions** ([critic] ≈ 3,500 copied lines; [check 1] ≈ 8,500 with the gaps' copies;
  [check 2] ≈ 9,000 with the booking guard, the two release guards, the job's candidates, the chain events and the
  schedule candidates —
  `ledger_post_set`, `ledger_entry_verify`, `ingest_statement`, `transfer_line_check` twice (7b, 7e-3), `debit_queue`,
  `pending_item_deadlines` —, `bank_booking_post_rows`, `run_remittance_runs_checks`, `bank_booking_recheck` and the
  statement build among them; the ledger's own checks, `ledger_entry_guard` and `ledger_entry_verify`, are the
  riskiest: 7c-1 and 7d-2 re-run every pgTAP file and the worker suites, and their PRs diff each copy against its
  source line by line): copy
  the latest body, diff it against its source in the PR (the « only the change » rule), re-run 033–042 and every
  integration file; [critic] F12 two slices never redefine the same function in parallel.
- **R-c The at-booking cover changes 6b's assertions** ([critic] F4: the list of §3.9 case 16, completed by running the
  suites on a prototype first): flipped deliberately, each in the ADR, purpose kept.
- **R-d Legal defaults** (7d) wait for counsel; the texts say « règle du cabinet » where the law is not the source.
  [critic] 7d now carries more of them (Q17–Q21, OQ-92/93/94/97/99); its split into three PRs ([check 1], §1.4)
  keeps each part reviewable.
- **R-e Scale CI time** (`scale-payouts` + ~8 min; Q13); [critic] F15 the machine's PR budget (≤ 6 min, §8.2).
- **R-f A top-up typed by ops and ordered again by the hour** (`request_top_up` takes no remit lock): over-funding with
  the servicer's own money, swept back; accepted.
- **[critic] R-g D1 kept (booked, not paid)** until the founder answers Q17: for a client without a claw-back clause
  whose payout came back, the servicer advances a reversed collection's amount that netting would have spared.

---

## Appendix — inventory items not taken, and where they went
- D13 (line split) → the bank / founder 6b-2 Q5, Q11. D21 (payee address) → the bank / counsel (OQ-79).
- RP-4 (paths that do not reverse 4670): checked, nothing to do.
- Design §15 `payee_changed` and `document_missing`: not M2c-7's (no slice named them; `remittance_document_missing`
  exists); left to a later ops slice.
- LEX-30 (payment services) → OQ-45, a go-live gate (§8.6). LEX-06, LEX-04, LEX-20: nothing new to build.

## Appendix B — [critic] critic findings not taken, or taken in part, with why
Every finding of the three critics was checked against the code at `1440178` (and the texts on LibreJustice); all hold
in substance and are folded in above. These parts were not taken as proposed:
- **M7-MONEY-8 / L5, option « key "remitted" on `remittance_chain_paid` and release the cover when a payout comes
  back »** — not taken; the critics' other option is. A `payout_returned` item re-queues the whole N as one item, paid
  again later in another run, so a per-line « paid and stayed paid » key would change T(R) with every later payout:
  I23 would have no stable value to check at commit (LG009), and a cover already clawed back could not be released.
  Kept: « booked » (D1), founder Q17 and OQ-97 with the scenario, the texts' « reversé le » only from
  `remittance_run_paid_on`, and `payout_not_received` on requests (§1.3 D1, §5.2.7, 043 case 17).
- **M7-MONEY-6, « statements must print only the DRA or run reference, never RMT/SWP/TOP ids »** — taken for the letter,
  not for statements. A payout's end-to-end id (RMT…) reaches the client's bank with the SEPA transfer, so the client
  sees it anyway, and the fr-3 statement prints it (`statement.py:654`, `:709`) so the client can match its payout;
  removing it would not stop a client quoting it. The defence is that a reference read from a label never books by
  itself (§7.3, D14).
- **M7-MONEY-10, « book the dedicated-account surplus as a pending item for the client, or refund it to the payer
  through the M2b refund path »** — taken in another form: one path for both accounts, a `client_credit` owed back by
  the servicer (the surplus overpaid a debt to the servicer, so it is the servicer's liability, not client money held
  for collection), swept with the servicer's share and refunded from the own account by `record_client_refund`
  (§5.2.4–5.2.6, OQ-98). A new uncommissioned queue kind for it is not needed.
- **M7-MONEY-5 (a), « recompute at … the N = 0 approval »** — no change needed there: the N = 0 run is booked and its
  settlement posted at approval, where `remittance_approval_refusal` already reads the bar of that day (redefined in
  7d with both kinds and the seizure).
- **M7-MONEY-3, « an expiry rule must be specified »** — specified as a founder question (Q20, default: no expiry, ops
  withdraw), not built; the withdrawal command is built.
- **L8 (2), « alert unpaid post-opening invoices with the L622-17 IV and L641-13 III deadlines (record the
  liquidation's publication date) »** — the alert is built (`post_opening_unpaid`, quoting L622-17 IV as read), but no
  deadline is computed: the end of the observation period is not modelled and L641-13 III was not read in this round;
  both go to OQ-92. Recording the liquidation's publication date is covered by `publication_date` (kind `liquidation`).
- **L14, « either a `seizure` event … or make Q12's default say ops must also hold the client's runs »** — the first
  is taken (event pair `seizure` / `seizure_released`); the second is not needed.
- **F9, « check reversals posted since the last clean run … »** — taken, plus a monthly and on-demand full pass
  (`p_full`) so a gap a bug let through before the window is still found.
- **L2, the texts cited in MAND-02 and OQ-94** — C. civ. 427 al. 5 is quoted as read; [check 1] 473, 440, 467 and
  472 are now read and quoted (2026-11-21); the seizure texts L211-3, R211-4, R211-5 and L641-13 are cited from the
  legal inventory and marked « to quote verbatim when the row is written », since no revision read them.

### [check 1] Completeness critic's gaps: options not taken, or taken in another form
All 14 gaps were checked against `1440178` and hold; each is folded in above. Where the critic offered options, or the
check found more than it said:
- **Gap 1, option (ii)** (no barred entry; a `settlement_withheld` pending row keyed on the payout's `remittance`
  entry) — not taken; option (i) is (§6.2.11 (a)). Every queue item today is the −Σ4670 of its own entry
  (`remittance_line_insert_guard`'s amount rule, `20261113090000:1860`; the 4670 trigger; I14's per-entry reading); a
  row keyed on a `remittance` entry whose 4670 posting is +N would need an exception in each, and the withheld money
  would have no ledger trace of its own. (i) costs one narrow LG003 exception, pinned by four refusal cases and a
  commit-time check. The critic's « the I14 `remittance_completeness` read » needs no change under (i) (pinned by a
  test, not redefined).
- **Gap 1, `remittance_line_insert_guard`** — not redefined for the new kind: it reads no kind (§6.2.11 (a) 6). 7b's
  redefinition of it (the advance mandate) stands, now with its latest source (`20261113090000:1860`).
- **Gap 2** — taken, and wider than listed: besides the book rows, `allowed_books` and `ledger_entry_verify`, the new
  books also need `ledger_post_set`'s hard-coded book lists, the `ledger_account_shape` check, the read policy,
  `ledger_balance` and the accounting export (each refuses or drops an unknown book), and two nightly identities.
- **Gap 3, option « replace the statement trigger with a row guard that lets only those columns move once from
  null »** — not taken; the side tables are. They keep `client_status_event` append-only (as M2c-2 built it, its
  change log meaning « inserted »), let a representative be corrected with its history, and need no exception in a
  guard every event write goes through. `qualified_at` stays a column (added by DDL, set at insert only).
- **Gap 5, « a release as a debtor payment, like release_own_credit »** — taken as `release_own_credit` itself
  (redefined to accept the new kind) rather than a new command: one exit, one set of refusals, the payment created as
  every other released credit is. Exit (b) needs no decision table: the booking is the decision. The critic's
  `bank_import_stage` column is taken; its « `private.stage_refined_kinds` and `private.held_line_kind` » are taken;
  `bank_booking_recheck` is **not** redefined for it (its kind rules already refuse other bookings, §7.3).
- **Gap 6, « for an N = 0 run take its booked_on and the wording « réglé par compensation » »** — taken, with two
  refinements: an N = 0 run with D = 0 (lines netted by an unplanned payout's −P row) is worded « compris … montant
  net nul », not « compensation » (nothing was set off), and an N = 0 run whose unplanned payout came back is followed
  to the re-queued item, as a returned payout is (else 043 case 5f would let a request through for money the client
  never kept).
- **Gap 7** — taken; the copy to the curator is stated as the servicer's rule by analogy with 467 al. 3 (which governs
  significations), not as the law's requirement for letters.
- **Gap 10, « otherwise require the second admin's explicit attestation »** — taken as the proposer's written
  explanation, stored on the account and shown to the confirming second admin (the confirmation command is unchanged:
  its existing second-person rule is the attestation); founder Q21 asks whether a strict refusal is preferred.
- **Gap 12** — taken, plus `cancel_top_up` widened to a filed top-up (so the exit does not require cancelling a whole
  file), and the draft's non-existent `book_own_credit` corrected to `link_debit … 'own_credit'`; the pick is a new
  command (`book_top_up_credit`) rather than a new parameter of `link_debit` (its signature and grants stay).
- **Gap 14** — taken; the redefinition table now carries every function with its slice and measured length, and the
  slices were re-sized: 7c, 7d and 7e exceed ~2,500 lines once the gaps' copies are counted, so they split (§1.4).

### [check 2] Second completeness check: options not taken, or taken in another form
All 6 gaps were checked against `1440178` (every line the critic cites confirmed) and hold; each is folded in above.
Where the critic offered options, or the check found more than it said:
- **Gap 1 (3), option « say that the ingest writes the review row »** — not taken; `bank_booking_candidates` and
  `decide_line` are (§7.3 « The job »). The reviews are the job's: `apply_bank_bookings` deletes and rewrites a line's
  review on every pass (`20261117090000:1522-1532`), and a held duplicate released later as `label_reference` never
  passes through the ingest (`resolve_duplicate` books no payment for that kind and leaves the line to the job). One
  path serves both; a review written by the ingest would need a second writer at the release.
- **Gap 1, « all in 7e-2 »** — taken across two PRs: revision 2's 7e-2 plus the five copies came to ≈ 2,880 lines, so
  7e-2 holds and reviews the kind and 7e-3 carries the three exits with every guard and reader they need (§1.4). The
  booking guard is copied once, in 7e-3, with both its changed arms (return and client payment).
- **Gap 1 (4)** — taken, a little wider than proposed: the chain events count a return booked on any credit with no
  end-to-end id whose `reference_from_label` is the transfer's id (a CSV `return` line carrying the label reference,
  booked by ops, counts too), and never an unbooked one (D14).
- **Gap 1, found while folding** — `release_own_credit` names the payer « Versement relayé par le cabinet » for every
  kind but `client_transfer_in` (`20261117110000:3202-3203`); a debtor's credit would have named the servicer as its
  payer. Exit (c) now takes the line's counterparty, or « relayé par le client » for a client's confirmed IBAN.
- **Gap 2** — taken as proposed (rule 3 from the bookings; 043 case 17 (d)).
- **Gap 3** — taken with a trigger of its own, `settlement_withheld`, rather than counting a withheld item in
  `payout_returned`: the run page would have said « Virement revenu » for money the servicer withheld. So
  `remittance_schedule_candidates` gains a column (dropped and recreated) and the run's trigger check gains a value.
- **Gap 4, option « define both twins on the one-letter map »** — not taken: the key must be the name the writer
  sends, so both twins use `_SPELLED`. Found while folding: the key also needs the combining-mark rule spelled out
  (only U+0300–U+036F but U+034F, whose class is 0) and a null for anything left outside Basic Latin, so that a
  difference between PostgreSQL's and Python's Unicode tables can only ever ask for an explanation, never accept.
- **Gap 5** — taken; the on-demand pass is a request row taken by the next ordinary check run, not a run of its own,
  because « Contrôles » shows the latest `payment_check_run` only (a run holding the advance checks alone would hide
  every other result until the next night).
- **Gap 6, option « move the `claims_declared` kind and `p_declared` to 7d-3 »** — not taken; `claims_declared_item`
  moved into 7d-1 instead: `record_client_status_event` is dropped and recreated once (7d-1), where the other option
  would recreate it a second time in 7d-3 (≈ 110 more copied lines) for the same result. 7d-1 then records
  declarations that 7d-3's alert reads.
