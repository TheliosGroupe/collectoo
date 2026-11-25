-- M2c-7d-3 « declarations, liquidation, statement » (plan docs/design/m2c-7-plan.md §0, §1.3, §1.4's 7d-3 row, §2, §6.1's
-- disposition table, §6.2.8's statement fr-4, §6.2.10's 7d-3 part, §6.3, §6.4, §6.6's 046c; ADR-0014 « M2c-7d-3 »).
-- Founder questions (plan §10) and counsel's (§11), none answered: their defaults are built and left open; no text
-- presents the servicer's rule as the law's. Texts read on LibreJustice on 2026-11-25, the versions in force: C. com.
-- L622-24 (2025-12-31), L622-26 (2021-10-01), R622-24 (2014-07-02), R622-21 (2015-10-01), L622-17 (2021-10-01), L641-3
-- (2019-05-24), L641-9 (2022-05-15), L641-13 (2023-10-25); CPCE R124-6 (2012-06-01); C. civ. 2008 (1804-03-21).
--
-- What it builds:
--   * claims_to_declare (alert; [critic] L8, L4, [check 2]): for a client with a proceeding or a liquidation in effect,
--     each open invoice born before the opening and each open advance (any birth), not named by a declaration of claims
--     (7d-1's claims_declared_item) — with its deadline: two months after the BODACC publication for a claim born
--     before the opening (R622-24 al. 1), two months after its exigibility for one born after (L622-24 al. 6 « Les
--     délais courent à compter de la date d'exigibilité de la créance »; the exigibility of an advance is its date:
--     the servicer's default, OQ-92), « publication_missing » without a publication date; P0 from 15 days before;
--   * advance_open leaves out the advances of a client with a proceeding or a liquidation in effect (carried item 1:
--     claims_to_declare lists them — each such advance in one alert, none once declared);
--   * post_opening_unpaid (alert; [critic] L8): an invoice born on or after the opening, unpaid at its due date, not
--     declared — no deadline computed (L622-17 IV runs from the end of the observation period, which is not modelled;
--     L641-13 III's six months for a liquidation are quoted, OQ-92); (review round 2) an invoice its run set off in
--     full (no due date of its own) whose set-off the debit withheld, from the debit's day (private.invoice_withheld_on);
--     (review round 3) one whose payout is not debited while the client's invoice bar applies, from the day the bar was
--     recorded (private.client_set_off_bar_recorded_on);
--   * payout_after_liquidation (alert, P0; [critic] L11, [check 1] gap 9): a payout to an account that is not the
--     liquidator's account confirmed after the liquidation's recording, in a file with a requested date on or after the
--     judgment or debited on or after it (not returned) — `cancellable` its file not downloaded or the switch on; until a
--     disposition is recorded (public.record_liquidation_payout_disposition; public.liquidation_payout_disposition,
--     append-only, staff only) — never by elapsed time;
--   * set_off_after_bar stops for a settlement whose outcome is recorded (carried item 2: public.record_set_off_outcome,
--     « compensation maintenue » with counsel's answer as evidence; public.set_off_outcome) — giving the sum back is not
--     built (no entry type does it: Left open);
--   * invoice_overdue leaves out the invoices born before the opening of a client in a proceeding and every invoice of a
--     client in liquidation ([critic] L9: to declare, never dunned); (review round 2) it lists an invoice its run set
--     off in full whose set-off the debit withheld (a mandate's end, a seizure), from the debit's day;
--   * the statement fr-4 (§6.2.8; [critic] L12, L13, M7-MONEY-5): a payload of schema 2 when it has something fr-3 cannot
--     word — the end of the mandate known at K (its kind, its day, the day the servicer recorded it — C. civ. 2008 —,
--     the payee the events require), who the statement is addressed to (roles only: the names and addresses of who acts
--     for the client stay money staff's, plan §6.1), the set-offs a debit withheld that this run gives back, each advance
--     taken back with its date (§1.2); otherwise fr-3's payload unchanged (schema 1). The record step takes each payload
--     by its own template only;
--   * public.remittance_run_withheld follows a giving run's returned payout to the run that pays it again (carried item
--     4: as remittance_run_payout's repaid_by), naming the run whose payout came back.
-- New: the two tables, private.client_procedure_facts, private.client_documents_declared,
-- private.client_claims_to_declare, private.client_post_opening_unpaid, private.client_payouts_after_liquidation,
-- private.invoice_to_declare, private.statement_mandate_end, private.statement_addressees and the two commands; (review
-- round 1) private.client_event_known and private.settlement_set_off_alert; (review round 2) private.invoice_withheld_on;
-- (review round 3) private.client_set_off_bar_recorded_on.
-- Redefined, each copied whole from its latest definition across every migration file (the last `create or replace
-- function` of the name wins; diffed against the live body before the change; only the change; SECURITY DEFINER, every
-- `set` clause, `search_path ''` and the grants restated): private.run_advance_checks (20261127090000_set_off_bars.sql:2117,
-- 7d-2's), private.run_remittance_runs_checks (20261121120000_switch_on_prerequisites_5.sql:195),
-- private.remittance_statement_build and private.remittance_documents_record (20261117120000_statement_suivi.sql:363,
-- :824), public.remittance_run_withheld (20261127090000_set_off_bars.sql:1373); (review round 1)
-- private.set_off_after_bar_rows (20261127090000_set_off_bars.sql:2056).
-- The cancellation-after-download switch stays off: nothing here writes private.feature_switch; only
-- payout_after_liquidation's `cancellable` reads it (public.cancellation_after_download()).
-- Review round 1 (ADR-0014 « M2c-7d-3 review fixes »): the statement's end of the mandate and addressees read each event
-- as it stood at K (private.client_event_known: an old « Tutelle ou curatelle » row counts as a tutelle from its
-- qualification, dated by it — ML-1); set_off_after_bar's rule in one function (private.settlement_set_off_alert), read
-- by its nightly (private.set_off_after_bar_rows, redefined from 20261127090000_set_off_bars.sql:2056) and by
-- « Compensation maintenue » (ML-2); invoice_overdue asks private.invoice_to_declare for the invoices of the clients in
-- a proceeding or a liquidation only (v_proc — CC-1).
-- Review round 2: a run's own invoice set off in full carries no due date (paid with its run's payout); once the debit
-- withheld that set-off it is unpaid from the debit's day (private.invoice_withheld_on: the run's barred settlement by
-- its key) — post_opening_unpaid lists it for a client in a proceeding or a liquidation (born after the opening),
-- invoice_overdue for the servicer's other clients with an event (v_evt: a mandate's end, a seizure).
-- Review round 3: the statement's « Fin du mandat » states, before the end at K, each end the code applied earlier from
-- its own day (private.statement_mandate_end's `earlier`: a death known first, then an older tutelle qualified); while
-- such an invoice's payout is not debited, once the client's invoice bar applies the payout no longer pays it —
-- post_opening_unpaid lists it from the day the bar was recorded (private.client_set_off_bar_recorded_on, new;
-- private.client_event_known moved before it, unchanged).

------------------------------------------------------------------------------------------
-- Schema
------------------------------------------------------------------------------------------

-- ([check 1] gap 9; [critic] L11, OQ-99) What became of a payout made to the client after its liquidation: ratified by
-- the liquidator, or the sum paid to the liquidator — recorded by an administrator with its evidence, never changed. Read
-- by the servicer's money staff only (the liquidation and its outcome are staff matters until counsel answers OQ-99).
create table public.liquidation_payout_disposition (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  transfer_id uuid not null unique references public.bank_transfer (id),
  kind text not null check (kind in ('ratified', 'repaid_to_liquidator')),
  evidence_document_id uuid not null references public.document (id),
  note text check (length(btrim(note)) between 1 and 2000),
  recorded_by uuid not null references public.app_user (id),
  recorded_at timestamptz not null default clock_timestamp()
);
comment on table public.liquidation_payout_disposition is
  'What became of a payout made to the client after its liquidation (append-only; OQ-99).';

-- (carried item 2) The outcome of a run's settlement set_off_after_bar alerts: kept (counsel's answer, its evidence).
create table public.set_off_outcome (
  entry_id uuid primary key references public.ledger_entry (id),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  kind text not null check (kind in ('kept')),
  evidence_document_id uuid not null references public.document (id),
  note text check (length(btrim(note)) between 1 and 2000),
  recorded_by uuid not null references public.app_user (id),
  recorded_at timestamptz not null default clock_timestamp()
);
comment on table public.set_off_outcome is
  'The outcome recorded for a set-off posted after a bar (append-only): kept. Giving it back is not built.';

-- a payout of that servicer and client; the evidence a status evidence of that client (the transfer by its primary
-- key alone, fenced: a stale estimate of the servicer's or the client's key never reads their transfers instead)
create function private.liquidation_payout_disposition_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1
                 from (select q.kind, q.organization_id, q.client_organization_id from public.bank_transfer q
                       where q.id = new.transfer_id offset 0) t
                 where t.kind = 'payout' and t.organization_id = new.organization_id
                   and t.client_organization_id = new.client_organization_id)
     or not private.client_document_of(new.evidence_document_id, new.client_organization_id,
                                       'client_status_evidence') then
    raise exception 'liquidation payout disposition: a payout of the client, with its evidence'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger liquidation_payout_disposition_guard before insert on public.liquidation_payout_disposition
  for each row execute function private.liquidation_payout_disposition_guard();
alter table public.liquidation_payout_disposition enable always trigger liquidation_payout_disposition_guard;
create trigger liquidation_payout_disposition_append_only before update or delete or truncate
  on public.liquidation_payout_disposition for each statement execute function private.refuse_change();
alter table public.liquidation_payout_disposition enable always trigger liquidation_payout_disposition_append_only;
create trigger liquidation_payout_disposition_change_log after insert or update or delete
  on public.liquidation_payout_disposition for each row execute function private.log_change();

-- a run's settlement (`settle:<run>`) of that servicer and client; the evidence a status evidence of that client
-- (the entry by its primary key alone, fenced: the reads test found the servicer's entries read whole — 10,013
-- tuples — by its organization's key under a stale estimate)
create function private.set_off_outcome_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1
                 from (select q.entry_type, q.organization_id, q.client_organization_id, q.source_type, q.source_id,
                              q.idempotency_key
                       from public.ledger_entry q where q.id = new.entry_id offset 0) e
                 where e.entry_type = 'client_settlement'
                   and e.organization_id = new.organization_id and e.client_organization_id = new.client_organization_id
                   and e.source_type = 'remittance_run' and e.idempotency_key = 'settle:' || e.source_id)
     or not private.client_document_of(new.evidence_document_id, new.client_organization_id,
                                       'client_status_evidence') then
    raise exception 'set-off outcome: a run''s settlement of the client, with its evidence'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger set_off_outcome_guard before insert on public.set_off_outcome
  for each row execute function private.set_off_outcome_guard();
alter table public.set_off_outcome enable always trigger set_off_outcome_guard;
create trigger set_off_outcome_append_only before update or delete or truncate on public.set_off_outcome
  for each statement execute function private.refuse_change();
alter table public.set_off_outcome enable always trigger set_off_outcome_append_only;
create trigger set_off_outcome_change_log after insert or update or delete on public.set_off_outcome
  for each row execute function private.log_change('entry_id');

alter table public.liquidation_payout_disposition enable row level security;
alter table public.set_off_outcome enable row level security;
revoke all on public.liquidation_payout_disposition, public.set_off_outcome from public, anon, authenticated;
grant select on public.liquidation_payout_disposition, public.set_off_outcome to authenticated;
-- money staff of the servicer only: never the client's users, its restricted viewers or a collector
create policy liquidation_payout_disposition_read on public.liquidation_payout_disposition for select
  to authenticated using (organization_id = any ((select private.money_staff_org_ids())::uuid[]));
create policy set_off_outcome_read on public.set_off_outcome for select
  to authenticated using (organization_id = any ((select private.money_staff_org_ids())::uuid[]));

------------------------------------------------------------------------------------------
-- A client's procedure: its opening, its declarations, what is to declare (plan §6.3)
------------------------------------------------------------------------------------------

-- The client's collective proceeding in effect on p_on: the opening (private.client_opening_date's: the earliest
-- proceeding_opened or liquidation effective by then, L641-3 al. 1), the kind and the BODACC publication of the event
-- that opens it (R622-24: the declarations run from it; of two on the same day, the one with a publication), and the
-- liquidation's day and recording when one is in effect (L641-9 I: « à partir de sa date »). No row: none. The client's
-- events by client_status_event_client_idx (fenced: a per-client read, never a partial index of the servicer's events).
create function private.client_procedure_facts(p_client uuid, p_on date)
returns table (opening_on date, opening_kind text, publication_date date, liquidation_on date,
               liquidation_recorded_at timestamptz)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  with e as materialized (
    select x.id, x.kind, x.effective_date, x.publication_date, x.recorded_at
    from (select q.id, q.kind, q.effective_date, q.publication_date, q.recorded_at
          from public.client_status_event q
          where q.client_organization_id = p_client and q.effective_date <= p_on offset 0) x
    where x.kind in ('proceeding_opened', 'liquidation'))
  select o.effective_date, o.kind, o.publication_date, l.effective_date, l.recorded_at
  from (select e.* from e order by e.effective_date, e.publication_date is null, e.recorded_at, e.id limit 1) o
  left join lateral (select e.effective_date, e.recorded_at from e where e.kind = 'liquidation'
                     order by e.effective_date, e.recorded_at, e.id limit 1) l on true;
$$;

-- The documents the client's declarations of claims name (its claims_declared events effective by p_on, each one's
-- items by the item table's primary key prefix).
create function private.client_documents_declared(p_client uuid, p_on date)
returns setof uuid
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select i.document_id
  from (select x.id, x.kind from public.client_status_event x
        where x.client_organization_id = p_client and x.effective_date <= p_on offset 0) e
  cross join lateral (select q.document_id from public.claims_declared_item q where q.event_id = e.id offset 0) i
  where e.kind = 'claims_declared';
$$;

-- ([critic] L8, L4) What the client owes the servicer and the servicer is to declare, on p_on: each open invoice born
-- before the opening (private.document_born_on: the earliest collection it charges, OQ-92) and each open advance
-- whatever its birth (no advance is taken or requested while a proceeding stands, so one born after is declared under
-- L622-24 al. 6), not named by a declaration; its open part (private.document_open, private.advance_open: from the
-- settlements of the ledger), its birth, the deadline — two months after the publication for a claim born before the
-- opening (R622-24 al. 1; null when no publication is recorded), two months after its exigibility for one born after
-- (L622-24 al. 6; the exigibility of an advance its date, the servicer's default) — and its basis. The client's
-- invoices and advances by their client indexes (fenced), each one's open part and birth by its key; read only for a
-- client with a procedure.
create function private.client_claims_to_declare(p_client uuid, p_on date)
returns table (document_kind text, document_id uuid, currency char(3), open_minor bigint, number text, born_on date,
               pre_opening boolean, opening_on date, opening_kind text, publication_date date, liquidation_on date,
               deadline date, deadline_basis text)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  with f as materialized (select * from private.client_procedure_facts(p_client, p_on)),
  dec as materialized (select x.id from private.client_documents_declared(p_client, p_on) x (id)
                       where exists (select 1 from f)),
  docs as materialized (
    select 'invoice'::text as kind, i.id, i.currency, i.number, private.document_open(i.id) as open
    from f
    cross join lateral (select q.id, q.currency, q.number, q.kind from public.commission_invoice q
                        where q.client_organization_id = p_client offset 0) i
    where i.kind = 'invoice'
    union all
    select 'advance', a.id, a.currency, null, private.advance_open(a.id)
    from f
    cross join lateral (select q.id, q.currency from public.client_advance q
                        where q.client_organization_id = p_client offset 0) a),
  born as materialized (
    select d.*, case d.kind when 'invoice' then private.document_born_on(d.id)
                            else private.advance_born_on(d.id) end as born
    from docs d where d.open > 0 and not exists (select 1 from dec where dec.id = d.id))
  select b.kind, b.id, b.currency, b.open, b.number, b.born, b.born < f.opening_on, f.opening_on, f.opening_kind,
         f.publication_date, f.liquidation_on,
         case when b.born < f.opening_on then (f.publication_date + interval '2 months')::date
              else (b.born + interval '2 months')::date end,
         case when b.born >= f.opening_on then 'exigibility'
              when f.publication_date is null then 'publication_missing' else 'publication' end
  from born b cross join f
  where b.kind = 'advance' or b.born < f.opening_on;
$$;

-- (Review round 2) The day the debit of an invoice's own run withheld its set-off, else null. An invoice its run's plan
-- sets off in full carries no due date (commission_invoice_due: it is paid with its run's payout, the payment line
-- naming that payout); when the debit withholds that set-off (7d-2: `settle:<run>:barred`, reversed at once, no
-- commission_settlement row) the invoice stays open with no date of its own — the debit's day is the day it was to be
-- paid (the servicer's rule, OQ-92). An invoice netted with no due date and a run; the run's barred settlement by
-- ledger_entry_idempotency_uq; none of the run's settlements of it (commission_settlement_document_idx: a set-off the
-- debit let through is no withholding). The invoice by its key (fenced: the filters on its run and due date stay
-- outside, implying no partial index's predicate).
create function private.invoice_withheld_on(p_invoice_id uuid)
returns date
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select e.effective_date
  from (select q.id, q.organization_id, q.run_id, q.kind, q.settlement, q.due_date from public.commission_invoice q
        where q.id = p_invoice_id offset 0) i
  cross join lateral (select x.effective_date from public.ledger_entry x
                      where x.organization_id = i.organization_id
                        and x.idempotency_key = 'settle:' || i.run_id::text || ':barred' offset 0) e
  where i.kind = 'invoice' and i.settlement = 'netted' and i.due_date is null and i.run_id is not null
    and not exists (select 1 from (select s.run_id from public.commission_settlement s
                                   where s.document_id = i.id offset 0) s
                    where s.run_id = i.run_id);
$$;

-- (Review round 1, ML-1) An event as it stood at p_at, and since when the code applied it: client_event_effective's kind
-- as of p_at — an old « Tutelle ou curatelle » row whose qualification was recorded after p_at is still to qualify
-- (guardianship_to_qualify: it ends nothing, holds the payouts) — and the day it took effect in the code: its recording,
-- or for an old row counting as a tutelle by its qualification the later of the two (until then the row ended nothing:
-- no set-off barred, no payment set aside; the servicer learnt it was a tutelle when it qualified it — OQ-93). No row
-- for an event recorded after p_at. The event and its qualification by their keys.
create function private.client_event_known(p_event_id uuid, p_at timestamptz)
returns table (kind text, known_at timestamptz)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select case when e.kind <> 'guardianship' then e.kind
              when q.kind = 'curatorship' then null
              when q.kind = 'guardianship' or e.qualified_at is not null then 'guardianship'
              else 'guardianship_to_qualify' end,
         case when q.kind = 'guardianship' then greatest(e.recorded_at, q.recorded_at) else e.recorded_at end
  from (select x.id, x.kind, x.qualified_at, x.recorded_at from public.client_status_event x where x.id = p_event_id
        offset 0) e
  left join lateral (select y.kind, y.recorded_at
                     from (select z.kind, z.recorded_at from public.client_status_event_qualification z
                           where z.event_id = e.id offset 0) y
                     where y.recorded_at <= p_at) q on true
  where e.recorded_at <= p_at;
$$;

-- (Review round 3) The Paris day the servicer recorded the bar private.client_set_off_barred names (p_code) on p_on —
-- since when the code applies it: a liquidation, the first recording among those in effect; the mandate's end, the
-- first day the code knew an end in effect (private.client_event_known: an old « Tutelle ou curatelle » row from its
-- qualification); a seizure, the first recording among those standing (private.client_seizures_standing); else null.
-- The client's events by client_status_event_client_idx (fenced: their kinds filtered outside), each end's knowledge and
-- each standing seizure by its key.
create function private.client_set_off_bar_recorded_on(p_client uuid, p_on date, p_code text)
returns date
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select (case p_code
    when 'liquidation' then (select min(e.recorded_at)
                             from (select q.kind, q.recorded_at from public.client_status_event q
                                   where q.client_organization_id = p_client and q.effective_date <= p_on offset 0) e
                             where e.kind = 'liquidation')
    when 'mandate_ended' then (select min(k.known_at)
                               from (select q.id, q.kind from public.client_status_event q
                                     where q.client_organization_id = p_client and q.effective_date <= p_on offset 0) e
                               cross join lateral private.client_event_known(e.id, 'infinity') k
                               where e.kind in ('death', 'guardianship', 'mandate_ended')
                                 and k.kind in ('death', 'guardianship', 'mandate_ended'))
    when 'seizure' then (select min(x.recorded_at)
                         from private.client_seizures_standing(p_client, p_on) s (id)
                         cross join lateral (select q.recorded_at from public.client_status_event q
                                             where q.id = s.id offset 0) x)
  end at time zone 'Europe/Paris')::date;
$$;

-- ([critic] L8) The client's invoices born on or after the opening and unpaid at their due date on p_on, not named by a
-- declaration (L622-17 IV in a proceeding, L641-13 III in liquidation: the administrator's, the judicial
-- representative's or the liquidator's knowledge keeps their privilege — no deadline computed, OQ-92). (Review round 2)
-- An invoice its run sets off in full has no due date: the day its run's debit withheld that set-off stands for it
-- (`withheld_on`, private.invoice_withheld_on — the servicer's rule, OQ-92); one whose payout is still to come is paid
-- by it, never listed. (Review round 3) Unless the client's invoice bar applies on p_on (private.client_set_off_barred:
-- a liquidation, the mandate's end, a seizure): the payout to come no longer pays it (its set-off would be withheld at
-- the debit; in liquidation the payout is held), so an invoice netted with no due date, still open and not withheld —
-- its run's payout not debited: a debit either set it off (open 0) or withheld it (`withheld_on`), and a cancelled
-- run's full credit note, applied at once, annuls it (open 0) — is unpaid from the day the bar was recorded
-- (`barred_on`, private.client_set_off_bar_recorded_on; `bar`, its code — the servicer's rule, OQ-92). The client's
-- invoices by commission_invoice_client_idx, fenced (the dates filtered outside: a filter on the due date would imply
-- commission_invoice_due_idx's predicate, the servicer's invoices by due date), each one's withholding (an invoice with
-- no due date only), open part and birth by key; the bar and its day once.
create function private.client_post_opening_unpaid(p_client uuid, p_on date)
returns table (document_id uuid, currency char(3), open_minor bigint, number text, due_date date, born_on date,
               opening_on date, opening_kind text, publication_date date, liquidation_on date, withheld_on date,
               barred_on date, bar text)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  with f as materialized (select * from private.client_procedure_facts(p_client, p_on)),
  dec as materialized (select x.id from private.client_documents_declared(p_client, p_on) x (id)
                       where exists (select 1 from f)),
  bar as materialized (
    select b.code, private.client_set_off_bar_recorded_on(p_client, p_on, b.code) as on_day
    from f
    cross join lateral (select private.client_set_off_barred(p_client, p_on, 'invoice') as code offset 0) b
    where b.code is not null),
  inv as materialized (
    select i.id, i.currency, i.number, i.due_date, w.withheld_on, x.on_day as barred_on, x.code as bar,
           private.document_open(i.id) as open
    from f
    cross join lateral (select q.id, q.currency, q.number, q.kind, q.due_date, q.settlement, q.run_id
                        from public.commission_invoice q where q.client_organization_id = p_client offset 0) i
    cross join lateral (select case when i.kind = 'invoice' and i.due_date is null
                                    then private.invoice_withheld_on(i.id) end as withheld_on offset 0) w
    left join lateral (select bar.code, bar.on_day
                       from bar
                       where i.kind = 'invoice' and i.due_date is null and w.withheld_on is null
                         and i.settlement = 'netted' and i.run_id is not null) x on true
    where i.kind = 'invoice' and coalesce(i.due_date, w.withheld_on, x.on_day) < p_on)
  select i.id, i.currency, i.open, i.number, i.due_date, b.born, f.opening_on, f.opening_kind, f.publication_date,
         f.liquidation_on, i.withheld_on, i.barred_on, i.bar
  from inv i
  cross join lateral (select private.document_born_on(i.id) as born) b
  cross join f
  where i.open > 0 and b.born >= f.opening_on and not exists (select 1 from dec where dec.id = i.id);
$$;

-- ([critic] L11, [check 1] gap 9) The client's payouts made after its liquidation, on p_on: each payout of its runs'
-- transfer chains to an IBAN that is not its liquidator's account (kind court_appointed, confirmed by a second admin
-- after the liquidation's recording, with its authority evidence — the payee remittance_payout_blockers requires),
-- debited on or after the judgment and not returned (its payout or unplanned debit bookings by
-- bank_line_booking_transfer_idx; a return reverses the booking's entry: ledger_entry_reversed_once_uq) — `booked`,
-- the debits' amount and first day — or else in a file with a requested execution date on or after it — `in_file`,
-- whether its file was downloaded. `disposed`: a disposition recorded (liquidation_payout_disposition by its unique
-- transfer). The client's runs by remittance_run_client_idx, each transfer by key; read only in liquidation.
create function private.client_payouts_after_liquidation(p_client uuid, p_on date)
returns table (transfer_id uuid, run_id uuid, run_number text, currency char(3), status text, amount_minor bigint,
               requested_execution_date date, debited_on date, liquidation_on date, downloaded boolean,
               disposed boolean)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  with f as materialized (
    select x.liquidation_on, x.liquidation_recorded_at from private.client_procedure_facts(p_client, p_on) x
    where x.liquidation_on is not null),
  court as materialized (
    select a.iban
    from f
    cross join lateral (select q.iban, q.kind, q.confirmed_via, q.confirmed_at, q.authority_document_id
                        from public.client_payout_account q where q.client_organization_id = p_client offset 0) a
    where a.kind = 'court_appointed' and a.confirmed_via = 'second_admin' and a.authority_document_id is not null
      and a.confirmed_at > f.liquidation_recorded_at),
  tr as materialized (
    select r.id as run_id, r.number, t.id, t.status, t.amount_minor, t.requested_execution_date, t.payee_iban,
           t.currency, t.transfer_file_id
    from f
    cross join lateral (select q.id, q.number, q.transfer_id from public.remittance_run q
                        where q.client_organization_id = p_client offset 0) r
    cross join lateral private.transfer_chain(r.transfer_id) c
    cross join lateral (select y.id, y.kind, y.status, y.amount_minor, y.requested_execution_date, y.payee_iban,
                               y.currency, y.transfer_file_id
                        from public.bank_transfer y where y.id = c.transfer_id offset 0) t
    where r.transfer_id is not null and t.kind = 'payout'),
  deb as materialized (
    select t.id, sum(k.amount_minor)::bigint as amount, min(e.effective_date) as debited_on
    from tr t
    cross join f
    cross join lateral (select q.kind, q.entry_id, q.amount_minor from public.bank_line_booking q
                        where q.transfer_id = t.id offset 0) k
    cross join lateral (select q.effective_date from public.ledger_entry q where q.id = k.entry_id offset 0) e
    where k.kind in ('payout', 'unplanned_payout') and e.effective_date >= f.liquidation_on
      and not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = k.entry_id offset 0)
    group by t.id)
  select t.id, t.run_id, t.number, t.currency, case when d.id is not null then 'booked' else 'in_file' end,
         coalesce(d.amount, t.amount_minor), t.requested_execution_date, d.debited_on, f.liquidation_on,
         case when d.id is null
              then exists (select 1 from public.transfer_file x
                           where x.id = t.transfer_file_id and x.first_downloaded_at is not null) end,
         exists (select 1 from public.liquidation_payout_disposition x where x.transfer_id = t.id offset 0)
  from tr t
  cross join f
  left join deb d on d.id = t.id
  where not exists (select 1 from court c where c.iban = t.payee_iban)
    and (d.id is not null or (t.status = 'in_file' and t.requested_execution_date >= f.liquidation_on));
$$;

-- ([critic] L9) An invoice the remittance runs' checks do not dun (invoice_overdue) on p_on: one of a client in
-- liquidation, or one born before the opening of a client in a proceeding — to declare (claims_to_declare), never
-- dunned. The client's procedure by its key, the invoice's birth by its key when it has one.
create function private.invoice_to_declare(p_invoice uuid, p_client uuid, p_on date)
returns boolean
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select coalesce((select f.liquidation_on is not null or private.document_born_on(p_invoice) < f.opening_on
                   from private.client_procedure_facts(p_client, p_on) f), false);
$$;

------------------------------------------------------------------------------------------
-- The statement's facts as of K (plan §6.2.8, §6.2.12; [critic] L12, L13)
------------------------------------------------------------------------------------------

-- The end of the client's mandate known at p_at (an end event — a death, a qualified tutelle, a mandate end: C. civ.
-- 2003 — effective by p_on and known by p_at: private.client_end_event's rule as of K) with the day the servicer
-- recorded it (C. civ. 2008: what it did before is valid) — (review round 1, ML-1) the day the code applied it
-- (private.client_event_known: an old row's qualification day) —, and the payee the events known then require
-- (private.client_payee_rule's order as of K: an old row still to qualify at K holds the payouts, 'to_qualify'); null
-- when none. The statement is a function of the books at K: an event, or a qualification, recorded after K never changes
-- a statement drawn later. (Review round 3) The code applies, from each day, the earliest end it then knows
-- (private.client_end_event): an end known before the one stated, while no end it knew was earlier in effect, was
-- applied from its own day — each such end (`earlier` [{kind, effective_date, recorded_on}], in the order the code
-- applied them, one per Paris day: the last of the day) is stated with its day, so that « informé », the payments set
-- aside and nothing deducted are each dated as the code did them; an end known later and later in effect changed
-- nothing the code applied and is not stated. The key only when there is one. The client's events by
-- client_status_event_client_idx (the ends applied read from the same rows).
create function private.statement_mandate_end(p_client uuid, p_on date, p_at timestamptz)
returns jsonb
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  with ev as materialized (
    select x.id, x.effective_date, k.known_at as recorded_at, k.kind
    from (select q.id, q.kind, q.effective_date from public.client_status_event q
          where q.client_organization_id = p_client and q.effective_date <= p_on offset 0) x
    cross join lateral private.client_event_known(x.id, p_at) k
    where x.kind in ('liquidation', 'death', 'guardianship', 'curatorship', 'mandate_ended')),
  en as (select ev.* from ev where ev.kind in ('death', 'guardianship', 'mandate_ended')
         order by ev.effective_date, ev.recorded_at, ev.id limit 1),
  -- the ends the code applied in turn: each earlier in effect than every end known before it
  st as (select x.kind, x.effective_date, (x.recorded_at at time zone 'Europe/Paris')::date as recorded_on
         from (select ev.*, min(ev.effective_date) over (order by ev.recorded_at, ev.effective_date, ev.id
                                                         rows between unbounded preceding and 1 preceding) as before
               from ev where ev.kind in ('death', 'guardianship', 'mandate_ended')) x
         where x.before is null or x.effective_date < x.before),
  dy as (select distinct on (st.recorded_on) st.* from st order by st.recorded_on, st.effective_date),
  pay as (select case max(case ev.kind when 'guardianship_to_qualify' then 5 when 'liquidation' then 4
                                       when 'death' then 3 when 'mandate_ended' then 1 else 2 end)
                   when 5 then 'to_qualify' when 4 then 'court_appointed' when 3 then 'estate'
                   when 2 then 'protected_adult' else 'client' end as kind
          from ev
          where ev.kind in ('liquidation', 'death', 'guardianship', 'guardianship_to_qualify', 'curatorship',
                            'mandate_ended'))
  select jsonb_build_object('kind', en.kind, 'effective_date', en.effective_date,
                            'recorded_on', (en.recorded_at at time zone 'Europe/Paris')::date, 'payee_kind', pay.kind)
         || coalesce((select jsonb_build_object('earlier', jsonb_agg(jsonb_build_object(
                                 'kind', dy.kind, 'effective_date', dy.effective_date, 'recorded_on', dy.recorded_on)
                               order by dy.recorded_on))
                      from dy where dy.recorded_on < (en.recorded_at at time zone 'Europe/Paris')::date
                      having count(*) > 0), '{}'::jsonb)
  from en cross join pay;
$$;

-- ([critic] L12, [check 1] gap 7) Who the statement is addressed to, as of K: private.client_addressee's rule with the
-- events, their kinds (review round 1, ML-1: private.client_event_known — an old row qualified after K still to qualify)
-- and the representatives recorded by p_at — the roles only (`client`, `notary`, `heirs`, `tutor`, `curator`,
-- `liquidator`), never the names and addresses (plan §6.1: money staff's; the statement stays readable by the client's
-- users, OQ-99's default). After a curatelle the client and the curator in copy. No row while the governing event has
-- nobody recorded, or is an old row still to qualify.
create function private.statement_addressees(p_client uuid, p_on date, p_at timestamptz)
returns table (role text, copy boolean)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  with ev as (
    select e.id, e.effective_date, k.known_at as recorded_at, k.kind,
           case k.kind when 'liquidation' then 1 when 'death' then 2 when 'curatorship' then 4 else 3 end as rank
    from (select x.id, x.kind, x.effective_date from public.client_status_event x
          where x.client_organization_id = p_client and x.effective_date <= p_on offset 0) e
    cross join lateral private.client_event_known(e.id, p_at) k
    where e.kind in ('liquidation', 'death', 'guardianship', 'curatorship')
      and k.kind in ('liquidation', 'death', 'guardianship', 'guardianship_to_qualify', 'curatorship')),
  gov as (select ev.id, ev.kind from ev order by ev.rank, ev.effective_date, ev.recorded_at, ev.id limit 1),
  rep as (select g.kind, r.representative
          from gov g
          cross join lateral (select x.representative from public.client_status_event_representative x
                              where x.event_id = g.id and x.recorded_at <= p_at
                              order by x.recorded_at desc, x.id desc limit 1) r)
  select 'client'::text, false
  where not exists (select 1 from gov) or exists (select 1 from rep where rep.kind = 'curatorship')
  union all
  select rep.representative ->> 'role', rep.kind = 'curatorship'
  from rep where rep.kind in ('liquidation', 'death', 'guardianship', 'curatorship');
$$;

------------------------------------------------------------------------------------------
-- The commands (plan §6.3; carried item 2)
------------------------------------------------------------------------------------------

-- ([critic] L11, [check 1] gap 9) « Enregistrer la suite » of a payout made to the client after its liquidation (admins
-- at aal2): ratified by the liquidator, or the sum paid to the liquidator, with its evidence (a status evidence of that
-- client: the liquidator's letter) and a note — what stops payout_after_liquidation, never elapsed time (OQ-99).
-- Refusals « liquidation payout disposition refused: <code> »: bad_kind, already_disposed (the unique transfer the
-- backstop: its unique_violation the same code), not_after_liquidation (not a payout of a client in liquidation debited
-- on or after the judgment to an account that is not the liquidator's: one in a file, one debited before, one to the
-- liquidator's account, a sweep), evidence_required, bad_note (over 2,000 characters; a blank one is none). The payout
-- row locked (for key share: its booking may run), lock_timeout 2s. Returns {disposition_id, transfer_id, kind}.
create function public.record_liquidation_payout_disposition(p_idempotency_key text, p_transfer_id uuid, p_kind text,
                                                             p_evidence_document_id uuid,
                                                             p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
set lock_timeout = '2s'
as $$
declare
  t public.bank_transfer;
  v_request jsonb := jsonb_build_object('transfer_id', p_transfer_id, 'kind', p_kind,
                                        'evidence_document_id', p_evidence_document_id, 'note', p_note);
  v_result jsonb;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_id uuid;
begin
  select * into t from public.bank_transfer where id = p_transfer_id for key share;
  if not found or not private.has_role(t.organization_id, array['admin']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('record_liquidation_payout_disposition', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if p_kind is null or p_kind not in ('ratified', 'repaid_to_liquidator') then
    raise exception 'liquidation payout disposition refused: bad_kind' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.liquidation_payout_disposition x where x.transfer_id = t.id) then
    raise exception 'liquidation payout disposition refused: already_disposed' using errcode = 'check_violation';
  end if;
  if t.kind <> 'payout' or not exists (
       select 1 from private.client_payouts_after_liquidation(t.client_organization_id, private.paris_today()) x
       where x.transfer_id = t.id and x.status = 'booked') then
    raise exception 'liquidation payout disposition refused: not_after_liquidation' using errcode = 'check_violation';
  end if;
  if p_evidence_document_id is null
     or not private.client_document_of(p_evidence_document_id, t.client_organization_id, 'client_status_evidence') then
    raise exception 'liquidation payout disposition refused: evidence_required' using errcode = 'check_violation';
  end if;
  if length(v_note) > 2000 then
    raise exception 'liquidation payout disposition refused: bad_note' using errcode = 'check_violation';
  end if;
  begin
    insert into public.liquidation_payout_disposition (organization_id, client_organization_id, transfer_id, kind,
                                                       evidence_document_id, note, recorded_by)
    values (t.organization_id, t.client_organization_id, t.id, p_kind, p_evidence_document_id, v_note, auth.uid())
    returning id into v_id;
  exception when unique_violation then
    raise exception 'liquidation payout disposition refused: already_disposed' using errcode = 'check_violation';
  end;
  v_result := jsonb_build_object('disposition_id', v_id, 'transfer_id', t.id, 'kind', p_kind);
  perform private.command_record('record_liquidation_payout_disposition', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- (Review round 1, ML-2) Whether set_off_after_bar names a part of a run's settlement — the alert's rule in one place,
-- read by its nightly (private.set_off_after_bar_rows) and by « Compensation maintenue »
-- (public.record_set_off_outcome): the bar of the part's document on its settlement's day (the document's kind's code,
-- else the procedure), or null — its document nettable that day (private.document_nettable), or (review M2c-7d-2 round
-- 1, MLAW-3; C. civ. 2008: « Si le mandataire ignore la mort du mandant ou l'une des autres causes qui font cesser le
-- mandat, ce qu'il a fait dans cette ignorance est valide. »; LEX-27, OQ-93) a set-off posted before the servicer
-- recorded the mandate's end (client_end_event's recorded_at: the default knowledge date) and barred by that end alone
-- — no seizure standing, not born before an opening, no proceeding for an advance — valid: never alerted. The entry and
-- the end event by their keys, read only for a part whose bar is the end.
create function private.settlement_set_off_alert(p_entry_id uuid, p_client uuid, p_settled_on date, p_document_id uuid,
                                                 p_document_kind text)
returns text
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select b.bar
  from (select private.document_nettable(p_document_id, p_settled_on) as ok offset 0) n
  cross join lateral (select coalesce(private.client_set_off_barred(p_client, p_settled_on, p_document_kind),
                                      'proceeding') as bar offset 0) b
  where n.ok is false
    and not (b.bar = 'mandate_ended'
             and (select q.posted_at from public.ledger_entry q where q.id = p_entry_id)
                 < (select x.recorded_at from private.client_end_event(p_client, p_settled_on) x)
             and not exists (select 1 from private.client_seizures_standing(p_client, p_settled_on))
             and not coalesce(private.document_before_opening(p_document_id, p_settled_on), false)
             and not (p_document_kind = 'advance'
                      and exists (select 1 from (select e.kind from public.client_status_event e
                                                 where e.client_organization_id = p_client
                                                   and e.effective_date <= p_settled_on offset 0) e
                                  where e.kind = 'proceeding_opened')));
$$;

-- private.set_off_after_bar_rows, redefined from 20261127090000_set_off_bars.sql (line 2056, 7d-2's; same signature and
-- settings, its grants restated below). M2c-7d-3 review round 1 (ML-2): each settlement part's test is
-- private.settlement_set_off_alert (the same rule, now shared with « Compensation maintenue »; evaluated once per part:
-- fenced). Its other statements are unchanged.
-- (§6.3 [critic] M7-MONEY-5) The runs' set-offs a bar reveals afterwards: for each client of the servicer with an event
-- that may bar one, its runs' settlements of kind compensation (an invoice or an advance)
-- whose document private.document_nettable refuses on the settlement's own day — an event recorded after the debit (the
-- debit withholds what it knows, private.post_run_settlements); per settlement entry: the barred documents' parts (the
-- ledger's commission_settlement rows), the bar (the documents' kind's code, else the procedure) and its day. Keyed:
-- the servicer's clients by organization_servicer_idx, each one's events by client_status_event_client_idx (a probe
-- per client, fenced: never a partial index of the servicer's events read whole), its settlements by
-- commission_settlement_client_idx.
create or replace function private.set_off_after_bar_rows(p_organization_id uuid, p_today date)
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
  cross join lateral (select private.settlement_set_off_alert(s.entry_id, s.client_organization_id, s.settled_on,
                                                              s.document_id, s.document_kind) as bar offset 0) b
  cross join lateral (select q.currency from public.remittance_run q where q.id = s.run_id offset 0) r
  where b.bar is not null
  group by s.entry_id, s.client_organization_id, r.currency, s.run_id, s.settled_on;
$$;

-- (carried item 2; plan §6.3 set_off_after_bar « ops record the outcome ») « Compensation maintenue » (admins at
-- aal2): counsel's answer — the set-off a run's settlement made after a bar is kept —, with its evidence (a status
-- evidence of that client) and a note; stops set_off_after_bar for that settlement. Giving the sum back (through a
-- client credit of cause procedure) is not built: no entry type re-opens a settled document (Left open), so `given_back`
-- or any other kind is refused bad_kind. Refusals « set-off outcome refused: <code> »: bad_kind, not_alerted (not a run's
-- settlement of the servicer that set_off_after_bar names: (review round 1, ML-2) private.settlement_set_off_alert, the
-- alert's own rule, on the settlements of the run's frozen plan's documents by commission_settlement_document_idx, this
-- entry's, settled by today), already_recorded (the primary key the backstop), evidence_required, bad_note. lock_timeout
-- 2s. Returns {entry_id, kind}.
create function public.record_set_off_outcome(p_idempotency_key text, p_entry_id uuid, p_kind text,
                                              p_evidence_document_id uuid, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
set lock_timeout = '2s'
as $$
declare
  e public.ledger_entry;
  v_request jsonb := jsonb_build_object('entry_id', p_entry_id, 'kind', p_kind,
                                        'evidence_document_id', p_evidence_document_id, 'note', p_note);
  v_result jsonb;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  select * into e from public.ledger_entry where id = p_entry_id;
  if not found or not private.has_role(e.organization_id, array['admin']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('record_set_off_outcome', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if p_kind is null or p_kind <> 'kept' then
    raise exception 'set-off outcome refused: bad_kind' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.set_off_outcome x where x.entry_id = e.id) then
    raise exception 'set-off outcome refused: already_recorded' using errcode = 'check_violation';
  end if;
  if e.entry_type <> 'client_settlement' or e.source_type is distinct from 'remittance_run'
     or e.idempotency_key is distinct from 'settle:' || e.source_id
     or not exists (
          select 1
          from (select r.settlement_plan from public.remittance_run r
                where r.id = case when pg_input_is_valid(e.source_id, 'uuid') then e.source_id::uuid end offset 0) r
          cross join lateral jsonb_array_elements(case when jsonb_typeof(r.settlement_plan -> 'settles') = 'array'
                                                       then r.settlement_plan -> 'settles' else '[]' end) v
          cross join lateral (select q.entry_id, q.document_id, q.document_kind, q.kind, q.amount_minor, q.settled_on,
                                     q.run_id
                              from public.commission_settlement q
                              where q.document_id = (v ->> 'document_id')::uuid offset 0) s
          where s.entry_id = e.id and s.run_id is not null and s.kind = 'compensation' and s.amount_minor > 0
            and s.document_kind in ('invoice', 'advance') and s.settled_on <= private.paris_today()
            -- (review round 1, ML-2) the alert's own rule (MLAW-3's valid set-off included), never a looser one
            and private.settlement_set_off_alert(e.id, e.client_organization_id, s.settled_on, s.document_id,
                                                 s.document_kind) is not null) then
    raise exception 'set-off outcome refused: not_alerted' using errcode = 'check_violation';
  end if;
  if p_evidence_document_id is null
     or not private.client_document_of(p_evidence_document_id, e.client_organization_id, 'client_status_evidence') then
    raise exception 'set-off outcome refused: evidence_required' using errcode = 'check_violation';
  end if;
  if length(v_note) > 2000 then
    raise exception 'set-off outcome refused: bad_note' using errcode = 'check_violation';
  end if;
  begin
    insert into public.set_off_outcome (entry_id, organization_id, client_organization_id, kind, evidence_document_id,
                                        note, recorded_by)
    values (e.id, e.organization_id, e.client_organization_id, p_kind, p_evidence_document_id, v_note, auth.uid());
  exception when unique_violation then
    raise exception 'set-off outcome refused: already_recorded' using errcode = 'check_violation';
  end;
  v_result := jsonb_build_object('entry_id', e.id, 'kind', p_kind);
  perform private.command_record('record_set_off_outcome', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

------------------------------------------------------------------------------------------
-- The nightly (plan §6.2.10, §6.3)
------------------------------------------------------------------------------------------

-- private.run_advance_checks, redefined from 20261127090000_set_off_bars.sql (line 2117, 7d-2's: 7d-1's body with
-- set_off_after_bar; same signature and settings, its grants restated below). M2c-7d-3 (plan §6.2.10, §6.3): the
-- servicer's clients with a proceeding or a liquidation in effect read once (v_proc); advance_open leaves out their
-- advances (carried item 1: claims_to_declare lists them); set_off_after_bar leaves out a settlement whose outcome is
-- recorded (carried item 2); three checks after it — claims_to_declare, post_opening_unpaid, payout_after_liquidation.
-- Its other statements are unchanged.
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
  v_proc uuid[];
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
  -- (M2c-7d-3, plan §6.3) the servicer's clients with a proceeding or a liquidation in effect today — the clients of the
  -- declarations' checks below, whose advances advance_open leaves out: the servicer's clients by
  -- organization_servicer_idx, each one's events by client_status_event_client_idx (a probe per client, fenced)
  select coalesce(array_agg(o.id order by o.id), '{}') into v_proc
  from (select q.id from public.organization q where q.servicer_organization_id = p_organization_id offset 0) o
  where exists (select 1
                from (select e.kind from public.client_status_event e
                      where e.client_organization_id = o.id and e.effective_date <= v_today offset 0) e
                where e.kind in ('proceeding_opened', 'liquidation'));

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
    and not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = a.entry_id)
    -- (M2c-7d-3, plan §6.2.10 [critic] L4; carried item 1) never an advance of a client with a proceeding or a
    -- liquidation in effect: claims_to_declare lists it (each such advance in one alert; none once declared)
    and not (a.client_organization_id = any (v_proc));

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
  from private.set_off_after_bar_rows(p_organization_id, v_today) x
  -- (M2c-7d-3; carried item 2) until its outcome is recorded (public.record_set_off_outcome: kept), by its key
  where not exists (select 1 from public.set_off_outcome o where o.entry_id = x.entry_id);

  -- (M2c-7d-3, plan §6.3 [critic] L8, L4; [check 2]) claims_to_declare (alert; P0 from 15 days before its deadline): per
  -- document of a client with a proceeding or a liquidation, an open invoice born before the opening or an open advance,
  -- not named by a declaration (private.client_claims_to_declare): its open part, its birth, its deadline (two months
  -- after the BODACC publication for a claim born before the opening, R622-24 al. 1; after its exigibility for one born
  -- after, L622-24 al. 6) — `publication_missing` without a publication date (then no P0: the deadline is unknown)
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'claims_to_declare', 'alert',
         case x.document_kind when 'invoice' then 'commission_invoice' else 'client_advance' end, x.document_id,
         x.currency, x.open_minor, 1, v_today - x.opening_on,
         jsonb_build_object('client_id', c.id, 'document_kind', x.document_kind, 'number', x.number,
                            'born_on', x.born_on, 'pre_opening', x.pre_opening, 'opening_on', x.opening_on,
                            'opening_kind', x.opening_kind, 'publication_date', x.publication_date,
                            'liquidation_on', x.liquidation_on, 'deadline', x.deadline,
                            'deadline_basis', x.deadline_basis,
                            'p0', coalesce(x.deadline - v_today <= 15, false))
  from unnest(v_proc) c (id)
  cross join lateral private.client_claims_to_declare(c.id, v_today) x;

  -- (M2c-7d-3, plan §6.3 [critic] L8) post_opening_unpaid (alert): an invoice of a client with a proceeding or a
  -- liquidation, born on or after the opening, unpaid at its due date and not declared
  -- (private.client_post_opening_unpaid); no deadline computed (L622-17 IV: the end of the observation period is not
  -- modelled; L641-13 III in liquidation). (Review round 2) an invoice its run set off in full, whose set-off the debit
  -- withheld: from that day (`withheld_on`, standing for its due date); (review round 3) one whose run is in flight
  -- while the client's invoice bar applies: from the day the bar was recorded (`barred_on`, its code `bar`)
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'post_opening_unpaid', 'alert', 'commission_invoice', x.document_id,
         x.currency, x.open_minor, 1, v_today - coalesce(x.due_date, x.withheld_on, x.barred_on),
         jsonb_build_object('client_id', c.id, 'number', x.number, 'due_date', x.due_date, 'born_on', x.born_on,
                            'opening_on', x.opening_on, 'opening_kind', x.opening_kind,
                            'publication_date', x.publication_date, 'liquidation_on', x.liquidation_on,
                            'withheld_on', x.withheld_on, 'barred_on', x.barred_on, 'bar', x.bar)
  from unnest(v_proc) c (id)
  cross join lateral private.client_post_opening_unpaid(c.id, v_today) x;

  -- (M2c-7d-3, plan §6.3 [critic] L11, [check 1] gap 9) payout_after_liquidation (alert, P0): a payout made to the
  -- client after its liquidation, to an account that is not its liquidator's — in its file (`cancellable` while the
  -- file is not downloaded, or once downloaded with the cancellation-after-download switch on) or debited — until a
  -- disposition is recorded (private.client_payouts_after_liquidation), never by elapsed time
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'payout_after_liquidation', 'alert', 'bank_transfer', x.transfer_id,
         x.currency, x.amount_minor, 1, v_today - x.liquidation_on,
         jsonb_build_object('client_id', c.id, 'run_id', x.run_id, 'run_number', x.run_number, 'status', x.status,
                            'requested_execution_date', x.requested_execution_date, 'debited_on', x.debited_on,
                            'liquidation_on', x.liquidation_on, 'downloaded', x.downloaded,
                            'cancellable', case when x.status = 'in_file'
                                                then not x.downloaded or public.cancellation_after_download() end,
                            'p0', true)
  from unnest(v_proc) c (id)
  cross join lateral private.client_payouts_after_liquidation(c.id, v_today) x
  where not x.disposed;
end;
$$;

-- private.run_remittance_runs_checks, redefined from 20261121120000_switch_on_prerequisites_5.sql (line 195; same
-- signature and settings, its grants restated below). M2c-7d-3 (plan §6.2.10 [critic] L9): invoice_overdue leaves out
-- the invoices of a client in liquidation and those born before the opening of a client in a proceeding (to declare);
-- (review round 1, CC-1) the servicer's clients with a proceeding or a liquidation read once (v_proc), the per-invoice
-- test asked for theirs only; (review round 2) in the same pass the clients with any event (v_evt), whose invoices
-- netted in full and withheld at the debit invoice_overdue lists from that day. Every other check as before.
create or replace function private.run_remittance_runs_checks(p_check_run_id uuid, p_organization_id uuid,
                                                              p_today date default null)
returns void
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_today date := coalesce(p_today, private.paris_today());
  v_since timestamptz;      -- the previous check run of the servicer
  v_full boolean;           -- I16 over every run (Sundays, or the first check run), else over the runs changed lately
  v_failures timestamptz;   -- the schedule's failures reported from (at least the last 24 hours)
  v_proc uuid[];            -- (M2c-7d-3 review round 1, CC-1) the servicer's clients with a proceeding or a liquidation
  v_evt uuid[];             -- (M2c-7d-3 review round 2) the servicer's clients with any event in effect
begin
  select max(c.started_at) into v_since from public.payment_check_run c
  where c.organization_id = p_organization_id and c.id <> p_check_run_id and c.finished_at is not null;
  v_full := v_since is null or extract(isodow from v_today) = 7;
  v_failures := least(coalesce(v_since, clock_timestamp()), clock_timestamp() - interval '24 hours');
  -- (M2c-7d-3 review round 1, CC-1) the servicer's clients with a proceeding or a liquidation in effect today, read once
  -- (as run_advance_checks' v_proc: the servicer's clients by organization_servicer_idx, each one's events by
  -- client_status_event_client_idx, fenced): invoice_overdue asks private.invoice_to_declare for their invoices only.
  -- (Review round 2) in the same pass, those with any event in effect (v_evt): a debit withholds a set-off only for
  -- them (private.runs_with_client_events), and events are never deleted — invoice_overdue reads their invoices whose
  -- set-off the debit withheld
  select coalesce(array_agg(o.id order by o.id) filter (where x.proc), '{}'), coalesce(array_agg(o.id order by o.id), '{}')
    into v_proc, v_evt
  from (select q.id from public.organization q where q.servicer_organization_id = p_organization_id offset 0) o
  cross join lateral (select bool_or(e.kind in ('proceeding_opened', 'liquidation')) as proc
                      from (select e.kind from public.client_status_event e
                            where e.client_organization_id = o.id and e.effective_date <= v_today offset 0) e) x
  where x.proc is not null;

  -- Review round 2 (ld2-named-debit-returned-after-booking; CPCE-08), rounds 3 and 4, M2c-6b-3b part 1: a booked run
  -- whose payout chain holds a payout cancelled out of a downloaded file (a re-issue's run, or one booked by its late
  -- predecessor) gets its R124-6 rows at the date its chain paid the client and stayed paid
  -- (private.remittance_chain_paid: every execution and return of the chain, each counted for the transfer it names).
  -- Keyed: the servicer's cancelled filed transfers by bank_transfer_cancelled_filed_idx, each run, chain and line by key.
  -- M2c-6b-3b part 2: the runs this branch judges are read by private.remittance_booked_chain_runs (its CTEs bc and
  -- bp moved there verbatim), which the alert « remittance_breach_held » below reads too: one rule for the rows and
  -- their alert.
  -- M2c-6b-3b part 3 (founder question 3 of « M2c-6b-3b part 2 », its default): read once each — the booked chained
  -- runs into pg_temp._rc_runs, and every line due at each run's date with what its hold found into pg_temp._rc_lines
  -- (private.remittance_chain_judged: private.remittance_chain_rows' lines, unfiltered, each with its date's
  -- coverage, waiting, expired and the possible debits judged on). The rows are those lines whose holds pass, as
  -- before; the alert below reads the same two tables instead of reading the runs and the holds' facts again.
  drop table if exists pg_temp._rc_runs;
  create temp table _rc_runs on commit drop as
  select * from private.remittance_booked_chain_runs(p_organization_id);
  create index on pg_temp._rc_runs (run_id);
  drop table if exists pg_temp._rc_lines;
  create temp table _rc_lines on commit drop as
  select p.run_id, x.ledger_entry_id, x.payment_id, x.deadline, x.latest_execution_date, x.kind, x.covered, x.waiting,
         x.expired, x.lines
  from pg_temp._rc_runs p
  cross join lateral private.remittance_chain_judged(p.run_id, p.paid_on, p.chain_paid, p.paying, null, v_today,
                                                     true) x;
  create index on pg_temp._rc_lines (run_id, latest_execution_date);
  insert into public.remittance_deadline_breach (organization_id, client_organization_id, ledger_entry_id, payment_id,
                                                 run_id, deadline, latest_execution_date, requested_execution_date,
                                                 late_reason, blocked_reason)
  select p.organization_id, p.client_organization_id, l.ledger_entry_id, l.payment_id, l.run_id, l.deadline,
         l.latest_execution_date, p.requested_execution_date, p.late_reason,
         case when l.expired then 'debit_unbooked' when l.kind = 'payout_returned' then 'payout_returned' end
  from pg_temp._rc_lines l
  cross join lateral (select r.organization_id, r.client_organization_id, r.requested_execution_date, r.late_reason
                      from pg_temp._rc_runs r where r.run_id = l.run_id limit 1) p
  where l.covered and not l.waiting
  on conflict (ledger_entry_id) do nothing;

  with dl as materialized (     -- the collections waiting, of files under a mandate with terms (review legal#2)
    select * from private.pending_item_deadlines(p_organization_id) d where d.monitored),
  ol as materialized (          -- the collections of runs approved or sent, not debited by their date (legal#3)
    select * from private.inflight_overdue_lines(p_organization_id, v_today)),
  ua as materialized (          -- money matched to a file, not allocated (legal#7, perf#0)
    select * from private.unallocated_payment_deadlines(p_organization_id)),
  -- M2c-6b-3b part 2 (CPCE-08; founder question 2 of « M2c-6b-3b part 1 », its default): the booked runs of a chain
  -- whose R124-6 rows the holds keep back — read after the first statement above wrote the rows that are due, so a
  -- run whose row is written raises nothing.
  -- M2c-6b-3b part 3 (founder question 3 of « M2c-6b-3b part 2 », its default): the same alert as
  -- private.remittance_breach_held (part 2's reading, kept as the standalone one the tests compare it with), read from
  -- what the booked branch above recorded instead of a second pass: its runs (pg_temp._rc_runs) and its lines with
  -- their holds' findings (pg_temp._rc_lines); and the uncovered days once per account and window, not once per run.
  -- hl: the lines due at each run's date that still have no row, each with the date it is held to (the booked
  -- branch's own: its latest execution date, or the one-month date of a delay that cannot be met)
  hl as materialized (
    select c.run_id, c.ledger_entry_id, c.latest_execution_date as latest, x.amount_minor
    from pg_temp._rc_lines c
    cross join lateral (select y.amount_minor from public.remittance_line y
                        where y.ledger_entry_id = c.ledger_entry_id and not y.released offset 0) x
    where not exists (select 1 from public.remittance_deadline_breach b where b.ledger_entry_id = c.ledger_entry_id
                      offset 0)),
  -- he: per run with such a line, once: its paying account and e0, the earliest execution date of its chain's
  -- transfers handed out (an item of a file downloaded at least once)
  he as materialized (
    select k.run_id, e.account, e.e0
    from (select distinct h.run_id from hl h) k
    cross join lateral (select r.transfer_id from pg_temp._rc_runs r where r.run_id = k.run_id limit 1) t
    cross join lateral (
      select (select q.debtor_bank_account_id from public.bank_transfer q where q.id = t.transfer_id) as account,
             (select min(i.execution_date)
              from private.transfer_chain(t.transfer_id) c
              cross join lateral (select q.file_id, q.execution_date from public.transfer_file_item q
                                  where q.transfer_id = c.transfer_id offset 0) i
              cross join lateral (select ff.download_count from public.transfer_file ff where ff.id = i.file_id
                                  offset 0) ff
              where ff.download_count > 0) as e0) e),
  -- hk: per run and date held to: the window [least(e0, L), L], and the possible debits its hold judged on when the
  -- booked branch found the window covered
  hk as materialized (
    select k.run_id, k.latest, e.account, least(coalesce(e.e0, k.latest), k.latest) as d_from, f.covered as found,
           f.lines
    from (select distinct h.run_id, h.latest from hl h) k
    join he e on e.run_id = k.run_id
    cross join lateral (select c.covered, c.lines from pg_temp._rc_lines c
                        where c.run_id = k.run_id and c.latest_execution_date = k.latest limit 1) f),
  -- hw: per paying account and window, once: covered now (private.statement_covers), else the business days no
  -- imported statement covers yet (each read alone; none named: the balances' break)
  hw as materialized (
    select k.account, k.d_from, k.d_to, v.covered,
           case when not v.covered
                then array(select g.d::date
                           from generate_series(k.d_from, k.d_to, interval '1 day') g (d)
                           where private.is_business_day(g.d::date)
                             and not private.statement_covers(k.account, g.d::date, g.d::date)
                           order by 1) end as days
    from (select distinct h.account, h.d_from, h.latest as d_to from hk h) k
    cross join lateral (select coalesce(private.statement_covers(k.account, k.d_from, k.d_to), false) as covered
                        offset 0) v),
  -- hf: per run and date held to, the window's facts — the waiting lines named only when the window is covered and
  -- was so when the booked branch judged it (else the facts moved meanwhile: the next check judges the run again)
  hf as materialized (
    select h.run_id, h.latest, w.covered, w.days,
           case when w.covered and h.found then h.lines else '[]'::jsonb end as lines
    from hk h
    join hw w on w.account is not distinct from h.account and w.d_from = h.d_from and w.d_to = h.latest),
  -- hwl: the lines a covered date waits on: each once, with a transfer it may be the debit of. Review round 1
  -- (dt3-race-alert-for-run-paid-on-time): never a line booked or linked since the booked branch judged it — read
  -- again here by key (as private.transfer_debit_lines reads it): the alert never asks ops to book a booked line
  hwl as materialized (
    select distinct on (f.run_id, (v.v ->> 1)::uuid)
           f.run_id, (v.v ->> 1)::uuid as line_id, (v.v ->> 2)::date as line_date, (v.v ->> 0)::uuid as transfer_id
    from hf f
    cross join lateral jsonb_array_elements(f.lines) v (v)
    where f.covered
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = (v.v ->> 1)::uuid
                      offset 0)
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = (v.v ->> 1)::uuid
                      offset 0)
    order by f.run_id, (v.v ->> 1)::uuid, (v.v ->> 2)::date, (v.v ->> 0)::uuid),
  hs as materialized (
    select l.run_id, sum(l.amount_minor) as amount, count(*) as n, min(l.latest) as earliest,
           max(v_today - l.latest) as oldest,
           (array_agg(l.ledger_entry_id order by l.ledger_entry_id))[1:50] as ids
    from hl l group by l.run_id),
  -- Review round 1 (cost-1): each run's days and waiting lines aggregated once per run and joined to it by key —
  -- never a scan of hf or hwl per run. hd: the days no statement covers, each once, in order (the first 31 named), how
  -- many, the last of them (dt3-csv-hint-last-day-not-named: the day to export past, also beyond the 31 named), and a
  -- window whose every day is covered but whose balances do not follow (the break)
  hd as materialized (
    select f.run_id,
           array_agg(distinct u.d order by u.d) filter (where u.d is not null) as days,
           count(distinct u.d) as n, max(u.d) as last,
           coalesce(bool_or(not f.covered and cardinality(f.days) = 0), false) as brk
    from hf f
    left join lateral unnest(f.days) u (d) on true
    group by f.run_id),
  -- hwa: the waiting lines, numbered per run by date and id; the first 10 named with their amount and the transfer each
  -- may be the debit of (read by key for those only), all of them counted
  hwr as materialized (
    select w.run_id, w.line_id, w.line_date, w.transfer_id,
           row_number() over (partition by w.run_id order by w.line_date, w.line_id) as rn,
           count(*) over (partition by w.run_id) as n
    from hwl w),
  hwa as materialized (
    select r.run_id, max(r.n) as n,
           jsonb_agg(jsonb_build_object('line_id', r.line_id, 'booking_date', r.line_date,
                                        'amount_minor', x.amount_minor::text, 'currency', x.currency,
                                        'end_to_end_id', tr.end_to_end_id)
                     order by r.line_date, r.line_id) as waiting
    from hwr r
    cross join lateral (select q.amount_minor, q.currency from public.bank_transaction q where q.id = r.line_id
                        offset 0) x
    cross join lateral (select q.end_to_end_id from public.bank_transfer q where q.id = r.transfer_id offset 0) tr
    where r.rn <= 10
    group by r.run_id),
  bh as materialized (
    select p.run_id, p.currency, s.amount::bigint as amount_minor, s.n::integer as line_count,
           s.oldest::integer as oldest_days,
           jsonb_build_object(
             'number', p.number,
             'judged_on', p.paid_on,
             'earliest_latest_execution_date', s.earliest,
             'uncovered_days', to_jsonb((coalesce(d.days, '{}'::date[]))[1:31]),
             'uncovered_count', coalesce(d.n, 0),
             'last_uncovered_day', d.last,
             'balance_break', coalesce(d.brk, false),
             'waiting', coalesce(a.waiting, '[]'),
             'waiting_count', coalesce(a.n, 0),
             'bound_days', private.transfer_debit_bound_days(),
             'ids', to_jsonb(s.ids)) as details
    from hs s
    cross join lateral (select r.run_id, r.currency, r.number, r.paid_on from pg_temp._rc_runs r
                        where r.run_id = s.run_id limit 1) p
    left join hd d on d.run_id = s.run_id
    left join hwa a on a.run_id = s.run_id),
  -- I21: a positive collection not paid by its latest execution date — one month after E when its mandate's delay
  -- cannot be met (review legal#1) — writes a breach row, once; one the calendar cannot place has no date to hold it
  -- to (its alert below)
  waiting_breach as (
    insert into public.remittance_deadline_breach (organization_id, client_organization_id, ledger_entry_id, payment_id,
                                                   run_id, deadline, latest_execution_date, blocked_reason)
    select p_organization_id, d.client_organization_id, d.ledger_entry_id, d.payment_id, d.draft_run_id,
           d.check_deadline, d.check_latest_execution_date,
           -- M2c-6b-1 (Q7's default, OQ-36): an item paid again after its payout came back keeps its lines' date, and
           -- its breach is recorded « bloqué : virement revenu impayé »
           case when exists (select 1 from private.remittance_pending q where q.ledger_entry_id = d.ledger_entry_id
                               and q.kind = 'payout_returned') then 'payout_returned' end
    from dl d where not d.out_of_horizon and d.check_latest_execution_date < v_today
    on conflict (ledger_entry_id) do nothing),
  -- … and so does a collection whose run was approved but whose payout is not debited by then (§9.2: paid means
  -- debited). M2c-6b-1 (plan §2.5 [critic]): « paid » is the bank's debit date, often imported a day later, and the
  -- table is append-only — so the row is written only once the paying account's statements cover that date
  -- (private.statement_covers) and show no debit of the payout, nor a line not booked yet that could be it (its
  -- PmtInf's batch line whatever its amount, a line of its amount with neither reference: review legal-texts#2); until
  -- then the alert below only. A payout never handed out to the bank (still ordered, or in a file nobody downloaded)
  -- is not paid whatever the statements: its row is written at once. A late debit booked later writes its row at the
  -- booking (private.bank_booking_post_rows).
  -- M2c-6b-3a-2 (I; CPCE-08): a run whose transfer re-issues another (its predecessor cancelled with a downloaded
  -- file) or is itself cancelled (refused by the bank, cancelled alone: the run still approved or sent) is proven unpaid
  -- at L only once the statements cover [e0, L] — e0 the earliest execution date of its chain's transfers that were in
  -- a file downloaded at least once, whether or not the re-issue itself was handed out — and no such transfer may have
  -- been debited by L (private.transfer_debit_suppression(x, L, today) not 'waiting': its own id, its PmtInf's batch
  -- lines, a line of its amount without our references or to its payee, dated up to L, not booked nor linked — a line
  -- dated after L never holds the row back, the payment being certainly late); 'expired' writes the row « bloqué :
  -- débit possible non comptabilisé ». A predecessor's late debit may have paid the run on time: written at once, the
  -- append-only row would be false (its booking writes none, on conflict). Other runs keep the two branches below.
  -- Review round 1 (LD-1): nor ever while a debit naming a chain transfer by our references (its own id, a detail of an
  -- entry kept unsplit, its PmtInf's batch line that can hold it), dated by L, waits unbooked — that transfer was
  -- executed on time; 'expired' is for lines that only may be its debit. Its booking (the late predecessor, or the
  -- re-issue's own debit) then writes the true row at its date. Review round 4 (CPCE-08): « executed on time » is the
  -- one rule over the chain (private.remittance_chain_paid): the chain paid the client by L and stayed paid — a
  -- transfer whose every execution came back (its return unflagged included) paid nothing, one executed more often
  -- than it came back stays paid.
  -- M2c-6b-3b part 1 review round 1 (chain-holds-snapshot-race; CPCE-08): the rule above, unchanged, judged by
  -- private.remittance_inflight_judge on facts read in one snapshot (the run still in flight, its transfer, the
  -- coverage, the chain's paid date, the lines that may be a debit) — no longer this statement's snapshot beside the
  -- suppression's own later reads, between which ops' booking of the run's on-time debit without our references (or an
  -- import) could land and the append-only row be written for a run paid on time — a proof resting on the options
  -- asked after that snapshot standing only if the facts read again afterwards have not moved. Every run in flight,
  -- chained or not (the in-flight branch of a run with no other transfer included: production since 6b-2c).
  olc as materialized (
    select k.run_id, k.latest_execution_date, j.proven, j.debit_unbooked
    from (select distinct o.run_id, o.latest_execution_date from ol o where not o.out_of_horizon) k
    cross join lateral private.remittance_inflight_judge(k.run_id, k.latest_execution_date, v_today) j),
  inflight_breach as (
    insert into public.remittance_deadline_breach (organization_id, client_organization_id, ledger_entry_id, payment_id,
                                                   run_id, deadline, latest_execution_date, requested_execution_date,
                                                   late_reason, blocked_reason)
    select p_organization_id, o.client_organization_id, o.ledger_entry_id, o.payment_id, o.run_id, o.deadline,
           o.latest_execution_date, o.requested_execution_date, o.late_reason,
           -- M2c-6b-2c (plan §4.2, Q14's default): « bloqué : débit possible non comptabilisé »; else a returned
           -- payout paid again (Q7, review legal-texts#1): its line's kind, by the item's live line
           case when c.debit_unbooked then 'debit_unbooked'
                when (select x.kind from public.remittance_line x
                      where x.ledger_entry_id = o.ledger_entry_id and not x.released) = 'payout_returned'
                then 'payout_returned' end
    from ol o
    join olc c on c.run_id = o.run_id and c.latest_execution_date = o.latest_execution_date and c.proven
    where not o.out_of_horizon
    on conflict (ledger_entry_id) do nothing)
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, u.code, u.severity, u.subject_type, u.subject_id, u.currency,
         u.amount_minor, u.count, u.oldest_days, coalesce(u.details, '{}')
  from (
  -- (I14 is in run_payment_checks)
  -- I15: an item both waiting and in a live line
  select 'remittance_item_twice'::text, 'violation'::text, 'ledger_entry'::text, q.ledger_entry_id, q.currency::char(3),
         q.amount_minor::bigint, null::integer, null::integer, '{}'::jsonb
  from private.remittance_pending q
  join public.remittance_line l on l.ledger_entry_id = q.ledger_entry_id and not l.released
  where q.organization_id = p_organization_id
  union all
  -- I16: a run's arithmetic — gross = Σ lines, N + D = gross, N ≥ 0, the payout = N, documents' HT plus what the
  -- run's credits absorbed of manual credit notes' waivers (M2c-5b) = Σ line commissions. A run's lines and totals are frozen once approved: each run is read in one pass over its lines, the
  -- runs changed since the previous check run (with a day's margin), every run on Sundays (review perf#5).
  select 'remittance_run_totals', 'violation', 'remittance_run', r.id, r.currency, r.gross_minor, null, null,
         jsonb_build_object('number', r.number, 'lines_minor', l.gross::text, 'documents_ht_minor', s.docs::text,
                            'absorbed_minor', s.absorbed::text, 'commission_minor', (l.charged + s.repriced)::text)
  from public.remittance_run r
  cross join lateral (select coalesce(sum(x.amount_minor), 0) as gross, count(*) as n,
                             coalesce(sum(x.commission_minor) filter (where x.commission_state = 'charged'), 0)
                               as charged
                      from public.remittance_line x where x.run_id = r.id) l
  cross join lateral (
    select (select coalesce(sum(i.ht_minor), 0) from public.commission_invoice i
            where i.run_id = r.id and i.reason = 'commission') as docs,
           (select coalesce(sum(x.commission_minor), 0) from public.remittance_line_repricing x
            where x.pricing_run_id = r.id and x.commission_state = 'charged') as repriced,
           (select t.amount_minor from public.bank_transfer t where t.id = r.transfer_id) as payout,
           -- what the run's credits absorbed of manual credit notes' waivers (M2c-5b: lines with no document)
           (select coalesce(sum(w.amount_minor), 0) from public.commission_waiver w
            where w.run_id = r.id and w.cause = 'absorbed') as absorbed) s
  where r.organization_id = p_organization_id and r.status in ('approved', 'sent', 'booked', 'cancelled')
    and r.approved_at is not null and (v_full or r.updated_at > v_since - interval '1 day')
    and (l.gross <> r.gross_minor or l.n <> r.line_count or r.net_minor < 0
         or r.net_minor + r.settlement_minor <> r.gross_minor or s.docs + s.absorbed <> l.charged + s.repriced
         or (r.status <> 'cancelled' and r.net_minor > 0 and s.payout is distinct from r.net_minor)
         or (r.net_minor = 0 and r.transfer_id is not null))
  union all
  -- I22 (M2c-5b): each (file, tier key) whose state changed since the previous check run (with a day's margin): what
  -- its invoices still charge plus the waivers they hold is the commission charged, the waivers its state's, none below
  -- 0 (the engine's input: the prepare refuses a key that breaks it; keyed per key)
  select 'commission_key_state', 'violation', 'account', c.account_id, 'EUR',
         (o.open_minor + o.waived_minor - s.commission_minor)::bigint, null, null,
         jsonb_build_object('tier_key', c.tier_key, 'commission_minor', s.commission_minor::text,
                            'open_minor', o.open_minor::text, 'waived_minor', o.waived_minor::text,
                            'state_waived_minor', s.waived_minor::text)
  from (select distinct k.account_id, k.tier_key from public.remittance_key_state k
        where k.organization_id = p_organization_id
          and k.created_at > coalesce(v_since, '-infinity'::timestamptz) - interval '1 day') c
  cross join lateral (select k.commission_minor, k.waived_minor from public.remittance_key_state k
                      where k.account_id = c.account_id and k.tier_key = c.tier_key
                      order by k.seq desc limit 1) s
  cross join lateral private.commission_key_open(c.account_id, c.tier_key) o
  where o.open_minor + o.waived_minor <> s.commission_minor or o.waived_minor <> s.waived_minor or o.negative
  union all
  -- I17 numbering: per series and year, 1…n with no gap, the counter at n, dates never going back
  select 'invoice_numbering', 'violation', 'servicer', null, null, null, x.n::integer, null,
         jsonb_build_object('series', x.series, 'year', x.year, 'max_seq', x.mx, 'counter', c.last_seq,
                            'dates_back', x.back)
  from (select i.series, i.year, count(*) as n, max(i.seq) as mx, min(i.seq) as mn,
               bool_or(i.issue_date < i.prev_date) as back
        from (select y.*, lag(y.issue_date) over (partition by y.series, y.year order by y.seq) as prev_date
              from public.commission_invoice y where y.organization_id = p_organization_id) i
        group by i.series, i.year) x
  left join private.invoice_counter c on c.organization_id = p_organization_id and c.series = x.series
    and c.year = x.year
  where x.n <> x.mx or x.mn <> 1 or c.last_seq is distinct from x.mx or x.back
  union all
  -- I17 ledger: each document's entry is the document (4111 = TTC, 7060 = −HT)
  select 'invoice_ledger', 'violation', 'commission_invoice', i.id, i.currency, i.ttc_minor, null, null,
         jsonb_build_object('number', i.number, 'receivable_minor', e.receivable::text, 'revenue_minor', e.revenue::text)
  from public.commission_invoice i
  cross join lateral (
    -- the entry's postings by key first, then each one's account by key (plan robustness, ARCHITECTURE §4)
    select coalesce(sum(p.amount_minor) filter (where la.book = 'commission_receivable'), 0) as receivable,
           coalesce(sum(p.amount_minor) filter (where la.book = 'servicer_revenue'), 0) as revenue
    from (select q.amount_minor, q.ledger_account_id from public.ledger_posting q
          where q.entry_id = i.ledger_entry_id offset 0) p
    cross join lateral (select a.book from public.ledger_account a where a.id = p.ledger_account_id offset 0) la) e
  where i.organization_id = p_organization_id and (e.receivable <> i.ttc_minor or e.revenue <> -i.ht_minor)
  union all
  -- I18: per client, Σ open invoices − Σ refunds owed = 4111[c]; 44574 = Σ pending VAT of the documents (the client's
  -- and the servicer's pooled accounts by their indexes: 4111 has no portfolio, 44574 no claim item; review perf#2)
  select 'settlement_ledger', 'violation', 'client', y.client_organization_id, 'EUR', (y.ledger - y.docs)::bigint, null,
         null, jsonb_build_object('documents_minor', y.docs::text, 'ledger_minor', y.ledger::text)
  from (select c.client_organization_id,
               coalesce((select sum(private.document_open(i.id) * case i.kind when 'invoice' then 1 else -1 end)
                         from public.commission_invoice i where i.client_organization_id = c.client_organization_id),
                        0) as docs,
               coalesce((select sum(p.amount_minor) from public.ledger_account la
                         join public.ledger_posting p on p.ledger_account_id = la.id
                         where la.book = 'commission_receivable' and la.client_organization_id = c.client_organization_id
                           and la.portfolio_id is null),
                        0) as ledger
        from (select distinct i.client_organization_id from public.commission_invoice i
              where i.organization_id = p_organization_id) c) y
  where y.docs <> y.ledger
  union all
  select 'vat_pending_ledger', 'violation', 'servicer', null, 'EUR', (v.ledger - v.docs)::bigint, null, null,
         jsonb_build_object('documents_minor', v.docs::text, 'ledger_minor', v.ledger::text)
  from (select coalesce((select sum(private.document_pending_vat(i.id)) from public.commission_invoice i
                         where i.organization_id = p_organization_id and i.kind = 'invoice'), 0) as docs,
               coalesce((select -sum(p.amount_minor) from public.ledger_account la
                         join public.ledger_posting p on p.ledger_account_id = la.id
                         where la.organization_id = p_organization_id and la.book = 'vat_pending'
                           and la.claim_item_id is null), 0) as ledger) v
  where v.docs <> v.ledger
  union all
  -- I21: collections waiting past the date they are held to (violation, per client)
  select 'remittance_deadline_breached', 'violation', 'client', d.client_organization_id, d.currency,
         sum(d.amount_minor)::bigint, count(*)::integer, max(v_today - d.check_latest_execution_date),
         jsonb_build_object('earliest_latest_execution_date', min(d.check_latest_execution_date),
                            'unmeetable', count(*) filter (where d.unmeetable),
                            'ids', (array_agg(d.ledger_entry_id order by d.check_latest_execution_date))[1:50])
  from dl d where not d.out_of_horizon and d.check_latest_execution_date < v_today
  group by d.client_organization_id, d.currency
  union all
  -- … whose mandate's delay could not be met (OQ-71: « délai intenable », an alert) while the month still runs
  select 'remittance_delay_unmeetable', 'alert', 'client', d.client_organization_id, d.currency,
         sum(d.amount_minor)::bigint, count(*)::integer, max(v_today - d.latest_execution_date),
         jsonb_build_object('earliest_latest_execution_date', min(d.latest_execution_date),
                            'one_month_latest_execution_date', min(d.check_latest_execution_date),
                            'ids', (array_agg(d.ledger_entry_id order by d.latest_execution_date))[1:50])
  from dl d
  where d.unmeetable and not d.out_of_horizon and d.latest_execution_date < v_today
    and d.check_latest_execution_date >= v_today
  group by d.client_organization_id, d.currency
  union all
  -- due soon (D-5 business days) and critical (D-1): per client, the earliest date (one month's for an unmeetable
  -- delay)
  select case when min(d.check_alert_critical_date) <= v_today then 'remittance_due_critical'
              else 'remittance_due_soon' end,
         'alert', 'client', d.client_organization_id, d.currency, sum(d.amount_minor)::bigint, count(*)::integer, null,
         jsonb_build_object('earliest_latest_execution_date', min(d.check_latest_execution_date))
  from dl d
  where not d.out_of_horizon and d.check_latest_execution_date >= v_today and d.check_alert_soon_date <= v_today
  group by d.client_organization_id, d.currency
  union all
  -- collections the business calendar cannot place (E before its horizon: long past any deadline; review nc#0)
  select 'remittance_deadline_not_computable', 'alert', 'client', d.client_organization_id, d.currency,
         sum(d.amount_minor)::bigint, count(*)::integer, null,
         jsonb_build_object('of', 'items', 'earliest_encaissement_date', min(d.encaissement_date),
                            'ids', (array_agg(d.ledger_entry_id order by d.encaissement_date))[1:50])
  from dl d where d.out_of_horizon
  group by d.client_organization_id, d.currency
  union all
  select 'remittance_deadline_not_computable', 'alert', 'remittance_run', o.run_id, o.currency,
         sum(o.amount_minor)::bigint, count(*)::integer, null,
         jsonb_build_object('of', 'lines', 'number', min(o.number),
                            'ids', (array_agg(o.ledger_entry_id order by o.ledger_entry_id))[1:50])
  from ol o where o.out_of_horizon
  group by o.run_id, o.currency
  union all
  select 'remittance_deadline_not_computable', 'alert', 'servicer', null, u.currency, sum(u.unallocated_minor)::bigint,
         count(*)::integer, null,
         jsonb_build_object('of', 'payments', 'earliest_encaissement_date', min(u.encaissement_date),
                            'ids', (array_agg(u.payment_id order by u.encaissement_date))[1:50])
  from ua u where u.out_of_horizon
  group by u.currency
  union all
  -- a run approved or sent whose payout is not debited by its lines' date (violation; review legal#3) …
  select 'remittance_payout_overdue', 'violation', 'remittance_run', o.run_id, o.currency, sum(o.amount_minor)::bigint,
         count(*)::integer, max(v_today - o.latest_execution_date),
         jsonb_build_object('number', min(o.number), 'earliest_latest_execution_date', min(o.latest_execution_date),
                            'requested_execution_date', min(o.requested_execution_date),
                            'ids', (array_agg(o.ledger_entry_id order by o.latest_execution_date))[1:50])
  from ol o where not o.out_of_horizon
  group by o.run_id, o.currency
  union all
  -- M2c-6b-3b part 2 (CPCE-08): a booked run whose payout chain holds another transfer, its payout standing, with lines
  -- late at the chain's paid date and no R124-6 row because the statements do not cover [least(e0, L), L] yet (the
  -- days named, or a break in the balances) or a line that may be another transfer's debit waits (the lines named):
  -- an operational safeguard, not a legal deadline — the row is written by the check that finds both holds passing,
  -- and the alert is then no longer raised
  select 'remittance_breach_held', 'alert', 'remittance_run', h.run_id, h.currency, h.amount_minor, h.line_count,
         h.oldest_days, h.details
  from bh h
  union all
  -- … or by the date it was ordered for (alert)
  select 'remittance_payout_not_executed', 'alert', 'remittance_run', r.id, r.currency, r.net_minor, null,
         v_today - r.requested_execution_date,
         jsonb_build_object('number', r.number, 'requested_execution_date', r.requested_execution_date,
                            'transfer_status', (select t.status from public.bank_transfer t where t.id = r.transfer_id))
  from public.remittance_run r
  where r.organization_id = p_organization_id and r.status in ('approved', 'sent')
    and r.requested_execution_date < v_today
    and not exists (select 1 from public.bank_transfer t where t.id = r.transfer_id and t.status = 'booked')
  union all
  -- a draft whose payout is blocked, with its reason and its deadline
  select 'payout_blocked', 'alert', 'remittance_run', r.id, r.currency, r.net_minor, null, null,
         jsonb_build_object('number', r.number, 'blockers', to_jsonb(r.blockers),
                            'earliest_latest_execution_date', r.earliest_latest_execution_date)
  from public.remittance_run r
  where r.organization_id = p_organization_id and r.status = 'draft' and r.net_minor > 0
    and cardinality(r.blockers) > 0
  union all
  -- a draft waiting more than one business day; one whose preparation failed at once (nothing retries it before
  -- « Actualiser »; review tests-ui#3)
  select 'draft_waiting', 'alert', 'remittance_run', r.id, r.currency, r.net_minor, null,
         private.business_days_between((coalesce(r.prepared_at, (r.last_failure ->> 'at')::timestamptz, r.known_at)
                                        at time zone 'Europe/Paris')::date, v_today),
         jsonb_build_object('number', r.number)
         || case when r.prepared_at is null
                 then jsonb_build_object('prepare_failed', true, 'failure_code', r.last_failure ->> 'code')
                 else '{}'::jsonb end
  from public.remittance_run r
  where r.organization_id = p_organization_id and r.status = 'draft'
    and ((r.prepared_at is not null
          and private.business_days_between((r.prepared_at at time zone 'Europe/Paris')::date, v_today) > 1)
         or (r.prepared_at is null and r.job is null and r.last_failure ->> 'step' = 'prepare'))
  union all
  -- an approval more than 2 business days after K (invoice_late)
  select 'invoice_late', 'alert', 'remittance_run', r.id, r.currency, r.invoice_ttc_minor, null, null,
         jsonb_build_object('number', r.number, 'known_at', r.known_at, 'approved_at', r.approved_at)
  from public.remittance_run r
  where r.organization_id = p_organization_id and r.invoice_late and r.approved_at > clock_timestamp() - interval '30 days'
  union all
  -- an invoice still open after the date it is paid by (§15 invoice_overdue; L441-10 II: penalties run from the next
  -- day): a due invoice, a cancellation's corrective invoice the next run did not set off in time (legal review #4,
  -- round 2; OQ-72), or a run's netted invoice whose plan left a remainder for the next run by its date (M2c-5 review
  -- legal#4; what its own run sets off is held to that run's payout by the payout checks above)
  -- (M2c-7d-3, plan §6.2.10 [critic] L9) never an invoice of a client in liquidation, nor one born before the opening of
  -- a client in a proceeding: to declare (claims_to_declare), never dunned (private.invoice_to_declare, by keys)
  select 'invoice_overdue', 'alert', 'commission_invoice', i.id, i.currency, o.open, null, v_today - i.due_date,
         jsonb_build_object('number', i.number, 'client_id', i.client_organization_id, 'settlement', i.settlement,
                            'due_date', i.due_date)
  from public.commission_invoice i
  cross join lateral (select private.document_open(i.id) as open) o
  where i.organization_id = p_organization_id and i.due_date is not null and i.due_date < v_today and o.open > 0
    -- (review round 1, CC-1) asked only for a client in a proceeding or a liquidation (v_proc): one call per such
    -- invoice, none for the others (the case keeps the order)
    and not case when i.client_organization_id = any (v_proc)
                 then private.invoice_to_declare(i.id, i.client_organization_id, v_today) else false end
  union all
  -- (M2c-7d-3 review round 2) a run's invoice its plan set off in full (no due date: paid with its run's payout) whose
  -- set-off the debit withheld — a mandate's end, a seizure (7d-2) —: still open after that day, which stands for its
  -- due date (private.invoice_withheld_on; the servicer's rule, OQ-92); the same exclusions. Only the clients with an
  -- event in effect (v_evt), their invoices by commission_invoice_client_idx (fenced), each one's withholding (no due
  -- date only), then its open part, by keys
  select 'invoice_overdue', 'alert', 'commission_invoice', i.id, i.currency, o.open, null, v_today - w.withheld_on,
         jsonb_build_object('number', i.number, 'client_id', i.client_organization_id, 'settlement', i.settlement,
                            'due_date', i.due_date, 'withheld_on', w.withheld_on)
  from unnest(v_evt) c (id)
  cross join lateral (select q.id, q.organization_id, q.client_organization_id, q.kind, q.currency, q.number,
                             q.settlement, q.due_date
                      from public.commission_invoice q where q.client_organization_id = c.id offset 0) i
  cross join lateral (select case when i.kind = 'invoice' and i.due_date is null
                                  then private.invoice_withheld_on(i.id) end as withheld_on offset 0) w
  cross join lateral (select case when w.withheld_on < v_today then private.document_open(i.id) end as open offset 0) o
  where i.organization_id = p_organization_id and w.withheld_on < v_today and o.open > 0
    and not case when i.client_organization_id = any (v_proc)
                 then private.invoice_to_declare(i.id, i.client_organization_id, v_today) else false end
  union all
  -- a refund owed to the client still unpaid 30 days after its credit note (M2c-5b review legal#0; an operating
  -- threshold, not a legal deadline): what a credit note gives back beyond what its invoices still owed is paid with a
  -- later run's payout (the plan's refunds); with no later run (no collection left, a proceeding, the mandate ended)
  -- nothing pays it until M2c-7's record_client_refund (design §16: an ops-ordered transfer from the own account).
  -- Credit notes that owed a refund at issue only, by their index; `planned_run`: a run in flight whose plan pays it.
  select 'credit_refund_owed', 'alert', 'commission_invoice', i.id, i.currency, o.open, null, v_today - i.issue_date,
         jsonb_build_object('number', i.number, 'client_id', i.client_organization_id, 'reason', i.reason,
                            'issue_date', i.issue_date,
                            'planned_run', (select r.number from public.remittance_run r
                                            where r.client_organization_id = i.client_organization_id
                                              and r.currency = i.currency and r.status in ('approved', 'sent')
                                              and exists (select 1 from jsonb_array_elements(
                                                                   coalesce(r.settlement_plan -> 'settles', '[]')) s
                                                          where s ->> 'document_id' = i.id::text)
                                            limit 1))
  from public.commission_invoice i
  cross join lateral (select private.document_open(i.id) as open) o
  where i.organization_id = p_organization_id and i.kind = 'credit_note' and i.issue_date < v_today - 30
    and exists (select 1 from public.commission_credit_correction c where c.credit_note_id = i.id and c.excess_minor > 0)
    and o.open > 0
  union all
  -- money matched to a client's file but not allocated (still in 4710) gets the same clock (OQ-26, compliance B7)
  select 'unallocated_deadline', 'alert', 'servicer', null, u.currency, sum(u.unallocated_minor)::bigint,
         count(*)::integer, null,
         jsonb_build_object('earliest_latest_execution_date', min(u.latest_execution_date),
                            'held', count(*) filter (where u.held),
                            'ids', (array_agg(u.payment_id order by u.latest_execution_date))[1:50])
  from ua u where not u.out_of_horizon and u.alert_soon_date <= v_today
  group by u.currency
  union all
  -- the hourly schedule could not create a client's draft, or read its candidates, or its job died (review nc#0)
  select 'remittance_schedule_failed', 'alert', 'servicer', null, null, null, count(*)::integer, null,
         jsonb_build_object('last_failed_at', max(f.failed_at),
                            'last_error', (array_agg(f.error order by f.failed_at desc))[1],
                            'codes', to_jsonb(array_agg(distinct f.code)),
                            'client_ids', to_jsonb(coalesce(array_agg(distinct f.client_organization_id)
                                                              filter (where f.client_organization_id is not null),
                                                            '{}')))
  from private.remittance_schedule_failure f
  where f.organization_id = p_organization_id and f.failed_at >= v_failures
  having count(*) > 0
  union all
  -- documents the job could not draw (M2c-5 review perf#2): each failure is recorded on its row and retried; until it
  -- is drawn, the alert names it with its last error
  select 'remittance_document_failed', 'alert', 'servicer', null, null, null, count(*)::integer,
         max(v_today - (t.created_at at time zone 'Europe/Paris')::date),
         jsonb_build_object('statements', count(*) filter (where t.kind = 'statement'),
                            'invoices', count(*) filter (where t.kind = 'invoice'),
                            'last_failed_at', max(t.last_attempt_at),
                            'last_error', (array_agg(t.last_error order by t.last_attempt_at desc, t.ref_id))[1],
                            'ids', to_jsonb((array_agg(t.ref_id order by t.created_at, t.ref_id))[1:50]))
  from private.remittance_document_todo t
  where t.organization_id = p_organization_id and t.attempts > 0
  having count(*) > 0
  union all
  -- … and the documents still due 24 hours after they were (§15 document_missing): a statement or a PDF the client
  -- space says « en préparation »
  select 'remittance_document_missing', 'alert', 'servicer', null, null, null, count(*)::integer,
         max(v_today - (m.due_since at time zone 'Europe/Paris')::date),
         jsonb_build_object('statements', count(*) filter (where m.kind = 'statement'),
                            'invoices', count(*) filter (where m.kind = 'invoice'),
                            'oldest_due_since', min(m.due_since),
                            'numbers', to_jsonb((array_agg(m.number order by m.due_since, m.ref_id))[1:50]))
  from private.remittance_documents_missing(p_organization_id, interval '24 hours') m
  having count(*) > 0
  union all
  -- reference data (M2c-3): the VAT pack's review, the calendar's horizon
  select a.code, 'alert', 'servicer', null, null, null, null, null, a.details
  from private.reference_data_alerts(v_today) a
  ) u (code, severity, subject_type, subject_id, currency, amount_minor, count, oldest_days, details);
end;
$$;

------------------------------------------------------------------------------------------
-- The statement fr-4 (plan §6.2.8) and the run page's withheld set-off (carried item 4)
------------------------------------------------------------------------------------------

-- private.remittance_statement_build, redefined from 20261117120000_statement_suivi.sql (line 363; same signature and
-- settings: SECURITY DEFINER, search_path '', enable_hashjoin and enable_mergejoin off — and, M2c-7d-3, enable_seqscan
-- off: the reads test found its « not remitted » read of the client's queue items posted after K reading the queue of
-- every servicer whole, 10,000 planted items, by a sequential scan under a stale estimate of the servicer's and the
-- client's keys, where remittance_pending_client_idx serves it; its grants restated below).
-- M2c-7d-3 (plan §6.2.8; [critic] L12, L13, M7-MONEY-5): a payload of schema 2 (template releve-reversement-fr-4) when
-- it holds what fr-3 cannot word — the end of the mandate known at K (`mandate_end` {kind, effective_date, recorded_on,
-- payee_kind}), who it is addressed to (`addressees` [{role, copy}], when someone acts for the client), the set-offs a
-- debit withheld that this run gives back (`withheld_given_back` [{run_number, amount_minor, withheld_on, reason}]),
-- an advance taken back (each with its `born_on`); otherwise fr-3's payload, unchanged. As of K throughout: an event or
-- a representative recorded after K changes no statement. Nothing else changes.
create or replace function private.remittance_statement_build(p_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
set enable_seqscan = off
as $$
declare
  r public.remittance_run;
  v_cancelled boolean;
  v_exp integer;
  v_lines jsonb;
  v_files jsonb;
  v_natures jsonb;
  v_totals jsonb;
  v_docs jsonb;
  v_earlier jsonb;
  v_mandates jsonb;
  v_payout jsonb;
  v_suivi jsonb;
  v_held jsonb;
  v_refunded jsonb;
  v_position jsonb;
  v_prev public.remittance_run;
  v_k_day date;
  v_issue date;
  v_payload jsonb;
  v_receivable bigint;
  v_advances bigint;
  v_docs_ttc bigint;
  v_issuer jsonb;
  v_client jsonb;
  v_end jsonb;
  v_addr jsonb;
  v_withheld jsonb;
  v_fr4 boolean;
begin
  select * into r from public.remittance_run where id = p_run_id for share;
  if not found or r.approved_at is null then
    raise exception 'statement of %: not an approved run', p_run_id using errcode = 'check_violation';
  end if;
  v_cancelled := r.status = 'cancelled';
  select c.minor_exponent into v_exp from public.currency c where c.code = r.currency;
  v_k_day := (r.known_at at time zone 'Europe/Paris')::date;
  v_issue := (r.approved_at at time zone 'Europe/Paris')::date;

  -- the run's lines, then the earlier lines whose commission this run priced (amount 0: remitted then)
  drop table if exists pg_temp._rd_line;
  create temp table _rd_line on commit drop as
  select 0 as section, l.line_no, l.line_no as source_line_no, null::text as from_run, l.kind, l.ledger_entry_id,
         l.account_id, l.portfolio_id, l.mandate_id, l.payment_id, l.encaissement_date, l.effective_date, l.deadline,
         l.amount_minor, l.commission_minor, l.commission_state, l.parts, l.invoice_id, l.posted_at,
         l.latest_execution_date, l.unmeetable
  from public.remittance_line l where l.run_id = r.id
  union all
  select 1, 0, l.line_no, (select x.number from public.remittance_run x where x.id = l.run_id), l.kind,
         l.ledger_entry_id, l.account_id, l.portfolio_id, l.mandate_id, l.payment_id, l.encaissement_date,
         l.effective_date, l.deadline, 0, rp.commission_minor, rp.commission_state, rp.parts, rp.invoice_id,
         l.posted_at, l.latest_execution_date, l.unmeetable
  from public.remittance_line_repricing rp
  cross join lateral (select y.* from public.remittance_line y where y.run_id = rp.run_id and y.line_no = rp.line_no
                      offset 0) l
  where rp.pricing_run_id = r.id;

  drop table if exists pg_temp._rd_fact;
  create temp table _rd_fact on commit drop as
  select x.section, x.line_no, x.source_line_no, x.from_run, x.kind, x.account_id, x.amount_minor, x.commission_minor,
         a.external_ref as file, d.name as debtor, m.reference as mandate, pf.name as portfolio,
         coalesce(it.items, '[]'::jsonb) as items, coalesce(it.components, '[]'::jsonb) as components,
         -- M2c-6b-2b (review LT-2, critic L4): the item an unplanned payout's return re-owes is marked `unplanned`: the
         -- renderer words it « Virement exécuté hors reversement revenu », never « Virement revenu impayé — reversé à
         -- nouveau »
         case when un.unplanned then 'unplanned' else n.reason end as nature_reason,
         x.encaissement_date, x.effective_date, x.deadline, x.commission_state,
         coalesce(pt.rules, '[]'::jsonb) as rules, coalesce(pt.rates, '[]'::jsonb) as rates,
         coalesce(pt.basis, 0) as basis, coalesce(inv.number, cn.number) as invoice, rc.number as receipt,
         la.ledger_entry_id is not null as late, lc.cause as late_cause,
         -- M2c-6b-2d (critic L9, critic2 ML-9): what unplanned payouts paid of a late line, as of K, and when
         pu.paid_minor as paid_by_unplanned_minor, pu.paid_on as paid_by_unplanned_on
  from pg_temp._rd_line x
  left join lateral (select q.external_ref from public.account q where q.id = x.account_id offset 0) a on true
  left join lateral (
    select (array_agg(pa.display_name order by pa.display_name, pa.id))[1] as name
    from public.account_party ap
    cross join lateral (select q.id, q.display_name from public.party q where q.id = ap.party_id offset 0) pa
    where ap.account_id = x.account_id and ap.role = 'borrower') d on true
  left join lateral (select q.reference from public.mandate q where q.id = x.mandate_id offset 0) m on true
  left join lateral (select q.name from public.portfolio q where q.id = x.portfolio_id offset 0) pf on true
  -- the items and components the entry moved (its 1100 postings), each item once, in a total order
  left join lateral (
    with y as (
      select q.claim_item_id, q.component
      from public.ledger_posting lp
      cross join lateral (select v.claim_item_id, v.component from public.ledger_account v
                          where v.id = lp.ledger_account_id and v.book = 'debtor_receivable' offset 0) q
      where lp.entry_id = x.ledger_entry_id)
    select (select jsonb_agg(jsonb_build_array(z.kind, z.ref) order by z.due_date nulls last, z.ref, z.kind, z.id)
            from (select distinct ci.id, ci.kind, ci.ref, ci.due_date
                  from y cross join lateral (select c.id, c.kind, c.ref, c.due_date from public.claim_item c
                                             where c.id = y.claim_item_id offset 0) ci) z) as items,
           (select jsonb_agg(z.component order by z.sort_order)
            from (select distinct y.component, lc.sort_order
                  from y cross join lateral (select c.sort_order from public.ledger_component c
                                             where c.code = y.component offset 0) lc) z) as components) it on true
  left join lateral (select q.reason from public.client_notification q where q.ledger_entry_id = x.ledger_entry_id
                     offset 0) n on true
  -- M2c-6b-2b (review LT-2): a payout_returned line reversing an unplanned remittance (the reversed entry's booking is an
  -- unplanned_payout), by key: the line's entry, then the reversed entry's booking by its entry
  left join lateral (select exists (select 1 from public.bank_line_booking k
                                    where k.entry_id = e.reverses_entry_id and k.kind = 'unplanned_payout') as unplanned
                     from (select q.reverses_entry_id from public.ledger_entry q where q.id = x.ledger_entry_id
                           offset 0) e
                     where x.kind = 'payout_returned') un on true
  -- the rules and band rates of the line's parts, and the basis they priced
  left join lateral (
    select (select jsonb_agg(distinct p ->> 'label_fr') from jsonb_array_elements(x.parts) p
            where p ->> 'label_fr' is not null) as rules,
           (select jsonb_agg(distinct t ->> 0) from jsonb_array_elements(x.parts) p
            cross join lateral jsonb_array_elements(coalesce(p -> 'tiers', '[]')) t) as rates,
           (select sum((p ->> 'basis')::bigint) from jsonb_array_elements(x.parts) p) as basis) pt on true
  left join lateral (select q.number from public.commission_invoice q where q.id = x.invoice_id offset 0) inv on true
  -- a reversal's negative commission is on the run's credit note, which names its entry (review figures#5)
  left join lateral (select q.number
                     from public.commission_credit_alloc ca
                     cross join lateral (select y.number, y.seq from public.commission_invoice y
                                         where y.id = ca.credit_note_id and y.run_id = r.id
                                           and y.kind = 'credit_note' and y.reason = 'commission' offset 0) q
                     where x.invoice_id is null and ca.entry_id = x.ledger_entry_id
                     order by q.seq limit 1) cn on true
  left join lateral (select q.number from public.receipt q where q.payment_id = x.payment_id
                     order by q.version limit 1) rc on true
  left join lateral (select q.ledger_entry_id from public.remittance_late_approval q
                     where q.run_id = r.id and q.ledger_entry_id = x.ledger_entry_id and x.section = 0
                     offset 0) la on true
  -- M2c-6b-2d (critic L9, critic2 ML-9; Q15's default: the item keeps its own clock): a late line an unplanned payout's
  -- P paid (private.unplanned_paid_item) — its booking posted at or before K and not reversed by then — states that
  -- payout's date and the amount attributed (all of the line, or part of it). Read for the late lines only, by key
  -- (private.remittance_statement_paid_by_unplanned). `offset 0` keeps the subquery whole: pulled up, the late test
  -- would filter the helper's rows after calling it for every line (50 000 calls for a run with none late, 0.7 s);
  -- kept, it is a one-time filter and the helper is never called for a line that is not late
  left join lateral (select u.paid_minor, u.paid_on
                     from private.remittance_statement_paid_by_unplanned(x.ledger_entry_id, r.known_at) u
                     where la.ledger_entry_id is not null
                     offset 0) pu on true
  -- why a line was paid after its latest execution date, from the data (review legal#6; the approver's reason stays
  -- in the back office): a payout of it that came back unpaid, paid again (M2c-6b-1 review round 2, L1: the line keeps
  -- the date of the run line it came from, K2), the mandate's delay could not be met (held to one month, R124-6), the
  -- collection reached the queue after its J-5 date (the deadline guard's margin, 5 business days before its latest
  -- execution date), or the approval came late
  -- (M2c-6b-2b, review LT-2: the item an unplanned payout's return re-owes, held to the date of the items its P paid,
  -- critic2 ML-2 — the unplanned payout came back unpaid, never « reversé à nouveau »)
  -- (M2c-6b-2d, critic L9: an item an unplanned payout paid, as of K — first: the date it was paid is the fact; review
  -- round 1 legal-texts-3: only when it paid all of the line — one it paid in part keeps its own cause for the rest,
  -- the attribution carried beside it in paid_by_unplanned_minor / _on)
  left join lateral (select case when pu.paid_minor > 0 and pu.paid_minor >= x.amount_minor then 'paid_by_unplanned'
                                 when x.kind = 'payout_returned' and un.unplanned then 'unplanned_payout_returned'
                                 when x.kind = 'payout_returned' then 'payout_returned'
                                 when x.unmeetable then 'unmeetable'
                                 when private.business_days_between((x.posted_at at time zone 'Europe/Paris')::date,
                                                                    x.latest_execution_date) < 5
                                 then 'identified_late'
                                 else 'approved_late' end as cause
                     where la.ledger_entry_id is not null offset 0) lc on true;

  select coalesce(jsonb_agg(jsonb_build_array(
           f.source_line_no, f.mandate, f.portfolio, f.file, f.debtor, f.items, f.components, f.kind, f.nature_reason,
           f.from_run, f.encaissement_date, f.effective_date, f.deadline, f.amount_minor::text, f.rules, f.rates,
           f.basis::text, f.commission_minor::text, f.commission_state, f.invoice, f.receipt, f.late, f.late_cause,
           f.paid_by_unplanned_minor::text, f.paid_by_unplanned_on)
           order by f.section, f.from_run, f.source_line_no), '[]')
  into v_lines from pg_temp._rd_fact f;

  -- per file (the PDF's table): the run's lines and the commission priced on the file in this run (a file with only
  -- earlier lines priced now has 0 lines: counted apart in the totals, review tests-ui#4)
  select coalesce(jsonb_agg(jsonb_build_object(
           'file', g.file, 'debtor', g.debtor, 'lines', g.n::text, 'amount_minor', g.amount::text,
           'commission_minor', g.commission::text, 'late', g.late::text)
           order by g.file nulls last, g.account_id), '[]')
  into v_files
  from (select f.account_id, min(f.file) as file, min(f.debtor) as debtor,
               count(*) filter (where f.section = 0) as n, sum(f.amount_minor) as amount,
               sum(f.commission_minor) as commission, count(*) filter (where f.late) as late
        from pg_temp._rd_fact f group by f.account_id) g;

  -- per nature (the run's lines by kind and reason; the earlier lines priced now as one row)
  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', n.kind, 'reason', n.reason, 'count', n.c::text, 'amount_minor', n.amount::text,
           'commission_minor', n.commission::text) order by n.section, n.kind, n.reason nulls first), '[]')
  into v_natures
  from (select f.section, case when f.section = 1 then 'repricing' else f.kind end as kind,
               case when f.section = 0 and f.kind in ('forward', 'allocation_reversal', 'forward_reversal')
                    then f.nature_reason
                    -- M2c-6b-2b (review LT-2): the unplanned returns' items apart from the planned returns'
                    when f.section = 0 and f.kind = 'payout_returned' and f.nature_reason = 'unplanned'
                    then 'unplanned' end as reason,
               count(*) as c, sum(f.amount_minor) as amount, sum(f.commission_minor) as commission
        from pg_temp._rd_fact f group by 1, 2, 3) n;

  select jsonb_build_object(
           'line_count', count(*) filter (where f.section = 0),
           'repriced_count', count(*) filter (where f.section = 1),
           'file_count', count(distinct f.account_id) filter (where f.section = 0),
           'repriced_only_file_count',
             (select count(*) from (select g.account_id from pg_temp._rd_fact g group by g.account_id
                                    having bool_and(g.section = 1)) o),
           'collected_minor', coalesce(sum(f.amount_minor) filter (where f.amount_minor > 0), 0)::text,
           'reversed_minor', coalesce(sum(f.amount_minor) filter (where f.amount_minor < 0), 0)::text,
           'commission_ht_minor', coalesce(sum(f.commission_minor), 0)::text,
           'late_count', count(*) filter (where f.late))
         || jsonb_build_object(
           'gross_minor', r.gross_minor::text,
           'invoice_ht_minor', coalesce(r.invoice_ht_minor, 0)::text,
           'invoice_vat_minor', coalesce(r.invoice_vat_minor, 0)::text,
           'invoice_ttc_minor', coalesce(r.invoice_ttc_minor, 0)::text,
           'credit_ht_minor', coalesce(r.credit_ht_minor, 0)::text,
           'credit_vat_minor', coalesce(r.credit_vat_minor, 0)::text,
           'credit_ttc_minor', coalesce(r.credit_ttc_minor, 0)::text,
           'commission_taken_minor', coalesce(r.commission_taken_minor, 0)::text,
           'advance_recovered_minor', coalesce(r.advance_recovered_minor, 0)::text,
           'refund_minor', coalesce(r.refund_minor, 0)::text,
           'settlement_minor', r.settlement_minor::text,
           'net_minor', r.net_minor::text)
         -- M2c-5b: what the run's credits absorbed of manual credit notes' waivers (lines with no document: a
         -- manual credit note credited it already), named with the invoices it was on and the manual credit notes
         -- that waived it (review legal#4: « avoir n° … rectifiant la facture … », followed back through a
         -- cancellation's corrective invoice); absent when nothing was (payloads drawn before keep their bytes)
         || coalesce((select jsonb_build_object('waived_absorbed_minor', (-sum(w.amount_minor))::text,
                                                'waived_absorbed_invoices',
                                                jsonb_agg(distinct i.number order by i.number),
                                                'waived_absorbed_credit_notes',
                                                private.absorbed_credit_notes(r.id))
                      from public.commission_waiver w
                      cross join lateral (select q.number from public.commission_invoice q
                                          where q.id = w.invoice_id offset 0) i
                      where w.run_id = r.id and w.cause = 'absorbed'
                      having count(*) > 0), '{}'::jsonb)
  into v_totals from pg_temp._rd_fact f;

  -- the run's documents (its approval's; a cancellation's too when the run was cancelled before this was drawn), each
  -- with the invoices it corrects, the credit notes of the cancellation that annul it, and what this payout sets off
  -- (nothing once cancelled)
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id, 'kind', i.kind, 'number', i.number, 'issue_date', i.issue_date, 'reason', i.reason,
           'mandate', (select m.reference from public.mandate m where m.id = i.mandate_id),
           'ht_minor', i.ht_minor::text, 'vat_minor', i.vat_minor::text, 'ttc_minor', i.ttc_minor::text,
           'vat_rate', i.vat_rate::text, 'settlement', i.settlement, 'due_date', i.due_date,
           'clause_ref', i.payload #>> '{settlement,clause_ref}',
           'payment_reference', i.payload -> 'payment_reference',
           'own_account', case when i.payload -> 'own_account' is not null
                               and jsonb_typeof(i.payload -> 'own_account') = 'object'
                               then jsonb_build_object('iban', private.iban_masked(i.payload #>> '{own_account,iban}'),
                                                       'holder', i.payload #>> '{own_account,holder}') end,
           'corrects', (select coalesce(jsonb_agg(jsonb_build_object('number', o.number, 'issue_date', o.issue_date,
                                                                     'ht_minor', c.ht_minor::text,
                                                                     'vat_minor', c.vat_minor::text)
                                                  order by o.seq), '[]')
                        from public.commission_credit_correction c
                        cross join lateral (select q.number, q.issue_date, q.seq from public.commission_invoice q
                                            where q.id = c.original_invoice_id offset 0) o
                        where c.credit_note_id = i.id),
           'cancelled_by', (select coalesce(jsonb_agg(jsonb_build_object('number', o.number,
                                                                         'issue_date', o.issue_date)
                                                      order by o.seq), '[]')
                            from public.commission_credit_correction c
                            cross join lateral (select q.number, q.issue_date, q.seq from public.commission_invoice q
                                                where q.id = c.credit_note_id and q.run_id = r.id
                                                  and q.reason = 'run_cancelled' offset 0) o
                            where c.original_invoice_id = i.id),
           'settles_minor', case when v_cancelled then '0'
                                 else (select coalesce(sum((s ->> 'amount')::bigint), 0)::text
                                       from jsonb_array_elements(coalesce(r.settlement_plan -> 'settles', '[]')) s
                                       where s ->> 'document_id' = i.id::text) end)
           order by i.seq), '[]')
  into v_docs
  from public.commission_invoice i where i.run_id = r.id;

  -- what this payout sets off from documents of earlier runs (compensation, a refund owed, an advance); nothing once
  -- the run is cancelled
  -- (M2c-7d-3, plan §1.2, §6.2.8) each advance taken back with its date (private.advance_born_on: the date the client
  -- space prints), fr-4's
  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', s ->> 'kind', 'document_kind', i.kind, 'number', i.number, 'issue_date', i.issue_date,
           'amount_minor', s ->> 'amount')
           || case when s ->> 'kind' = 'advance'
                   then jsonb_build_object('born_on', private.advance_born_on((s ->> 'document_id')::uuid))
                   else '{}'::jsonb end
           order by i.seq nulls last, s ->> 'document_id'), '[]')
  into v_earlier
  from jsonb_array_elements(case when v_cancelled then '[]'::jsonb
                                 else coalesce(r.settlement_plan -> 'settles', '[]') end) s
  left join lateral (select q.kind, q.number, q.issue_date, q.seq, q.run_id from public.commission_invoice q
                     where q.id = (s ->> 'document_id')::uuid offset 0) i on true
  where i.run_id is distinct from r.id and (s ->> 'amount')::bigint <> 0;

  -- (M2c-7d-3, plan §6.2.8; [critic] L13) the end of the client's mandate known at K — its kind, its day, the day the
  -- servicer recorded it (C. civ. 2008) — and the payee the events known then require; ([critic] L12) who the statement
  -- is addressed to as of K, by role only, kept when someone acts for the client; ([critic] M7-MONEY-5) the set-offs a
  -- debit withheld that this run gives back: each settlement_withheld line, the run it was withheld from (its barred
  -- settlement's source), that settlement's day and the ledger's reason (its reversal's), by key
  v_end := private.statement_mandate_end(r.client_organization_id, v_k_day, r.known_at);
  select case when bool_or(a.role <> 'client')
              then jsonb_agg(jsonb_build_object('role', a.role, 'copy', a.copy) order by a.copy, a.role) end
  into v_addr
  from private.statement_addressees(r.client_organization_id, v_k_day, r.known_at) a;
  select coalesce(jsonb_agg(jsonb_build_object('run_number', y.number, 'amount_minor', l.amount_minor::text,
                                               'withheld_on', b.effective_date, 'reason', x.reason)
                            order by b.effective_date, y.number, l.line_no), '[]')
  into v_withheld
  from pg_temp._rd_line l
  cross join lateral (select q.reason, q.reverses_entry_id from public.ledger_entry q where q.id = l.ledger_entry_id
                      offset 0) x
  cross join lateral (select q.effective_date, q.source_id from public.ledger_entry q where q.id = x.reverses_entry_id
                      offset 0) b
  cross join lateral (select q.number from public.remittance_run q
                      where q.id = case when pg_input_is_valid(b.source_id, 'uuid') then b.source_id::uuid end
                      offset 0) y
  where l.section = 0 and l.kind = 'settlement_withheld';
  -- fr-4's payload (schema 2) when one of these is there; otherwise fr-3's, unchanged (schema 1: its bytes kept)
  v_fr4 := v_end is not null or v_addr is not null or jsonb_array_length(v_withheld) > 0
           or exists (select 1 from jsonb_array_elements(v_earlier) e where e ->> 'kind' = 'advance');

  -- the mandates the statement covers, with the clause references of their terms on K's day (R124-3 3°, 4°)
  select coalesce(jsonb_agg(jsonb_build_object(
           'reference', m.reference, 'signed_on', m.signed_on,
           'commission_clause_ref', t.commission_clause_ref, 'remittance_clause_ref', t.remittance_clause_ref,
           'netting_clause_ref', t.remittance_terms #>> '{netting,clause_ref}',
           'clawback_clause_ref', t.remittance_terms #>> '{clawback,clause_ref}')
           order by m.reference, m.id), '[]')
  into v_mandates
  from (select distinct x.mandate_id from pg_temp._rd_line x where x.mandate_id is not null
        union select i.mandate_id from public.commission_invoice i where i.run_id = r.id) mm
  cross join lateral (select q.* from public.mandate q where q.id = mm.mandate_id offset 0) m
  left join lateral (select q.commission_clause_ref, q.remittance_clause_ref, q.remittance_terms
                     from public.mandate_terms q
                     where q.mandate_id = m.id and q.valid_from <= v_k_day
                     order by q.valid_from desc limit 1) t on true;

  -- the payout as ordered (never « payé » before the bank's debit: M2c-6 books it)
  select jsonb_build_object('amount_minor', t.amount_minor::text, 'ordered_on', v_issue,
                            'requested_execution_date', t.requested_execution_date,
                            'iban', private.iban_masked(t.payee_iban), 'holder', t.payee_name,
                            'end_to_end_id', t.end_to_end_id, 'status', t.status)
  into v_payout from public.bank_transfer t where t.id = r.transfer_id;

  -- (M2c-6b-2d) « Suivi »: the events of the client's earlier approved runs of the currency posted in the window from
  -- the previous approved run's K to this run's K, as of K (private.remittance_statement_previous_payouts; plan §5).
  -- M2c-5's follow_up (the previous run's current state, not as of K) is dropped.
  v_suivi := private.remittance_statement_previous_payouts(r.id);
  -- the run this one follows (the refunds' window below)
  select * into v_prev from public.remittance_run x where x.id = r.previous_run_id;

  -- money received on the client's files and not remitted, as of K (C. civ. 1993, OQ-40; review figures#2): per file
  -- and reason, what each payment matched to one of them by K still held on 4710 at K — its amount less what its
  -- other entries posted by K moved (allocations, forwards, refunds, returns, and their reversals: a refund that came
  -- back by K is held again, review legal#3). The payments that can have held money at K: those holding some now,
  -- those refunded or returned since K, and those allocated or forwarded since K (their entries are the client's
  -- pending items posted after K). No payer data.
  select coalesce(jsonb_agg(jsonb_build_object(
           'file', h.file, 'reason', h.reason, 'currency', h.currency, 'amount_minor', h.amount::text,
           'first_date', h.first_date, 'last_date', h.last_date, 'count', h.n::text)
           order by h.file, h.reason, h.currency), '[]')
  into v_held
  from (select a.external_ref as file,
               coalesce(p.review_reason, case when p.status in ('refund_pending', 'refunded') then 'refund_pending'
                                              else 'pending' end) as reason,
               p.currency, sum(u.unallocated) as amount, min(p.booking_date) as first_date,
               max(p.booking_date) as last_date, count(*) as n
        from (select distinct c.id
              from (select y.id from public.payment y
                    where y.organization_id = r.organization_id
                      and y.status in ('matched', 'partially_allocated', 'refund_pending')
                      and y.client_organization_id = r.client_organization_id
                    union all
                    select y.id from public.payment y
                    where y.organization_id = r.organization_id and y.status in ('refunded', 'returned')
                      and y.client_organization_id = r.client_organization_id and y.updated_at > r.known_at
                    union all
                    select e.payment_id from private.remittance_pending q
                    cross join lateral (select y.payment_id from public.ledger_entry y where y.id = q.ledger_entry_id
                                        offset 0) e
                    where q.organization_id = r.organization_id
                      and q.client_organization_id = r.client_organization_id
                      and q.posted_at > r.known_at and e.payment_id is not null) c) c
        cross join lateral (select y.* from public.payment y where y.id = c.id offset 0) p
        cross join lateral (
          select (p.amount_minor - coalesce(sum(lp.amount_minor), 0))::bigint as unallocated
          from (select e.id from public.ledger_entry e
                where e.payment_id = p.id and e.entry_type <> 'cash_in' and e.posted_at <= r.known_at offset 0) e
          cross join lateral (select y.amount_minor from public.ledger_posting y
                              where y.entry_id = e.id
                                and (select la.book from public.ledger_account la where la.id = y.ledger_account_id)
                                    = 'unallocated_payment'
                              offset 0) lp) u
        cross join lateral (select q.external_ref from public.account q where q.id = p.account_id offset 0) a
        where p.client_organization_id = r.client_organization_id and p.created_at <= r.known_at
          and p.matched_at <= r.known_at and u.unallocated > 0
        group by 1, 2, 3) h;

  -- refunded to payers between the previous K and this K, and not back by K (a refund that bounced by K is money held
  -- again, above: review legal#3, figures#3)
  select coalesce(jsonb_agg(jsonb_build_object(
           'file', h.file, 'reason', h.reason, 'currency', h.currency, 'amount_minor', h.amount::text,
           'first_date', h.first_date, 'last_date', h.last_date, 'count', h.n::text)
           order by h.file, h.reason, h.currency), '[]')
  into v_refunded
  from (select a.external_ref as file, q.reason_code as reason, q.currency, sum(q.amount_minor) as amount,
               min(q.executed_on) as first_date, max(q.executed_on) as last_date, count(*) as n
        from public.refund_request q
        cross join lateral (select y.account_id, y.client_organization_id from public.payment y
                            where y.id = q.payment_id offset 0) p
        cross join lateral (select y.external_ref from public.account y where y.id = p.account_id offset 0) a
        cross join lateral (select y.posted_at from public.ledger_entry y where y.id = q.cash_out_entry_id offset 0) e
        left join lateral (select y.posted_at from public.ledger_entry y where y.id = q.bounce_entry_id offset 0) b
          on true
        where q.organization_id = r.organization_id and q.status in ('executed', 'bounced')
          and p.client_organization_id = r.client_organization_id
          and e.posted_at <= r.known_at and (v_prev.known_at is null or e.posted_at > v_prev.known_at)
          and (q.status = 'executed' or b.posted_at > r.known_at)
        group by a.external_ref, q.reason_code, q.currency) h;

  -- the position (§10.7): owed to the client at K — every item pending then is this run's (one live run per client
  -- and currency, I14) — and after this payout (still owed once the run is cancelled); what the client owes the
  -- servicer (4111 + 4112) as known at K and after this statement's documents and the settlement at the payout's debit
  -- (none once cancelled: every document of the run counts, the approval's and the cancellation's)
  select coalesce(sum(private.ledger_balance(la.id, '9999-12-31'::date, r.known_at)), 0)
  into v_receivable
  from public.ledger_account la
  where la.organization_id = r.organization_id and la.book = 'commission_receivable'
    and la.client_organization_id = r.client_organization_id and la.currency = r.currency;
  select coalesce(sum(private.ledger_balance(la.id, '9999-12-31'::date, r.known_at)), 0)
  into v_advances
  from public.ledger_account la
  where la.organization_id = r.organization_id and la.book = 'client_advance_receivable'
    and la.client_organization_id = r.client_organization_id and la.currency = r.currency;
  select coalesce(sum(i.ttc_minor), 0) into v_docs_ttc
  from public.commission_invoice i where i.run_id = r.id and (v_cancelled or i.reason <> 'run_cancelled');
  v_position := jsonb_build_object(
    'owed_before_minor', r.gross_minor::text,
    'owed_after_minor', case when v_cancelled then r.gross_minor else 0 end::text,
    'receivable_before_minor', v_receivable::text,
    'receivable_after_minor',
      (v_receivable + v_docs_ttc
       - case when v_cancelled then 0 else coalesce((r.settlement_plan ->> 'dc')::bigint, 0) end)::text,
    'advances_before_minor', v_advances::text,
    'advances_after_minor',
      (v_advances - case when v_cancelled then 0 else coalesce((r.settlement_plan ->> 'da')::bigint, 0) end)::text);

  -- the parties as the run's invoices froze them at approval (review figures#2), else as they stand
  select i.payload -> 'seller', i.payload -> 'buyer' into v_issuer, v_client
  from public.commission_invoice i where i.run_id = r.id and i.reason = 'commission'
  order by i.seq limit 1;

  v_payload := jsonb_build_object(
    'schema', case when v_fr4 then 2 else 1 end,
    'number', r.number,
    'issue_date', v_issue,
    'known_at', to_char(r.known_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'currency', r.currency,
    'exponent', v_exp,
    'status', r.status,
    'cancelled_on', case when v_cancelled then (r.cancelled_at at time zone 'Europe/Paris')::date end,
    -- N = 0: the settlement was posted at approval, nothing is transferred (review legal#5)
    'settled_on', case when r.status = 'booked' and r.transfer_id is null then r.booked_on end,
    'issuer', coalesce(v_issuer, private.invoice_party(r.organization_id)),
    'client', coalesce(v_client, private.invoice_party(r.client_organization_id)),
    'mandates', v_mandates,
    'service_period', jsonb_build_object('from', r.service_from, 'to', r.service_to),
    'totals', v_totals,
    'files', v_files,
    'natures', v_natures,
    'line_columns', private.remittance_statement_line_columns(),
    'lines', v_lines,
    'documents', v_docs,
    'earlier_settled', v_earlier,
    'payout', v_payout,
    'requested_execution_date', r.requested_execution_date,
    'previous_payouts', v_suivi,
    'not_remitted', jsonb_build_object('held', v_held, 'refunded', v_refunded),
    'position', v_position)
    || case when v_fr4 then jsonb_build_object('withheld_given_back', v_withheld) else '{}'::jsonb end
    || case when v_end is not null then jsonb_build_object('mandate_end', v_end) else '{}'::jsonb end
    || case when v_addr is not null then jsonb_build_object('addressees', v_addr) else '{}'::jsonb end;

  return v_payload;
end;
$$;

-- private.remittance_documents_record, redefined from 20261117120000_statement_suivi.sql (line 824; same signature and
-- settings: SECURITY DEFINER, search_path ''; its grants restated below). M2c-7d-3 (plan §6.2.8): a statement is
-- refused unless drawn by its payload's template — fr-4 for schema 2, fr-3 for schema 1 (review M2c-6b-2d round 1
-- SR-2's guard, per payload). Nothing else changes.
create or replace function private.remittance_documents_record(p_organization_id uuid, p_statement_template text,
                                                              p_invoice_template text, p_renderer_version text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bad text;
  v_s integer;
  v_i integer;
  v_need text;
begin
  -- review M2c-6b-2d round 1 (SR-2): this payload's « Suivi » (`previous_payouts`, line columns appended) is drawn by
  -- `releve-reversement-fr-3` alone; a worker of an older template (deployed after this migration) would store a
  -- statement with a false « Suivi » forever (stored statements are never drawn again). Refused inside the item's
  -- savepoint: the attempt is recorded failed and retried until the new worker draws it. Invoices are unaffected.
  -- (M2c-7d-3, plan §6.2.8) each payload by its own template: schema 2 by releve-reversement-fr-4 (an older worker
  -- would draw it without its « Fin du mandat », its addressee or its withheld row), schema 1 by releve-reversement-fr-3
  -- (its bytes kept)
  select x.need into v_need
  from (select case when s.payload ->> 'schema' = '2' then 'releve-reversement-fr-4'
                    else 'releve-reversement-fr-3' end as need
        from pg_temp._rd_statement s) x
  where x.need is distinct from p_statement_template
  limit 1;
  if v_need is not null then
    raise exception 'statements drawn by template %: this payload is drawn by % only', p_statement_template, v_need
      using errcode = 'check_violation';
  end if;
  select min(coalesce(s.run_id, f.run_id)::text) into v_bad
  from pg_temp._rd_statement s full join pg_temp._rd_statement_files f on f.run_id = s.run_id
  where s.run_id is null or f.run_id is null;
  if v_bad is not null then
    raise exception 'statement of run %: prepared and rendered statements differ', v_bad
      using errcode = 'check_violation';
  end if;

  drop table if exists pg_temp._rd_new_statement;
  create temp table _rd_new_statement on commit drop as
  select r.id as run_id, r.organization_id, r.client_organization_id, r.currency, r.number, r.known_at,
         (r.approved_at at time zone 'Europe/Paris')::date as issue_date, s.payload, s.payload_sha256, s.line_count,
         s.file_count, f.pdf_sha256, f.csv_sha256, gen_random_uuid() as pdf_id, gen_random_uuid() as csv_id,
         private.remittance_statement_path(r.organization_id, r.client_organization_id, r.number) as path
  from pg_temp._rd_statement s
  join pg_temp._rd_statement_files f on f.run_id = s.run_id
  cross join lateral (select x.* from public.remittance_run x where x.id = s.run_id offset 0) r
  where r.organization_id = p_organization_id;
  if (select count(*) from pg_temp._rd_new_statement) <> (select count(*) from pg_temp._rd_statement) then
    raise exception 'statements: a run of another servicer' using errcode = 'check_violation';
  end if;
  insert into public.document (id, organization_id, client_organization_id, kind, storage_bucket, storage_path, sha256,
                               mime_type, file_name)
  select n.pdf_id, n.organization_id, n.client_organization_id, 'remittance_statement_pdf', 'documents',
         n.path || '.pdf', n.pdf_sha256, 'application/pdf', n.number || '.pdf'
  from pg_temp._rd_new_statement n
  union all
  select n.csv_id, n.organization_id, n.client_organization_id, 'remittance_statement_csv', 'documents',
         n.path || '.csv', n.csv_sha256, 'text/csv', n.number || '.csv'
  from pg_temp._rd_new_statement n;
  insert into public.remittance_statement (run_id, organization_id, client_organization_id, currency, number,
                                           issue_date, known_at, line_count, file_count, gross_minor, net_minor,
                                           drawn_status, payload, payload_sha256, template_version, renderer_version,
                                           pdf_document_id, pdf_sha256, csv_document_id, csv_sha256)
  select n.run_id, n.organization_id, n.client_organization_id, n.currency, n.number, n.issue_date, n.known_at,
         n.line_count, n.file_count, (n.payload #>> '{totals,gross_minor}')::bigint,
         (n.payload #>> '{totals,net_minor}')::bigint, n.payload ->> 'status', n.payload, n.payload_sha256,
         p_statement_template, p_renderer_version, n.pdf_id, n.pdf_sha256, n.csv_id, n.csv_sha256
  from pg_temp._rd_new_statement n;
  get diagnostics v_s = row_count;

  drop table if exists pg_temp._rd_new_invoice;
  create temp table _rd_new_invoice on commit drop as
  select i.id as invoice_id, i.organization_id, i.client_organization_id, i.number, f.pdf_sha256,
         gen_random_uuid() as document_id,
         private.commission_invoice_path(i.organization_id, i.client_organization_id, i.year, i.number) as path,
         nullif(btrim(coalesce(i.payload #>> '{buyer,invoice_acceptance_ref}', '')), '') is not null as electronic
  from pg_temp._rd_invoice_pdf f
  cross join lateral (select x.* from public.commission_invoice x where x.id = f.invoice_id offset 0) i
  where i.organization_id = p_organization_id;
  if (select count(*) from pg_temp._rd_new_invoice) <> (select count(*) from pg_temp._rd_invoice_pdf) then
    raise exception 'invoice documents: an invoice of another servicer, or unknown' using errcode = 'check_violation';
  end if;
  insert into public.document (id, organization_id, client_organization_id, kind, storage_bucket, storage_path, sha256,
                               mime_type, file_name)
  select n.document_id, n.organization_id, n.client_organization_id, 'commission_invoice_pdf', 'documents', n.path,
         n.pdf_sha256, 'application/pdf', n.number || '.pdf'
  from pg_temp._rd_new_invoice n;
  insert into public.commission_invoice_document (invoice_id, organization_id, client_organization_id, document_id,
                                                  pdf_sha256, template_version, renderer_version, electronic)
  select n.invoice_id, n.organization_id, n.client_organization_id, n.document_id, n.pdf_sha256, p_invoice_template,
         p_renderer_version, n.electronic
  from pg_temp._rd_new_invoice n;
  get diagnostics v_i = row_count;

  delete from private.remittance_document_todo t
  where (t.kind = 'statement' and t.ref_id in (select n.run_id from pg_temp._rd_new_statement n))
     or (t.kind = 'invoice' and t.ref_id in (select n.invoice_id from pg_temp._rd_new_invoice n));
  delete from pg_temp._rd_statement;
  delete from pg_temp._rd_statement_files;
  delete from pg_temp._rd_invoice_pdf;
  return jsonb_build_object('statements', v_s, 'invoices', v_i,
                            'more', private.remittance_documents_due(p_organization_id));
end;
$$;

-- (M2c-7d-3; carried item 4) Where a withheld item (the reversal p_entry) went back to the client: the run holding its
-- live line, then — while that run is booked and its payout chain holds a return (a payout_returned booking of one of
-- its transfers: the return booking's entry, as private.transfer_line_post books it, the late predecessor's included)
-- — the run holding that return's payout_returned item in a live line, and so on (20 at most). One row: the last run
-- reached, its status, whether its own payout came back, and the run before it (whose payout came back). Keyed: each
-- live line by its entry (remittance_line_live_uq), each run by key, each chain's bookings by
-- bank_line_booking_transfer_idx.
create function private.withheld_given_back(p_entry uuid)
returns table (number text, status text, returned boolean, returned_by text)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  with recursive h (run_id, number, status, transfer_id, depth, back) as (
    select y.id, y.number, y.status, y.transfer_id, 0, null::text
    from (select l.run_id from public.remittance_line l
          where l.ledger_entry_id = p_entry and not l.released offset 0 limit 1) l
    cross join lateral (select q.id, q.number, q.status, q.transfer_id from public.remittance_run q
                        where q.id = l.run_id offset 0) y
    union all
    select y.id, y.number, y.status, y.transfer_id, h.depth + 1, h.number
    from h
    cross join lateral (select k.entry_id
                        from private.transfer_chain(h.transfer_id) c
                        cross join lateral (select q.entry_id, q.kind from public.bank_line_booking q
                                            where q.transfer_id = c.transfer_id offset 0) k
                        where k.kind = 'payout_returned'
                        limit 1) k
    cross join lateral (select l.run_id from public.remittance_line l
                        where l.ledger_entry_id = k.entry_id and not l.released and l.kind = 'payout_returned'
                        offset 0) l
    cross join lateral (select q.id, q.number, q.status, q.transfer_id from public.remittance_run q
                        where q.id = l.run_id offset 0) y
    where h.depth < 20 and h.status = 'booked')
  select h.number, h.status,
         h.status = 'booked' and exists (select 1 from private.transfer_chain(h.transfer_id) c
                                         cross join lateral (select q.kind from public.bank_line_booking q
                                                             where q.transfer_id = c.transfer_id offset 0) k
                                         where k.kind = 'payout_returned'),
         h.back
  from h
  order by h.depth desc
  limit 1;
$$;

-- public.remittance_run_withheld, redefined from 20261127090000_set_off_bars.sql (line 1373; same signature and
-- settings, its grants restated below). M2c-7d-3 (carried item 4; ADR-0014 « M2c-7d-2 review fixes », left open
-- withheld-given-back-after-return): the run giving W back is followed, once its payout came back, through the returned
-- payout's payout_returned item to the run that pays it again (as remittance_run_payout's repaid_by) — given_back_by
-- once that run is booked and its payout not returned, giving_back_by while it is approved or sent — and returned_by
-- names the last run whose payout came back on the way. Nothing else changes.
create or replace function public.remittance_run_withheld(p_run_id uuid)
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
           'giving_back_by', case when g.status in ('approved', 'sent') then g.number end,
           -- (M2c-7d-3; carried item 4) the run whose payout came back on the way: the last run named
           'returned_by', case when g.returned then g.number else g.returned_by end)
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
  -- (M2c-7d-3; carried item 4) the run giving W back, followed through each returned payout to the run that pays it
  -- again (private.withheld_given_back)
  left join lateral private.withheld_given_back(x.id) g on true;
$$;

------------------------------------------------------------------------------------------
-- Privileges (restated for every function redefined here; the new ones internal, or the callers')
------------------------------------------------------------------------------------------

-- the new helpers: internal (only the SECURITY DEFINER callers above use them)
revoke execute on function private.client_procedure_facts(uuid, date), private.client_documents_declared(uuid, date),
  private.client_claims_to_declare(uuid, date), private.client_post_opening_unpaid(uuid, date),
  private.client_payouts_after_liquidation(uuid, date), private.invoice_to_declare(uuid, uuid, date),
  private.statement_mandate_end(uuid, date, timestamptz), private.statement_addressees(uuid, date, timestamptz),
  private.withheld_given_back(uuid), private.liquidation_payout_disposition_guard(), private.set_off_outcome_guard(),
  private.client_event_known(uuid, timestamptz), private.settlement_set_off_alert(uuid, uuid, date, uuid, text),
  private.set_off_after_bar_rows(uuid, date), private.invoice_withheld_on(uuid),
  private.client_set_off_bar_recorded_on(uuid, date, text)
  from public, anon, authenticated, service_role;
-- the two commands: authenticated (admins at aal2, checked inside); never anon
revoke execute on function public.record_liquidation_payout_disposition(text, uuid, text, uuid, text),
  public.record_set_off_outcome(text, uuid, text, uuid, text) from public, anon;
grant execute on function public.record_liquidation_payout_disposition(text, uuid, text, uuid, text),
  public.record_set_off_outcome(text, uuid, text, uuid, text) to authenticated;

-- the redefined, as their latest migrations left them
-- (20261127090000) the advance checks: internal
revoke execute on function private.run_advance_checks(uuid, uuid, date, boolean)
  from public, anon, authenticated, service_role;
-- (20261121120000) the remittance runs' checks: internal
revoke execute on function private.run_remittance_runs_checks(uuid, uuid, date)
  from public, anon, authenticated, service_role;
-- (20261117120000) the statement's build and the record step: the documents job's
revoke execute on function private.remittance_statement_build(uuid) from public, anon, authenticated;
grant execute on function private.remittance_statement_build(uuid) to service_role;
revoke execute on function private.remittance_documents_record(uuid, text, text, text) from public, anon, authenticated;
grant execute on function private.remittance_documents_record(uuid, text, text, text) to service_role;
-- (20261127090000) the run page's withheld set-off: authenticated (money staff, checked inside); never anon
revoke execute on function public.remittance_run_withheld(uuid) from public, anon;
grant execute on function public.remittance_run_withheld(uuid) to authenticated;
