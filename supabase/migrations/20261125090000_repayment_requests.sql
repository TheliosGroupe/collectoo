-- M2c-7c-2 « repayment requests » (plan docs/design/m2c-7-plan.md §0 #5, §1.3 D1, §2, §5.1, §5.2.7, §5.2.8, §5.3, §5.4,
-- §5.6; design docs/design/m2c-remittances.md §7.3, §13 #5; ADR-0014 « M2c-7c-2 »). Forward-only.
--
-- « Demande de remboursement d'avance »: a letter, not an invoice (no VAT), asking a client to repay advances of the
-- servicer that no claw-back clause recovers. A request moves no money; the client's repayment is 7c-1's « Règlement du
-- client ». The command (public.request_advance_repayment, admins and ops managers at aal2) takes the advances of one
-- client and currency, under the locks approvals take, and refuses, per advance in this order: not open (not_open), in
-- an approved or sent run's plan (in_flight), born before the client's proceeding opened (before_opening), in another
-- request of the last 30 days (recently_requested: a reminder after 30 days is a new request), under a claw-back clause
-- in force today ([critic] M7-MONEY-3, L7: clawback_applies — the next run takes it; asking the client too would make it
-- pay twice), not received by the client ([critic] M7-MONEY-8, L5; [check 1]: payout_not_received exactly while
-- private.entry_remitted(E).paid_on is null — a payout come back and not paid again; an N = 0 run or a run whose
-- returned payout a later run paid is requestable; (beyond the plan) an overrun whose run's payout came back); then the
-- total the sheet showed (total_changed), the own account (no_own_account), the servicer's billing identity
-- (identity_incomplete) and ([critic] L12) a death, guardianship, liquidation or mandate end of the client
-- (recipient_unknown: 7c-2 sends nothing then; 7d-1 narrows it). The request (DRA-AAAA-NNNNNN, unique, not gapless) freezes
-- its payload (private.advance_repayment_payload: canonical jsonb, amounts as text, no payer data) and its items, and
-- queues the letter's job ({type: repayment_request} on `remittances`): the worker draws the deterministic PDF
-- (demande-remboursement-avance-fr-1), stores it at repayment-requests/<servicer>/<request>.pdf and records its document
-- once (private.repayment_request_document_done, the stored bytes' hash). « Retirer la demande »
-- (public.withdraw_advance_repayment_request) sets the withdrawal once (no expiry: founder Q20); the advance can then be
-- clawed back or requested anew. [critic] M7-MONEY-3: an advance an item of a request not withdrawn names is requested —
-- the worker's prepare reads it (private.client_requested_advances) and leaves it to its request; the approval re-checks
-- it (private.remittance_approval_refusal: documents_changed). The nightly (private.run_advance_checks): advance_open says
-- when an advance was last requested (requested_on), repayment_request_document_missing alerts a letter not drawn one hour
-- after its request. [critic] F11: the PDF, as the request's rows, is read by money staff and the client's whole-client
-- members (the remittance documents' rule: document_remittance_scope, remittance_document_object_read), never by another
-- tenant, a portfolio-restricted member or a collector.
-- The carried default (ADR-0014 « M2c-7a review fixes » Left open): an advance whose item reads not received — a
-- collection an unplanned payout paid only in part, in a run whose own payout came back — is not requested
-- (payout_not_received; founder question Q22 asks whether a run's set-off should be shared out over its items).
--
-- New: the tables public.advance_repayment_request and public.advance_repayment_request_item (RLS, change log, the
-- request's guard: append-only but for its document and its withdrawal, each set once), the sequence of their numbers;
-- private.advance_live_request, private.client_requested_advances (the worker's prepare), private.advance_payout_not_received,
-- private.advance_repayment_refusal, private.advance_reversal_origin, private.advance_repayment_row,
-- private.advance_repayment_payload, private.repayment_request_job and private.repayment_request_document_done (the
-- worker's); public.advance_repayment_preview (the sheet's total and refusals), public.request_advance_repayment,
-- public.withdraw_advance_repayment_request, public.client_repayment_requests (« Ce que le client doit au cabinet », the
-- client space).
-- Redefined, each copied whole from its latest definition across every migration file (indexed: the last
-- `create or replace function` of each name wins, checked against the live definition; the change only; settings,
-- search_path '' and SECURITY DEFINER where they were, grants restated): private.remittance_approval_refusal
-- (20261114090000:688), private.run_advance_checks (20261124090000:2281, 7c-1's), private.advance_row
-- (20261123090000:387: « Demandé le »), private.can_read_remittance_document_object (20261113090000:1552) with the
-- policies remittance_document_object_read and document_remittance_scope (20261113090000:1565, :1569). Not redefined:
-- public.register_client_document and private.can_read_client_document(_object) — the letter is a document the worker
-- draws, read under the remittance documents' rule, not a client document staff register (ADR « Deviations »).
-- Review fixes round 1 (ADR-0014 « M2c-7c-2 review fixes »): also redefined, whole, the change only —
-- private.transfer_line_check (20261123090000:889) and private.remitted_cover_release (20261122090000:614): a return
-- that would release an advance a request not withdrawn names is refused advance_requested (MONEY-1);
-- public.client_payment_line (20261124090000:1722) and public.book_client_payment_line (20261124090000:2046): a
-- dedicated-account line whose label names the client's DRA-… number designates that request's advances (MONEY-2; new
-- private.label_requested_advances); remittance_approval_refusal gains `set enable_seqscan = off` (CC-3). The
-- withdrawal says which other request still names its advances (UI-1); a request withdrawn before its letter was drawn
-- gets no letter and no alert (NIGHT-1, CC-1); the withdrawal's motif and the staff's ids are not readable over the API
-- (TUI-3, CC-2: column privileges).
-- The cancellation-after-download switch stays off: nothing here writes private.feature_switch.

------------------------------------------------------------------------------------------
-- The request and its items (plan §5.1)
------------------------------------------------------------------------------------------

-- DRA-AAAA-NNNNNN: unique, not gapless (design §3.2 #4), the run numbers' mechanism
create sequence private.advance_repayment_request_number_seq;
revoke all on sequence private.advance_repayment_request_number_seq from public, anon, authenticated;

-- A « Demande de remboursement d'avance »: one client, one currency, its total (Σ its items' open parts when it was
-- made), its payload frozen (what the letter states; amounts as text, no payer data) and its hash, the template; the
-- letter's document once drawn (document, pdf_sha256, renderer_version, set together, once); its withdrawal (at, by,
-- reason, set together, once). Append-only but for those two.
create table public.advance_repayment_request (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  currency char(3) not null references public.currency (code),
  number text not null check (number ~ '^DRA-[0-9]{4}-[0-9]{6,}$'),
  issue_date date not null,
  total_minor bigint not null check (total_minor > 0 and total_minor <= 1000000000000000),
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),
  payload_sha256 text not null check (payload_sha256 ~ '^[0-9a-f]{64}$'),
  template_version text not null check (template_version = 'demande-remboursement-avance-fr-1'),
  renderer_version text check (length(renderer_version) between 1 and 200),
  document_id uuid references public.document (id),
  pdf_sha256 text check (pdf_sha256 ~ '^[0-9a-f]{64}$'),
  issued_by uuid not null,
  created_at timestamptz not null default clock_timestamp(),
  withdrawn_at timestamptz,
  withdrawn_by uuid,
  withdrawal_reason text check (length(btrim(withdrawal_reason)) between 1 and 2000),
  constraint advance_repayment_request_number_uq unique (organization_id, number),
  constraint advance_repayment_request_drawn check (num_nonnulls(document_id, pdf_sha256, renderer_version) in (0, 3)),
  constraint advance_repayment_request_withdrawn
    check (num_nonnulls(withdrawn_at, withdrawn_by, withdrawal_reason) in (0, 3))
);
-- a client's requests (the pages), the servicer's letters not drawn yet of requests not withdrawn (the nightly:
-- document_id is null and withdrawn_at is null — (review round 1, NIGHT-1) a request withdrawn before its letter was
-- drawn gets none). The latter partial on those two literal predicates, which the nightly's read states literally:
-- implied whatever its parameters (never a parameter's filter the planner would have to prove implies it, the class
-- that broke main after 7a), it holds only the letters still to draw, so no other index of the servicer (its numbers'
-- advance_repayment_request_number_uq, priced at one row when the servicer's key is analysed as unique) is cheaper
create index advance_repayment_request_client_idx on public.advance_repayment_request (client_organization_id, created_at);
create index advance_repayment_request_undrawn_idx on public.advance_repayment_request (organization_id, created_at)
  where document_id is null and withdrawn_at is null;
comment on table public.advance_repayment_request is
  'A « Demande de remboursement d''avance » (DRA-…; not an invoice; moves no money): its frozen payload and total, its '
  'letter''s document once drawn, its withdrawal. Append-only but for those, each set once.';

-- The advances a request names, each with its open part when the request was made. An advance is requested while an
-- item of a request not withdrawn names it and it is open. Append-only.
create table public.advance_repayment_request_item (
  request_id uuid not null references public.advance_repayment_request (id),
  advance_id uuid not null references public.client_advance (id),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  open_minor bigint not null check (open_minor > 0 and open_minor <= 1000000000000000),
  primary key (request_id, advance_id)
);
create index advance_repayment_request_item_advance_idx on public.advance_repayment_request_item (advance_id);
comment on table public.advance_repayment_request_item is
  'An advance a repayment request names, with its open part then. Append-only.';

-- The request's guard: no delete; an update sets, once, the document (with its hash and renderer) or the withdrawal
-- (with who and why) — every other column as it was
create or replace function private.advance_repayment_request_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_set constant text[] := array['document_id', 'pdf_sha256', 'renderer_version', 'withdrawn_at', 'withdrawn_by',
                                 'withdrawal_reason'];
begin
  if tg_op <> 'UPDATE' then
    raise exception '% on % refused: these rows are facts (append-only)', tg_op, tg_table_name
      using errcode = 'check_violation';
  end if;
  if (to_jsonb(new) - v_set) is distinct from (to_jsonb(old) - v_set)
     or (old.document_id is not null and (new.document_id, new.pdf_sha256, new.renderer_version)
                                         is distinct from (old.document_id, old.pdf_sha256, old.renderer_version))
     or (old.withdrawn_at is not null and (new.withdrawn_at, new.withdrawn_by, new.withdrawal_reason)
                                          is distinct from (old.withdrawn_at, old.withdrawn_by, old.withdrawal_reason)) then
    raise exception 'repayment request: only its document and its withdrawal are set, each once'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger advance_repayment_request_guard before update or delete on public.advance_repayment_request
  for each row execute function private.advance_repayment_request_guard();
alter table public.advance_repayment_request enable always trigger advance_repayment_request_guard;
create trigger advance_repayment_request_no_truncate before truncate on public.advance_repayment_request
  for each statement execute function private.refuse_change();
alter table public.advance_repayment_request enable always trigger advance_repayment_request_no_truncate;
create trigger advance_repayment_request_change_log after insert or update or delete on public.advance_repayment_request
  for each row execute function private.log_change();
create trigger advance_repayment_request_item_append_only before update or delete or truncate
  on public.advance_repayment_request_item for each statement execute function private.refuse_change();
alter table public.advance_repayment_request_item enable always trigger advance_repayment_request_item_append_only;
create trigger advance_repayment_request_item_change_log after insert or update or delete
  on public.advance_repayment_request_item for each row execute function private.log_change('request_id', 'advance_id');

-- RLS ([critic] F18; §5.1): money staff of the servicer; the client's members with access to the whole client read their
-- own requests (design §6.2's rule for client documents, OQ-48); collectors, portfolio-restricted members and other
-- tenants none. Written only by the SECURITY DEFINER commands and the worker. (Review round 1, TUI-3, CC-2) Over the API,
-- the request's columns but the withdrawal's motif and who issued or withdrew it (ops' internal note, the staff's user
-- ids: never the client's to read, §2.1); the service role reads every column, the pages read through their functions.
alter table public.advance_repayment_request enable row level security;
alter table public.advance_repayment_request_item enable row level security;
revoke all on public.advance_repayment_request, public.advance_repayment_request_item from public, anon, authenticated;
grant select (id, organization_id, client_organization_id, currency, number, issue_date, total_minor, payload,
              payload_sha256, template_version, renderer_version, document_id, pdf_sha256, created_at, withdrawn_at)
  on public.advance_repayment_request to authenticated;
grant select on public.advance_repayment_request to service_role;
grant select on public.advance_repayment_request_item to authenticated, service_role;
create policy advance_repayment_request_read on public.advance_repayment_request for select to authenticated using (
  organization_id = any ((select private.money_staff_org_ids())::uuid[])
  or client_organization_id = any ((select private.client_whole_org_ids())::uuid[]));
create policy advance_repayment_request_item_read on public.advance_repayment_request_item for select to authenticated
  using (organization_id = any ((select private.money_staff_org_ids())::uuid[])
         or client_organization_id = any ((select private.client_whole_org_ids())::uuid[]));

------------------------------------------------------------------------------------------
-- What is requested, and what may be (plan §5.2.7)
------------------------------------------------------------------------------------------

-- The latest request not withdrawn that names the advance (its id, number, issue date), none otherwise. Keyed: the
-- advance's items by advance_repayment_request_item_advance_idx, each request by its key.
create or replace function private.advance_live_request(p_advance_id uuid)
returns table (request_id uuid, number text, issue_date date)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select q.id, q.number, q.issue_date
  from (select i.request_id from public.advance_repayment_request_item i where i.advance_id = p_advance_id offset 0) i
  cross join lateral (select r.id, r.number, r.issue_date, r.created_at, r.withdrawn_at
                      from public.advance_repayment_request r where r.id = i.request_id offset 0) q
  where q.withdrawn_at is null
  order by q.issue_date desc, q.created_at desc
  limit 1;
$$;

-- [critic] M7-MONEY-3 (the worker's prepare, jobs/remittances.py _open_advances): the client's open advances in a
-- currency that a request not withdrawn names — the plan leaves each to its request (never set off: `run._plan`)
create or replace function private.client_requested_advances(p_client_organization_id uuid, p_currency char(3))
returns table (advance_id uuid, request_number text, issue_date date)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select a.advance_id, r.number, r.issue_date
  from private.client_open_advances(p_client_organization_id, p_currency) a
  cross join lateral private.advance_live_request(a.advance_id) r;
$$;

-- [critic] M7-MONEY-8, L5; [check 1]: whether the client has not received what the advance covers — for a remitted
-- reversal's cover, its collection E remitted in a booked run whose `paid_on` is null (private.entry_remitted: a payout
-- come back and not paid again, an unplanned payout that had paid it come back, or — the carried default — an item an
-- unplanned payout paid only in part in a run whose own payout came back); (beyond the plan) for an overrun, its run's
-- payout come back and not paid again (private.run_settled_on: no row). The run's number and what came back
-- (« <RV-…>:run » or « <RV-…>:unplanned »), null when received. Keyed reads only.
create or replace function private.advance_payout_not_received(p_advance_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select case
    when a.cause = 'remitted_reversal' then
      (select x.run_number || ':' || coalesce(x.returned_via, 'run')
       from (select z.reverses_entry_id from public.ledger_entry z where z.id = a.cause_entry_id offset 0) z
       cross join lateral private.entry_remitted(z.reverses_entry_id, a.cause_entry_id) x
       where x.paid_on is null
       limit 1)
    when a.cause = 'payout_overrun' and a.transfer_id is not null then
      (select r.number || ':run'
       from (select t.run_id from public.bank_transfer t where t.id = a.transfer_id offset 0) t
       cross join lateral (select q.id, q.number, q.status from public.remittance_run q where q.id = t.run_id offset 0) r
       where r.status = 'booked' and not exists (select 1 from private.run_settled_on(r.id)))
  end
  from (select q.cause, q.cause_entry_id, q.transfer_id from public.client_advance q where q.id = p_advance_id offset 0) a;
$$;

-- Why an advance may not be requested of client p_client in p_currency on p_today (code, detail), in the plan's order;
-- no row when it may: not_open (unknown, another client's or currency's, nothing open); in_flight (an approved or sent
-- run's plan takes it: the run's number); before_opening (born before the client's proceeding opened:
-- private.document_before_opening, L622-7 I; a liquidation alone opens it, L641-3 al. 1); recently_requested (a request
-- not withdrawn issued less than 30 days ago: its day); clawback_applies (its mandate's terms in force that day hold a
-- claw-back clause and set-off is not barred — the next run takes it: the clause); payout_not_received (the run, and
-- what came back).
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

-- Why no request may be sent to the client (the client's and the servicer's, whatever the advances): no own account in
-- the currency, the servicer's billing identity incomplete (R123-237/238), ([critic] L12) an event after which 7c-2
-- sends nothing — a death, a guardianship, a liquidation or a mandate end in effect (7d-1 names who receives then)
create or replace function private.advance_repayment_client_refusal(p_organization_id uuid, p_client_organization_id uuid,
                                                                    p_currency char(3), p_today date)
returns text
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select case
    when not exists (select 1 from public.servicer_billing_settings s
                     join public.bank_account b on b.id = s.own_bank_account_id
                     where s.organization_id = p_organization_id and b.purpose = 'own' and b.status = 'active'
                       and b.currency = p_currency) then 'no_own_account'
    when cardinality(private.billing_identity_gaps(p_organization_id)) > 0 then 'identity_incomplete'
    when exists (select 1 from public.client_status_event e
                 where e.client_organization_id = p_client_organization_id and e.effective_date <= p_today
                   and e.kind in ('death', 'guardianship', 'liquidation', 'mandate_ended')) then 'recipient_unknown'
  end;
$$;

------------------------------------------------------------------------------------------
-- The letter's payload (plan §5.3): what it states, frozen in the request
------------------------------------------------------------------------------------------

-- The origin of a remitted reversal's cover, each date a recording date and the facts in their order ([critic] L3,
-- M7-MONEY-9): the collection (its payment's booking date, its file), the run that remitted it and how and when the
-- client received it (private.entry_remitted: paid_how, paid_on, paid_run_number, returned_via; for a cover of what
-- unplanned payouts paid of a collection no booked run holds, « unplanned » on the latest attributing booking's date), the
-- reversal (a bank return: the return line's booking date, and its amount when the bank took back part of the payment;
-- « Désimputer »: its recording date; else its recording date) and whether it was recorded while the run was in flight
-- (the cover posted at the booking: adv:<R>:<run>). Never a payer's name or IBAN, never an RMT, SWP or TOP id.
create or replace function private.advance_reversal_origin(p_reversal_id uuid, p_cover_entry_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select jsonb_build_object(
    'collected_on', pay.booking_date,
    'file_ref', acc.external_ref,
    'run_number', x.run_number,
    'paid_how', coalesce(x.paid_how, case when x.run_id is null then 'unplanned' end),
    'paid_on', coalesce(x.paid_on, case when x.run_id is null then f.payout_on end),
    'paid_run_number', x.paid_run_number,
    'returned_via', x.returned_via,
    'reversal', case when r.idempotency_key like 'unalloc:%' then 'unallocated'
                     when bl.booking_date is not null then 'bank_return' else 'other' end,
    'reversed_on', coalesce(bl.booking_date, (r.posted_at at time zone 'Europe/Paris')::date),
    'returned_minor', case when bl.amount_minor < pay.amount_minor then bl.amount_minor::text end,
    'reversed_minor', coalesce(x.amount_minor, f.target)::text,
    'in_flight', coalesce(ce.idempotency_key = 'adv:' || p_reversal_id || ':' || x.run_id, false))
  from (select q.id, q.reverses_entry_id, q.idempotency_key, q.posted_at from public.ledger_entry q
        where q.id = p_reversal_id offset 0) r
  cross join lateral (select e.id, e.payment_id, e.account_id from public.ledger_entry e
                      where e.id = r.reverses_entry_id offset 0) e
  cross join lateral (select q.idempotency_key from public.ledger_entry q where q.id = p_cover_entry_id offset 0) ce
  left join lateral (select p.booking_date, p.amount_minor from public.payment p where p.id = e.payment_id offset 0) pay
    on true
  left join lateral (select a.external_ref from public.account a where a.id = e.account_id offset 0) acc on true
  left join lateral (select y.run_id, y.run_number, y.amount_minor, y.paid_on, y.paid_how, y.paid_run_number,
                            y.returned_via
                     from private.entry_remitted(e.id, r.id) y limit 1) x on true
  left join lateral (select g.payout_on, g.target from private.remitted_cover_fact(r.id) g
                     where x.run_id is null limit 1) f on true
  left join lateral (select b.booking_date, b.amount_minor from public.bank_transaction b
                     where r.idempotency_key like 'return:%'
                       and b.id = case when split_part(r.idempotency_key, ':', 2)
                                            ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                                       then split_part(r.idempotency_key, ':', 2)::uuid end
                     offset 0) bl on true;
$$;

-- One row of the letter: the advance's recording date (Paris), its mandate's reference (none: the letter says
-- « plusieurs mandats » for a payout of several mandates, « — » otherwise), its cause, what was paid beyond what was owed
-- (its amount), what it repaid already (compensations and payments: never what was passed as a loss — LEX-28, nothing
-- of a write-off is told to the client), what is asked (its open part) and its origin's facts
create or replace function private.advance_repayment_row(p_advance_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select jsonb_build_object(
    'advance_id', a.id,
    'recorded_on', (a.created_at at time zone 'Europe/Paris')::date,
    'mandate', m.reference,
    'cause', a.cause,
    'amount_minor', a.amount_minor::text,
    'repaid_minor', coalesce(s.repaid, 0)::text,
    'open_minor', private.advance_open(a.id)::text,
    'origin', case a.cause
                when 'remitted_reversal' then private.advance_reversal_origin(a.cause_entry_id, a.entry_id)
                when 'payout_overrun' then jsonb_build_object('run_number', tr.number, 'paid_on', bl.booking_date)
                else jsonb_build_object('executed_on', bl.booking_date, 'run_number', tr.number) end)
  from (select q.* from public.client_advance q where q.id = p_advance_id offset 0) a
  left join lateral (select q.reference from public.mandate q where q.id = a.mandate_id offset 0) m on true
  left join lateral (select sum(z.amount_minor) filter (where z.kind in ('compensation', 'payment_own',
                                                                           'payment_dedicated')) as repaid
                     from public.commission_settlement z
                     where z.document_id = a.id and z.document_kind = 'advance') s on true
  left join lateral (select x.number
                     from (select t.run_id from public.bank_transfer t where t.id = a.transfer_id offset 0) t
                     cross join lateral (select q.number from public.remittance_run q where q.id = t.run_id offset 0) x)
    tr on true
  left join lateral (select b.booking_date from public.bank_transaction b where b.id = a.bank_transaction_id offset 0) bl
    on true;
$$;

-- The letter's payload (plan §5.3; canonical jsonb, amounts as text, no payer data): the template, number, issue date and
-- currency; the issuer (the servicer's billing identity: R123-237/238, private.receipt_issuer); the recipient (the
-- client's name and billing address, else its registered office); the own account to repay to (holder, IBAN, BIC); the
-- total; the rows (private.advance_repayment_row), by recording then id. 7d-1 redefines it (the addressees).
create or replace function private.advance_repayment_payload(p_request public.advance_repayment_request,
                                                             p_advance_ids uuid[])
returns jsonb
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select jsonb_build_object(
    'template', p_request.template_version,
    'number', p_request.number,
    'issue_date', p_request.issue_date,
    'currency', p_request.currency,
    'issuer', private.receipt_issuer(p_request.organization_id),
    'recipient', (select jsonb_build_object('name', o.legal_name,
                                            'address', coalesce(b.billing_address, b.registered_office))
                  from public.organization o left join public.billing_identity b on b.organization_id = o.id
                  where o.id = p_request.client_organization_id),
    'own_account', (select jsonb_build_object('holder', o.legal_name, 'iban', ba.iban, 'bic', ba.bic)
                    from public.servicer_billing_settings s
                    join public.bank_account ba on ba.id = s.own_bank_account_id
                    join public.organization o on o.id = s.organization_id
                    where s.organization_id = p_request.organization_id),
    'total_minor', p_request.total_minor::text,
    'rows', (select coalesce(jsonb_agg(private.advance_repayment_row(x.id) order by x.created_at, x.id), '[]')
             from (select q.id, q.created_at from public.client_advance q where q.id = any (p_advance_ids)) x));
$$;

------------------------------------------------------------------------------------------
-- « Demander le remboursement », its preview, « Retirer la demande » (plan §5.2.7)
------------------------------------------------------------------------------------------

-- The sheet's preview: the total of the advances (their open parts, from the ledger: the command compares it) and why
-- each, or the client, may not be requested (the command's codes and details). Money staff of the servicer (aal2).
create or replace function public.advance_repayment_preview(p_client_organization_id uuid, p_currency char(3),
                                                           p_advance_ids uuid[])
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  c public.organization;
  v_today date := private.paris_today();
begin
  select * into c from public.organization where id = p_client_organization_id and kind <> 'servicer';
  if not found or c.servicer_organization_id is null
     or not private.has_role(c.servicer_organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if p_advance_ids is null or cardinality(p_advance_ids) > 200 then
    raise exception 'repayment request refused: bad_request' using errcode = 'check_violation';
  end if;
  return jsonb_build_object(
    'total_minor', (select coalesce(sum(o.open_minor), 0)::text
                    from (select distinct x from unnest(p_advance_ids) x) x
                    cross join lateral (select q.client_organization_id, q.currency from public.client_advance q
                                        where q.id = x.x offset 0) q
                    cross join lateral (select private.advance_open(x.x) as open_minor) o
                    where q.client_organization_id = c.id and q.currency = p_currency),
    -- each advance's open part only when it is this client's in this currency (never another client's amount)
    'rows', (select coalesce(jsonb_agg(jsonb_build_object(
                      'advance_id', x.x,
                      'open_minor', (case when q.client_organization_id = c.id and q.currency = p_currency
                                          then coalesce(private.advance_open(x.x), 0) else 0 end)::text,
                      'refusal', w.code, 'detail', w.detail) order by x.n), '[]')
             from unnest(p_advance_ids) with ordinality x (x, n)
             left join lateral (select q.client_organization_id, q.currency from public.client_advance q
                                where q.id = x.x offset 0) q on true
             left join lateral private.advance_repayment_refusal(x.x, c.id, p_currency, v_today) w on true),
    'refusal', private.advance_repayment_client_refusal(c.servicer_organization_id, c.id, p_currency, v_today));
end;
$$;

-- 5.2.7 « Demander le remboursement » (design §7.3, §13 #5): admins and ops managers of the client's servicer at aal2;
-- replay and request hash; the advances of one client and currency (1–200, none twice, none null) and the total the
-- sheet showed (minor units). Under the locks approvals take (the plans of approved runs, a request a prepare or an
-- approval reads: private.remittance_command_locks(org, true)); each advance's refusal in order
-- (private.advance_repayment_refusal), then total_changed, then the client's (no_own_account, identity_incomplete,
-- recipient_unknown). Inserts the request (DRA-AAAA-NNNNNN, dated today in Paris; its payload frozen and hashed) and its
-- items, and queues the letter's job. Moves no money. Returns {request_id, number}.
create or replace function public.request_advance_repayment(p_idempotency_key text, p_client_organization_id uuid,
                                                           p_currency char(3), p_advance_ids uuid[],
                                                           p_expected_total_text text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
set enable_seqscan = off
as $$
declare
  c public.organization;
  v_request jsonb;
  v_result jsonb;
  v_today date;
  v_a uuid;
  v_why record;
  v_total bigint;
  v_client text;
  v_req public.advance_repayment_request;
begin
  select * into c from public.organization where id = p_client_organization_id and kind <> 'servicer';
  if not found or c.servicer_organization_id is null
     or not private.has_role(c.servicer_organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('client_organization_id', p_client_organization_id, 'currency', p_currency,
                                  'advance_ids', p_advance_ids, 'expected_total', p_expected_total_text);
  v_result := private.command_replay('request_advance_repayment', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if p_advance_ids is null or cardinality(p_advance_ids) not between 1 and 200
     or array_position(p_advance_ids, null) is not null
     or cardinality(p_advance_ids) <> (select count(distinct x) from unnest(p_advance_ids) x)
     or p_expected_total_text is null or p_expected_total_text !~ '^[0-9]{1,16}$' or p_currency is null then
    raise exception 'repayment request refused: bad_request' using errcode = 'check_violation';
  end if;
  perform private.remittance_command_locks(c.servicer_organization_id, true);
  v_today := private.paris_today();
  foreach v_a in array p_advance_ids loop
    select w.code, w.detail into v_why from private.advance_repayment_refusal(v_a, c.id, p_currency, v_today) w limit 1;
    if v_why.code is not null then
      raise exception 'repayment request refused: %', v_why.code using errcode = 'check_violation',
        detail = coalesce(v_why.detail, '');
    end if;
  end loop;
  v_total := (select sum(private.advance_open(x)) from unnest(p_advance_ids) x);
  if v_total <> p_expected_total_text::bigint then
    raise exception 'repayment request refused: total_changed' using errcode = 'check_violation';
  end if;
  v_client := private.advance_repayment_client_refusal(c.servicer_organization_id, c.id, p_currency, v_today);
  if v_client is not null then
    raise exception 'repayment request refused: %', v_client using errcode = 'check_violation';
  end if;
  v_req.id := gen_random_uuid();
  v_req.organization_id := c.servicer_organization_id;
  v_req.client_organization_id := c.id;
  v_req.currency := p_currency;
  v_req.number := 'DRA-' || to_char(v_today, 'YYYY') || '-'
                  || lpad(nextval('private.advance_repayment_request_number_seq')::text, 6, '0');
  v_req.issue_date := v_today;
  v_req.total_minor := v_total;
  v_req.template_version := 'demande-remboursement-avance-fr-1';
  v_req.issued_by := auth.uid();
  v_req.payload := private.advance_repayment_payload(v_req, p_advance_ids);
  v_req.payload_sha256 := encode(sha256(convert_to(v_req.payload::text, 'UTF8')), 'hex');
  insert into public.advance_repayment_request (id, organization_id, client_organization_id, currency, number,
                                                issue_date, total_minor, payload, payload_sha256, template_version,
                                                issued_by)
  values (v_req.id, v_req.organization_id, v_req.client_organization_id, v_req.currency, v_req.number,
          v_req.issue_date, v_req.total_minor, v_req.payload, v_req.payload_sha256, v_req.template_version,
          v_req.issued_by);
  insert into public.advance_repayment_request_item (request_id, advance_id, organization_id, client_organization_id,
                                                     open_minor)
  select v_req.id, x, v_req.organization_id, c.id, private.advance_open(x) from unnest(p_advance_ids) x;
  perform pgmq.send('remittances', jsonb_build_object('type', 'repayment_request', 'request_id', v_req.id,
                                                      'organization_id', v_req.organization_id));
  v_result := jsonb_build_object('request_id', v_req.id, 'number', v_req.number);
  perform private.command_record('request_advance_repayment', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- [critic] « Retirer la demande »: admins and ops managers of the request's servicer at aal2, with a motif (1–2,000
-- characters, staff only); sets the withdrawal once (already_withdrawn); its advances can then be clawed back again or
-- requested anew — but (review round 1, UI-1) those another request not withdrawn names stay requested (a reminder
-- withdrawn leaves the first request): `still_requested_by`, the numbers of the other requests not withdrawn that name
-- one of its advances still open (each advance's items by advance_repayment_request_item_advance_idx, each request by
-- its key). No automatic expiry (founder Q20). Under the same locks as the request. Returns {request_id, number,
-- withdrawn_on, still_requested_by}.
create or replace function public.withdraw_advance_repayment_request(p_idempotency_key text, p_request_id uuid,
                                                                    p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
set enable_seqscan = off
as $$
declare
  q public.advance_repayment_request;
  v_request jsonb;
  v_result jsonb;
begin
  select * into q from public.advance_repayment_request where id = p_request_id;
  if not found or not private.has_role(q.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('request_id', p_request_id, 'reason', p_reason);
  v_result := private.command_replay('withdraw_advance_repayment_request', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if p_reason is null or length(btrim(p_reason)) not between 1 and 2000 then
    raise exception 'repayment request refused: reason_required' using errcode = 'check_violation';
  end if;
  perform private.remittance_command_locks(q.organization_id, true);
  select * into q from public.advance_repayment_request where id = p_request_id for update;
  if q.withdrawn_at is not null then
    raise exception 'repayment request refused: already_withdrawn' using errcode = 'check_violation';
  end if;
  update public.advance_repayment_request
  set withdrawn_at = clock_timestamp(), withdrawn_by = auth.uid(), withdrawal_reason = btrim(p_reason)
  where id = q.id
  returning * into q;
  v_result := jsonb_build_object(
    'request_id', q.id, 'number', q.number, 'withdrawn_on', (q.withdrawn_at at time zone 'Europe/Paris')::date,
    'still_requested_by', (
      select coalesce(jsonb_agg(distinct o.number order by o.number), '[]')
      from (select i.advance_id from public.advance_repayment_request_item i where i.request_id = q.id offset 0) i
      cross join lateral (select j.request_id from public.advance_repayment_request_item j
                          where j.advance_id = i.advance_id offset 0) j
      cross join lateral (select r.number, r.withdrawn_at from public.advance_repayment_request r
                          where r.id = j.request_id offset 0) o
      where j.request_id <> q.id and o.withdrawn_at is null and private.advance_open(i.advance_id) > 0));
  perform private.command_record('withdraw_advance_repayment_request', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

------------------------------------------------------------------------------------------
-- The letter's job (plan §5.4; the worker's: jobs/repayment_requests.py)
------------------------------------------------------------------------------------------

-- What the job draws, the request's row held (two jobs never draw it at once, nor a withdrawal meanwhile): its number,
-- issue date, frozen payload, template, its key in the bucket, its document if drawn already and (review round 1,
-- NIGHT-1, CC-1) the day it was withdrawn — a request withdrawn before its letter was drawn gets none (the worker
-- draws nothing). Null for no such request.
create or replace function private.repayment_request_job(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  q public.advance_repayment_request;
begin
  select * into q from public.advance_repayment_request where id = p_request_id for update;
  if not found then
    return null;
  end if;
  return jsonb_build_object(
    'request_id', q.id, 'organization_id', q.organization_id, 'number', q.number, 'issue_date', q.issue_date,
    'payload', q.payload, 'template_version', q.template_version,
    'storage_path', 'repayment-requests/' || q.organization_id || '/' || q.id || '.pdf',
    'document_id', q.document_id, 'pdf_sha256', q.pdf_sha256,
    'withdrawn_on', (q.withdrawn_at at time zone 'Europe/Paris')::date);
end;
$$;

-- The letter drawn: once its file is stored at its key, its document (kind advance_repayment_request_pdf, the bytes'
-- SHA-256) recorded and set on the request, once. Again with the same bytes: the same document; with other bytes:
-- refused (the letter is a function of the frozen payload). (Review round 1, NIGHT-1, CC-1) Refused for a request
-- withdrawn before its letter was drawn: the client space never offers a letter of a request withdrawn before it
-- existed.
create or replace function private.repayment_request_document_done(p_request_id uuid, p_pdf_sha256 text,
                                                                   p_renderer text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  q public.advance_repayment_request;
  v_path text;
  v_doc uuid;
begin
  select * into q from public.advance_repayment_request where id = p_request_id for update;
  if not found or p_pdf_sha256 is null or p_pdf_sha256 !~ '^[0-9a-f]{64}$' or p_renderer is null
     or length(p_renderer) not between 1 and 200 then
    raise exception 'repayment request document: a request, the bytes'' hash and the renderer are required'
      using errcode = 'check_violation';
  end if;
  if q.document_id is not null then
    if q.pdf_sha256 = p_pdf_sha256 then
      return q.document_id;
    end if;
    raise exception 'repayment request document: already drawn with other bytes' using errcode = 'check_violation';
  end if;
  if q.withdrawn_at is not null then
    raise exception 'repayment request document: the request was withdrawn before its letter was drawn'
      using errcode = 'check_violation';
  end if;
  v_path := 'repayment-requests/' || q.organization_id || '/' || q.id || '.pdf';
  if not exists (select 1 from storage.objects o where o.bucket_id = 'documents' and o.name = v_path) then
    raise exception 'repayment request document: the file is not stored at its key' using errcode = 'check_violation';
  end if;
  insert into public.document (organization_id, client_organization_id, kind, storage_bucket, storage_path, sha256,
                               mime_type, file_name)
  values (q.organization_id, q.client_organization_id, 'advance_repayment_request_pdf', 'documents', v_path,
          p_pdf_sha256, 'application/pdf', q.number || '.pdf')
  returning id into v_doc;
  update public.advance_repayment_request
  set document_id = v_doc, pdf_sha256 = p_pdf_sha256, renderer_version = p_renderer
  where id = q.id;
  return v_doc;
end;
$$;

------------------------------------------------------------------------------------------
-- The pages: the client's requests (« Ce que le client doit au cabinet », the client space)
------------------------------------------------------------------------------------------

-- A client's requests, newest first (200 at most): number, issue date, currency, total, the day it was withdrawn, its
-- letter's document once drawn, the advances it names. Money staff of its servicer (aal2) and the client's whole-client
-- members (the request's RLS rule); « not allowed » otherwise. Its client's requests by
-- advance_repayment_request_client_idx, each one's items by the primary key's prefix.
create or replace function public.client_repayment_requests(p_client_organization_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_org uuid;
begin
  select c.servicer_organization_id into v_org from public.organization c
  where c.id = p_client_organization_id and c.kind <> 'servicer';
  if v_org is null
     or not (p_client_organization_id = any (private.client_whole_org_ids())
             or private.has_role(v_org, array['admin', 'ops_manager'])) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return jsonb_build_object('rows', (
    select coalesce(jsonb_agg(jsonb_build_object(
             'request_id', q.id, 'number', q.number, 'issue_date', q.issue_date, 'currency', q.currency,
             'total_minor', q.total_minor::text,
             'withdrawn_on', (q.withdrawn_at at time zone 'Europe/Paris')::date,
             'document_id', q.document_id,
             'advance_ids', (select coalesce(jsonb_agg(i.advance_id order by i.advance_id), '[]')
                             from public.advance_repayment_request_item i where i.request_id = q.id))
           order by q.created_at desc, q.id desc), '[]')
    from (select r.id, r.number, r.issue_date, r.currency, r.total_minor, r.withdrawn_at, r.document_id, r.created_at,
                 r.organization_id
          from public.advance_repayment_request r where r.client_organization_id = p_client_organization_id
          order by r.created_at desc limit 200) q
    where q.organization_id = v_org));
end;
$$;

------------------------------------------------------------------------------------------
-- Redefinitions (each copied whole from its latest definition, the change only)
------------------------------------------------------------------------------------------

-- private.remittance_approval_refusal, redefined from 20261114090000_manual_credit_note.sql (line 688; same
-- signature, its grants restated below). M2c-7c-2 (plan §5.2.7 [critic] M7-MONEY-3): the approval re-checks a planned
-- advance settle against the requests — documents_changed when a request not withdrawn names the advance (it was
-- requested after the draft was prepared). (Review round 1, CC-3) `set enable_seqscan = off` added: under the
-- statistics the scale files leave (draft_run_id at two values), the generic plan of its first statement counted the
-- run's items by a sequential scan of the whole queue (private.remittance_pending); under the setting, by
-- remittance_pending_run_idx (`draft_run_id = $1` implies its predicate), and the in-flight runs' sum by
-- remittance_run_client_idx. 7d-2 redefines it from this body (the setting with it). Nothing else changes.
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
  -- the client's proceeding the plan's set-offs assumed (§9.6, L622-7 I; money review #2): recorded or in force since
  if exists (select 1 from jsonb_array_elements(coalesce(p_draft.plan -> 'settles', '[]')) s
             where s ->> 'kind' in ('compensation', 'advance'))
     and (select min(e.effective_date) from public.client_status_event e
          where e.client_organization_id = p_run.client_organization_id and e.kind = 'proceeding_opened'
            and e.effective_date <= p_today) is distinct from p_draft.proceeding_opened_on then
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

-- private.run_advance_checks, redefined from 20261124090000_client_payments.sql (line 2281, 7c-1's: 7b's body with
-- 7c-1's three checks; same signature and settings, its grants restated below). M2c-7c-2 (plan §5.2.8):
-- advance_open's details say when the advance was last requested (requested_on), and one check after
-- written_off_recovery_ledger — repayment_request_document_missing (alert). Its other statements are unchanged.
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
end;
$$;

-- private.advance_row (« Avances »), redefined from 20261123090000_advance_recovery.sql (line 387; same signature
-- and settings, its grants restated below). M2c-7c-2 (plan §5.5): the request that names an open advance (« Demandé
-- le »). Nothing else changes.
create or replace function private.advance_row(p_advance_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select jsonb_build_object(
    'advance_id', a.id, 'client_id', a.client_organization_id, 'client_name', c.legal_name, 'currency', a.currency,
    'cause', a.cause, 'created_at', a.created_at, 'created_on', (a.created_at at time zone 'Europe/Paris')::date,
    'born_on', bo.born_on, 'cause_on', (ce.posted_at at time zone 'Europe/Paris')::date, 'file_ref', f.external_ref,
    'amount_minor', a.amount_minor::text,
    'recovered', jsonb_build_object(
      'compensation', coalesce(s.compensation, 0)::text, 'payment_own', coalesce(s.payment_own, 0)::text,
      'payment_dedicated', coalesce(s.payment_dedicated, 0)::text, 'write_off', coalesce(s.write_off, 0)::text),
    'open_minor', private.advance_open(a.id)::text,
    'reversed', exists (select 1 from public.ledger_entry z where z.reverses_entry_id = a.entry_id),
    'mandate_id', a.mandate_id, 'mandate_reference', m.reference, 'recovery', r.recovery, 'clause_ref', r.clause_ref,
    'in_flight_run', (select jsonb_build_object('run_id', x.run_id, 'number', x.run_number)
                      from private.advance_in_flight_run(a.id) x limit 1),
    -- (M2c-7c-2, plan §5.5) « Demandé le »: the request not withdrawn that names it, while it is open
    'request', (select jsonb_build_object('request_id', q.request_id, 'number', q.number, 'issue_date', q.issue_date)
                from private.advance_live_request(a.id) q where private.advance_open(a.id) > 0))
  from (select q.* from public.client_advance q where q.id = p_advance_id offset 0) a
  cross join lateral (select o.legal_name from public.organization o where o.id = a.client_organization_id offset 0) c
  cross join lateral (select e.posted_at, e.entry_type, e.reverses_entry_id from public.ledger_entry e
                      where e.id = a.cause_entry_id offset 0) ce
  left join lateral (select ac.external_ref
                     from (select e.account_id from public.ledger_entry e
                           where a.cause = 'remitted_reversal' and e.id = ce.reverses_entry_id offset 0) e
                     cross join lateral (select q.external_ref from public.account q where q.id = e.account_id
                                         offset 0) ac) f on true
  left join lateral (select sum(z.amount_minor) filter (where z.kind = 'compensation') as compensation,
                            sum(z.amount_minor) filter (where z.kind = 'payment_own') as payment_own,
                            sum(z.amount_minor) filter (where z.kind = 'payment_dedicated') as payment_dedicated,
                            sum(z.amount_minor) filter (where z.kind = 'write_off') as write_off
                     from public.commission_settlement z
                     where z.document_id = a.id and z.document_kind = 'advance') s on true
  left join lateral (select q.reference from public.mandate q where q.id = a.mandate_id offset 0) m on true
  cross join lateral (select private.advance_born_on(a.id) as born_on) bo
  cross join lateral private.advance_recovery_of(a.mandate_id, a.client_organization_id, bo.born_on,
                                                 private.paris_today()) r;
$$;

-- private.can_read_remittance_document_object (the storage policy's), redefined from
-- 20261113090000_remittance_documents.sql (line 1552; same signature and settings, its grants restated below).
-- M2c-7c-2 ([critic] F11): the letter's PDF too, for whom private.can_read_remittance_document allows — money staff
-- and the client's whole-client members. Nothing else changes.
create or replace function private.can_read_remittance_document_object(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.document d
                 where d.storage_bucket = 'documents' and d.storage_path = p_name
                   and d.kind in ('remittance_statement_pdf', 'remittance_statement_csv', 'commission_invoice_pdf',
                                  'advance_repayment_request_pdf')
                   and private.can_read_remittance_document(d.id, d.kind, d.organization_id,
                                                            d.client_organization_id));
$$;

-- the storage policy remittance_document_object_read, recreated from 20261113090000_remittance_documents.sql (line
-- 1565) with the letters' keys (repayment-requests/<servicer>/<request>.pdf)
drop policy remittance_document_object_read on storage.objects;
create policy remittance_document_object_read on storage.objects for select to authenticated
  using (bucket_id = 'documents'
         and (name like 'statements/%' or name like 'invoices/%' or name like 'repayment-requests/%')
         and (select private.can_read_remittance_document_object(name)));
-- the policy document_remittance_scope, recreated from 20261113090000_remittance_documents.sql (line 1569) with the
-- letter's kind: document_read lets every staff member and every member of the client read its documents; these kinds
-- are narrower (money staff, the client's whole-client members; an invoice's PDF only when accepted electronically)
drop policy document_remittance_scope on public.document;
create policy document_remittance_scope on public.document as restrictive for select to authenticated
  using (kind not in ('remittance_statement_pdf', 'remittance_statement_csv', 'commission_invoice_pdf',
                      'advance_repayment_request_pdf')
         or private.can_read_remittance_document(id, kind, organization_id, client_organization_id));

------------------------------------------------------------------------------------------
-- Review fixes round 1 (ADR-0014 « M2c-7c-2 review fixes »): the returns that would release a requested advance,
-- a dedicated-account line naming a DRA-…
------------------------------------------------------------------------------------------

-- private.transfer_line_check, redefined from 20261123090000_advance_recovery.sql (line 889, 7b's; same signature and
-- settings, its grants restated below). M2c-7c-2 review round 1 (MONEY-1): the return of an unplanned booking whose
-- double_payout advance a repayment request not withdrawn names is refused advance_requested
-- (private.advance_live_request), as 7b refuses advance_in_flight: booked, it would reverse the advance while the
-- client space keeps the letter asking for it (plan §0 #1, ADR D5: never ask for what the client did not receive).
-- Under the locks the request takes (transfer_line_locks: … → remit), so a request and this return never interleave.
-- Nothing else changes.
create or replace function private.transfer_line_check(p_line_id uuid, p_locked boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
<<chk>>
declare
  l public.bank_transaction;
  v_kind text;
  v_held boolean;
  v_class text := (select m.v from pg_temp._tl_meta m where m.k = 'class');
  v_returned_id text;
  v_why text;
  v_detail text;
  v_parts_signed bigint;
  v_cands integer;
  v_file uuid;
  v_file_downloads integer;
  v_fee record;
  v_main record;
  r record;
  v_x record;
  v_cap bigint;
  v_queue bigint;
  v_p bigint;
  v_n_el integer;
  v_c uuid;
  v_bk record;
  v_first uuid;
  v_live_id uuid;
  v_live_status text;
  v_live_number text;
  v_own uuid;
  v_iban_clients integer;
  v_y record;          -- M2c-6b-3a-2 (E): a late predecessor's live transfer
  v_lp_entry uuid;     -- (G): its payout booking's entry
  v_lp_n integer;
  v_chained boolean;   -- M2c-6b-3b part 1 review round 1: a payout part's run whose chain holds another transfer
  v_chain_paid date;   -- … the date its chain paid the client and stayed paid, this line its execution
begin
  -- (the working tables every branch's statements name exist, so each statement plans whatever the class)
  create temp table if not exists _tl_locked_runs (run_id uuid primary key) on commit drop;
  drop table if exists pg_temp._tl_u;
  create temp table _tl_u (k integer, id text, dir text, amount bigint, transfer_id uuid, tr_kind text,
                           tr_status text, tr_debtor uuid, part_kind text, returns_line_id uuid, tr_run uuid)
    on commit drop;
  select * into l from public.bank_transaction where id = p_line_id;
  select coalesce(d.released_kind, l.kind), (l.kind = 'suspected_duplicate' and d.decision is distinct from 'released')
  into v_kind, v_held
  from (select 1) z left join public.bank_duplicate_resolution d on d.bank_transaction_id = l.id;
  v_returned_id := coalesce(l.original_end_to_end_id, l.end_to_end_id);

  drop table if exists pg_temp._tl;
  create temp table _tl on commit drop as
  select q.n, q.kind, q.transfer_id, q.client_id, q.returns_line_id, q.amount,
         x.kind as tr_kind, x.status as tr_status, x.end_to_end_id as tr_e2e, x.debtor_bank_account_id as tr_debtor,
         x.creditor_bank_account_id as tr_creditor, x.currency as tr_currency, x.amount_minor as tr_minor,
         x.transfer_file_id as tr_file, x.run_id as tr_run, x.client_organization_id as tr_client,
         x.entry_id as tr_entry, x.return_entry_id as tr_return_entry, x.payee_iban as tr_iban,
         ru.status as run_status, ru.transfer_id as run_transfer, ru.number as run_number,
         ru.payout_account_id as run_payout_account,
         null::uuid as c, 0::bigint as a, 0::bigint as p, 0::bigint as adv, null::text as p_bound, false as late,
         null::date as late_date,
         null::uuid as own_bank, null::uuid as ub_entry, null::uuid as ub_adv_entry, null::uuid as ub_adv_id,
         0::bigint as ub_adv, null::uuid as payout_account, null::uuid as entry_id, null::uuid as adv_id,
         null::uuid as adv_entry_id, null::uuid as rev_entry_id, null::uuid as rev_adv_entry_id,
         -- M2c-6b-3a-2 (E): a late predecessor part — its run's live transfer y, y's status, the transfer the booking
         -- cancels (y, ordered or in a file not downloaded yet) and the file it withdraws (y's, not downloaded yet)
         false as lp, null::uuid as lp_y, null::text as lp_status, null::uuid as lp_cancel, null::text as lp_cancel_e2e,
         null::uuid as lp_file, null::text as lp_file_number,
         -- review round 2 (ld2-reissue-return-pays-twice): the other transfer of the run's chain the part concerns —
         -- the unplanned payout a return of the run's payout closes, or the transfer whose return is the run's payout's
         null::text as other_e2e
  from pg_temp._tl_req q
  left join lateral (select y.* from public.bank_transfer y where y.id = q.transfer_id offset 0) x on true
  left join lateral (select y.status, y.transfer_id, y.number, y.payout_account_id from public.remittance_run y
                     where y.id = x.run_id offset 0) ru on true;
  drop table if exists pg_temp._tl_items;
  create temp table _tl_items (n integer not null, ledger_entry_id uuid not null, amount_minor bigint not null,
                               primary key (n, ledger_entry_id)) on commit drop;
  drop table if exists pg_temp._tl_drafts;
  create temp table _tl_drafts (run_id uuid primary key, number text not null, client_organization_id uuid not null)
    on commit drop;
  drop table if exists pg_temp._tl_pool;
  create temp table _tl_pool (n integer not null, ledger_entry_id uuid not null, primary key (n, ledger_entry_id))
    on commit drop;

  <<rules>>
  begin
    -- §3.4.2 the line's state
    if v_held then v_why := 'held_duplicate'; exit rules; end if;
    if exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = l.id)
       or exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = l.id) then
      v_why := 'already_booked'; exit rules;
    end if;
    if exists (select 1 from public.bank_debit_link k where k.bank_transaction_id = l.id) then
      v_why := 'already_linked'; exit rules;
    end if;
    if exists (select 1 from public.payment p where p.bank_transaction_id = l.id) then
      v_why := 'line_is_payment'; exit rules;
    end if;
    -- (critic F16) the kinds a part may sit on, as the job reads them (class U: per stored detail, below). Review LT-6:
    -- the line's direction first — a debit part on a credit line (our payout's flagged return among them) or a return
    -- part on a debit line is wrong_direction — then its kind (a refund, a direct debit, a payment's return: not a
    -- transfer line; a credit that is not coming back: not a return)
    if v_class = 'U' then
      if v_kind not in ('transfer_out', 'other_debit', 'batch_unsplit', 'return', 'own_transfer_in',
                        'client_transfer_in') then
        v_why := case when l.direction = 'debit' then 'not_a_transfer_line' else 'not_a_return' end; exit rules;
      end if;
    else
      if exists (select 1 from pg_temp._tl t
                 where (t.kind in ('payout', 'sweep', 'unplanned_payout', 'unplanned_sweep') and l.direction <> 'debit')
                    or (t.kind in ('payout_returned', 'sweep_returned', 'unplanned_payout_returned',
                                   'unplanned_sweep_returned') and l.direction <> 'credit')) then
        v_why := 'wrong_direction'; exit rules;
      end if;
      if exists (select 1 from pg_temp._tl t
                 where t.kind in ('payout', 'sweep', 'unplanned_payout', 'unplanned_sweep')
                   and v_kind not in ('transfer_out', 'other_debit', 'batch_unsplit')) then
        v_why := 'not_a_transfer_line'; exit rules;
      end if;
      if exists (select 1 from pg_temp._tl t
                 where t.kind in ('payout_returned', 'sweep_returned', 'unplanned_payout_returned',
                                  'unplanned_sweep_returned')
                   and v_kind not in ('return', 'own_transfer_in', 'client_transfer_in')) then
        v_why := 'not_a_return'; exit rules;
      end if;
    end if;
    -- (review money-1) an entry the bank kept unsplit holding no detail of ours (unsplit_ours 0, its details or NbOfTxs
    -- counted) carries the entry's total, not one movement: never booked as one — rule 3b's one candidate, a client's
    -- or our own IBAN's part, the return of an unplanned payout — as the job never books such a line (batch_partial,
    -- return_differs). Only our lot (class B, its count checked against its only subset below) and an entry holding
    -- ours (class U, from its stored details) are booked from it
    if l.unsplit_ours is not null and v_class not in ('U', 'B') then
      v_why := 'unsplit_not_bookable'; exit rules;
    end if;
    -- a lot holding a refund, or of two kinds (S11: left)
    if v_class = 'B' and l.direction = 'debit'
       and exists (select 1 from pg_temp._tl_pre p where p.role = 'member'
                   having bool_or(p.kind = 'refund') or count(distinct p.kind) > 1) then
      v_why := 'batch_mixed'; exit rules;
    end if;

    -- §3.4.12 an entry kept unsplit: its parts are the statement's own details, never ops' (critic F8, F7, L11)
    if v_class = 'U' then
      if l.unsplit_details is null
         or exists (select 1 from jsonb_array_elements(l.unsplit_details) d where d ->> 'amount_minor' is null) then
        v_why := 'unsplit_detail_missing'; exit rules;
      end if;
      -- (critic2 ML-5) every detail of the entry ours, and NbOfTxs, when given, the count
      if l.unsplit_detail_count is distinct from l.unsplit_ours::integer
         or (l.unsplit_batch_count is not null and l.unsplit_batch_count <> l.unsplit_detail_count) then
        v_why := 'unsplit_not_bookable'; exit rules;
      end if;
      insert into pg_temp._tl_u (k, id, dir, amount, transfer_id, tr_kind, tr_status, tr_debtor, tr_run)
      select d.o::integer, d.v ->> 'id', d.v ->> 'direction', (d.v ->> 'amount_minor')::bigint,
             x.id, x.kind, x.status, x.debtor_bank_account_id, x.run_id
      from jsonb_array_elements(l.unsplit_details) with ordinality d (v, o)
      -- (critic2 CSO2-10) by (the line's servicer, the id), then its account: never another servicer's transfer (CI
      -- scale fix: the probe holds the id alone, the servicer compared outside it)
      left join lateral (select y.id, y.kind, y.status, y.debtor_bank_account_id, y.run_id
                         from (select q.id, q.kind, q.status, q.debtor_bank_account_id, q.organization_id, q.run_id
                               from public.bank_transfer q where q.end_to_end_id = d.v ->> 'id' offset 0) y
                         where y.organization_id = l.organization_id) x
        on true;
      if exists (select 1 from pg_temp._tl_u u
                 where u.id !~ '^(RMT|SWP)' or u.transfer_id is null or u.tr_debtor <> l.bank_account_id
                    or u.tr_kind not in ('payout', 'sweep'))
         or (select count(distinct u.id) <> count(*) from pg_temp._tl_u u) then
        v_why := 'unsplit_not_bookable'; exit rules;
      end if;
      -- M2c-6b-3a-2 review round 1 (CSC-2): two debits of one run's payout chain in one entry (a payout and the transfer
      -- it re-issues, or two of its re-issues, the bank executing both) are never two payouts of that run — one run
      -- settled twice — nor its payout and a « Virement hors reversement » derived from the details alone: not bookable
      -- here (ops ask the bank for the detail, the support books it)
      if exists (select 1 from pg_temp._tl_u u
                 where u.dir = 'debit' and u.tr_kind = 'payout' and u.tr_run is not null
                 group by u.tr_run having count(*) > 1) then
        v_why := 'unsplit_not_bookable'; exit rules;
      end if;
      -- the kind each detail gives: a debit, the planned debit of a live transfer or the unplanned one of a cancelled,
      -- booked or returned one; a credit, the planned return, or the unplanned booking's return while one is open
      update pg_temp._tl_u u set part_kind = case
          -- M2c-6b-3a-2 review round 1 (DP-2, CSC-2): a late predecessor's debit is its run's payout, as the options
          -- propose it (private.transfer_line_options_of); the late predecessor's rules below then decide
          when u.dir = 'debit' and u.tr_status = 'cancelled' and u.tr_kind = 'payout'
               and private.transfer_late_predecessor(u.transfer_id) then u.tr_kind
          when u.dir = 'debit' and u.tr_status in ('cancelled', 'booked', 'returned') then 'unplanned_' || u.tr_kind
          when u.dir = 'debit' then u.tr_kind
          when private.transfer_unplanned_open(u.transfer_id) then 'unplanned_' || u.tr_kind || '_returned'
          else u.tr_kind || '_returned' end
      where true;  -- every row (an API session refuses an UPDATE without WHERE: pg-safeupdate)
      update pg_temp._tl_u u set returns_line_id = (
          select o.line_id from private.transfer_line_open_unplanned(l.organization_id, u.transfer_id, null, null,
                                                                     'unplanned_' || u.tr_kind) o limit 1)
      where u.part_kind like 'unplanned_%_returned';
      if (select count(*) from pg_temp._tl t where t.kind <> 'fee') <> (select count(*) from pg_temp._tl_u)
         or exists (select 1 from pg_temp._tl_u u
                    where not exists (select 1 from pg_temp._tl t
                                      where t.kind = u.part_kind and t.transfer_id = u.transfer_id
                                        and t.amount = u.amount
                                        and t.returns_line_id is not distinct from u.returns_line_id)) then
        v_why := 'unsplit_parts_differ'; exit rules;
      end if;
    end if;

    -- §3.5 a lot: its parts among its members (debit) or returnable members (credit)
    if v_class = 'B' then
      v_file := (select i.file_id
                 from (select y.file_id from public.transfer_file_item y where y.pmt_inf_id = l.payment_info_id offset 0) i
                 cross join lateral (select f.debtor_bank_account_id from public.transfer_file f
                                     where f.id = i.file_id offset 0) f
                 where f.debtor_bank_account_id = l.bank_account_id limit 1);
      select f.download_count into v_file_downloads from public.transfer_file f where f.id = v_file;
      if l.direction = 'debit' and coalesce(v_file_downloads, 0) = 0 then
        v_why := 'not_handed_out'; exit rules;
      end if;
      if exists (select 1 from pg_temp._tl t
                 where t.kind <> 'fee'
                   and not exists (select 1 from pg_temp._tl_pre p
                                   where p.role in ('member', 'returnable') and p.transfer_id = t.transfer_id)) then
        v_why := 'not_its_line'; exit rules;
      end if;
      -- (lot credit) its universe depends on statuses: read again under the locks, it must be the one the subset
      -- was computed on
      if p_locked and l.direction = 'credit'
         and (select coalesce(array_agg(m.transfer_id || ':' || m.amount_minor || ':' || m.unplanned_open
                                        order by m.seq), '{}')
              from private.transfer_line_returnable(l.id) m)
             is distinct from
             (select coalesce(array_agg(p.transfer_id || ':' || p.amount_minor || ':' || p.unplanned_open
                                        order by p.ord), '{}')
              from pg_temp._tl_pre p where p.role = 'returnable') then
        v_why := 'split_changed'; exit rules;
      end if;
    end if;

    -- §3.4.2 the signed sum: debit parts and a fee −, return parts +, against the signed line
    select coalesce(sum(case when t.kind in ('payout_returned', 'sweep_returned', 'unplanned_payout_returned',
                                             'unplanned_sweep_returned') then t.amount else -t.amount end), 0)
    into v_parts_signed from pg_temp._tl t;
    if v_parts_signed <> (case l.direction when 'credit' then l.amount_minor else -l.amount_minor end) then
      v_why := 'parts_do_not_add_up'; exit rules;
    end if;

    -- §3.4.10 a fee only on our transfer's own line (critic L2, F7; critic2 ML-6, ML-10, CSO2-1)
    select t.* into v_fee from pg_temp._tl t where t.kind = 'fee';
    if found then
      if v_class = 'E' and l.direction = 'debit' then
        select t.* into v_main from pg_temp._tl t
        where t.kind in ('payout', 'sweep', 'unplanned_payout', 'unplanned_sweep') and t.tr_e2e = l.end_to_end_id;
        if not found or l.amount_minor <= v_main.tr_minor then
          v_why := 'fee_not_allowed'; exit rules;
        end if;
      elsif v_class = 'E' and l.direction = 'credit' and v_kind = 'return' then
        select t.* into v_main from pg_temp._tl t
        where t.kind in ('payout_returned', 'sweep_returned', 'unplanned_payout_returned', 'unplanned_sweep_returned')
          and t.tr_e2e = v_returned_id;
        if not found or l.amount_minor >= v_main.amount then
          v_why := 'fee_not_allowed'; exit rules;
        end if;
      elsif v_class = 'U' and l.direction = 'debit' and l.unsplit_ours = 1 and l.unsplit_detail_count = 1
            and coalesce(l.unsplit_batch_count, 1) = 1
            and (select u.dir from pg_temp._tl_u u) = 'debit' then
        -- (c) the ISO shape of S08: one detail in all, ours, at N; the entry N + F, F the statement's own charge
        if l.charges_minor is null then
          v_why := 'unsplit_detail_missing'; exit rules;
        end if;
        if l.charges_minor <> v_fee.amount then
          v_why := 'amount_differs'; exit rules;
        end if;
      else
        v_why := 'fee_not_allowed'; exit rules;
      end if;
      if v_class = 'E' then
        -- (review LT-3) a charges block the import saw and could not read (camt.053.001.02's `Chrgs`, a record not the
        -- bank's debit in the account's currency): the statement records a charge Collectoo cannot read — never booked as
        -- a line that records none (COMPLIANCE OQ-84 (j))
        if l.charges_read is false then
          v_why := 'unsplit_detail_missing'; exit rules;
        end if;
        -- (critic2 ML-10) the statement's charge when it records one; with none, never the amount of one of our
        -- transfers put in a file on this account (the line's own included: a double debit in one entry)
        if l.charges_minor is not null and l.charges_minor <> v_fee.amount then
          v_why := 'amount_differs'; exit rules;
        end if;
        if l.charges_minor is null
           and exists (select 1 from public.bank_transfer y
                       where y.debtor_bank_account_id = l.bank_account_id and y.amount_minor = v_fee.amount
                         and y.transfer_file_id is not null) then
          v_why := 'fee_unexplained'; exit rules;
        end if;
      end if;
    end if;

    -- §3.5 the only subset of the lot making the line (critic CSO-3: computed before the locks)
    if v_class = 'B' then
      if (select m.v from pg_temp._tl_meta m where m.k = 'subset') is distinct from 'one'
         or exists (select 1 from pg_temp._tl_pre p
                    where p.role in ('member', 'returnable') and p.in_subset
                      and not exists (select 1 from pg_temp._tl t where t.transfer_id = p.transfer_id)) then
        v_why := 'batch_ambiguous'; exit rules;
      end if;
      -- (review money-1) our lot kept unsplit by the bank: the count of its transactions the statement gives — NbOfTxs,
      -- or its details (none of them ours) — is the only subset's, else the entry holds a movement that is not ours
      if l.unsplit_ours is not null
         and ((l.unsplit_batch_count is not null
               and l.unsplit_batch_count <> (select count(*) from pg_temp._tl_pre p
                                             where p.role in ('member', 'returnable') and p.in_subset))
              or (coalesce(l.unsplit_detail_count, 0) > 0
                  and l.unsplit_detail_count <> (select count(*) from pg_temp._tl_pre p
                                                 where p.role in ('member', 'returnable') and p.in_subset))) then
        v_why := 'unsplit_not_bookable'; exit rules;
      end if;
    end if;

    -- rule 3b's candidates (classes N, O, E0): read again under the locks, never one the locks did not take
    if v_class in ('N', 'O', 'E0') and l.direction = 'debit' then
      if p_locked and exists (select 1 from private.transfer_line_candidates(l.id, v_class) c
                              where not exists (select 1 from pg_temp._tl_pre p
                                                where p.role = 'candidate' and p.transfer_id = c.transfer_id)) then
        v_why := 'split_changed'; exit rules;
      end if;
      select count(*) into v_cands from pg_temp._tl_pre p where p.role = 'candidate';
      if v_cands > 1 then
        v_why := 'line_ambiguous'; exit rules;
      end if;
    end if;

    -- the items an unplanned payout of a cancelled or returned transfer was meant to pay (§3.6.1): a cancelled
    -- transfer's run's released lines, a returned one's return item (by key)
    -- M2c-6b-3a-2 review round 1 (DP-3): and the return items of its run's payout chain — the payout_returned bookings'
    -- entries of every transfer of the chain of its run's transfer (a late predecessor booked as the run's payout, then
    -- returned, keeps no return entry of its own; a re-issue booked then returned): this debit paid the client that
    -- money again, which the client's next run would otherwise pay a second time (by key: the chain, each one's
    -- bookings)
    insert into pg_temp._tl_pool (n, ledger_entry_id)
    select distinct t.n, y.ledger_entry_id
    from pg_temp._tl t
    cross join lateral (select q.ledger_entry_id, q.released from public.remittance_line q
                        where q.run_id = t.tr_run offset 0) y
    where t.kind = 'unplanned_payout' and t.tr_status = 'cancelled' and t.tr_run is not null and y.released
    union
    select t.n, t.tr_return_entry from pg_temp._tl t
    where t.kind = 'unplanned_payout' and t.tr_status = 'returned' and t.tr_return_entry is not null
    union
    select t.n, k.entry_id
    from pg_temp._tl t
    cross join lateral private.transfer_chain(t.run_transfer) h
    cross join lateral (select q.entry_id, q.kind from public.bank_line_booking q
                        where q.transfer_id = h.transfer_id offset 0) k
    where t.kind = 'unplanned_payout' and t.tr_kind = 'payout' and t.tr_status in ('cancelled', 'returned')
      and t.run_transfer is not null and k.kind = 'payout_returned';

    -- each part's own rules (§3.4.3–§3.4.13), in its order
    for r in select * from pg_temp._tl t order by t.n loop
      if r.kind in ('payout', 'sweep') then
        -- (review LT-6) a transfer of this servicer of another kind (a sweep part naming one of our payouts)
        if r.tr_kind is distinct from r.kind then v_why := 'transfer_kind_differs'; exit rules; end if;
        if v_class <> 'U' and l.direction <> 'debit' then v_why := 'wrong_direction'; exit rules; end if;
        if not (case v_class
                 when 'E' then l.end_to_end_id = r.tr_e2e
                 when 'B' then exists (select 1 from pg_temp._tl_pre p where p.role = 'member'
                                         and p.transfer_id = r.transfer_id) and r.tr_file = v_file
                 when 'U' then true
                 else v_cands = 1 and exists (select 1 from pg_temp._tl_pre p where p.role = 'candidate'
                                                and p.transfer_id = r.transfer_id) end) then
          v_why := 'not_its_line'; exit rules;
        end if;
        -- M2c-6b-3a-2 (E): a payout cancelled out of a downloaded file whose run is still approved or sent, in the
        -- chain of that run's transfer (private.transfer_late_predecessor), executed late: that run's payout (the late
        -- predecessor). The run's live transfer y — read here, under the locks for the command (private.
        -- transfer_line_locks re-reads it after the remit lock and locks it) — decides: nothing to cancel (y is x, or y
        -- cancelled already); y cancelled (ordered) or withdrawn with its file (in a file not downloaded yet:
        -- superseded, private.transfer_line_post); refused reissue_in_downloaded_file while y's file is downloaded or
        -- sent (the bank may still execute it: ops have that file cancelled on the evidence first, OQ-80 (n)); already
        -- debited once a transfer of the chain is
        if r.tr_status = 'cancelled' and r.kind = 'payout' and private.transfer_late_predecessor(r.transfer_id) then
          if exists (select 1
                     from private.transfer_chain(r.run_transfer) h
                     cross join lateral (select k.kind from public.bank_line_booking k
                                         where k.transfer_id = h.transfer_id offset 0) k
                     where k.kind = 'payout') then
            v_why := 'already_debited'; exit rules;
          end if;
          if r.tr_debtor <> l.bank_account_id or r.tr_currency <> l.currency then
            v_why := 'transfer_differs'; exit rules;
          end if;
          select y.id, y.status, y.end_to_end_id, y.transfer_file_id, f.status as file_status, f.download_count,
                 f.number
          into v_y
          from (select q.id, q.status, q.end_to_end_id, q.transfer_file_id from public.bank_transfer q
                where q.id = r.run_transfer offset 0) y
          left join lateral (select g.status, g.download_count, g.number from public.transfer_file g
                             where g.id = y.transfer_file_id offset 0) f on true;
          if v_y.status in ('booked', 'returned') then v_why := 'already_debited'; exit rules; end if;
          if v_y.status = 'in_file' and (coalesce(v_y.download_count, 0) > 0
                                         or v_y.file_status not in ('pending', 'generated')) then
            v_why := 'reissue_in_downloaded_file'; v_detail := v_y.number; exit rules;
          end if;
          update pg_temp._tl t set lp = true, lp_y = v_y.id, lp_status = v_y.status,
            lp_cancel = case when v_y.id <> r.transfer_id and v_y.status in ('ordered', 'in_file') then v_y.id end,
            lp_cancel_e2e = case when v_y.id <> r.transfer_id and v_y.status in ('ordered', 'in_file')
                                 then v_y.end_to_end_id end,
            lp_file = case when v_y.status = 'in_file' then v_y.transfer_file_id end,
            lp_file_number = case when v_y.status = 'in_file' then v_y.number end
          where t.n = r.n;
        else
          if r.tr_status = 'cancelled' then v_why := 'transfer_cancelled'; exit rules; end if;
          if r.tr_status in ('booked', 'returned')
             or exists (select 1 from public.bank_line_booking k where k.transfer_id = r.transfer_id
                          and k.kind in ('payout', 'sweep')) then
            v_why := 'already_debited'; exit rules;
          end if;
          if r.tr_status <> 'in_file'
             or not exists (select 1 from public.transfer_file f where f.id = r.tr_file and f.download_count > 0
                              and f.status in ('downloaded', 'sent')) then
            v_why := 'not_handed_out'; exit rules;
          end if;
          if r.tr_debtor <> l.bank_account_id or r.tr_currency <> l.currency then
            v_why := 'transfer_differs'; exit rules;
          end if;
          if r.kind = 'payout' and (r.run_status is null or r.run_status not in ('approved', 'sent')
                                    or r.run_transfer is distinct from r.transfer_id) then
            v_why := 'run_not_in_flight'; exit rules;
          end if;
        end if;
        if r.amount <> r.tr_minor then v_why := 'amount_differs'; exit rules; end if;
        -- (review 6b-2c money-3, legal-deadlines-2) late, and the date its breach is recorded against, as
        -- private.bank_booking_post_rows records the row: the run's lines late at the line's date by their own date, a
        -- line whose delay cannot be met by its one-month date (private.remittance_run_late_on: the run's lines by its
        -- key, as the CI scale fix reads them)
        -- M2c-6b-3a-2 review round 1 (LD-2): judged at the earliest debit naming another transfer of the run's chain by
        -- our references, when earlier than this line (a late predecessor's own debit paid the client then), as
        -- private.bank_booking_post_rows records the row. Review round 4 (CPCE-08): for a run whose chain holds another
        -- transfer, at the date its chain paid the client and stayed paid with this line booked as this part's payout
        -- (private.remittance_chain_paid: every execution and return of the chain, each counted for the transfer it
        -- names), this line's date when none stayed paid; a run with no other transfer, at this line's date as before
        -- M2c-6b-3b part 1 review round 1 (chain-holds-snapshot-race): the chain's paid date read here (null when no
        -- copy stayed) is passed to the holds, which read it again with the coverage and the possible debits and wait
        -- when it moved
        v_chained := r.kind = 'payout'
                     and exists (select 1 from private.transfer_chain(r.run_transfer) h
                                 where h.transfer_id <> r.transfer_id);
        v_chain_paid := case when v_chained
                             then (select p.paid_on
                                   from private.remittance_chain_paid(r.run_transfer, l.id, r.transfer_id) p) end;
        update pg_temp._tl t set c = r.tr_client, a = r.amount,
          -- M2c-6b-3b part 1 (CPCE-08): for a run whose chain holds another transfer, only the lines whose rows the
          -- booking writes (private.remittance_chain_rows: the statements cover L, no other transfer of the chain may
          -- have paid by L uncounted; this line, previewed, none of them) — the sheet says late only then
          late_date = case when r.kind = 'payout' then
            case when v_chained
                 then (select min(x.latest_execution_date)
                       from private.remittance_chain_rows(r.tr_run, coalesce(v_chain_paid, l.booking_date), v_chain_paid,
                                                          r.transfer_id, l.id, null, false) x)
                 else private.remittance_run_late_on(r.tr_run, l.booking_date) end end
        where t.n = r.n;
        update pg_temp._tl t set late = t.late_date is not null where t.n = r.n;

      elsif r.kind in ('unplanned_payout', 'unplanned_sweep') and r.transfer_id is not null then
        if r.tr_kind is distinct from (case r.kind when 'unplanned_payout' then 'payout' else 'sweep' end) then
          v_why := 'transfer_kind_differs'; exit rules;
        end if;
        if v_class <> 'U' and l.direction <> 'debit' then v_why := 'wrong_direction'; exit rules; end if;
        if not (case v_class
                 when 'E' then l.end_to_end_id = r.tr_e2e
                 when 'B' then exists (select 1 from pg_temp._tl_pre p where p.role = 'member'
                                         and p.transfer_id = r.transfer_id)
                 when 'U' then true
                 else v_cands = 1 and exists (select 1 from pg_temp._tl_pre p where p.role = 'candidate'
                                                and p.transfer_id = r.transfer_id) end) then
          v_why := 'not_its_line'; exit rules;
        end if;
        if r.tr_status not in ('cancelled', 'booked', 'returned') then
          v_why := 'not_cancelled_nor_booked'; exit rules;
        end if;
        -- (critic2 ML-4) a cancelled payout whose run is still approved or sent: this debit is that run's payout
        if r.kind = 'unplanned_payout' and r.tr_status = 'cancelled' and r.run_status in ('approved', 'sent') then
          v_why := 'run_still_live'; v_detail := r.run_number; exit rules;
        end if;
        if r.tr_debtor <> l.bank_account_id or r.tr_currency <> l.currency then
          v_why := 'transfer_differs'; exit rules;
        end if;
        if r.amount <> r.tr_minor then v_why := 'amount_differs'; exit rules; end if;
        if r.kind = 'unplanned_payout' then
          -- (critic F6) what this payout paid sits in a run of the client approved but not handed out yet: that run
          -- is cancelled first, so that its items come back to the queue and this debit is netted against them
          select rr.number into v_detail
          from pg_temp._tl_pool p
          cross join lateral (select q.run_id from public.remittance_line q
                              where q.ledger_entry_id = p.ledger_entry_id and not q.released offset 0) q
          cross join lateral (select y.status, y.number, y.transfer_id, y.client_organization_id
                              from public.remittance_run y where y.id = q.run_id offset 0) rr
          left join lateral (select y.status, y.transfer_file_id from public.bank_transfer y
                             where y.id = rr.transfer_id offset 0) bt on true
          left join lateral (select y.download_count from public.transfer_file y where y.id = bt.transfer_file_id
                             offset 0) f on true
          where p.n = r.n and rr.status in ('approved', 'sent') and rr.client_organization_id = r.tr_client
            and (bt.status is null or bt.status = 'ordered' or (bt.status = 'in_file' and coalesce(f.download_count, 0) = 0))
          order by rr.number limit 1;
          if v_detail is not null then v_why := 'client_run_cancellable'; exit rules; end if;
          update pg_temp._tl t set c = r.tr_client, a = r.amount where t.n = r.n;
        else
          update pg_temp._tl t set a = r.amount, own_bank = r.tr_creditor where t.n = r.n;
        end if;

      elsif r.kind = 'unplanned_payout' then
        -- §3.4.6 to a client's registered payout IBAN, matching nothing of ours (S13, S07)
        if v_class not in ('N', 'O', 'E0') or l.direction <> 'debit' then v_why := 'not_its_line'; exit rules; end if;
        if not exists (select 1 from public.client_payout_account a
                       where a.client_organization_id = r.client_id and a.iban = l.counterparty_iban
                         and a.currency = l.currency and a.confirmed_at is not null
                         and a.status in ('active', 'returned', 'retired')) then
          v_why := 'client_iban_mismatch'; exit rules;
        end if;
        -- (critic CSO-5) the same IBAN registered for another client of this servicer
        select count(distinct a.client_organization_id) into v_iban_clients
        from public.client_payout_account a
        where a.iban = l.counterparty_iban and a.organization_id = l.organization_id;
        if v_iban_clients > 1 then v_why := 'client_ambiguous'; exit rules; end if;
        -- (critic F13, F12, L12) on every class: never while a transfer of ours may be this debit
        if exists (select 1 from pg_temp._tl_pre p where p.role = 'candidate' and p.cand in ('i', 'ii')) then
          v_why := 'payout_in_flight_matches'; exit rules;
        end if;
        if exists (select 1 from pg_temp._tl_pre p where p.role = 'candidate' and p.cand = 'iii') then
          v_why := 'cancelled_payout_matches'; exit rules;
        end if;
        -- M2c-6b-3a (K): a refund or a sweep cancelled out of a downloaded file may be this debit
        if exists (select 1 from pg_temp._tl_pre p where p.role = 'candidate' and p.cand = 'iv') then
          v_why := 'cancelled_transfer_matches'; exit rules;
        end if;
        if exists (select 1 from public.bank_transfer y
                   left join public.transfer_file f on f.id = y.transfer_file_id
                   where y.debtor_bank_account_id = l.bank_account_id and y.status in ('ordered', 'in_file')
                     and y.kind = 'payout' and y.client_organization_id = r.client_id
                     and y.amount_minor = l.amount_minor and y.payee_iban = l.counterparty_iban
                     and (y.status = 'ordered' or coalesce(f.download_count, 0) = 0)) then
          v_why := 'payout_not_handed_out_matches'; exit rules;
        end if;
        if r.amount <> l.amount_minor then v_why := 'amount_differs'; exit rules; end if;
        update pg_temp._tl t set c = r.client_id, a = r.amount, p = 0, adv = r.amount, p_bound = 'none'
        where t.n = r.n;

      elsif r.kind = 'unplanned_sweep' then
        -- §3.4.8 to our own IBAN, without an order of ours (S14, S07)
        if v_class not in ('N', 'O', 'E0') or l.direction <> 'debit' then v_why := 'not_its_line'; exit rules; end if;
        select o.id into v_own from public.bank_account o
        where o.organization_id = l.organization_id and o.purpose = 'own' and o.status = 'active'
          and o.iban = l.counterparty_iban and o.currency = l.currency;
        if v_own is null then v_why := 'own_account_unknown'; exit rules; end if;
        if exists (select 1 from pg_temp._tl_pre p where p.role = 'candidate' and p.kind = 'sweep') then
          v_why := 'sweep_in_flight_matches'; exit rules;
        end if;
        -- M2c-6b-3a (K): a refund cancelled out of a downloaded file may be this debit
        if exists (select 1 from pg_temp._tl_pre p where p.role = 'candidate' and p.cand = 'iv') then
          v_why := 'cancelled_transfer_matches'; exit rules;
        end if;
        if exists (select 1 from pg_temp._tl_pre p where p.role = 'candidate') then
          v_why := 'payout_in_flight_matches'; exit rules;
        end if;
        if r.amount <> l.amount_minor then v_why := 'amount_differs'; exit rules; end if;
        update pg_temp._tl t set a = r.amount, own_bank = v_own where t.n = r.n;

      elsif r.kind in ('payout_returned', 'sweep_returned') then
        if r.tr_kind is distinct from (case r.kind when 'payout_returned' then 'payout' else 'sweep' end) then
          v_why := 'transfer_kind_differs'; exit rules;
        end if;
        if v_class <> 'U' and l.direction <> 'credit' then v_why := 'wrong_direction'; exit rules; end if;
        if not (case v_class
                 when 'E' then v_returned_id = r.tr_e2e
                               -- review round 2 (ld2-reissue-return-pays-twice): the line returns another transfer of
                               -- the run's chain whose unplanned payout a return of this payout closed — both copies came
                               -- back, this one is the run's payout's (private.transfer_return_partner)
                               or (r.kind = 'payout_returned'
                                   and private.transfer_return_partner(
                                         (select y.id from (select q.id, q.organization_id from public.bank_transfer q
                                                            where q.end_to_end_id = v_returned_id offset 0) y
                                          where y.organization_id = l.organization_id))
                                       is not distinct from r.transfer_id)
                 when 'B' then exists (select 1 from pg_temp._tl_pre p where p.role = 'returnable'
                                         and p.transfer_id = r.transfer_id)
                 when 'U' then true
                 else false end) then
          v_why := 'not_its_line'; exit rules;
        end if;
        if v_class = 'E' and v_returned_id is distinct from r.tr_e2e then
          update pg_temp._tl t set other_e2e = v_returned_id where t.n = r.n;
        end if;
        if r.tr_status in ('ordered', 'in_file') then v_why := 'return_before_debit'; exit rules; end if;
        -- (critic F1) the copy that comes back is the unplanned booking's: booked as this one, it would pay again
        if private.transfer_unplanned_open(r.transfer_id) then v_why := 'unplanned_open'; exit rules; end if;
        -- (critic2 ML-3) a second or late debit of it waits on a statement: booked first
        select x into v_detail from private.transfer_late_lines(r.transfer_id) x limit 1;
        if v_detail is not null then v_why := 'debit_pending'; exit rules; end if;
        if r.tr_status = 'returned'
           or exists (select 1 from public.bank_line_booking k where k.transfer_id = r.transfer_id
                        and k.kind in ('payout_returned', 'sweep_returned')) then
          v_why := 'already_returned'; exit rules;
        end if;
        -- M2c-6b-3a-2 (G): a late predecessor booked as its run's payout — a payout cancelled with exactly one payout
        -- booking and no return booked (above) — comes back as that booking's entry reversed (it has no entry of its own)
        if r.tr_status = 'cancelled' and r.tr_kind = 'payout' then
          select count(*), min(k.entry_id::text)::uuid into v_lp_n, v_lp_entry
          from public.bank_line_booking k where k.transfer_id = r.transfer_id and k.kind = 'payout';
          if v_lp_n <> 1 then v_why := 'transfer_cancelled'; exit rules; end if;
          r.tr_entry := v_lp_entry;
          update pg_temp._tl t set tr_entry = v_lp_entry where t.n = r.n;
        elsif r.tr_status = 'cancelled' then
          v_why := 'transfer_cancelled'; exit rules;
        elsif r.tr_status <> 'booked' or r.tr_entry is null
           or not exists (select 1 from public.bank_line_booking k where k.transfer_id = r.transfer_id
                            and k.kind in ('payout', 'sweep')) then
          v_why := 'return_differs'; exit rules;
        end if;
        if r.tr_debtor <> l.bank_account_id or r.tr_currency <> l.currency then
          v_why := 'transfer_differs'; exit rules;
        end if;
        if l.booking_date < (select e.effective_date from public.ledger_entry e where e.id = r.tr_entry) then
          v_why := 'return_before_debit'; exit rules;
        end if;
        if v_class = 'E' and l.amount_minor > r.tr_minor then v_why := 'return_differs'; exit rules; end if;
        if r.amount <> r.tr_minor then v_why := 'amount_differs'; exit rules; end if;
        update pg_temp._tl t set c = r.tr_client, a = r.amount,
          payout_account = case when r.kind = 'payout_returned' then r.run_payout_account end
        where t.n = r.n;

      elsif r.kind in ('unplanned_payout_returned', 'unplanned_sweep_returned') then
        -- §3.4.13 the return of an unplanned booking (S27, S28)
        select q.* into v_x from public.bank_transaction q where q.id = r.returns_line_id;
        if v_x.bank_account_id <> l.bank_account_id or v_x.currency <> l.currency then
          v_why := 'transfer_differs'; exit rules;
        end if;
        if r.transfer_id is not null and r.tr_kind is distinct from
           (case r.kind when 'unplanned_payout_returned' then 'payout' else 'sweep' end) then
          v_why := 'transfer_kind_differs'; exit rules;
        end if;
        select k.entry_id, k.amount_minor, k.transfer_id, e.effective_date, e.client_organization_id
        into v_bk
        from public.bank_line_booking k
        join public.ledger_entry e on e.id = k.entry_id
        where k.bank_transaction_id = r.returns_line_id
          and k.kind = case r.kind when 'unplanned_payout_returned' then 'unplanned_payout' else 'unplanned_sweep' end
          and (k.transfer_id is not distinct from r.transfer_id
               -- review round 2 (ld2-reissue-return-pays-twice): the return of a run's payout closes the unplanned
               -- payout of another transfer of the run's chain (private.transfer_chain_unplanned)
               or (r.kind = 'unplanned_payout_returned' and r.transfer_id is not null
                   and k.transfer_id in (select c from private.transfer_chain_unplanned(r.transfer_id) c)))
          and (r.client_id is null or e.client_organization_id = r.client_id)
        order by k.seq limit 1;
        if v_bk.entry_id is null then v_why := 'transfer_unknown'; exit rules; end if;
        if v_bk.transfer_id is distinct from r.transfer_id then
          update pg_temp._tl t set other_e2e = (select y.end_to_end_id from public.bank_transfer y
                                                where y.id = v_bk.transfer_id)
          where t.n = r.n;
        end if;
        if exists (select 1 from public.ledger_entry z where z.reverses_entry_id = v_bk.entry_id) then
          v_why := 'already_returned'; exit rules;
        end if;
        -- (critic L3) our id, or the bank's own return from the IBAN the unplanned payout went to
        if not (v_class = 'U'
                or (v_class = 'E' and r.transfer_id is not null and v_returned_id = r.tr_e2e)
                or (v_class = 'B' and exists (select 1 from pg_temp._tl_pre p where p.role = 'returnable'
                                                and p.transfer_id = r.transfer_id))
                or (v_kind = 'return' and v_class in ('N', 'O', 'E0') and l.counterparty_iban is not null
                    and l.counterparty_iban = coalesce(r.tr_iban, v_x.counterparty_iban))) then
          v_why := 'not_its_line'; exit rules;
        end if;
        -- (critic F1) of several open unplanned bookings, the one with the largest advance (ties: the earliest line)
        if r.transfer_id is not null or r.kind = 'unplanned_payout_returned' then
          select o.line_id into v_first
          from private.transfer_line_open_unplanned(l.organization_id, r.transfer_id, v_bk.client_organization_id,
                                                    v_x.counterparty_iban,
                                                    case r.kind when 'unplanned_payout_returned' then 'unplanned_payout'
                                                                else 'unplanned_sweep' end) o
          limit 1;
          if v_first is distinct from r.returns_line_id then v_why := 'return_differs'; exit rules; end if;
        end if;
        if l.booking_date < v_bk.effective_date then v_why := 'return_before_debit'; exit rules; end if;
        if exists (select 1 from public.client_advance a
                   join public.commission_settlement s on s.document_kind = 'advance' and s.document_id = a.id
                   where a.cause_entry_id = v_bk.entry_id and a.cause = 'double_payout') then
          v_why := 'advance_settled'; exit rules;
        end if;
        -- (M2c-7b) a run approved or sent takes the advance back: refused until its debit settles it
        if exists (select 1 from public.client_advance a
                   cross join lateral private.advance_in_flight_run(a.id) f
                   where a.cause_entry_id = v_bk.entry_id and a.cause = 'double_payout') then
          v_why := 'advance_in_flight'; exit rules;
        end if;
        -- (M2c-7c-2 review round 1, MONEY-1) a repayment request not withdrawn names the advance: the return would
        -- reverse it while a letter asks the client to repay it (a payout the client did not keep) — refused until the
        -- request is withdrawn (« Retirer la demande »)
        if exists (select 1 from public.client_advance a
                   cross join lateral private.advance_live_request(a.id) q
                   where a.cause_entry_id = v_bk.entry_id and a.cause = 'double_payout') then
          v_why := 'advance_requested'; exit rules;
        end if;
        if r.amount <> v_bk.amount_minor then v_why := 'amount_differs'; exit rules; end if;
        update pg_temp._tl t set c = case when r.kind = 'unplanned_payout_returned' then v_bk.client_organization_id end,
          a = r.amount, ub_entry = v_bk.entry_id,
          ub_adv_entry = (select a.entry_id from public.client_advance a
                          where a.cause_entry_id = v_bk.entry_id and a.cause = 'double_payout'),
          ub_adv_id = (select a.id from public.client_advance a
                       where a.cause_entry_id = v_bk.entry_id and a.cause = 'double_payout'),
          ub_adv = coalesce((select a.amount_minor from public.client_advance a
                             where a.cause_entry_id = v_bk.entry_id and a.cause = 'double_payout'), 0),
          payout_account = case
            when r.kind <> 'unplanned_payout_returned' then null
            when r.transfer_id is not null then r.run_payout_account
            else (select a.id from public.client_payout_account a
                  where a.client_organization_id = v_bk.client_organization_id and a.iban = v_x.counterparty_iban
                    and a.currency = l.currency and a.status = 'active' limit 1) end
        where t.n = r.n;
        update pg_temp._tl t set p = t.a - t.ub_adv, adv = t.ub_adv where t.n = r.n;
      end if;
    end loop;

    -- §3.6.1 P per item (Q4's default; critic F2, F3, F4, F5, L1; critic2 ML-1; review money-2), part by part in their
    -- order: least(A, what the queue nets, the signed net of the items still owed, A less what earlier unreversed
    -- unplanned bookings of the same transfer netted)
    for r in select * from pg_temp._tl t where t.kind = 'unplanned_payout' and t.transfer_id is not null order by t.n loop
      drop table if exists pg_temp._tl_el;
      create temp table _tl_el on commit drop as
      select p.ledger_entry_id as i, q.amount_minor as pend, e.posted_at,
             (select z.id from public.ledger_entry z where z.reverses_entry_id = p.ledger_entry_id) as rev,
             0::bigint as net, 0::bigint as paid
      from pg_temp._tl_pool p
      cross join lateral (select y.amount_minor from private.remittance_pending y
                          where y.ledger_entry_id = p.ledger_entry_id offset 0) q
      cross join lateral (select y.posted_at from public.ledger_entry y where y.id = p.ledger_entry_id offset 0) e
      where p.n = r.n and not private.unplanned_own_item(p.ledger_entry_id);
      -- an item that reverses another pending item of the pool is counted in that item's chain, once
      delete from pg_temp._tl_el a using pg_temp._tl_el b where b.rev = a.i;
      update pg_temp._tl_el e set
        net = e.pend + coalesce((select q.amount_minor from private.remittance_pending q
                                 where q.ledger_entry_id = e.rev), 0),
        paid = coalesce((select sum(u.amount_minor) from private.unplanned_paid_item u
                         where u.ledger_entry_id = e.i
                           and not exists (select 1 from public.ledger_entry z
                                           where z.reverses_entry_id = u.booking_entry_id)), 0)
               + coalesce((select sum(t.amount_minor) from pg_temp._tl_items t where t.ledger_entry_id = e.i), 0)
      where true;  -- every row (pg-safeupdate, as above)
      -- M2c-6b-3a-2 (J; COMPLIANCE OQ-82, Q3 (a)): an item another transfer's late execution already netted — an
      -- unreversed unplanned booking of another transfer attributed it, or an earlier part of this call for another
      -- transfer — is left out (it counts nothing here): its gross left is the commission its run set off, which the
      -- next run on the item takes; netted again it would be taken from the client's other collections, a hold-back
      -- without a clause. The rest of A is the servicer's advance (recovered only under a claw-back clause)
      update pg_temp._tl_el e set paid = greatest(e.net, e.paid)
      where exists (select 1
                    from (select u.booking_entry_id from private.unplanned_paid_item u
                          where u.ledger_entry_id = e.i offset 0) u
                    cross join lateral (select k.transfer_id from public.bank_line_booking k
                                        where k.entry_id = u.booking_entry_id offset 0) k
                    where k.transfer_id is distinct from r.transfer_id
                      and not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = u.booking_entry_id))
         or exists (select 1 from pg_temp._tl_items i join pg_temp._tl t on t.n = i.n
                    where i.ledger_entry_id = e.i and i.amount_minor > 0
                      and t.transfer_id is distinct from r.transfer_id);
      select count(*), greatest(0, coalesce(sum(e.net), 0) - coalesce(sum(e.paid), 0))
      into v_n_el, v_cap from pg_temp._tl_el e;
      -- (review money-2, LT-1) the unreversed unplanned bookings of one transfer together never net more than its amount:
      -- x's amount is all its run would have paid the client of its items (their gross less the commission that run set
      -- off). An item's gross left after a first execution paid x in full is that commission, owed to the servicer by
      -- the next run on the item: netted again, it would be taken from the client's unrelated collections — a hold-back
      -- without a claw-back clause (Q4, founder #7). A second execution of x is then the servicer's advance in full
      v_cap := least(v_cap, greatest(0, r.amount - coalesce((
                 select sum(k.amount_minor - coalesce(a.amount_minor, 0))
                 from (select q.entry_id, q.amount_minor from public.bank_line_booking q
                       where q.transfer_id = r.transfer_id and q.kind = 'unplanned_payout' offset 0) k
                 left join lateral (select y.amount_minor from public.client_advance y
                                    where y.cause_entry_id = k.entry_id and y.cause = 'double_payout' offset 0) a on true
                 where not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = k.entry_id)), 0)));
      v_queue := greatest(0, coalesce((select sum(q.amount_minor) from private.remittance_pending q
                                       where q.organization_id = l.organization_id
                                         and q.client_organization_id = r.tr_client and q.currency = l.currency), 0))
                 - coalesce((select sum(t.p) from pg_temp._tl t
                             where t.n < r.n and t.kind = 'unplanned_payout' and t.c = r.tr_client), 0);
      v_p := greatest(0, least(r.amount, v_queue, v_cap));
      insert into pg_temp._tl_items (n, ledger_entry_id, amount_minor)
      select r.n, z.i, least(z.lft, v_p - z.before)
      from (select e.i, e.net - e.paid as lft,
                   coalesce(sum(e.net - e.paid) over (order by e.posted_at, e.i
                                                     rows between unbounded preceding and 1 preceding), 0) as before
            from pg_temp._tl_el e where e.net - e.paid > 0) z
      where z.before < v_p;
      update pg_temp._tl t set p = v_p, adv = t.a - v_p,
        p_bound = case when v_n_el = 0 then 'none' when v_p = t.a then 'amount' when v_p = v_cap then 'items'
                       else 'queue' end
      where t.n = r.n;
    end loop;

    -- §3.6.5 the drafts: the live run of each client of an unplanned payout or return, re-read here; a draft is
    -- re-prepared; under the locks, a live run the locks did not take is split_changed (critic CSO-12)
    for v_c in select distinct t.c from pg_temp._tl t
               where t.kind in ('unplanned_payout', 'unplanned_payout_returned') and t.c is not null loop
      select y.id, y.status, y.number into v_live_id, v_live_status, v_live_number from public.remittance_run y
      where y.client_organization_id = v_c and y.currency = l.currency and y.status in ('draft', 'approved', 'sent');
      if v_live_id is not null then
        if p_locked and not exists (select 1 from pg_temp._tl_locked_runs k where k.run_id = v_live_id) then
          v_why := 'split_changed'; exit rules;
        end if;
        if v_live_status = 'draft' then
          insert into pg_temp._tl_drafts values (v_live_id, v_live_number, v_c) on conflict do nothing;
        end if;
      end if;
    end loop;
  end rules;

  return jsonb_build_object('why', v_why, 'detail', v_detail);
end;
$$;


-- private.remitted_cover_release, redefined from 20261122090000_remitted_reversals_covered.sql (line 614; same signature
-- and settings, its grants restated below). M2c-7c-2 review round 1 (MONEY-1): refused advance_requested while a
-- repayment request not withdrawn names a cover it would reverse (private.advance_live_request), as advance_in_flight —
-- raised as the command's refusal (SQLSTATE 55000). Nothing else changes.
create or replace function private.remitted_cover_release(p_booking_entry_id uuid, p_line_id uuid, p_on date)
returns integer
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  i record;
  f record;
  a record;
  v_held bigint;
  v_n integer := 0;
  v_k integer := 0;
begin
  perform private.remitted_cover_begin();
  for i in select z.id as reversal_id
           from (select u.ledger_entry_id from private.unplanned_paid_item u
                 where u.booking_entry_id = p_booking_entry_id offset 0) u
           cross join lateral (select z.id from public.ledger_entry z
                               where z.reverses_entry_id = u.ledger_entry_id offset 0) z
           order by z.id loop
    select * into f from private.remitted_cover_fact(i.reversal_id) limit 1;
    if not found or f.held <= f.target then
      continue;
    end if;
    for a in select q.id from public.client_advance q
             where q.cause_entry_id = i.reversal_id and q.cause = 'remitted_reversal'
               and not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = q.entry_id) loop
      if exists (select 1 from public.commission_settlement s where s.document_kind = 'advance'
                   and s.document_id = a.id) then
        raise exception 'transfer line booking refused: advance_settled' using errcode = '55000';
      end if;
      if exists (select 1 from private.advance_in_flight_run(a.id)) then
        raise exception 'transfer line booking refused: advance_in_flight' using errcode = '55000';
      end if;
      -- (M2c-7c-2 review round 1, MONEY-1) a repayment request not withdrawn names the cover: refused until it is
      -- withdrawn (the release would leave a letter asking for a payout the client did not keep)
      if exists (select 1 from private.advance_live_request(a.id)) then
        raise exception 'transfer line booking refused: advance_requested' using errcode = '55000';
      end if;
    end loop;
    v_held := f.held;
    for a in select q.id, q.entry_id, q.amount_minor, e.effective_date
             from public.client_advance q
             join public.ledger_entry e on e.id = q.entry_id
             where q.cause_entry_id = i.reversal_id and q.cause = 'remitted_reversal'
               and not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = q.entry_id)
             order by q.created_at desc, q.id desc loop
      exit when v_held <= f.target;
      perform private.ledger_reverse(a.entry_id, 'return:rr:' || p_line_id || ':' || a.id,
                                     'Avance du cabinet annulée : le virement hors reversement qui avait payé cet '
                                     || 'encaissement est revenu (relevé du ' || to_char(p_on, 'DD/MM/YYYY') || ')',
                                     greatest(p_on, a.effective_date));
      v_held := v_held - a.amount_minor;
      v_n := v_n + 1;
    end loop;
    if v_held < f.target then
      v_k := v_k + 1;
      insert into pg_temp._rcv (n, reversal_id, organization_id, client_organization_id, currency, mandate_id,
                                amount_minor, on_date, idem_key, transfer_id, bank_transaction_id)
      values (v_k, i.reversal_id, f.organization_id, f.client_organization_id, f.currency, f.mandate_id,
              f.target - v_held, greatest(f.reversal_date, coalesce(f.payout_on, f.reversal_date)),
              'adv:' || i.reversal_id || ':rel:' || p_line_id || ':' || p_booking_entry_id, null, p_line_id);
    end if;
  end loop;
  return v_n + private.remitted_cover_post();
end;
$$;


-- (M2c-7c-2 review round 1, MONEY-2; plan §5.2.5, [critic] L16) The advances a dedicated-account line's label
-- designates by naming one of the client's repayment requests (« DRA-2026-000001 »: the reference the letter asks the
-- client to quote; C. civ. 1342-10 al. 1): each request of that client and currency whose number the label names, as a
-- whole token (« DRA-AAAA-N… », its digits all of them: never a prefix of a longer number), issued on or before the
-- line's day (a later one the label cannot name), withdrawn or not (the client names the debt a letter asked for); its
-- advances in the letter's order (their recording, then id). [{number, advance_ids}] by number. Its requests by their
-- number (advance_repayment_request_number_uq), their items by the primary key's prefix, each advance by its key.
create or replace function private.label_requested_advances(p_organization_id uuid, p_client_organization_id uuid,
                                                            p_currency char(3), p_label text, p_on date)
returns jsonb
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select coalesce(jsonb_agg(jsonb_build_object('number', r.number, 'advance_ids', q.advance_ids) order by r.number),
                  '[]')
  from (select distinct m[1] as number
        from regexp_matches(upper(coalesce(p_label, '')), 'DRA-[0-9]{4}-[0-9]{6,}', 'g') m) n
  cross join lateral (select x.id, x.number, x.client_organization_id, x.currency, x.issue_date
                      from public.advance_repayment_request x
                      where x.organization_id = p_organization_id and x.number = n.number offset 0) r
  cross join lateral (select coalesce(jsonb_agg(a.id order by a.created_at, a.id), '[]') as advance_ids
                      from (select i.advance_id from public.advance_repayment_request_item i
                            where i.request_id = r.id offset 0) i
                      cross join lateral (select y.id, y.created_at from public.client_advance y
                                          where y.id = i.advance_id offset 0) a) q
  where r.client_organization_id = p_client_organization_id and r.currency = p_currency and r.issue_date <= p_on;
$$;

-- public.client_payment_line, redefined from 20261124090000_client_payments.sql (line 1722, 7c-1's; same signature and
-- settings, its grants restated below). M2c-7c-2 review round 1 (MONEY-2): what the label designates is also the
-- advances of the client's repayment requests it names by their number (private.label_requested_advances; the 7c-1
-- ADR left the DRA-… numbers to 7c-2), open on the line's day, after the invoices it names; `named_requests` the
-- requests it names (the page words « l'avance du … (demande DRA-…) »). The client's documents read once. Nothing else
-- changes.
create or replace function public.client_payment_line(p_bank_transaction_id uuid, p_documents uuid[] default null,
                                                      p_recover_written_off uuid[] default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  t public.bank_transaction;
  f record;
  v_name text;
  v_named jsonb;
  v_preview jsonb;
  v_docs jsonb;
  v_reqs jsonb;
begin
  select * into t from public.bank_transaction where id = p_bank_transaction_id;
  if not found or not private.has_role(t.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  select * into f from private.client_line_facts(t.id);
  if f.client_id is not null then
    select o.legal_name into v_name from public.organization o where o.id = f.client_id;
    -- (review round 4) only an invoice issued on or before the line's day: the client cannot have designated one that
    -- did not exist (a later one is not the line's to settle: the default order skips it too)
    v_docs := private.client_payment_docs(f.client_id, t.currency, t.booking_date);
    select coalesce(jsonb_agg(x ->> 'id' order by x ->> 'number'), '[]') into v_named
    from jsonb_array_elements(v_docs) x
    where x ->> 'kind' = 'invoice' and (x ->> 'open_on')::boolean
      and position(upper(x ->> 'number') in upper(coalesce(t.remittance_text, ''))) > 0;
    -- (M2c-7c-2 review round 1, MONEY-2) then the advances of the client's repayment requests its label names, open on
    -- the line's day, in the requests' and the letters' order, each once
    v_reqs := private.label_requested_advances(t.organization_id, f.client_id, t.currency, t.remittance_text,
                                               t.booking_date);
    v_named := v_named || coalesce((
      select jsonb_agg(y.id order by y.k)
      from (select a.id, min(r.n * 1000 + a.n) as k
            from jsonb_array_elements(v_reqs) with ordinality r (v, n)
            cross join lateral jsonb_array_elements_text(r.v -> 'advance_ids') with ordinality a (id, n)
            where exists (select 1 from jsonb_array_elements(v_docs) x
                          where x ->> 'id' = a.id and x ->> 'kind' = 'advance' and (x ->> 'open_on')::boolean)
            group by a.id) y), '[]');
    v_preview := public.client_payment_preview(f.client_id, t.currency,
                                               (t.amount_minor / 100)::text || ',' || lpad((t.amount_minor % 100)::text, 2, '0'),
                                               p_documents, p_recover_written_off, t.booking_date);
  end if;
  return jsonb_build_object(
    'bank_transaction_id', t.id, 'client_id', f.client_id, 'client_name', v_name, 'currency', t.currency,
    'amount_minor', t.amount_minor::text, 'booking_date', t.booking_date, 'label', t.remittance_text,
    'named_documents', coalesce(v_named, '[]'), 'named_requests', coalesce(v_reqs, '[]'), 'refusal', f.refusal,
    'preview', v_preview);
end;
$$;


-- public.book_client_payment_line, redefined from 20261124090000_client_payments.sql (line 2046, 7c-1's; same signature
-- and settings, its grants restated below). M2c-7c-2 review round 1 (MONEY-2; plan §5.2.5, [critic] L16): a label
-- naming the number of one of the client's repayment requests (private.label_requested_advances) is the client's
-- designation of that request's advances, as a label naming an invoice's number is of that invoice — no other evidence
-- needed. Nothing else changes.
create or replace function public.book_client_payment_line(p_idempotency_key text, p_bank_transaction_id uuid,
                                                           p_documents uuid[], p_designation_document_id uuid,
                                                           p_recover_written_off uuid[], p_expected_open_text text,
                                                           p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
set enable_seqscan = off
as $$
declare
  t public.bank_transaction;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb;
  v_result jsonb;
  f record;
  v_docs jsonb;
  v_free jsonb;
  v_rec jsonb;
  v_why record;
  v_rows jsonb;
  v_label jsonb;
begin
  select * into t from public.bank_transaction where id = p_bank_transaction_id;
  if not found or not private.has_role(t.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('bank_transaction_id', p_bank_transaction_id, 'documents', p_documents,
                                  'designation_document_id', p_designation_document_id,
                                  'recover_written_off', p_recover_written_off, 'expected_open', p_expected_open_text,
                                  'reason', v_reason);
  v_result := private.command_replay('book_client_payment_line', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'client payment refused: reason_required' using errcode = 'check_violation';
  end if;
  if p_expected_open_text is null or p_expected_open_text !~ '^[0-9]{1,16}$'
     or array_position(p_documents, null) is not null or array_position(p_recover_written_off, null) is not null
     or coalesce(cardinality(p_documents), 0) <> (select count(distinct x) from unnest(p_documents) x)
     or coalesce(cardinality(p_recover_written_off), 0) <> (select count(distinct x) from unnest(p_recover_written_off) x)
  then
    raise exception 'client payment refused: bad_request' using errcode = 'check_violation';
  end if;
  -- [critic] F7: the funds pass's order — the allocation lock, the line, then the remit lock; the facts re-read
  perform private.remittance_command_locks(t.organization_id, false);
  perform 1 from public.bank_transaction x where x.id = t.id for no key update;
  perform private.remittance_command_locks(t.organization_id, true);
  select * into f from private.client_line_facts(t.id);
  if f.refusal is not null then
    raise exception 'client payment refused: %', f.refusal using errcode = 'check_violation';
  end if;
  v_docs := private.client_payment_docs(f.client_id, t.currency, t.booking_date);
  -- (M2c-7c-2 review round 1, MONEY-2) the client's repayment requests its label names
  v_label := private.label_requested_advances(t.organization_id, f.client_id, t.currency, t.remittance_text,
                                              t.booking_date);
  if coalesce(cardinality(p_recover_written_off), 0) > 0
     and (p_designation_document_id is null
          or not private.client_document_of(p_designation_document_id, f.client_id, 'payment_designation_evidence'))
     or coalesce(cardinality(p_documents), 0) > 0
        and (p_designation_document_id is null
             or not private.client_document_of(p_designation_document_id, f.client_id, 'payment_designation_evidence'))
        -- [critic] L16: a label naming each designated invoice by its number is the client's designation
        -- (M2c-7c-2 review round 1, MONEY-2) or an advance of a repayment request it names by its DRA-… number
        and exists (select 1 from unnest(p_documents) n (id)
                    where not exists (select 1 from jsonb_array_elements(v_docs) x
                                      where (x ->> 'id')::uuid = n.id and x ->> 'kind' = 'invoice'
                                        and position(upper(x ->> 'number') in upper(coalesce(t.remittance_text, ''))) > 0)
                      and not exists (select 1 from jsonb_array_elements(v_label) r
                                      cross join lateral jsonb_array_elements_text(r -> 'advance_ids') a (id)
                                      where a.id::uuid = n.id))
  then
    raise exception 'client payment refused: designation_evidence_required' using errcode = 'check_violation';
  end if;
  v_free := private.client_payment_free(v_docs);
  v_rec := private.client_payment_recoveries(f.client_id, t.currency, p_recover_written_off, t.booking_date);
  select * into v_why from private.client_payment_named_refusal(v_docs, p_documents, p_recover_written_off, v_rec);
  if v_why.code is not null then
    raise exception 'client payment refused: %', v_why.code using errcode = 'check_violation',
      detail = coalesce(v_why.detail, '');
  end if;
  if private.client_payment_considered(v_free, p_documents, v_rec) <> p_expected_open_text::bigint then
    raise exception 'client payment refused: open_changed' using errcode = 'check_violation';
  end if;
  v_rows := private.client_payment_rows(v_free, t.amount_minor, p_documents, v_rec,
                                        private.client_proceeding_stands(f.client_id, t.booking_date), t.booking_date);
  v_result := private.client_payment_post(
    'client_payment_dedicated', t.organization_id, f.client_id, t.currency, t.amount_minor, t.booking_date, v_rows,
    v_docs, 'cpayd:' || t.id, 'bank_transaction', t.id::text,
    'Règlement du client reçu sur le compte dédié (le ' || to_char(t.booking_date, 'DD/MM/YYYY') || ')',
    t.bank_account_id);
  insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id, kind, entry_id,
                                        amount_minor, method, reason, decided_by)
  values (t.id, 1, t.organization_id, t.bank_account_id, 'client_payment', (v_result ->> 'entry_id')::uuid,
          t.amount_minor, 'ops', v_reason, auth.uid());
  delete from public.bank_debit_review v where v.bank_transaction_id = t.id;
  perform private.ledger_check_now();
  set constraints public.bank_line_booking_complete immediate;
  set constraints public.bank_line_booking_complete deferred;
  perform private.command_record('book_client_payment_line', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;


------------------------------------------------------------------------------------------
-- Privileges (the new internals revoked; every redefined function's grants restated)
------------------------------------------------------------------------------------------

-- the new internals (PostgreSQL grants EXECUTE to PUBLIC by default): the SECURITY DEFINER paths and checks use them
revoke execute on function private.advance_repayment_request_guard(), private.advance_live_request(uuid),
  private.advance_payout_not_received(uuid), private.advance_repayment_refusal(uuid, uuid, char, date),
  private.advance_repayment_client_refusal(uuid, uuid, char, date), private.advance_reversal_origin(uuid, uuid),
  private.advance_repayment_row(uuid), private.advance_repayment_payload(public.advance_repayment_request, uuid[])
  from public, anon, authenticated, service_role;
-- the worker's: its prepare reads the requested advances; its letter's job reads and records the request
revoke execute on function private.client_requested_advances(uuid, char), private.repayment_request_job(uuid),
  private.repayment_request_document_done(uuid, text, text)
  from public, anon, authenticated;
grant execute on function private.client_requested_advances(uuid, char), private.repayment_request_job(uuid),
  private.repayment_request_document_done(uuid, text, text)
  to service_role;
-- the commands and the reads: authenticated (each checks the caller inside); never anon
revoke execute on function public.advance_repayment_preview(uuid, char, uuid[]),
  public.request_advance_repayment(text, uuid, char, uuid[], text),
  public.withdraw_advance_repayment_request(text, uuid, text), public.client_repayment_requests(uuid)
  from public, anon;
grant execute on function public.advance_repayment_preview(uuid, char, uuid[]),
  public.request_advance_repayment(text, uuid, char, uuid[], text),
  public.withdraw_advance_repayment_request(text, uuid, text), public.client_repayment_requests(uuid)
  to authenticated;

-- (20261114090000) the approval's re-check: internal
revoke execute on function private.remittance_approval_refusal(public.remittance_run, private.remittance_draft, date)
  from public, anon, authenticated;
-- (20261122090000) the advance checks: internal
revoke execute on function private.run_advance_checks(uuid, uuid, date, boolean)
  from public, anon, authenticated, service_role;
-- (20261123090000) one advance as the pages read it: internal
revoke execute on function private.advance_row(uuid) from public, anon, authenticated, service_role;
-- (20261113090000) the storage policy's helper runs as the caller
revoke execute on function private.can_read_remittance_document_object(text) from public, anon, authenticated;
grant execute on function private.can_read_remittance_document_object(text) to authenticated;

-- (review round 1) the label's requests: internal (the dedicated-account line's read and command use it)
revoke execute on function private.label_requested_advances(uuid, uuid, char, text, date)
  from public, anon, authenticated, service_role;
-- (20261123090000) the transfer line's check: internal
revoke execute on function private.transfer_line_check(uuid, boolean) from public, anon, authenticated, service_role;
-- (20261122090000) the release of an unplanned payout's covers: internal
revoke execute on function private.remitted_cover_release(uuid, uuid, date) from public, anon, authenticated, service_role;
-- (20261124090000) the dedicated-account line's read and command: authenticated (each checks the caller inside)
revoke execute on function public.client_payment_line(uuid, uuid[], uuid[]),
  public.book_client_payment_line(text, uuid, uuid[], uuid, uuid[], text, text)
  from public, anon;
grant execute on function public.client_payment_line(uuid, uuid[], uuid[]),
  public.book_client_payment_line(text, uuid, uuid[], uuid, uuid[], text, text)
  to authenticated;
