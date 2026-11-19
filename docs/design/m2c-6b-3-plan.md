# M2c-6b-3a: switch-on prerequisites. Build plan (revised after the critics)

> **As built (2026-11-18, branch `m6b3a`; ADR-0014 « M2c-6b-3a »).** §9 step 2's first group — L, K, N, A, A′, B,
> C, D, M with `034` (no `todo()`) and `039` A–D, K–N — is built in `20261118090000_switch_on_prerequisites.sql` (2,760
> lines: past §5's split point), with the texts' « on » variants that do not depend on E. **E–J are 6b-3a-2's**, with
> T13, T14, T16's late-predecessor wording, T17, T18, the worker twins (J), the LP integration file and the switch-on
> E2E project; §3.3's changes of 037 D (F4, F6), 037b and 038 come with them. Deviations: a third partial index
> (`refund_request_transfer_idx`: M's refund lookup was quadratic on the 5,000-refund scale file); `transfer_overview`
> redefined (A′ on « Virements »); D built on rule 3b's (iv); M3 unreachable (one live run per client); §3.3 gains
> `037c` R (L: the run's cancellation refused beside a reference-less debit at its cancelled payout's amount) and a new
> `037c` R pinning 6b-2d's rule with the run cancelled first. The switch stays off.

> **As built, part 2 (2026-11-18, branch `m6b3a2`; ADR-0014 « M2c-6b-3a-2 »).** E–J are built in
> `20261118100000_switch_on_prerequisites_2.sql` (one new helper, `private.transfer_late_predecessor`; 19 functions
> redefined whole from their latest definitions), with pgTAP `040_switch_on_followups_2` (38), §3.3's changes of 037 D
> (F4, F6), 037b `s_s02_live` and 038 `h_released`, the J twin and its property, `HELD_TO_SQL`, the texts T13, T14, T16's
> late-predecessor wording, T17, T18 and J's sentence (`switch-on-texts-2.test.ts`), the 6b-3a review's lows, the
> switch-on E2E project (§3.7: two screenshots, no late predecessor built in it) and the cancelled-and-re-issued scale
> file (`test_transfer_cancellation_scale_integration.py`, not the 6a file: §3.5). Not built: the LP worker
> integration file (§3.5; the two-connection cases). The switch stays off.

Base: `b795713` (main `cd4981b` + 6b-2d, PR #35). Migrations up to `20261117120000` are treated as merged.
This slice's migration is `supabase/migrations/20261118090000_switch_on_prerequisites.sql`.
Branch: `m6b3a` (one PR). Never `main`. `docs/PROGRESS.md` and `CLAUDE.md` are not edited.

**The switch stays OFF.** `private.feature_switch` `downloaded_file_cancellation` is never written by this migration.
6b-3b flips it with a one-line migration once the founder answers Q1 (OQ-81 (a)).

Everything below was checked against the code at `b795713`. The base was read with `git show`, and the migration files
were copied to the scratchpad and compared with `cmp`. No checkout was made. The critics' findings, and what this
revision does with each one, are in §10.

**What changed from the draft:**
- Three new items, all from critics' high findings:
  - **L**: a debit that carries none of our references can be a cancelled transfer's late execution, and every hold now
    sees it.
  - **M**: holds beyond the transfer's own replaces chain, for the client's next payout and the payment's next refund.
  - **N**: the cancellation evidence also sees debits that carry none of our references.
- Items revised:
  - **A**: the sweep rule is servicer-wide over every dedicated account, active or not.
  - **B**: the test is rebuilt so that it kills its mutant.
  - **C**: x is excluded only while its live end is alerted.
  - **D**: H-PAY covers any cancelled refund of the account at the line's amount, with the CSV residual.
  - **E**: the lock claim is corrected, plus E4b.
  - **F**: the run page's advances are added.
  - **I**: the rule now reads dates, covers the chain's whole window, and covers a run whose payout was cancelled alone.
  - **K**: a cancelled sweep that is the line's only candidate is booked `unplanned_sweep(S1)`.
- Corrected: the texts (§4) and the changed assertions (§3.3).
- §0 now says what the prototype does not prove.

## 0. What was run (main stack, read-only, every run `BEGIN … ROLLBACK`, `statement_timeout` 60–120 s)

**034 as it is today.** These tests fail:

| Test | Scenario | What the run shows |
|---|---|---|
| #9 | SW2 | the re-download is served: `"2"`, not `holds_debited_transfer` |
| #10 | SW2 | the alerts are `["sweep 12000 cancelled"]`: the cancelled S1 is alerted, the in-flight S2 is not |
| #12, #13 | SW3 | the first download of F2 is served: `downloaded` / `in_file`, nothing blocked |
| #15 | G1c | the alerts are `[]`: the G1 branch is keyed on live runs and waiting refunds |
| #18 | H-PAY | the reference-less line executes r2: `r2 executed`, transfer `booked` |

Test #16 (G1c, `cancelled_transfer_debited` for the batch line) already passes. It has done so since 6b-1.

**A throw-away prototype.** It is at `…/scratchpad/m6b3a/proto/proto_all.sql`, built by `proto/build.py` from the latest
definitions. It contains:
- `private.sweep_after_debited_cancelled`;
- `transfer_hold_reason` with a sweep branch;
- `transfer_file_download` with the sweep in both re-checks;
- `run_transfer_checks` with the G1 branch re-keyed;
- `generate_transfer_file` with the sweep's `created_at = clock_timestamp()`;
- `refund_transfer_follow` with H-PAY scoped to the payment.

Results with the prototype, every run rolled back:
- 034 with its 4 `todo()` lines removed: **18/18 pass**. No booking had to be added to any scenario.
- 015, 017, 023, 024, 026, 027, 028, 029, 031, 032, 033 (switch-off, unchanged), 035, 036, 037, 037b, 037c and 038 pass
  unchanged.
- **One outcome changes: 030 #27** (D4, scenario A2). Besides Lilas's payout, the blocked array of `f4`'s download now
  holds `<sweep> cancelled_sweep_debited`. That is the SW3 fix applied to 030's own state: a sweep generated after the
  cancelled sweep, which was later debited. The assertion's meaning (« superseded at download, not served ») holds. Its
  expected array gains that one element, and the ADR records why (house rule R3).
- Without the `clock_timestamp()` change, SW2 and SW3 still fail. See item A, « Timestamps ».

**What the prototype does not prove** (critics 1-7, 2-5):
- Its `sweep_after_debited_cancelled` keys c on the **same paying account** and uses the source plan's « no booking
  decided before creation » form. So the 18/18 result validates neither A′ (servicer-wide) nor the « second late line »
  half of A. The build re-runs 034 with A's final body first (§9 step 2).
- Only A, C and D were prototyped: items E–N are unproven. §3.3 is a provisional list, and the build re-runs 015–039
  after each item.

## 1. Scope

**In (this PR):**
- A. SW2/SW3: the second sweep, taken servicer-wide (A′), with the timestamp rule.
- B. Sweep proposals after an `unplanned_sweep` booking.
- C. G1c.
- D. H-PAY.
- E. The late predecessor (LP), booked through `book_transfer_line`.
- F. Every reader of « t is booked ».
- G. The return of a late predecessor.
- H. `transfer_file_release` with booked runs and refunds (defence in depth).
- I. R124-6 in-flight rows of a re-issue, and of a run whose payout was cancelled alone.
- J. OQ-82's known limit (P across transfers).
- K. Rule 3b: cancelled refunds and sweeps as candidates (iv).
- **L. (new)** A debit that carries none of our references, taken as a possible late execution of a cancelled transfer.
- **M. (new)** Holds beyond the replaces chain: the client's next payout, the payment's next refund.
- **N. (new)** The cancellation evidence sees debits that carry none of our references.
- The texts for the switch on (§4).
- pgTAP: 034 without `todo()`; the new `039_switch_on_followups`; the changed assertions (§3.3).
- Worker twins and tests, vitest, E2E with screenshots, docs.

**Out, and why:**
- **The switch itself:** 6b-3b, after the founder answers Q1.
- **033 turned into a switch-on test:** 6b-3b. Here 033 stays the switch-off test, byte for byte.
- **S06**, a debit of a payout never handed out (6b-2 plan Q9). It is not a switch-on prerequisite: it is reachable with
  the switch off, and its answer is open.
- **S25**, a debit of a cancelled refund that cannot be linked (OQ-81 (b), 6b-2 Q2). Its entries are not chosen. This
  revision leaves three more states in S25's bucket, each held or alerted, and none booked:
  - the reference-less twin, when K's iv candidate alone is a refund;
  - a refund still held by M once its predecessor's RFD line is on a statement;
  - a cancelled refund whose late debit leaves its payment's money free to be allocated again.

  Q1's text names them.
- **Relaxing the evidence rules** (m2c-6b-plan §3.3): no rule is removed. N tightens one.
- **The re-download of a file that was executed by lines without our references** (critic 1-1, low): its
  `file_executed` branch reads only our references. It is not switch-dependent, and the page already warns. A false
  block would stop the only way to get back a file that was lost. It is recorded in OQ-80 (o) as a residual.

**Inert while the switch is off.** Every new rule bites only in states that need a downloaded file to be cancelled:
- cancelled transfers of downloaded files (L, M, C, K);
- re-issues (E, I);
- files superseded or rejected after download (A, B, D);
- a cancellation request (N, whose commands refuse `bank_booking_required` before the evidence is read when the switch is
  off).

Production has none, and the prototype shows 033 unchanged. The code is still live, so it is reviewed as if the switch
were on. The two new partial indexes (§5) are the only change that is not inert.

## 2. Items

**Rules for every redefinition.**
- Each function named below is redefined with `CREATE OR REPLACE`, copied from its **latest** definition.
- The file and line given are the latest across all migration files. They were re-checked with a grep over
  `supabase/migrations/*.sql`, and are re-grepped at build time.
- Each redefinition restates `SECURITY DEFINER` where the original had it, every `SET` clause, `search_path`, and the
  grants or revokes of the latest file that names it.
- Each header names the file it is copied from.
- A new function is revoked from `public, anon, authenticated, service_role`, unless it is a page read.

**Dependencies.**
- L is the base of A, B, C, D, I, M and N, so it is built first (§9).
- K is the base of D's refund rule and of the sweep exit in L and B.

### A. SW2/SW3: a sweep made after a cancelled sweep that the bank debited late

**Today:**
- `private.transfer_hold_reason` (`20261115090000:1587`) returns null for every sweep: `if t.kind <> 'payout' then
  return null`.
- `public.transfer_file_download` (`20261117090000:1596`) re-checks two things:
  - in the generated branch, the holds of payouts and refunds only, plus `sweep_exceeds_share`;
  - in the downloaded/sent branch, `holds_debited_transfer` for payouts and refunds only.
- `private.run_transfer_checks` (`20261117110000:1637`) alerts the cancelled sweep itself, through
  `debited_cancelled_sweeps`. It never alerts the sweep still in flight.

**Change:**
1. **A new function**, `private.sweep_after_debited_cancelled(p_sweep_id uuid) returns boolean`. It is sql, stable,
   `search_path ''` and `enable_seqscan off`, and not security definer. It is true when t is a sweep, `ordered` or
   `in_file`, and some sweep c meets all of these:
   - c is of the **same servicer and currency** (A′), on any client_funds account of the servicer, whatever its status:
     a sweep of an account closed since can still be executed late (critic 1-7);
   - c is read by organization through `bank_transfer_cancelled_filed_idx`, whose leading column is `organization_id`;
   - c is `cancelled` and was an item of a file downloaded at least once;
   - `c.cancelled_at < t.created_at`;
   - c's return is not seen (`private.transfer_return_seen`);
   - c's late debit was not settled before t was made. That holds when either of these is true:
     - `private.transfer_late_debit_open(c.id)` (L): a line of c, own id or batch, or one carrying none of our
       references, that is not booked or linked yet;
     - an `unplanned_sweep` booking of c has an **entry `posted_at` >= `t.created_at`**.

   `transfer_debited_before(c)` is **not** the gate here. Its own-id arm counts booked lines, but its new arm (L)
   counts unresolved lines only. Once a line of c that carries none of our references is booked `unplanned_sweep(S1)`,
   it would read false, and S2, made before that booking, would be released.

   Use the entry's `posted_at`, which is `clock_timestamp()`, and never `bank_line_booking.decided_at`, which is
   `now()`.
2. **Timestamps.** `public.generate_transfer_file` (`20261116090000:276`) inserts the sweep with `created_at = v_now`,
   the `clock_timestamp()` it reads right after `remittance_command_locks` (`:333`). Two reasons:
   - `bank_transfer.created_at` defaults to `now()`, the start of the transaction. A generation that waited for the
     remit lock behind a confirmation would carry a `created_at` earlier than `c.cancelled_at` (which is
     `clock_timestamp()`), although c was already cancelled when the share was computed. The new sweep would then not be
     held: a double sweep.
   - In pgTAP the whole file is one transaction. The prototype without this change still fails SW2/SW3.

   `book_transfer_line` takes the remit lock (`20261117105000:125`), so a booking and a generation run one after the
   other. The sweep-return alert's `s.created_at > re.posted_at` becomes exact too.
3. **`private.transfer_hold_reason`:** right after `not_eur`, add `if t.kind = 'sweep' then return case when
   private.sweep_after_debited_cancelled(t.id) then 'cancelled_sweep_debited' end; end if;`.
4. **`public.transfer_file_download`:**
   - **Generated branch:** the holds run over the kinds `payout`, `refund` **and `sweep`**. That gives a blocked row
     `{transfer_id, kind 'sweep', reason 'cancelled_sweep_debited'}`, then `file_blocked`, then
     `transfer_file_release(…, 'superseded')`, which cancels the sweep.
   - **Downloaded/sent branch:** `holds_debited_transfer` also fires for an in-file sweep of the file for which
     `sweep_after_debited_cancelled` holds. It stays before `file_executed`. Its hint is reworded so that it is true for
     a sweep (§4 T19).
5. **`private.run_transfer_checks`:** a new `transfer_already_debited` branch for the servicer's sweeps that are
   `ordered` or `in_file` and for which `sweep_after_debited_cancelled` holds. Its details are `kind 'sweep'` and the
   sweep's status.
6. **A′, generation's D4** (`20261116090000:375`). Generation's share is servicer-wide per currency
   (`−Σ 4679 − Σ sweeps ordered/in file`), but D4 reads only the generating account's cancelled sweeps:
   `debited_cancelled_sweeps(b.id)`.
   - With two dedicated EUR accounts, a cancelled sweep of account A that is debited late does not stop account B's
     next sweep. The servicer's share then leaves twice, from client money (`servicer_shortfall`).
   - Payouts are already blocked when there are two active client_funds accounts (`several_client_funds_accounts`,
     `20261115090000:912`); sweeps are not.
   - **Fix:** D4 asks `exists` over every client_funds account of the servicer in that currency, whatever its status:
     `cross join lateral private.debited_cancelled_sweeps(a.id)`.
   - `debited_cancelled_sweeps` keeps its signature and stays per account (B). So the alert branch, which already loops
     over the client_funds accounts, lists each sweep once.

**Functions:**
- `generate_transfer_file` (`20261116090000:276`; security definer, `search_path ''`, `lock_timeout '5s'`);
- `transfer_hold_reason` (`20261115090000:1587`; stable, security definer, `search_path ''`);
- `transfer_file_download` (`20261117090000:1596`; security definer, `search_path ''`, `lock_timeout '5s'`);
- `run_transfer_checks` (`20261117110000:1637`; security definer, `search_path ''`, `enable_seqscan off`);
- the new `sweep_after_debited_cancelled`.

**Tests:**
- 034 #9, #10 (SW2) and #12, #13 (SW3), without `todo`, re-run with A's final body.
- 039 A:
  - A1: S2, made before ops book S1's late debit, stays held after the booking. Its re-download is refused.
  - A2: S3, made after the booking, is not held. Generation proposes it, and its first download is served.
  - A3: a second late line of S1, after the booking, holds again.
  - A4: the alert carries `kind sweep` and `status in_file`.
- 039 A′ (critic 2-5): two dedicated EUR accounts.
  - A′1: S1 on account A is cancelled, then debited late. B's generation gives `sweep_minor 0` and
    `cancelled_sweep_debited`.
  - A′2: the SW3 shape across the accounts. S2 on B is generated after S1 was cancelled. B's first download is
    `file_blocked` with `cancelled_sweep_debited`, and S2 is alerted.
  - A′3: account A is closed (`status` not active) after S1's cancellation. A′1 still holds.
- 039 A-batch (critic 2-15): S1's late debit comes as a batch line of its PmtInf (no SWP id), and S1 is cancelled alone
  out of a live file.
- 030 #27: the expected array gains the sweep (§3.3).

**Mutants, each with the test that kills it:**

| Mutant | Killed by |
|---|---|
| `<` → `>` on `cancelled_at/created_at` | 034 #9–#13 |
| the « booking posted at or after creation » clause removed | A2 (S3 held) |
| the « open late debit » half removed | A3 |
| the sweep dropped from the generated re-check | 034 #12, #13 |
| the sweep dropped from `holds_debited_transfer` | 034 #9 |
| the alert branch removed | 034 #10 |
| `created_at` back to `now()` | 034 #9–#13 (shown by the prototype) |
| c read per account | A′2 |
| D4 per account again | A′1 |
| D4 over active accounts only | A′3 |
| `transfer_late_debit_open` replaced by `transfer_own_debit_seen` | A-batch |

### B. Sweep proposals after an `unplanned_sweep` booking

**Today:** `private.debited_cancelled_sweeps` (`20261115090000:1269`) reads the cancelled sweep's debit whether it is
booked or not. So once ops book S1's late SWP line as `unplanned_sweep` (6b-2b), three things stay true for good:
- generation keeps `v_sweep = 0`, `cancelled_sweep_debited`;
- the cancelled sweep stays alerted (`transfer_already_debited`);
- `servicer_funds_unswept` follows.

The share is never swept. No money moves twice: the share is stuck.

**Change:** `debited_cancelled_sweeps(p_bank_account_id)` keeps the account's cancelled sweeps in a downloaded file for
which `private.transfer_late_debit_open(x.id)` holds (L: a late line not booked or linked yet, ours or one carrying none
of our references, and no return seen). It no longer uses `transfer_debited_before`.
- A second late line brings the hold back.
- The amount generation proposes comes from the booked 4679, because the `unplanned_sweep` entry debits it.
- The function keeps sql, stable, `search_path ''`, `enable_seqscan off` and its signature. It stays per account (A′
  loops over the accounts).

**Tests (039 B; rebuilt per critic 2-6).** D4 runs only when `v_sweep > 0` (`20261116090000:375`), and the booking
empties −Σ4679. So the scenario settles **new servicer money** (a commission booked to 4679) after the booking. Then:
- B1: generation gives `sweep_minor` = that new share (−Σ4679 − Σ in flight) and no `sweep_hold`.
- B2: the nightly check raises no `transfer_already_debited` for S1. S2, made before the booking, is still alerted
  (A1).
- B3: a second SWP line of S1 brings `cancelled_sweep_debited` back.
- B4 (K): a line carrying none of our references to our own IBAN, booked `unplanned_sweep(S1)` (K's iv), gives the same
  results as B1–B2.

**Mutant:** the clause removed. B1 fails (sweep 0, `cancelled_sweep_debited`).

### C. G1c: a refused payout executed late after its run was cancelled

**Today:** `run_transfer_checks`' G1 branch is keyed on the live runs and the waiting refunds. That is the
`20261117110000:1637` block `select r.transfer_id … union select q.transfer_id …`, read at `:1746–1762`. 034 #15 fails.

**Change:**
- **Source:** the servicer's cancelled payouts and refunds on client_funds accounts, with `transfer_file_id not null`,
  read by organization through `bank_transfer_cancelled_filed_idx`.
- **Kept:** those that meet all of these:
  - they were an item of a file downloaded at least once;
  - `private.transfer_debited_before(t.id)`, which with L includes lines carrying none of our references;
  - `private.transfer_late_debit_open(t.id)`: the alert goes silent once ops book or link the line.
- **Excluded:** t, **only while** the live end of its run or refund is alerted by the ordered/in-file branch (critic
  2-8). That is:
  - t's run is `approved`/`sent`, its `transfer_id` is `ordered`/`in_file`, and t is in `private.transfer_chain` of
    that transfer;
  - or t's refund request is `requested` with its transfer `ordered`/`in_file`, and t is in its chain.

  With the old rule (« re-issued by no transfer »), x re-issued as y, then its run or refund cancelled (y cancelled,
  never filed), was silent, although ROADMAP's G1c says « after its run or refund was cancelled ». The new rule keeps
  034 G2's exact `["refund 5000 in_file"]`.
- Sweeps keep their own branch.
- The cancelled transfers are read once, in a `materialized` CTE shared with the `cancelled_transfer_debited` branch:
  the same rows, half the calls (§7).

**Tests:**
- 034 #15. It passes with the prototype.
- 039 C:
  - C1: the G1c alert stops once ops book the late batch line as `unplanned_payout` (run cancelled, P = A).
  - C2 (critic 2-8): x re-issued as y (ordered), the run cancelled (y cancelled), then x's late debit. x is alerted.
  - C3 (L): the same with a line carrying none of our references at x's amount.
  - C4: a cancelled refund whose request was cancelled, then its late RFD line. It is alerted.
- 032's G1 exact array is unchanged (prototype).

**Mutants:**

| Mutant | Killed by |
|---|---|
| re-keyed on live runs | 034 #15 |
| the live-end exclusion removed | 034 #6 (q0 alerted beside q1) |
| the exclusion back to « re-issued by no transfer » | C2 |
| the late-lines condition removed | C1 |

### D. H-PAY: a debit carrying none of our references, and a refund still in a downloaded file

**Today:** `private.refund_transfer_follow` (`20261116090000:4683`) accepts a reference-less line for a refund whose
transfer is in a downloaded or sent file while `t.replaces_transfer_id is null`. 034 #18 fails.

**Change (scope revised per critic 1-5; Q2):**
1. **A new function**, `private.cancelled_refund_line_may_be(p_line_id uuid, p_refund_request_id uuid) returns text`.
   It is stable, security definer, `search_path ''` and `enable_seqscan off`. It returns the file number of a refund
   transfer c that the line may be the late execution of (K's iv refund), not in the request's own chain, when c meets
   all of these:
   - c is of kind `refund`, `cancelled`, and was an item of a file downloaded at least once, with an execution date on or
     before the line's date;
   - c is on the same paying account and currency;
   - its amount is the line's;
   - its payee IBAN is the line's counterparty IBAN, when the line has one;
   - its return is not seen.

   Otherwise it returns null. Whatever the payment, c's amount must equal the line's for the line to execute r2. So the
   payment scope that 034 #18 asserts is included, and the same line at the amount of another payment's cancelled refund
   is caught too.

   It reads keys only: the account's transfers at the amount (`bank_transfer_account_amount_idx`), their items and
   files.
2. **`refund_transfer_follow`:** the reference-less arm, and only for a transfer in a downloaded or sent file, also
   requires that function to be null. Otherwise the refusal is `reissue_in_downloaded_file`, with a new hint branch.
   - **The hint depends on the account's feed (critic 2-3):**
     - `camt053`: « Ce débit ne porte aucune référence, et un remboursement de ce montant était dans le fichier TF-…,
       annulé après téléchargement : il peut en être l'exécution tardive. Il ne peut pas exécuter ce remboursement,
       dont le virement est dans le fichier TF-…, déjà téléchargé. Ne le rattachez pas : attendez la ligne qui porte sa
       référence RFD ou celle de son lot, ou voyez avec la banque. »
     - `csv`: the same first two sentences, then « Ce relevé ne porte pas nos références : demandez à la banque le
       détail de ce débit et prévenez le support. »
   - **A refund whose transfer is `ordered`, never filed, is not refused.** Linking the line executes it and books its
     ordered transfer, which is the right money outcome when the line is the earlier refund's late execution. It is also
     M's exit.
   - The trigger keeps security definer and `search_path ''`.
3. **`public.debit_link_options`** (`20261117110000:2623`; stable, security definer, `search_path ''`, `enable_hashjoin
   off`, `enable_mergejoin off`) no longer lists such a refund for that line. Otherwise the page would offer a link that
   the trigger refuses.
4. **`link_debit_guard`** (`20261117113000:265`) is **unchanged**. The trigger is the single enforcement point, and the
   options hide the link. The return and the loss keep OQ-86's rule: iv is never a reason to refuse them. A cancelled
   refund cannot « still be paid out », and refusing them would leave a debtor's real return allocated (OQ-86's I13
   argument).

**Residual on a feed without our references (critic 2-3; OQ-80 (n), OQ-81 (b)).** Take r2 in a downloaded file, and a
line at its amount on or after a cancelled refund's execution date:
- that line is refused for good;
- r2's own file cannot be cancelled either (N: the line is at r2's amount from its execution date);
- both lines stay unbooked (5120 ≠ bank, alerted `bank_line_unbooked`), and the cancelled refund is alerted (C, status
  `cancelled`).

The only exit is the bank's detail and support, until OQ-81 (b) gives a four-eyes link on the bank's written
confirmation. Q2 says so.

**Tests (039 D):**
- D1: the hint, both feeds (a `says()`-style pattern).
- D2: `debit_link_options` does not list r2.
- D3: r2's own RFD line still books it.
- D4 (Q2 (a)): a refund **of another payment** at the same amount, in a downloaded file, is refused by such a line. At
  another amount, it is linked.
- D5: the first refund cancelled **alone** out of a live downloaded file is caught too.
- D6: an earlier refund whose file was never downloaded does not block (033's rule).
- D7: r2's transfer is `ordered`: the line links and executes r2, and its transfer is `booked`.
- D8 (critic 2-15): r1's transfer is in a file superseded **before** download, then executed from a downloaded file. r2's
  reference-less line still links. This is the « same file » semantics, also on the switch-off path.
- D9: the CSV stuck state:
  - refused, and r2's file cancellation refused `unreferenced_debit_open` (N);
  - alerts `bank_line_unbooked` and C.

**Mutants:**

| Mutant | Killed by |
|---|---|
| the clause removed | 034 #18 |
| scoped to the same payment | D4 |
| the « cancelled alone » arm dropped | D5 |
| the download and the supersede read on different files | D8 |
| the options filter removed | D2 |
| refused also for an ordered transfer | D7 |

### E. The late predecessor, booked through `book_transfer_line`
> *As built (6b-3a-2):* as below, the late predecessor read by `private.transfer_late_predecessor` (cancelled, its
> run approved or sent, in a file downloaded once, held by the chain of the run's transfer); pgTAP `040` E1–E8,
> F1b. The two-connection test is not built (the re-read's mutant survives one session).
> *As built (6b-3b part 1):* the worker integration file `test_switch_on_late_predecessor_integration.py` takes the
> late predecessor through the import and the debit job, its return (G4), `HELD_TO_SQL`'s parity, and the two
> connections against a generation (the re-read's lock order observed) and against the download, each first.


**Today, switch on.** Take x, cancelled out of a downloaded file, whose run is still `approved`/`sent`. Its live end y
is the run's transfer: x itself when x was cancelled alone, else its re-issue. The bank then executes x late.
- `payout(x)` is refused `transfer_cancelled` (`transfer_line_check` `20261117110000:452`, the payout branch).
- `unplanned_payout(x)` is refused `run_still_live`, same function, the ML-4 rule.
- The options propose the unplanned kind and show `run_still_live` (`transfer_line_options_of`, `20261117110000:117`).
- `cancel_remittance_run` refuses `transfer_already_debited`.

So the run's only real payout can never be booked. The line stays unbooked: an I9 gap, `bank_line_unbooked` and the P0
`cancelled_transfer_debited` for good. The run page says « il ne peut pas encore être comptabilisé ».

When x's late line carries none of our references, `transfer_debited_before(y)` does not see it, so y is not held: it can
be filed and executed, and the client is paid twice. **That hold is item L.** E is the booking that exits it.

**Change.** The state model is m2c-6b-plan §3.1's. No guard changes.

1. **The check.** `private.transfer_line_check` (`20261117110000:452`; security definer, `search_path ''`,
   `enable_seqscan off`). A `payout` part on a cancelled x is allowed as a **late predecessor (LP)** when all of these
   hold:
   - x is of kind `payout`;
   - the line identifies x as a payout line does:
     - class E: the line's e2e is x's;
     - class B: x is a member of the named PmtInf, with `r.tr_file = v_file` (x keeps the `transfer_file_id` of the
       file it was cancelled from);
     - classes N/O/E0: x is rule 3b's only candidate (with K's iv counted);
     - class U: the stored detail;
   - x's run is `approved` or `sent`;
   - x is in `private.transfer_chain(run.transfer_id)`;
   - no transfer of that chain has a `payout` booking;
   - account, currency and amount match.

   The live end, `y = run.transfer_id` **read after the remit lock** (point 3), then decides:

   | y | What the LP does |
   |---|---|
   | y = x, or y `cancelled` | nothing more (E4, E4b) |
   | `ordered` | cancel it |
   | `in_file`, file `pending`/`generated` (`download_count = 0`) | supersede that file, then cancel y |
   | `in_file`, file `downloaded` or `sent` | refuse **`reissue_in_downloaded_file`**, with y's file number as the detail (the G2 twin, OQ-80 (n)): ops have that file cancelled first, on the evidence |
   | `booked` or `returned` | `already_debited` (defensive: the run would be booked) |

   `late` and `late_date` are computed as for any payout. New `pg_temp._tl` columns: `lp boolean`, `lp_cancel uuid`,
   `lp_file uuid`.
2. **The options.** `private.transfer_line_options_of` (`20261117110000:117`; volatile, security definer,
   `search_path ''`, `enable_seqscan off`). A cancelled payout whose run is `approved`/`sent` is proposed as `payout`
   (action `payout`), not `unplanned_payout`, in classes E, B, U and N/O/E0 (iii). The preview's refusal
   (`reissue_in_downloaded_file`) is shown when y is handed out.
3. **The locks** (corrected per critic 1-6). `generate_transfer_file` takes **no run lock**. Its order is the account row
   `FOR SHARE`, the allocation lock, the remit lock, then files and transfers (`20261116090000:331`).
   `private.transfer_line_locks` (`20261117105000:47`; security definer, `search_path ''`, `enable_seqscan off`)
   collects its keys before the run and remit locks (`:125`). So a generation that commits in between moves y into a
   generated file the LP did not collect. Change:
   - after the remit lock, re-read `y = run.transfer_id` and y's current file;
   - step 8 locks that file `FOR UPDATE`, in id order before the `FOR SHARE` set, if it is `pending` or `generated`
     (m2c-6b-plan §2.6's [critic] rule);
   - step 9 locks y and every transfer of that file `FOR UPDATE`;
   - the check reads y and its file after the locks, and refuses **`split_changed`** whenever y's current file is not
     the one named in the caller's compare text (`:lp:<y>:<file>`, point 6). The same applies whenever y's status
     changed since the preview.

   The order is unchanged: runs → … → remit → files → transfers. A generation either commits before the LP takes the
   remit lock (then the LP sees y's new file: it supersedes it if generated, or refuses if the caller's text named
   another file), or waits for the LP's commit.
4. **The posting.** `private.transfer_line_post` (`20261117100000:1487`; security definer, `search_path ''`). Before the
   planned parts:
   - `transfer_file_release(lp_file, 'superseded', 'Virement <y.e2e> retiré : le virement qu''il remplace a été débité
     (relevé du jj/mm/aaaa)', null, null)`;
   - then `update bank_transfer set status = 'cancelled', cancelled_at = clock_timestamp(), cancelled_by = auth.uid(),
     cancel_reason = left('Réémission annulée : le virement <x.e2e> qu''elle remplace a été débité (relevé du …)', 2000)
     where id = y and status = 'ordered'`.
5. `private.bank_booking_post_rows` (`20261117100000:2496`; security definer, `search_path ''`): the update that books
   the transfer skips a cancelled one (`and x.status <> 'cancelled'`). x stays `cancelled`, with `entry_id` null.

   Everything else is a payout's:
   - `remit:<x>`, with source `bank_transfer` x;
   - `settle:<run>` at the line's date;
   - the `payout_overrun` cover;
   - the run `booked`, with `booked_on` the line's date;
   - breach rows only for the lines late at that date.
6. **What the sheet and the compare text read.**
   - `private.transfer_line_parts_json` (`20261117110000:1108`; stable, security definer, `search_path ''`) adds
     `late_predecessor`, `cancels_transfer_id` (null when y = x or y is already cancelled), `cancels_end_to_end_id` and
     `supersedes_file_number`.
   - `private.transfer_line_text` (`20261117100000:1187`; stable, `search_path ''`): an LP part appends `:lp:<y>:<y's
     file or ->`. A y that changes between the sheet and the command is then refused `split_changed`. The other parts'
     text is unchanged.
7. **The job is unchanged.** A debit of a cancelled transfer is never automatic (`cancelled_transfer_debited`, P0).
   `bank_line_booking_guard`'s `payout` clause has no status rule, so it is unchanged for the debit (checked).

**Tests (039 E):**
1. E1: x re-issued as y, y `ordered` (held `already_debited`); the E line carries x's RMT id.
   - The options propose `payout(x)`.
   - The booking posts `remit:<x>` and `settle:<run>`. The run is `booked`, with `booked_on` the line's date.
   - x is `cancelled`, with `entry_id` null; y is `cancelled`.
   - I20, I9, I19, I13 and I14 are clean.
   - `cancelled_transfer_debited`, the G1 alert and `transfer_already_debited` are silent.
   - A breach row is written only if late.
2. E2: y is in a generated file F_g. F_g is `superseded`, its other payouts are `ordered` with their dates, and its sweep
   is `cancelled`.
3. E3: y is in a downloaded file F2, and **again with F2 marked `sent`** (critic 2-15).
   - The options' refusal and the command's are `reissue_in_downloaded_file`, and nothing changes.
   - F2 is then cancelled whole on evidence, by two people: y2 is `ordered` and held.
   - The LP is then allowed, and y2 is cancelled.
4. E4: x cancelled alone (`run.transfer_id = x`, run `sent`). The run is booked; there is no y.
5. E4b (critic 1-8): y cancelled alone out of a still-live downloaded F2, then x's late line. The LP books the run. A
   later debit of y is booked `unplanned_payout(y)`, the run being booked: P = 0, the advance is A, the client is paid
   twice and the claw-back applies (Q4/OQ-82). y is alerted by C until then. The texts never say that y can no longer
   leave the account.
6. E5: a batch line of x's PmtInf (class B), and a reference-less line (class N, rule 3b's only candidate). The N case
   first shows L's hold on y, then the LP lifts it.
7. E6: G1c's 583 840 variant, with Lilas live and Martin late in one line. The parts are `payout(Lilas) + payout(Martin,
   LP)`. With Martin's run cancelled instead, they are `payout + unplanned_payout` (P = A).

   The first statement holds only the sweep's f1-2 line. That lets Martin be cancelled alone (D2) while Lilas stays live:
   G1c's base statement books Lilas (critic 2-15).
8. E7: a second execution of x after the LP. It is booked `unplanned_payout(x)` (its run is booked): P = 0, and the
   advance is A.
9. E8: `split_changed` when y's file is generated between the preview and the command.

**Worker integration**, `test_switch_on_late_predecessor_integration.py`. It goes through the real path: the API session,
the import of a synthetic camt.053 of the old pain.001, and the jobs. The switch is on for its own committed transaction
only, then committed off, as `test_a_run_cancelled_after_download_then_its_late_debit_pays_its_items` does. It covers:
- the LP end to end, with the nightly checks clean;
- two connections, the LP against `generate_transfer_file`. Connection A holds the remit lock (through
  `remittance_command_locks`) and generates y's file. Connection B's `book_transfer_line`, its keys collected before, waits
  at the remit lock and then refuses `split_changed`. With the caller's text naming the new file, B supersedes it instead.
  There is no deadlock, and nothing is booked twice;
- two connections, the LP against `transfer_file_download` of y's generated file. One wins.

**Mutants:**

| Mutant | Killed by |
|---|---|
| the « y handed out » refusal removed | E3 |
| `status = 'downloaded'` only (the `sent` case dropped) | E3 with `sent` |
| y not cancelled | E1 |
| the supersede dropped | E2 |
| the cancelled skip removed from `bank_booking_post_rows` | E1 (guard error, `posting_failed`) |
| the options still unplanned | E1 options |
| the chain test replaced by « any run » | E4/E1 with an unrelated run |
| `:lp:` dropped from the text | E8 |
| y read before the remit lock (no re-read) | the two-connection test |

### F. Every reader of « t is booked »
> *As built (6b-3a-2):* I20 (`run_payment_checks`), the deadlines (`pending_item_deadlines`, `HELD_TO_SQL`), the
> P0 `payout_returned`, the run page (`remittance_run_payout`: `late_predecessor`, its advances, `repaid_by`), the
> client summary's `returned_runs`, the lot's returnable members, the booked update skipping a cancelled transfer;
> « Suivi » needed no change (pgTAP `040` F7). pgTAP `040` F1–F7.


An LP transfer is cancelled, with a `payout` booking and no return booking. Each reader below must take it as booked.
Before writing F, the build re-greps every reader of `bank_transfer.entry_id` and `return_entry_id` (critic 2-4). Those
known now:
- `20261117110000:3252`, `:3272`, `:3292`, `:3446`, `:3452`;
- `20261117100000:2393`;
- `worker/src/collectoo_worker/jobs/remittances.py:597–612`.

| Reader | Latest definition | Today | Change | Test |
|---|---|---|---|---|
| I20 `transfer_booked_once` | `private.run_payment_checks` `20261116090000:2617` (security definer, `search_path ''`) | x flagged as not booked with a debit; the run flagged as booked while its transfer y is cancelled | exempt a payout that is `cancelled`, with exactly one `payout` booking (and at most one return booking), whose run is `booked` and holds x in its chain, with no other chain transfer booked; exempt a booked run whose chain holds exactly one such x | 039 F1: clean after E1/G1; a forged cancelled payout with a payout booking whose run is not booked is still flagged |
| Deadlines of a returned payout | `private.pending_item_deadlines` `20261117100000:2344` (sql, stable, security definer, `search_path ''`, `enable_seqscan off`); `HELD_TO_SQL` / `_held_to`, `worker/.../jobs/remittances.py:597,662` | planned branch keyed `bt.entry_id = e.reverses_entry_id`: x's return has no deadline, no breach row and no late reason (a missing R124-6 row) | also when the reversed entry is x's `payout` booking's entry (`bank_line_booking` by `entry_id`, unique) | 039 F2; the parity test in `test_transfer_line_ops_integration.py` extended |
| `payout_returned` alert | `run_transfer_checks` (above) | the same `bt.entry_id` key: no P0 | the same widening | 039 F3 |
| Client « Reversements » | `public.client_remittance_summary` `20261117110000:3391` (stable, security definer, `search_path ''`) | `returned_runs` keyed on `run.transfer_id` returned (`:3446`, `:3452` on `return_entry_id`): the returned LP run reads « Virement débité » in green (a false statement on the page) | also runs whose chain holds a cancelled payout with a `payout_returned` booking: `returned_on` from that line, `repaid_by` by the return booking's entry; the per-run fact `transfer_outcome` for §4 T17 | 039 F4 |
| Run page: dates, returned items | `public.remittance_run_payout` `20261117110000:3230` (stable, security definer, `search_path ''`, `enable_seqscan off`) | the dates are there; `repaid_by` and the returned items (`:3252`, `:3272`) keyed on `return_entry_id`, which is null for x | `repaid_by` and the returned items by the return booking's entry; a `late_predecessor` flag; web `runs.ts` `runPayoutNotes` (the returned note also for status `cancelled`) | 039 F5, vitest |
| Run page: advances (critic 2-4) | the same function, `'advances'` at `20261117110000:3292` (`client_advance.cause_entry_id = x.entry_id`, `cause 'payout_overrun'`) | x's `entry_id` is null, so an LP's `payout_overrun` advance is missing from the page: a missing amount | reach the advance through the `payout` booking's entry of x (`bank_line_booking` kind `payout`, transfer x) | 039 F5b: an LP with an overrun lists its advance with its amount |
| « Virements » | `public.transfer_bookings` `20261117110000:3342` | the data is fine; web `transferBookingText` gives null for a cancelled transfer with `debited_on` | web only (§4 T18) | vitest |
| « Suivi » | `private.remittance_statement_previous_payouts` `20261117120000:141` | it reads the chain's bookings: `debited` on x's line date, then `returned`. Correct | none | 039 F7 asserts the next run's events |
| A lot credit | `private.transfer_line_returnable` `20261117100000:254` (sql, stable, security definer, `search_path ''`, `enable_seqscan off`) | returnable only if `status = 'booked'` | also a cancelled member with a `payout` booking in that file and no return | 039 G3 |
| Accounting export | — | `remit:<x>` with source `bank_transfer` x: its RMT id | none | 039 asserts it |

### G. The return of a late predecessor
> *As built (6b-3a-2):* the check takes a cancelled payout with exactly one `payout` booking as that booking's
> entry reversed; the guard widened to it; x stays cancelled. pgTAP `040` G1–G3 (G4 through the job: not built).


**Today:**
- The job reviews it `return_differs` (`payments/debits.py:677`, `f.status != "booked"`). It is never automatic, and that
  is kept.
- `transfer_line_check`'s `payout_returned` branch refuses `transfer_cancelled`.
- `bank_line_booking_guard` requires `reverses_entry_id = transfer.entry_id`, which is null.
- `transfer_line_post` sets `returned`, and the guard refuses `cancelled → returned`.

**Change:**
1. `transfer_line_check`: x cancelled, with exactly one `payout` booking (of entry E) and no return booking, proceeds
   with `tr_entry := E`. The other rules are unchanged: `return_before_debit` by E's date, `unplanned_open`,
   `debit_pending`, the amount, and the fee on a flagged short return.
2. `transfer_line_post`: it reverses E (`return:<line>:<x>`). Its `returned` update skips a cancelled transfer. The
   payout account is marked `returned`, as today.
3. `private.bank_line_booking_guard` (`20261117100000:2197`; trigger, `search_path ''`, `enable_hashjoin off`,
   `enable_mergejoin off`). Its `payout_returned` clause becomes `x.reverses_entry_id = x.tr_entry or (x.tr_entry is null
   and x.reversed_kind = 'payout' and x.reversed_transfer = n.transfer_id)`.
4. The options' E-credit `payout_returned(x)` proposal now previews ok. F gives the lot credit.

**Tests (039 G):**
1. G1: after E1, a credit carrying x's id as its original id gives:
   - the reversal of `remit:<x>`, and the `payout_returned` +N item with the run's deadline (F2);
   - the payout account `returned`, the P0 alert (F3), and the client's `returned_runs` (F4);
   - the run page's returned items (F5);
   - x still `cancelled`, and I20 clean;
   - the schedule drafts the client's run (trigger `payout_returned`).
2. G2: a return short of N gives `payout_returned` + `fee`.
3. G3: a lot credit naming x's PmtInf.
4. G4 (critic 2-15): the same credit through the import job is reviewed `return_differs` and never booked automatically
   (worker integration).

**Mutants:**

| Mutant | Killed by |
|---|---|
| the guard widening removed | G1 (`posting_failed`) |
| the status skip removed | G1 |
| the returnable widening removed | G3 |
| the planned-branch widening of `pending_item_deadlines` removed | F2 |

### H. `transfer_file_release` with booked runs and refunds
> *As built (6b-3a-2):* as below; pgTAP `040` H.


**Today:** `private.transfer_file_release` (`20261115090000:1669`; security definer, `search_path ''`) re-issues every
in-file payout and refund of a downloaded file.

No state reaches a re-issue whose run is booked or cancelled, or whose refund is not `requested`:
- `cancel_remittance_run` refuses `payout_in_downloaded_file` whatever the switch (`20261116090000:5124–5140`);
- `cancel_refund` refuses `in_downloaded_file`;
- an executed transfer is `booked`;
- the LP never leaves y handed out.

So this item is defence in depth (low), as m2c-6b-plan §3.1 asks.

**Change:** in the loop, a payout whose run is not `approved`/`sent`, or a refund whose request is not `requested`, is
cancelled and not re-issued. Its reason is « Fichier … annulé après téléchargement : non réémis (reversement déjà
comptabilisé ou annulé / remboursement plus en attente) ». The run's and the refund's pointers stay.

**Test, 039 H:** forge a run `booked` while its payout is in a downloaded file (`remittance_run_guard` lets `sent →
booked` through). Cancel the file whole on evidence: there is no re-issue, x is cancelled, and the run is still booked.

**Mutant:** the rule removed. A re-issue is created, and H fails.

### I. R124-6 in-flight rows of a re-issue, and of a run whose payout was cancelled alone
> *As built (6b-3a-2):* in `private.run_remittance_runs_checks`; pgTAP `040` I1–I6.
> *As built (6b-3b part 1):* the booking of a chained run's payout (`private.bank_booking_post_rows`), its sheet's late
> flag and the nightly booked branch apply the same two holds (`private.remittance_chain_holds`: coverage of
> [least(e0, L), L], no uncounted possible debit of another transfer of the chain by L); pgTAP `041`.


**Today:** in `private.run_remittance_runs_checks` (`20261117110000:1251`; security definer, `search_path ''`,
`enable_seqscan off`), `olc.proven` has two branches:
- a payout never handed out (`ordered`, or in a file never downloaded) is proven unpaid at once;
- a payout handed out is proven once the statements cover L with no `transfer_debit_seen` (its own e2e or PmtInf only).

With the switch on, two cases go wrong:
- **A re-issue y**, ordered or downloaded, whose predecessor x's late debit is on a statement (x's RMT id, the old
  PmtInf's batch line, or a line carrying none of our references). Its run's items get an **append-only breach row**,
  although x may have paid them on time. The LP booking writes no correction (`on conflict do nothing`). That is a false
  R124-6 row.
- **A run whose payout was cancelled alone** (y = x, « Virement refusé par la banque », the run still approved or
  sent; critic 2-2 (b)). `olc.proven` is true only for `ordered`/`in_file` transfers, so it is false here.
  `inflight_overdue_lines` keeps listing the run, but no row is ever written while the run waits: a missing R124-6 row.

**Change.** For a run in flight whose transfer t is a re-issue (`replaces_transfer_id is not null`) or is itself
`cancelled`, `proven` at L requires both:
- **coverage:** the statements cover **[e0, L]**, where e0 is the earliest execution date of the chain's transfers that
  were handed out (an item of a file downloaded at least once). This holds even when t itself was never handed out
  (critics 2-2 (c), 2-14);
- **no possible debit by L:** for each such chain transfer x, `private.transfer_debit_suppression(x.id, L, today)`
  (latest `20261117113000:175`; read only) is not `'waiting'`.

What that reader brings:
- it reads x's own e2e, its PmtInf's batch lines, lines carrying none of our references at its amount, and O/E0 lines to
  its payee, dated from x's execution date **to L**, not booked and not linked;
- so a debit dated after L never suppresses the row (critic 2-2 (a): the payment is certainly late);
- a line already booked to another transfer no longer keeps the row back (critic 2-2, low; `batch_debit_may_hold`
  ignored bookings).

`'expired'` gives a proven row with the reason « débit possible non comptabilisé », as for in-flight payouts today. Other
transfers keep today's two branches. The chain is read by key and is a few rows long.

**Tests (039 I):**
1. I1: F1 cancelled whole, y ordered, and x's late debit dated before L: no breach row. Then the LP: no row (on time).
2. I2: the same with the debit dated after L. The nightly check writes the row once [e0, L] is covered, and the LP then
   books with no second row.
3. I3: y ordered, no debit of the chain, and the statements covering [e0, L]: the row is written, as today.
4. I4: a line of x carrying none of our references, dated on or before L. The rule is `'waiting'` (no row) within the
   bound days, then `'expired'` (a row with the reason).
5. I5: a re-issue never handed out, with a statement missing one day of [e0, L]: no row until it is imported.
6. I6: a run whose payout was cancelled alone (y = x): the row is written once [e0, L] is covered with no possible debit
   of x.

**Mutants:**

| Mutant | Killed by |
|---|---|
| the chain condition removed | I1 (writes a row) |
| the coverage reduced to L only | I5 |
| the suppression removed | I4 |
| date-blind (any chain debit suppresses) | I2 |
| the cancelled-run-transfer branch removed | I6 |

### J. OQ-82's known limit: P across two transfers
> *As built (6b-3a-2):* default (a) in the check and its twin (`PoolItem.paid_by_other`, `UnplannedAsk.transfer`);
> pgTAP `037` D (F4), `040` J; pytest `test_j_an_item_netted_after_another_transfer_is_not_netted_again` and the
> property.


**Today:** the P loop of `transfer_line_check` (`20261117110000:452`, « §3.6.1 P per item ») caps per transfer: A, less
what earlier bookings of the **same** transfer netted. Take an item released by two cancelled runs whose payouts x1 and x2
are both executed late. It is netted up to its gross: 037 D (F4) pins `x2 → paid 5400, advance 24600`. The 5 400 is the
commission share that R1 set off, and the next run then takes it from the client's unrelated collections. That is a
hold-back without a clause (Q4, founder #7, OQ-38).

OQ-82 says this must be fixed « before the switch goes on ». The exact per-item net needs the commission's VAT share per
item, which is open: it is never invented.

**Change (default, conservative):** an item already attributed is left out of the part's pool, so P counts it 0. That is
an item with an `unplanned_paid_item` of an unreversed booking of **another** transfer, or of an earlier part of this
call for another transfer. The rest of A is the servicer's advance. Recovery is slower, and there is never a hold-back.
- **SQL:** in that loop, `_tl_el` drops such items.
- **Twin:** `worker/src/collectoo_worker/payments/transfer_lines.py` `unplanned_p` (`:79`). Add `PoolItem.paid_by_other:
  bool`, and `UnplannedAsk.transfer: str | None` for the in-call case.
- **Property:** `worker/tests/test_transfer_line_ops.py:227` `test_p_bounds_and_attribution`.

**Tests:**
- 037 D (F4): the expected second part becomes `paid 0, advance 30000, items`, and `attributed [[24600,1]]` (§3.3).
- 039 J: two calls, x1 then x2, give P2 = 0.
- The property test and the integration parity (the twin against the command's result).

**Mutant:** the exclusion removed. 039 J, 037 F4 and the property fail.

### K. Rule 3b: cancelled refunds and sweeps as candidates (iv)

**Today:** `private.transfer_line_candidates` (`20261117110000:2009`; sql, stable, security definer, `search_path ''`,
`enable_seqscan off`). Its (iii) holds cancelled and returned **payouts** only.

Take a CSV debit with no reference and no IBAN (class N, where k is not required) at an in-flight payout's amount. It may
be the late execution of a refund or a sweep cancelled out of a downloaded file. Rule 3b's only candidate is the payout,
so the page proposes `payout(t)`. The booking misclassifies the money: t's real debit later becomes a « double payout »
advance claimed from a client that was paid once (medium, rare: it needs an amount coincidence).

**Change:** a new `cand 'iv'`: a refund or a sweep that is `cancelled` and was an item of a downloaded file of b, at
amount a, with its execution date ≤ d, its payee IBAN = k when k is given, and its return not seen. Its effects (revised
per critic 1-4):

| Case | Effect |
|---|---|
| a payout or sweep part with `v_cands > 1` | `line_ambiguous` (as today) |
| iv alone, a **sweep** S1 | `unplanned_sweep(S1)`, bound to S1, is proposed and allowed: the class N/O/E0 check passes with `v_cands = 1` and S1 the candidate (`20261117110000:822`). A and B read it as S1's booked late debit. The unplanned_sweep with no transfer is refused `sweep_in_flight_matches` (`:901`, `p.kind = 'sweep'`), so the share is never booked off S1's record |
| iv alone, a **refund** | no proposal; the refusal is `cancelled_transfer_matches`. This is S25's reference-less twin (OQ-81 (b)): no booking kind exists yet. The line stays unbooked, alerted `bank_line_unbooked` and, through L/C, `transfer_already_debited` with status `cancelled`. OQ-80 (n) records it. `cancel_refund` of a refund whose chain holds that transfer is refused (L); the M hold keeps the payment's next refund out of files |

`link_debit_guard` (`20261117113000:265`) is **unchanged**:
- the fee and the explanation are already refused on every candidate;
- the refund link is handled by D's trigger and options;
- the return and the loss keep OQ-86's rule: iv never refuses them.

The other consumers read the candidates through this one function: `transfer_line_check`, `options_of`,
`transfer_line_bookable_as`, the suppression and `bank_line_unbooked`. iv has no run, so `p0` is unchanged.

**Tests (039 K):**
- K1: a payout in flight and a cancelled refund at one amount: `line_ambiguous`.
- K2: the cancelled refund alone:
  - `cancelled_transfer_matches`, with no proposal;
  - « Frais » and « Classer » refused;
  - the return and the loss of a debtor payment still allowed (OQ-86).
- K3: the cancelled sweep alone:
  - `unplanned_sweep(S1)` is proposed and booked;
  - the unplanned_sweep with no transfer is refused `sweep_in_flight_matches`;
  - then B resumes the proposals (B4).
- K4: 037 P's read bound is still met (the probe is the same index).

**Mutants:**

| Mutant | Killed by |
|---|---|
| iv removed | K1, K2 |
| iv alone refused for a sweep too | K3 |

Default: included (Q4). If deferred, the residual of K's paragraph goes into OQ-80 (n), and L's sweep exit (L4) then
needs the unplanned_sweep with no transfer, booked against S1 by a separate rule. So deferring K costs more than building
it.

### L. (new) A debit carrying none of our references, taken as a possible late execution of a cancelled transfer

**Today:** both `private.transfer_debited_before` (`20261115090000:1221`) and `private.transfer_late_lines`
(`20261117090000:825`) read only debits carrying the transfer's own e2e, and batch lines of a PmtInf that held it. Every
hold and every guard goes through them:
- `transfer_hold_reason` (`20261115090000:1606`), for generation and the download's generated re-check;
- `holds_debited_transfer` (`20261117090000:1698`);
- `cancel_remittance_run` (`20261116090000:5145`);
- `refund_transfer_follow`'s cancel branch (`20261116090000:4741`);
- the `transfer_already_debited` alert;
- `debited_cancelled_sweeps`.

A CSV feed without the end-to-end column carries no reference at all, and nor does a camt.053 entry without references
(OQ-80 (n)). There, a cancelled transfer's late execution is invisible:
- a re-issue y is filed and its first download is served: the client is paid twice;
- the run can be cancelled: its items are paid again;
- a re-issued refund can be cancelled, and the payment's money released while the debtor already has it;
- the new sweep is not held and D4 is not set: the share is swept twice.

All of these follow an ordinary ops action: generating, or cancelling with what the page offers. Critics 1-2 and 2-1 rate
it high. OQ-80 (k)'s own default is « held whenever it cannot be ruled out ».

**Change:**
1. **`private.transfer_unreferenced_lines(p_transfer_id uuid) returns table (id uuid, booking_date date)`**: plpgsql,
   stable, `search_path ''`, `enable_seqscan off`, not security definer (as `transfer_late_lines`), revoked from all
   four roles. It applies to a transfer t that was an item of a file downloaded at least once; e is the earliest
   execution date of such an item (otherwise the result is empty). It returns the debits of t's paying account that meet
   all of these:
   - same currency, `amount_minor` = t's, and `booking_date >= e`;
   - they carry none of our references. Read per line with `private.transfer_line_class` (keyed, as the suppression
     reads it):
     - class N (no e2e, no PmtInfId), with the counterparty IBAN null or t's payee IBAN;
     - or class O/E0 with the counterparty IBAN = t's payee IBAN, and not an E0 whose PmtInfId names another lot of ours
       on the account (`private.pmt_inf_names_account_lot`);
   - `unsplit_ours` is null;
   - they are **unresolved**, with `transfer_late_lines`' four exclusions:
     - not booked;
     - not linked other than `explained`;
     - not a payment;
     - not decided a duplicate.

   It never calls `transfer_line_offers` or `transfer_line_candidates`: a line that offers nothing still counts (critic
   1-2).

   It is keyed: t by id, its items by transfer, and the lines by a new partial index `bank_transaction_debit_amount_idx
   on public.bank_transaction (bank_account_id, amount_minor) where direction = 'debit'`. The existing
   `bank_transaction_other_debit_amount_idx` is limited to `kind = 'other_debit'`; the build checks that no other index
   serves before adding this one.
2. **`private.transfer_late_debit_open(p_transfer_id uuid) returns boolean`**: sql, stable, `search_path ''`, revoked.
   It is true when both hold:
   - `exists (select from private.transfer_late_lines(t))` or `exists (select from
     private.transfer_unreferenced_lines(t))`;
   - not `private.transfer_return_seen(t)`.

   It is used by A, B, C and M.
3. **`private.transfer_debited_before`** (`20261115090000:1221`; plpgsql, stable, `search_path ''`, `enable_seqscan
   off`, not security definer; its grants restated). In the chain loop, for a chain member at depth > 0, and for t itself
   when it is `cancelled`, the function is also true when both hold:
   - `exists (select from private.transfer_unreferenced_lines(member))`;
   - its return is not seen.

   It never applies to t's own execution out of the live downloaded file it is in (depth 0, `in_file`): that line is t's
   own, rule 3b (i)/(ii). An `ordered` t at depth 0 was never in a downloaded file, because with the switch on a
   downloaded file's transfers are re-issued, never re-queued. Its own probe is empty.

   Every caller listed above inherits the arm.

`transfer_late_lines` itself is **unchanged**. The job's return rule (`debit_pending`, the worker twin at
`payments/debits.py:377`) and the P0 `cancelled_transfer_debited` keep reading our references only. A debit carrying none
of our references is never booked automatically, so no worker twin is needed.

**Exit.** The line is booked or linked, and the hold lifts. That can be:
- the LP (E) or `unplanned_*`;
- K's `unplanned_sweep(S1)`;
- the refund link to the chain's own refund: `refund_transfer_follow` executes a refund whose transfer is ordered, and
  books it.

**Trade-off** (OQ-80 (p), Q5): a coincidental debit of the same amount, to the same payee or with no IBAN, holds until
ops classify it. When rule 3b leaves it ambiguous, the exit is the bank's detail.

**A deviation from round 4's default, recorded in the ADR.** A line within a cancellation's window that is imported after
the cancellation counts here. The round-4 default does not read such a batch line as a late execution, because a
statement the bank produced after a day is final for it. A line carrying none of our references cannot be told apart, and
N refuses the cancellation while such a line is unresolved.

**Tests (039 L):**
- L1 (critics 1-2, 2-1, E5): on a CSV-fed account (fixture `feed 'csv'`), F1 is cancelled whole and y is ordered. Import
  an N line at x's amount, dated after x's execution date, then generate:
  - y is held `already_debited`;
  - `cancel_remittance_run` is refused `transfer_already_debited`;
  - the alert lists y as `ordered`;
  - then the LP books the line: y is cancelled and the run is booked.
- L2: the same line resolved otherwise (decided a duplicate): the hold lifts.
- L3: the refund twin. q0 is cancelled with its file, q1 is ordered, and an N line is at q0's amount:
  - q1 is held;
  - `cancel_refund` is refused `already_debited`;
  - linking the line to the refund executes it and books q1.
- L4: the sweep. S1 is cancelled, and an N line to our own IBAN is at S1's amount:
  - D4 gives `cancelled_sweep_debited`;
  - S2, made after S1's cancellation, is held;
  - then `unplanned_sweep(S1)` (K) is booked, and B resumes the proposals once new servicer money is settled.
- L5: these lines do not hold:
  - a line dated before x's execution date;
  - a line at another amount;
  - an N line with another counterparty IBAN;
  - an O line to another IBAN;
  - an E0 line naming another lot of ours.
- L6: t in its live downloaded file, executed by an N line. t is not « debited before », and the re-download of its file
  behaves as today.
- L7: re-run 028–038. Any changed outcome is listed in §3.3 with its reason.

**Mutants:**

| Mutant | Killed by |
|---|---|
| the arm removed | L1, L3, L4 |
| the depth/cancelled condition dropped | L6 |
| the date bound dropped | L5 |
| the IBAN filter dropped | L5 |
| the exclusions dropped | L2 |

### M. (new) Holds beyond the replaces chain: the client's next payout, the payment's next refund

**Today:** `transfer_hold_reason` (`20261115090000:1587`) holds a payout or a refund only through its own chain
(`transfer_debited_before`). `payout_not_covered` does not help either: an unbooked debit leaves the client's 4670
untouched.

**Path (critic 1-3), switch on:**
1. x is cancelled alone out of a live file F1 (refused by the bank).
2. R1 is cancelled. That passes, because no line exists yet.
3. R2 is approved with R1's released items, and z is ordered.
4. x's late debit then arrives, with its RMT id, as a batch line, or as a line carrying none of our references. z is not
   in x's chain, so it is not held. Generation files z, its download is served, and R1's items are paid twice.

6b-2 expects ops to cancel R2 before `unplanned_payout(x)` (`client_run_cancellable`, `20261117110000:854`), but nothing
stops generation in the meantime.

The refund twin: r1's transfer is cancelled after download and r1 is cancelled. r2, a refund of the same payment, is
ordered. Then r1's late debit arrives, and r2 is filed: the debtor is refunded twice.

**Change:**
1. **The payout branch of `transfer_hold_reason`.** After `already_debited`, the hold is `client_payout_debited_late`
   when a cancelled payout x′ meets all of these:
   - it is of the same client (`bank_transfer.client_organization_id`) and currency;
   - it was an item of a file downloaded at least once;
   - it is not in t's chain;
   - its run is not `approved`/`sent`;
   - `private.transfer_late_debit_open(x′)` holds.

   When x′'s run is `approved`/`sent`, its late line pays that run (E), and the per-client cap already counts that run
   as in flight. Holding t would then only delay the client.
2. **The refund branch.** After `already_debited`, the hold is `payment_refund_debited_late` when another refund request
   of t's payment has, in its transfer's chain, a transfer that meets all of these:
   - it was an item of a file downloaded at least once;
   - it is `cancelled` since;
   - `transfer_late_debit_open` holds for it.
3. **The download re-checks.**
   - In the generated branch, these holds give a blocked row, then `file_blocked` and the supersede. The payout or the
     refund is re-queued, and then held.
   - In the downloaded/sent branch, `holds_debited_transfer` also fires for such a transfer, with the reason in the
     blocked detail.
   - `run_transfer_checks`' `transfer_already_debited` branch lists such in-flight payouts and refunds, `ordered` or
     `in_file`. Its details are `reason`, and the cancelled transfer's id (« demandez à la banque de ne pas l'exécuter »).
4. **Keyed.**
   - The cancelled payouts are read by client, through a new partial index `bank_transfer_client_cancelled_idx on
     public.bank_transfer (client_organization_id, currency) where kind = 'payout' and status = 'cancelled' and
     transfer_file_id is not null`. The build checks that no existing index serves first: `bank_transfer_payout_iban_idx`
     does not lead with status.
   - The refunds are read by `refund_request.payment_id`.

**Exit.**
- **For a payout:** ops cancel R2, which is allowed while z is ordered, because `transfer_debited_before(z)` reads the
  chain only. They then book x′'s line `unplanned_payout(x′)`: 6b-2's `client_run_cancellable` rule asks for exactly this
  order. The hold lifts.
- **For a refund:** ops link or book r1's line.
  - When the line carries none of our references and r2's transfer is ordered, linking it to r2 executes r2 (D7). That
    is the right money outcome, since the debtor was refunded once.
  - When it carries r1's RFD id, it is S25 (no booking kind yet), and r2 stays held. Ops can cancel r2.

**Tests (039 M):**
- M1 (the G1c state, then z ordered):
  - generation holds z `client_payout_debited_late`, and the alert lists z;
  - ops cancel R2, then book `unplanned_payout(x)`;
  - the hold lifts for the client's next run R3.
- M2: the same with x′'s late line carrying none of our references (L).
- M3: x′'s run still `sent` (E's state): z of another run is not held.
- M4: z already in a generated file when x's late debit arrives. The first download supersedes the file, and z is held.
  z in a downloaded file: its re-download is refused, and z is alerted `in_file`.
- M5: the refund twin, both with r1's RFD line and with a line carrying none of our references.
- M6: another client's payout is not held (pins the client key).

**Mutants:**

| Mutant | Killed by |
|---|---|
| the payout rule removed | M1 |
| the run-live exclusion removed | M3 |
| keyed on the servicer instead of the client | M6 |
| the refund rule removed | M5 |
| the re-check left out of the download | M4 |

### N. (new) The cancellation evidence sees debits carrying none of our references

**Today:** `private.transfer_cancel_evidence` (`20261115090000:1435`, the latest; stable, security definer,
`search_path ''`, `enable_seqscan off`) sets `debit_seen` only from our references:
- **the file branch** (`:1460–1480`): a debit carrying one of the file's PmtInfIds, or a transfer's own e2e, or a booked
  transfer;
- **the one-transfer branch:** its own e2e, and the batch lines of its PmtInf.

`statement_covers` (`:1072`) counts CSV statements as cover. Take a file the bank executed on a CSV-fed account, by class-N
lines that are not booked yet (those are never booked automatically). After the window,
`request_transfer_file_cancellation` and `confirm_transfer_file_cancellation` pass, even with the attestation
`not_uploaded`. Then `transfer_file_release` (`:1669`) re-issues every payout and refund, so each is paid twice, and the
sweep is recomputed and swept again.

The one-transfer commands do the same for a camt.053 entry without an EndToEndId, once another member's ids satisfy D2.
This needs an ordinary action, with four eyes and the evidence the page shows: high (critic 1-1).

**Change:**
- A new key `unreferenced_debit` (boolean) and `unreferenced_from` (the earliest such line's date), and a new refusal
  **`unreferenced_debit_open`**, placed after `debit_seen` and before `batch_ambiguous`:
  - **file branch:** it is set by either of these:
    - any in-file payout, refund or sweep of the file (`transfer_file_id = f`, `in_file`) for which `exists (select from
      private.transfer_unreferenced_lines(t))` (L: dated on or after its execution date);
    - an unresolved debit carrying none of our references, dated in [`first_execution_date`, today], whose amount equals
      one PmtInf's open sum: a bank ignoring `BtchBookg false` on a CSV (OQ-83). This is keyed by (account, amount) once
      per PmtInf of the file.
  - **one-transfer branch:** `exists (select from private.transfer_unreferenced_lines(t))`.
- The confirmation recomputes the evidence, as today, so a line imported between the request and the confirmation
  refuses the confirmation.
- Critic 1-1 suggested reusing `transfer_debit_suppression`. It is not used here. Its reference-less arm ignores the IBAN,
  and its `'waiting'` depends on `transfer_line_offers` and on a day bound. The evidence needs L's plain keyed fact.

**Trade-off** (OQ-80 (p), Q5): a coincidental debit of the same amount blocks the cancellation until it is classified.
If rule 3b leaves it ambiguous, the file stays « en cours », as it does with the switch off today (OQ-81). The sentence in
m2c-6b-plan §3.3, « subsumed by D3/E2/G1 », is corrected: it was true only for lines carrying our references.

**Tests (039 N):**
- N1: a CSV-fed file executed by N lines, one per transfer, with the window covered:
  - the request is refused `unreferenced_debit_open`, and nothing is re-issued;
  - the evidence card's `unreferenced_from` is the lines' date.
- N2: after the lines are booked as payouts (rule 3b (i)), the request is refused `debit_seen` (booked transfers).
- N3: a line at another amount, or before the window: allowed.
- N4: the one-transfer branch, on a camt.053 entry without references, another member's ids satisfying D2: refused.
- N5: the batch-sum variant.
- N6: a line imported between the request and the confirmation: the confirmation is refused.
- N7: the attestation `not_uploaded`: refused alike.

**Mutants:**

| Mutant | Killed by |
|---|---|
| the key removed | N1, N4 |
| the batch-sum arm removed | N5 |
| the date bound dropped | N3 |

## 3. Tests

### 3.1 034
Remove the four `select todo(…)` lines (2 + 2 + 2 + 1). Every assertion stays, and `plan(18)` is unchanged. No scenario
needs a booking (prototype, re-run with A's final body).

### 3.2 `supabase/tests/039_switch_on_followups.test.sql`
- The file uses the 034/037 fixture style: the pg_temp helpers copied, and `pg_temp.isolated` scenarios.
- It adds one CSV-fed client_funds account fixture (`feed 'csv'`) for the L, M, N and D9 scenarios.
- Each scenario switches the flag on inside its own subtransaction, and the file asserts at its end that the flag is off.

**Scenarios,** with the expected result of each given above:
- A1–A4, A′1–A′3, A-batch; B1–B4; C1–C4; D1–D9;
- E1–E8 and E4b; F1–F7 and F5b; G1–G3; H; I1–I6; J; K1–K4;
- L1–L7; M1–M6; N1–N7.

**RLS and grants:**
- `sweep_after_debited_cancelled`, `cancelled_refund_line_may_be`, `transfer_unreferenced_lines` and
  `transfer_late_debit_open` are not executable by `anon`, `authenticated` or `service_role` (42501).
- `cancellation_after_download()` answers the flag to a servicer member, of any role, and false to a client user and to
  `anon` (§4).
- The command at aal1, or as a collector, is refused.

That is roughly 100 tests. Each case is written first and seen failing on `b795713` (WIP commit), except the
« unchanged » pins. G4 and the two-connection cases are worker integration tests.

### 3.3 Assertions whose expected value changes

Each change is a switch-on test state, justified in the ADR (R3). No assertion is removed.

| Test | Expected now | Expected after this slice | Why |
|---|---|---|---|
| 030 #27 (D4) | the blocked array holds Lilas's payout | it also holds `<sweep> cancelled_sweep_debited` | A (prototype) |
| 037 D (F6) `still_live_options` | `"run_still_live"` (`->> 'refusal'`) | `null`: the options propose `payout(y)` (LP) and refuse nothing (critic 2-7) | E |
| 037b `s_s02_live` | `{"proposals": 0, "refusal": "run_still_live", "detail": true, "command": "run_still_live", "run": "sent", "bookings": []}` | `{"proposals": 1, "refusal": null, "detail": null, "command": "run_still_live", "run": "sent", "bookings": []}`: the proposal is `payout(v_5) + payout(v_6 LP)`; `refusal_detail` is null, and null = text gives null (critic 2-7); the command asks `unplanned_payout(v_6)`, still refused | E |
| 038 `h_released` `x_live` | `run_still_live` | `reissue_in_downloaded_file` (y2 is in a downloaded file) | E |
| 037 D (F4) | `x2 → paid 5400, advance 24600` | `paid 0, advance 30000`, `attributed [[24600,1]]` | J |

The command's `run_still_live` for `unplanned_payout` on a live run stays asserted where it is: in 037 F6 `still_live`,
and in 037b's `command`.

**This list is provisional for E–N** (critic 2-7). Only A, C and D were prototyped. L widens `transfer_debited_before`,
and K adds candidates, so any switch-on state of 028–038 that holds a line without our references at a cancelled
transfer's amount may change. The build re-runs 015–039 after each item (§9). Each changed outcome is added here with its
reason, and to the ADR, before the PR. An outcome that changes for a reason this plan does not give is a bug, not an
edit.

### 3.4 Re-run
All of `supabase test db` (015–039), after each item.

### 3.5 Worker
- `HELD_TO_SQL` parity (F2).
- The `unplanned_p` twin and its property (J).
- The new LP integration file (E, G4, the two-connection cases).
- `test_transfer_files_scale_integration.py`: the nightly checks with 5,000 booked and 50 cancelled transfers stay under
  5 s (C, I, L, M). It also times generation's holds (L, M) and the evidence (N) on that fixture (critic 1, missing
  tests).
- `ruff`, `ruff format --check`, `mypy --strict`, the unit and integration tests, and eval.

### 3.6 Web
- Vitest for every on/off text (§4).
- The round-5 sweep (`transfers.test.ts` « M2c-6a review, round 5 ») is extended: no on variant contains « pas encore
  disponible », « ne peut pas être annulé d'ici là », « pas encore être annulé » or « ne peut pas encore être
  comptabilisé ». The off variants' assertions stay untouched.
- Each new or changed function, put back alone, fails a test.

### 3.7 E2E and screenshots
A serial Playwright project, `switch-on.spec.ts`. In its setup it asserts that the flag is **off** (critic 2-15), then
turns the flag on through `psql`, committed on the local stack only. It turns it back off in teardown, and runs after the
other projects.

It builds an LP from « Débits et retours » and takes these screenshots, mobile and desktop:
- `m2c-debit-reversement-annule`, the LP sheet;
- `m2c-reversement-debite-en-retard`, the run page;
- `m2c-virement-telecharge`, retaken: the cancellation card offered;
- `m2c-annulation-debit-sans-reference`, the card refusing `unreferenced_debit_open` (N).

The off pages are unchanged and are not retaken. **Risk:** the flip must never leak. The teardown is in `finally`, and
the project asserts the flag off at its start and at its end.

## 4. Texts (§4.2): written for the switch off, and given their « on » variants

**How the pages read the flag.** Through a new read, `public.cancellation_after_download() returns boolean`: stable,
security definer, `search_path ''`.
- It returns `private.switch_on('downloaded_file_cancellation')` to **any member of a servicer organization**, of any
  role and any aal, and false to everyone else (critic 2-12).
- The payment page uses `staffSession`, collectors included. A money-staff-only read would show them the off texts while
  the switch is on.
- The flag is configuration, not tenant data, and `transfer_file_detail` already exposes it.
- It is granted to authenticated, and revoked from public and anon.
- The pages already reading it (`transfer_file_detail`, `transfer_overview`) keep their field.

**The rules:**
- every off text below is **unchanged**;
- each on text is new, chosen as `text(on)`, and vitest-tested;
- the client page reads per-run facts, never the flag;
- the build polishes the wording, not the meaning.

| # | Source (b795713) | Shown | On variant (French copy) |
|---|---|---|---|
| T1 | `lib/boarding/forms.ts:263` `PAYOUT_NOT_EXECUTED` | in T4 | « … n'apparaît sur aucun relevé : une fois importés les relevés de son jour d'exécution et du jour ouvré suivant, sans son débit, son annulation, ou celle de son fichier, peut être demandée, relevés à l'appui, puis confirmée par une autre personne. » (critic 2-13: D1, D2 and `batch_ambiguous` may still refuse it, so the text says « peut ») |
| T2 | `forms.ts:266` `FILE_TRANSFER_NOT_EXECUTED` | in T7, T12 | the same, for the file or one of its transfers |
| T3 | `forms.ts:283` `REFUND_NOT_EXECUTED` | in T5, T11 | the same, « … puis le remboursement annulé ou réémis » |
| T4 | `forms.ts:503` `run_already_sent`, `:602` `run_payout_in_downloaded_file` | run page refusals | « Le virement de ce reversement est dans un fichier déjà téléchargé : pour annuler le reversement, faites d'abord annuler ce virement depuis la page du fichier (« Virement refusé par la banque » ou l'annulation du fichier, relevés à l'appui, confirmée par une autre personne) ; sinon il reste en cours jusqu'à ce que son débit soit comptabilisé depuis le relevé (${PAYOUT_BOOKED_WHEN}). » |
| T5 | `forms.ts:609` `refund_in_downloaded_file` | payment page | the refund's analogue of T4 |
| T6 | `forms.ts:516–517` `credit_note_in_flight`, `credit_note_run_in_flight`; `lib/remittance/credit-notes.ts:114,116` | credit-note page | « … ensuite il ne peut l'être qu'une fois son virement annulé, relevés à l'appui (deux personnes), ou son débit comptabilisé depuis le relevé (…) » |
| T7 | `forms.ts:565` `transfer_cancellation_request_required` | file page | raised **only with the switch on** (`cancel_transfer_file`, `20261116090000:4758`), so today's text is false whenever it shows. On: « Ce fichier a été téléchargé : il ne se remplace plus d'un clic. Demandez son annulation, relevés à l'appui ; une autre personne la confirme. » The off text is kept (unreachable) |
| T8 | `lib/remittance/transfers.ts:860` `DOWNLOADED_FILE_NOTE` | file page, only `!cancellable` | none: the on page shows the cancellation card |
| T9 | `transfers.ts:867` `runPayoutInDownloadedFileNote(file)` → `(file, on)` | run page | « Le virement est dans le fichier TF-…, déjà téléchargé : pour annuler ce reversement, faites d'abord annuler ce virement depuis la page du fichier (relevés à l'appui, confirmée par une autre personne). S'il est exécuté, son débit est comptabilisé depuis le relevé (…), puis, si la banque du bénéficiaire le renvoie, son retour. » |
| T10 | `transfers.ts:875` `payeeMismatchFollowUp(cancellable)` | file page | already has both variants: unchanged |
| T11 | `lib/payments/debits.ts:1410` `refundInDownloadedFileNote(file)` → `(file, on)` | payment page | as T5 |
| T12 | `debits.ts:1063` `file_not_marked_sent` help | « Contrôles » | « … s'il ne doit pas partir, demandez son annulation depuis sa page, relevés à l'appui (deux personnes) ; un fichier jamais déposé n'apparaît sur aucun relevé : son annulation peut être demandée une fois les relevés de son jour d'exécution et du jour ouvré suivant importés. » |
| T13 | `debits.ts:228` `CANCELLED_TRANSFER_LIVE_RUN` | « Débits et retours » | **false once E ships, both ways.** Replaced by texts chosen from the options' `cancels_transfer_id` and `supersedes_file_number` (critic 2-10). See the variants listed below the table |
| T14 | `debits.ts:162` the `cancelled_transfer_debited` review text | « Débits et retours » | kind-aware, both ways (critic 2-11). See the variants listed below the table |
| T15 | `debits.ts:1090` `transfer_already_debited` help | « Contrôles » | both ways, with its last sentences by case (critic 2-11). See the variants listed below the table. « prévenez le support pour rattacher » goes: it is false once E and B ship |
| T16 | `lib/payments/transfer-lines.ts:30` `transfer_cancelled`, `:56` `run_still_live`; the LP decision label and sheet sentence; the new codes `cancelled_transfer_matches`, `client_payout_debited_late`, `payment_refund_debited_late`, `unreferenced_debit_open` | « Débits et retours », file page, « Contrôles » | see the variants listed below the table |
| T17 | `lib/remittance/documents.ts:130` « Annulé avant la remise de son virement à la banque » | client space | a per-run fact from `client_remittance_summary`, `transfer_outcome`, keyed on what the chain's files and transfers show, never on the download count alone (critic 2-9). See the variants listed below the table |
| T18 | `lib/remittance/runs.ts:346,369` `runPayoutNotes`; `transfers.ts:1069` `transferBookingText` | run page, « Virements » | LP: « Débité de notre compte le … (virement annulé, exécuté en retard par la banque) »; the returned note also for a cancelled transfer with `returned_on`; « Virements »: « Annulé — exécuté en retard par la banque le …, comptabilisé comme le débit de son reversement » [« , revenu impayé le … »] |
| T19 | `forms.ts` `transfer_file_holds_debited`; the SQL hint of `holds_debited_transfer` | file page | both ways, true for a sweep and for M's holds: « Un virement de ce fichier a peut-être déjà quitté le compte (débité sous la référence du virement qu'il remplace, dans une ligne groupée de son lot ou sans référence), ou un virement annulé du même client ou du même paiement a été débité en retard, ou la quote-part du cabinet de ce fichier a déjà été virée par une quote-part annulée exécutée en retard : … » |
| T20 | SQL hints | API callers | new: H-PAY (D, by feed); the LP refusals and the new hold codes carry no hints (the web words them). The existing switch-dependent hints (`cancel_remittance_run`, `refund_transfer_follow`, the five commands) already have both variants and are unchanged; 033 reads the off ones |

**T13: the two texts that replace `CANCELLED_TRANSFER_LIVE_RUN`.**
- **LP proposed:** « Débit d'un virement annulé dans Collectoo : la banque l'a peut-être exécuté en retard. Son reversement
  est toujours en cours : si ce débit est bien ce virement (vérifiez-le auprès de la banque quand la ligne ne porte pas sa
  référence), comptabilisez-le comme « Débit d'un reversement » : le reversement est comptabilisé comme payé. » Then,
  by case:
  - y ordered: « Son virement de remplacement, pas encore remis à la banque, est annulé. »
  - y in a generated file: « Son virement de remplacement est annulé et retiré du fichier TF-… ; les autres virements de
    ce fichier repassent dans le prochain fichier. »
  - y = x, or y already cancelled: no sentence about a replacement.
- **Refused `reissue_in_downloaded_file`:** « … son virement de remplacement est dans le fichier TF-…, déjà téléchargé :
  demandez à la banque de ne pas l'exécuter, faites annuler ce fichier, relevés à l'appui (deux personnes), puis
  comptabilisez ce débit ; si le remplacement est débité malgré tout, comptabilisez ce débit-là comme « Virement hors
  reversement ». »

**T14: the review text for `cancelled_transfer_debited`, by kind.**
- **Payout:** « … comptabilisez-le avec « Comptabiliser… » : comme le débit de son reversement s'il est encore en cours,
  sinon comme « Virement hors reversement » (risque de double paiement). »
- **Sweep:** « … comptabilisez-le comme la quote-part annulée débitée (« Virement au compte propre » de cette quote-part ;
  review round 1, pages-texts-1: the label the sheet shows) :
  aucune autre quote-part n'est virée d'ici là. »
- **Refund:** « Débit d'un remboursement annulé : il ne peut pas encore être comptabilisé ; ne refaites pas ce
  remboursement, voyez avec la banque et prévenez le support. »

**T15: the last sentences of the `transfer_already_debited` help.**
- **Transfer ordered or held:** « Ne refaites aucun virement ; comptabilisez le débit dans « Débits et retours »
  (« Comptabiliser… ») : la retenue cesse ensuite. »
- **Transfer in a downloaded file:** « Demandez à la banque de ne pas l'exécuter, faites annuler ce fichier, relevés à
  l'appui, puis comptabilisez le débit. »
- **Sweep:** « … tant que le débit de la quote-part annulée n'est ni comptabilisé ni revenu. » The current « tant qu'une
  quote-part annulée débitée n'est pas revenue » is false after B.

**T16: the line refusals, the LP label and the new codes.**
- **`run_still_live`:** « … ce débit est le paiement de son reversement (RV-…) : comptabilisez-le comme « Débit d'un
  reversement » ».
- **LP sheet:** « Débit d'un reversement — virement annulé, exécuté en retard : le reversement RV-… est comptabilisé
  comme payé le jj/mm/aaaa », then T13's sentence for y by case. It never says that a replacement already handed out can
  no longer leave the account (critic 1-8).
- **`cancelled_transfer_matches`:** « Ce débit peut être l'exécution tardive d'un remboursement ou d'une quote-part
  annulés après téléchargement : il ne peut pas être comptabilisé comme un autre virement. Demandez à la banque le détail
  de ce débit. »
- **`client_payout_debited_late`:** « Retenu : un virement annulé de ce client a été débité en retard (relevé du …) ;
  comptabilisez ce débit d'abord (« Débits et retours »), après avoir annulé ce reversement s'il reprend les mêmes
  encaissements. »
- **`payment_refund_debited_late`:** « Retenu : un remboursement annulé de ce paiement a peut-être été exécuté en retard
  (relevé du …) ; rattachez ce débit d'abord, ou annulez ce remboursement. »
- **`unreferenced_debit_open`:** « Le relevé montre, depuis le …, un débit sans nos références du montant d'un virement
  de ce fichier, pas encore comptabilisé : il peut en être l'exécution. Comptabilisez-le ou classez-le d'abord dans
  « Débits et retours » (avec le détail de la banque s'il le faut). »

**T17: the client space's text for a cancelled run.**

| `transfer_outcome` | When | Text |
|---|---|---|
| `never_handed_out` | no chain transfer was in a file downloaded at least once, or every such file was closed `not_uploaded` | the off text, unchanged and true (never deposited) |
| `not_executed` | a chain file was closed `rejected_by_bank`, or a chain transfer was cancelled alone out of a live downloaded file | « Annulé : la banque n'a pas exécuté son virement (les relevés ne le montraient pas débité) » |

`unplanned_runs` keeps its text. Each variant is vitest-tested.

Each of these pages calls `cancellation_after_download()` once: the run page, the payment page, the credit-note page,
« Contrôles » and « Débits et retours ».

## 5. The migration (`20261118090000_switch_on_prerequisites.sql`)

Forward-only. No table change. Two new partial indexes, each added only after the build checks that no existing index
serves:
- `bank_transaction_debit_amount_idx (bank_account_id, amount_minor) where direction = 'debit'` (L, N, D);
- `bank_transfer_client_cancelled_idx (client_organization_id, currency) where kind = 'payout' and status = 'cancelled'
  and transfer_file_id is not null` (M).

A further index on the cancelled filed sweeps comes only if the read bounds of 039 C/K show a scan.
`bank_transfer_cancelled_filed_idx` already leads with `organization_id`.

**Order:**
1. **The indexes**, then the new helpers: `transfer_unreferenced_lines`, `transfer_late_debit_open`,
   `sweep_after_debited_cancelled`, `cancelled_refund_line_may_be` and `cancellation_after_download`.
2. **The redefinitions,** in dependency order:
   - `transfer_debited_before`, `debited_cancelled_sweeps`;
   - the candidates, then the check, the options, the locks, the post, `post_rows`, `parts_json`, the text and the guard;
   - `transfer_line_returnable` and `pending_item_deadlines`;
   - the evidence (`transfer_cancel_evidence`);
   - the checks (`run_transfer_checks`, `run_remittance_runs_checks`, `run_payment_checks`);
   - the summary and the payout read;
   - the release, the generation, the download and the hold;
   - `refund_transfer_follow` and `debit_link_options`.
3. **The privileges block,** restating the latest grants and revokes of each function, and revoking the new helpers.

**The header** lists every function redefined, with its source file, and says that the switch is not touched. **No
statement writes `private.feature_switch`.** The database types are regenerated, since the new public read changes them.

**Size.** The redefinitions are large: `transfer_line_check`, `run_transfer_checks` and `transfer_file_download` are each
several hundred lines. If the migration passes about 2,500 lines, the build stops after §9 step 2's first group (L, N,
A, B, C, D, K, M with 034 and 039 A–D, K–N) and proposes splitting off E–J as 3a-2 (switch still off). 6b-3b needs
both.

## 6. Docs

- **ADR-0014:** a new section, « M2c-6b-3a: switch-on prerequisites (switch still off) ». It records:
  - the decisions of A–N, with the timestamp rule (the sweep's `created_at` and the booking entry's `posted_at`);
  - L's arm, and its deviation from round 4's « final statement » default;
  - the LP state model and the lock re-read after the remit lock;
  - H-PAY's account-wide scope, J's conservative default, K's widening, M's holds and N's refusal;
  - the changed assertions of §3.3, each with why;
  - the mutants, with what killed each;
  - deviations from m2c-6b-plan §3, among them 033 left for 6b-3b, 039 as the follow-ups file, and L/M/N added.
- **COMPLIANCE:**
  - **OQ-80:**
    - (n) gets H-PAY's account-wide rule and its payment-only alternative, K's iv refund (S25's twin), and the residual
      of the feed without our references (D);
    - (i) and (m) get the LP exit;
    - (k) gets L's arm;
    - (o) gets the re-download residual;
    - a new **(p)** for L and N: a debit carrying none of our references, at a cancelled or in-file transfer's amount,
      holds and blocks a cancellation until classified. It records the trade-off, and the bound to set once the bank
      answers founder #15 (the latest day it can debit).
  - **OQ-81:** (a) stays open (Q1); (b) stays open, and now lists the three S25-bucket states of §1.
  - **OQ-82:** the known limit is closed by J's default; the VAT share stays open for counsel.
  - **CPCE-08:** the R124-6 rows of a re-issue, and of a run whose payout was cancelled alone (I).
  - **SEPA-01**, if the wording changes.
- **DOMAIN:**
  - « Débit tardif d'un virement annulé (prédécesseur tardif) »;
  - « Quote-part retenue » (A);
  - « Débit sans nos références » (L).
- **Design:**
  - `docs/design/m2c-remittances.md` §9.7, and §15's alerts and holds;
  - `docs/design/m2c-6b-plan.md` §1.2, with a note: 6b-3 is split into 3a (prerequisites, switch off) and 3b (the switch,
    and 033 inverted);
  - `docs/design/m2c-6b-plan.md` §3.3's « subsumed » sentence corrected (N).
- **ROADMAP M2c-6b:** SW2/SW3, G1c, H-PAY and the texts are met with the switch on in tests; the switch remains (6b-3b).
- **`docs/benchmarks/remittances.md`:** the nightly checks, the generation holds and the evidence timings (C, I, L, M,
  N).
- **`docs/PROGRESS.md`:** not edited (the workflow's rule).

## 7. Risks

| Risk | Prevention |
|---|---|
| SW comparisons wrong in production, because `created_at` and `decided_at` are `now()` | the sweep's `created_at = v_now` (clock) under the remit lock; bookings compared by their entry's `posted_at` (clock); the 034 prototype proves the test needs it |
| LP deadlock, with y's file superseded under the booking | y and its file re-read after the remit lock, the file `FOR UPDATE` at step 8 in id order; `split_changed` when y's file is not the one the caller saw; two-connection integration tests (generation committing between key collection and the remit lock; download) |
| LP books while y can still execute | refused while y is in a downloaded or sent file (the G2 twin); y cancelled in the same transaction otherwise; E4b's residual worded and tested |
| A cancelled transfer's late execution carries none of our references | L: every hold and guard sees it; N: the evidence sees it; M: the client's and the payment's next transfers |
| False holds from coincidental amounts (L, M, N) | keyed on amount, date ≥ execution date, IBAN when given, unresolved only; the exit is classifying the line; Q5/Q6; OQ-80 (p) |
| Stuck states on a feed without our references (D, N) | alerted (`bank_line_unbooked`, C); exit by the bank's detail and support until OQ-81 (b); named in Q1/Q2 |
| A reader still treating a cancelled transfer as unpaid | F's table, built from a re-grep of `entry_id`/`return_entry_id` readers, each with a test; I20 nightly catches any miss |
| Nightly cost: C, I, L and the sweep alert scan every cancelled filed transfer, and that history grows | one shared `materialized` CTE; keyed laterals with `offset 0`; the scale test with 50 cancelled and 5,000 booked under 5 s; a date bound once the bank answers founder #15 (OQ-80 (p)); the volume CI (`scale`, `scale-payouts`) dispatched on the branch, since transfer files and payout bookings are timed paths (CLAUDE.md) |
| J changes P for existing pinned cases | only cross-transfer attributions change; 037 F4 named (§3.3); the property test is the oracle |
| L/K change outcomes in 028–038 not foreseen | re-run 015–039 after each item; every change listed in §3.3 and the ADR before the PR, or treated as a bug |
| A switch-on test state leaking (E2E) | serial project, the flag asserted off at its start and at its end, the flip back in `finally`; never in a migration |
| Silent test edits (R3) | §3.3 is the complete list once the re-runs are done; every other assertion stays byte for byte; the ADR names each |
| Redefinitions copied from a non-latest body | the per-function file:line above, re-grepped at build time; the migration header lists the sources; a diff of each body against its source shows only the planned lines |
| Slice size past ~2,500 migration lines | the split point in §5 |

## 8. Founder questions (« 1 ok, 2 b … »; each default is built and stays open)

1. **Turn on cancellation after download (6b-3b)?** (OQ-81 (a))
   - **a (default):** yes, by its one-line migration, once this PR is merged and 034 passes with no `todo()`. These stay
     open, each held or alerted, never booked:
     - S06;
     - S25 and its twins (§1);
     - the feed-without-references stuck states (D, N), whose exit is the bank's detail and support.
   - **b:** no. Refused payouts stay « en cours » beyond R124-6's month.
2. **A debit without our references, and a refund still in a downloaded file** (H-PAY, OQ-80 (n)).
   - **a (default):** it does not execute that refund if a cancelled refund **of the same account and amount** (any
     payment) was in a downloaded file, unless the refund's transfer is not handed out yet. On a feed without our
     references, such a refund and its line then stay « en cours » until the bank details the debit (support, OQ-81
     (b)).
   - **b:** only an earlier refund of the same payment blocks (034's minimum). The same line can then execute another
     payment's refund while it may be the cancelled one: that debtor may be refunded twice.
3. **The same sums repaid by two late transfers** (OQ-82).
   - **a (default):** a sum already deducted after the first late transfer is not deducted again. The second is wholly an
     advance by the firm, recovered only under the claw-back clause, otherwise by a repayment request (M2c-7).
   - **b:** deduct again up to the gross. The commission share would then be withheld from the client's other
     collections, with no clause.
4. **A debit without reference that may be the late execution of a cancelled refund or share** (K).
   - **a (default):** it is never booked as another payout without the bank's detail (« ambigu »). A cancelled share
     alone is booked as that share's late debit.
   - **b:** it is booked as the payout in progress, as today.
5. **A debit without our references, at the amount of a cancelled transfer or one in a file** (L, N; OQ-80 (p)).
   - **a (default):** it counts as a possible late execution until classified. It holds the replacement and the run's
     cancellation, and it refuses the file's cancellation.
   - **b:** only debits carrying our references count (today). On a CSV feed, a transfer executed late can then be paid
     twice.
6. **Holds beyond the transfer's own replacement** (M).
   - **a (default):** while a cancelled payout of a client (its run ended) shows an unbooked late debit, the client's
     other payouts are held. Likewise for a payment's other refunds.
   - **b:** alert only. Generation may then pay the same collections twice before ops act.

Questions 2–16 of the 6b-2 plan keep their defaults and stay open. S06 (Q9) and S25 (Q2) wait for a later slice.

## 9. Order of work

1. **Tests first:**
   - 034 without `todo()`;
   - 039 (A–N);
   - the §3.3 changes;
   - the worker parity, twin and property tests;
   - the LP integration file;
   - the vitest texts.

   See them fail on `b795713`, then make a WIP commit.
2. **The migration, by group, re-running 015–039 after each item and updating §3.3:**
   - L (with its index), then K, then N;
   - then A (re-run 034 with A's final body first), A′, B, C and D;
   - then M (with its index);
   - then E, F and G;
   - then H, I and J.
3. **The worker twins,** then the web texts and reads.
4. **The mutants** (§2), each killed. The runs are not kept in the repository.
5. **Docs** (§6).
6. **Full runs:**
   - `make reset`;
   - `supabase test db` (all files);
   - worker lint, unit, integration and eval;
   - web lint, `tsc` and vitest;
   - E2E with screenshots;
   - the scale files for transfer files and payout bookings;
   - the CI volume run dispatched on the branch before merging.
7. **Squash commit and PR** (« what, why, how tested, open questions »).

## 10. Critics

Each finding is accepted or rejected, with the reason. The code claims were checked against `b795713`.

**Double payment and money (critic 1).**

| # | Finding | Verdict | Reason and where it goes |
|---|---|---|---|
| 1-1 | High: the cancellation evidence does not see reference-less debits; a CSV-fed file executed by N lines is cancelled and re-issued | **Accepted** → N | Confirmed: `transfer_cancel_evidence` (`20261115090000:1460–1480`) sets `debit_seen` only from our references, and `statement_covers` counts CSV. It needs an ordinary four-eyes action. Built on L's keyed fact, not on `transfer_debit_suppression` (its reference-less arm ignores the IBAN, and its `'waiting'` depends on offers and on a day bound). The §3.3 « subsumed » sentence is corrected |
| 1-1 (low) | The re-download `file_executed` branch has the same blindness | **Rejected for this slice**, recorded | It is switch-independent and the page warns. A false block would stop the only way to get back a lost file. OQ-80 (o) records it |
| 1-2 | High: a reference-less late debit of a chain predecessor holds nothing | **Accepted** → L | Confirmed: `transfer_debited_before` (`:1221`) and `transfer_late_lines` (`20261117090000:825`) read own ids and PmtInf batch lines only. The arm is added inside `transfer_debited_before`, so every guard inherits it; it does not depend on `transfer_line_offers` |
| 1-3 | High: holds keyed on the replaces chain miss the client's next run and the payment's next refund | **Accepted** → M | Confirmed: `transfer_hold_reason` has no client or payment rule, and `cancel_remittance_run` lets R1 go once x is cancelled with no line (`20261116090000:5140–5150`). The exit is 6b-2's own order (cancel R2, then `unplanned_payout(x)`). The hold is restricted to cancelled payouts whose run ended: with the run live, E books the line and the cap counts that run |
| 1-4 | Medium: K's iv makes a cancelled sweep's reference-less late debit unbookable | **Accepted** → K revised | Confirmed: the unplanned_sweep with no transfer refuses `sweep_in_flight_matches` on a sweep candidate (`20261117110000:901`), and « iv alone → refused » would also refuse the one bound to S1. iv alone, a sweep, now books `unplanned_sweep(S1)`. iv alone, a refund, is S25's twin, recorded in OQ-80 (n) |
| 1-5 | Medium: H-PAY's payment scope is inconsistent with K | **Accepted** → D revised, Q2 | The line's amount must equal r2's to execute it, so « any cancelled refund of the account at that amount » contains the payment scope and closes the cross-payment double refund. It is refused only while r2's transfer is handed out: ordered, the link is the right outcome. OQ-86's return/loss rule is untouched |
| 1-6 | Low: the lock claim is wrong | **Accepted** → E.3 | Confirmed: generation takes the account row, allocation and remit locks, never the run (`20261116090000:331`), and `transfer_line_locks` collects keys before the remit lock. y is re-read after the remit lock, with `split_changed`, and a two-connection test is added |
| 1-7 | Low: A′ details; the prototype is per account | **Accepted** → A | Accounts of any status are read by organization. §0 states that the prototype validates neither A′ nor the late-line half, and the build re-runs 034 with the final body |
| 1-8 | Low: « y cancelled: nothing to do » leaves y's own late execution | **Accepted** → E4b, T16 | It is not refused: refusing would leave the run unbookable for good. y's later debit is an `unplanned_payout` advance, alerted by C, and the texts never claim that y cannot leave |
| 1 (tests) | CSV variants across items; scale timing of the new predicates | **Accepted** | L1–L7, M2, M5, N1–N7, D1/D9, C3; §3.5 times generation, download and the evidence |

**Tests and legal (critic 2).**

| # | Finding | Verdict | Reason and where it goes |
|---|---|---|---|
| 2-1 | High: a reference-less late predecessor still lets the re-issue be filed (the same as 1-2) | **Accepted** → L | Also covers the refund re-issue and the new sweep under D4. The E5 test variant is L1 |
| 2-2 (a) | Medium: I is date-blind | **Accepted** → I | It now reads per chain transfer, through `transfer_debit_suppression(x, L, today)`, which only reads lines dated up to L |
| 2-2 (b) | Medium: a run whose payout was cancelled alone gets no row | **Accepted** → I | Confirmed: `olc.proven` needs `ordered`/`in_file`. A cancelled run transfer is treated like a re-issue (I6) |
| 2-2 (c) | Tests and mutants for suppression and coverage | **Accepted** | I4–I6 and three mutants |
| 2-2 (low) | `batch_debit_may_hold` ignores bookings | **Accepted** | The suppression skips booked and linked lines |
| 2-3 | Medium: H-PAY on a CSV feed has no exit, and its hint is false there | **Accepted** as a residual | No exit is invented: it needs OQ-81 (b)'s four-eyes link on the bank's confirmation, which is open. The hint is chosen by the feed, the stuck state is pinned (D9) and alerted, and Q1/Q2 name it |
| 2-4 | Medium: F misses the run page's advances | **Accepted** → F | Confirmed: `20261117110000:3292` is keyed `cause_entry_id = x.entry_id`. The build re-greps every `entry_id`/`return_entry_id` reader (the list in F), and F5b tests it |
| 2-5 | Medium: the A′ test gap lets a per-account body survive | **Accepted** → A′2, A′3 | A per-account mutant is added |
| 2-6 | Low: 039 B does not kill its mutant | **Accepted** → B | Confirmed: D4 needs `v_sweep > 0` (`20261116090000:375`). New servicer money is settled after the booking, and S1's alert stops while S2's persists |
| 2-7 | Low: §3.3 incomplete; 037b `detail` → null; 037 F6 → null | **Accepted** → §3.3 | Confirmed by reading 037 (`:1995`, `:2004`) and 037b (`:1336–1362`). §3.3 is marked provisional for E–N and re-run after each item |
| 2-8 | Low: C's exclusion silences a chain whose live end was cancelled | **Accepted** → C | x is excluded only while its run's or refund's live end is `ordered`/`in_file` and holds x in its chain (C2) |
| 2-9 | Low: T17 is false for files never deposited | **Accepted** → T17 | Keyed on `close_attestation` and on the transfer cancelled alone (`transfer_outcome`). `not_uploaded` keeps the off text, which is true |
| 2-10 | Low: the T13/T16 LP texts assume a replacement and assert too much | **Accepted** | The texts are chosen from `cancels_transfer_id`, hedged for class N, and the file is « retiré », not « remplacé » |
| 2-11 | Low: T14/T15 are payout-only, or false after B | **Accepted** | Kind-aware variants, B's wording, and the downloaded-re-issue sentence |
| 2-12 | Low: `cancellation_after_download()` false for collectors and aal1 | **Accepted** | The flag goes to any servicer member. It is configuration, not tenant data |
| 2-13 | Low: T1–T3 overstate | **Accepted** | « son annulation, ou celle de son fichier, peut être demandée » |
| 2-14 | Low: I covers only day L | **Accepted** → I | Coverage is [e0, L] |
| 2-15 | Missing tests: SW batch line and SW cancelled alone; E3 `sent`; H-PAY same-file; LP return through the job; E6 statement; E2E flag at setup | **Accepted** | A-batch; E3 with `sent` (and a mutant); D8; G4; E6's first statement; §3.7 |

**Found while revising (beyond the critics).**
- **A's gate.** `transfer_debited_before(c)` cannot gate `sweep_after_debited_cancelled` once L's arm counts unresolved
  lines only: S2 would be released by booking S1's reference-less line. The gate is instead `transfer_late_debit_open(c)`
  or a booking posted at or after S2's creation (A.1).
- **`debited_cancelled_sweeps` stays per account.** Made servicer-wide, the alert branch that loops over the accounts
  would list each sweep once per account. D4 loops instead (A.6).
- **S25's bucket grows by three states** (§1). A cancelled refund's late debit can leave its payment's money free to be
  allocated again. That is not built here (S25's entries are not chosen), and it is named in Q1 and OQ-81 (b).
- **The slice's size** (§5 split point).
