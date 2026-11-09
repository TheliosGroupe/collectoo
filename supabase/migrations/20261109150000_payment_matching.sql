-- M2b-3 (M2-08): reconciliation — which file (account) each payment pays.
-- Design: docs/design/m2b-payments.md §6 (payment_match, payer_account_link, account_hold), §7, §8.4 (rules
-- R1–R6 and gating), §9 (job payments.match; assign / accept / unassign), §12.2 (exception queue);
-- decisions: docs/adr/0013-payments-allocation-client-money.md (founder #3, #11, #12, #18; M2b-3 addendum).
-- Forward-only: nothing of 20261109090000 / 20261109120000 is edited; private.complete_batch_confirmation
-- is redefined (one line added: the rematch).
--
-- What changes for money: nothing is posted. Matching is a decision in the payment sub-ledger (design §0):
-- a payment gets its file and, when the payer named invoices, its designation; allocation (M2b-4) posts from
-- there. Every decision, by a rule (the worker's deterministic rules, collectoo_worker.payments.matching) or
-- by ops, is kept in payment_match (append-only). No model, no LLM decides a match (CLAUDE.md, GDPR art. 22).

------------------------------------------------------------------------------------------
-- Reference keys, and the indexes matching reads (design §6, last bullets)
------------------------------------------------------------------------------------------

-- An invoice or file reference as compared: ASCII letters and digits only, upper case.
-- Python twin: collectoo_worker.payments.matching.ref_key (parity test on random strings).
create or replace function private.ref_key(p text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select translate(regexp_replace(p, '[^0-9A-Za-z]', '', 'g'), 'abcdefghijklmnopqrstuvwxyz',
                   'ABCDEFGHIJKLMNOPQRSTUVWXYZ')
$$;

create index claim_item_ref_key_idx on public.claim_item (private.ref_key(ref));
create index account_ref_key_idx on public.account (organization_id, private.ref_key(external_ref));
create index party_display_name_trgm_idx on public.party using gin (display_name extensions.gin_trgm_ops);
create index payment_candidate_idx on public.payment (candidate_account_id) where candidate_account_id is not null;
-- A decision row names its payment within the payment's servicer.
alter table public.payment add constraint payment_org_key unique (id, organization_id);

------------------------------------------------------------------------------------------
-- Holds (minimal, DOMAIN §3.6; design §2 #17). M2b reads only surendettement and collective_proceeding:
-- an active one blocks allocation (C. conso L722-5, C. com. L622-7; founder #12). M4 adds the outbound
-- guardrails. Placed and lifted by admins and ops managers; evidence required for those two kinds
-- (founder 2026-11-07: hold only on proof).
------------------------------------------------------------------------------------------

create table public.account_hold (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  client_organization_id uuid not null,
  portfolio_id uuid not null,
  account_id uuid not null,
  kind text not null check (kind in ('dispute', 'surendettement', 'collective_proceeding', 'recalled', 'wrong_party')),
  legal_basis text check (length(btrim(legal_basis)) between 1 and 500),
  scope text[] not null check (cardinality(scope) > 0
                               and scope <@ array['outbound', 'payment_requests', 'accruals', 'enforcement']),
  evidence_document_id uuid references public.document (id),
  reason text not null check (length(btrim(reason)) between 1 and 2000),
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  end_reason text check (length(btrim(end_reason)) between 1 and 2000),
  decided_by uuid references public.app_user (id),
  ended_by uuid references public.app_user (id),
  created_at timestamptz not null default now(),
  constraint account_hold_account_fk foreign key (account_id, organization_id, client_organization_id, portfolio_id)
    references public.account (id, organization_id, client_organization_id, portfolio_id),
  constraint account_hold_evidence check (kind not in ('surendettement', 'collective_proceeding')
                                          or evidence_document_id is not null),
  constraint account_hold_end check ((ended_at is null) = (end_reason is null)
                                     and (ended_at is null or ended_at >= started_at))
);
create unique index account_hold_active_uq on public.account_hold (account_id, kind) where ended_at is null;
create index account_hold_portfolio_idx on public.account_hold (portfolio_id);
comment on table public.account_hold is
  'Holds on a file (DOMAIN §3.6). Active surendettement / collective_proceeding holds block allocation (M2b).';

-- A hold is on a confirmed file of the same servicer; once placed, only its end is written, once.
create or replace function private.account_hold_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.ended_at is not null or not exists (select 1 from public.account a
                                               where a.id = new.account_id and a.status <> 'staged') then
      raise exception 'account hold: the file is not confirmed, or the hold is already ended' using errcode = 'check_violation';
    end if;
    if new.evidence_document_id is not null and not exists (
         select 1 from public.document d
         where d.id = new.evidence_document_id and d.organization_id = new.organization_id
           and d.client_organization_id = new.client_organization_id
           and (d.account_id is null or d.account_id = new.account_id)) then
      raise exception 'account hold: the evidence is not a document of this file' using errcode = 'check_violation';
    end if;
    return new;
  end if;
  if (new.id, new.organization_id, new.client_organization_id, new.portfolio_id, new.account_id, new.kind,
      new.legal_basis, new.scope, new.evidence_document_id, new.reason, new.started_at, new.decided_by, new.created_at)
     is distinct from
     (old.id, old.organization_id, old.client_organization_id, old.portfolio_id, old.account_id, old.kind,
      old.legal_basis, old.scope, old.evidence_document_id, old.reason, old.started_at, old.decided_by, old.created_at)
     or old.ended_at is not null or new.ended_at is null then
    raise exception 'account hold %: only its end is written, once', old.id using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger account_hold_guard before insert or update on public.account_hold
  for each row execute function private.account_hold_guard();
alter table public.account_hold enable always trigger account_hold_guard;
create trigger account_hold_no_delete before delete or truncate on public.account_hold
  for each statement execute function private.refuse_delete();
alter table public.account_hold enable always trigger account_hold_no_delete;
create trigger account_hold_change_log after insert or update or delete on public.account_hold
  for each row execute function private.log_change();

------------------------------------------------------------------------------------------
-- Match decisions (append-only history) and the candidates shown to ops (derived, replaced each run)
------------------------------------------------------------------------------------------

create table public.payment_match (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  payment_id uuid not null,
  action text not null check (action in ('assign', 'unassign')),
  account_id uuid not null,                 -- the file assigned, or the file the payment left
  client_organization_id uuid not null,     -- of that file (RLS)
  portfolio_id uuid not null,
  method text not null check (method in ('rf_structured', 'rf_text', 'rf_body', 'item_ref', 'iban_memory', 'manual')),
  rule text check (rule in ('R1', 'R2', 'R3', 'R4')),
  rule_version text not null check (length(rule_version) between 1 and 40),
  trigger text not null check (trigger in ('import', 'rematch', 'ops')),
  evidence jsonb not null default '{}' check (jsonb_typeof(evidence) = 'object'),
  designation jsonb check (designation is null or jsonb_typeof(designation) = 'object'),
  review_reason text,                       -- what the gating said then (null: ready for allocation)
  iban_link boolean not null default false, -- this assignment taught the IBAN memory (undone on unassign)
  reason text check (length(btrim(reason)) between 1 and 2000),
  decided_by uuid references public.app_user (id),  -- null: a rule (the worker)
  decided_at timestamptz not null default now(),
  constraint payment_match_payment_fk foreign key (payment_id, organization_id)
    references public.payment (id, organization_id),
  constraint payment_match_account_fk foreign key (account_id, organization_id, client_organization_id, portfolio_id)
    references public.account (id, organization_id, client_organization_id, portfolio_id),
  -- a rule decides automatically (worker, no person); ops decide by hand, with their reason
  constraint payment_match_who check (
    (trigger = 'ops') = (method = 'manual')
    and (trigger = 'ops') = (decided_by is not null)
    and (trigger <> 'ops' or reason is not null)
    and (rule is not null) = (method <> 'manual')
    and (action = 'assign' or method = 'manual'))
);
create index payment_match_payment_idx on public.payment_match (payment_id, decided_at);
create index payment_match_portfolio_idx on public.payment_match (portfolio_id);
create index payment_match_account_idx on public.payment_match (account_id);
comment on table public.payment_match is
  'Every assignment of a payment to a file and every unassignment, by a rule (R1–R4) or by ops (append-only).';
create trigger payment_match_append_only before update or delete or truncate on public.payment_match
  for each statement execute function private.refuse_change();
alter table public.payment_match enable always trigger payment_match_append_only;

create table public.payment_match_candidate (
  payment_id uuid not null references public.payment (id),
  rank smallint not null check (rank between 1 and 3),
  organization_id uuid not null,
  account_id uuid not null references public.account (id) on delete cascade,  -- a rolled-back staged file
  rule text not null check (rule in ('R1', 'R2', 'R3', 'R4', 'R5', 'R6')),
  acceptable boolean not null default false,  -- one tap: the single best suggestion of a confirmed file
  signals jsonb not null default '{}' check (jsonb_typeof(signals) = 'object'),
  created_at timestamptz not null default now(),
  primary key (payment_id, rank),
  constraint payment_match_candidate_one_tap check (not acceptable or rank = 1)
);
create index payment_match_candidate_account_idx on public.payment_match_candidate (account_id);
comment on table public.payment_match_candidate is
  'Files proposed for a payment left to ops (up to 3, ranked, with the signals that ranked them). Replaced each run.';

-- IBAN memory (design R4): which files a payer's IBAN paid, by decisions that teach it (an RF, a cited number
-- that a second signal backed, ops). Internal: never exposed (third-party payer data). The IBAN is kept as the
-- worker reads it (no spaces, upper case); the worker checks its digits before it looks one up (a mod-97 check
-- per row here costs seconds at 50k).
create table private.payer_account_link (
  organization_id uuid not null references public.organization (id),
  payer_iban text not null check (payer_iban ~ '^[A-Z]{2}[0-9]{2}[0-9A-Z]{11,30}$'),
  account_id uuid not null references public.account (id),
  confirmed_count integer not null default 0 check (confirmed_count >= 0),
  first_seen date not null,
  last_seen date not null,
  updated_at timestamptz not null default now(),
  primary key (organization_id, payer_iban, account_id)
);
create index payer_account_link_account_idx on private.payer_account_link (account_id);

------------------------------------------------------------------------------------------
-- Recording assignments (rules and ops share it): gating, payment, history, IBAN memory
------------------------------------------------------------------------------------------

-- The assignments to record, in processing order (booking date, then statement line): the caller fills it.
create or replace function private.assign_begin()
returns void
language plpgsql
set search_path = ''
as $$
begin
  drop table if exists pg_temp._assign;
  create temp table _assign (
    ord bigint not null,
    payment_id uuid primary key,
    account_id uuid not null,
    method text not null,
    rule text,
    rule_version text not null,
    evidence jsonb not null default '{}',
    designation jsonb,
    teaches boolean not null default false,
    review_reason text
  ) on commit drop;
end;
$$;

-- Gating (design §8.4), first that applies: file not confirmed (waits for the rematch at confirmation,
-- founder #11), closed (a recalled file is forwarded by ops), other currency (1343-3, no conversion: #9),
-- booked before servicing started (#10), active surendettement / collective proceeding hold (#12),
-- nothing left to pay. "Left to pay" = Σ receivable of the file − payments already matched to it and not
-- allocated − earlier payments of this batch on the same file.
create or replace function private.gate_assignments()
returns void
language plpgsql
set search_path = ''
as $$
begin
  analyze pg_temp._assign;
  drop table if exists pg_temp._gate_file;
  create temp table _gate_file on commit drop as
  select f.account_id, f.status, f.currency, s.servicing_start, coalesce(h.n, 0) as holds,
         coalesce(b.balance, 0) as balance, coalesce(d.pending, 0) as pending
  from (select a.id as account_id, a.status, a.currency from public.account a
        where a.id in (select g.account_id from pg_temp._assign g)) f
  left join (select o.account_id, min(o.valid_from) as servicing_start from public.claim_ownership_period o
             where o.account_id in (select g.account_id from pg_temp._assign g) group by o.account_id) s using (account_id)
  left join (select h.account_id, count(*) as n from public.account_hold h
             where h.account_id in (select g.account_id from pg_temp._assign g) and h.ended_at is null
               and h.kind in ('surendettement', 'collective_proceeding')
             group by h.account_id) h using (account_id)
  left join (select la.account_id, sum(lp.amount_minor) as balance
             from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
             where la.account_id in (select g.account_id from pg_temp._assign g) and la.book = 'debtor_receivable'
             group by la.account_id) b using (account_id)
  left join (select p.account_id, sum(p.amount_minor) as pending from public.payment p
             where p.account_id in (select g.account_id from pg_temp._assign g) and p.status = 'matched'
               and p.id not in (select g.payment_id from pg_temp._assign g)
             group by p.account_id) d using (account_id);
  analyze pg_temp._gate_file;

  update pg_temp._assign g set review_reason = case
      when f.status = 'staged' then 'account_not_confirmed'
      when f.status in ('closed_paid', 'closed_settled', 'closed_uncollectable', 'closed_recalled') then 'account_closed'
      when p.currency <> f.currency then 'currency_mismatch'
      when f.servicing_start is null or p.booking_date < f.servicing_start then 'before_servicing_start'
      when f.holds > 0 then 'hold_blocks_allocation'
    end
  from pg_temp._gate_file f, public.payment p
  where f.account_id = g.account_id and p.id = g.payment_id;

  update pg_temp._assign g set review_reason = 'nothing_due'
  from (select x.payment_id,
               f.balance - f.pending - coalesce(sum(p.amount_minor) over (
                 partition by x.account_id order by x.ord rows between unbounded preceding and 1 preceding), 0) as due
        from pg_temp._assign x
        join pg_temp._gate_file f on f.account_id = x.account_id
        join public.payment p on p.id = x.payment_id
        where x.review_reason is null) y
  where g.payment_id = y.payment_id and y.due <= 0;
end;
$$;

-- Records pg_temp._assign: gates each assignment, sets the payment, writes its payment_match row (none for a
-- file not confirmed: it waits), teaches the IBAN memory, drops the old candidates. Returns the count per
-- review reason ("ready" when none).
create or replace function private.record_assignments(p_organization_id uuid, p_trigger text, p_decided_by uuid,
                                                      p_reason text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v jsonb;
begin
  perform private.gate_assignments();

  update public.payment p set
    account_id = case when g.review_reason = 'account_not_confirmed' then null else g.account_id end,
    status = case when g.review_reason = 'account_not_confirmed' then 'unmatched' else 'matched' end,
    match_method = case when g.review_reason = 'account_not_confirmed' then null else g.method end,
    matched_at = case when g.review_reason = 'account_not_confirmed' then null else now() end,
    designation = case when g.review_reason = 'account_not_confirmed' then null else g.designation end,
    review_reason = g.review_reason,
    candidate_account_id = case when g.review_reason = 'account_not_confirmed' then g.account_id end
  from pg_temp._assign g
  where p.id = g.payment_id and p.organization_id = p_organization_id;

  drop table if exists pg_temp._assign_iban;
  create temp table _assign_iban on commit drop as
  select x.payment_id, x.account_id, x.teaches, x.booking_date,
         case when x.iban ~ '^[A-Z]{2}[0-9]{2}[0-9A-Z]{11,30}$' then x.iban end as iban
  from (select g.payment_id, g.account_id, g.teaches, p.booking_date, private.rf_normalise(p.payer_iban) as iban
        from pg_temp._assign g join public.payment p on p.id = g.payment_id
        where g.review_reason is distinct from 'account_not_confirmed' and p.payer_iban is not null) x;

  insert into public.payment_match (organization_id, payment_id, action, account_id, client_organization_id,
                                    portfolio_id, method, rule, rule_version, trigger, evidence, designation,
                                    review_reason, iban_link, reason, decided_by)
  select p_organization_id, g.payment_id, 'assign', g.account_id, a.client_organization_id, a.portfolio_id, g.method,
         g.rule, g.rule_version, p_trigger, g.evidence, g.designation, g.review_reason,
         coalesce(i.teaches and i.iban is not null, false), p_reason, p_decided_by
  from pg_temp._assign g
  join public.account a on a.id = g.account_id
  left join pg_temp._assign_iban i on i.payment_id = g.payment_id
  where g.review_reason is distinct from 'account_not_confirmed'
  order by g.ord;

  insert into private.payer_account_link as l (organization_id, payer_iban, account_id, confirmed_count, first_seen,
                                               last_seen)
  select p_organization_id, i.iban, i.account_id, count(*) filter (where i.teaches), min(i.booking_date),
         max(i.booking_date)
  from pg_temp._assign_iban i where i.iban is not null
  group by i.iban, i.account_id
  on conflict (organization_id, payer_iban, account_id) do update
    set confirmed_count = l.confirmed_count + excluded.confirmed_count,
        last_seen = greatest(l.last_seen, excluded.last_seen), updated_at = now();

  delete from public.payment_match_candidate c using pg_temp._assign g where c.payment_id = g.payment_id;

  select coalesce(jsonb_object_agg(r, n), '{}') into v
  from (select coalesce(g.review_reason, 'ready') as r, count(*) as n from pg_temp._assign g group by 1) x;
  return v;
end;
$$;

------------------------------------------------------------------------------------------
-- The match job (worker): decisions computed by collectoo_worker.payments.matching, applied set-based
------------------------------------------------------------------------------------------

-- The worker fills pg_temp._mr_decision (one row per payment it decided) and pg_temp._mr_candidate.
create or replace function private.match_results_begin()
returns void
language plpgsql
set search_path = ''
as $$
begin
  drop table if exists pg_temp._mr_decision;
  create temp table _mr_decision (
    payment_id uuid primary key,
    ord bigint not null,
    outcome text not null check (outcome in ('auto', 'suggestion', 'ambiguous', 'none')),
    rule text not null check (rule in ('R1', 'R2', 'R3', 'R4', 'R5', 'R6')),
    method text,
    account_id uuid,
    rule_version text not null,
    designation jsonb,
    evidence jsonb not null,
    teaches boolean not null default false,
    review_reason text,
    candidate_account_id uuid,
    check ((outcome = 'auto') = (account_id is not null and method is not null))
  ) on commit drop;
  drop table if exists pg_temp._mr_candidate;
  create temp table _mr_candidate (
    payment_id uuid not null,
    rank smallint not null,
    account_id uuid not null,
    rule text not null,
    acceptable boolean not null,
    signals jsonb not null,
    primary key (payment_id, rank)
  ) on commit drop;
end;
$$;

-- Applies the worker's decisions to the payments still waiting (ops may have decided meanwhile): automatic
-- matches are recorded and gated; the others stay unmatched, in the queue with their reason and candidates.
create or replace function private.apply_match_results(p_organization_id uuid, p_trigger text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_gates jsonb;
  v_queue jsonb;
begin
  if p_trigger not in ('import', 'rematch', 'ops') then
    raise exception 'match: unknown trigger %', p_trigger using errcode = '22023';
  end if;
  analyze pg_temp._mr_decision;
  drop table if exists pg_temp._mr;
  create temp table _mr on commit drop as
  select d.* from pg_temp._mr_decision d
  join public.payment p on p.id = d.payment_id
  where p.organization_id = p_organization_id and p.status = 'unmatched' and p.account_id is null;
  analyze pg_temp._mr;

  perform private.assign_begin();
  insert into pg_temp._assign (ord, payment_id, account_id, method, rule, rule_version, evidence, designation, teaches)
  select m.ord, m.payment_id, m.account_id, m.method, m.rule, m.rule_version, m.evidence, m.designation, m.teaches
  from pg_temp._mr m join public.account a on a.id = m.account_id and a.organization_id = p_organization_id
  where m.outcome = 'auto';
  v_gates := private.record_assignments(p_organization_id, p_trigger, null, null);

  update public.payment p
  set review_reason = m.review_reason, candidate_account_id = c.id
  from pg_temp._mr m
  left join public.account c on c.id = m.candidate_account_id and c.organization_id = p_organization_id
  where p.id = m.payment_id and m.outcome <> 'auto'
    and (p.review_reason, p.candidate_account_id) is distinct from (m.review_reason, c.id);
  delete from public.payment_match_candidate c using pg_temp._mr m where c.payment_id = m.payment_id;
  insert into public.payment_match_candidate (payment_id, rank, organization_id, account_id, rule, acceptable, signals)
  select c.payment_id, c.rank, p_organization_id, c.account_id, c.rule, c.acceptable, c.signals
  from pg_temp._mr_candidate c
  join pg_temp._mr m on m.payment_id = c.payment_id and m.outcome <> 'auto'
  join public.account a on a.id = c.account_id and a.organization_id = p_organization_id;

  select coalesce(jsonb_object_agg(r, n), '{}') into v_queue
  from (select m.review_reason as r, count(*) as n from pg_temp._mr m where m.outcome <> 'auto' group by 1) x;
  return jsonb_build_object('decided', (select count(*) from pg_temp._mr), 'automatic', v_gates, 'queue', v_queue);
end;
$$;

------------------------------------------------------------------------------------------
-- Confirmation: the payments waiting for a file are matched again (founder #11). A rolled-back file: the
-- payments that waited for it need the client's ratification or a refund (no_mandate, 1342-2).
------------------------------------------------------------------------------------------

create or replace function private.complete_batch_confirmation(p_batch_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.boarding_batch;
begin
  select * into v from public.boarding_batch where id = p_batch_id for update;
  if not found or v.status <> 'confirming' then
    return 'skipped';
  end if;
  if not private.has_active_mandate(v.portfolio_id, private.paris_today()) then
    update public.boarding_batch
    set failed_job = jsonb_build_object('type', 'confirm', 'error', 'mandate_inactive', 'at', now())
    where id = p_batch_id and coalesce(failed_job ->> 'type', '') not in ('documents', 'purge_documents');
    perform private.transition_batch(p_batch_id, 'committed', 'mandat inactif (CPCE R124-3)', 'worker:boarding');
    return 'mandate_inactive';
  end if;
  perform private.post_opening_balances(p_batch_id);
  update public.account set status = 'awaiting_first_letter'
  where boarding_batch_id = p_batch_id and status = 'staged';
  perform private.issue_payment_references(p_batch_id);  -- M2-06: one RF reference per workable account
  -- M2-08: payments left to ops (waiting for these files, or unmatched) are matched again (founder #11).
  perform pgmq.send('payments', jsonb_build_object('type', 'match', 'organization_id', v.organization_id,
                                                   'trigger', 'rematch', 'batch_id', p_batch_id));
  perform private.transition_batch(p_batch_id, 'confirmed', 'confirmed', 'worker:boarding');
  return 'confirmed';
end;
$$;

create or replace function private.account_deleted_payments()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  update public.payment p
  set review_reason = case when p.review_reason = 'account_not_confirmed' then 'no_mandate' else p.review_reason end,
      candidate_account_id = case when p.review_reason = 'account_not_confirmed' then p.candidate_account_id end
  from old_rows o
  where p.candidate_account_id = o.id and p.account_id is null;
  return null;
end;
$$;
create trigger account_deleted_payments after delete on public.account
  referencing old table as old_rows for each statement execute function private.account_deleted_payments();
alter table public.account enable always trigger account_deleted_payments;

------------------------------------------------------------------------------------------
-- Commands (admins and ops managers at aal2, decision #18): idempotency key + request hash; each takes
-- milliseconds. A payment the match job holds makes them wait at most 2 s, then fail (« réessayez »).
------------------------------------------------------------------------------------------

-- Assign a payment to a confirmed file. One file per payment for now: splitting a payment across files
-- comes with allocation (M2b-4), where its amounts matter.
create or replace function public.assign_payment(p_idempotency_key text, p_payment_id uuid, p_splits jsonb,
                                                 p_designation jsonb, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  p public.payment;
  a public.account;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb;
  v_result jsonb;
  v_account uuid;
  v_items uuid[];
  v_source text;
  v_doc uuid;
  v_designation jsonb;
  v_suggested jsonb;
begin
  select * into p from public.payment where id = p_payment_id for update;
  if not found or not private.has_role(p.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('payment_id', p_payment_id, 'splits', p_splits, 'designation', p_designation,
                                  'reason', v_reason);
  v_result := private.command_replay('assign_payment', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if p.status <> 'unmatched' or p.account_id is not null then
    raise exception 'the payment is already matched: unassign it first' using errcode = 'check_violation';
  end if;
  if jsonb_typeof(p_splits) is distinct from 'array' or jsonb_array_length(p_splits) <> 1
     or jsonb_typeof(p_splits -> 0) <> 'object' or (p_splits -> 0) ? 'amount_text'
     or coalesce(p_splits -> 0 ->> 'account_id', '') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'one file for the whole payment (splitting comes with allocation)' using errcode = 'check_violation';
  end if;
  v_account := (p_splits -> 0 ->> 'account_id')::uuid;
  select * into a from public.account where id = v_account;
  if not found or a.organization_id <> p.organization_id then
    raise exception 'unknown file' using errcode = 'check_violation';
  end if;
  if a.status = 'staged' then
    raise exception 'the file is not confirmed yet' using errcode = 'check_violation';
  end if;
  if p_designation is not null then
    -- The debtor's own indication « lorsqu'il paie » (1342-10): invoices of this file only.
    v_source := p_designation ->> 'source';
    if jsonb_typeof(p_designation -> 'item_ids') is distinct from 'array'
       or v_source is null or v_source not in ('remittance_text', 'document', 'portal') then
      raise exception 'invalid designation' using errcode = 'check_violation';
    end if;
    select array_agg(distinct x.v::uuid) into v_items
    from jsonb_array_elements_text(p_designation -> 'item_ids') x (v)
    where x.v ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
    if coalesce(cardinality(v_items), 0) = 0 or cardinality(v_items) <> jsonb_array_length(p_designation -> 'item_ids')
       or (select count(*) from public.claim_item i where i.account_id = a.id and i.id = any (v_items))
          <> cardinality(v_items) then
      raise exception 'invalid designation: invoices of this file only' using errcode = 'check_violation';
    end if;
    if v_source = 'document' then
      v_doc := nullif(p_designation ->> 'evidence_document_id', '')::uuid;
      if v_doc is null or not exists (select 1 from public.document d where d.id = v_doc
                                        and d.organization_id = a.organization_id
                                        and d.client_organization_id = a.client_organization_id) then
        raise exception 'invalid designation: the document is required' using errcode = 'check_violation';
      end if;
    end if;
    v_designation := jsonb_build_object('item_ids', to_jsonb(v_items), 'source', v_source,
                                        'evidence_document_id', v_doc, 'captured_at', now());
  end if;
  -- what ops saw proposed, kept with the decision
  select jsonb_agg(jsonb_build_object('rank', c.rank, 'account_id', c.account_id, 'rule', c.rule) order by c.rank)
  into v_suggested from public.payment_match_candidate c where c.payment_id = p.id;
  perform private.assign_begin();
  insert into pg_temp._assign (ord, payment_id, account_id, method, rule, rule_version, evidence, designation, teaches)
  values (1, p.id, a.id, 'manual', null, 'ops',
          jsonb_strip_nulls(jsonb_build_object('suggested', v_suggested)), v_designation, true);
  perform private.record_assignments(p.organization_id, 'ops', auth.uid(), v_reason);
  select jsonb_build_object('payment_id', x.id, 'account_id', a.id, 'review_reason', x.review_reason)
  into v_result from public.payment x where x.id = p.id;
  perform private.command_record('assign_payment', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- Accept the single best suggestion of up to 200 payments of one servicer (bulk on desktop). A payment
-- that is not waiting any more, or has no one-tap suggestion, is skipped and said so.
create or replace function public.accept_suggestions(p_idempotency_key text, p_payment_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  v_ids uuid[];
  v_org uuid;
  v_orgs bigint;
  v_found bigint;
  v_request jsonb;
  v_result jsonb;
begin
  select array_agg(distinct x order by x) into v_ids from unnest(p_payment_ids) x where x is not null;
  if coalesce(cardinality(v_ids), 0) not between 1 and 200 then
    raise exception 'between 1 and 200 payments' using errcode = 'check_violation';
  end if;
  select count(distinct p.organization_id), min(p.organization_id::text)::uuid, count(*)
  into v_orgs, v_org, v_found from public.payment p where p.id = any (v_ids);
  if v_found <> cardinality(v_ids) or v_orgs <> 1 or not private.has_role(v_org, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('payment_ids', to_jsonb(v_ids));
  v_result := private.command_replay('accept_suggestions', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  perform 1 from public.payment p where p.id = any (v_ids) order by p.id for update;

  perform private.assign_begin();
  insert into pg_temp._assign (ord, payment_id, account_id, method, rule, rule_version, evidence, designation, teaches)
  select row_number() over (order by p.booking_date, p.created_at, p.id), p.id, c.account_id, 'manual', null, 'ops',
         jsonb_build_object('accepted', jsonb_build_object('rule', c.rule, 'signals', c.signals)),
         case when jsonb_typeof(c.signals -> 'designation') = 'array' and jsonb_array_length(c.signals -> 'designation') > 0
              then jsonb_build_object('item_ids', c.signals -> 'designation', 'source', 'remittance_text',
                                      'captured_at', now()) end,
         true
  from public.payment p
  join public.payment_match_candidate c on c.payment_id = p.id and c.rank = 1 and c.acceptable
  join public.account a on a.id = c.account_id and a.organization_id = p.organization_id and a.status <> 'staged'
  where p.id = any (v_ids) and p.status = 'unmatched' and p.account_id is null and p.review_reason = 'no_match';
  -- a designation names invoices of the accepted file only
  update pg_temp._assign g set designation = null
  where g.designation is not null
    and (select count(*) from public.claim_item i
         where i.account_id = g.account_id
           and i.id::text in (select jsonb_array_elements_text(g.designation -> 'item_ids')))
        <> jsonb_array_length(g.designation -> 'item_ids');
  perform private.record_assignments(v_org, 'ops', auth.uid(), 'suggestion acceptée');

  select jsonb_build_object(
    'accepted', (select count(*) from pg_temp._assign),
    'skipped', coalesce((select jsonb_agg(jsonb_build_object('payment_id', x, 'reason',
                          case when p.status = 'unmatched' then 'no_suggestion' else 'not_waiting' end) order by x)
                         from unnest(v_ids) x join public.payment p on p.id = x
                         where x not in (select g.payment_id from pg_temp._assign g)), '[]'))
  into v_result;
  perform private.command_record('accept_suggestions', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- Take a payment off its file (nothing allocated yet). It goes back to the queue; the rules then only
-- suggest for it, never the file it left; an IBAN this assignment taught is forgotten.
create or replace function public.unassign_payment(p_idempotency_key text, p_payment_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  p public.payment;
  a public.account;
  last public.payment_match;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb;
  v_result jsonb;
  v_iban text;
  v_moved bigint;
begin
  select * into p from public.payment where id = p_payment_id for update;
  if not found or not private.has_role(p.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('payment_id', p_payment_id, 'reason', v_reason);
  v_result := private.command_replay('unassign_payment', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if p.account_id is null then
    raise exception 'the payment is not matched' using errcode = 'check_violation';
  end if;
  -- Nothing allocated, forwarded or returned: the payment's entries net to zero on 4710 (and its status says so).
  select coalesce(sum(lp.amount_minor), 0) into v_moved
  from public.ledger_entry e
  join public.ledger_posting lp on lp.entry_id = e.id
  join public.ledger_account la on la.id = lp.ledger_account_id and la.book = 'unallocated_payment'
  where e.payment_id = p.id;
  if p.status <> 'matched' or v_moved <> 0 then
    raise exception 'money of this payment is allocated: reverse the allocation first' using errcode = 'check_violation';
  end if;
  select * into a from public.account where id = p.account_id;
  select * into last from public.payment_match m
  where m.payment_id = p.id and m.action = 'assign' and m.account_id = p.account_id
  order by m.decided_at desc, m.id desc limit 1;

  update public.payment
  set account_id = null, status = 'unmatched', match_method = null, matched_at = null, designation = null,
      review_reason = 'no_match', candidate_account_id = null
  where id = p.id;
  insert into public.payment_match (organization_id, payment_id, action, account_id, client_organization_id,
                                    portfolio_id, method, rule, rule_version, trigger, evidence, reason, decided_by)
  values (p.organization_id, p.id, 'unassign', a.id, a.client_organization_id, a.portfolio_id, 'manual', null, 'ops',
          'ops', jsonb_build_object('undoes', last.id), v_reason, auth.uid());
  if coalesce(last.iban_link, false) then
    v_iban := private.rf_normalise(p.payer_iban);
    update private.payer_account_link
    set confirmed_count = greatest(confirmed_count - 1, 0), updated_at = now()
    where organization_id = p.organization_id and payer_iban = v_iban and account_id = a.id;
  end if;
  delete from public.payment_match_candidate where payment_id = p.id;
  perform private.regate_account(a.id);  -- the file's other payments may find something left to pay
  -- fresh suggestions for ops (never this file again)
  perform pgmq.send('payments', jsonb_build_object('type', 'match', 'organization_id', p.organization_id,
                                                   'trigger', 'ops', 'payment_ids', jsonb_build_array(p.id)));
  v_result := jsonb_build_object('payment_id', p.id, 'unassigned_from', a.id);
  perform private.command_record('unassign_payment', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- Payments matched to a file and not allocated yet are gated again when one of its holds changes.
create or replace function private.regate_account(p_account_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform private.assign_begin();
  insert into pg_temp._assign (ord, payment_id, account_id, method, rule_version)
  select row_number() over (order by p.booking_date, p.created_at, p.id), p.id, p.account_id, p.match_method, 'regate'
  from public.payment p where p.account_id = p_account_id and p.status = 'matched';
  perform private.gate_assignments();
  update public.payment p set review_reason = g.review_reason
  from pg_temp._assign g
  where p.id = g.payment_id and p.review_reason is distinct from g.review_reason;
end;
$$;

create or replace function public.place_account_hold(p_idempotency_key text, p_account_id uuid, p_kind text,
                                                     p_legal_basis text, p_evidence_document_id uuid, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  a public.account;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb;
  v_result jsonb;
  v_id uuid;
begin
  select * into a from public.account where id = p_account_id for update;
  if not found or not private.has_role(a.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('account_id', p_account_id, 'kind', p_kind, 'legal_basis', p_legal_basis,
                                  'evidence_document_id', p_evidence_document_id, 'reason', v_reason);
  v_result := private.command_replay('place_account_hold', p_idempotency_key, v_request);
  if v_result is not null then
    return (v_result ->> 'hold_id')::uuid;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if p_kind is null or p_kind not in ('dispute', 'surendettement', 'collective_proceeding', 'recalled', 'wrong_party') then
    raise exception 'unknown hold kind' using errcode = 'check_violation';
  end if;
  if p_kind in ('surendettement', 'collective_proceeding') and p_evidence_document_id is null then
    raise exception 'evidence is required for this hold' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.account_hold h where h.account_id = a.id and h.kind = p_kind and h.ended_at is null) then
    raise exception 'the file already has this hold' using errcode = 'check_violation';
  end if;
  insert into public.account_hold (organization_id, client_organization_id, portfolio_id, account_id, kind, legal_basis,
                                   scope, evidence_document_id, reason, decided_by)
  values (a.organization_id, a.client_organization_id, a.portfolio_id, a.id, p_kind, nullif(btrim(p_legal_basis), ''),
          case p_kind when 'surendettement' then array['outbound', 'payment_requests']
                      when 'collective_proceeding' then array['outbound', 'payment_requests', 'accruals']
                      else array['outbound'] end,
          p_evidence_document_id, v_reason, auth.uid())
  returning id into v_id;
  perform private.regate_account(a.id);
  perform private.command_record('place_account_hold', p_idempotency_key, v_request, jsonb_build_object('hold_id', v_id));
  return v_id;
end;
$$;

create or replace function public.lift_account_hold(p_idempotency_key text, p_hold_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  h public.account_hold;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb := jsonb_build_object('hold_id', p_hold_id, 'reason', btrim(coalesce(p_reason, '')));
begin
  select * into h from public.account_hold where id = p_hold_id for update;
  if not found or not private.has_role(h.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if private.command_replay('lift_account_hold', p_idempotency_key, v_request) is not null then
    return;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if h.ended_at is not null then
    raise exception 'the hold is already lifted' using errcode = 'check_violation';
  end if;
  update public.account_hold set ended_at = now(), end_reason = v_reason, ended_by = auth.uid() where id = h.id;
  perform private.regate_account(h.account_id);
  perform private.command_record('lift_account_hold', p_idempotency_key, v_request, jsonb_build_object('lifted', true));
end;
$$;

------------------------------------------------------------------------------------------
-- Reads for the back-office (money staff; bounded, milliseconds)
------------------------------------------------------------------------------------------

-- What the queue shows of proposed files: reference, client, debtor, what is left to pay (as text), RF.
create or replace function public.match_queue_accounts(p_account_ids uuid[])
returns table (account_id uuid, external_ref text, status text, client_name text, debtor_name text, currency char(3),
               balance_minor text, pending_minor text, rf text)
language sql
stable
security definer
set search_path = ''
as $$
  select a.id, a.external_ref, a.status, c.legal_name,
         (select min(pa.display_name) from public.account_party ap join public.party pa on pa.id = ap.party_id
          where ap.account_id = a.id and ap.role = 'borrower'),
         a.currency,
         coalesce((select sum(lp.amount_minor) from public.ledger_account la
                   join public.ledger_posting lp on lp.ledger_account_id = la.id
                   where la.account_id = a.id and la.book = 'debtor_receivable'), 0)::text,
         coalesce((select sum(p.amount_minor) from public.payment p where p.account_id = a.id and p.status = 'matched'), 0)::text,
         (select r.rf from public.payment_reference r where r.account_id = a.id and r.status = 'active')
  from public.account a
  join public.organization c on c.id = a.client_organization_id
  where a.id = any (p_account_ids[1:100])
    and a.organization_id = any (private.money_staff_org_ids());
$$;

-- Files ops may assign a payment to: by file, invoice or RF reference, else by debtor name (trigram).
create or replace function public.search_payment_files(p_payment_id uuid, p_query text)
returns table (account_id uuid, external_ref text, status text, client_name text, debtor_name text, currency char(3),
               balance_minor text, pending_minor text, rf text, found_by text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_org uuid;
  v_key text := private.ref_key(coalesce(p_query, ''));
  v_rf text := private.rf_normalise(coalesce(p_query, ''));
begin
  select p.organization_id into v_org from public.payment p
  where p.id = p_payment_id and p.organization_id = any (private.money_staff_org_ids());
  if v_org is null or length(btrim(coalesce(p_query, ''))) < 3 then
    return;
  end if;
  return query
  with hits as (
    select a.id, 'reference'::text as found_by, 1 as rank_ from public.account a
    where a.organization_id = v_org and private.ref_key(a.external_ref) = v_key
    union all
    select i.account_id, 'invoice', 2 from public.claim_item i
    join public.account a on a.id = i.account_id and a.organization_id = v_org
    where private.ref_key(i.ref) = v_key
    union all
    select r.account_id, 'rf', 0 from public.payment_reference r where r.organization_id = v_org and r.rf = v_rf
    union all
    select x.account_id, 'name', 3 from (
      select ap.account_id, max(extensions.similarity(pa.display_name, p_query)) as sim
      from public.party pa join public.account_party ap on ap.party_id = pa.id
      where pa.organization_id = v_org and pa.display_name operator(extensions.%) p_query
      group by ap.account_id order by sim desc limit 10) x
  ), best as (
    select h.id, min(h.rank_) as rank_, (array_agg(h.found_by order by h.rank_))[1] as found_by
    from hits h group by h.id order by min(h.rank_) limit 10
  )
  select q.account_id, q.external_ref, q.status, q.client_name, q.debtor_name, q.currency, q.balance_minor,
         q.pending_minor, q.rf, b.found_by
  from best b
  join public.match_queue_accounts(array[b.id]) q on q.account_id = b.id
  where q.status <> 'staged'
  order by b.rank_, q.external_ref;
end;
$$;

-- The exception queue (design §12.2), oldest first: payments without a file or held for a reason; or, tab
-- 'rapproches', the matched payments ready for allocation, latest first. The client is the file's, else the
-- candidate file's. Amounts as text; the payer's IBAN by its end only (design R10). Security invoker: RLS
-- applies (admins and ops managers read every payment of their servicer).
create or replace function public.payment_queue(p_tab text default 'a-traiter', p_reason text default null,
                                                p_client uuid default null, p_min_minor bigint default null,
                                                p_max_minor bigint default null, p_min_days integer default null,
                                                p_offset integer default 0, p_limit integer default 20)
returns table (payment_id uuid, amount_minor text, currency char(3), booking_date date, age_days integer,
               payer_name text, payer_iban_end text, remittance_text text, creditor_reference text, status text,
               review_reason text, match_method text, matched_at timestamptz, account_id uuid,
               candidate_account_id uuid, client_organization_id uuid, total bigint)
language sql
stable
set search_path = ''
as $$
  with q as (
    select p.*, coalesce(p.client_organization_id, c.client_organization_id) as client_id
    from public.payment p
    left join public.account c on c.id = p.candidate_account_id
    where case when p_tab = 'rapproches' then p.status = 'matched' and p.review_reason is null
               else p.status = 'unmatched' or p.review_reason is not null end
      and (p_reason is null or p.review_reason = p_reason or (p_reason = 'waiting' and p.review_reason is null))
      and (p_min_minor is null or p.amount_minor >= p_min_minor)
      and (p_max_minor is null or p.amount_minor <= p_max_minor)
      and (p_min_days is null or p.booking_date <= (now() at time zone 'Europe/Paris')::date - p_min_days)
  )
  select q.id, q.amount_minor::text, q.currency, q.booking_date,
         ((now() at time zone 'Europe/Paris')::date - q.booking_date)::integer, q.payer_name, right(q.payer_iban, 4),
         q.remittance_text, q.creditor_reference, q.status, q.review_reason, q.match_method, q.matched_at, q.account_id,
         q.candidate_account_id, q.client_id, count(*) over ()
  from q
  where p_client is null or q.client_id = p_client
  order by case when p_tab = 'rapproches' then q.matched_at end desc nulls last, q.booking_date, q.id
  offset greatest(coalesce(p_offset, 0), 0) limit least(greatest(coalesce(p_limit, 20), 1), 100);
$$;

-- Per statement: payments, matched by a rule, left to ops, not tried yet (the match job is queued) (security
-- invoker: RLS applies).
create or replace function public.statement_match_counts(p_statement_ids uuid[])
returns table (statement_id uuid, payments bigint, automatic bigint, to_review bigint, waiting bigint)
language sql
stable
set search_path = ''
as $$
  select t.statement_id, count(*),
         count(*) filter (where p.match_method in ('rf_structured', 'rf_text', 'rf_body', 'item_ref', 'iban_memory')),
         count(*) filter (where p.review_reason is not null),
         count(*) filter (where p.status = 'unmatched' and p.review_reason is null)
  from public.bank_transaction t
  join public.payment p on p.bank_transaction_id = t.id
  where t.statement_id = any (p_statement_ids[1:50])
  group by t.statement_id;
$$;

------------------------------------------------------------------------------------------
-- Read access (decision #18): payments and their decisions are staff data; collectors read the decisions
-- of the payments of their portfolios; clients see no bank line, decision or candidate.
------------------------------------------------------------------------------------------

alter table public.account_hold enable row level security;
alter table public.payment_match enable row level security;
alter table public.payment_match_candidate enable row level security;
alter table private.payer_account_link enable row level security;
revoke all on public.account_hold, public.payment_match, public.payment_match_candidate from public, anon, authenticated;
revoke all on private.payer_account_link from public, anon, authenticated;
grant select on public.account_hold, public.payment_match, public.payment_match_candidate to authenticated;

-- Holds: whoever reads the portfolio (clients included: they decide on recalls and are told of holds).
create policy account_hold_read on public.account_hold for select to authenticated
  using (portfolio_id = any ((select private.readable_portfolio_ids())::uuid[]));
-- Decisions: admins and ops managers; a collector those of a payment now in one of its portfolios.
create policy payment_match_read on public.payment_match for select to authenticated using (
  organization_id = any ((select private.money_staff_org_ids())::uuid[])
  or (portfolio_id = any ((select private.readable_portfolio_ids())::uuid[])
      and organization_id = any ((select private.staff_org_ids())::uuid[])
      and exists (select 1 from public.payment p
                  where p.id = payment_match.payment_id and p.portfolio_id = payment_match.portfolio_id)));
-- Candidates are proposals for unmatched payments (third-party payer data): admins and ops managers.
create policy payment_match_candidate_read on public.payment_match_candidate for select to authenticated
  using (organization_id = any ((select private.money_staff_org_ids())::uuid[]));

------------------------------------------------------------------------------------------
-- Privileges
------------------------------------------------------------------------------------------

revoke execute on function private.ref_key(text), private.account_hold_guard(), private.assign_begin(),
  private.gate_assignments(), private.record_assignments(uuid, text, uuid, text), private.match_results_begin(),
  private.apply_match_results(uuid, text), private.account_deleted_payments(), private.regate_account(uuid)
  from public, anon, authenticated, service_role;
-- The worker (service_role) runs the match job: it reads reference keys and writes its decisions.
grant execute on function private.ref_key(text), private.match_results_begin(), private.apply_match_results(uuid, text)
  to service_role;
grant select on private.payer_account_link to service_role;
revoke execute on function public.assign_payment(text, uuid, jsonb, jsonb, text),
  public.accept_suggestions(text, uuid[]), public.unassign_payment(text, uuid, text),
  public.place_account_hold(text, uuid, text, text, uuid, text), public.lift_account_hold(text, uuid, text),
  public.match_queue_accounts(uuid[]), public.search_payment_files(uuid, text), public.statement_match_counts(uuid[]),
  public.payment_queue(text, text, uuid, bigint, bigint, integer, integer, integer)
  from public, anon;
grant execute on function public.assign_payment(text, uuid, jsonb, jsonb, text),
  public.accept_suggestions(text, uuid[]), public.unassign_payment(text, uuid, text),
  public.place_account_hold(text, uuid, text, text, uuid, text), public.lift_account_hold(text, uuid, text),
  public.match_queue_accounts(uuid[]), public.search_payment_files(uuid, text), public.statement_match_counts(uuid[]),
  public.payment_queue(text, text, uuid, bigint, bigint, integer, integer, integer)
  to authenticated;
