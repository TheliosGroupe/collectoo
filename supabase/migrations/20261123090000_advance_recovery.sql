-- M2c-7b « claw-back and write-off » (plan docs/design/m2c-7-plan.md §0 #4, §2, §4; design docs/design/m2c-remittances.md
-- §7.2, §9.6, §13; ADR-0014 « M2c-7b »). Forward-only.
--
-- An advance of the servicer (public.client_advance: a remitted reversal's cover, a payout beyond what was owed, a payout
-- executed outside any run) is open for its amount less its settlements, of every kind (a run's compensation, from 7c
-- the client's payments, a write-off), and 0 once its entry is reversed (a cover released, 7a). It belongs to the mandate
-- 7a sets at its insert (the line's, the single mandate of the payout's run, else none), and is recovered:
--   * by a run's settlement plan (the worker's prepare, `run._plan`: its open advances, its queue items in its mandate's
--     money), only under that mandate's claw-back clause (founder #7; a null mandate never: a repayment request, 7c),
--     re-checked at the approval (private.document_open now reads an advance: documents_changed) and posted at the
--     payout's debit (private.post_run_settlements, unchanged: compensation, −4112 Da);
--   * or passed as a loss by an admin, with its evidence (public.write_off_advance: +6780 / −4112[c], never reversed,
--     LG003), never while a run is taking it back (in_flight), and nothing is sent to the client (founder Q5's default:
--     not a remission of the debt; LEX-28: never worded « abandon » or « remise » toward the client).
-- [critic] M7-MONEY-2, F2: an advance an approved or sent run is taking back is never released, reversed or written off
-- under it (private.transfer_line_check's double_payout rule refuses advance_in_flight; 7a's release already does).
-- [critic] M7-MONEY-7, [check 1]: a remitted reversal's cover's queue item counts in its advance's mandate (the line
-- insert guard checks it); review round 1 (M7B-MONEY-1): a double payout's or an overrun's in none, with the rows of
-- no file it pairs with. [critic] F11: the evidence kind advance_write_off_evidence, read by money staff only.
-- Review round 1 (M7B-MONEY-2): how an advance is recovered follows the prepare's rule — one born before the client's
-- proceeding opened is never said to be clawed back (barred_proceeding: private.advance_recovery_of).
-- Review round 2: « Avances » and the client space return each advance's birth (born_on, the date that rule reads)
-- beside its recording date; the worker's prepare reads the client's open advances and its unplanned payouts'
-- attributions through two keyed functions, seq scans off (SWEEP-7B-STATS); private.run_advance_checks is copied from
-- the CI round's body (20261123080000).
--
-- New: private.advance_open, private.advance_mandate, private.advance_born_on, private.mandate_recovery,
-- private.client_opening_on, private.advance_recovery_of, private.advance_recovery, (review round 2) the worker's
-- prepare reads private.client_open_advances and private.unplanned_paid_live,
-- private.commission_settlement_advance_guard (its trigger), public.write_off_advance
-- (« Passer en perte »), public.client_advances (« Avances »), public.client_space_advances (the client space).
-- Redefined, each copied whole from its latest definition across every migration file (the change only, its settings,
-- search_path '' and grants restated): private.document_open (20261112090000:1715), private.item_settled_at
-- (20261122090000:172: the 7a round 3 carry-over), private.run_advance_checks (20261123080000:138),
-- private.remittance_line_insert_guard (20261113090000:1860), private.transfer_line_check (20261119090000:739),
-- public.register_client_document and private.can_read_client_document_object (20261111120000:579, :555) with the
-- policy document_client_money_scope (20261111120000:571), public.allocation_remitted (20261122090000:1111),
-- public.remittance_run_payout (20261122090000:2085). The entry type advance_write_off's label (20261111090000:102).
-- The cancellation-after-download switch stays off: nothing here writes private.feature_switch.

------------------------------------------------------------------------------------------
-- The label of the write-off (plan §4.1, LEX-28): a staff-only book, never « abandon » toward anyone
------------------------------------------------------------------------------------------

update public.ledger_entry_type set label_fr = 'Avance passée en perte' where code = 'advance_write_off';

------------------------------------------------------------------------------------------
-- What is open of an advance, its mandate, its birth, how it is recovered (plan §4.1.1–§4.1.3, §4.1.7)
------------------------------------------------------------------------------------------

-- An advance's open part: 0 once its entry is reversed (a cover released); else its amount less Σ its settlements of
-- every kind (compensation, payment_own, payment_dedicated, write_off). Null for an id that is no advance. Keyed: the
-- advance by its key, its entry's reversal by ledger_entry_reversed_once_uq, its settlements by
-- commission_settlement_document_idx.
create or replace function private.advance_open(p_advance_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select case when exists (select 1 from public.ledger_entry z where z.reverses_entry_id = a.entry_id) then 0::bigint
              else a.amount_minor - coalesce((select sum(s.amount_minor) from public.commission_settlement s
                                              where s.document_id = a.id and s.document_kind = 'advance'), 0)::bigint
         end
  from public.client_advance a where a.id = p_advance_id;
$$;

-- An advance's mandate ([critic] F10): the one 7a sets at its insert — the line's for a remitted reversal's cover, the
-- single mandate of the payout's run for an overrun or a double payout — else none (a run of several mandates, a client
-- part with no transfer, a forward on no file). A null mandate is never clawed back (founder Q2's default).
create or replace function private.advance_mandate(p_advance_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select a.mandate_id from public.client_advance a where a.id = p_advance_id;
$$;

-- When the claim of an advance is born: its entry's effective date ([critic] F3: 7a dates a cover no earlier than the
-- payout it covers, so that date is already the earliest). The prepare filters by it as invoices by their issue date.
create or replace function private.advance_born_on(p_advance_id uuid)
returns date
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select e.effective_date
  from (select a.entry_id from public.client_advance a where a.id = p_advance_id offset 0) a
  cross join lateral (select q.effective_date from public.ledger_entry q where q.id = a.entry_id offset 0) e;
$$;

-- How an advance of a mandate is recovered on p_on: « clawback » when the mandate's terms in force that day hold a
-- claw-back clause (its reference), « request » otherwise (a repayment request, 7c), « request_no_mandate » with no
-- mandate (founder Q2). The worker's prepare reads the same clause (`run._clauses`, the terms in force today).
create or replace function private.mandate_recovery(p_mandate_id uuid, p_on date)
returns table (recovery text, clause_ref text)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select case when p_mandate_id is null then 'request_no_mandate'
              when jsonb_typeof(t.remittance_terms -> 'clawback') = 'object' then 'clawback'
              else 'request' end,
         case when p_mandate_id is not null and jsonb_typeof(t.remittance_terms -> 'clawback') = 'object'
              then t.remittance_terms -> 'clawback' ->> 'clause_ref' end
  from (select 1) one
  left join lateral (select q.remittance_terms from public.mandate_terms q
                     where p_mandate_id is not null and q.mandate_id = p_mandate_id and q.valid_from <= p_on
                       and (q.valid_to is null or p_on < q.valid_to)
                     order by q.valid_from desc limit 1) t on true;
$$;

-- (review round 1, M7B-MONEY-2) The opening of the client's collective proceeding as of p_on: its earliest
-- proceeding_opened event in effect that day (client_status_event_client_idx) — the date the prepare reads
-- (jobs/remittances.py load_facts: proceeding_opened_on), null without one
create or replace function private.client_opening_on(p_client_organization_id uuid, p_on date)
returns date
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select min(e.effective_date) from public.client_status_event e
  where e.client_organization_id = p_client_organization_id and e.kind = 'proceeding_opened' and e.effective_date <= p_on;
$$;

-- (review round 1, M7B-MONEY-2) How an advance of a mandate, born on p_born_on, of a client is recovered on p_on — the
-- prepare's rule, never only the clause: « barred_proceeding » when the client's proceeding opened (as of p_on) after the
-- advance was born (run._advances: not nettable, never set off — L622-7 I as the plan applies it; neither a claw-back
-- nor a request is said, founder Q18's default and OQ-41); else the mandate's (private.mandate_recovery). Every page,
-- the client space and the nightly read it, so none says « reprise » for an advance no run will take.
create or replace function private.advance_recovery_of(p_mandate_id uuid, p_client_organization_id uuid, p_born_on date,
                                                       p_on date)
returns table (recovery text, clause_ref text)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select case when o.opened is not null and p_born_on < o.opened then 'barred_proceeding' else m.recovery end,
         case when o.opened is not null and p_born_on < o.opened then null else m.clause_ref end
  from (select private.client_opening_on(p_client_organization_id, p_on) as opened) o
  cross join lateral private.mandate_recovery(p_mandate_id, p_on) m;
$$;

-- An advance's recovery today (Paris): its mandate's, unless it was born before the client's proceeding opened
create or replace function private.advance_recovery(p_advance_id uuid)
returns table (recovery text, clause_ref text)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select r.recovery, r.clause_ref
  from (select a.id, a.mandate_id, a.client_organization_id from public.client_advance a
        where a.id = p_advance_id offset 0) a
  cross join lateral private.advance_recovery_of(a.mandate_id, a.client_organization_id, private.advance_born_on(a.id),
                                                 private.paris_today()) r;
$$;

-- (review round 2, SWEEP-7B-STATS) The worker's prepare reads (jobs/remittances.py `load_facts`): a client's open
-- advances in a currency, the claw-back's documents — client_advance_client_idx, its conditions outside the fence. A
-- statement of the worker's own session, generic (a prepared statement's, or under stale statistics: client_advance
-- analysed with two clients), was a sequential scan of the whole table; here seq scans are off.
create or replace function private.client_open_advances(p_client_organization_id uuid, p_currency char(3))
returns table (advance_id uuid, mandate_id uuid, cause text, born_on date, created_at timestamptz, open_minor bigint)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select a.id, a.mandate_id, a.cause, private.advance_born_on(a.id), a.created_at, o.open_minor
  from (select q.id, q.mandate_id, q.cause, q.created_at from public.client_advance q
        where q.client_organization_id = p_client_organization_id and q.currency = p_currency offset 0) a
  cross join lateral (select private.advance_open(a.id) as open_minor) o
  where o.open_minor > 0;
$$;

-- (review round 2, SWEEP-7B-STATS) What a run's unplanned payouts paid of its items (review round 1, M7B-MONEY-1):
-- their attributions whose booking is not reversed — the bookings' by the primary key's prefix (booking_entry_id), each
-- reversal by ledger_entry_reversed_once_uq. The worker's own statement, generic under stale statistics, was a
-- sequential scan of private.unplanned_paid_item; here seq scans are off.
create or replace function private.unplanned_paid_live(p_booking_entry_ids uuid[])
returns table (booking_entry_id uuid, ledger_entry_id uuid, amount_minor bigint)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select u.booking_entry_id, u.ledger_entry_id, u.amount_minor
  from (select q.booking_entry_id, q.ledger_entry_id, q.amount_minor from private.unplanned_paid_item q
        where q.booking_entry_id = any(p_booking_entry_ids) offset 0) u
  where not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = u.booking_entry_id);
$$;

------------------------------------------------------------------------------------------
-- document_open reads an advance (plan §4.1.4): the approval's documents_changed re-checks a planned advance settle
------------------------------------------------------------------------------------------

-- private.document_open, redefined from 20261112090000_remittance_runs.sql (line 1715; same signature and settings,
-- its grants restated below): a document's open part — an invoice's TTC not settled; a credit note's refund still
-- owed; (M2c-7b, plan §4.1.4) an advance's (private.advance_open) when no invoice has the id, so the approval's
-- documents_changed re-checks a planned advance settle (it read null and never refused). Nothing else changes.
create or replace function private.document_open(p_document_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select coalesce((select case i.kind
           when 'invoice' then i.ttc_minor - coalesce((select sum(s.amount_minor) from public.commission_settlement s
                                                       where s.document_id = i.id), 0)
           else -i.ttc_minor
                - coalesce((select sum(s.amount_minor) from public.commission_settlement s
                            where s.credit_note_id = i.id), 0)
                - coalesce((select sum(s.amount_minor) from public.commission_settlement s
                            where s.document_id = i.id and s.kind = 'refund'), 0) end
  from public.commission_invoice i where i.id = p_document_id),
    -- (M2c-7b) an advance: its open part
    private.advance_open(p_document_id));
$$;

------------------------------------------------------------------------------------------
-- The settlement guard (plan §4.1.5): defence in depth for every poster (a run's settlements, 7c's payments, write-offs)
------------------------------------------------------------------------------------------

-- For the statement's rows of document_kind advance: the document is an advance of the row's servicer and client whose
-- entry is not reversed, and Σ its settlements (this statement's with the earlier ones) stays within its amount. One
-- keyed lookup per advance of the statement (a run's settlements carry a handful); other rows are not read.
create or replace function private.commission_settlement_advance_guard()
returns trigger
language plpgsql
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_bad text;
begin
  select min(n.document_id::text) into v_bad
  from (select distinct q.document_id, q.organization_id, q.client_organization_id from new_rows q
        where q.document_kind = 'advance') n
  left join lateral (select a.organization_id, a.client_organization_id, a.entry_id from public.client_advance a
                     where a.id = n.document_id offset 0) a on true
  where a.entry_id is null or a.organization_id <> n.organization_id
     or a.client_organization_id <> n.client_organization_id
     or exists (select 1 from public.ledger_entry z where z.reverses_entry_id = a.entry_id);
  if v_bad is not null then
    raise exception 'commission settlement: not an advance of its client, or its advance reversed'
      using errcode = 'check_violation', detail = 'advance ' || v_bad;
  end if;
  select min(n.document_id::text) into v_bad
  from (select distinct q.document_id from new_rows q where q.document_kind = 'advance') n
  cross join lateral (select a.amount_minor from public.client_advance a where a.id = n.document_id offset 0) a
  cross join lateral (select coalesce(sum(s.amount_minor), 0) as settled from public.commission_settlement s
                      where s.document_id = n.document_id and s.document_kind = 'advance') s
  where s.settled > a.amount_minor;
  if v_bad is not null then
    raise exception 'commission settlement: an advance settled beyond its amount'
      using errcode = 'check_violation', detail = 'advance ' || v_bad;
  end if;
  return null;
end;
$$;
create trigger commission_settlement_advance_guard after insert on public.commission_settlement
  referencing new table as new_rows for each statement execute function private.commission_settlement_advance_guard();
alter table public.commission_settlement enable always trigger commission_settlement_advance_guard;

------------------------------------------------------------------------------------------
-- « Passer en perte » (plan §4.1.6; design §5.2; founder Q5's default; D8)
------------------------------------------------------------------------------------------

-- An admin of the advance's servicer at aal2 passes W of an advance as a loss: +6780 W / −4112[c] W (advance_write_off,
-- its document the evidence uploaded for that client — D8: ledger_entry_fund_source requires source_type 'document' —,
-- key awo:<md5 of the idempotency key>, dated Paris today, reason « Avance passée en perte (décision du JJ/MM/AAAA) »;
-- the motif ops type stays in the command record, staff only) and one commission_settlement (document_kind advance, kind
-- write_off, W, no VAT). Never reversed (LG003). Collectoo stops claiming W: nothing is sent to the client (not a
-- remission of the debt). Replay + request hash; the amount in euros (private.euros_to_minor); compare and set on the
-- open the page showed. Locks: the allocation then the remit lock (private.remittance_command_locks), the order every
-- path that settles an advance takes (the approval, the debit). Refusals (« advance write-off refused: <code> »,
-- check_violation): bad_amount, bad_request (the open text), reason_required, not_open, open_changed,
-- amount_exceeds_open, in_flight (an approved or sent run's plan takes it back: its debit settles it,
-- private.advance_in_flight_run; review round 1, tests-ui-5: that run's number in the error's detail, for the sheet),
-- evidence_required. Returns {entry_id, open_after_minor}.
create or replace function public.write_off_advance(p_idempotency_key text, p_advance_id uuid, p_amount_text text,
                                                    p_expected_open_text text, p_reason text,
                                                    p_evidence_document_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  a public.client_advance;
  v_request jsonb;
  v_result jsonb;
  v_amount bigint := private.euros_to_minor(p_amount_text);
  v_open bigint;
  v_today date := private.paris_today();
  v_entry uuid;
  v_run text;
begin
  select * into a from public.client_advance where id = p_advance_id;
  if not found or not private.has_role(a.organization_id, array['admin']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('advance_id', p_advance_id, 'amount', p_amount_text,
                                  'expected_open', p_expected_open_text, 'reason', p_reason,
                                  'evidence_document_id', p_evidence_document_id);
  v_result := private.command_replay('write_off_advance', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_amount is null or v_amount <= 0 then
    raise exception 'advance write-off refused: bad_amount' using errcode = 'check_violation';
  end if;
  if p_expected_open_text is null or p_expected_open_text !~ '^[0-9]{1,16}$' then
    raise exception 'advance write-off refused: bad_request' using errcode = 'check_violation';
  end if;
  if p_reason is null or length(btrim(p_reason)) not between 1 and 2000 then
    raise exception 'advance write-off refused: reason_required' using errcode = 'check_violation';
  end if;
  perform private.remittance_command_locks(a.organization_id, true);
  v_open := private.advance_open(a.id);
  if v_open = 0 then
    raise exception 'advance write-off refused: not_open' using errcode = 'check_violation';
  end if;
  if v_open <> p_expected_open_text::bigint then
    raise exception 'advance write-off refused: open_changed' using errcode = 'check_violation';
  end if;
  if v_amount > v_open then
    raise exception 'advance write-off refused: amount_exceeds_open' using errcode = 'check_violation';
  end if;
  select x.run_number into v_run from private.advance_in_flight_run(a.id) x order by x.run_number limit 1;
  if v_run is not null then
    raise exception 'advance write-off refused: in_flight' using errcode = 'check_violation', detail = v_run;
  end if;
  if p_evidence_document_id is null
     or not private.client_document_of(p_evidence_document_id, a.client_organization_id, 'advance_write_off_evidence') then
    raise exception 'advance write-off refused: evidence_required' using errcode = 'check_violation';
  end if;
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                  client_organization_id, source_type, source_id, reason)
  values (1, a.organization_id, 'advance_write_off', v_today, 'awo:' || md5(p_idempotency_key), a.client_organization_id,
          'document', p_evidence_document_id::text,
          'Avance passée en perte (décision du ' || to_char(v_today, 'DD/MM/YYYY') || ')');
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency) values
    (1, 1, 'servicer_losses', v_amount, a.currency),
    (1, 2, 'client_advance_receivable', -v_amount, a.currency);
  select x.entry_id into v_entry from private.ledger_post_set() x;
  insert into public.commission_settlement (organization_id, client_organization_id, document_kind, document_id,
                                            entry_id, kind, amount_minor, vat_moved_minor, settled_on)
  values (a.organization_id, a.client_organization_id, 'advance', a.id, v_entry, 'write_off', v_amount, 0, v_today);
  perform private.ledger_check_now();
  v_result := jsonb_build_object('entry_id', v_entry, 'open_after_minor', (v_open - v_amount)::text);
  perform private.command_record('write_off_advance', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

------------------------------------------------------------------------------------------
-- « Avances » and the client space (plan §4.1.7, §4.3)
------------------------------------------------------------------------------------------

-- One advance as the pages read it: its client, cause and dates (the recording dates, Paris: §2.1; review round 2,
-- advance-date-contradicts-barred: and its birth, born_on — private.advance_born_on, the date its recovery's barred rule
-- reads —, the advance's date on every page), the file of a remitted collection taken back, its amount, what was
-- recovered by kind and what is open, its mandate, how it is recovered today, the approved or sent run whose plan takes
-- it back
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
                      from private.advance_in_flight_run(a.id) x limit 1))
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

-- « Avances » (Reversements): money staff of the servicer (aal2). Its advances (one client's with p_client), newest first,
-- open ones only by default, keyset-paged by (created_at, id) — p_after the `next` of the previous page —, p_limit a page
-- (1–200); the open total per client and currency (the Reversements cards' chip « Avance à récupérer »); whether the
-- caller may pass one as a loss (an admin). « not allowed » otherwise.
create or replace function public.client_advances(p_organization_id uuid, p_client uuid default null,
                                                  p_open_only boolean default true, p_after jsonb default null,
                                                  p_limit integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_open_only boolean := coalesce(p_open_only, true);
  v_at timestamptz;
  v_id uuid;
  v_rows jsonb;
  v_next jsonb;
begin
  if p_organization_id is null or not private.has_role(p_organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if p_after is not null then
    begin
      v_at := (p_after ->> 'created_at')::timestamptz;
      v_id := (p_after ->> 'id')::uuid;
    exception when others then
      raise exception 'advances: a bad page cursor' using errcode = '22023';
    end;
  end if;
  with page as materialized (
    select a.id, a.created_at, row_number() over (order by a.created_at desc, a.id desc) as n
    from (select q.id, q.created_at from public.client_advance q
          where q.organization_id = p_organization_id
            and (p_client is null or q.client_organization_id = p_client)
            and (v_at is null or (q.created_at, q.id) < (v_at, v_id))
            and (not v_open_only or private.advance_open(q.id) > 0)
          order by q.created_at desc, q.id desc
          limit v_limit + 1) a)
  select coalesce(jsonb_agg(private.advance_row(p.id) order by p.n) filter (where p.n <= v_limit), '[]'),
         (select jsonb_build_object('created_at', x.created_at, 'id', x.id) from page x where x.n = v_limit
          and exists (select 1 from page y where y.n = v_limit + 1))
  into v_rows, v_next
  from page p;
  return jsonb_build_object(
    'rows', v_rows, 'next', v_next,
    'totals', (select coalesce(jsonb_agg(jsonb_build_object('client_id', t.client, 'currency', t.currency,
                                                            'open_minor', t.open_minor::text)
                                         order by t.client, t.currency), '[]')
               from (select q.client_organization_id as client, q.currency, sum(private.advance_open(q.id)) as open_minor
                     from public.client_advance q
                     where q.organization_id = p_organization_id
                       and (p_client is null or q.client_organization_id = p_client)
                     group by q.client_organization_id, q.currency) t
               where t.open_minor > 0),
    'can_write_off', private.has_role(p_organization_id, array['admin']));
end;
$$;

-- The client space (« Reversements »): the client's members with access to the whole client (the client_advance and
-- commission_settlement policies' rule), or money staff of its servicer. Its open advances (oldest first): the recording
-- date and (review round 2, advance-date-contradicts-barred) its birth, born_on — the advance's date the client reads,
-- the one its recovery's barred rule reads —, the cause, what is still to recover, how (the claw-back clause and its
-- reference, a request, or neither for one born before the client's proceeding) — never what was passed as a loss
-- (Collectoo no longer claims it; nothing is sent: founder Q5) — and the open total per currency.
create or replace function public.client_space_advances(p_client_organization_id uuid)
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
  return (
    with o as materialized (
      select a.id, a.currency, a.cause, a.created_at, a.mandate_id, private.advance_open(a.id) as open_minor,
             private.advance_born_on(a.id) as born_on
      from public.client_advance a
      where a.client_organization_id = p_client_organization_id and a.organization_id = v_org)
    select jsonb_build_object(
      'rows', coalesce((select jsonb_agg(jsonb_build_object(
                                 'advance_id', o.id, 'currency', o.currency, 'cause', o.cause,
                                 'created_on', (o.created_at at time zone 'Europe/Paris')::date, 'born_on', o.born_on,
                                 'open_minor', o.open_minor::text, 'recovery', r.recovery, 'clause_ref', r.clause_ref)
                               order by o.created_at, o.id)
                        from o cross join lateral private.advance_recovery_of(o.mandate_id, p_client_organization_id,
                                                                              o.born_on, private.paris_today()) r
                        where o.open_minor > 0), '[]'),
      'total', coalesce((select jsonb_agg(jsonb_build_object('currency', t.currency, 'open_minor', t.s::text)
                                          order by t.currency)
                         from (select o.currency, sum(o.open_minor) as s from o where o.open_minor > 0
                               group by o.currency) t), '[]')));
end;
$$;

------------------------------------------------------------------------------------------
-- Redefinitions (each copied whole from its latest definition, the change only)
------------------------------------------------------------------------------------------

-- private.item_settled_at, redefined from 20261122090000_remitted_reversals_covered.sql (line 172; same signature and
-- settings, its grants restated below). M2c-7b (ADR-0014 7a round 3 « Left open », « The return named for an item
-- its run never carried »): when the item's attributions not netted in its run — those of the unplanned payouts
-- that paid it, live or come back, whose return is not a line of the run itself — cover its line, the run's own
-- payout never carried it: what came back on its way is never the run's (« run »), it is « unplanned » once one of
-- those payouts came back (it stayed « run » while the money waited and once a later run paid it). Nothing else
-- changes.
create or replace function private.item_settled_at(p_entry_id uuid, p_run_id uuid, p_depth integer)
returns table (on_date date, how text, run_number text, too_deep boolean, returned text)
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  s record;
  t record;
  v_z uuid;
  v_y uuid;
  v_all boolean;
  v_deep boolean := false;
  v_followed boolean := false;
  v_date date;
  v_how text;
  v_num text;
  v_ret text;
  v_line bigint;
  v_live bigint;
  v_live_on date;
  v_cov bigint;
begin
  if p_depth > 10 then
    return query select null::date, null::text, null::text, true, null::text;
    return;
  end if;
  select * into s from private.run_settled_at(p_run_id, p_depth) limit 1;
  if not found then
    return;
  end if;
  if s.too_deep then
    return query select null::date, null::text, null::text, true, s.returned;
    return;
  end if;
  v_all := s.on_date is not null;
  v_ret := s.returned;
  -- (M2c-7b) the item's attributions not netted in this run cover its line: the run's own payout never carried
  -- it, so its return is not what came back on the item's way (« unplanned » below, once one of them came back)
  if v_ret = 'run' then
    select q.amount_minor into v_line
    from (select l.amount_minor, l.run_id from public.remittance_line l
          where l.ledger_entry_id = p_entry_id and not l.released offset 0) q
    where q.run_id = p_run_id;
    select coalesce(sum(u.amount_minor), 0) into v_cov
    from (select y.booking_entry_id, y.amount_minor from private.unplanned_paid_item y
          where y.ledger_entry_id = p_entry_id offset 0) u
    where not exists (select 1
                      from (select z.id from public.ledger_entry z
                            where z.reverses_entry_id = u.booking_entry_id offset 0) z
                      cross join lateral (select l.run_id from public.remittance_line l
                                          where l.ledger_entry_id = z.id and not l.released offset 0) l
                      where l.run_id = p_run_id);
    if v_line > 0 and v_cov >= v_line then
      v_ret := null;
    end if;
  end if;
  for v_z in
    select z.id
    from (select u.booking_entry_id from private.unplanned_paid_item u
          where u.ledger_entry_id = p_entry_id offset 0) u
    cross join lateral (select z.id from public.ledger_entry z
                        where z.reverses_entry_id = u.booking_entry_id offset 0) z
  loop
    v_y := null;
    select l.run_id into v_y
    from (select q.run_id from public.remittance_line q where q.ledger_entry_id = v_z and not q.released offset 0) l
    cross join lateral (select x.status from public.remittance_run x where x.id = l.run_id offset 0) x
    where x.status = 'booked';
    if v_y = p_run_id then
      continue;
    end if;
    v_ret := coalesce(v_ret, 'unplanned');
    v_followed := true;
    if v_y is null then
      v_all := false;
      continue;
    end if;
    select * into t from private.item_settled_at(v_z, v_y, p_depth + 1) limit 1;
    if not found or (t.on_date is null and not t.too_deep) then
      v_all := false;
    elsif t.too_deep then
      v_deep := true;
    elsif v_date is null or t.on_date > v_date then
      v_date := t.on_date;
      v_how := t.how;
      v_num := t.run_number;
    end if;
  end loop;
  -- (review round 3) paid in full by unplanned payouts that stayed paid, the run's own payout came back: the item's own
  -- row, never a later run's (it carried the run's net, not this item)
  if not v_followed and (s.on_date is null or s.returned is not null) then
    select q.amount_minor into v_line
    from (select l.amount_minor, l.run_id from public.remittance_line l
          where l.ledger_entry_id = p_entry_id and not l.released offset 0) q
    where q.run_id = p_run_id;
    select coalesce(sum(u.amount_minor), 0), max(b.effective_date) into v_live, v_live_on
    from (select y.booking_entry_id, y.amount_minor from private.unplanned_paid_item y
          where y.ledger_entry_id = p_entry_id offset 0) u
    cross join lateral (select q.effective_date from public.ledger_entry q where q.id = u.booking_entry_id offset 0) b
    where not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = u.booking_entry_id);
    if v_line > 0 and v_live >= v_line then
      return query select v_live_on, 'unplanned'::text, null::text, false, null::text;
      return;
    end if;
  end if;
  if v_deep then
    return query select null::date, null::text, null::text, true, v_ret;
  elsif v_all and v_followed then
    return query select v_date, v_how, v_num, false, v_ret;
  elsif v_all then
    return query select s.on_date, s.how, s.run_number, false, v_ret;
  else
    return query select null::date, null::text, null::text, false, v_ret;
  end if;
end;
$$;

-- private.run_advance_checks, redefined from 20261123080000_cover_reads_by_run_key.sql (line 138, the CI round's body:
-- each booked run's lines by the run's key alone; same signature and settings, its grants restated below; review round
-- 2, REBASE-7B: 7b's copy of 20261122090000's body put the per-run read of every live line back). M2c-7b (plan
-- §4.1.8): advance_open's details say how the advance is recovered (recovery: clawback, request or request_no_mandate —
-- the mandate's terms in force on the day the checks hold the books to). Its codes are unchanged (044 h pins them).
-- Nothing else changes.
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
end;
$$;

-- private.remittance_line_insert_guard, redefined from 20261113090000_remittance_documents.sql (line 1860; same
-- signature and settings, its grants restated below). M2c-7b (plan §4.1.9 [critic] M7-MONEY-7, [check 1]): a line
-- of kind client_advance or client_advance_reversal carries its advance's mandate (client_advance.mandate_id, the
-- advance by its entry, or by the reversed entry for a reversal; none with none): an advance's item counts in its
-- mandate's money, never in another's. Review round 1 (M7B-MONEY-1): only a remitted reversal's cover's (it pairs
-- with R(E) on E's file); a double payout's or an overrun's carries none (it pairs with rows of no file: the
-- unplanned payout's −U, whatever left 4670 in debit), as the prepare writes it (`run._advance_item_mandate`). One
-- keyed lookup per advance line of the statement. Nothing else changes.
create or replace function private.remittance_line_insert_guard()
returns trigger
language plpgsql
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_bad text;
begin
  if exists (select 1 from (select distinct n.run_id, n.organization_id, n.client_organization_id, n.currency
                            from new_rows n) n
             left join lateral (select r.organization_id, r.client_organization_id, r.currency
                                from public.remittance_run r where r.id = n.run_id offset 0) r on true
             where (r.organization_id, r.client_organization_id, r.currency)
                   is distinct from (n.organization_id, n.client_organization_id, n.currency)) then
    raise exception 'remittance line: its run''s servicer, client and currency' using errcode = 'check_violation';
  end if;
  select min(n.run_id || '/' || n.line_no) into v_bad
  from new_rows n
  cross join lateral (
    select coalesce(-sum(p.amount_minor), 0) as owed, min(la.client_organization_id::text) as client,
           min(la.currency) as currency, count(*) as n
    from (select q.amount_minor, q.ledger_account_id from public.ledger_posting q
          where q.entry_id = n.ledger_entry_id offset 0) p
    cross join lateral (select a.client_organization_id, a.currency from public.ledger_account a
                        where a.id = p.ledger_account_id and a.book = 'client_payable' offset 0) la) x
  where x.n = 0 or x.owed <> n.amount_minor or x.client <> n.client_organization_id::text or x.currency <> n.currency;
  if v_bad is not null then
    raise exception 'remittance line %: not the 4670 posting of its entry for the run''s client and currency', v_bad
      using errcode = 'check_violation';
  end if;
  -- (M2c-7b) an advance's item in its advance's mandate
  select min(n.run_id || '/' || n.line_no) into v_bad
  from (select q.run_id, q.line_no, q.kind, q.ledger_entry_id, q.mandate_id from new_rows q
        where q.kind in ('client_advance', 'client_advance_reversal')) n
  cross join lateral (select case when n.kind = 'client_advance' then n.ledger_entry_id
                                  else (select e.reverses_entry_id from public.ledger_entry e
                                        where e.id = n.ledger_entry_id) end as entry_id) k
  -- (review round 1, M7B-MONEY-1) a remitted reversal's cover on its advance's mandate (with R(E)); any other
  -- advance's on none (with the rows of no file it pairs with)
  left join lateral (select case when a.cause = 'remitted_reversal' then a.mandate_id end as mandate_id
                     from public.client_advance a where a.entry_id = k.entry_id offset 0) a
    on true
  where a.mandate_id is distinct from n.mandate_id;
  if v_bad is not null then
    raise exception 'remittance line %: an advance item outside its advance''s mandate', v_bad
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;

-- private.transfer_line_check, redefined from 20261119090000_switch_on_prerequisites_3.sql (line 739; same signature
-- and settings, its grants restated below). M2c-7b (plan §4.1.10 [critic] M7-MONEY-2, F2): the return of an
-- unplanned booking whose double_payout advance an approved or sent run's plan takes back is refused
-- advance_in_flight (private.advance_in_flight_run): that run's settlement is posted at its debit
-- (private.post_run_settlements), which never re-checks the advance — the return would reverse the advance and the
-- debit then post −4112 against nothing; after the debit it is advance_settled, as before. Nothing else changes.
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

-- public.register_client_document (« Joindre un document »), redefined from 20261111120000_identities_terms.sql (line
-- 579; same signature and settings, its grants restated below). M2c-7b (plan §4.1.11 [critic] F11): it also takes
-- the kind advance_write_off_evidence (a write-off's evidence, D8), read by money staff only (the policy
-- document_client_money_scope and private.can_read_client_document_object below). Nothing else changes.
create or replace function public.register_client_document(p_idempotency_key text, p_client_organization_id uuid,
                                                           p_kind text, p_storage_path text, p_file_name text,
                                                           p_sha256 text, p_mime_type text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.organization;
  v_request jsonb := jsonb_build_object('client_organization_id', p_client_organization_id, 'kind', p_kind,
                                        'storage_path', p_storage_path, 'file_name', p_file_name,
                                        'sha256', lower(p_sha256), 'mime_type', p_mime_type);
  v_result jsonb;
  v_id uuid;
begin
  select * into c from public.organization where id = p_client_organization_id;
  if c.id is null or c.servicer_organization_id is null
     or not private.has_role(c.servicer_organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('register_client_document', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if p_kind is null or p_kind not in ('payout_rib', 'mandate_document', 'client_status_evidence',
                                     'advance_write_off_evidence') then
    raise exception 'document: invalid kind' using errcode = 'check_violation';
  end if;
  if p_sha256 is null or p_sha256 !~ '^[0-9a-fA-F]{64}$' or p_file_name is null
     or length(p_file_name) not between 1 and 255 or p_file_name ~ '[/\\[:cntrl:]]'
     or p_mime_type is null or p_mime_type not in ('application/pdf', 'image/png', 'image/jpeg') then
    raise exception 'document: invalid file' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from private.client_document_key(p_storage_path) k
                 where k.servicer_id = c.servicer_organization_id and k.client_id = c.id) then
    raise exception 'document: the file is not at a key of this client' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'documents' and o.name = p_storage_path) then
    raise exception 'document: the file is not uploaded yet' using errcode = 'check_violation';
  end if;
  insert into public.document (organization_id, client_organization_id, kind, storage_bucket, storage_path, sha256,
                               mime_type, file_name)
  values (c.servicer_organization_id, c.id, p_kind, 'documents', p_storage_path, lower(p_sha256), p_mime_type,
          p_file_name)
  returning id into v_id;
  v_result := jsonb_build_object('document_id', v_id);
  perform private.command_record('register_client_document', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- private.can_read_client_document_object (the storage policy's), redefined from 20261111120000_identities_terms.sql
-- (line 555; same signature and settings, its grants restated below). M2c-7b ([critic] F11): the file of a
-- write-off's evidence too, for whom private.can_read_client_document allows (money staff only). Nothing else
-- changes.
create or replace function private.can_read_client_document_object(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.document d
                 where d.storage_bucket = 'documents' and d.storage_path = p_name
                   and d.kind in ('payout_rib', 'mandate_document', 'client_status_evidence',
                                  'advance_write_off_evidence')
                   and private.can_read_client_document(d.organization_id, d.client_organization_id, d.kind));
$$;

-- the policy document_client_money_scope, recreated from 20261111120000_identities_terms.sql (line 571) with the kind
-- advance_write_off_evidence (plan §4.1.11 [critic] F11): document_read lets every staff member and every member of the
-- client read its documents; these kinds are narrower — money staff only, or for the RIB and the mandate the client's
-- administrators too (private.can_read_client_document, unchanged: it gives every other kind to money staff only)
drop policy document_client_money_scope on public.document;
create policy document_client_money_scope on public.document as restrictive for select to authenticated
  using (kind not in ('payout_rib', 'mandate_document', 'client_status_evidence', 'advance_write_off_evidence')
         or private.can_read_client_document(organization_id, client_organization_id, kind));

-- public.allocation_remitted (the « Désimputer » read), redefined from 20261122090000_remitted_reversals_covered.sql
-- (line 1111; same signature and settings, its grants restated below). M2c-7b (plan §4.3 [critic] L19 (d)): each
-- entry also says how the advance its reversal would post is recovered — recovery and clause_ref of its cover's
-- mandate (the line's, else its file's: private.remitted_cover_fact's rule) on the terms in force today. Nothing
-- else changes.
create or replace function public.allocation_remitted(p_payment_id uuid)
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
  select q.organization_id into v_org from public.payment q where q.id = p_payment_id;
  if v_org is null or not private.has_role(v_org, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'entry_id', e.id, 'account_id', e.account_id, 'run_number', x.run_number,
             'run_transfer', r.transfer_id is not null, 'booked_on', x.booked_on,
             'amount_minor', x.amount_minor::text, 'paid_on', x.paid_on, 'paid_how', x.paid_how,
             'paid_run_number', x.paid_run_number, 'returned_via', x.returned_via,
             'recovery', rc.recovery, 'clause_ref', rc.clause_ref) order by e.effective_date, e.id),
                    '[]')
    from (select q.id, q.account_id, q.effective_date, q.portfolio_id, q.client_organization_id from public.ledger_entry q
          where q.payment_id = p_payment_id and q.entry_type in ('allocation', 'forward') offset 0) e
    cross join lateral private.entry_remitted(e.id) x
    cross join lateral (select q.transfer_id from public.remittance_run q where q.id = x.run_id offset 0) r
    -- (review round 1, M7B-MONEY-2) the cover would be born greatest(its reversal's date — « Désimputer » reverses at
    -- the allocation's own date —, the payout it covers): barred_proceeding when that is before the client's opening
    cross join lateral private.advance_recovery_of(
      coalesce(x.mandate_id, (select pf.mandate_id from public.portfolio pf where pf.id = e.portfolio_id)),
      e.client_organization_id, greatest(e.effective_date, x.booked_on), private.paris_today()) rc
    where not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = e.id));
end;
$$;

-- public.remittance_run_payout (the run page's read), redefined from 20261122090000_remitted_reversals_covered.sql
-- (line 2085; same signature and settings, its grants restated below). M2c-7b (plan §4.3): each advance of the
-- chain's payout also gives its id, its open part (private.advance_open: 0 once reversed), whether its entry is
-- reversed, what was passed as a loss and how the rest is recovered (recovery, clause_ref), so the page words it.
-- Nothing else changes.
create or replace function public.remittance_run_payout(p_run_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  r public.remittance_run;
begin
  select * into r from public.remittance_run where id = p_run_id;
  if not found or not (r.organization_id = any (private.money_staff_org_ids())) then
    return null;
  end if;
  return jsonb_build_object(
    'transfers', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', x.id, 'status', x.status, 'end_to_end_id', x.end_to_end_id, 'amount_minor', x.amount_minor::text,
               'debited_on', d.booking_date, 'returned_on', rt.booking_date, 'line_id', d.line_id,
               'return_line_id', rt.line_id, 'repaid_by', p.number,
               -- M2c-6b-3a-2 (F): a payout cancelled and booked as its run's payout (the late predecessor)
               'late_predecessor', x.status = 'cancelled' and d.line_id is not null) order by c.depth), '[]')
      from private.transfer_chain(r.transfer_id) c
      cross join lateral (select y.id, y.status, y.end_to_end_id, y.amount_minor, y.return_entry_id
                          from public.bank_transfer y where y.id = c.transfer_id offset 0) x
      left join lateral (select l.booking_date, l.id as line_id
                         from (select k.bank_transaction_id, k.kind from public.bank_line_booking k
                               where k.transfer_id = x.id offset 0) k
                         cross join lateral (select q.id, q.booking_date from public.bank_transaction q
                                             where q.id = k.bank_transaction_id offset 0) l
                         where k.kind in ('payout', 'sweep')
                         order by l.booking_date limit 1) d on true
      left join lateral (select l.booking_date, l.id as line_id, k.entry_id
                         from (select k.bank_transaction_id, k.kind, k.entry_id from public.bank_line_booking k
                               where k.transfer_id = x.id offset 0) k
                         cross join lateral (select q.id, q.booking_date from public.bank_transaction q
                                             where q.id = k.bank_transaction_id offset 0) l
                         where k.kind in ('payout_returned', 'sweep_returned')
                         order by l.booking_date limit 1) rt on true
      -- a returned payout paid again: the booked run whose live line holds the payout_returned item its return put
      -- back (as client_remittance_summary's repaid_by)
      left join lateral (select y.number
                         -- M2c-6b-3a-2 (F): a late predecessor's return entry is its return booking's
                         from (select l.run_id from public.remittance_line l
                               where l.ledger_entry_id = coalesce(x.return_entry_id, rt.entry_id) and not l.released
                                 and l.kind = 'payout_returned' offset 0) l
                         cross join lateral (select q.number, q.status from public.remittance_run q
                                             where q.id = l.run_id offset 0) y
                         where y.status = 'booked' limit 1) p on true),
    'payout_account_blocked', coalesce((select a.status = 'returned' from public.client_payout_account a
                                        where a.id = r.payout_account_id), false),
    'settled_on', (select e.effective_date from public.ledger_entry e
                   where e.organization_id = r.organization_id and e.idempotency_key = 'settle:' || r.id),
    'settlement_minor', coalesce(r.settlement_minor, 0)::text,
    'commission_minor', coalesce(r.commission_taken_minor, 0)::text,
    'advances_recovered_minor', coalesce(r.advance_recovered_minor, 0)::text,
    'advances', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'advance_id', a.id, 'cause', a.cause, 'amount_minor', a.amount_minor::text,
               -- (M2c-7b) its open part, its reversal, what was passed as a loss, how the rest is recovered
               'open_minor', private.advance_open(a.id)::text,
               'reversed', exists (select 1 from public.ledger_entry z where z.reverses_entry_id = a.entry_id),
               'written_off_minor', coalesce(s.written_off, 0)::text, 'recovery', rc.recovery,
               'clause_ref', rc.clause_ref,
               'created_on', (a.created_at at time zone 'Europe/Paris')::date) order by a.created_at, a.id), '[]')
      from private.transfer_chain(r.transfer_id) c
      -- M2c-7a ([critic] F5): the advances posted for this chain's payout, by client_advance_transfer_idx — its overrun
      -- (payout_overrun) and the covers of its reversed collections (remitted_reversal: at the booking, or at a later
      -- reversal of a line it paid), each worded by its cause on the run page
      cross join lateral (select q.* from public.client_advance q
                          where q.transfer_id = c.transfer_id and q.cause in ('payout_overrun', 'remitted_reversal')
                          offset 0) a
      left join lateral (select sum(z.amount_minor) filter (where z.kind = 'write_off') as written_off
                         from public.commission_settlement z
                         where z.document_kind = 'advance' and z.document_id = a.id) s on true
      cross join lateral private.advance_recovery_of(a.mandate_id, a.client_organization_id,
                                                     private.advance_born_on(a.id), private.paris_today()) rc),
    'unplanned', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'line_id', k.bank_transaction_id, 'kind', k.kind, 'amount_minor', k.amount_minor::text,
               'on', l.booking_date, 'paid_minor', (k.amount_minor - coalesce(a.amount_minor, 0))::text,
               -- review round 1 (pages-texts-5): a late predecessor (booked as the run's payout) executed again is
               -- a second execution, not one after the cancellation
               'advance_minor', coalesce(a.amount_minor, 0)::text,
               'after_cancellation', x.status = 'cancelled'
                                     and not exists (select 1 from public.bank_line_booking z
                                                     where z.transfer_id = x.id and z.kind = 'payout'),
               'returned', exists (select 1 from public.ledger_entry z where z.reverses_entry_id = k.entry_id))
               -- review round 2: closed by the return of another transfer of the chain (its reference; key only then)
               || coalesce((select jsonb_build_object('returned_by_end_to_end_id', y.end_to_end_id)
                            from (select z.id from public.ledger_entry z where z.reverses_entry_id = k.entry_id
                                  offset 0) z
                            cross join lateral (select q.transfer_id from public.bank_line_booking q
                                                where q.entry_id = z.id offset 0) q
                            cross join lateral (select y.end_to_end_id from public.bank_transfer y
                                                where y.id = q.transfer_id offset 0) y
                            where q.transfer_id is distinct from x.id), '{}'::jsonb)
               order by l.booking_date, k.bank_transaction_id), '[]')
      from private.transfer_chain(r.transfer_id) c
      cross join lateral (select y.id, y.status from public.bank_transfer y where y.id = c.transfer_id offset 0) x
      cross join lateral (select q.bank_transaction_id, q.kind, q.amount_minor, q.entry_id from public.bank_line_booking q
                          where q.transfer_id = x.id offset 0) k
      cross join lateral (select q.booking_date from public.bank_transaction q
                          where q.id = k.bank_transaction_id offset 0) l
      left join lateral (select q.amount_minor from public.client_advance q
                         where q.cause_entry_id = k.entry_id and q.cause = 'double_payout' offset 0) a on true
      where k.kind = 'unplanned_payout'),
    -- (review 6b-2c money-4) what the draft deducts of each unplanned booking: the net of that booking's own rows it
    -- holds — its −A row and its double_payout advance's +(A − P) row (private.unplanned_own_item's two), that is P;
    -- a booking whose rows net to nothing (P = 0) is not listed
    'draft_unplanned', case when r.status = 'draft' then (
      select coalesce(jsonb_agg(jsonb_build_object(
               'amount_minor', (-(q.amount_minor + coalesce(av.amount_minor, 0)))::text, 'on', l.booking_date,
               'line_id', k.bank_transaction_id, 'statement_on', s.to_date)
               order by l.booking_date, k.bank_transaction_id), '[]')
      from (select y.ledger_entry_id, y.amount_minor from private.remittance_pending y
            where y.draft_run_id = r.id and y.kind = 'unplanned_payout' offset 0) q
      cross join lateral (select z.bank_transaction_id from public.bank_line_booking z
                          where z.entry_id = q.ledger_entry_id and z.kind = 'unplanned_payout' offset 0) k
      left join lateral (select sum(y.amount_minor) as amount_minor
                         from (select a.entry_id from public.client_advance a
                               where a.cause_entry_id = q.ledger_entry_id and a.cause = 'double_payout' offset 0) a
                         cross join lateral (select y.amount_minor from private.remittance_pending y
                                             where y.ledger_entry_id = a.entry_id and y.draft_run_id = r.id
                                             offset 0) y) av on true
      cross join lateral (select z.booking_date, z.statement_id from public.bank_transaction z
                          where z.id = k.bank_transaction_id offset 0) l
      left join lateral (select z.to_date from public.bank_statement z where z.id = l.statement_id offset 0) s on true
      where q.amount_minor + coalesce(av.amount_minor, 0) <> 0)
      else '[]'::jsonb end);
end;
$$;

------------------------------------------------------------------------------------------
-- Privileges (the new internals revoked; every redefined function's grants restated)
------------------------------------------------------------------------------------------

-- the new internals (PostgreSQL grants EXECUTE to PUBLIC by default): the SECURITY DEFINER paths and checks use them
revoke execute on function private.advance_open(uuid), private.advance_mandate(uuid), private.advance_born_on(uuid),
  private.mandate_recovery(uuid, date), private.client_opening_on(uuid, date),
  private.advance_recovery_of(uuid, uuid, date, date), private.advance_recovery(uuid), private.advance_row(uuid),
  private.commission_settlement_advance_guard()
  from public, anon, authenticated, service_role;
-- the worker's prepare reads the open advances (its facts) and its tests the predicates
grant execute on function private.advance_open(uuid), private.advance_mandate(uuid), private.advance_born_on(uuid)
  to service_role;
-- (review round 2) the worker's prepare reads: the worker's only
revoke execute on function private.client_open_advances(uuid, char), private.unplanned_paid_live(uuid[])
  from public, anon, authenticated;
grant execute on function private.client_open_advances(uuid, char), private.unplanned_paid_live(uuid[])
  to service_role;
-- the commands and the reads: authenticated (each checks the caller inside); never anon
revoke execute on function public.write_off_advance(text, uuid, text, text, text, uuid),
  public.client_advances(uuid, uuid, boolean, jsonb, integer), public.client_space_advances(uuid)
  from public, anon;
grant execute on function public.write_off_advance(text, uuid, text, text, text, uuid),
  public.client_advances(uuid, uuid, boolean, jsonb, integer), public.client_space_advances(uuid)
  to authenticated;

-- the redefined, as their latest migrations left them
-- (20261112090000) document_open: the worker's (the prepare's facts), never a client role's
revoke execute on function private.document_open(uuid) from public, anon, authenticated;
grant execute on function private.document_open(uuid) to service_role;
-- (20261122090000) the item's settlement and the advance checks: internal
revoke execute on function private.item_settled_at(uuid, uuid, integer),
  private.run_advance_checks(uuid, uuid, date, boolean)
  from public, anon, authenticated, service_role;
-- (20261113090000) the line insert guard: a trigger's
revoke execute on function private.remittance_line_insert_guard() from public, anon, authenticated;
-- (20261119090000) the transfer line's check: internal
revoke execute on function private.transfer_line_check(uuid, boolean) from public, anon, authenticated, service_role;
-- (20261111120000) « Joindre un document » and the storage policy's helper
revoke execute on function public.register_client_document(text, uuid, text, text, text, text, text) from public, anon;
grant execute on function public.register_client_document(text, uuid, text, text, text, text, text) to authenticated;
revoke execute on function private.can_read_client_document_object(text) from public, anon, authenticated;
grant execute on function private.can_read_client_document_object(text) to authenticated;
-- (20261122090000) the « Désimputer » read and the run page's
revoke execute on function public.allocation_remitted(uuid), public.remittance_run_payout(uuid) from public, anon;
grant execute on function public.allocation_remitted(uuid), public.remittance_run_payout(uuid) to authenticated;
