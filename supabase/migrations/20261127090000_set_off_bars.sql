-- M2c-7d-2 « set-off bars » (plan docs/design/m2c-7-plan.md §6.2.2, §6.2.4–§6.2.6, §6.2.9, §6.2.11 with the withheld
-- kind and every redefinition it needs, §6.3's set_off_after_bar; ADR-0014 « M2c-7d-2 »). Forward-only.
--
-- What the servicer may set off of its own claims on a client (its commission invoices, its advances) once the
-- client's status is read — every rule the law does not fix is the servicer's default, never presented as the law's:
--   * the opening of the client's collective proceeding (private.client_opening_date, 7c-1's): the earliest
--     proceeding_opened or liquidation in effect — C. com. L641-3 al. 1 gives a liquidation judgment the effects of
--     L622-7 I al. 1 (read 2026-11-25, versions in force since 2019-05-24 and 2021-10-01);
--   * each claim's birth (private.document_born_on, default OQ-92): an invoice at the earliest collection it charges,
--     never its issue date; an advance at its birth;
--   * the bars per kind (private.client_set_off_barred): a liquidation (founder Q11: nothing set off, before or after
--     the judgment), a mandate's end (Q9: the clauses belonged to the mandate that ended), a standing seizure (Q12,
--     [critic] L14: CPCE L211-2 al. 1 « attribution immédiate au profit du saisissant de la créance saisie », C. civ.
--     1347-7 « La compensation ne préjudicie pas aux droits acquis par des tiers. »), and for advances a standing
--     proceeding (Q18, [critic] L4: L622-7 I al. 1, second sentence: « interdiction de payer toute créance née après le
--     jugement d'ouverture, non mentionnée au I de l'article L. 622-17 »; OQ-92);
--   * document_nettable: no bar for its kind and born on or after the opening (L622-7 I al. 1 excepts « le paiement par
--     compensation de créances connexes », which the code cannot tell apart: OQ-41 — none is set off, prudence).
-- Where it is read: the prepare's facts (private.prepare_set_off_facts, the births), the approval
-- (private.remittance_approval_refusal: a standing seizure refuses whatever N; client_status_changed when the opening
-- or the bars differ from the draft's, or the plan sets off a document barred that day), the hold before download
-- (private.transfer_hold_reason), the debit (private.post_run_settlements: the barred set-off posted and reversed at
-- once — the one exception to LG003, private.ledger_entry_guard, with its commit check ledger_entry_barred_reversed —,
-- its reversal a settlement_withheld item the next run pays back, held to the withheld run's R124-6 date and drafted
-- within the hour under its own trigger), the nightly (set_off_after_bar: a set-off an event recorded after the debit
-- reveals barred), what the client may pay (private.document_client_payable: an advance while a proceeding stands,
-- gap 11), how an advance is recovered (private.advance_recovery_of) and the repayment request (in_proceeding).
--
-- Redefined, each copied whole from its latest definition across every migration file (indexed: the last
-- `create or replace function` / `create function` of each name wins), only the change applied, SECURITY DEFINER,
-- every SET clause, search_path '' and the grants restated: private.document_before_opening, document_client_payable,
-- client_payment_docs, advance_recovery_of (20261124090000:1140, :1161, :1367, :1181), private.client_opening_on
-- (20261123090000:125), private.advance_repayment_refusal (20261125090000:258), private.ledger_entry_guard
-- (20261111090000:233), private.ledger_check_now (20261122090000:1149), private.ledger_posting_client_payable
-- (20261111090000:1252), private.remittance_record_draft (20261112090000:1087), private.remittance_approval_refusal
-- (20261125090000:787, 7c-2's with its enable_seqscan off), private.transfer_hold_reason (20261118090000:2461),
-- private.post_run_settlements (20261116090000:767), private.pending_item_deadlines (20261118100000:2775),
-- private.remittance_schedule_candidates (20261112090000:2421, dropped and recreated: one column more),
-- private.issue_commission_documents (20261114090000:1994), private.run_advance_checks (20261126090000:1717, 7d-1's),
-- private.approve_remittance_run (20261122090000:1410, 7a's: `set enable_seqscan = off` only, ADR-0014 « M2c-7d-2 » D4);
-- (review round 1, MLAW-2) private.transfer_line_preview_of (20261117100000:1869: a payout part's set-off and withheld
-- parts as its booking computes them);
-- the checks remittance_pending_kind_check, remittance_line_kind_check, remittance_run_trigger_check.
-- The cancellation-after-download switch is not read nor written here.

------------------------------------------------------------------------------------------
-- Schema (§6.1's withheld kind, [check 2] the trigger)
------------------------------------------------------------------------------------------

-- the withheld settlement's queue item and line ([critic] M7-MONEY-5): the reversal of a barred settlement
alter table private.remittance_pending drop constraint remittance_pending_kind_check,
  add constraint remittance_pending_kind_check check (kind in (
    'allocation', 'allocation_reversal', 'forward', 'forward_reversal', 'client_advance', 'client_advance_reversal',
    'payout_returned', 'unplanned_payout', 'settlement_withheld'));
alter table public.remittance_line drop constraint remittance_line_kind_check,
  add constraint remittance_line_kind_check check (kind in (
    'allocation', 'allocation_reversal', 'forward', 'forward_reversal', 'client_advance', 'client_advance_reversal',
    'payout_returned', 'unplanned_payout', 'settlement_withheld'));
-- ([check 2] gap 3) a run drafted to give a withheld set-off back (« Compensation retenue à rendre »)
alter table public.remittance_run drop constraint remittance_run_trigger_check,
  add constraint remittance_run_trigger_check check (trigger in (
    'schedule', 'deadline', 'payout_returned', 'manual', 'settlement_withheld'));
-- (No new index on client_status_event: a partial index of the servicer's events whose predicate names their kinds is
-- implied by every per-client read that filters on a kind — client_opening_date, client_end_event, the bars — and a
-- generic plan under stale statistics read it whole for each of them: the per-client reads stay on
-- client_status_event_client_idx, and the nightly reaches the servicer's clients by organization_servicer_idx.)
-- For the same reason 7d-1's index of the servicer's seizures goes: every per-client seizure read (the blockers'
-- probe, private.client_seizures_standing — read now by the approval whatever N) implies its predicate, and in the db
-- job's order a generic plan read it whole (5,005 planted seizures per blocker check, 10,006 per approval:
-- test_client_event_reads_integration). Those reads keep client_status_event_client_seizure_idx (keyed by the client);
-- the nightly's seizure_standing reaches the servicer's clients by organization_servicer_idx (run_advance_checks below).
drop index public.client_status_event_seizure_idx;


------------------------------------------------------------------------------------------
-- The bars and the births (§6.2.4–§6.2.6)
------------------------------------------------------------------------------------------

-- (§6.2.4; default OQ-92: « the earliest date the claim can be said to be born ») an invoice: the earliest of its issue
-- date and the collections it charges (its lines by remittance_line_invoice_idx, the lines a later run repriced onto it
-- by remittance_line_repricing_invoice_idx, each line by its key); with none (a corrective invoice), the earliest of its
-- issue date and its period's start; a credit note: its issue; an advance: private.advance_born_on (7b). Null for an id
-- that is none. Each parameter's filter implies its partial index's predicate (`invoice_id = $1`: not null), and the
-- seq scans are off: keyed whatever the statistics.
create function private.document_born_on(p_document_id uuid)
returns date
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select coalesce(
    (select case when i.kind = 'invoice'
                 then least(i.issue_date, coalesce(
                        (select min(x.e) from (
                           select l.encaissement_date as e from public.remittance_line l where l.invoice_id = i.id
                           union all
                           select q.encaissement_date
                           from (select rp.run_id, rp.line_no from public.remittance_line_repricing rp
                                 where rp.invoice_id = i.id offset 0) rp
                           cross join lateral (select l.encaissement_date from public.remittance_line l
                                               where l.run_id = rp.run_id and l.line_no = rp.line_no offset 0) q) x),
                        i.service_from, i.issue_date))
                 else i.issue_date end
     from public.commission_invoice i where i.id = p_document_id),
    (select private.advance_born_on(a.id) from public.client_advance a where a.id = p_document_id));
$$;

-- (§6.2.6) Why nothing of kind p_kind ('invoice' or 'advance') may be set off for the client on p_on, else null — the
-- servicer's rules (founder Q9, Q11, Q12, Q18; OQ-41, OQ-91, OQ-92), in this order: `liquidation` once a liquidation is
-- in effect (nothing set off, before or after the judgment); `mandate_ended` once the mandate ended
-- (private.client_end_event: a death, a qualified tutelle, a mandate end — C. civ. 2003); `seizure` while a seizure
-- stands (private.client_seizures_standing; CPCE L211-2 al. 1, C. civ. 1347-7); `proceeding` for an advance while a
-- proceeding_opened is in effect (L622-7 I al. 1, second sentence; OQ-92). The client's events in effect read once, by
-- client_status_event_client_idx alone (materialized: no filter on a kind reaches the scan, so no partial index whose
-- predicate names kinds is ever read whole for it); the end event and the standing seizures only when such a kind is
-- among them. A client with no event in effect: one probe.
create function private.client_set_off_barred(p_client uuid, p_on date, p_kind text)
returns text
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  with ev as materialized (
    select e.kind from public.client_status_event e
    where e.client_organization_id = p_client and e.effective_date <= p_on)
  select case
    when not exists (select 1 from ev) then null
    when exists (select 1 from ev where ev.kind = 'liquidation') then 'liquidation'
    when exists (select 1 from ev where ev.kind in ('death', 'guardianship', 'mandate_ended'))
         and exists (select 1 from private.client_end_event(p_client, p_on)) then 'mandate_ended'
    when exists (select 1 from ev where ev.kind = 'seizure')
         and exists (select 1 from private.client_seizures_standing(p_client, p_on)) then 'seizure'
    when p_kind = 'advance' and exists (select 1 from ev where ev.kind = 'proceeding_opened') then 'proceeding'
  end;
$$;

-- Since when a bar (client_set_off_barred's code) applies on p_on: a liquidation's earliest judgment, the mandate's end,
-- the earliest seizure standing, a proceeding's opening (client_opening_date: also for a claim born before it)
create function private.client_set_off_bar_since(p_client uuid, p_on date, p_code text)
returns date
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select case p_code
    when 'liquidation' then (select min(e.effective_date) from public.client_status_event e
                             where e.client_organization_id = p_client and e.effective_date <= p_on
                               and e.kind = 'liquidation')
    when 'mandate_ended' then (select x.effective_date from private.client_end_event(p_client, p_on) x)
    when 'seizure' then (select min(e.effective_date)
                         from private.client_seizures_standing(p_client, p_on) s (id)
                         cross join lateral (select q.effective_date from public.client_status_event q
                                             where q.id = s.id offset 0) e)
    when 'proceeding' then private.client_opening_date(p_client, p_on)
  end;
$$;

-- The bars of the day as the draft records them (§6.1 private.remittance_draft.set_off_barred, compared at the approval
-- and before download): « <invoice bar or ->/<advance bar or -> », null when neither kind is barred
create function private.client_set_off_bars(p_client uuid, p_on date)
returns text
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select case when b.i is null and b.a is null then null else coalesce(b.i, '-') || '/' || coalesce(b.a, '-') end
  from (select private.client_set_off_barred(p_client, p_on, 'invoice') as i,
               private.client_set_off_barred(p_client, p_on, 'advance') as a) b;
$$;

-- (§6.2.6) Whether a document may be set off on p_on: a credit note always (the servicer's policy: a price correction
-- is not a set-off, [critic] L19 (e)); an invoice or an advance when no bar of its kind applies and it was not born
-- before the client's opening (private.document_before_opening). Null for an id that is none.
create function private.document_nettable(p_document_id uuid, p_on date)
returns boolean
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select case d.kind
    when 'credit_note' then true
    else private.client_set_off_barred(d.client, p_on, d.kind) is null
         and not coalesce(private.document_before_opening(p_document_id, p_on), false)
  end
  from (select i.kind, i.client_organization_id as client from public.commission_invoice i where i.id = p_document_id
        union all
        select 'advance', a.client_organization_id from public.client_advance a where a.id = p_document_id) d
  limit 1;
$$;

-- What the prepare reads of the client's status (jobs/remittances.py load_facts), one call: the opening, the draft's
-- text of the bars, and each kind's bar with the day it applies from (the run's own invoice names it)
create function private.prepare_set_off_facts(p_client uuid, p_on date)
returns table (opening_on date, set_off_barred text, invoice_bar text, invoice_since date, advance_bar text,
               advance_since date)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select private.client_opening_date(p_client, p_on),
         case when b.i is null and b.a is null then null else coalesce(b.i, '-') || '/' || coalesce(b.a, '-') end,
         b.i, case when b.i is not null then private.client_set_off_bar_since(p_client, p_on, b.i) end,
         b.a, case when b.a is not null then private.client_set_off_bar_since(p_client, p_on, b.a) end
  from (select private.client_set_off_barred(p_client, p_on, 'invoice') as i,
               private.client_set_off_barred(p_client, p_on, 'advance') as a) b;
$$;

-- (§6.2.11 (a)) The reason of a withheld set-off's reversal: « Compensation retenue : <the bar> depuis le JJ/MM/AAAA
-- (règle du cabinet) » — the invoices' bar when there is one, else the procedure (a claim born before its opening, or an
-- advance while it stands); never the law's words for the servicer's rule
create function private.set_off_bar_reason(p_client uuid, p_on date)
returns text
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select 'Compensation retenue : '
         || case b.code when 'liquidation' then 'liquidation judiciaire' when 'mandate_ended' then 'fin du mandat'
                        when 'seizure' then 'saisie entre les mains du cabinet' else 'procédure collective' end
         || coalesce(' depuis le ' || to_char(private.client_set_off_bar_since(p_client, p_on, b.code), 'DD/MM/YYYY'), '')
         || ' (règle du cabinet)'
  from (select coalesce(private.client_set_off_barred(p_client, p_on, 'invoice'), 'proceeding') as code) b;
$$;

-- Whether a plan's settles (a draft's, refs naming the run's own documents `new:<mandate>`; or a run's frozen plan,
-- each with its `document_id`) set off on p_on a document barred that day: an earlier document not
-- private.document_nettable; the run's own invoice when invoices are barred, or when the earliest collection of its
-- mandate it charges precedes the opening ([critic] L1) — the draft's own lines (invoiced) and (review round 1, MLAW-1)
-- the earlier runs' lines it reprices (private.remittance_draft_repricing, invoiced; each line's mandate by its key, as
-- the approval files the repricing under `new:<line's mandate>` and private.document_born_on later counts it). A settle
-- of a refund is the servicer paying, never a set-off. (Review round 1, CC-2) the opening is read once, and the run's
-- lines only when the client has one: no draft line is read for a client with no opening.
create function private.plan_sets_off_barred(p_run_id uuid, p_client uuid, p_settles jsonb, p_on date)
returns boolean
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select exists (
    select 1
    from (select private.client_opening_date(p_client, p_on) as opening_on) o
    cross join jsonb_array_elements(case when jsonb_typeof(p_settles) = 'array' then p_settles else '[]' end) s
    where s ->> 'kind' in ('compensation', 'advance') and coalesce((s ->> 'amount')::bigint, 0) > 0
      and case when coalesce(s ->> 'document_id', s ->> 'ref') !~ '^new'
               then not coalesce(private.document_nettable(coalesce(s ->> 'document_id', s ->> 'ref')::uuid, p_on),
                                 false)
               when private.client_set_off_barred(p_client, p_on, 'invoice') is not null then true
               when o.opening_on is null then false
               else coalesce(
                      (select min(x.e) from (
                         select l.encaissement_date as e from private.remittance_draft_line l
                         where l.run_id = p_run_id and l.invoiced and l.mandate_id::text = substr(s ->> 'ref', 5)
                         union all
                         select q.encaissement_date
                         from (select rp.line_run_id, rp.line_no from private.remittance_draft_repricing rp
                               where rp.run_id = p_run_id and rp.invoiced offset 0) rp
                         cross join lateral (select l.encaissement_date, l.mandate_id from public.remittance_line l
                                             where l.run_id = rp.line_run_id and l.line_no = rp.line_no offset 0) q
                         where q.mandate_id::text = substr(s ->> 'ref', 5)) x)
                      < o.opening_on, false)
          end);
$$;

-- (§6.2.9, §6.2.11 (b)) Whether a run's set-off no longer holds on p_on: the opening or the bars differ from what its
-- draft recorded (private.remittance_draft.opening_on, set_off_barred: a draft prepared before 7d-2 recorded none),
-- or its settles set off a document barred that day. The draft by its key.
create function private.run_set_off_changed(p_run_id uuid, p_client uuid, p_settles jsonb, p_on date)
returns boolean
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select d.opening_on is distinct from private.client_opening_date(p_client, p_on)
         or d.set_off_barred is distinct from private.client_set_off_bars(p_client, p_on)
         or private.plan_sets_off_barred(p_run_id, p_client, p_settles, p_on)
  from (select 1) o
  left join lateral (select q.opening_on, q.set_off_barred from private.remittance_draft q where q.run_id = p_run_id
                     offset 0) d on true;
$$;


------------------------------------------------------------------------------------------
-- Redefinitions: what the client may pay, how an advance is recovered, the request (each copied whole)
------------------------------------------------------------------------------------------

-- private.document_before_opening, redefined from 20261124090000_client_payments.sql (line 1140; same signature and
-- settings, its grants restated below). M2c-7d-2 (plan §6.2.5): a document is born before the opening when its birth
-- (private.document_born_on: an invoice at the earliest collection it charges, no longer its issue date) precedes
-- private.client_opening_date; the birth is read only when the client has an opening (the one date it is compared with).
create or replace function private.document_before_opening(p_document_id uuid, p_on date)
returns boolean
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select case when o.opening is null then false
              else coalesce(private.document_born_on(d.id) < o.opening, false) end
  from (select i.id, i.client_organization_id as client from public.commission_invoice i
        where i.id = p_document_id
        union all
        select a.id, a.client_organization_id from public.client_advance a
        where a.id = p_document_id) d
  cross join lateral (select private.client_opening_date(d.client, p_on) as opening) o
  limit 1;
$$;
-- private.document_client_payable, redefined from 20261124090000_client_payments.sql (line 1161; same signature and
-- settings, its grants restated below). M2c-7d-2 ([check 1] gap 11, plan §6.2.6 [critic] L4): nor an advance while a
-- proceeding stands (a proceeding_opened or a liquidation in effect, private.client_proceeding_stands), whatever its
-- birth — the client's money for it is held for the procedure, never settles it (founder Q4 a, Q18 a; OQ-92).
create or replace function private.document_client_payable(p_document_id uuid, p_on date)
returns boolean
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select not coalesce(private.document_before_opening(p_document_id, p_on), false)
         and not exists (select 1 from public.client_advance a
                         where a.id = p_document_id
                           and private.client_proceeding_stands(a.client_organization_id, p_on));
$$;
-- private.client_payment_docs, redefined from 20261124090000_client_payments.sql (line 1367; same signature and
-- settings, its grants restated below). M2c-7d-2 (carried from 7c-1 round 1, « Left open »): each document's
-- payability is private.document_client_payable's (7d-2's: an advance while a proceeding stands), its « before the
-- opening » private.document_before_opening's — the advances' inline test of 7c-1 goes. Nothing else changes.
create or replace function private.client_payment_docs(p_client_organization_id uuid, p_currency char(3), p_on date)
returns jsonb
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select coalesce(jsonb_agg(x.doc order by x.kind, x.at, x.id), '[]')
  from (select 'invoice' as kind, i.issue_date::timestamptz as at, i.id,
               jsonb_build_object(
                 'kind', 'invoice', 'id', i.id, 'number', i.number, 'issue_date', i.issue_date, 'due_date', i.due_date,
                 'settlement', i.settlement, 'ttc_minor', i.ttc_minor::text, 'open', o.open::text,
                 'pending_vat', private.document_pending_vat(i.id)::text, 'payable', b.payable,
                 'before_opening', b.before, 'year', i.year, 'seq', i.seq, 'since', i.issue_date,
                 'open_on', i.issue_date <= p_on,
                 'in_flight_run', (select jsonb_build_object('run_id', f.run_id, 'number', f.run_number)
                                   from private.document_in_flight_run(i.id, i.client_organization_id, i.currency) f
                                   limit 1)) as doc
        from (select q.id, q.number, q.kind, q.currency, q.issue_date, q.due_date, q.settlement, q.ttc_minor, q.year,
                     q.seq, q.client_organization_id
              from public.commission_invoice q where q.client_organization_id = p_client_organization_id offset 0) i
        cross join lateral (select private.document_open(i.id) as open) o
        cross join lateral (select coalesce(private.document_before_opening(i.id, p_on), false) as before,
                                   private.document_client_payable(i.id, p_on) as payable) b
        where i.kind = 'invoice' and i.currency = p_currency and o.open > 0
        union all
        select 'advance', a.created_at, a.advance_id,
               jsonb_build_object(
                 'kind', 'advance', 'id', a.advance_id, 'cause', a.cause, 'born_on', a.born_on,
                 'created_at', a.created_at, 'created_on', (a.created_at at time zone 'Europe/Paris')::date,
                 'amount_minor', (select q.amount_minor from public.client_advance q where q.id = a.advance_id)::text,
                 'open', a.open_minor::text, 'pending_vat', '0', 'mandate_id', a.mandate_id,
                 'payable', b.payable, 'before_opening', b.before, 'year', 0, 'seq', 0, 'since', a.born_on,
                 'open_on', coalesce(a.born_on <= p_on, false),
                 'in_flight_run', (select jsonb_build_object('run_id', f.run_id, 'number', f.run_number)
                                   from private.advance_in_flight_run(a.advance_id) f order by f.run_number limit 1))
        from private.client_open_advances(p_client_organization_id, p_currency) a
        cross join lateral (select coalesce(private.document_before_opening(a.advance_id, p_on), false) as before,
                                   private.document_client_payable(a.advance_id, p_on) as payable) b) x;
$$;
-- private.advance_recovery_of, redefined from 20261124090000_client_payments.sql (line 1181, 7c-1's; same signature
-- and settings, its grants restated below). M2c-7d-2 (carried from 7c-1 rounds 2–3; plan §6.2.6): how an advance is
-- recovered as the runs and the request now do it — « barred_proceeding » for every advance while a proceeding
-- stands (a proceeding_opened or a liquidation recorded alone, private.client_proceeding_stands: L4, founder Q18 a —
-- whatever its birth), and a claw-back clause no longer applied after a mandate's end or while a seizure stands
-- (private.client_set_off_barred: founder Q9 a, Q12 a): the advance is then recovered by a request. The birth is no
-- longer read (p_born_on kept: the callers' signature).
create or replace function private.advance_recovery_of(p_mandate_id uuid, p_client_organization_id uuid, p_born_on date,
                                                       p_on date)
returns table (recovery text, clause_ref text)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select case when b.barred then 'barred_proceeding' when b.lapsed then 'request' else m.recovery end,
         case when b.barred or b.lapsed then null else m.clause_ref end
  from private.mandate_recovery(p_mandate_id, p_on) m
  cross join lateral (select private.client_proceeding_stands(p_client_organization_id, p_on) as barred) p
  cross join lateral (select p.barred,
                             m.recovery = 'clawback' and not p.barred
                             and private.client_set_off_barred(p_client_organization_id, p_on, 'advance')
                                 is not null as lapsed) b;
$$;
-- private.client_opening_on, redefined from 20261123090000_advance_recovery.sql (line 125; same signature and
-- settings, its grants restated below). M2c-7d-2 (carried from 7c-1): the opening is client_opening_date's, a
-- liquidation recorded alone included — nothing reads proceeding_opened alone any more.
create or replace function private.client_opening_on(p_client_organization_id uuid, p_on date)
returns date
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select private.client_opening_date(p_client_organization_id, p_on);
$$;
-- private.advance_repayment_refusal, redefined from 20261125090000_repayment_requests.sql (line 258; same signature and
-- settings, its grants restated below). M2c-7d-2 (plan §6.2.6 [critic] L4, §6.4): `in_proceeding` after
-- `before_opening` — while a proceeding stands no advance is requested, whatever its birth (« Client en procédure
-- collective : l'avance n'est ni reprise ni demandée ; elle est à déclarer. »).
create or replace function private.advance_repayment_refusal(p_advance_id uuid, p_client_organization_id uuid,
                                                             p_currency char(3), p_today date)
returns table (code text, detail text)
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  a record;
  v_run text;
  v_last date;
  m record;
begin
  select q.id, q.client_organization_id, q.currency, q.mandate_id into a
  from public.client_advance q where q.id = p_advance_id;
  if not found or a.client_organization_id <> p_client_organization_id or a.currency <> p_currency
     or coalesce(private.advance_open(a.id), 0) <= 0 then
    return query select 'not_open'::text, null::text;
    return;
  end if;
  select x.run_number into v_run from private.advance_in_flight_run(a.id) x order by x.run_number limit 1;
  if v_run is not null then
    return query select 'in_flight'::text, v_run;
    return;
  end if;
  if coalesce(private.document_before_opening(a.id, p_today), false) then
    return query select 'before_opening'::text, null::text;
    return;
  end if;
  -- (M2c-7d-2, [critic] L4) while a proceeding stands, whatever the advance's birth
  if private.client_proceeding_stands(p_client_organization_id, p_today) then
    return query select 'in_proceeding'::text, null::text;
    return;
  end if;
  select x.issue_date into v_last from private.advance_live_request(a.id) x;
  if v_last is not null and v_last > p_today - 30 then
    return query select 'recently_requested'::text, v_last::text;
    return;
  end if;
  select x.recovery, x.clause_ref into m
  from private.advance_recovery_of(a.mandate_id, p_client_organization_id, private.advance_born_on(a.id), p_today) x;
  if m.recovery = 'clawback' then
    return query select 'clawback_applies'::text, m.clause_ref;
    return;
  end if;
  v_run := private.advance_payout_not_received(a.id);
  if v_run is not null then
    return query select 'payout_not_received'::text, v_run;
    return;
  end if;
end;
$$;

------------------------------------------------------------------------------------------
-- The ledger: the one exception to LG003 and its commit check (§6.2.11 (a) 3–5)
------------------------------------------------------------------------------------------

-- private.ledger_entry_guard, redefined from 20261111090000_remittance_funds.sql (line 233; same signature and
-- settings, its grants restated below). M2c-7d-2 ([check 1] gap 1, plan §6.2.11 (a) 3): one exception in the LG003 type
-- rule only — a new entry whose idempotency key is 'return:barred:' || x reversing a client_settlement of the same
-- organization whose key is 'settle:' || x || ':barred' and whose source is the run x (source_type remittance_run,
-- source_id x): the barred part of a run's settlement, posted and reversed at its payout's debit by
-- private.post_run_settlements. Every other reversal of a client_settlement, a commission document or a write-off still
-- raises LG003; the guard's other rules (tenant, scope, line count, date) are unchanged and apply to it.
create or replace function private.ledger_entry_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_bad text;
begin
  select min(n.id::text) into v_bad from new_rows n
  where not exists (select 1 from public.organization o where o.id = n.organization_id and o.kind = 'servicer')
     or (n.client_organization_id is not null and not exists (
           select 1 from public.organization o
           where o.id = n.client_organization_id and o.servicer_organization_id = n.organization_id))
     or (n.portfolio_id is not null and not exists (
           select 1 from public.portfolio p
           where p.id = n.portfolio_id and p.organization_id = n.organization_id
             and p.client_organization_id = n.client_organization_id))
     or (n.account_id is not null and not exists (
           select 1 from public.account a
           where a.id = n.account_id and a.portfolio_id = n.portfolio_id and a.organization_id = n.organization_id))
     or (n.payment_id is not null and not exists (
           select 1 from public.payment p where p.id = n.payment_id and p.organization_id = n.organization_id));
  if v_bad is not null then
    raise exception 'ledger: entry % is outside its tenant (organization, client, portfolio, account, payment)', v_bad
      using errcode = 'LG002';
  end if;
  -- One keyed lookup per reversal (the reversed entry, by its primary key: fenced, so that no other index of
  -- ledger_entry is read for it). (M2c-7d-2) The one exception: a barred settlement's reversal under its own run's key
  -- (both keys and the source read off that one row; anything unknown — a null — is no exception).
  select min(n.id::text) into v_bad from new_rows n
  cross join lateral (select t.entry_type, t.organization_id, t.source_type, t.source_id, t.idempotency_key
                      from public.ledger_entry t where t.id = n.reverses_entry_id offset 0) t
  where n.reverses_entry_id is not null
    and t.entry_type in ('commission_invoice', 'commission_credit_note', 'client_settlement', 'advance_write_off')
    and not coalesce(t.entry_type = 'client_settlement' and t.organization_id = n.organization_id
                     and t.source_type = 'remittance_run'
                     and t.idempotency_key = 'settle:' || t.source_id || ':barred'
                     and n.idempotency_key = 'return:barred:' || t.source_id, false);
  if v_bad is not null then
    raise exception 'ledger: entry % reverses a commission document, a settlement or a write-off (never reversed: issue a credit note)',
      v_bad using errcode = 'LG003';
  end if;
  -- A reversal keeps the reversed entry's scope and payment; a cash_in is never reversed (a wrong
  -- statement line is corrected by a payment-tagged cash_out).
  select min(n.id::text) into v_bad from new_rows n
  left join public.ledger_entry t on t.id = n.reverses_entry_id
  where n.reverses_entry_id is not null
    and (t.id is null or t.reverses_entry_id is not null
         or t.entry_type = 'cash_in'
         or t.organization_id <> n.organization_id
         or t.client_organization_id is distinct from n.client_organization_id
         or t.portfolio_id is distinct from n.portfolio_id
         or t.account_id is distinct from n.account_id
         or t.payment_id is distinct from n.payment_id
         or t.line_count <> n.line_count
         or n.effective_date < t.effective_date);
  if v_bad is not null then
    raise exception 'ledger: reversal % does not match the entry it reverses', v_bad using errcode = 'LG003';
  end if;
  return null;
end;
$$;

-- (§6.2.11 (a) 4) The commit check: a barred settlement exists only with its reversal, posted in its transaction
-- (robust to the debit job's savepoints: no reliance on xmin or posted_at). The reversal by
-- ledger_entry_reversed_once_uq.
create function private.barred_settlement_check()
returns trigger
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
begin
  if not exists (select 1 from public.ledger_entry r where r.reverses_entry_id = new.id) then
    raise exception 'ledger: barred settlement % not reversed in its transaction', new.id using errcode = 'LG003';
  end if;
  return null;
end;
$$;
create constraint trigger ledger_entry_barred_reversed after insert on public.ledger_entry
  deferrable initially deferred for each row
  when (new.entry_type = 'client_settlement' and new.idempotency_key like 'settle:%:barred')
  execute function private.barred_settlement_check();
alter table public.ledger_entry enable always trigger ledger_entry_barred_reversed;

-- private.ledger_check_now, redefined from 20261122090000_remitted_reversals_covered.sql (line 1149, 7a's; same
-- signature and settings, its grants restated below): the commit-time checks it runs now also hold the barred
-- settlement's (ledger_entry_barred_reversed). Nothing else changes.
create or replace function private.ledger_check_now()
returns void
language plpgsql
set search_path = ''
as $$
begin
  set constraints public.ledger_entry_balanced, private.client_payable_in_credit, public.ledger_entry_remitted_cover,
    public.remittance_run_booked_cover, public.ledger_entry_barred_reversed immediate;
  set constraints public.ledger_entry_balanced, private.client_payable_in_credit, public.ledger_entry_remitted_cover,
    public.remittance_run_booked_cover, public.ledger_entry_barred_reversed deferred;
end;
$$;

-- private.ledger_posting_client_payable, redefined from 20261111090000_remittance_funds.sql (line 1252; same signature
-- and settings, its grants restated below). M2c-7d-2 (§6.2.11 (a) 5): the reversal of a client_settlement (only a barred
-- one exists: LG003) is a settlement_withheld item — the −Σ4670 of its own entry, W, owed back to the client.
create or replace function private.ledger_posting_client_payable()
returns trigger
language plpgsql
security definer
set search_path = ''
set enable_nestloop = off
set enable_mergejoin = off
set enable_seqscan = off
as $$
begin
  -- One statement (no working table: this fires for every posting statement, reversals in loops included).
  with cpb as materialized (
    select n.entry_id, la.organization_id, la.client_organization_id, la.currency, sum(n.amount_minor) as amount_minor
    from new_rows n
    join (select l.id, l.organization_id, l.client_organization_id, l.currency
          from public.ledger_account l where l.book = 'client_payable') la on la.id = n.ledger_account_id
    group by n.entry_id, la.organization_id, la.client_organization_id, la.currency
  ),
  bal as (
    insert into private.client_payable_balance as b (organization_id, client_organization_id, currency, balance_minor)
    select x.organization_id, x.client_organization_id, x.currency, sum(x.amount_minor)
    from cpb x
    group by x.organization_id, x.client_organization_id, x.currency
    on conflict (client_organization_id, currency)
      do update set balance_minor = b.balance_minor + excluded.balance_minor, updated_at = clock_timestamp()
    returning 1
  )
  insert into private.remittance_pending as q (ledger_entry_id, organization_id, client_organization_id, currency, kind,
                                              amount_minor, posted_at)
  select y.entry_id, y.organization_id, y.client_organization_id, y.currency, y.kind, -y.amount_minor, y.posted_at
  from (select x.*,
               (select case e.entry_type
                         when 'allocation' then 'allocation'
                         when 'forward' then 'forward'
                         when 'client_advance' then 'client_advance'
                         when 'reversal' then (select case t.entry_type
                                                        when 'allocation' then 'allocation_reversal'
                                                        when 'forward' then 'forward_reversal'
                                                        when 'client_advance' then 'client_advance_reversal'
                                                        when 'remittance' then 'payout_returned'
                                                        -- (M2c-7d-2) a barred settlement given back
                                                        when 'client_settlement' then 'settlement_withheld' end
                                               from public.ledger_entry t where t.id = e.reverses_entry_id)
                       end
                from public.ledger_entry e where e.id = x.entry_id) as kind,
               (select e.posted_at from public.ledger_entry e where e.id = x.entry_id) as posted_at
        from cpb x
        where x.amount_minor <> 0) y
  where y.kind is not null   -- (the balance upsert in WITH always runs to completion)
  on conflict (ledger_entry_id) do update set amount_minor = q.amount_minor + excluded.amount_minor;
  return null;
end;
$$;


------------------------------------------------------------------------------------------
-- The draft, the approval, the hold before download (§6.1, §6.2.9, §6.2.11 (b))
------------------------------------------------------------------------------------------

-- private.remittance_record_draft, redefined from 20261112090000_remittance_runs.sql (line 1087; same signature and
-- settings, its grants restated below). M2c-7d-2 (plan §6.1): the draft records the opening and the bars its plan
-- assumed (`opening_on`, `set_off_barred`: the prepare's client_opening_date and client_set_off_bars), compared at the
-- approval and before download. Nothing else changes.
create or replace function private.remittance_record_draft(p_run_id uuid, p_token uuid, p jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.remittance_run;
  v_lines integer;
  v_gross bigint;
  v_reserved integer;
begin
  select * into r from public.remittance_run where id = p_run_id for update;
  if not found or r.status <> 'draft' or r.job is distinct from 'prepare' or r.job_token is distinct from p_token then
    raise exception 'remittance draft %: no longer this job''s', p_run_id using errcode = '40001';
  end if;
  select count(*), coalesce(sum(d.amount_minor), 0) into v_lines, v_gross
  from private.remittance_draft_line d where d.run_id = p_run_id;
  -- each reserved item has its line (one keyed probe per item, whatever the statistics)
  select count(*) into v_reserved from private.remittance_pending q
  cross join lateral (select 1 from private.remittance_draft_line d where d.run_id = p_run_id
                        and d.ledger_entry_id = q.ledger_entry_id and d.amount_minor = q.amount_minor
                      limit 1) d
  where q.draft_run_id = p_run_id;
  if v_lines <> r.item_count or v_reserved <> r.item_count or v_gross <> (p ->> 'gross')::bigint
     or v_lines <> (p ->> 'line_count')::integer then
    raise exception 'remittance draft %: its lines are not the items reserved (% lines, % reserved, % items)',
      p_run_id, v_lines, v_reserved, r.item_count using errcode = '23514';
  end if;
  insert into private.remittance_draft (run_id, vat_rate, documents, key_states, history_seq, plan, vat_on_debits,
                                        proceeding_opened_on, opening_on, set_off_barred)
  values (p_run_id, (p ->> 'vat_rate')::numeric, coalesce(p -> 'documents', '[]'), coalesce(p -> 'key_states', '[]'),
          coalesce((p ->> 'history_seq')::bigint, 0), coalesce(p -> 'plan', '{}'),
          coalesce((p ->> 'vat_on_debits')::boolean, false), (p ->> 'proceeding_opened_on')::date,
          (p ->> 'opening_on')::date, nullif(p ->> 'set_off_barred', ''));
  insert into private.remittance_draft_repricing (run_id, line_run_id, line_no, ledger_entry_id, commission_minor,
                                                  commission_state, commission_reason, parts, invoiced)
  select p_run_id, (x ->> 'run_id')::uuid, (x ->> 'line_no')::integer, (x ->> 'ledger_entry_id')::uuid,
         (x ->> 'commission')::bigint, x ->> 'state', x ->> 'reason', coalesce(x -> 'parts', '[]'),
         coalesce((x ->> 'invoiced')::boolean, false)
  from jsonb_array_elements(coalesce(p -> 'repricing', '[]')) x;
  update public.remittance_run set
    prepared_at = clock_timestamp(), job = null, job_token = null, job_queued_at = null, version = version + 1,
    line_count = v_lines, gross_minor = v_gross,
    invoice_ht_minor = (p ->> 'invoice_ht')::bigint, invoice_vat_minor = (p ->> 'invoice_vat')::bigint,
    invoice_ttc_minor = (p ->> 'invoice_ttc')::bigint, credit_ht_minor = (p ->> 'credit_ht')::bigint,
    credit_vat_minor = (p ->> 'credit_vat')::bigint, credit_ttc_minor = (p ->> 'credit_ttc')::bigint,
    commission_taken_minor = (p ->> 'taken')::bigint, advance_recovered_minor = (p ->> 'advances')::bigint,
    refund_minor = (p ->> 'refunds')::bigint, settlement_minor = (p ->> 'settlement')::bigint,
    net_minor = (p ->> 'net')::bigint, vat_rate = (p ->> 'vat_rate')::numeric,
    earliest_deadline = (p ->> 'earliest_deadline')::date,
    earliest_latest_execution_date = (p ->> 'earliest_latest_execution_date')::date,
    unmeetable_count = coalesce((p ->> 'unmeetable')::integer, 0),
    blockers = coalesce(array(select jsonb_array_elements_text(p -> 'blockers')), '{}'),
    commission_blockers = coalesce(array(select jsonb_array_elements_text(p -> 'commission_blockers')), '{}'),
    engine_version = p ->> 'engine_version', inputs_hash = p ->> 'inputs_hash',
    payout_account_id = (p ->> 'payout_account_id')::uuid, last_failure = null
  where id = p_run_id;
end;
$$;
-- private.remittance_approval_refusal, redefined from 20261125090000_repayment_requests.sql (line 787, 7c-2's, its
-- `set enable_seqscan = off` kept; same signature and settings, its grants restated below; 7d-1 did not redefine it).
-- M2c-7d-2 (plan §6.2.9): a standing seizure refuses the run whatever N (`payout_blocked:client_status:seizure`: the
-- blockers were read only when N > 0, so an N = 0 run set off sums a seizure attributed to the creditor — 046a sp9's
-- pin, changed); client_status_changed when the opening (client_opening_date, no longer the proceeding_opened alone)
-- or the bars differ from the draft's, or a planned set-off is barred that day (the run's own invoice included,
-- [critic] L1). Nothing else changes.
create or replace function private.remittance_approval_refusal(p_run public.remittance_run,
                                                               p_draft private.remittance_draft, p_today date)
returns text
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_owed bigint;
  v_inflight bigint;
  v_blockers text[];
  v_bad text;
begin
  if p_draft.run_id is null then
    return 'not_prepared';
  end if;
  if (select count(*) from private.remittance_pending q where q.draft_run_id = p_run.id) <> p_run.item_count then
    return 'items_changed';
  end if;
  if jsonb_array_length(p_draft.documents) > 0 and private.vat_rate_on(p_today) <> p_draft.vat_rate then
    return 'vat_rate_changed';
  end if;
  -- the VAT book the plan assumed for the run's invoices (money review #1): 44571 at once on debits, else 44574
  if jsonb_array_length(p_draft.documents) > 0
     and coalesce((select s.vat_on_debits from public.servicer_billing_settings s
                   where s.organization_id = p_run.organization_id), false) <> p_draft.vat_on_debits then
    return 'vat_option_changed';
  end if;
  if jsonb_array_length(p_draft.documents) > 0
     and cardinality(private.remittance_commission_blockers(p_run.client_organization_id)) > 0 then
    return 'commission_blocked';
  end if;
  -- (M2c-7d-2, plan §6.2.9 [critic] L14) a standing seizure: nothing paid out and nothing set off, whatever N — an
  -- N = 0 run would set off sums the act attributed to the seizing creditor (CPCE L211-2 al. 1; C. civ. 1347-7)
  if exists (select 1 from private.client_seizures_standing(p_run.client_organization_id, p_today)) then
    return 'payout_blocked:client_status:seizure';
  end if;
  -- the client's status the plan's set-offs assumed (§9.6; money review #2) — (M2c-7d-2, §6.2.9) the opening
  -- (client_opening_date: a liquidation recorded alone too), the bars of the day as the draft recorded them, and every
  -- planned set-off still allowed today (private.run_set_off_changed)
  if exists (select 1 from jsonb_array_elements(coalesce(p_draft.plan -> 'settles', '[]')) s
             where s ->> 'kind' in ('compensation', 'advance'))
     and private.run_set_off_changed(p_run.id, p_run.client_organization_id, p_draft.plan -> 'settles', p_today) then
    return 'client_status_changed';
  end if;
  if p_run.net_minor > 0 then
    v_blockers := private.remittance_payout_blockers(p_run.client_organization_id, p_run.currency, p_today);
    if cardinality(v_blockers) > 0 then
      return 'payout_blocked:' || v_blockers[1];
    end if;
    if p_run.payout_account_id is distinct from (
         select pa.id from public.client_payout_account pa
         where pa.client_organization_id = p_run.client_organization_id and pa.currency = p_run.currency
           and pa.status = 'active') then
      return 'payout_account_changed';
    end if;
    v_bad := private.execution_date_refusal(p_run.organization_id, p_run.currency, p_run.requested_execution_date);
    if v_bad is not null then
      return v_bad;
    end if;
    if p_run.requested_execution_date > p_run.earliest_latest_execution_date and p_run.late_reason is null then
      return 'late_reason_required';
    end if;
  end if;
  -- N = 0 settles today: after the latest execution date, the reason too (money review #3)
  if p_run.net_minor = 0 and p_today > p_run.earliest_latest_execution_date and p_run.late_reason is null then
    return 'late_reason_required';
  end if;
  if p_run.net_minor < 0 then
    return 'negative_net';
  end if;
  -- the cap (§9.5, ledger critique #1): gross ≤ what the client is owed less the runs in flight
  select -b.balance_minor into v_owed from private.client_payable_balance b
  where b.client_organization_id = p_run.client_organization_id and b.currency = p_run.currency;
  select coalesce(sum(x.net_minor + x.settlement_minor), 0) into v_inflight from public.remittance_run x
  where x.client_organization_id = p_run.client_organization_id and x.currency = p_run.currency
    and x.status in ('approved', 'sent') and x.id <> p_run.id;
  if p_run.gross_minor > coalesce(v_owed, 0) - v_inflight then
    return 'balance_changed';
  end if;
  -- the tier history and the documents the plan continued from (the run's own key states, written before the locks
  -- in this transaction, excepted; a manual credit note's key state has no run and counts: M2c-5b)
  if coalesce((select max(k.seq) from public.remittance_key_state k
               where k.client_organization_id = p_run.client_organization_id
                 and k.run_id is distinct from p_run.id), 0)
     <> p_draft.history_seq then
    return 'history_changed';
  end if;
  -- (M2c-7c-2, plan §5.2.7 [critic] M7-MONEY-3) a planned advance settle names an advance a request not withdrawn
  -- names — requested since the draft was prepared (the prepare leaves a requested advance to its request): a run never
  -- also sets off what a request asks, also when the terms gained a claw-back clause after the request. One keyed probe
  -- per planned advance (private.advance_live_request); a settle of another kind is never cast.
  if exists (select 1 from jsonb_array_elements(coalesce(p_draft.plan -> 'settles', '[]')) s
             cross join lateral private.advance_live_request(case when s ->> 'kind' = 'advance'
                                                                  then (s ->> 'ref')::uuid end) q) then
    return 'documents_changed';
  end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p_draft.plan -> 'settles', '[]')) s
             where (s ->> 'ref') !~ '^new' and private.document_open((s ->> 'ref')::uuid) <> (s ->> 'open_before')::bigint)
     or exists (select 1 from jsonb_array_elements(p_draft.documents) d
                cross join lateral jsonb_array_elements(coalesce(d -> 'corrections', '[]')) c
                where private.document_open((c ->> 'original_invoice_id')::uuid) <> (c ->> 'open_before')::bigint) then
    return 'documents_changed';
  end if;
  return null;
end;
$$;
-- private.approve_remittance_run, redefined from 20261122090000_remitted_reversals_covered.sql (line 1410, 7a's; same
-- signature, its grants restated below). M2c-7d-2: `set enable_seqscan = off` added, the body unchanged — the stale-
-- statistics test of the approval (test_set_off_bar_reads_integration: the queue's draft_run_id analysed with two
-- values, a generic plan) found its « their items leave the pending queue » delete reading the servicer's whole queue
-- (remittance_pending_run_idx priced at half the table); the re-check it calls (private.remittance_approval_refusal,
-- 7d-2's) and every other read it makes are by key. Nothing else changes.
create or replace function private.approve_remittance_run(p_run_id uuid, p_token uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '10s'
set enable_seqscan = off
as $$
declare
  r public.remittance_run;
  d private.remittance_draft;
  pa public.client_payout_account;
  v_today date;
  v_why text;
  v_docs jsonb;
  v_ids jsonb := '{}';
  v_issued jsonb;
  v_n integer;
  v_plan jsonb;
  v_bank uuid;
  v_transfer uuid;
  v_info text;
  v_entry uuid;
  v_late boolean;
begin
  select * into r from public.remittance_run where id = p_run_id for update;
  if not found or r.status <> 'draft' or r.job is distinct from 'approve' or r.job_token is distinct from p_token then
    return jsonb_build_object('status', 'skipped');
  end if;
  select * into d from private.remittance_draft where run_id = r.id;
  if r.net_minor > 0 then
    select * into pa from public.client_payout_account where id = r.payout_account_id for key share;
    v_bank := private.paying_account(r.organization_id, r.currency);
    perform 1 from public.bank_account b where b.id = v_bank for share;
  end if;
  -- the documents' ids first (the lines name their invoice; the foreign key is checked at commit)
  select coalesce(jsonb_agg(x.doc || jsonb_build_object('id', gen_random_uuid(),
                                                        'key', case x.doc ->> 'kind' when 'invoice' then 'inv:'
                                                                                     else 'crn:' end
                                                               || r.id || ':' || (x.doc ->> 'mandate_id'))
                            order by x.ord), '[]')
  into v_docs from jsonb_array_elements(coalesce(d.documents, '[]')) with ordinality x (doc, ord);
  select coalesce(jsonb_object_agg(x ->> 'ref', x ->> 'id'), '{}') into v_ids from jsonb_array_elements(v_docs) x;

  begin
    -- The frozen facts, written under the run's row lock only, before the allocation lock (performance review #4):
    -- the lines, their repricings, the tier history (with what the run's credits absorb of manual credit notes'
    -- waivers, M2c-5b: a manual credit note since the prepare is caught by `history_changed`) and the invoices'
    -- charges depend only on the draft and on
    -- immutable entries; the refusal below rolls them back with this block. Holding the allocation lock is then the
    -- checks, the queue, the numbering and posting of the documents and the payout (each item in exactly one live
    -- line, I15), then the deferred checks at commit: 5k lines, 0.09 s + 0.07 s of a 0.83 s job (all of it before).
    -- The row locks these inserts take on what the lines name are key-share locks, taken (as every command takes its
    -- row locks) before the advisory lock: no lock cycle with an allocation.
    insert into public.remittance_line (run_id, line_no, organization_id, client_organization_id, currency,
                                        ledger_entry_id, kind, account_id, portfolio_id, mandate_id, mandate_terms_id,
                                        payment_id, encaissement_date, effective_date, posted_at, deadline,
                                        latest_execution_date, unmeetable, amount_minor, basis, commission_minor,
                                        commission_state, commission_reason, parts, original_entry_id, invoice_id)
    select l.run_id, l.line_no, r.organization_id, r.client_organization_id, r.currency, l.ledger_entry_id, l.kind,
           l.account_id, l.portfolio_id, l.mandate_id, l.mandate_terms_id, l.payment_id, l.encaissement_date,
           l.effective_date, l.posted_at, l.deadline, l.latest_execution_date, l.unmeetable, l.amount_minor, l.basis,
           l.commission_minor, l.commission_state, l.commission_reason, l.parts, l.original_entry_id,
           case when l.invoiced then (v_ids ->> ('new:' || l.mandate_id))::uuid end
    from private.remittance_draft_line l where l.run_id = r.id;
    get diagnostics v_n = row_count;
    insert into public.remittance_line_repricing (pricing_run_id, run_id, line_no, ledger_entry_id, commission_minor,
                                                  commission_state, commission_reason, parts, invoice_id)
    select r.id, x.line_run_id, x.line_no, x.ledger_entry_id, x.commission_minor, x.commission_state,
           x.commission_reason, x.parts,
           case when x.invoiced then (v_ids ->> ('new:' || l.mandate_id))::uuid end
    from (select q.* from private.remittance_draft_repricing q where q.run_id = r.id offset 0) x
    cross join lateral (select y.mandate_id from public.remittance_line y
                        where y.run_id = x.line_run_id and y.line_no = x.line_no offset 0) l;
    insert into public.remittance_key_state (organization_id, client_organization_id, account_id, tier_key, run_id,
                                             cause, basis, kept_basis_minor, kept_minor, commission_minor,
                                             waived_minor)
    select r.organization_id, r.client_organization_id, (k ->> 'account_id')::uuid, k ->> 'tier_key', r.id, 'approved',
           coalesce(k -> 'basis', '[]'), (k ->> 'kept_basis')::bigint, (k ->> 'kept')::bigint,
           (k ->> 'commission')::bigint, coalesce((k ->> 'waived')::bigint, 0)
    from jsonb_array_elements(coalesce(d.key_states, '[]')) k;
    -- what the run's credits absorb of the waivers manual credit notes left on earlier invoices (M2c-5b): no document
    -- carries it; the waiver's guard keeps each (invoice, key) balance between 0 and what was waived
    insert into public.commission_waiver (organization_id, client_organization_id, invoice_id, account_id, tier_key,
                                          amount_minor, cause, run_id, entry_id)
    select r.organization_id, r.client_organization_id, (w ->> 0)::uuid, (k ->> 'account_id')::uuid, k ->> 'tier_key',
           -(w ->> 1)::bigint, 'absorbed', r.id, (w ->> 2)::uuid
    from jsonb_array_elements(coalesce(d.key_states, '[]')) k
    cross join lateral jsonb_array_elements(coalesce(k -> 'absorbed', '[]')) w;
    -- what the run's invoices charge each (file, tier key) (one row per file at 50k; the invoices numbered below)
    insert into public.commission_invoice_charge (invoice_id, account_id, tier_key, charged_minor)
    select (x.doc ->> 'id')::uuid, (c ->> 'account_id')::uuid, c ->> 'tier_key', (c ->> 'amount')::bigint
    from jsonb_array_elements(v_docs) x (doc)
    cross join lateral jsonb_array_elements(coalesce(x.doc -> 'charges', '[]')) c
    where x.doc ->> 'kind' = 'invoice';

    -- lock order (ADR-0014): the run row → allocation lock → remit lock → invoice counter (last, in
    -- issue_commission_documents)
    perform pg_advisory_xact_lock(hashtext('payments:' || r.organization_id::text));
    perform pg_advisory_xact_lock(hashtext('remit:' || r.organization_id::text));
    v_today := private.paris_today();
    v_why := private.remittance_approval_refusal(r, d, v_today);
    if v_why is not null then
      raise exception '%', v_why using errcode = 'RR001';
    end if;
    if v_n <> r.line_count then
      raise exception 'approval of %: % lines frozen for % prepared', r.number, v_n, r.line_count
        using errcode = '23514';
    end if;
    -- their items leave the pending queue
    delete from private.remittance_pending q where q.draft_run_id = r.id;

    -- invoices and credit notes, numbered (the counter locked last), their entries posted, in the VAT book the plan
    -- assumed (money review #1)
    v_issued := private.issue_commission_documents(r.organization_id, r.client_organization_id, r.id,
                                                   (select coalesce(jsonb_agg(x.doc - 'charges' order by x.ord), '[]')
                                                    from jsonb_array_elements(v_docs) with ordinality x (doc, ord)),
                                                   'commission', d.vat_on_debits);

    -- the plan with the run's documents named (M2c-6 posts it at the debit)
    select d.plan || jsonb_build_object('settles', coalesce(jsonb_agg(
             s || jsonb_build_object('document_id', coalesce(v_ids ->> (s ->> 'ref'), s ->> 'ref'))), '[]'))
    into v_plan from jsonb_array_elements(coalesce(d.plan -> 'settles', '[]')) s;

    v_late := private.business_days_between((r.known_at at time zone 'Europe/Paris')::date, v_today) > 2;
    if r.net_minor > 0 then
      select left('REVERSEMENT ' || r.number || coalesce(' FACTURE ' || string_agg(i.number, ' ' order by i.seq), ''),
                  140)
      into v_info from public.commission_invoice i where i.run_id = r.id and i.kind = 'invoice';
      insert into public.bank_transfer (organization_id, client_organization_id, kind, debtor_bank_account_id, currency,
                                        amount_minor, payee_name, payee_iban, payee_bic, end_to_end_id,
                                        remittance_info, requested_execution_date, run_id, ordered_by)
      values (r.organization_id, r.client_organization_id, 'payout', v_bank, r.currency, r.net_minor, pa.holder_name,
              pa.iban, pa.bic, 'RMT' || upper(substr(md5(gen_random_uuid()::text), 1, 12)), v_info,
              r.requested_execution_date, r.id, r.approval_requested_by)
      returning id into v_transfer;
      perform private.remittance_late_lines(r, r.requested_execution_date);
      update public.remittance_run set status = 'approved', approved_by = r.approval_requested_by,
        approved_at = clock_timestamp(), transfer_id = v_transfer, settlement_plan = v_plan, invoice_late = v_late,
        payout_snapshot = jsonb_build_object('payout_account_id', pa.id, 'holder_name', pa.holder_name,
                                             'iban', pa.iban, 'bic', pa.bic, 'kind', pa.kind,
                                             'confirmed_at', pa.confirmed_at),
        job = null, job_token = null, job_queued_at = null, version = version + 1
      where id = r.id;
      return jsonb_build_object('status', 'approved', 'transfer_id', v_transfer, 'documents', v_issued -> 'documents');
    end if;
    -- N = 0 (§9.5 step 5): nothing to transfer; the settlement is posted now and the run is booked — its date is the
    -- items' payment date (I21: « settled when N = 0 », money review #3)
    perform private.remittance_late_lines(r, v_today);
    v_entry := private.post_run_settlement(r.id, v_plan, v_today);
    -- M2c-7a (plan §3.2.12): the run is booked now: a line reversed since it was prepared is covered (a same-run pair
    -- posts nothing: [critic] M7-MONEY-1)
    perform private.cover_booked_run_reversals(array[r.id], array[v_today]);
    update public.remittance_run set status = 'booked', booked_on = v_today, approved_by = r.approval_requested_by,
      approved_at = clock_timestamp(), settlement_plan = v_plan || jsonb_build_object('entry_id', v_entry),
      invoice_late = v_late, job = null, job_token = null, job_queued_at = null, version = version + 1
    where id = r.id;
    return jsonb_build_object('status', 'booked', 'entry_id', v_entry, 'documents', v_issued -> 'documents');
  exception when sqlstate 'RR001' then
    -- a business refusal: everything above rolled back, the locks released; back to draft with the reason
    perform private.remittance_back_to_draft(r.id, p_token, sqlerrm, null);
    return jsonb_build_object('status', 'back_to_draft', 'reason', sqlerrm);
  end;
end;
$$;
-- private.transfer_hold_reason, redefined from 20261118090000_switch_on_prerequisites.sql (line 2461; same signature,
-- its grants restated below). M2c-7d-2 (plan §6.2.11 (b)): a payout whose run's frozen set-off no longer holds (the
-- client's status changed since its prepare) is held client_status_changed — whatever the switch: before download a run
-- is always cancellable. `set enable_seqscan = off` added (its reads are by key; the new probes stay keyed whatever the
-- statistics). Nothing else changes.
create or replace function private.transfer_hold_reason(p_transfer_id uuid, p_today date, p_execution_date date,
                                                        p_late_reason text)
returns text
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  t public.bank_transfer;
  r public.remittance_run;
  v_blockers text[];
  v_owed bigint;
  v_inflight bigint;
  v_sibling text;
begin
  select * into t from public.bank_transfer where id = p_transfer_id;
  if t.currency <> 'EUR' then
    return 'not_eur';
  end if;
  -- M2c-6b-3a (A): the servicer's share left once already, by a cancelled sweep executed late
  if t.kind = 'sweep' then
    return case when private.sweep_after_debited_cancelled(t.id) then 'cancelled_sweep_debited' end;
  end if;
  if t.kind in ('payout', 'refund') and private.transfer_debited_before(t.id) then
    return 'already_debited';
  end if;
  -- M2c-6b-3a (M): a cancelled payout of its client, or refund of its payment, debited late
  v_sibling := private.transfer_sibling_debited_late(t.id);
  if v_sibling is not null then
    return v_sibling;
  end if;
  if t.kind = 'refund' then
    if not exists (select 1 from public.refund_request q where q.transfer_id = t.id and q.status = 'requested') then
      return 'refund_not_pending';
    end if;
    if private.epc_name_empty(t.payee_name) then
      return 'payee_name_not_epc';
    end if;
    if not private.iban_in_sepa(t.payee_iban) then
      return 'iban_not_sepa';
    end if;
    return null;
  end if;
  if t.kind <> 'payout' then
    return null;
  end if;
  select * into r from public.remittance_run where id = t.run_id;
  if r.id is null or r.status not in ('approved', 'sent') then
    return 'run_not_in_flight';
  end if;
  v_blockers := private.remittance_payout_blockers(r.client_organization_id, r.currency, p_today);
  if cardinality(v_blockers) > 0 then
    return 'payout_blocked:' || v_blockers[1];
  end if;
  if r.payout_account_id is distinct from (
       select pa.id from public.client_payout_account pa
       where pa.client_organization_id = r.client_organization_id and pa.currency = r.currency
         and pa.status = 'active') then
    return 'payout_account_changed';
  end if;
  -- (M2c-7d-2, plan §6.2.11 (b)) the client's status changed since the prepare and the run's frozen set-off no longer
  -- holds: no file is generated or downloaded with it; ops cancel the run (before download: always possible) and prepare
  -- it again. Read only for a run that sets something off and a client with an event in effect (or a draft that
  -- recorded one): one keyed probe each, the rest in private.run_set_off_changed
  if exists (select 1 from jsonb_array_elements(case when jsonb_typeof(r.settlement_plan -> 'settles') = 'array'
                                                     then r.settlement_plan -> 'settles' else '[]' end) s
             where s ->> 'kind' in ('compensation', 'advance') and coalesce((s ->> 'amount')::bigint, 0) > 0)
     and (exists (select 1 from public.client_status_event e
                  where e.client_organization_id = r.client_organization_id and e.effective_date <= p_today)
          or exists (select 1 from private.remittance_draft d
                     where d.run_id = r.id and (d.opening_on is not null or d.set_off_barred is not null)))
     and private.run_set_off_changed(r.id, r.client_organization_id, r.settlement_plan -> 'settles', p_today) then
    return 'client_status_changed';
  end if;
  select -b.balance_minor into v_owed from private.client_payable_balance b
  where b.client_organization_id = r.client_organization_id and b.currency = r.currency;
  select coalesce(sum(x.net_minor + x.settlement_minor), 0) into v_inflight from public.remittance_run x
  where x.client_organization_id = r.client_organization_id and x.currency = r.currency
    and x.status in ('approved', 'sent') and x.id <> r.id;
  if r.gross_minor > coalesce(v_owed, 0) - v_inflight then
    return 'payout_not_covered';
  end if;
  if private.epc_name_empty(t.payee_name) then
    return 'payee_name_not_epc';
  end if;
  if not private.iban_in_sepa(t.payee_iban) then
    return 'iban_not_sepa';
  end if;
  if r.earliest_latest_execution_date is not null and p_execution_date > r.earliest_latest_execution_date
     and r.late_reason is null and p_late_reason is null then
    return 'late_reason_required';
  end if;
  return null;
end;
$$;

------------------------------------------------------------------------------------------
-- The debit: the barred set-off posted and reversed (§6.2.11 (a))
------------------------------------------------------------------------------------------

-- The runs of p_runs (their clients and debit dates by position) whose client has an event in effect by that date: the
-- only runs whose plan's set-offs the debit reads document by document (one keyed probe of
-- client_status_event_client_idx per run, whatever the statistics)
create function private.runs_with_client_events(p_clients uuid[], p_days date[])
returns table (ord integer)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select x.ord::integer
  from unnest(p_clients, p_days) with ordinality x (client, on_date, ord)
  where exists (select 1 from public.client_status_event e
                where e.client_organization_id = x.client and e.effective_date <= x.on_date);
$$;

-- The settles of a run's frozen plan barred on p_on (§6.2.11 (a) 1): of kind compensation (an invoice) or advance whose
-- document private.document_nettable refuses that day — a refund settle (a credit note paid with the payout: the
-- servicer paying, not setting off) never; their positions (1-based), W, its invoices' part Wc, its advances' Wa and
-- their VAT moved Wv
create function private.run_barred_settles(p_settles jsonb, p_on date)
returns table (barred integer[], w bigint, wc bigint, wa bigint, wv bigint)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select coalesce(array_agg(s.n::integer order by s.n), '{}'),
         coalesce(sum((s.v ->> 'amount')::bigint), 0)::bigint,
         coalesce(sum((s.v ->> 'amount')::bigint) filter (where s.v ->> 'kind' = 'compensation'), 0)::bigint,
         coalesce(sum((s.v ->> 'amount')::bigint) filter (where s.v ->> 'kind' = 'advance'), 0)::bigint,
         coalesce(sum((s.v ->> 'vat_moved')::bigint), 0)::bigint
  from jsonb_array_elements(case when jsonb_typeof(p_settles) = 'array' then p_settles else '[]' end)
         with ordinality s (v, n)
  where s.v ->> 'kind' in ('compensation', 'advance')
    and not coalesce(private.document_nettable((s.v ->> 'document_id')::uuid, p_on), false);
$$;

-- private.post_run_settlements, redefined from 20261116090000_debit_bookings.sql (line 767; same signature and
-- settings, its grants restated below). M2c-7d-2 ([critic] M7-MONEY-5, [check 1] gap 1; plan §6.2.11 (a) 1–2): the
-- client's status re-read at the debit. For each run, the plan's settles barred on the debit's date
-- (private.run_barred_settles, read only for a run whose client has an event in effect by then) are posted in a second
-- entry `settle:<run>:barred` (the shape of any settlement: +4670[c] W / −4679 W ‖ +4689 W / −4111[c] Wc / −4112[c] Wa ‖
-- +44574 Wv / −44571 Wv), with no commission_settlement row, reversed at once (`return:barred:<run>`, its reason
-- private.set_off_bar_reason — « Compensation retenue : … depuis le JJ/MM/AAAA (règle du cabinet) »): the 4670 trigger
-- queues the reversal as a settlement_withheld item of W, which the next run pays back. The allowed settles post as
-- before (`settle:<run>`: D − W, Dc − Wc, Da − Wa, v − Wv, their commission_settlement rows). When the allowed part
-- would be ≤ 0 while D > 0 (a refund at least as large as the allowed invoices), the whole plan is withheld (W = D, no
-- allowed entry): never a zero settlement. (Deviation, ADR-0014 « M2c-7d-2 ») with D ≤ 0 (a refund larger than every
-- take, paid by the servicer's share) W cannot be D: the barred takes are withheld and the rest posts as such a run's
-- negative settlement always did. A barred settle of 0 (a closed invoice's VAT left pending) is dropped with its VAT
-- (moved by the next settlement). The documents stay open (to declare, or due). Switch off and on alike.
create or replace function private.post_run_settlements(p_run_ids uuid[], p_dates date[], p_chunk integer default 2000)
returns table (run_id uuid, entry_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_bad text;
  v_from integer;
  v_max integer;
  b record;
begin
  if p_chunk is null or p_chunk < 1 then
    raise exception 'post_run_settlements: chunk must be at least 1' using errcode = '22023';
  end if;
  drop table if exists pg_temp._prs;
  create temp table _prs on commit drop as
  select x.ord::integer as ord, r.id, r.organization_id, r.client_organization_id, r.currency, r.number,
         x.on_date, r.settlement_plan as plan,
         coalesce((r.settlement_plan ->> 'settlement')::bigint, 0) as d,
         coalesce((r.settlement_plan ->> 'dc')::bigint, 0) as dc,
         coalesce((r.settlement_plan ->> 'da')::bigint, 0) as da,
         coalesce((r.settlement_plan ->> 'vat_moved')::bigint, 0) as vat,
         -- (M2c-7d-2) the barred part (none until read below)
         '{}'::integer[] as barred, 0::bigint as w, 0::bigint as wc, 0::bigint as wa, 0::bigint as wv
  from unnest(p_run_ids, p_dates) with ordinality x (run_id, on_date, ord)
  cross join lateral (select q.* from public.remittance_run q where q.id = x.run_id offset 0) r;
  select min(p.number) into v_bad from pg_temp._prs p
  where p.d = 0 and exists (select 1 from jsonb_array_elements(coalesce(p.plan -> 'settles', '[]')));
  if v_bad is not null then
    raise exception 'settlement of %: documents to settle with D = 0', v_bad using errcode = '23514';
  end if;
  select min(p.number) into v_bad from pg_temp._prs p where p.d <> 0 and p.dc + p.da <> p.d;
  if v_bad is not null then
    raise exception 'settlement of %: D ≠ Dc + Da', v_bad using errcode = '23514';
  end if;
  -- (M2c-7d-2, §6.2.11 (a) 1) the barred settles, for the runs of a client with an event in effect by the debit's date
  -- ((review round 1, CC-4) runs_with_client_events answers positions in the arrays it is given, rebuilt from _prs in its
  -- order: matched to each run by that position — never by its ord, which a run id naming no run leaves a gap in)
  update pg_temp._prs p set barred = x.barred, w = x.w, wc = x.wc, wa = x.wa, wv = x.wv
  from (select p2.ord, bs.*
        from private.runs_with_client_events(array(select q.client_organization_id from pg_temp._prs q order by q.ord),
                                             array(select q.on_date from pg_temp._prs q order by q.ord)) e
        join (select q.*, (row_number() over (order by q.ord))::integer as pos from pg_temp._prs q) p2 on p2.pos = e.ord
        cross join lateral private.run_barred_settles(p2.plan -> 'settles', p2.on_date) bs
        where p2.d <> 0) x
  where p.ord = x.ord;
  -- never a zero (or, D > 0, negative) allowed settlement while settles remain: the whole plan withheld (W = D)
  update pg_temp._prs p set w = p.d, wc = p.dc, wa = p.da, wv = p.vat,
    barred = array(select g::integer from generate_series(1, jsonb_array_length(coalesce(p.plan -> 'settles', '[]'))) g)
  where p.w > 0 and p.d > 0 and p.d - p.w <= 0;
  select coalesce(max(p.ord), 0) into v_max from pg_temp._prs p;
  drop table if exists pg_temp._prs_posted;
  create temp table _prs_posted (entry_no integer primary key, entry_id uuid not null) on commit drop;
  if exists (select 1 from pg_temp._prs p where p.d <> 0) then
    -- the runs in their order, p_chunk at a time (each chunk one ledger_post_set call): each run's allowed entry
    -- (entry_no its position) and its barred one (v_max + its position)
    for v_from in select g from generate_series(1, (select max(p.ord) from pg_temp._prs p), p_chunk) g loop
      continue when not exists (select 1 from pg_temp._prs p
                                where p.d <> 0 and p.ord between v_from and v_from + p_chunk - 1);
      perform private.ledger_post_set_begin();
      insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                      client_organization_id, source_type, source_id)
      select p.ord, p.organization_id, 'client_settlement', p.on_date, 'settle:' || p.id, p.client_organization_id,
             'remittance_run', p.id::text
      from pg_temp._prs p where p.d <> 0 and p.d - p.w <> 0 and p.ord between v_from and v_from + p_chunk - 1
      union all
      select v_max + p.ord, p.organization_id, 'client_settlement', p.on_date, 'settle:' || p.id || ':barred',
             p.client_organization_id, 'remittance_run', p.id::text
      from pg_temp._prs p where p.d <> 0 and p.w > 0 and p.ord between v_from and v_from + p_chunk - 1;
      insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency)
      select y.entry_no, row_number() over (partition by y.entry_no order by l.o)::integer, l.book, l.amount, y.currency
      from (select p.ord as entry_no, p.currency, p.d - p.w as d, p.dc - p.wc as dc, p.da - p.wa as da,
                   p.vat - p.wv as vat
            from pg_temp._prs p where p.d <> 0 and p.d - p.w <> 0 and p.ord between v_from and v_from + p_chunk - 1
            union all
            select v_max + p.ord, p.currency, p.w, p.wc, p.wa, p.wv
            from pg_temp._prs p where p.d <> 0 and p.w > 0 and p.ord between v_from and v_from + p_chunk - 1) y
      cross join lateral (values (1, 'client_payable', y.d), (2, 'due_to_servicer', -y.d),
                                 (3, 'due_from_client_funds', y.d), (4, 'commission_receivable', -y.dc),
                                 (5, 'client_advance_receivable', -y.da), (6, 'vat_pending', y.vat),
                                 (7, 'vat_collected', -y.vat)) l (o, book, amount)
      where l.amount <> 0;
      insert into pg_temp._prs_posted (entry_no, entry_id)
      select x.entry_no, x.entry_id from private.ledger_post_set() x;
    end loop;
    select min(p.number) into v_bad from pg_temp._prs p
    where p.d <> 0
      and ((p.d - p.w <> 0 and not exists (select 1 from pg_temp._prs_posted x where x.entry_no = p.ord))
           or (p.w > 0 and not exists (select 1 from pg_temp._prs_posted x where x.entry_no = v_max + p.ord)));
    if v_bad is not null then
      raise exception 'settlement of %: not posted', v_bad using errcode = '23514';
    end if;
    -- (M2c-7d-2, §6.2.11 (a) 2) each barred settlement reversed at once, the same day: the one reversal LG003 lets
    -- through (private.ledger_entry_guard), checked at commit (ledger_entry_barred_reversed)
    for b in select p.id, p.client_organization_id, p.on_date, x.entry_id
             from pg_temp._prs p join pg_temp._prs_posted x on x.entry_no = v_max + p.ord
             where p.w > 0 order by p.ord loop
      perform private.ledger_reverse(b.entry_id, 'return:barred:' || b.id,
                                     private.set_off_bar_reason(b.client_organization_id, b.on_date), b.on_date);
    end loop;
    insert into public.commission_settlement (organization_id, client_organization_id, document_kind, document_id,
                                              entry_id, kind, amount_minor, vat_moved_minor, settled_on, run_id)
    select p.organization_id, p.client_organization_id,
           case s.v ->> 'kind' when 'refund' then 'credit_note' when 'advance' then 'advance' else 'invoice' end,
           (s.v ->> 'document_id')::uuid, x.entry_id,
           case s.v ->> 'kind' when 'advance' then 'compensation' else s.v ->> 'kind' end,
           (s.v ->> 'amount')::bigint, (s.v ->> 'vat_moved')::bigint, p.on_date, p.id
    from pg_temp._prs p
    join pg_temp._prs_posted x on x.entry_no = p.ord
    cross join lateral jsonb_array_elements(coalesce(p.plan -> 'settles', '[]')) with ordinality s (v, n)
    where p.d <> 0 and not (s.n::integer = any (p.barred))
    order by p.ord, s.n;
  end if;
  return query select p.id, x.entry_id from pg_temp._prs p left join pg_temp._prs_posted x on x.entry_no = p.ord
               order by p.ord;
end;
$$;

-- (Review round 1, MLAW-2) What the debit of a run's payout on p_on would set off and withhold — post_run_settlements'
-- rule for one run, read by the « Lier » preview before ops confirm a booking: D the frozen plan's settlement; W its
-- settles barred that day (private.run_barred_settles, read only when the client has an event in effect by then); the
-- whole plan withheld when the allowed part would be ≤ 0 while D > 0. allowed = D − W. Keyed: the run by its key, one
-- probe of client_status_event_client_idx.
create function private.run_settlement_split(p_run_id uuid, p_on date)
returns table (allowed bigint, withheld bigint)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select r.d - w.w, w.w
  from (select q.client_organization_id, q.settlement_plan as plan,
               coalesce((q.settlement_plan ->> 'settlement')::bigint, 0) as d
        from public.remittance_run q where q.id = p_run_id offset 0) r
  cross join lateral (
    select case when b.w > 0 and r.d > 0 and r.d - b.w <= 0 then r.d else b.w end as w
    from (select case when r.d <> 0
                       and exists (select 1 from public.client_status_event e
                                   where e.client_organization_id = r.client_organization_id and e.effective_date <= p_on)
                      then (select x.w from private.run_barred_settles(r.plan -> 'settles', p_on) x)
                      else 0 end as w) b) w;
$$;

-- private.transfer_line_preview_of, redefined from 20261117100000_transfer_line_ops.sql (line 1869; same signature and
-- settings, its grants restated below). Review round 1 (MLAW-2): a payout part's settlement_minor is what its booking on
-- the line's date sets off (D − W, private.run_settlement_split), no longer the plan's D, and withheld_minor W what it
-- withholds (posted and reversed at once, given back by the next run): the sheet words both. Nothing else changes.
create or replace function private.transfer_line_preview_of(p_bank_transaction_id uuid, p_parts jsonb, p_pre boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  l public.bank_transaction;
  v_why text;
  v_chk jsonb;
begin
  select * into l from public.bank_transaction where id = p_bank_transaction_id;
  v_why := private.transfer_line_parse(p_parts);
  v_why := coalesce(v_why, private.transfer_line_tenant(l.organization_id));
  if p_pre then
    v_why := coalesce(v_why, private.transfer_line_pre(l.id));
  end if;
  if v_why is not null then
    return jsonb_build_object('ok', false, 'why', v_why, 'detail', null, 'parts', '[]'::jsonb, 'drafts', '[]'::jsonb,
                              'supersedes_file', null, 'expected_text', null);
  end if;
  v_chk := private.transfer_line_check(l.id, false);
  return jsonb_build_object(
    'ok', v_chk ->> 'why' is null, 'why', v_chk ->> 'why', 'detail', v_chk ->> 'detail',
    -- (review round 1, MLAW-2) each payout part: what its booking on the line's date sets off and withholds
    'parts', (select coalesce(jsonb_agg(case when x.p ->> 'kind' = 'payout' and x.p ->> 'run_id' is not null
                                             then x.p || coalesce((select jsonb_build_object(
                                                                    'settlement_minor', s.allowed::text,
                                                                    'withheld_minor', s.withheld::text)
                                                                  from private.run_settlement_split(
                                                                    (x.p ->> 'run_id')::uuid, l.booking_date) s),
                                                                 '{}'::jsonb)
                                             else x.p end order by x.n), '[]')
              from jsonb_array_elements(private.transfer_line_parts_json()) with ordinality x (p, n)),
    'drafts', (select coalesce(jsonb_agg(jsonb_build_object('run_id', d.run_id, 'number', d.number)
                                         order by d.number), '[]') from pg_temp._tl_drafts d),
    'supersedes_file', case when v_chk ->> 'why' is null then private.transfer_line_supersedes(l.id) end,
    'expected_text', case when v_chk ->> 'why' is null then private.transfer_line_text() end);
end;
$$;

-- The run page's withheld set-off (§6.2.11 (a); money staff of the servicer): what the debit withheld (W, from the barred
-- entry's postings), when and why (its reversal's reason), its parts and what the debit set off — (review round 1,
-- TUI-2) from the run's frozen plan: each settle the debit's allowed entry carries (its commission_settlement row) was
-- set off, or paid for a refund; every other one was withheld, a refund among them not paid (so W = the invoices' and
-- the advances' parts − the refund not paid when the whole plan is withheld) — and the run giving W back (the live line
-- of the withheld item): given_back_by once that run is booked and its payout not returned, giving_back_by while it is
-- approved or sent (review round 1, MLAW-4, TUI-3: as a returned payout's repaid_by reads a booked run); null when
-- nothing was withheld. Every read by key: (CC-1) a settle's settlement by its document
-- (commission_settlement_document_idx) and the allowed entry, never the run's settlements by run_id (no index on it).
create function public.remittance_run_withheld(p_run_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select jsonb_build_object(
           'withheld_minor', p.w::text, 'commission_minor', coalesce(pl.c, 0)::text,
           'advances_minor', coalesce(pl.a, 0)::text, 'refund_unpaid_minor', coalesce(pl.rf, 0)::text,
           'withheld_on', b.effective_date, 'reason', x.reason,
           'set_off_commission_minor', coalesce(pl.sc, 0)::text, 'set_off_advances_minor', coalesce(pl.sa, 0)::text,
           'given_back_by', case when g.status = 'booked' and g.returned is not true then g.number end,
           'giving_back_by', case when g.status in ('approved', 'sent') then g.number end)
  from (select r.id, r.organization_id, r.settlement_plan from public.remittance_run r
        where r.id = p_run_id and r.organization_id = any (private.money_staff_org_ids()) offset 0) r
  cross join lateral (select e.id, e.effective_date from public.ledger_entry e
                      where e.organization_id = r.organization_id and e.idempotency_key = 'settle:' || r.id || ':barred'
                      offset 0) b
  cross join lateral (select q.id, q.reason from public.ledger_entry q where q.reverses_entry_id = b.id offset 0) x
  cross join lateral (select coalesce(sum(lp.amount_minor) filter (where la.book = 'client_payable'), 0) as w
                      from (select q.amount_minor, q.ledger_account_id from public.ledger_posting q
                            where q.entry_id = b.id offset 0) lp
                      cross join lateral (select a.book from public.ledger_account a
                                          where a.id = lp.ledger_account_id offset 0) la) p
  left join lateral (select e.id from public.ledger_entry e
                     where e.organization_id = r.organization_id and e.idempotency_key = 'settle:' || r.id
                     offset 0) al on true
  cross join lateral (
    select sum(s.amount) filter (where s.kind = 'compensation' and not s.settled) as c,
           sum(s.amount) filter (where s.kind = 'advance' and not s.settled) as a,
           sum(s.amount) filter (where s.kind = 'refund' and not s.settled) as rf,
           sum(s.amount) filter (where s.kind = 'compensation' and s.settled) as sc,
           sum(s.amount) filter (where s.kind = 'advance' and s.settled) as sa
    from (select v ->> 'kind' as kind, coalesce((v ->> 'amount')::bigint, 0) as amount,
                 exists (select 1
                         from (select q.entry_id from public.commission_settlement q
                               where q.document_id = (v ->> 'document_id')::uuid offset 0) q
                         where q.entry_id = al.id) as settled
          from jsonb_array_elements(case when jsonb_typeof(r.settlement_plan -> 'settles') = 'array'
                                         then r.settlement_plan -> 'settles' else '[]' end) v) s) pl
  left join lateral (select y.number, y.status, y.returned
                     from (select l.run_id from public.remittance_line l
                           where l.ledger_entry_id = x.id and not l.released offset 0) l
                     cross join lateral (select q.number, q.status,
                                                (select t.status = 'returned' from public.bank_transfer t
                                                 where t.id = q.transfer_id) as returned
                                         from public.remittance_run q where q.id = l.run_id offset 0) y
                     limit 1) g on true;
$$;


------------------------------------------------------------------------------------------
-- The withheld item's deadline and schedule (§6.2.11 (a) 7, 8b)
------------------------------------------------------------------------------------------

-- (Review round 1, CC-5) The prepare's held items (jobs/remittances.py HELD_TO_SQL, private.pending_item_deadlines'
-- twin for the items a draft reserved): a payout that came back, the item an unplanned payout's reversal re-owed and
-- (M2c-7d-2) a withheld settlement, each with the R124-6 basis it keeps — its E, its terms and their delay. Moved from
-- the worker's own statement (6b-2b's two branches, 7d-2's third: the body unchanged, the run its one parameter) into
-- a function whose seq scans are off: generic under the statistics the scale files leave (the reserved items' run at
-- two values, the lines' run at two), that statement read the whole queue three times and the withheld run's lines
-- whole (test_set_off_bar_reads_integration). Each read is by key: the reserved items by remittance_pending_run_idx,
-- each entry by its primary key, each run's lines by the primary key's prefix.
create function private.draft_held_items(p_run uuid)
returns table (ledger_entry_id uuid, encaissement_date date, terms_id uuid, days integer)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
    select q.ledger_entry_id, rl.encaissement_date, coalesce(t.id, ti.id),
           coalesce(t.days, ti.days, 30)
    from private.remittance_pending q
    cross join lateral (select le.reverses_entry_id from public.ledger_entry le
                        where le.id = q.ledger_entry_id offset 0) e
    cross join lateral (select re.source_id from public.ledger_entry re
                        where re.id = e.reverses_entry_id and re.entry_type = 'remittance'
                          and re.source_type = 'bank_transfer' offset 0) re
    cross join lateral (select bt.run_id from public.bank_transfer bt
                        where bt.id = case when pg_input_is_valid(re.source_id, 'uuid')
                                           then re.source_id::uuid end
                          and (bt.entry_id = e.reverses_entry_id
                               or exists (select 1 from public.bank_line_booking k
                                          where k.entry_id = e.reverses_entry_id
                                            and k.kind = 'payout' and k.transfer_id = bt.id))
                        offset 0) bt
    cross join lateral (select l.encaissement_date, l.mandate_id, l.mandate_terms_id
                        from (select x.* from public.remittance_line x where x.run_id = bt.run_id offset 0) l
                        where l.amount_minor > 0
                          and not l.released and l.latest_execution_date is not null
                          and l.encaissement_date is not null
                        order by l.latest_execution_date, l.line_no limit 1) rl
    left join lateral (select mt.id, mt.remittance_max_days as days
                       from public.mandate_terms mt
                       where mt.mandate_id = rl.mandate_id
                         and mt.valid_from <= rl.encaissement_date
                         and (mt.valid_to is null or rl.encaissement_date < mt.valid_to)
                       limit 1) t on true
    left join lateral (select mt.id, mt.remittance_max_days as days
                       from public.mandate_terms mt
                       where rl.mandate_id is null and mt.id = rl.mandate_terms_id
                       offset 0) ti on true
    where q.draft_run_id = p_run and q.kind = 'payout_returned'
      and q.amount_minor > 0
    union all
    select q.ledger_entry_id, rl.encaissement_date, coalesce(t.id, ti.id),
           coalesce(t.days, ti.days, 30)
    from private.remittance_pending q
    cross join lateral (select le.reverses_entry_id from public.ledger_entry le
                        where le.id = q.ledger_entry_id offset 0) e
    cross join lateral (select re.id from public.ledger_entry re
                        where re.id = e.reverses_entry_id and re.entry_type = 'remittance'
                        offset 0) re
    cross join lateral (
      select l.encaissement_date, l.mandate_id, l.mandate_terms_id
      from (select u.ledger_entry_id from private.unplanned_paid_item u
            where u.booking_entry_id = re.id offset 0) u
      cross join lateral (select x.encaissement_date, x.mandate_id, x.mandate_terms_id,
                                 x.latest_execution_date, x.run_id, x.line_no,
                                 x.amount_minor
                          from public.remittance_line x
                          where x.ledger_entry_id = u.ledger_entry_id and not x.released
                          offset 0) l
      where l.amount_minor > 0 and l.latest_execution_date is not null
        and l.encaissement_date is not null
      order by l.latest_execution_date, l.run_id, l.line_no limit 1) rl
    left join lateral (select mt.id, mt.remittance_max_days as days
                       from public.mandate_terms mt
                       where mt.mandate_id = rl.mandate_id
                         and mt.valid_from <= rl.encaissement_date
                         and (mt.valid_to is null or rl.encaissement_date < mt.valid_to)
                       limit 1) t on true
    left join lateral (select mt.id, mt.remittance_max_days as days
                       from public.mandate_terms mt
                       where rl.mandate_id is null and mt.id = rl.mandate_terms_id
                       offset 0) ti on true
    where q.draft_run_id = p_run and q.kind = 'payout_returned'
      and q.amount_minor > 0
    union all
    select q.ledger_entry_id, rl.encaissement_date, coalesce(t.id, ti.id),
           coalesce(t.days, ti.days, 30)
    from private.remittance_pending q
    cross join lateral (select le.reverses_entry_id from public.ledger_entry le
                        where le.id = q.ledger_entry_id offset 0) e
    cross join lateral (select re.source_id from public.ledger_entry re
                        where re.id = e.reverses_entry_id and re.entry_type = 'client_settlement'
                          and re.source_type = 'remittance_run' offset 0) re
    cross join lateral (select l.encaissement_date, l.mandate_id, l.mandate_terms_id
                        from (select x.* from public.remittance_line x
                              where x.run_id = case when pg_input_is_valid(re.source_id, 'uuid')
                                                    then re.source_id::uuid end offset 0) l
                        where l.amount_minor > 0 and not l.released
                          and l.latest_execution_date is not null
                          and l.encaissement_date is not null
                        order by l.latest_execution_date, l.line_no limit 1) rl
    left join lateral (select mt.id, mt.remittance_max_days as days
                       from public.mandate_terms mt
                       where mt.mandate_id = rl.mandate_id
                         and mt.valid_from <= rl.encaissement_date
                         and (mt.valid_to is null or rl.encaissement_date < mt.valid_to)
                       limit 1) t on true
    left join lateral (select mt.id, mt.remittance_max_days as days
                       from public.mandate_terms mt
                       where rl.mandate_id is null and mt.id = rl.mandate_terms_id
                       offset 0) ti on true
    where q.draft_run_id = p_run and q.kind = 'settlement_withheld'
      and q.amount_minor > 0;
$$;

-- private.pending_item_deadlines, redefined from 20261118100000_switch_on_prerequisites_2.sql (line 2775; same signature
-- and settings, its grants restated below). M2c-7d-2 (plan §6.2.11 (a) 7): a settlement_withheld item is held to the
-- R124-6 date of the run it was withheld from (its own branch, as a returned payout's). A breach is recorded as for any
-- late item, with no blocked reason: the delay is the servicer's own withholding. Nothing else changes.
create or replace function private.pending_item_deadlines(p_organization_id uuid,
                                                          p_unreserved_only boolean default false)
returns table (ledger_entry_id uuid, client_organization_id uuid, currency char(3), amount_minor bigint,
               draft_run_id uuid, payment_id uuid, monitored boolean, encaissement_date date, max_days integer,
               deadline date, latest_execution_date date, alert_soon_date date, alert_critical_date date,
               unmeetable boolean, check_deadline date, check_latest_execution_date date, check_alert_soon_date date,
               check_alert_critical_date date, out_of_horizon boolean)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  with items as materialized (
    select q.ledger_entry_id, q.client_organization_id, q.currency, q.amount_minor, q.draft_run_id, e.payment_id,
           x.e_date, coalesce(t.days, 30) as days, f.mandate_id
    from private.remittance_pending q
    join lateral (select le.payment_id, le.account_id from public.ledger_entry le
                  where le.id = q.ledger_entry_id offset 0) e on true
    left join lateral (select private.encaissement_date(p.booking_date, p.value_date) as e_date,
                              coalesce(e.account_id, p.account_id) as account_id
                       from public.payment p where p.id = e.payment_id offset 0) x on true
    left join lateral (select pf.mandate_id
                       from public.account a join public.portfolio pf on pf.id = a.portfolio_id
                       where a.id = coalesce(x.account_id, e.account_id) offset 0) f on true
    left join lateral (select mt.remittance_max_days as days from public.mandate_terms mt
                       where mt.mandate_id = f.mandate_id and mt.valid_from <= x.e_date
                         and (mt.valid_to is null or x.e_date < mt.valid_to)
                       limit 1) t on true
    where q.organization_id = p_organization_id and q.amount_minor > 0 and q.kind in ('allocation', 'forward')
      and (not p_unreserved_only or q.draft_run_id is null)
    union all
    -- M2c-6b-1 (design §9.2, Q7's default): a payout that came back is held to the earliest date of the returned run's
    -- positive live lines — its E and its mandate's delay, those of the line with the earliest latest execution date
    -- (the reversal → the reversed remittance → its transfer → its run → its lines, each by key). A line that is itself
    -- a re-proposed payout (returned a second time) has no mandate (the worker's prepare: no file, no mandate's gross)
    -- but the terms version it was held to: that version gives the delay and the mandate (monitored), as the worker's
    -- prepare reads it (jobs/remittances.py _held_to; review M2c-6b-1 legal-texts#1 item 3, parity)
    select q.ledger_entry_id, q.client_organization_id, q.currency, q.amount_minor, q.draft_run_id, rl.payment_id,
           rl.encaissement_date, coalesce(t.days, ti.days, 30), coalesce(rl.mandate_id, ti.mandate_id)
    from private.remittance_pending q
    cross join lateral (select le.reverses_entry_id from public.ledger_entry le
                        where le.id = q.ledger_entry_id offset 0) e
    cross join lateral (select re.source_id from public.ledger_entry re
                        where re.id = e.reverses_entry_id and re.entry_type = 'remittance'
                          and re.source_type = 'bank_transfer' offset 0) re
    cross join lateral (select bt.run_id from public.bank_transfer bt
                        where bt.id = case when pg_input_is_valid(re.source_id, 'uuid') then re.source_id::uuid end
                          -- M2c-6b-2b (critic F11, L4): the transfer's own planned remittance only — M2c-6b-3a-2
                          -- (F): a late predecessor's is its payout booking's entry (by the booking's unique entry)
                          and (bt.entry_id = e.reverses_entry_id
                               or exists (select 1 from public.bank_line_booking k
                                          where k.entry_id = e.reverses_entry_id and k.kind = 'payout'
                                            and k.transfer_id = bt.id))
                        offset 0) bt
    cross join lateral (select l.payment_id, l.encaissement_date, l.mandate_id, l.mandate_terms_id
                        from (select x.* from public.remittance_line x where x.run_id = bt.run_id offset 0) l
                        where l.amount_minor > 0 and not l.released
                          and l.latest_execution_date is not null and l.encaissement_date is not null
                        order by l.latest_execution_date, l.line_no limit 1) rl
    left join lateral (select mt.remittance_max_days as days from public.mandate_terms mt
                       where mt.mandate_id = rl.mandate_id and mt.valid_from <= rl.encaissement_date
                         and (mt.valid_to is null or rl.encaissement_date < mt.valid_to)
                       limit 1) t on true
    left join lateral (select mt.mandate_id, mt.remittance_max_days as days from public.mandate_terms mt
                       where rl.mandate_id is null and mt.id = rl.mandate_terms_id offset 0) ti on true
    where q.organization_id = p_organization_id and q.amount_minor > 0 and q.kind = 'payout_returned'
      and (not p_unreserved_only or q.draft_run_id is null)
    union all
    -- M2c-6b-2b (critic2 ML-2): the re-owed item of an unplanned remittance returned after a run froze the items its
    -- P paid (their clocks ended at that run, the −A row netting them) is held like a planned return: to the earliest
    -- latest execution date of those items' live lines — the reversal → the reversed remittance → its attributions
    -- (private.unplanned_paid_item by booking_entry_id) → each item's live line (remittance_line_live_uq), each by key —
    -- its E, mandate and terms version as the planned branch reads them. While those items are still pending: no line,
    -- no deadline (critic F11, L4: they keep their own clocks, Q15's default). Parity: jobs/remittances.py _held_to
    select q.ledger_entry_id, q.client_organization_id, q.currency, q.amount_minor, q.draft_run_id, rl.payment_id,
           rl.encaissement_date, coalesce(t.days, ti.days, 30), coalesce(rl.mandate_id, ti.mandate_id)
    from private.remittance_pending q
    cross join lateral (select le.reverses_entry_id from public.ledger_entry le
                        where le.id = q.ledger_entry_id offset 0) e
    cross join lateral (select re.id from public.ledger_entry re
                        where re.id = e.reverses_entry_id and re.entry_type = 'remittance' offset 0) re
    cross join lateral (select l.payment_id, l.encaissement_date, l.mandate_id, l.mandate_terms_id
                        from (select u.ledger_entry_id from private.unplanned_paid_item u
                              where u.booking_entry_id = re.id offset 0) u
                        cross join lateral (select x.payment_id, x.encaissement_date, x.mandate_id, x.mandate_terms_id,
                                                   x.latest_execution_date, x.run_id, x.line_no, x.amount_minor
                                            from public.remittance_line x
                                            where x.ledger_entry_id = u.ledger_entry_id and not x.released offset 0) l
                        where l.amount_minor > 0 and l.latest_execution_date is not null
                          and l.encaissement_date is not null
                        order by l.latest_execution_date, l.run_id, l.line_no limit 1) rl
    left join lateral (select mt.remittance_max_days as days from public.mandate_terms mt
                       where mt.mandate_id = rl.mandate_id and mt.valid_from <= rl.encaissement_date
                         and (mt.valid_to is null or rl.encaissement_date < mt.valid_to)
                       limit 1) t on true
    left join lateral (select mt.mandate_id, mt.remittance_max_days as days from public.mandate_terms mt
                       where rl.mandate_id is null and mt.id = rl.mandate_terms_id offset 0) ti on true
    where q.organization_id = p_organization_id and q.amount_minor > 0 and q.kind = 'payout_returned'
      and (not p_unreserved_only or q.draft_run_id is null)
    union all
    -- (M2c-7d-2, plan §6.2.11 (a) 7) a withheld settlement is held to the R124-6 date of the run it was withheld from:
    -- the reversal → the reversed barred settlement (its source the run) → that run's positive, live, dated line with the
    -- earliest latest execution date, its terms and delay — as a returned payout follows its transfer's run (each by
    -- key). The worker's twin, jobs/remittances.py HELD_TO_SQL, alike
    select q.ledger_entry_id, q.client_organization_id, q.currency, q.amount_minor, q.draft_run_id, rl.payment_id,
           rl.encaissement_date, coalesce(t.days, ti.days, 30), coalesce(rl.mandate_id, ti.mandate_id)
    from private.remittance_pending q
    cross join lateral (select le.reverses_entry_id from public.ledger_entry le
                        where le.id = q.ledger_entry_id offset 0) e
    cross join lateral (select re.source_id from public.ledger_entry re
                        where re.id = e.reverses_entry_id and re.entry_type = 'client_settlement'
                          and re.source_type = 'remittance_run' offset 0) re
    cross join lateral (select l.payment_id, l.encaissement_date, l.mandate_id, l.mandate_terms_id
                        from (select x.* from public.remittance_line x
                              where x.run_id = case when pg_input_is_valid(re.source_id, 'uuid')
                                                    then re.source_id::uuid end offset 0) l
                        where l.amount_minor > 0 and not l.released
                          and l.latest_execution_date is not null and l.encaissement_date is not null
                        order by l.latest_execution_date, l.line_no limit 1) rl
    left join lateral (select mt.remittance_max_days as days from public.mandate_terms mt
                       where mt.mandate_id = rl.mandate_id and mt.valid_from <= rl.encaissement_date
                         and (mt.valid_to is null or rl.encaissement_date < mt.valid_to)
                       limit 1) t on true
    left join lateral (select mt.mandate_id, mt.remittance_max_days as days from public.mandate_terms mt
                       where rl.mandate_id is null and mt.id = rl.mandate_terms_id offset 0) ti on true
    where q.organization_id = p_organization_id and q.amount_minor > 0 and q.kind = 'settlement_withheld'
      and (not p_unreserved_only or q.draft_run_id is null)),
  mon as (
    select k.mandate_id, exists (select 1 from public.mandate_terms v where v.mandate_id = k.mandate_id) as monitored
    from (select distinct i.mandate_id from items i where i.mandate_id is not null) k),
  -- one deadline per distinct (E, delay), whatever the estimates (review perf#0, round 2: an inlined CTE was joined
  -- first and its deadline computed once per item when the queue had no statistics)
  dl as materialized (
    select k.e_date, k.days, d.*
    from (select distinct i.e_date, i.days from items i where i.e_date is not null) k
    cross join lateral private.remittance_deadline_or_null(k.e_date, k.days) d),
  m as materialized (   -- one month, for the delays that cannot be met: once per distinct E
    select k.e_date, d.*
    from (select distinct dl.e_date from dl where dl.unmeetable) k
    cross join lateral private.remittance_deadline_or_null(k.e_date, 30) d)
  select i.ledger_entry_id, i.client_organization_id, i.currency, i.amount_minor, i.draft_run_id, i.payment_id,
         coalesce(mon.monitored, false), i.e_date, i.days, dl.deadline, dl.latest_execution_date, dl.alert_soon_date,
         dl.alert_critical_date, coalesce(dl.unmeetable, false),
         case when dl.unmeetable then m.deadline else dl.deadline end,
         case when dl.unmeetable then m.latest_execution_date else dl.latest_execution_date end,
         case when dl.unmeetable then m.alert_soon_date else dl.alert_soon_date end,
         case when dl.unmeetable then m.alert_critical_date else dl.alert_critical_date end,
         coalesce(dl.out_of_horizon, false) or coalesce(m.out_of_horizon, false)
  from items i
  left join mon on mon.mandate_id = i.mandate_id
  left join dl on dl.e_date = i.e_date and dl.days = i.days
  left join m on m.e_date = i.e_date and dl.unmeetable;
$$;

-- private.remittance_schedule_candidates, dropped and recreated from 20261112090000_remittance_runs.sql (line 2421; one
-- column more, last: settlement_withheld; its grants restated below as at :3544, :3559). M2c-7d-2 ([check 2] gap 3, plan
-- §6.2.11 (a) 8b): whether a withheld settlement waits unreserved — the schedule then drafts a run under its own trigger
-- at its next hour, on any day (jobs/remittances.py _schedule_trigger). `set enable_seqscan = off` added (the queue by
-- the servicer's key whatever the statistics; the deadlines' read had it already). Nothing else changes.
drop function private.remittance_schedule_candidates(uuid, date);
create function private.remittance_schedule_candidates(p_organization_id uuid, p_today date)
returns table (client_organization_id uuid, currency char(3), terms jsonb[], payout_returned boolean,
               latest_execution_dates date[], settlement_withheld boolean)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  with c as (
    select q.client_organization_id, q.currency, bool_or(q.kind = 'payout_returned') as payout_returned,
           bool_or(q.kind = 'settlement_withheld') as settlement_withheld
    from private.remittance_pending q
    where q.organization_id = p_organization_id and q.draft_run_id is null
    group by q.client_organization_id, q.currency),
  d as (select * from private.pending_item_deadlines(p_organization_id, true))
  select c.client_organization_id, c.currency,
         coalesce((select array_agg(mt.remittance_terms order by mt.id) from public.mandate m
                   join public.mandate_terms mt on mt.mandate_id = m.id and mt.valid_from <= p_today
                     and (mt.valid_to is null or p_today < mt.valid_to)
                   where m.client_organization_id = c.client_organization_id and mt.remittance_terms is not null),
                  '{}'),
         c.payout_returned,
         coalesce((select array_agg(d.latest_execution_date order by d.latest_execution_date) from d
                   where d.client_organization_id = c.client_organization_id and d.currency = c.currency
                     and d.latest_execution_date is not null), '{}'),
         c.settlement_withheld
  from c
  where not exists (select 1 from public.remittance_run r where r.client_organization_id = c.client_organization_id
                      and r.currency = c.currency and r.status in ('draft', 'approved', 'sent'));
$$;

------------------------------------------------------------------------------------------
-- The run's own invoice's payment line ([critic] L1, §6.4)
------------------------------------------------------------------------------------------

-- private.issue_commission_documents, redefined from 20261114090000_manual_credit_note.sql (line 1994; same signature and
-- settings, its grants restated below). M2c-7d-2 (plan §6.4 [critic] L1): a run's invoice its plan may not set off (born
-- before the client's opening, a liquidation, a seizure) carries the draft's `payment_note` into its frozen payload —
-- the line the PDF prints in place of « par compensation » (remittance/invoice.py _payment_line); a document without one
-- is frozen as before, to the byte. Nothing else changes.
create or replace function private.issue_commission_documents(p_organization_id uuid, p_client_organization_id uuid,
                                                              p_run_id uuid, p_docs jsonb, p_reason text,
                                                              p_vat_on_debits boolean default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_set public.servicer_billing_settings;
  v_series text;
  v_on_debits boolean;
  v_issue date;
  v_last integer;
  v_n integer := jsonb_array_length(p_docs);
  v_run public.remittance_run;
  v_out jsonb := '{}';
  v_doc record;
  v_seller jsonb;
  v_buyer jsonb;
  v_own jsonb;
  v_professional boolean;
  v_proceeding jsonb;
  v_plan jsonb;
  v_transfer boolean;
  v_exec date;
begin
  if v_n = 0 then
    return jsonb_build_object('issue_date', null, 'documents', '{}'::jsonb);
  end if;
  -- the settings in force at issue, held to the commit (the payload freezes them: L441-9, legal review #4)
  select * into v_set from public.servicer_billing_settings s where s.organization_id = p_organization_id for share;
  v_series := coalesce(v_set.invoice_prefix, 'FC');
  -- the VAT book of the invoices: the one their plan assumed (the approval checked it is still the servicer's), else
  -- the servicer's now (money review #1)
  v_on_debits := coalesce(p_vat_on_debits, v_set.vat_on_debits, false);
  select * into v_run from public.remittance_run where id = p_run_id;
  -- Numbered on the transaction's Paris day: the counter of its year created if needed and locked in one statement
  -- (the year of the issue date). The ledger dates entries up to the transaction's day (paris_today() = now()): a
  -- clock past midnight once the counter is ours means the transaction began the day before; it is retried in a
  -- fresh one rather than refused as data (numbering review #1). The dates then follow the numbers.
  v_issue := private.paris_today();
  insert into private.invoice_counter as c (organization_id, series, year, last_seq, last_issue_date)
  values (p_organization_id, v_series, extract(year from v_issue)::integer, v_n, v_issue)
  on conflict (organization_id, series, year)
    do update set last_seq = c.last_seq + excluded.last_seq, last_issue_date = excluded.last_issue_date
  returning c.last_seq - v_n into v_last;
  if (clock_timestamp() at time zone 'Europe/Paris')::date <> v_issue then
    raise exception 'commission documents: the day turned during the transaction, retry' using errcode = '40001';
  end if;

  -- the parties, the indemnity (L441-9 I, L441-10 II, D441-5: 40 €, stated to every professional buyer; the latest
  -- proceeding of the client recorded by the issue date kept beside it, for the dunning step), the own account a due
  -- invoice is paid to
  v_seller := private.invoice_party(p_organization_id);
  v_buyer := private.invoice_party(p_client_organization_id);
  v_professional := coalesce((v_buyer ->> 'is_professional')::boolean, false);
  select jsonb_build_object('kind', e.kind, 'effective_date', e.effective_date) into v_proceeding
  from public.client_status_event e
  where e.client_organization_id = p_client_organization_id and e.kind in ('proceeding_opened', 'liquidation')
    and e.effective_date <= v_issue
  order by e.effective_date desc, e.recorded_at desc, e.id desc limit 1;
  select jsonb_build_object('iban', b.iban, 'bic', b.bic, 'holder', o.legal_name) into v_own
  from public.bank_account b join public.organization o on o.id = b.organization_id
  where b.id = v_set.own_bank_account_id;
  -- an approval's netted documents are set off with its run, as far as its settlement plan (the draft's, approved
  -- here) sets them off: on its payout of the requested date, or on the approval date when nothing is transferred
  -- (N = 0, the plan posted at approval); a due document's date is its due date (legal review #4, round 2)
  if p_reason = 'commission' and v_run.id is not null then
    select d.plan into v_plan from private.remittance_draft d where d.run_id = v_run.id;
    v_transfer := coalesce(v_run.net_minor, 0) > 0;
    v_exec := coalesce(v_run.requested_execution_date, v_issue);
  end if;

  drop table if exists pg_temp._docs;
  create temp table _docs on commit drop as
  select x.ord::integer as entry_no, (x.doc ->> 'id')::uuid as id, x.doc ->> 'ref' as ref, x.doc ->> 'key' as key,
         x.doc ->> 'kind' as kind, (x.doc ->> 'mandate_id')::uuid as mandate_id,
         (x.doc ->> 'ht')::bigint as ht, (x.doc ->> 'vat')::bigint as vat, (x.doc ->> 'ttc')::bigint as ttc,
         (x.doc ->> 'vat_rate')::numeric as vat_rate,
         case when x.doc ->> 'kind' = 'invoice' and x.doc ->> 'settlement' = 'due' then 'due' else 'netted' end
           as settlement,
         -- what the run's plan sets off on this document (a run's own documents only)
         pl.planned,
         -- a due invoice's date, a corrective invoice's set off on the next run at the latest by then (OQ-72), and
         -- the date by which the next run sets off what this run's plan leaves of a netted invoice (legal#4): the
         -- mandate's term, 30 days without one, never more than 45 after issue (L441-10 I)
         case when x.doc ->> 'kind' = 'invoice'
                   and (x.doc ->> 'settlement' = 'due' or x.doc ->> 'payment' = 'next_run'
                        or (v_plan is not null and pl.planned < (x.doc ->> 'ttc')::bigint))
              then v_issue + least(coalesce((x.doc ->> 'due_days')::integer, tm.days, 30), 45) end as due_date,
         (x.doc ->> 'due_days')::integer as due_days, x.doc,
         coalesce((x.doc ->> 'service_from')::date, v_run.service_from) as service_from,
         coalesce((x.doc ->> 'service_to')::date, v_run.service_to) as service_to,
         v_last + x.ord::integer as seq,
         coalesce((select sum((c ->> 'vat_pending')::bigint) from jsonb_array_elements(x.doc -> 'corrections') c), 0)
           as v_pending,
         coalesce((select sum((c ->> 'vat_collected')::bigint) from jsonb_array_elements(x.doc -> 'corrections') c), 0)
           as v_collected
  from jsonb_array_elements(p_docs) with ordinality x (doc, ord)
  cross join lateral (select coalesce(sum((s ->> 'amount')::bigint), 0)::bigint as planned
                      from jsonb_array_elements(coalesce(v_plan -> 'settles', '[]')) s
                      where s ->> 'ref' = x.doc ->> 'ref') pl
  left join lateral (select (mt.remittance_terms ->> 'invoice_payment_days')::integer as days
                     from public.mandate_terms mt
                     where mt.mandate_id = (x.doc ->> 'mandate_id')::uuid and mt.valid_from <= v_issue
                       and (mt.valid_to is null or v_issue < mt.valid_to)
                     order by mt.valid_from desc limit 1) tm on true;
  if exists (select 1 from pg_temp._docs where kind not in ('invoice', 'credit_note') or ttc <> ht + vat
               or (kind = 'invoice' and (ht <= 0 or vat < 0)) or (kind = 'credit_note' and (ht >= 0 or vat > 0
                   or v_pending + v_collected <> -vat)))
     or exists (select 1 from pg_temp._docs d cross join lateral jsonb_array_elements(coalesce(d.doc -> 'corrections', '[]')) c
                where (c ->> 'vat_pending')::bigint < 0 or (c ->> 'vat_collected')::bigint < 0) then
    raise exception 'commission documents: amounts out of shape' using errcode = '23514';
  end if;

  perform private.ledger_post_set_begin();
  -- the engine and the run's inputs hash on each entry (ADR-0012: what computed it)
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                  client_organization_id, source_type, source_id, reason, engine_version,
                                  inputs_hash)
  select d.entry_no, p_organization_id,
         case d.kind when 'invoice' then 'commission_invoice' else 'commission_credit_note' end, v_issue, d.key,
         p_client_organization_id, 'commission_invoice', d.id::text, null,
         case when v_run.inputs_hash is not null then coalesce(v_run.engine_version, 'commission-1') end,
         v_run.inputs_hash
  from pg_temp._docs d;
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency)
  select l.entry_no, row_number() over (partition by l.entry_no order by l.o)::integer, l.book, l.amount, 'EUR'
  from (select d.entry_no, 1 as o, 'commission_receivable' as book, d.ttc as amount from pg_temp._docs d
        union all select d.entry_no, 2, 'servicer_revenue', -d.ht from pg_temp._docs d
        union all select d.entry_no, 3, case when v_on_debits then 'vat_collected' else 'vat_pending' end, -d.vat
          from pg_temp._docs d where d.kind = 'invoice' and d.vat > 0
        union all select d.entry_no, 3, 'vat_pending', d.v_pending from pg_temp._docs d
          where d.kind = 'credit_note' and d.v_pending > 0
        union all select d.entry_no, 4, 'vat_collected', d.v_collected from pg_temp._docs d
          where d.kind = 'credit_note' and d.v_collected > 0) l;
  drop table if exists pg_temp._doc_entries;
  create temp table _doc_entries on commit drop as select * from private.ledger_post_set();

  for v_doc in select x.*, e.entry_id from pg_temp._docs x join pg_temp._doc_entries e on e.entry_no = x.entry_no
           order by x.seq loop
    insert into public.commission_invoice (id, organization_id, client_organization_id, mandate_id, run_id, kind,
                                           series, year, seq, number, issue_date, service_from, service_to, currency,
                                           ht_minor, vat_rate, vat_minor, ttc_minor, vat_book, settlement, due_date,
                                           reason, payload, payload_sha256, ledger_entry_id)
    select v_doc.id, p_organization_id, p_client_organization_id, v_doc.mandate_id, p_run_id, v_doc.kind, v_series,
           extract(year from v_issue)::integer, v_doc.seq,
           v_series || '-' || extract(year from v_issue)::integer || '-' || lpad(v_doc.seq::text, 6, '0'), v_issue,
           v_doc.service_from, v_doc.service_to, 'EUR', v_doc.ht, case when v_doc.kind = 'invoice' then v_doc.vat_rate end,
           v_doc.vat,
           v_doc.ttc, case when v_doc.kind = 'invoice' then case when v_on_debits then 'vat_collected' else 'vat_pending' end end,
           v_doc.settlement, v_doc.due_date,
           p_reason, y.payload, encode(sha256(convert_to(y.payload::text, 'UTF8')), 'hex'), v_doc.entry_id
    from (select jsonb_build_object(
            'kind', v_doc.kind,
            'number', v_series || '-' || extract(year from v_issue)::integer || '-' || lpad(v_doc.seq::text, 6, '0'),
            'issue_date', v_issue,
            'seller', v_seller,
            'buyer', v_buyer,
            'mandate', (select jsonb_build_object('id', m.id, 'reference', m.reference) from public.mandate m
                        where m.id = v_doc.mandate_id),
            'run', case when v_run.id is not null then jsonb_build_object('id', v_run.id, 'number', v_run.number) end,
            'service_period', jsonb_build_object('from', v_doc.service_from, 'to', v_doc.service_to),
            'lines', coalesce(v_doc.doc -> 'lines', '[]'),
            -- per invoice it rectifies, its HT and VAT once this note is applied, all its credit notes included
            -- (M2c-5b review legal#1: « le montant du total hors taxes et de la TVA due après application de la
            -- réduction de prix », BOI-TVA-DECLA-30-20-20-20 §260, BOI-TVA-DED-40-10-20 §80)
            'corrections', (select coalesce(jsonb_agg(x.c || jsonb_build_object(
                                     'ht_after', (o.ht_minor + pc.ht + ea.ht + (x.c ->> 'ht')::bigint)::text,
                                     'vat_after', (o.vat_minor + pc.vat + ea.vat + (x.c ->> 'vat')::bigint)::text)
                                   order by x.ord), '[]')
                            from jsonb_array_elements(coalesce(v_doc.doc -> 'corrections', '[]'))
                              with ordinality x (c, ord)
                            cross join lateral (select q.ht_minor, q.vat_minor from public.commission_invoice q
                                                where q.id = (x.c ->> 'original_invoice_id')::uuid offset 0) o
                            cross join lateral (select coalesce(sum(y.ht_minor), 0) as ht,
                                                       coalesce(sum(y.vat_minor), 0) as vat
                                                from public.commission_credit_correction y
                                                where y.original_invoice_id = (x.c ->> 'original_invoice_id')::uuid) pc
                            cross join lateral (select coalesce(sum((z ->> 'ht')::bigint), 0) as ht,
                                                       coalesce(sum((z ->> 'vat')::bigint), 0) as vat
                                                from pg_temp._docs d2
                                                cross join lateral jsonb_array_elements(
                                                  coalesce(d2.doc -> 'corrections', '[]')) z
                                                where d2.seq < v_doc.seq
                                                  and z ->> 'original_invoice_id' = x.c ->> 'original_invoice_id') ea),
            'totals', jsonb_build_object('ht_minor', v_doc.ht::text, 'vat_minor', v_doc.vat::text, 'ttc_minor', v_doc.ttc::text,
                                         'vat_rate', v_doc.vat_rate::text, 'currency', 'EUR'),
            'settlement', jsonb_build_object('mode', v_doc.settlement, 'clause_ref', v_doc.doc ->> 'clause_ref',
                                             'due_days', v_doc.due_days),
            -- the mentions that change over time, as in force at issue (L441-9 I; legal review #4)
            'due_date', v_doc.due_date,
            -- netted documents only: what the run sets off (its payout of the requested date; the approval date and
            -- no transfer when N = 0) and the remainder set off on the next run by a date, or all of it on the next
            -- run by a date; a due one is paid by its due date to the own account below
            'payment_reference', case when v_doc.settlement = 'netted' then
                                   case when v_doc.doc ->> 'payment' = 'next_run'
                                          or (v_plan is not null and v_doc.kind = 'invoice' and v_doc.planned = 0)
                                        then jsonb_build_object('mode', 'next_run', 'latest_date', v_doc.due_date)
                                             || case when v_plan is not null
                                                     then jsonb_build_object('amount_minor', v_doc.ttc::text)
                                                     else '{}' end
                                        when v_plan is not null
                                        then jsonb_build_object('mode', 'run', 'run_number', v_run.number,
                                                                'execution_date', v_exec, 'transfer', v_transfer,
                                                                'amount_minor', v_doc.planned::text)
                                             || case when v_doc.kind = 'invoice' and v_doc.planned < v_doc.ttc
                                                     then jsonb_build_object(
                                                            'remainder_minor', (v_doc.ttc - v_doc.planned)::text,
                                                            'latest_date', v_doc.due_date)
                                                     else '{}' end
                                        when p_reason = 'commission' and v_run.id is not null
                                        then jsonb_build_object('mode', 'run', 'run_number', v_run.number,
                                                                'execution_date', v_exec, 'transfer', v_transfer)
                                   end end,
            'own_account', case when v_doc.settlement = 'due' then v_own end,
            'penalty_text', coalesce(v_set.penalty_text,
              'Pénalités de retard : taux d''intérêt appliqué par la Banque centrale européenne à son opération de '
              'refinancement la plus récente, majoré de 10 points de pourcentage.'),
            'flat_indemnity', jsonb_build_object('applies', v_professional,
                                                 'amount_minor', case when v_professional then '4000' end,
                                                 'proceeding', v_proceeding),
            'vat_on_debits', v_on_debits,
            'reason', p_reason)
          -- (M2c-7d-2, plan §6.4 [critic] L1) a run's invoice its plan could not set off: its payment line
          || case when v_doc.doc ? 'payment_note'
                  then jsonb_build_object('payment_note', v_doc.doc -> 'payment_note') else '{}'::jsonb end
          as payload) y;
    v_out := v_out || jsonb_build_object(v_doc.ref, jsonb_build_object(
      'id', v_doc.id, 'number', v_series || '-' || extract(year from v_issue)::integer || '-' || lpad(v_doc.seq::text, 6, '0')));
  end loop;

  insert into public.commission_invoice_line (invoice_id, line_no, kind, designation_fr, claim_type_code, rule_id,
                                              families, tiers, ht_minor, vat_rate, original_invoice_id)
  select d.id, l.ord::integer, l.line ->> 'kind', l.line ->> 'designation_fr', l.line ->> 'claim_type',
         l.line ->> 'rule_id', coalesce(array(select jsonb_array_elements_text(l.line -> 'families')), '{}'),
         coalesce(l.line -> 'tiers', '[]'), (l.line ->> 'ht')::bigint, (l.line ->> 'vat_rate')::numeric,
         (l.line ->> 'original_invoice_id')::uuid
  from pg_temp._docs d cross join lateral jsonb_array_elements(d.doc -> 'lines') with ordinality l (line, ord);
  insert into public.commission_invoice_charge (invoice_id, account_id, tier_key, charged_minor)
  select d.id, (c ->> 'account_id')::uuid, c ->> 'tier_key', (c ->> 'amount')::bigint
  from pg_temp._docs d cross join lateral jsonb_array_elements(coalesce(d.doc -> 'charges', '[]')) c
  where d.kind = 'invoice';
  insert into public.commission_credit_alloc (credit_note_id, line_no, original_invoice_id, account_id, tier_key,
                                              ht_minor, entry_id)
  select d.id, a.ord::integer, (a.x ->> 'original_invoice_id')::uuid, (a.x ->> 'account_id')::uuid, a.x ->> 'tier_key',
         (a.x ->> 'ht')::bigint, (a.x ->> 'entry_id')::uuid
  from pg_temp._docs d cross join lateral jsonb_array_elements(coalesce(d.doc -> 'allocations', '[]'))
    with ordinality a (x, ord)
  where d.kind = 'credit_note';
  insert into public.commission_credit_correction (credit_note_id, original_invoice_id, vat_rate, ht_minor, vat_minor,
                                                   vat_pending_minor, vat_collected_minor, applied_minor, excess_minor)
  select d.id, (c ->> 'original_invoice_id')::uuid, (c ->> 'vat_rate')::numeric, (c ->> 'ht')::bigint,
         (c ->> 'vat')::bigint, (c ->> 'vat_pending')::bigint, (c ->> 'vat_collected')::bigint,
         (c ->> 'applied')::bigint, (c ->> 'excess')::bigint
  from pg_temp._docs d cross join lateral jsonb_array_elements(coalesce(d.doc -> 'corrections', '[]')) c
  where d.kind = 'credit_note';
  -- A credit note reduces the invoices it corrects first (a price correction, 289 I 5): settled at once.
  insert into public.commission_settlement (organization_id, client_organization_id, document_kind, document_id,
                                            credit_note_id, entry_id, kind, amount_minor, vat_moved_minor, settled_on,
                                            run_id)
  select p_organization_id, p_client_organization_id, 'invoice', (c ->> 'original_invoice_id')::uuid, d.id, null,
         'credit_note', (c ->> 'applied')::bigint, (c ->> 'vat_pending')::bigint, v_issue, p_run_id
  from pg_temp._docs d cross join lateral jsonb_array_elements(coalesce(d.doc -> 'corrections', '[]')) c
  where d.kind = 'credit_note' and ((c ->> 'applied')::bigint > 0 or (c ->> 'vat_pending')::bigint > 0);
  -- what was credited never exceeds what each invoice charged each key, nor its HT, nor its VAT
  if exists (select 1 from pg_temp._docs d
             join public.commission_credit_alloc a on a.credit_note_id = d.id
             cross join lateral (select ch.charged_minor + coalesce((select sum(x.ht_minor)
                                   from public.commission_credit_alloc x
                                   where x.original_invoice_id = ch.invoice_id and x.account_id = ch.account_id
                                     and x.tier_key = ch.tier_key), 0) as open
                                 from public.commission_invoice_charge ch
                                 where ch.invoice_id = a.original_invoice_id and ch.account_id = a.account_id
                                   and ch.tier_key = a.tier_key) o
             where o.open < 0)
     or exists (select 1 from pg_temp._docs d
                join public.commission_credit_correction c on c.credit_note_id = d.id
                join public.commission_invoice i on i.id = c.original_invoice_id
                cross join lateral (select coalesce(sum(y.ht_minor), 0) as ht, coalesce(sum(y.vat_minor), 0) as vat
                                    from public.commission_credit_correction y
                                    where y.original_invoice_id = i.id) t
                where i.ht_minor + t.ht < 0 or i.vat_minor + t.vat < 0
                   or c.ht_minor <> (select coalesce(sum(a.ht_minor), 0) from public.commission_credit_alloc a
                                     where a.credit_note_id = d.id and a.original_invoice_id = i.id)) then
    raise exception 'commission credit note: more credited than the invoice charged' using errcode = '23514';
  end if;
  return jsonb_build_object('issue_date', v_issue, 'documents', v_out);
end;
$$;


------------------------------------------------------------------------------------------
-- The nightly (§6.3 set_off_after_bar)
------------------------------------------------------------------------------------------

-- (§6.3 [critic] M7-MONEY-5) The runs' set-offs a bar reveals afterwards: for each client of the servicer with an event
-- that may bar one, its runs' settlements of kind compensation (an invoice or an advance)
-- whose document private.document_nettable refuses on the settlement's own day — an event recorded after the debit (the
-- debit withholds what it knows, private.post_run_settlements); per settlement entry: the barred documents' parts (the
-- ledger's commission_settlement rows), the bar (the documents' kind's code, else the procedure) and its day. Keyed:
-- the servicer's clients by organization_servicer_idx, each one's events by client_status_event_client_idx (a probe
-- per client, fenced: never a partial index of the servicer's events read whole), its settlements by
-- commission_settlement_client_idx.
create function private.set_off_after_bar_rows(p_organization_id uuid, p_today date)
returns table (entry_id uuid, client_organization_id uuid, currency char(3), run_id uuid, settled_on date,
               amount_minor bigint, bar text, bar_on date, documents jsonb)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  with c as materialized (
    select o.id as client_organization_id
    from (select q.id from public.organization q where q.servicer_organization_id = p_organization_id offset 0) o
    where exists (select 1
                  from (select e.kind from public.client_status_event e
                        where e.client_organization_id = o.id and e.effective_date <= p_today offset 0) e
                  where e.kind in ('proceeding_opened', 'liquidation', 'death', 'guardianship', 'mandate_ended',
                                   'seizure'))),
  s as materialized (
    select x.entry_id, x.client_organization_id, x.run_id, x.settled_on, x.document_id, x.document_kind,
           x.amount_minor
    from c
    cross join lateral (select q.entry_id, q.client_organization_id, q.run_id, q.settled_on, q.document_id,
                               q.document_kind, q.amount_minor, q.kind
                        from public.commission_settlement q
                        where q.client_organization_id = c.client_organization_id offset 0) x
    where x.run_id is not null and x.kind = 'compensation' and x.amount_minor > 0
      and x.document_kind in ('invoice', 'advance') and x.settled_on <= p_today)
  select s.entry_id, s.client_organization_id, r.currency, s.run_id, s.settled_on, sum(s.amount_minor)::bigint,
         min(b.bar), min(private.client_set_off_bar_since(s.client_organization_id, s.settled_on, b.bar)),
         jsonb_agg(jsonb_build_object('document_id', s.document_id, 'document_kind', s.document_kind,
                                      'amount_minor', s.amount_minor::text) order by s.document_kind, s.document_id)
  from s
  cross join lateral (select private.document_nettable(s.document_id, s.settled_on) as ok) n
  cross join lateral (select coalesce(private.client_set_off_barred(s.client_organization_id, s.settled_on,
                                                                    s.document_kind), 'proceeding') as bar) b
  cross join lateral (select q.currency from public.remittance_run q where q.id = s.run_id offset 0) r
  where n.ok is false
    -- (review round 1, MLAW-3; C. civ. 2008: « Si le mandataire ignore la mort du mandant ou l'une des autres causes qui
    -- font cesser le mandat, ce qu'il a fait dans cette ignorance est valide. »; LEX-27, OQ-93) a set-off posted before
    -- the servicer recorded the mandate's end (client_end_event's recorded_at: the default knowledge date) and barred by
    -- that end alone — no seizure standing, not born before an opening, no proceeding for an advance — is valid: never
    -- alerted. Read only for a row whose bar is the end (its entry and the end event by their keys).
    and not (b.bar = 'mandate_ended'
             and (select q.posted_at from public.ledger_entry q where q.id = s.entry_id)
                 < (select x.recorded_at from private.client_end_event(s.client_organization_id, s.settled_on) x)
             and not exists (select 1 from private.client_seizures_standing(s.client_organization_id, s.settled_on))
             and not coalesce(private.document_before_opening(s.document_id, s.settled_on), false)
             and not (s.document_kind = 'advance'
                      and exists (select 1 from (select e.kind from public.client_status_event e
                                                 where e.client_organization_id = s.client_organization_id
                                                   and e.effective_date <= s.settled_on offset 0) e
                                  where e.kind = 'proceeding_opened')))
  group by s.entry_id, s.client_organization_id, r.currency, s.run_id, s.settled_on;
$$;

-- private.run_advance_checks, redefined from 20261126090000_client_events.sql (line 1717, 7d-1's: 7c-2's body with
-- protection_event_to_qualify and seizure_standing; same signature and settings, its grants restated below). M2c-7d-2
-- (plan §6.3): one check after seizure_standing — set_off_after_bar (alert, P0); seizure_standing reads the servicer's
-- seizures through its clients (7d-1's index of the servicer's seizures dropped above). Its other statements are unchanged
-- (advance_open keeps the advances of a client in a proceeding until 7d-3's claims_to_declare lists them: ADR-0014
-- « M2c-7d-2 », deviations).
create or replace function private.run_advance_checks(p_check_run_id uuid, p_organization_id uuid,
                                                      p_today date default null, p_full boolean default false)
returns void
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_today date := coalesce(p_today, private.paris_today());
  v_prev uuid;
  v_since timestamptz;
  v_since_date date;
  v_full boolean := coalesce(p_full, false);
  v_from_ts timestamptz;
  v_from_date date;
begin
  select r.id, r.started_at - interval '1 day' into v_prev, v_since
  from public.payment_check_run r
  where r.organization_id = p_organization_id and r.finished_at is not null and r.id <> p_check_run_id
  order by r.started_at desc limit 1;
  if v_prev is null then
    v_full := true;
  end if;
  v_since_date := (v_since at time zone 'Europe/Paris')::date;
  -- (review round 1, CC-2) the window's lower bounds, -infinity for the full pass: a key range in every plan — a
  -- « v_full or … » predicate is a filter under the generic plan PL/pgSQL caches after five calls in one backend, and
  -- the delta pass would then read every booked run, attribution and cover of the servicer
  v_from_ts := case when v_full then '-infinity'::timestamptz else v_since end;
  v_from_date := case when v_full then '-infinity'::date else v_since_date end;

  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  with day_rev as materialized (     -- the reversals posted since (ledger_entry_reversal_posted_idx)
    select x.id, x.reverses_entry_id from public.ledger_entry x
    where not v_full and x.organization_id = p_organization_id and x.entry_type = 'reversal' and x.posted_at >= v_since),
  booked as materialized (           -- the runs booked since (remittance_run_booked_idx), every one in the full pass
    select q.id from public.remittance_run q
    where q.organization_id = p_organization_id and q.status = 'booked' and q.booked_on >= v_from_date
    union
    -- (review round 1, CC-1) and the runs whose payout booking was recorded since, whatever their booked_on (the
    -- debit's date: a statement imported late, a late predecessor): bank_line_booking_org_idx, each transfer's run by key
    select t.run_id
    from (select b.transfer_id from public.bank_line_booking b
          where not v_full and b.organization_id = p_organization_id and b.decided_at >= v_from_ts
            and b.kind = 'payout' offset 0) b
    cross join lateral (select t.run_id from public.bank_transfer t
                        where t.id = b.transfer_id and t.run_id is not null offset 0) t),
  cand as materialized (
    select d.id as reversal_id from day_rev d
    union
    select a.cause_entry_id from day_rev d
    cross join lateral (select q.cause_entry_id from public.client_advance q
                        where q.entry_id = d.reverses_entry_id and q.cause = 'remitted_reversal' offset 0) a
    union
    select z.id from day_rev d
    cross join lateral (select u.ledger_entry_id from private.unplanned_paid_item u
                        where u.booking_entry_id = d.reverses_entry_id offset 0) u
    cross join lateral (select z.id from public.ledger_entry z where z.reverses_entry_id = u.ledger_entry_id offset 0) z
    union
    select z.id
    from booked r
    -- (CI round, main) each run's lines by the run's key alone, their conditions outside the fence
    cross join lateral (select l.ledger_entry_id, l.released, l.kind from public.remittance_line l
                        where l.run_id = r.id offset 0) l
    cross join lateral (select z.id from public.ledger_entry z where z.reverses_entry_id = l.ledger_entry_id offset 0) z
    where not l.released and l.kind in ('allocation', 'forward')
    union
    select z.id
    from (select u.ledger_entry_id from private.unplanned_paid_item u
          where u.organization_id = p_organization_id and u.created_at >= v_from_ts offset 0) u
    cross join lateral (select z.id from public.ledger_entry z where z.reverses_entry_id = u.ledger_entry_id offset 0) z
    union
    select a.cause_entry_id from public.client_advance a
    where a.organization_id = p_organization_id and a.cause = 'remitted_reversal' and a.created_at >= v_from_ts
    union
    select c.subject_id from public.payment_check_result c
    where c.run_id = v_prev and c.code = 'remitted_reversal_uncovered' and c.subject_id is not null)
  select p_check_run_id, p_organization_id, 'remitted_reversal_uncovered', 'violation', 'ledger_entry', c.reversal_id,
         f.currency, f.target - f.held, 1, v_today - (e.posted_at at time zone 'Europe/Paris')::date,
         jsonb_build_object('client_id', f.client_organization_id, 'reversed_entry_id', e.reverses_entry_id,
                            'run_id', f.run_id, 'target', f.target::text, 'held', f.held::text,
                            'recorded_on', (e.posted_at at time zone 'Europe/Paris')::date)
  from cand c
  cross join lateral private.remitted_cover_fact(c.reversal_id) f
  cross join lateral (select q.posted_at, q.reverses_entry_id from public.ledger_entry q
                      where q.id = c.reversal_id offset 0) e
  where f.target <> f.held;

  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  with adv as materialized (
    select a.client_organization_id, a.currency, sum(a.amount_minor - coalesce(s.settled, 0))::bigint as open_minor
    from (select q.id, q.client_organization_id, q.currency, q.amount_minor, q.entry_id from public.client_advance q
          where q.organization_id = p_organization_id offset 0) a
    left join lateral (select sum(c.amount_minor) as settled from public.commission_settlement c
                       where c.document_kind = 'advance' and c.document_id = a.id) s on true
    where not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = a.entry_id)
    group by a.client_organization_id, a.currency),
  led as materialized (
    select la.client_organization_id, la.currency, coalesce(sum(p.s), 0)::bigint as balance_minor
    from (select l.id, l.client_organization_id, l.currency from public.ledger_account l
          where l.organization_id = p_organization_id and l.book = 'client_advance_receivable' offset 0) la
    cross join lateral (select sum(q.amount_minor) as s from public.ledger_posting q
                        where q.ledger_account_id = la.id) p
    group by la.client_organization_id, la.currency)
  select p_check_run_id, p_organization_id, 'advance_ledger', 'violation', 'client',
         coalesce(a.client_organization_id, l.client_organization_id), coalesce(a.currency, l.currency),
         coalesce(l.balance_minor, 0) - coalesce(a.open_minor, 0), 1, null,
         jsonb_build_object('client_id', coalesce(a.client_organization_id, l.client_organization_id),
                            'advances_open', coalesce(a.open_minor, 0)::text,
                            'receivable', coalesce(l.balance_minor, 0)::text)
  from adv a
  full join led l on l.client_organization_id = a.client_organization_id and l.currency = a.currency
  where coalesce(a.open_minor, 0) <> coalesce(l.balance_minor, 0);

  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'advance_open', 'alert', 'client_advance', a.id, a.currency,
         a.amount_minor - coalesce(s.settled, 0), 1, v_today - (a.created_at at time zone 'Europe/Paris')::date,
         jsonb_build_object('client_id', a.client_organization_id, 'cause', a.cause, 'mandate_id', a.mandate_id,
                            'created_on', (a.created_at at time zone 'Europe/Paris')::date,
                            -- (M2c-7b) how it is recovered (review round 1: barred_proceeding when it was born before
                            -- the client's proceeding opened)
                            'recovery', (select r.recovery
                                         from private.advance_recovery_of(a.mandate_id, a.client_organization_id,
                                                                          private.advance_born_on(a.id), v_today) r))
         -- (M2c-7c-2, plan §5.2.8) the day it was last requested (a request not withdrawn), when it is
         || coalesce((select jsonb_build_object('requested_on', q.issue_date)
                      from private.advance_live_request(a.id) q), '{}'::jsonb)
         || case when a.cause = 'remitted_reversal'
                      and exists (select 1
                                  from (select z.reverses_entry_id from public.ledger_entry z
                                        where z.id = a.cause_entry_id offset 0) z
                                  cross join lateral (select l.run_id from public.remittance_line l
                                                      where l.ledger_entry_id = z.reverses_entry_id and not l.released
                                                      offset 0) l
                                  cross join lateral private.item_settled_at(z.reverses_entry_id, l.run_id, 0) t
                                  where t.too_deep)
                 then jsonb_build_object('settled_on_depth', true) else '{}'::jsonb end
  from (select q.id, q.client_organization_id, q.currency, q.amount_minor, q.cause, q.mandate_id, q.created_at,
               q.entry_id, q.cause_entry_id
        from public.client_advance q
        where q.organization_id = p_organization_id
          and q.created_at < ((v_today - 30)::timestamp at time zone 'Europe/Paris') offset 0) a
  left join lateral (select sum(c.amount_minor) as settled from public.commission_settlement c
                     where c.document_kind = 'advance' and c.document_id = a.id) s on true
  where a.amount_minor > coalesce(s.settled, 0)
    and not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = a.entry_id);

  -- (M2c-7c-1, plan §5.2.8) [critic] client_credit_owed (alert): what the servicer owes a client back, still open more
  -- than 15 days after it was recorded — at once (P0, `p0` in its details) for a sum held for the client's collective
  -- proceeding (cause procedure: ops and counsel decide, OQ-98). The servicer's credits by client_credit_org_idx, each
  -- one's refunds by commission_settlement_document_idx.
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'client_credit_owed', 'alert', 'client_credit', c.id, c.currency, o.open_minor,
         1, v_today - (c.created_at at time zone 'Europe/Paris')::date,
         jsonb_build_object('client_id', c.client_organization_id, 'cause', c.cause,
                            'created_on', (c.created_at at time zone 'Europe/Paris')::date, 'p0', c.cause = 'procedure')
  from (select q.id, q.client_organization_id, q.currency, q.cause, q.created_at from public.client_credit q
        where q.organization_id = p_organization_id offset 0) c
  cross join lateral (select private.client_credit_open(c.id) as open_minor) o
  where o.open_minor > 0
    and (c.cause = 'procedure' or c.created_at < ((v_today - 15)::timestamp at time zone 'Europe/Paris'));

  -- (M2c-7c-1, plan §5.0 (7)) [check 1] client_credit_ledger (violation, per client): Σ the open parts of its credits
  -- owed back = −Σ its 419 postings
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  with cc as materialized (
    select c.client_organization_id, c.currency, sum(c.amount_minor - coalesce(r.refunded, 0))::bigint as open_minor
    from (select q.id, q.client_organization_id, q.currency, q.amount_minor from public.client_credit q
          where q.organization_id = p_organization_id offset 0) c
    left join lateral (select sum(s.amount_minor) as refunded from public.commission_settlement s
                       where s.document_id = c.id and s.document_kind = 'client_credit') r on true
    group by c.client_organization_id, c.currency),
  led as materialized (
    select la.client_organization_id, la.currency, coalesce(-sum(p.s), 0)::bigint as owed_minor
    from (select l.id, l.client_organization_id, l.currency from public.ledger_account l
          where l.organization_id = p_organization_id and l.book = 'client_credit_owed' offset 0) la
    cross join lateral (select sum(q.amount_minor) as s from public.ledger_posting q
                        where q.ledger_account_id = la.id) p
    group by la.client_organization_id, la.currency)
  select p_check_run_id, p_organization_id, 'client_credit_ledger', 'violation', 'client',
         coalesce(c.client_organization_id, l.client_organization_id), coalesce(c.currency, l.currency),
         coalesce(l.owed_minor, 0) - coalesce(c.open_minor, 0), 1, null,
         jsonb_build_object('client_id', coalesce(c.client_organization_id, l.client_organization_id),
                            'credits_open', coalesce(c.open_minor, 0)::text, 'ledger', coalesce(l.owed_minor, 0)::text)
  from cc c
  full join led l on l.client_organization_id = c.client_organization_id and l.currency = c.currency
  where coalesce(c.open_minor, 0) <> coalesce(l.owed_minor, 0);

  -- (M2c-7c-1, plan §5.0 (7)) [check 1] written_off_recovery_ledger (violation, the servicer): Σ the recoveries of its
  -- advances passed as a loss = −Σ its 7714 postings, per currency
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  with rec as materialized (
    select r.currency, sum(r.amount_minor)::bigint as recovered_minor
    from (select q.currency, q.amount_minor from public.advance_write_off_recovery q
          where q.organization_id = p_organization_id offset 0) r
    group by r.currency),
  led as materialized (
    select la.currency, coalesce(-sum(p.s), 0)::bigint as income_minor
    from (select l.id, l.currency from public.ledger_account l
          where l.organization_id = p_organization_id and l.book = 'written_off_recovered' offset 0) la
    cross join lateral (select sum(q.amount_minor) as s from public.ledger_posting q
                        where q.ledger_account_id = la.id) p
    group by la.currency)
  select p_check_run_id, p_organization_id, 'written_off_recovery_ledger', 'violation', 'servicer', null,
         coalesce(r.currency, l.currency), coalesce(l.income_minor, 0) - coalesce(r.recovered_minor, 0), 1, null,
         jsonb_build_object('recovered', coalesce(r.recovered_minor, 0)::text, 'ledger', coalesce(l.income_minor, 0)::text)
  from rec r
  full join led l on l.currency = r.currency
  where coalesce(r.recovered_minor, 0) <> coalesce(l.income_minor, 0);

  -- (M2c-7c-2, plan §5.2.8) repayment_request_document_missing (alert): a request not withdrawn whose letter is not
  -- drawn one hour after it was recorded (its job failing, or dead). The servicer's undrawn requests by
  -- advance_repayment_request_undrawn_idx (its predicate stated literally here: never every request); (review round 1,
  -- NIGHT-1, CC-1) a withdrawn one gets no letter (its job draws none): never alerted — withdrawing and requesting again
  -- (the remedy for a dead job) leaves no alert behind.
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'repayment_request_document_missing', 'alert', 'advance_repayment_request',
         q.id, q.currency, q.total_minor, 1, v_today - (q.created_at at time zone 'Europe/Paris')::date,
         jsonb_build_object('client_id', q.client_organization_id, 'number', q.number,
                            'created_on', (q.created_at at time zone 'Europe/Paris')::date)
  from (select r.id, r.client_organization_id, r.currency, r.total_minor, r.number, r.created_at
        from public.advance_repayment_request r
        where r.organization_id = p_organization_id and r.document_id is null and r.withdrawn_at is null
          and r.created_at < now() - interval '1 hour' offset 0) q;

  -- (M2c-7d-1, plan §6.3; [critic] L17) protection_event_to_qualify (alert): an old « Tutelle ou curatelle » row
  -- (qualified_at null) ops have not yet said to be a tutelle or a curatelle — its payouts held meanwhile. The
  -- servicer's rows still to qualify by client_status_event_to_qualify_idx (its predicate stated literally), each one's
  -- qualification by its key (offset 0: a correlated probe, never an anti-join reading the qualifications whole).
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'protection_event_to_qualify', 'alert', 'client_status_event', e.id, null,
         null, 1, v_today - (e.recorded_at at time zone 'Europe/Paris')::date,
         jsonb_build_object('client_id', e.client_organization_id, 'effective_date', e.effective_date,
                            'recorded_on', (e.recorded_at at time zone 'Europe/Paris')::date)
  from (select x.id, x.client_organization_id, x.effective_date, x.recorded_at from public.client_status_event x
        where x.organization_id = p_organization_id and x.kind = 'guardianship' and x.qualified_at is null offset 0) e
  where not exists (select 1 from public.client_status_event_qualification q where q.event_id = e.id offset 0);

  -- (M2c-7d-1, plan §6.3; [critic] L14, [check 2] gap 6) seizure_standing (alert; P0 for 15 days after its recording,
  -- `p0` in its details): a seizure served on the servicer that no release naming it lifts by today — payouts and
  -- set-off stay blocked; the declaration to the bailiff and the payment of the causes are ops' and counsel's (CPCE
  -- L211-3, R211-4, R211-5). (M2c-7d-2) The servicer's clients by organization_servicer_idx, each one's seizures by
  -- client_status_event_client_seizure_idx (7d-1's index of the servicer's seizures dropped above), each seizure's
  -- release by client_status_event_release_uq (offset 0: a correlated probe per seizure — as an anti-join it read the
  -- release index whole under stale statistics).
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'seizure_standing', 'alert', 'client_status_event', e.id, null, null, 1,
         v_today - (e.recorded_at at time zone 'Europe/Paris')::date,
         jsonb_build_object('client_id', e.client_organization_id, 'effective_date', e.effective_date,
                            'recorded_on', (e.recorded_at at time zone 'Europe/Paris')::date,
                            'p0', v_today - (e.recorded_at at time zone 'Europe/Paris')::date < 15)
  from (select o.id from public.organization o where o.servicer_organization_id = p_organization_id offset 0) o
  cross join lateral (select x.id, x.organization_id, x.client_organization_id, x.effective_date, x.recorded_at
                      from public.client_status_event x
                      where x.client_organization_id = o.id and x.kind = 'seizure' offset 0) e
  where e.organization_id = p_organization_id and e.effective_date <= v_today
    and not exists (select 1 from public.client_status_event r
                    where r.refers_to_event_id = e.id and r.kind = 'seizure_released' and r.effective_date <= v_today
                    offset 0);

  -- (M2c-7d-2, plan §6.3 [critic] M7-MONEY-5) set_off_after_bar (alert, P0): a run's settlement posted on or after a
  -- bar's date that set off a document barred that day — an event recorded after the debit, which the debit's
  -- withholding could not see; its amount the barred documents' settlements (private.set_off_after_bar_rows). Counsel
  -- says what follows (kept, or given back): it stays alerted meanwhile.
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'set_off_after_bar', 'alert', 'ledger_entry', x.entry_id, x.currency,
         x.amount_minor, 1, v_today - x.settled_on,
         jsonb_build_object('client_id', x.client_organization_id, 'run_id', x.run_id, 'settled_on', x.settled_on,
                            'bar', x.bar, 'bar_on', x.bar_on, 'documents', x.documents, 'p0', true)
  from private.set_off_after_bar_rows(p_organization_id, v_today) x;
end;
$$;


------------------------------------------------------------------------------------------
-- Privileges (restated for every function redefined here; the new ones internal, or the worker's)
------------------------------------------------------------------------------------------

-- the new helpers: internal
revoke execute on function private.document_nettable(uuid, date), private.client_set_off_bar_since(uuid, date, text),
  private.set_off_bar_reason(uuid, date), private.plan_sets_off_barred(uuid, uuid, jsonb, date),
  private.run_set_off_changed(uuid, uuid, jsonb, date), private.runs_with_client_events(uuid[], date[]),
  private.run_barred_settles(jsonb, date), private.set_off_after_bar_rows(uuid, date),
  private.barred_settlement_check(), private.run_settlement_split(uuid, date)
  from public, anon, authenticated, service_role;
-- what the worker's prepare reads (jobs/remittances.py load_facts): the opening (7c-1's, revoked from service_role
-- then), the bars, the births
revoke execute on function private.client_opening_date(uuid, date), private.client_set_off_barred(uuid, date, text),
  private.client_set_off_bars(uuid, date), private.document_born_on(uuid), private.prepare_set_off_facts(uuid, date)
  from public, anon, authenticated;
grant execute on function private.client_opening_date(uuid, date), private.client_set_off_barred(uuid, date, text),
  private.client_set_off_bars(uuid, date), private.document_born_on(uuid), private.prepare_set_off_facts(uuid, date)
  to service_role;
-- the run page's withheld set-off: authenticated (money staff, checked inside); never anon
revoke execute on function public.remittance_run_withheld(uuid) from public, anon;
grant execute on function public.remittance_run_withheld(uuid) to authenticated;

-- the redefined, as their latest migrations left them
-- (20261124090000) what the client may pay, how an advance is recovered: internal
revoke execute on function private.document_before_opening(uuid, date), private.document_client_payable(uuid, date),
  private.client_payment_docs(uuid, char, date)
  from public, anon, authenticated, service_role;
revoke execute on function private.advance_recovery_of(uuid, uuid, date, date)
  from public, anon, authenticated, service_role;
-- (20261123090000) the opening as 7b named it: internal
revoke execute on function private.client_opening_on(uuid, date) from public, anon, authenticated;
-- (20261125090000) a request's refusals; the approval's re-check: internal
revoke execute on function private.advance_repayment_refusal(uuid, uuid, char, date) from public, anon, authenticated;
revoke execute on function private.remittance_approval_refusal(public.remittance_run, private.remittance_draft, date)
  from public, anon, authenticated;
-- (20261111090000, 20261122090000) the ledger's guard, its check now, the 4670 trigger: internal (the worker's role
-- runs ledger_check_now)
revoke execute on function private.ledger_entry_guard(), private.ledger_posting_client_payable(),
  private.ledger_check_now()
  from public, anon, authenticated;
grant execute on function private.ledger_check_now() to service_role;
-- (20261112090000) the draft's record: the worker's
revoke execute on function private.remittance_record_draft(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function private.remittance_record_draft(uuid, uuid, jsonb) to service_role;
-- (20261122090000) the approval's job: the worker's
revoke execute on function private.approve_remittance_run(uuid, uuid) from public, anon, authenticated;
grant execute on function private.approve_remittance_run(uuid, uuid) to service_role;
-- (20261118090000) the hold before download: internal
revoke execute on function private.transfer_hold_reason(uuid, date, date, text) from public, anon, authenticated;
-- (20261116090000) the debit's settlements: internal
revoke execute on function private.post_run_settlements(uuid[], date[], integer) from public, anon, authenticated;
-- (20261117100000) the « Lier » preview's body: internal, as 20261117100000 left it (revoked from every role)
revoke execute on function private.transfer_line_preview_of(uuid, jsonb, boolean)
  from public, anon, authenticated, service_role;
-- (review round 1, CC-5) the prepare's held items: the worker's
revoke execute on function private.draft_held_items(uuid) from public, anon, authenticated;
grant execute on function private.draft_held_items(uuid) to service_role;
-- (20261118100000) the items' deadlines: the worker's
revoke execute on function private.pending_item_deadlines(uuid, boolean) from public, anon, authenticated;
grant execute on function private.pending_item_deadlines(uuid, boolean) to service_role;
-- (20261112090000) the schedule's candidates: the worker's
revoke execute on function private.remittance_schedule_candidates(uuid, date) from public, anon, authenticated;
grant execute on function private.remittance_schedule_candidates(uuid, date) to service_role;
-- (20261114090000) the documents' issue: internal
revoke execute on function private.issue_commission_documents(uuid, uuid, uuid, jsonb, text, boolean)
  from public, anon, authenticated;
-- (20261126090000) the advance checks: internal
revoke execute on function private.run_advance_checks(uuid, uuid, date, boolean)
  from public, anon, authenticated, service_role;
