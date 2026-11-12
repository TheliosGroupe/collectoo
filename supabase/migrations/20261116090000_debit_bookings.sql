-- M2c-6b-1 Bookings core (design docs/design/m2c-remittances.md §5, §7, §12, §13, §15; plan docs/design/m2c-6b-plan.md
-- §1.2 row 6b-1, §2.1–§2.5, §4, the « [critic] » changes included; ADR-0014 « M2c-6b-1 »). The debits of our transfers
-- are booked from the imported statements — the bank's facts, never a file's generation, download or upload:
--   * a payout debited under its own RMT id (or in a batch line of its PmtInf): the `remittance` (+4670[c] N / −5120 N)
--     and the run's `client_settlement` (its plan, at the debit date: the commission set off, its VAT due), then the
--     booking-time cover — a `client_advance` (cause `payout_overrun`) when the payout went beyond what the client is
--     owed (a collection reversed since the approval), so a client's 4670 is never in debit (LG008) and no other
--     client's money is used; the transfer and its run `booked`; an R124-6 breach row per item debited after its date;
--   * the sweep debited under its SWP id (or as its PmtInf's line, to the own IBAN): the `servicer_sweep`;
--   * a batch line (no end-to-end id, the PmtInfId of one of our files): one entry set per member of that PmtInf in its
--     current file, all of them in_file, none cancelled, of one kind, adding up exactly — otherwise ops (never a
--     « best subset »); a PmtInf holding one refund alone is the M2b refund link (private.debit_candidates);
--   * a credit returning one of our payouts or sweeps (its RMT/SWP id): the reversal of its entry at the return date
--     (a `payout_returned` item queued by the 4670 trigger, the settlement kept, §9.7), the difference with a bank
--     charge as a `bank_fee` on the same line, the run's payout account `returned`;
--   * never automatically: a debit of a cancelled transfer (`cancelled_transfer_debited`, batch lines that can hold one
--     included), a second debit (`transfer_debited_twice`), a debit of a transfer never handed out
--     (`transfer_not_handed_out`): reviews and P0 alerts; ops book them in M2c-6b-2.
-- The funds pass runs in its own transaction (the worker's `process_debits` sends `funds_after: null`), so its lock
-- order — runs → payout accounts → bank accounts → allocation lock → bank lines → remit lock → files → transfers — is
-- never entered with the allocation lock already held by the M2b pass (plan §2.5 [critic]: a deadlock with
-- transfer_file_download, cancel_remittance_run and the cancellations, which hold a run row and then wait for it).
-- Cancellation after download stays OFF (private.feature_switch; pgTAP 033 and 034 unchanged).
--
-- New: public.client_advance (§6.1; append-only), private.post_run_settlements (set-based twin of
-- private.post_run_settlement), private.transfer_late_lines. bank_line_booking: kinds unplanned_sweep and
-- sweep_returned, seq widened, a transfer booked once and returned once (two partial unique indexes: I20).
-- Redefined, with their settings and grants restated (each from the file named): public.generate_transfer_file
-- (20261115090000: one PmtInf per kind — payouts, refunds, the sweep), private.bank_booking_begin,
-- private.bank_booking_post_rows, private.post_bank_bookings, private.apply_bank_bookings, private.bank_line_booking_guard,
-- private.bank_line_booking_check (signed, on the line's last booking), private.debit_candidates,
-- private.post_debit_links, public.debit_queue (all 20261111090000), private.bank_booking_candidates (20261111090000,
-- dropped and created: new columns), private.run_payment_checks, private.pending_item_deadlines (20261112090000),
-- private.run_remittance_runs_checks (the M2c-5b body of 20261114090000, renamed by 20261115090000),
-- private.run_transfer_checks (20261115090000), public.accounting_export_entries (20261113090000).
--
-- Review round 1: our payouts' and sweeps' lines are never a payment's return, a refund or a refund that came back, nor
-- explained (`own_transfer_line`, every link kind: a batch line takes only a refund whose transfer is in a file handed
-- out, its own trigger admitting only its own PmtInf; debit_queue returns the line's PmtInfId); a
-- returned payout paid again keeps its date and its breach rows say so (`payout_returned`, private.remittance_late_lines
-- redefined from 20261112090000); an in-flight payout is proven unpaid only with no line that could still be its debit
-- (private.transfer_debit_may_be_seen); the payments a booking's breach rows name are key-share locked before the
-- allocation lock; a return dated before its debit is reviewed `return_before_debit`; I20's refund rule is keyed
-- (private.refund_debit_links, bank_debit_link_refund_request_idx); the client's summary lists its runs whose payout
-- came back (public.client_remittance_summary, redefined from 20261113090000).

------------------------------------------------------------------------------------------
-- Schema
------------------------------------------------------------------------------------------

-- An advance to a client (§6.1, §13): the servicer's money paying what the client was not owed (yet). M2c-6b-1 posts
-- the booking-time cover of a payout overrun (cause `payout_overrun`); M2c-6b-2 the excess of an unplanned or double
-- payout (`double_payout`); M2c-7 the cover of a remitted reversal (`remitted_reversal`). Its entry is the M2c-1
-- `client_advance` type (+4679 A / −4670[c] A ‖ +4112[c] A / −4689 A), whose document is this row (R123-174). Its open
-- amount comes from its settlements (commission_settlement document_kind 'advance'; M2c-7's claw-back). Append-only.
create table public.client_advance (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  mandate_id uuid references public.mandate (id),
  currency char(3) not null references public.currency (code),
  amount_minor bigint not null check (amount_minor > 0 and amount_minor <= 1000000000000000),
  cause text not null check (cause in ('remitted_reversal', 'payout_overrun', 'double_payout')),
  cause_entry_id uuid not null references public.ledger_entry (id),   -- the payout (remittance) or reversal it covers
  entry_id uuid not null unique references public.ledger_entry (id),
  bank_transaction_id uuid references public.bank_transaction (id),  -- the bank line it was posted at
  transfer_id uuid references public.bank_transfer (id),              -- the payout it covers
  top_up_transfer_id uuid references public.bank_transfer (id),       -- M2c-7: the top-up ordered for it
  created_at timestamptz not null default clock_timestamp()
);
create index client_advance_client_idx on public.client_advance (client_organization_id, currency, created_at);
create index client_advance_org_idx on public.client_advance (organization_id, created_at desc);
create index client_advance_transfer_idx on public.client_advance (transfer_id) where transfer_id is not null;
comment on table public.client_advance is
  'Advances of the servicer to a client (design §6.1, §13): a payout beyond what the client was owed, a double payout, '
  'a remitted collection reversed. Append-only; its entry is a client_advance entry of that client for its amount.';

-- An advance is the client_advance entry of its client for its amount on 4112 (its document is this row), of a client
-- of the servicer, covering an entry of the servicer. One keyed lookup per row.
create or replace function private.client_advance_guard()
returns trigger
language plpgsql
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
as $$
declare v_bad text;
begin
  select min(n.id::text) into v_bad
  from new_rows n
  left join lateral (select e.organization_id, e.client_organization_id, e.entry_type, e.source_type, e.source_id
                     from public.ledger_entry e where e.id = n.entry_id offset 0) e on true
  left join lateral (select coalesce(sum(p.amount_minor), 0) as advanced
                     from (select q.amount_minor, q.ledger_account_id from public.ledger_posting q
                           where q.entry_id = n.entry_id offset 0) p
                     cross join lateral (select la.book, la.client_organization_id, la.currency
                                         from public.ledger_account la where la.id = p.ledger_account_id offset 0) la
                     where la.book = 'client_advance_receivable' and la.client_organization_id = n.client_organization_id
                       and la.currency = n.currency) x on true
  where e.entry_type is distinct from 'client_advance' or e.organization_id is distinct from n.organization_id
     or e.client_organization_id is distinct from n.client_organization_id
     or e.source_type is distinct from 'client_advance' or e.source_id is distinct from n.id::text
     or x.advanced <> n.amount_minor
     or not exists (select 1 from public.organization c where c.id = n.client_organization_id
                      and c.servicer_organization_id = n.organization_id)
     or not exists (select 1 from public.ledger_entry c where c.id = n.cause_entry_id
                      and c.organization_id = n.organization_id);
  if v_bad is not null then
    raise exception 'client advance %: not the client_advance entry of its client for its amount', v_bad
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;
create trigger client_advance_guard after insert on public.client_advance
  referencing new table as new_rows for each statement execute function private.client_advance_guard();
alter table public.client_advance enable always trigger client_advance_guard;
create trigger client_advance_append_only before update or delete or truncate on public.client_advance
  for each statement execute function private.refuse_change();
alter table public.client_advance enable always trigger client_advance_append_only;
alter table public.client_advance enable row level security;
revoke all on public.client_advance from public, anon, authenticated;
grant select on public.client_advance to authenticated, service_role;
-- money staff; the client's members with access to the whole client (§6.2, OQ-48 default)
create policy client_advance_read on public.client_advance for select to authenticated using (
  organization_id = any ((select private.money_staff_org_ids())::uuid[])
  or client_organization_id = any ((select private.client_whole_org_ids())::uuid[]));

-- Bank line bookings (M2c-1): the sweep's unplanned booking and its return (M2c-6b-2 books them by ops); a line holds as
-- many bookings as its batch has members (the scale target's 5,000-member line: seq no longer capped at 100). I20: a
-- transfer is booked once (its debit) and returned once — two partial unique indexes, so that a payout's return
-- booking does not collide with its debit booking (plan §2.1 [critic]); the unplanned kinds may repeat.
alter table public.bank_line_booking drop constraint bank_line_booking_kind_check,
  add constraint bank_line_booking_kind_check check (kind in ('payout', 'sweep', 'top_up', 'payout_returned',
    'sweep_returned', 'unplanned_payout', 'unplanned_sweep', 'fee', 'loss', 'client_payment'));
alter table public.bank_line_booking drop constraint bank_line_booking_seq_check;
alter table public.bank_line_booking alter column seq type integer;
alter table public.bank_line_booking add constraint bank_line_booking_seq_check check (seq >= 1);
create unique index bank_line_booking_debit_uq on public.bank_line_booking (transfer_id)
  where kind in ('payout', 'sweep', 'top_up');
create unique index bank_line_booking_return_uq on public.bank_line_booking (transfer_id)
  where kind in ('payout_returned', 'sweep_returned');
comment on table public.bank_line_booking is
  'Entries of the funds a bank line was booked by: fees, top-ups, the servicer''s losses, payouts, sweeps, their '
  'returns (M2c-6b), unplanned payouts and sweeps (ops).';

-- Why the job leaves one of our transfer lines to ops (plan §2.3): a debit of a cancelled transfer, a second debit, a
-- debit of a transfer never handed out, an id or amount we cannot place, a run not in flight, a batch line that does
-- not add up or mixes kinds, a return larger than the payout or before its debit.
alter table public.bank_debit_review drop constraint bank_debit_review_reason_check,
  add constraint bank_debit_review_reason_check check (reason in ('no_candidate', 'ambiguous', 'amount_differs',
    'partial_return', 'refund_not_pending', 'already_returned', 'changed', 'payment_returned', 'before_previous_return',
    'posting_failed', 'top_up_not_found', 'top_up_differs', 'client_credit', 'own_transfer_out',
    'cancelled_transfer_debited', 'transfer_debited_twice', 'transfer_not_handed_out', 'transfer_unknown',
    'transfer_differs', 'run_not_in_flight', 'batch_partial', 'batch_mixed', 'return_differs', 'return_before_debit'));

-- R124-6 (Q7's default, COMPLIANCE OQ-36): an item re-proposed after its payout came back keeps its lines' deadline and
-- its breach is recorded « bloqué : virement revenu impayé ».
alter table public.remittance_deadline_breach drop constraint remittance_deadline_breach_blocked_reason_check,
  add constraint remittance_deadline_breach_blocked_reason_check
    check (blocked_reason in ('unmeetable_delay', 'payout_returned'));

-- Keyed probes (ARCHITECTURE §4; plan §2.1 [critic]): the cancelled transfers that were in a file (the alerts' source),
-- the batch lines (debit, no end-to-end id, a PmtInfId) and the credits returning a debit, led by the servicer, so that
-- with stale statistics no chunk reads every payer line of the servicer.
create index bank_transfer_cancelled_filed_idx on public.bank_transfer (organization_id, debtor_bank_account_id)
  where status = 'cancelled' and transfer_file_id is not null;
create index bank_transaction_batch_line_idx on public.bank_transaction (organization_id, booking_date, id)
  where direction = 'debit' and end_to_end_id is null and payment_info_id is not null;
create index bank_transaction_return_credit_idx on public.bank_transaction (organization_id, booking_date, id)
  where direction = 'credit' and kind = 'return';
-- I20's refund rule counts each executed refund's M2b links by its request (review T7: without it, the nightly check read
-- the whole link table once per executed refund — every link ever made, quadratic in the servicer's history)
create index bank_debit_link_refund_request_idx on public.bank_debit_link (refund_request_id)
  where refund_request_id is not null;
-- The servicer-level checks (private.run_payment_checks: the fund identities, the receivables, the owners' claims) read
-- the servicer's ledger accounts by organisation and book; no index led by the organisation held the claim items'
-- accounts, so each read was a sequential scan of every servicer's accounts — five per nightly run (integration of the
-- M2c-6b-1 review: 750,000 accounts read for a servicer of two after the scale runs, 5 to 7.6 s cold)
create index ledger_account_org_book_idx on public.ledger_account (organization_id, book);

------------------------------------------------------------------------------------------
-- One PmtInf per kind (plan §2.1): the payouts, then the refunds, then the sweep, each per execution date. A batch line
-- (the bank booking a PmtInf as one debit) is then one kind, and the funds pass never splits a line between a client's
-- money and a payer's refund. Files of payouts and the sweep keep -1 / -2, refund-only files -1; only files mixing
-- payouts and refunds number their PmtInfs differently from M2c-6a. Redefined from 20261115090000, the PmtInf grouping
-- only; same settings.
------------------------------------------------------------------------------------------

create or replace function public.generate_transfer_file(p_idempotency_key text, p_bank_account_id uuid,
                                                         p_late_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '5s'
as $$
declare
  b public.bank_account;
  v_late text := nullif(btrim(coalesce(p_late_reason, '')), '');
  v_request jsonb := jsonb_build_object('bank_account_id', p_bank_account_id,
                                        'late_reason', nullif(btrim(coalesce(p_late_reason, '')), ''));
  v_result jsonb;
  v_now timestamptz;
  v_today date;
  v_earliest date;
  v_file uuid := gen_random_uuid();
  v_token uuid := gen_random_uuid();
  v_number text;
  v_name text;
  v_superseded uuid[];
  v_sum bigint;
  v_n integer;
  v_cash jsonb;
  v_available bigint;
  v_own public.bank_account;
  v_owed_servicer bigint;
  v_sweeps bigint;
  v_sweep bigint := 0;
  v_sweep_left bigint := 0;
  v_sweep_id uuid;
  v_sweep_hold text;
  v_e2e text;
  v_offset integer;
  v_held jsonb;
begin
  select * into b from public.bank_account where id = p_bank_account_id;
  if not found or not private.has_role(b.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('generate_transfer_file', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if length(v_late) > 2000 then
    raise exception 'transfer file refused: late_reason_too_long' using errcode = 'check_violation';
  end if;
  -- top-up files from the own account are M2c-7's (design §21); a paying account is an active dedicated one in EUR
  if b.purpose <> 'client_funds' or b.status <> 'active' then
    raise exception 'transfer file refused: not_a_paying_account' using errcode = 'check_violation';
  end if;
  if b.currency <> 'EUR' then
    raise exception 'transfer file refused: not_eur' using errcode = 'check_violation';
  end if;
  -- lock order: the account row, the allocation lock, the remit lock, then files and transfers
  perform 1 from public.bank_account x where x.id = b.id for share;
  perform private.remittance_command_locks(b.organization_id, true);
  v_now := clock_timestamp();
  v_today := (v_now at time zone 'Europe/Paris')::date;
  v_earliest := private.transfer_earliest_execution_date(b.id, v_now);

  -- one live file per account: a file not downloaded yet is replaced by this one (its transfers come in it again)
  select coalesce(array_agg(f.id order by f.id), '{}') into v_superseded from public.transfer_file f
  where f.debtor_bank_account_id = b.id and f.status in ('pending', 'generated');
  perform private.transfer_file_release(x, 'superseded', 'Remplacé par un nouveau fichier', null, v_file)
  from unnest(v_superseded) x;

  -- the candidates: the account's ordered payouts and refunds, locked; each one's date and why it is held, if it is
  perform 1 from public.bank_transfer t
  where t.debtor_bank_account_id = b.id and t.status = 'ordered' and t.kind in ('payout', 'refund')
  order by t.id for update;
  drop table if exists pg_temp._tf;
  create temp table _tf on commit drop as
  select t.id, t.kind, t.amount_minor, t.run_id, t.created_at, t.end_to_end_id,
         greatest(t.requested_execution_date, v_earliest) as execution_date,
         private.transfer_hold_reason(t.id, v_today, greatest(t.requested_execution_date, v_earliest), v_late) as hold
  from public.bank_transfer t
  where t.debtor_bank_account_id = b.id and t.status = 'ordered' and t.kind in ('payout', 'refund');
  select coalesce(sum(x.amount_minor), 0), count(*) into v_sum, v_n from pg_temp._tf x where x.hold is null;
  select coalesce(jsonb_agg(jsonb_build_object('transfer_id', x.id, 'kind', x.kind, 'end_to_end_id', x.end_to_end_id,
                                               'amount_minor', x.amount_minor::text, 'reason', x.hold)
                            order by x.created_at, x.id), '[]')
  into v_held from pg_temp._tf x where x.hold is not null;

  -- the sweep (§11, §13 #8; founder #9): the servicer's share settled on the account, less the sweeps already ordered
  -- or in a file, to its own account; read under the remit lock (every writer of 4679 holds it)
  select a.* into v_own from public.servicer_billing_settings s
  join public.bank_account a on a.id = s.own_bank_account_id
  where s.organization_id = b.organization_id and a.purpose = 'own' and a.status = 'active' and a.currency = b.currency;
  if v_own.id is not null then
    select coalesce(sum(lp.amount_minor), 0) into v_owed_servicer
    from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
    where la.organization_id = b.organization_id and la.book = 'due_to_servicer' and la.currency = b.currency;
    select coalesce(sum(x.amount_minor), 0) into v_sweeps from public.bank_transfer x
    where x.organization_id = b.organization_id and x.kind = 'sweep' and x.currency = b.currency
      and x.status in ('ordered', 'in_file');
    v_sweep := greatest(0, -v_owed_servicer - v_sweeps);
    -- review round 2 (D4): a cancelled sweep left the account all the same (its debit seen, no return): none again
    if v_sweep > 0 and exists (select 1 from private.debited_cancelled_sweeps(b.id)) then
      v_sweep := 0;
      v_sweep_hold := 'cancelled_sweep_debited';
    end if;
  end if;

  -- the cash check (ops critique #5): what the account can still pay covers the file; the servicer's sweep goes first
  -- when it does not (clients are paid first, founder #9)
  v_cash := private.transfer_cash_position(b.id);
  if v_cash is null then
    raise exception 'transfer file refused: no_closing_balance' using errcode = 'check_violation',
      hint = 'Importez un relevé du compte avec son solde de clôture.';
  end if;
  v_available := (v_cash ->> 'available_minor')::bigint;
  if v_available < v_sum + v_sweep then
    v_sweep_left := v_sweep;
    v_sweep := 0;
  end if;
  if v_available < v_sum then
    raise exception 'transfer file refused: cash_not_covered' using errcode = 'check_violation',
      detail = jsonb_build_object('available_minor', v_available::text, 'needed_minor', v_sum::text,
                                  'cash', v_cash)::text;
  end if;
  if v_n = 0 and v_sweep = 0 then
    raise exception 'transfer file refused: nothing_to_file' using errcode = 'check_violation',
      detail = jsonb_build_object('held', v_held, 'sweep_hold', v_sweep_hold)::text;
  end if;

  select legal_name into v_name from public.organization where id = b.organization_id;
  v_number := private.transfer_file_number(v_today, nextval('private.transfer_file_number_seq'));
  if v_sweep > 0 then
    v_e2e := 'SWP' || upper(substr(md5(gen_random_uuid()::text), 1, 12));
    insert into public.bank_transfer (organization_id, kind, debtor_bank_account_id, creditor_bank_account_id, currency,
                                      amount_minor, payee_name, payee_iban, payee_bic, end_to_end_id, remittance_info,
                                      requested_execution_date, ordered_by)
    values (b.organization_id, 'sweep', b.id, v_own.id, b.currency, v_sweep, left(btrim(v_name), 70), v_own.iban,
            v_own.bic, v_e2e, 'VIREMENT AU COMPTE PROPRE ' || v_number, v_earliest, auth.uid())
    returning id into v_sweep_id;
    insert into pg_temp._tf (id, kind, amount_minor, run_id, created_at, end_to_end_id, execution_date, hold)
    values (v_sweep_id, 'sweep', v_sweep, null, clock_timestamp(), v_e2e, v_earliest, null);
  end if;

  -- CreDtTm frozen now, Paris time with its offset
  v_offset := (extract(epoch from (v_now at time zone 'Europe/Paris') - (v_now at time zone 'UTC')) / 60)::integer;
  insert into public.transfer_file (id, organization_id, debtor_bank_account_id, currency, number, msg_id, pain_version,
                                    created_at_iso, initiating_party, debtor_name, debtor_iban, debtor_bic, nb_of_txs,
                                    ctrl_sum_minor, first_execution_date, last_execution_date, late_reason, cash_check,
                                    held, job_token, created_by)
  select v_file, b.organization_id, b.id, b.currency, v_number, v_number, b.pain_version,
         to_char(v_now at time zone 'Europe/Paris', 'YYYY-MM-DD"T"HH24:MI:SS')
           || case when v_offset < 0 then '-' else '+' end
           || lpad((abs(v_offset) / 60)::text, 2, '0') || ':' || lpad((abs(v_offset) % 60)::text, 2, '0'),
         v_name, v_name, b.iban, b.bic, count(*), sum(x.amount_minor), min(x.execution_date), max(x.execution_date),
         case when bool_or(x.kind = 'payout' and x.execution_date > r.earliest_latest_execution_date) then v_late end,
         v_cash || jsonb_build_object('ctrl_sum_minor', sum(x.amount_minor)::text,
                                      'sweep_left_minor', v_sweep_left::text, 'sweep_hold', v_sweep_hold),
         v_held, v_token, auth.uid()
  from pg_temp._tf x left join public.remittance_run r on r.id = x.run_id
  where x.hold is null;
  -- one PmtInf per kind and execution date — the payouts, then the refunds, then the sweep (M2c-6b-1, plan §2.1: a
  -- batch line is then one kind) — transactions in order
  insert into public.transfer_file_item (file_id, seq, transfer_id, organization_id, pmt_inf_id, execution_date, late)
  select v_file, row_number() over (order by g.grp, x.execution_date, x.created_at, x.id), x.id, b.organization_id,
         v_number || '-' || dense_rank() over (order by g.grp, x.execution_date), x.execution_date,
         coalesce(x.kind = 'payout' and x.execution_date > r.earliest_latest_execution_date, false)
  from pg_temp._tf x
  cross join lateral (select case x.kind when 'payout' then 1 when 'refund' then 2 else 3 end as grp) g
  left join public.remittance_run r on r.id = x.run_id
  where x.hold is null;
  update public.bank_transfer t set status = 'in_file', transfer_file_id = v_file
  from pg_temp._tf x where x.id = t.id and x.hold is null;
  perform pgmq.send('remittances', jsonb_build_object('type', 'transfer_file', 'file_id', v_file, 'token', v_token));

  v_result := jsonb_build_object('file_id', v_file, 'number', v_number, 'status', 'pending',
                                 'nb_of_txs', v_n + (v_sweep > 0)::integer, 'ctrl_sum_minor', (v_sum + v_sweep)::text,
                                 'sweep_minor', v_sweep::text, 'sweep_left_minor', v_sweep_left::text,
                                 'sweep_hold', v_sweep_hold,
                                 'first_execution_date', (select min(execution_date) from pg_temp._tf where hold is null),
                                 'held', v_held, 'superseded', to_jsonb(v_superseded));
  perform private.command_record('generate_transfer_file', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

------------------------------------------------------------------------------------------
-- The funds pass (§12; plan §2.2–§2.5): what the debit job may book, the rows it books, the posting
------------------------------------------------------------------------------------------

-- The rows the job (or ops: link_debit, M2c-6b-2's book_transfer_line) asks to book (redefined from 20261111090000):
-- one row per (bank line, transfer) — a batch line has one per member of its PmtInf — or one per line with no
-- transfer (a fee, a top-up from an own IBAN, a loss). The unplanned kinds are ops' (M2c-6b-2); the job's are fee,
-- top_up, payout, sweep, payout_returned and sweep_returned (a returned payout's bank charge is derived from it).
create or replace function private.bank_booking_begin()
returns void
language plpgsql
set search_path = ''
as $$
begin
  drop table if exists pg_temp._bank_booking;
  drop table if exists pg_temp._booking_skipped;
  drop table if exists pg_temp._booking_failed;
  create temp table _bank_booking (
    ord integer not null unique,
    bank_transaction_id uuid not null,
    kind text not null check (kind in ('fee', 'top_up', 'loss', 'payout', 'sweep', 'payout_returned', 'sweep_returned',
                                       'unplanned_payout', 'unplanned_sweep')),
    transfer_id uuid,               -- top_up: our TOP transfer; payout/sweep: the transfer debited; *_returned: returned
    amount_minor bigint,            -- loss: the excess over what was left of the payment (else derived)
    client_organization_id uuid,    -- (M2c-6b-2: an unplanned payout to a client's registered IBAN)
    method text not null check (method in ('auto', 'ops')),
    decided_by uuid,
    reason text,
    unique nulls not distinct (bank_transaction_id, transfer_id)
  ) on commit drop;
  create temp table _booking_skipped (bank_transaction_id uuid primary key, why text not null) on commit drop;
  create temp table _booking_failed (bank_transaction_id uuid primary key, detail text not null) on commit drop;
  -- job: the lines it leaves to ops, with why
  drop table if exists pg_temp._booking_review;
  create temp table _booking_review (
    bank_transaction_id uuid primary key,
    reason text not null,
    candidates jsonb not null default '[]',
    detail text
  ) on commit drop;
end;
$$;

-- The transfer a batch line of one refund alone is (plan §2.2 [critic]): the PmtInf, of a file of the account handed
-- out (downloaded or sent), holds exactly one member still in_file — a refund — and no cancelled member the bank did
-- not return. Such a line is the M2b refund link's (private.debit_candidates), never the funds pass's. Keyed: the
-- PmtInf's items, then each one's file and transfer by key.
create or replace function private.pmt_inf_single_refund(p_bank_account_id uuid, p_pmt_inf_id text)
returns uuid
language sql
stable
set search_path = ''
set enable_seqscan = off
as $$
  select case when count(*) filter (where m.status = 'in_file') = 1
                   and count(*) filter (where m.status = 'in_file' and m.kind = 'refund') = 1
                   and count(*) filter (where m.status = 'cancelled' and not m.returned) = 0
              then (array_agg(m.id) filter (where m.status = 'in_file'))[1] end
  from (select i.file_id, i.transfer_id from public.transfer_file_item i where i.pmt_inf_id = p_pmt_inf_id offset 0) i
  cross join lateral (select f.debtor_bank_account_id, f.status, f.download_count from public.transfer_file f
                      where f.id = i.file_id offset 0) f
  cross join lateral (select t.id, t.kind, t.status, t.transfer_file_id,
                             case when t.status = 'cancelled' then private.transfer_return_seen(t.id) else false end
                               as returned
                      from public.bank_transfer t where t.id = i.transfer_id offset 0) m
  where f.debtor_bank_account_id = p_bank_account_id and f.download_count > 0 and f.status in ('downloaded', 'sent')
    and m.transfer_file_id = i.file_id;
$$;

-- The lines the debit job may book in the funds (redefined from 20261111090000, dropped and created: one row per
-- (line, transfer fact), plan §2.2), in date order after `p_after`, not booked, not linked, not released as a payment:
--   * a debit carrying our RMT/SWP id (`own`: the transfer of that id, unique), or to our own IBAN (transfer_out);
--   * a batch line — a debit with no end-to-end id and the PmtInfId of one of our files, read as other_debit,
--     batch_unsplit or transfer_out — one row per member of that PmtInf in its current file (`member`; the file must
--     be of the line's account); a PmtInf of one refund alone is left to the M2b pass (private.pmt_inf_single_refund);
--   * a credit returning our payout or sweep (`return`: the transfer of its original id);
--   * a credit carrying our TOP id (`top_up`), from our own account or from a client (as M2c-1);
--   * a debit coded as the bank's charge (CHRG, FEES: a fee).
-- Each branch is read by its own partial index, led by the servicer, ordered and limited on its own, then merged
-- (ARCHITECTURE §4: with stale statistics no chunk reads every payer line of the servicer); every fact by key.
drop function private.bank_booking_candidates(uuid, date, uuid, integer);
create function private.bank_booking_candidates(p_organization_id uuid, p_after_date date, p_after_id uuid,
                                                p_limit integer)
returns table (line_id uuid, line_kind text, direction text, bank_account_id uuid, currency char(3),
               amount_minor bigint, booking_date date, bank_tx_code text, end_to_end_id text,
               original_end_to_end_id text, payment_info_id text, role text, transfer_id uuid, transfer_kind text,
               transfer_status text, transfer_amount_minor bigint, transfer_currency char(3),
               transfer_debtor_bank_account_id uuid, transfer_creditor_bank_account_id uuid, transfer_date date,
               transfer_file_id uuid, file_status text, file_download_count integer, pmt_inf_id text,
               batch_file_id uuid, batch_file_status text, batch_file_download_count integer, run_id uuid,
               run_status text, run_transfer_id uuid, replaces_transfer_id uuid, debit_booked boolean,
               return_booked boolean, return_seen boolean)
language plpgsql
stable
security definer
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
as $$
declare
  v_limit integer := greatest(coalesce(p_limit, 2000), 1);
begin
  return query
  with k as materialized (
    select z.id, z.booking_date
    from (
      (select t.id, t.booking_date from public.bank_transaction t
       where t.organization_id = p_organization_id
         and t.kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in')
         and (p_after_date is null or (t.booking_date, t.id) > (p_after_date, p_after_id))
         and not exists (select 1 from public.bank_line_booking b where b.bank_transaction_id = t.id offset 0)
         and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id offset 0)
         and not exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = t.id offset 0)
       order by t.booking_date, t.id limit v_limit)
      union
      (select t.id, t.booking_date from public.bank_transaction t
       where t.organization_id = p_organization_id and t.direction = 'debit' and t.end_to_end_id is null
         and t.payment_info_id is not null and t.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$'
         and t.kind in ('other_debit', 'batch_unsplit', 'transfer_out')
         and (p_after_date is null or (t.booking_date, t.id) > (p_after_date, p_after_id))
         and not exists (select 1 from public.bank_line_booking b where b.bank_transaction_id = t.id offset 0)
         and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id offset 0)
         and (t.kind = 'transfer_out' or private.pmt_inf_single_refund(t.bank_account_id, t.payment_info_id) is null)
       order by t.booking_date, t.id limit v_limit)
      union
      (select t.id, t.booking_date from public.bank_transaction t
       where t.organization_id = p_organization_id and t.direction = 'credit' and t.kind = 'return'
         and coalesce(t.original_end_to_end_id, t.end_to_end_id) ~ '^(RMT|SWP)[0-9A-F]{12}$'
         and (p_after_date is null or (t.booking_date, t.id) > (p_after_date, p_after_id))
         and not exists (select 1 from public.bank_line_booking b where b.bank_transaction_id = t.id offset 0)
         and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id offset 0)
       order by t.booking_date, t.id limit v_limit)
      union
      (select t.id, t.booking_date from public.bank_transaction t
       where t.organization_id = p_organization_id and t.kind = 'other_debit'
         and split_part(t.bank_tx_code, '/', 3) in ('CHRG', 'FEES')
         and not (t.end_to_end_id is null and coalesce(t.payment_info_id, '') ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$')
         and (p_after_date is null or (t.booking_date, t.id) > (p_after_date, p_after_id))
         and not exists (select 1 from public.bank_line_booking b where b.bank_transaction_id = t.id offset 0)
         and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id offset 0)
       order by t.booking_date, t.id limit v_limit)
      union
      (select t.id, t.booking_date from public.bank_transaction t
       where t.organization_id = p_organization_id and t.kind = 'suspected_duplicate'
         and (p_after_date is null or (t.booking_date, t.id) > (p_after_date, p_after_id))
         and exists (select 1 from public.bank_duplicate_resolution r where r.bank_transaction_id = t.id
                       and r.decision = 'released'
                       and r.released_kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in') offset 0)
         and not exists (select 1 from public.bank_line_booking b where b.bank_transaction_id = t.id offset 0)
         and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id offset 0)
         and not exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = t.id offset 0)
       order by t.booking_date, t.id limit v_limit)) z
    order by z.booking_date, z.id
    limit v_limit),
  x as materialized (
    select t.id, coalesce(r.released_kind, t.kind) as kind, t.direction, t.bank_account_id, t.currency, t.amount_minor,
           t.booking_date, t.bank_tx_code, t.end_to_end_id, t.original_end_to_end_id, t.payment_info_id
    from k
    cross join lateral (select q.* from public.bank_transaction q where q.id = k.id offset 0) t
    left join lateral (select q.decision, q.released_kind from public.bank_duplicate_resolution q
                       where q.bank_transaction_id = t.id offset 0) r on true),
  -- what each line names: its own id's transfer, the members of its PmtInf, the transfer it returns, the top-up — each
  -- transfer read once, by its key (its whole row carried on)
  f as materialized (
    select x.id as line_id, n.role, n.tr, n.batch_file_id
    from x
    cross join lateral (
      select 'own'::text as role, q.t as tr, null::uuid as batch_file_id
      from (select y as t from public.bank_transfer y
            where x.direction = 'debit' and x.end_to_end_id ~ '^(RMT|SWP)[0-9A-F]{12}$'
              and y.end_to_end_id = x.end_to_end_id offset 0) q
      where (q.t).organization_id = p_organization_id
      union all
      select 'return', q.t, null
      from (select y as t from public.bank_transfer y
            where x.direction = 'credit' and x.kind = 'return'
              and coalesce(x.original_end_to_end_id, x.end_to_end_id) ~ '^(RMT|SWP)[0-9A-F]{12}$'
              and y.end_to_end_id = coalesce(x.original_end_to_end_id, x.end_to_end_id) offset 0) q
      where (q.t).organization_id = p_organization_id
      union all
      select 'top_up', q.t, null
      from (select y as t from public.bank_transfer y
            where x.kind = 'own_transfer_in' and y.end_to_end_id = x.end_to_end_id offset 0) q
      where (q.t).organization_id = p_organization_id
      union all
      select 'member', m.t, i.file_id
      from (select y.file_id, y.transfer_id from public.transfer_file_item y
            where x.direction = 'debit' and x.end_to_end_id is null
              and x.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$' and y.pmt_inf_id = x.payment_info_id
            offset 0) i
      cross join lateral (select y.debtor_bank_account_id, y.organization_id from public.transfer_file y
                          where y.id = i.file_id offset 0) fl
      cross join lateral (select y as t from public.bank_transfer y where y.id = i.transfer_id offset 0) m
      where fl.debtor_bank_account_id = x.bank_account_id and fl.organization_id = p_organization_id
        and (m.t).transfer_file_id = i.file_id) n)
  select x.id, x.kind, x.direction, x.bank_account_id, x.currency, x.amount_minor, x.booking_date, x.bank_tx_code,
         x.end_to_end_id, x.original_end_to_end_id, x.payment_info_id, f.role, (f.tr).id, (f.tr).kind, (f.tr).status,
         (f.tr).amount_minor, (f.tr).currency, (f.tr).debtor_bank_account_id, (f.tr).creditor_bank_account_id,
         ((f.tr).created_at at time zone 'Europe/Paris')::date, (f.tr).transfer_file_id, tf.status, tf.download_count,
         (select i.pmt_inf_id from public.transfer_file_item i
          where i.file_id = (f.tr).transfer_file_id and i.transfer_id = (f.tr).id),
         f.batch_file_id, bf.status, bf.download_count, (f.tr).run_id, ru.status, ru.transfer_id,
         (f.tr).replaces_transfer_id,
         case when (f.tr).id is not null then exists (select 1 from public.bank_line_booking b
                                                        where b.transfer_id = (f.tr).id
                                                          and b.kind in ('payout', 'sweep', 'top_up') offset 0) end,
         case when (f.tr).id is not null then exists (select 1 from public.bank_line_booking b
                                                        where b.transfer_id = (f.tr).id
                                                          and b.kind in ('payout_returned', 'sweep_returned')
                                                        offset 0) end,
         case when (f.tr).status = 'cancelled' then private.transfer_return_seen((f.tr).id) end
  from x
  left join f on f.line_id = x.id
  left join lateral (select q.status, q.download_count from public.transfer_file q
                     where q.id = (f.tr).transfer_file_id offset 0) tf on true
  left join lateral (select q.status, q.download_count from public.transfer_file q where q.id = f.batch_file_id
                     offset 0) bf on true
  left join lateral (select q.status, q.transfer_id from public.remittance_run q where q.id = (f.tr).run_id offset 0)
    ru on true
  order by x.booking_date, x.id, (f.tr).id;
end;
$$;

-- A run's settlement at its payout's debit, set-based (plan §2.5 [critic]): what private.post_run_settlement
-- (20261112090000) posts for one run, for every run of a chunk in one private.ledger_post_set call — the
-- `client_settlement` of each plan (C fund: +4670[c] D / −4679 D ‖ S fund: +4689 D / −4111[c] Dc / −4112[c] Da;
-- +44574 v / −44571 v; key settle:<run>, its document the run, dated p_dates[i]) and its commission_settlement rows
-- (pgTAP 035 compares it with post_run_settlement on each shape). One call per run would rebuild the working tables
-- and run ledger_post_set 5,000 times in the transaction a 5,000-member batch line needs.
create or replace function private.post_run_settlements(p_run_ids uuid[], p_dates date[])
returns table (run_id uuid, entry_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_bad text;
begin
  drop table if exists pg_temp._prs;
  create temp table _prs on commit drop as
  select x.ord::integer as ord, r.id, r.organization_id, r.client_organization_id, r.currency, r.number,
         x.on_date, r.settlement_plan as plan,
         coalesce((r.settlement_plan ->> 'settlement')::bigint, 0) as d,
         coalesce((r.settlement_plan ->> 'dc')::bigint, 0) as dc,
         coalesce((r.settlement_plan ->> 'da')::bigint, 0) as da,
         coalesce((r.settlement_plan ->> 'vat_moved')::bigint, 0) as vat
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
  drop table if exists pg_temp._prs_posted;
  create temp table _prs_posted (entry_no integer primary key, entry_id uuid not null) on commit drop;
  if exists (select 1 from pg_temp._prs p where p.d <> 0) then
    perform private.ledger_post_set_begin();
    insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                    client_organization_id, source_type, source_id)
    select p.ord, p.organization_id, 'client_settlement', p.on_date, 'settle:' || p.id, p.client_organization_id,
           'remittance_run', p.id::text
    from pg_temp._prs p where p.d <> 0;
    insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency)
    select p.ord, row_number() over (partition by p.ord order by l.o)::integer, l.book, l.amount, p.currency
    from pg_temp._prs p
    cross join lateral (values (1, 'client_payable', p.d), (2, 'due_to_servicer', -p.d),
                               (3, 'due_from_client_funds', p.d), (4, 'commission_receivable', -p.dc),
                               (5, 'client_advance_receivable', -p.da), (6, 'vat_pending', p.vat),
                               (7, 'vat_collected', -p.vat)) l (o, book, amount)
    where p.d <> 0 and l.amount <> 0;
    insert into pg_temp._prs_posted (entry_no, entry_id) select x.entry_no, x.entry_id from private.ledger_post_set() x;
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
    where p.d <> 0
    order by p.ord, s.n;
  end if;
  return query select p.id, x.entry_id from pg_temp._prs p left join pg_temp._prs_posted x on x.entry_no = p.ord
               order by p.ord;
end;
$$;

-- Posts the rows of pg_temp._bb (checked by the caller under its locks; redefined from 20261111090000), set-based:
-- (1) one ledger_post_set for the remittances (+4670[c] N / −5120 N, remit:<t>), the sweeps (+4679 S / −5120 S ‖
-- +5122[own] S / −4689 S, sweep:<t>), fees, top-ups, losses, and the bank's charge on a returned payout or sweep (the
-- difference, a bank_fee on the same line, fee:<line>); (2) the reversal of each returned transfer's entry at the return
-- date (return:<line>; the 4670 trigger queues the `payout_returned` item); (3) the booked runs' settlements in one call
-- (private.post_run_settlements, at the debit date); (4) the cover: a client left in debit on 4670 by its payout (a
-- collection reversed since the approval) gets a `client_advance` of that much, cause `payout_overrun`
-- (adv:payout:<t>), so no other client's money is used (I13, LG008); then the bookings (seq: the line's last + its
-- rank, plan §2.5 [critic]), the transfers booked or returned, the runs booked, the run's payout account `returned`
-- after a returned payout (only while active: a retired one stays retired), an R124-6 breach row per item debited after
-- the date it is held to, the lines' reviews deleted; the ledger's commit checks and the lines' completeness, now.
create or replace function private.bank_booking_post_rows(p_organization_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ret record;
  v_entry uuid;
  v_bad text;
begin
  drop table if exists pg_temp._bb_entry;
  create temp table _bb_entry (entry_no integer primary key, entry_id uuid not null) on commit drop;

  -- (1) the remittances, sweeps, fees, top-ups and losses, and a returned transfer's bank charge (entry_no −ord)
  if exists (select 1 from pg_temp._bb b
             where b.kind in ('payout', 'sweep', 'fee', 'top_up', 'loss')
                or (b.kind in ('payout_returned', 'sweep_returned') and b.tr_minor > b.line_minor)) then
    perform private.ledger_post_set_begin();
    insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                    client_organization_id, source_type, source_id, reason)
    select b.ord, p_organization_id,
           case b.kind when 'payout' then 'remittance' when 'sweep' then 'servicer_sweep' when 'fee' then 'bank_fee'
                       when 'top_up' then 'servicer_top_up' else 'servicer_loss' end,
           b.line_date,
           case b.kind when 'payout' then 'remit:' || b.transfer_id when 'sweep' then 'sweep:' || b.transfer_id
                       when 'fee' then 'fee:' || b.bank_transaction_id when 'top_up' then 'topup:' || b.bank_transaction_id
                       else 'loss:' || b.bank_transaction_id end,
           case when b.kind = 'payout' then b.tr_client end,
           case when b.transfer_id is not null then 'bank_transfer' else 'bank_transaction' end,
           coalesce(b.transfer_id, b.bank_transaction_id)::text,
           coalesce(nullif(btrim(b.reason), ''), case b.kind when 'loss' then 'Excédent du retour sur le paiement (OQ-34)' end)
    from pg_temp._bb b where b.kind in ('payout', 'sweep', 'fee', 'top_up', 'loss')
    union all
    select -b.ord, p_organization_id, 'bank_fee', b.line_date, 'fee:' || b.bank_transaction_id, null,
           'bank_transaction', b.bank_transaction_id::text,
           'Frais de la banque déduits du virement revenu impayé (relevé du ' || to_char(b.line_date, 'DD/MM/YYYY') || ')'
    from pg_temp._bb b where b.kind in ('payout_returned', 'sweep_returned') and b.tr_minor > b.line_minor;
    insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id)
    select e.entry_no, v.line_no, v.book, v.sign * e.amount, e.currency,
           case v.book when 'client_money_cash' then e.line_bank when 'own_cash' then e.own_bank end
    from (select b.ord as entry_no, b.kind, b.book_minor as amount, b.currency, b.line_bank,
                 case b.kind when 'sweep' then b.tr_creditor else b.own_bank end as own_bank
          from pg_temp._bb b where b.kind in ('payout', 'sweep', 'fee', 'top_up', 'loss')
          union all
          select -b.ord, 'fee', b.tr_minor - b.line_minor, b.currency, b.line_bank, null
          from pg_temp._bb b where b.kind in ('payout_returned', 'sweep_returned') and b.tr_minor > b.line_minor) e
    cross join lateral (
      select * from (values
        -- remittance: +4670[c] N / −5120 N
        ('payout', 1, 'client_payable', 1), ('payout', 2, 'client_money_cash', -1),
        -- servicer_sweep: +4679 S / −5120 S ‖ +5122[own] S / −4689 S
        ('sweep', 1, 'due_to_servicer', 1), ('sweep', 2, 'client_money_cash', -1),
        ('sweep', 3, 'own_cash', 1), ('sweep', 4, 'due_from_client_funds', -1),
        -- bank_fee: +4679 / −5120 ‖ +6270 / −4689
        ('fee', 1, 'due_to_servicer', 1), ('fee', 2, 'client_money_cash', -1),
        ('fee', 3, 'bank_fees', 1), ('fee', 4, 'due_from_client_funds', -1),
        -- servicer_top_up: +5120 / −4679 ‖ +4689 / −5122
        ('top_up', 1, 'client_money_cash', 1), ('top_up', 2, 'due_to_servicer', -1),
        ('top_up', 3, 'due_from_client_funds', 1), ('top_up', 4, 'own_cash', -1),
        -- servicer_loss: +4679 / −5120 ‖ +6780 / −4689
        ('loss', 1, 'due_to_servicer', 1), ('loss', 2, 'client_money_cash', -1),
        ('loss', 3, 'servicer_losses', 1), ('loss', 4, 'due_from_client_funds', -1)
      ) w (kind, line_no, book, sign) where w.kind = e.kind) v;
    insert into pg_temp._bb_entry (entry_no, entry_id) select x.entry_no, x.entry_id from private.ledger_post_set() x;
  end if;

  -- (2) the returned transfers: their entry reversed at the return date (few: one by one)
  for v_ret in select b.ord, b.tr_entry, b.bank_transaction_id, b.line_date, b.kind from pg_temp._bb b
           where b.kind in ('payout_returned', 'sweep_returned') order by b.ord loop
    select x.entry_id into v_entry
    from private.ledger_reverse(v_ret.tr_entry, 'return:' || v_ret.bank_transaction_id,
                                case v_ret.kind when 'payout_returned' then 'Virement de reversement revenu impayé'
                                            else 'Virement au compte propre revenu impayé' end
                                || ' (relevé du ' || to_char(v_ret.line_date, 'DD/MM/YYYY') || ')',
                                v_ret.line_date) x;
    insert into pg_temp._bb_entry (entry_no, entry_id) values (v_ret.ord, v_entry);
  end loop;

  -- (3) the booked runs' settlements, at the debit date (§5.2, OQ-37 default)
  if exists (select 1 from pg_temp._bb b where b.kind = 'payout') then
    perform private.post_run_settlements(array(select b.tr_run from pg_temp._bb b where b.kind = 'payout' order by b.ord),
                                         array(select b.line_date from pg_temp._bb b where b.kind = 'payout'
                                               order by b.ord));
  end if;

  -- (4) the cover: what a booked payout left in debit on its client's 4670 (all its entries posted: the running
  -- balance), advanced by the servicer at the debit date
  drop table if exists pg_temp._bb_cover;
  create temp table _bb_cover on commit drop as
  select distinct on (b.tr_client, b.currency) b.ord, b.tr_client as client_organization_id, b.currency, b.transfer_id,
         b.bank_transaction_id, b.line_date, c.balance_minor as overrun, e.entry_id as cause_entry_id,
         gen_random_uuid() as advance_id
  from pg_temp._bb b
  join pg_temp._bb_entry e on e.entry_no = b.ord
  cross join lateral (select q.balance_minor from private.client_payable_balance q
                      where q.client_organization_id = b.tr_client and q.currency = b.currency) c
  where b.kind = 'payout' and c.balance_minor > 0
  order by b.tr_client, b.currency, b.ord;
  if exists (select 1 from pg_temp._bb_cover) then
    perform private.ledger_post_set_begin();
    insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                    client_organization_id, source_type, source_id, reason)
    select c.ord, p_organization_id, 'client_advance', c.line_date, 'adv:payout:' || c.transfer_id,
           c.client_organization_id, 'client_advance', c.advance_id::text,
           'Reversement au-delà de ce qui restait dû au mandant : avance du cabinet'
    from pg_temp._bb_cover c;
    -- client_advance: +4679 A / −4670[c] A ‖ +4112[c] A / −4689 A
    insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency)
    select c.ord, v.line_no, v.book, v.sign * c.overrun, c.currency
    from pg_temp._bb_cover c
    cross join (values (1, 'due_to_servicer', 1), (2, 'client_payable', -1), (3, 'client_advance_receivable', 1),
                       (4, 'due_from_client_funds', -1)) v (line_no, book, sign);
    drop table if exists pg_temp._bb_cover_posted;
    create temp table _bb_cover_posted on commit drop as select * from private.ledger_post_set();
    insert into public.client_advance (id, organization_id, client_organization_id, currency, amount_minor, cause,
                                       cause_entry_id, entry_id, bank_transaction_id, transfer_id)
    select c.advance_id, p_organization_id, c.client_organization_id, c.currency, c.overrun, 'payout_overrun',
           c.cause_entry_id, x.entry_id, c.bank_transaction_id, c.transfer_id
    from pg_temp._bb_cover c join pg_temp._bb_cover_posted x on x.entry_no = c.ord;
  end if;

  -- the bookings: one per row, the returned transfer's charge after its return; seq = the line's last + its rank
  insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id, kind, transfer_id,
                                        entry_id, amount_minor, method, reason, decided_by)
  select z.bank_transaction_id,
         coalesce((select max(k.seq) from public.bank_line_booking k where k.bank_transaction_id = z.bank_transaction_id),
                  0) + row_number() over (partition by z.bank_transaction_id order by z.o),
         p_organization_id, z.line_bank, z.kind, z.transfer_id, z.entry_id, z.amount, z.method, z.reason, z.decided_by
  from (select b.bank_transaction_id, b.ord::bigint * 2 as o, b.line_bank, b.kind, b.transfer_id, e.entry_id,
               b.book_minor as amount, b.method, nullif(btrim(b.reason), '') as reason, b.decided_by
        from pg_temp._bb b join pg_temp._bb_entry e on e.entry_no = b.ord
        union all
        select b.bank_transaction_id, b.ord::bigint * 2 + 1, b.line_bank, 'fee', null, e.entry_id,
               b.tr_minor - b.line_minor, b.method, nullif(btrim(b.reason), ''), b.decided_by
        from pg_temp._bb b join pg_temp._bb_entry e on e.entry_no = -b.ord
        where b.kind in ('payout_returned', 'sweep_returned')) z
  order by z.bank_transaction_id, z.o;

  -- the transfers booked (their entry) or returned (the reversal); the runs booked at the debit date; the run's payout
  -- account returned (it blocks payouts until replaced or reconfirmed: payout_account_returned)
  update public.bank_transfer x set status = 'booked', entry_id = e.entry_id
  from pg_temp._bb b join pg_temp._bb_entry e on e.entry_no = b.ord
  where b.kind in ('payout', 'sweep', 'top_up') and b.transfer_id is not null and x.id = b.transfer_id;
  update public.bank_transfer x set status = 'returned', return_entry_id = e.entry_id
  from pg_temp._bb b join pg_temp._bb_entry e on e.entry_no = b.ord
  where b.kind in ('payout_returned', 'sweep_returned') and x.id = b.transfer_id;
  update public.remittance_run r set status = 'booked', booked_on = b.line_date, version = r.version + 1
  from pg_temp._bb b
  where b.kind = 'payout' and r.id = b.tr_run and r.status in ('approved', 'sent');
  update public.client_payout_account a set status = 'returned'
  from pg_temp._bb b
  where b.kind = 'payout_returned' and a.id = b.run_payout_account and a.status = 'active';

  -- R124-6 (I21): an item of a booked run debited after the date it is held to (its latest execution date, or one
  -- month for a delay that cannot be met, as private.remittance_late_lines) gets its breach row, once; a returned
  -- payout paid again is recorded « bloqué : virement revenu impayé » (Q7's default, OQ-36; review legal-texts#1).
  -- Its payment's key-share lock (the foreign key) was taken before the allocation lock (post_bank_bookings).
  with late as materialized (
    select b.tr_run as run_id, b.line_date, ru.organization_id, ru.client_organization_id,
           ru.requested_execution_date, ru.late_reason, l.ledger_entry_id, l.payment_id, l.deadline,
           l.latest_execution_date, l.unmeetable, l.encaissement_date, l.kind
    from pg_temp._bb b
    cross join lateral (select q.organization_id, q.client_organization_id, q.requested_execution_date, q.late_reason
                        from public.remittance_run q where q.id = b.tr_run offset 0) ru
    cross join lateral (select x.ledger_entry_id, x.payment_id, x.deadline, x.latest_execution_date, x.unmeetable,
                               x.encaissement_date, x.kind
                        from public.remittance_line x
                        where x.run_id = b.tr_run and x.amount_minor > 0 and not x.released
                          and x.latest_execution_date < b.line_date offset 0) l
    where b.kind = 'payout'),
  m as materialized (
    select k.e_date, d.*
    from (select distinct l.encaissement_date as e_date from late l
          where l.unmeetable and l.encaissement_date is not null) k
    cross join lateral private.remittance_deadline_or_null(k.e_date, 30) d)
  insert into public.remittance_deadline_breach (organization_id, client_organization_id, ledger_entry_id, payment_id,
                                                 run_id, deadline, latest_execution_date, requested_execution_date,
                                                 late_reason, blocked_reason)
  select l.organization_id, l.client_organization_id, l.ledger_entry_id, l.payment_id, l.run_id,
         case when l.unmeetable then m.deadline else l.deadline end,
         case when l.unmeetable then m.latest_execution_date else l.latest_execution_date end,
         l.requested_execution_date, l.late_reason,
         case when l.kind = 'payout_returned' then 'payout_returned' end
  from late l left join m on l.unmeetable and m.e_date = l.encaissement_date
  where not l.unmeetable or m.latest_execution_date < l.line_date
  on conflict (ledger_entry_id) do nothing;

  delete from public.bank_debit_review v using pg_temp._bb b where v.bank_transaction_id = b.bank_transaction_id;
  perform private.ledger_check_now();
  -- each line booked whole, signed (I19 per line), set-based before the deferred trigger's own check
  select min(c.bank_transaction_id::text) into v_bad
  from (select distinct b.bank_transaction_id from pg_temp._bb b) l
  cross join lateral (select q.id as bank_transaction_id, q.direction, q.amount_minor, q.bank_account_id
                      from public.bank_transaction q where q.id = l.bank_transaction_id offset 0) c
  where private.bank_line_cash_moved(c.bank_transaction_id, c.bank_account_id)
        <> case c.direction when 'credit' then c.amount_minor else -c.amount_minor end;
  if v_bad is not null then
    raise exception 'bank line %: not booked whole', v_bad using errcode = 'LG001';
  end if;
  set constraints public.bank_line_booking_complete immediate;
  set constraints public.bank_line_booking_complete deferred;
end;
$$;

-- What a line's bookings and its M2b link moved on its own account's 5120 (signed: + in, − out).
create or replace function private.bank_line_cash_moved(p_bank_transaction_id uuid, p_bank_account_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select (coalesce((select sum(p.amount_minor)
                    from (select k.entry_id from public.bank_line_booking k
                          where k.bank_transaction_id = p_bank_transaction_id offset 0) k
                    cross join lateral (select q.amount_minor, q.ledger_account_id from public.ledger_posting q
                                        where q.entry_id = k.entry_id offset 0) p
                    cross join lateral (select la.book, la.bank_account_id from public.ledger_account la
                                        where la.id = p.ledger_account_id offset 0) la
                    where la.book = 'client_money_cash' and la.bank_account_id = p_bank_account_id), 0)
          + coalesce((select sum(p.amount_minor)
                      from (select l.cash_entry_id from public.bank_debit_link l
                            where l.bank_transaction_id = p_bank_transaction_id and l.cash_entry_id is not null
                            offset 0) l
                      cross join lateral (select q.amount_minor, q.ledger_account_id from public.ledger_posting q
                                          where q.entry_id = l.cash_entry_id offset 0) p
                      cross join lateral (select la.book, la.bank_account_id from public.ledger_account la
                                          where la.id = p.ledger_account_id offset 0) la
                      where la.book = 'client_money_cash' and la.bank_account_id = p_bank_account_id), 0))::bigint;
$$;

-- Posts pg_temp._bank_booking (redefined from 20261111090000). Lock order (plan §2.5; ADR-0014 M2c-6a's order plus
-- M2b's): the runs of the transfers FOR UPDATE (id order) → the payout accounts a return marks FOR NO KEY UPDATE →
-- the bank accounts FOR SHARE → the payments of the payout runs' lines that can be late at this debit FOR KEY SHARE (id
-- order; review concurrency-2: the breach rows name them, and their foreign key's key-share lock taken under the
-- allocation lock deadlocked with request_refund, link_debit, reverse_allocation or forward_payment, which hold the
-- payment FOR UPDATE and wait for that lock — the house rule: row locks before the advisory lock; pg_temp._bb_pay_locks
-- keeps the set, a superset of the breach rows' payments since a run's lines and a line's booking date never change)
-- → the allocation lock `payments:<org>` (when a row moves 4670) → the bank lines FOR NO KEY
-- UPDATE (the lock every decision on a line takes: an M2b link, a release) → the remit lock → the files FOR SHARE →
-- the transfers FOR UPDATE (id order) — every member of a batch line's PmtInf, booked or not, so that a concurrent
-- cancellation of a member is seen under the lock. Top-ups (M2c-1's first lock) moved after the remit lock:
-- cancel_top_up holds only its row. The job calls this in its own transaction (never after the M2b pass took the
-- allocation lock: plan §2.5 [critic]). Every row is re-checked on what is found under the locks, by the rules of plan
-- §2.3–§2.4: own id first, a batch line only for exactly the in_file members of its PmtInf in their current file, none
-- cancelled, one kind, adding up; never a cancelled transfer, a second debit, a transfer never handed out. A line is
-- booked whole or not at all: one refused row refuses its line. p_strict (ops) raises the first refusal; otherwise
-- (job) refused lines go to pg_temp._booking_skipped and lines the posting refuses (a ledger check) to
-- pg_temp._booking_failed, each line then tried alone with all its rows (never each row alone: a batch member alone
-- fails completeness), the others posted.
create or replace function private.post_bank_bookings(p_organization_id uuid, p_strict boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_why record;
  v_l record;
  v_state text;
  v_msg text;
begin
  -- The keys first (what a transfer pays, its file history and its run never change): the transfers the rows name and
  -- every member of the PmtInf a batch line names.
  drop table if exists pg_temp._bb_keys;
  create temp table _bb_keys on commit drop as
  select distinct k.transfer_id, x.run_id, x.debtor_bank_account_id, x.creditor_bank_account_id
  from (select b.transfer_id from pg_temp._bank_booking b where b.transfer_id is not null
        union
        select i.transfer_id
        from pg_temp._bank_booking b
        cross join lateral (select q.direction, q.end_to_end_id, q.payment_info_id from public.bank_transaction q
                            where q.id = b.bank_transaction_id offset 0) t
        cross join lateral (select y.transfer_id from public.transfer_file_item y
                            where y.pmt_inf_id = t.payment_info_id offset 0) i
        where b.kind in ('payout', 'sweep') and t.direction = 'debit' and t.end_to_end_id is null
          and t.payment_info_id is not null) k
  cross join lateral (select q.run_id, q.debtor_bank_account_id, q.creditor_bank_account_id from public.bank_transfer q
                      where q.id = k.transfer_id offset 0) x;

  drop table if exists pg_temp._bb_cover;
  create temp table _bb_cover (ord integer) on commit drop;   -- (the advances posted: bank_booking_post_rows)

  perform 1 from public.remittance_run r
  where r.id = any (array(select k.run_id from pg_temp._bb_keys k where k.run_id is not null))
  order by r.id for update;
  perform 1 from public.client_payout_account a
  where a.id = any (array(select r.payout_account_id from public.remittance_run r
                          where r.id = any (array(select k.run_id from pg_temp._bb_keys k
                                                  join pg_temp._bank_booking b on b.transfer_id = k.transfer_id
                                                  where b.kind = 'payout_returned' and k.run_id is not null))
                            and r.payout_account_id is not null))
  order by a.id for no key update;
  perform 1 from public.bank_account a
  where a.id = any (array(
          select t.bank_account_id from pg_temp._bank_booking b
          cross join lateral (select q.bank_account_id from public.bank_transaction q
                              where q.id = b.bank_transaction_id offset 0) t
          union
          select k.debtor_bank_account_id from pg_temp._bb_keys k
          union
          select k.creditor_bank_account_id from pg_temp._bb_keys k where k.creditor_bank_account_id is not null))
  order by a.id for share;
  drop table if exists pg_temp._bb_pay_locks;
  create temp table _bb_pay_locks on commit drop as
  select distinct y.payment_id
  from pg_temp._bank_booking b
  join pg_temp._bb_keys k on k.transfer_id = b.transfer_id
  cross join lateral (select q.booking_date from public.bank_transaction q where q.id = b.bank_transaction_id offset 0) t
  cross join lateral (select x.payment_id from public.remittance_line x
                      where x.run_id = k.run_id and x.amount_minor > 0 and not x.released and x.payment_id is not null
                        and x.latest_execution_date < t.booking_date offset 0) y
  where b.kind = 'payout' and k.run_id is not null;
  perform 1 from public.payment p
  where p.id = any (array(select l.payment_id from pg_temp._bb_pay_locks l))
  order by p.id for key share;
  if exists (select 1 from pg_temp._bank_booking b where b.kind in ('payout', 'payout_returned', 'unplanned_payout')) then
    perform pg_advisory_xact_lock(hashtext('payments:' || p_organization_id::text));
  end if;
  perform 1 from public.bank_transaction t
  where t.id = any (array(select b.bank_transaction_id from pg_temp._bank_booking b))
  order by t.id for no key update;
  if exists (select 1 from pg_temp._bank_booking) then
    perform pg_advisory_xact_lock(hashtext('remit:' || p_organization_id::text));
  end if;
  perform 1 from public.transfer_file f
  where f.id = any (array(select q.transfer_file_id from pg_temp._bb_keys k
                          cross join lateral (select y.transfer_file_id from public.bank_transfer y
                                              where y.id = k.transfer_id offset 0) q
                          where q.transfer_file_id is not null))
  order by f.id for share;
  perform 1 from public.bank_transfer x
  where x.id = any (array(select k.transfer_id from pg_temp._bb_keys k))
  order by x.id for update;

  -- The facts, read under the locks (one keyed lookup per row: laterals holding only the key).
  drop table if exists pg_temp._bb;
  create temp table _bb on commit drop as
  select b.*, t.organization_id as line_org, t.bank_account_id as line_bank, t.direction, t.currency,
         t.amount_minor as line_minor, t.booking_date as line_date, coalesce(dr.released_kind, t.kind) as line_kind,
         (t.kind = 'suspected_duplicate' and dr.decision is distinct from 'released') as held,
         t.counterparty_iban, t.end_to_end_id, coalesce(t.original_end_to_end_id, t.end_to_end_id) as returned_id,
         t.payment_info_id,
         (t.direction = 'debit' and t.end_to_end_id is null and t.payment_info_id is not null) as batch_line,
         -- booked in the funds, or an own credit released as a relayed debtor payment (booked by its cash_in)
         (exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = b.bank_transaction_id offset 0)
          or exists (select 1 from public.bank_own_credit_release c
                     where c.bank_transaction_id = b.bank_transaction_id offset 0)) as booked,
         (select l.kind from public.bank_debit_link l where l.bank_transaction_id = b.bank_transaction_id) as link_kind,
         coalesce((select -sum(p.amount_minor) from public.bank_debit_link l
                   join public.ledger_posting p on p.entry_id = l.cash_entry_id
                   where l.bank_transaction_id = b.bank_transaction_id and l.kind = 'return'
                     and (select la.book from public.ledger_account la where la.id = p.ledger_account_id)
                         = 'client_money_cash'), 0)::bigint as linked_minor,
         x.organization_id as tr_org, x.kind as tr_kind, x.status as tr_status, x.creditor_bank_account_id as tr_creditor,
         x.debtor_bank_account_id as tr_debtor, x.amount_minor as tr_minor, x.currency as tr_currency,
         x.end_to_end_id as tr_e2e, x.transfer_file_id as tr_file, x.run_id as tr_run,
         x.client_organization_id as tr_client, x.entry_id as tr_entry,
         f.status as file_status, f.download_count as file_downloads,
         (select i.pmt_inf_id from public.transfer_file_item i
          where i.file_id = x.transfer_file_id and i.transfer_id = x.id) as tr_pmt_inf,
         exists (select 1 from public.bank_line_booking k where k.transfer_id = b.transfer_id
                   and k.kind in ('payout', 'sweep', 'top_up') offset 0) as tr_debit_booked,
         exists (select 1 from public.bank_line_booking k where k.transfer_id = b.transfer_id
                   and k.kind in ('payout_returned', 'sweep_returned') offset 0) as tr_return_booked,
         (select e.effective_date from public.ledger_entry e where e.id = x.entry_id) as tr_entry_date,
         ru.status as run_status, ru.transfer_id as run_transfer, ru.payout_account_id as run_payout_account,
         null::uuid as own_bank, null::bigint as book_minor, null::text as why
  from pg_temp._bank_booking b
  left join lateral (select q.organization_id, q.bank_account_id, q.direction, q.currency, q.amount_minor,
                            q.booking_date, q.kind, q.counterparty_iban, q.end_to_end_id, q.original_end_to_end_id,
                            q.payment_info_id
                     from public.bank_transaction q where q.id = b.bank_transaction_id offset 0) t on true
  left join lateral (select q.decision, q.released_kind from public.bank_duplicate_resolution q
                     where q.bank_transaction_id = b.bank_transaction_id offset 0) dr on true
  left join lateral (select q.organization_id, q.kind, q.status, q.creditor_bank_account_id, q.debtor_bank_account_id,
                            q.amount_minor, q.currency, q.end_to_end_id, q.transfer_file_id, q.run_id,
                            q.client_organization_id, q.entry_id, q.id
                     from public.bank_transfer q where q.id = b.transfer_id offset 0) x on true
  left join lateral (select q.status, q.download_count from public.transfer_file q where q.id = x.transfer_file_id
                     offset 0) f on true
  left join lateral (select q.status, q.transfer_id, q.payout_account_id from public.remittance_run q
                     where q.id = x.run_id offset 0) ru on true;
  -- a top-up's own account: its transfer's, or (ops, no transfer) the registered own account the credit came from
  update pg_temp._bb b set own_bank = coalesce(b.tr_debtor, (
    select o.id from public.bank_account o
    where o.organization_id = b.line_org and o.purpose = 'own' and o.status = 'active' and o.iban = b.counterparty_iban
      and o.currency = b.currency))
  where b.kind = 'top_up';
  update pg_temp._bb b set book_minor = case when b.kind = 'loss' then b.amount_minor
                                             when b.kind in ('payout', 'sweep', 'payout_returned', 'sweep_returned')
                                               then b.tr_minor
                                             else b.line_minor end
  where b.bank_transaction_id is not null;

  update pg_temp._bb b set why = case
    when b.line_org is distinct from p_organization_id then 'line_unknown'
    when b.held then 'held_duplicate'
    when b.booked then 'already_booked'
    when b.method = 'ops' and nullif(btrim(b.reason), '') is null then 'reason_required'
    when b.kind = 'fee' then case
      when b.link_kind is not null then 'already_linked'
      -- an other debit only: our own transfers out are booked as sweeps and payouts or left to ops, never as fees
      -- (M2c-1 review: a withdrawal to the own account read as a bank fee); M2c-6b-1: nor a line carrying our RMT/SWP
      -- id or one of our PmtInfIds (plan §2.2)
      when b.direction <> 'debit' or b.line_kind <> 'other_debit' then 'not_a_fee'
      when b.end_to_end_id ~ '^(RMT|SWP)[0-9A-F]{12}$'
           or (b.batch_line and b.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$') then 'not_a_fee'
      when b.transfer_id is not null or b.amount_minor is not null then 'bad_request' end
    when b.kind = 'top_up' then case
      when b.link_kind is not null then 'already_linked'
      when b.direction <> 'credit' or b.line_kind <> 'own_transfer_in' then 'not_an_own_credit'
      when b.amount_minor is not null then 'bad_request'
      when b.transfer_id is not null and (b.tr_org is distinct from p_organization_id or b.tr_kind <> 'top_up'
                                          or b.tr_creditor is distinct from b.line_bank) then 'transfer_unknown'
      when b.transfer_id is not null and b.tr_status <> 'ordered' then 'transfer_not_pending'
      when b.transfer_id is not null and (b.tr_minor <> b.line_minor or b.tr_currency <> b.currency) then 'amount_differs'
      when b.own_bank is null then 'own_account_unknown' end
    when b.kind = 'loss' then case
      -- review round 2 (L4, money-1's defence in depth): never one of our payouts' or sweeps' lines — a line carrying our
      -- RMT/SWP id as its own or as the original it returns, or a batch line of one of our PmtInfIds — whatever kind the
      -- statement gives it: as for every other link (private.post_debit_links), such a line is only booked
      when coalesce(b.end_to_end_id ~ '^(RMT|SWP)[0-9A-F]{12}$', false)
           or coalesce(b.returned_id ~ '^(RMT|SWP)[0-9A-F]{12}$', false)
           or (b.batch_line and b.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$') then 'own_transfer_line'
      when b.direction <> 'debit' or b.line_kind <> 'return' then 'not_a_return'
      when b.link_kind is not null and b.link_kind <> 'return' then 'already_linked'
      when b.transfer_id is not null or b.amount_minor is null or b.amount_minor <= 0 then 'bad_request'
      when b.amount_minor + b.linked_minor <> b.line_minor then 'amount_differs' end
    when b.kind in ('payout', 'sweep') then case
      when b.amount_minor is not null or b.client_organization_id is not null then 'bad_request'
      when b.link_kind is not null then 'already_linked'
      when b.direction <> 'debit' or b.line_kind not in ('transfer_out', 'other_debit', 'batch_unsplit')
        then 'not_a_transfer_line'
      when b.transfer_id is null or b.tr_org is distinct from p_organization_id or b.tr_kind is distinct from b.kind
        then 'transfer_unknown'
      -- own id first (plan §2.4 rule 1): a line carrying an end-to-end id is that id's transfer only — a re-issue is
      -- never booked by its predecessor's id; a batch line names the transfer's PmtInf in its current file (rule 2)
      when not coalesce(b.end_to_end_id = b.tr_e2e or (b.batch_line and b.payment_info_id = b.tr_pmt_inf), false)
        then 'not_its_line'
      when b.tr_status = 'cancelled' then 'cancelled_transfer_debited'
      when b.tr_status in ('booked', 'returned') or b.tr_debit_booked then 'transfer_debited_twice'
      when b.tr_status <> 'in_file' or coalesce(b.file_downloads, 0) = 0
           or b.file_status not in ('downloaded', 'sent') then 'transfer_not_handed_out'
      when b.tr_debtor is distinct from b.line_bank or b.tr_currency is distinct from b.currency then 'transfer_differs'
      when not b.batch_line and b.tr_minor <> b.line_minor then 'transfer_differs'
      when b.kind = 'payout' and (b.run_status is null or b.run_status not in ('approved', 'sent')
                                  or b.run_transfer is distinct from b.transfer_id) then 'run_not_in_flight' end
    when b.kind in ('payout_returned', 'sweep_returned') then case
      when b.amount_minor is not null or b.client_organization_id is not null then 'bad_request'
      when b.link_kind is not null then 'already_linked'
      when b.direction <> 'credit' or b.line_kind <> 'return' then 'not_a_return'
      when b.transfer_id is null or b.tr_org is distinct from p_organization_id
           or b.tr_kind is distinct from case b.kind when 'payout_returned' then 'payout' else 'sweep' end
        then 'transfer_unknown'
      when b.returned_id is distinct from b.tr_e2e then 'not_its_line'
      when b.tr_status in ('ordered', 'in_file') then 'return_before_debit'
      when b.tr_status = 'returned' or b.tr_return_booked then 'already_returned'
      when b.tr_status <> 'booked' or not b.tr_debit_booked or b.tr_entry is null then 'return_differs'
      when b.tr_debtor is distinct from b.line_bank or b.tr_currency is distinct from b.currency then 'transfer_differs'
      when b.line_minor > b.tr_minor then 'return_differs'
      when b.line_date < b.tr_entry_date then 'return_before_debit' end
    -- the unplanned kinds are ops' (M2c-6b-2: public.book_transfer_line)
    else 'bad_request'
  end
  where b.bank_transaction_id is not null;  -- (every row: PostgREST sessions refuse an UPDATE without WHERE)

  -- A line is one kind of booking (the job's): a payout, sweep or return line holds nothing else.
  update pg_temp._bb b set why = 'bad_request'
  where b.why is null and exists (select 1 from pg_temp._bb o where o.bank_transaction_id = b.bank_transaction_id
                                    and o.kind <> b.kind
                                    and (o.kind in ('payout', 'sweep', 'payout_returned', 'sweep_returned')
                                         or b.kind in ('payout', 'sweep', 'payout_returned', 'sweep_returned')));
  -- A batch line (plan §2.3 row 3, §2.4 rule 2): booked only for exactly the in_file members of the PmtInf it names, in
  -- its file of the line's account (the members that file holds), none cancelled (but returned), of one kind, adding up
  -- to the line — never a « best subset ». The members are read under their locks.
  update pg_temp._bb b set why = w.why
  from (
    select l.bank_transaction_id,
           case
             when count(m.id) = 0 then 'transfer_unknown'
             when bool_or(m.status = 'cancelled' and not m.returned) then 'cancelled_transfer_debited'
             when bool_and(m.status = 'in_file' and (coalesce(m.download_count, 0) = 0
                                                     or m.file_status not in ('downloaded', 'sent')))
               then 'transfer_not_handed_out'
             when count(m.id) filter (where m.status = 'in_file') = 0 then 'transfer_debited_twice'
             when count(distinct m.kind) filter (where m.status = 'in_file') > 1
                  or bool_or(m.status = 'in_file' and m.kind = 'refund') then 'batch_mixed'
             when coalesce(sum(m.amount_minor) filter (where m.status = 'in_file'), 0) <> l.line_minor
               then 'batch_partial'
             when (array_agg(m.id order by m.id) filter (where m.status = 'in_file'))
                  is distinct from (select array_agg(o.transfer_id order by o.transfer_id) from pg_temp._bb o
                                    where o.bank_transaction_id = l.bank_transaction_id) then 'batch_incomplete'
           end as why
    from (select distinct o.bank_transaction_id, o.line_bank, o.payment_info_id, o.line_minor from pg_temp._bb o
          where o.batch_line and o.kind in ('payout', 'sweep') and o.why is null) l
    left join lateral (
      select t.id, t.kind, t.status, t.amount_minor, fl.download_count, fl.status as file_status,
             case when t.status = 'cancelled' then private.transfer_return_seen(t.id) else false end as returned
      from (select y.file_id, y.transfer_id from public.transfer_file_item y
            where y.pmt_inf_id = l.payment_info_id offset 0) i
      cross join lateral (select q.debtor_bank_account_id, q.status, q.download_count from public.transfer_file q
                          where q.id = i.file_id offset 0) fl
      cross join lateral (select q.id, q.kind, q.status, q.amount_minor, q.transfer_file_id from public.bank_transfer q
                          where q.id = i.transfer_id offset 0) t
      where fl.debtor_bank_account_id = l.line_bank and t.transfer_file_id = i.file_id) m on true
    group by l.bank_transaction_id, l.line_minor) w
  where b.bank_transaction_id = w.bank_transaction_id and b.why is null and w.why is not null;
  -- a transfer booked once per call (a later line waits: ops, or the next run)
  update pg_temp._bb b set why = 'transfer_twice'
  where b.why is null and b.transfer_id is not null
    and exists (select 1 from pg_temp._bb o where o.transfer_id = b.transfer_id and o.why is null and o.ord < b.ord
                  and o.bank_transaction_id <> b.bank_transaction_id
                  and (o.kind in ('payout_returned', 'sweep_returned')) = (b.kind in ('payout_returned', 'sweep_returned')));
  -- one refused row refuses its line (a line is booked whole)
  update pg_temp._bb b set why = w.why
  from (select distinct on (o.bank_transaction_id) o.bank_transaction_id, o.why from pg_temp._bb o
        where o.why is not null order by o.bank_transaction_id, o.ord) w
  where b.bank_transaction_id = w.bank_transaction_id and b.why is null;

  select b.why into v_why from pg_temp._bb b where b.why is not null order by b.ord limit 1;
  if found and p_strict then
    if v_why.why = 'own_transfer_line' then
      raise exception 'bank booking refused: %', v_why.why using errcode = 'check_violation',
        hint = 'Cette ligne est un débit ou un retour de nos propres virements (reversement, quote-part du cabinet, lot '
               'de notre fichier) : elle se comptabilise depuis le relevé, automatiquement ou par l''équipe (écran à '
               'venir). Elle ne se rattache pas à un paiement et ne se classe pas sans comptabilisation.';
    end if;
    raise exception 'bank booking refused: %', v_why.why using errcode = 'check_violation';
  end if;
  insert into pg_temp._booking_skipped (bank_transaction_id, why)
  select distinct on (b.bank_transaction_id) b.bank_transaction_id, b.why from pg_temp._bb b where b.why is not null
  order by b.bank_transaction_id, b.ord
  on conflict (bank_transaction_id) do update set why = excluded.why;
  delete from pg_temp._bb b where b.why is not null;
  analyze pg_temp._bb;

  if p_strict then
    begin
      perform private.bank_booking_post_rows(p_organization_id);
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
      if v_state like 'LG%' or v_state like '22%' or v_state like '23%' then
        raise exception 'bank booking refused: posting_failed (%: %)', v_state, left(v_msg, 500)
          using errcode = 'check_violation';
      end if;
      raise;
    end;
  elsif exists (select 1 from pg_temp._bb) then
    begin
      perform private.bank_booking_post_rows(p_organization_id);   -- the whole chunk at once
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if not (v_state like 'LG%' or v_state like '22%' or v_state like '23%') then
        raise;
      end if;
      -- a line the posting refuses: each LINE tried alone with all its rows (always rolled back), the refused ones to
      -- ops, then the others together
      drop table if exists pg_temp._bb_all;
      create temp table _bb_all on commit drop as select * from pg_temp._bb;
      for v_l in select a.bank_transaction_id from pg_temp._bb_all a group by a.bank_transaction_id
               order by min(a.ord) loop
        begin
          delete from pg_temp._bb b where b.bank_transaction_id is not null;
          insert into pg_temp._bb select * from pg_temp._bb_all a where a.bank_transaction_id = v_l.bank_transaction_id;
          perform private.bank_booking_post_rows(p_organization_id);
          raise exception 'bank booking tried' using errcode = 'BB000';
        exception when others then
          get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
          if v_state <> 'BB000' then
            if not (v_state like 'LG%' or v_state like '22%' or v_state like '23%') then
              raise;
            end if;
            insert into pg_temp._booking_failed (bank_transaction_id, detail)
            values (v_l.bank_transaction_id, left(v_state || ': ' || v_msg, 2000))
            on conflict (bank_transaction_id) do nothing;
          end if;
        end;
      end loop;
      delete from pg_temp._bb b where b.bank_transaction_id is not null;
      insert into pg_temp._bb select * from pg_temp._bb_all a
      where not exists (select 1 from pg_temp._booking_failed f where f.bank_transaction_id = a.bank_transaction_id);
      if exists (select 1 from pg_temp._bb) then
        perform private.bank_booking_post_rows(p_organization_id);
      end if;
    end;
  end if;

  -- M2c-1's counts, then (only when some were posted) the debits' bookings
  return jsonb_build_object(
    'fees', (select count(*) from pg_temp._bb where kind = 'fee'),
    'top_ups', (select count(*) from pg_temp._bb where kind = 'top_up'),
    'losses', (select count(*) from pg_temp._bb where kind = 'loss'),
    'skipped', (select count(*) from pg_temp._booking_skipped),
    'failed', (select count(*) from pg_temp._booking_failed))
    || jsonb_strip_nulls(jsonb_build_object(
         'payouts', (select nullif(count(*), 0) from pg_temp._bb where kind = 'payout'),
         'sweeps', (select nullif(count(*), 0) from pg_temp._bb where kind = 'sweep'),
         'returns', (select nullif(count(*), 0) from pg_temp._bb where kind in ('payout_returned', 'sweep_returned')),
         'advances', (select nullif(count(*), 0) from pg_temp._bb_cover)));
end;
$$;

-- The job's decisions (pg_temp._bank_booking: automatic bookings; pg_temp._booking_review: lines left to ops): bookings
-- posted, the lines' reviews replaced (redefined from 20261111090000: a line the re-check refused keeps its code in the
-- review's detail, `changed`; review T4/K5: a return dated before its debit — the line's own fault, not a change since
-- the job read it — is reviewed `return_before_debit`, as the job's rules review it).
create or replace function private.apply_bank_bookings(p_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v jsonb;
begin
  update pg_temp._bank_booking set method = 'auto', decided_by = null where bank_transaction_id is not null;
  v := private.post_bank_bookings(p_organization_id, false);
  insert into pg_temp._booking_review (bank_transaction_id, reason, detail)
  select f.bank_transaction_id, 'posting_failed', f.detail from pg_temp._booking_failed f
  on conflict (bank_transaction_id) do update set reason = excluded.reason, detail = excluded.detail;
  insert into pg_temp._booking_review (bank_transaction_id, reason, detail)
  select s.bank_transaction_id, case when s.why = 'return_before_debit' then s.why else 'changed' end,
         case when s.why = 'return_before_debit' then null else s.why end
  from pg_temp._booking_skipped s
  on conflict (bank_transaction_id) do nothing;
  delete from public.bank_debit_review v using pg_temp._booking_review r where v.bank_transaction_id = r.bank_transaction_id;
  insert into public.bank_debit_review (bank_transaction_id, organization_id, reason, candidates, detail)
  select r.bank_transaction_id, p_organization_id, r.reason, r.candidates, r.detail
  from pg_temp._booking_review r
  cross join lateral (select q.organization_id from public.bank_transaction q
                      where q.id = r.bank_transaction_id offset 0) t
  where t.organization_id = p_organization_id
    and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = r.bank_transaction_id offset 0)
    and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = r.bank_transaction_id offset 0)
    and not exists (select 1 from public.bank_own_credit_release c
                    where c.bank_transaction_id = r.bank_transaction_id offset 0);
  return v || jsonb_build_object('reviews', (select count(*) from pg_temp._booking_review));
end;
$$;

-- Each booking fits its line, its entry and its transfer (redefined from 20261111090000; per kind, plan §2.5): a payout
-- (or an unplanned one) is a `remittance` from the line's account, its document the payout transfer (or the line when
-- none); a sweep a `servicer_sweep`; a returned payout or sweep the reversal of that transfer's entry on a credit
-- `return`; a fee an other debit's (or the charge on a returned transfer: a credit `return`, checked whole at commit);
-- a loss, a top-up as before; a client's payment (M2c-7) a `client_payment_dedicated` of a client's credit. A line an
-- M2b link booked may carry only a loss; a payment's line never. One keyed lookup per row (kept lateral).
create or replace function private.bank_line_booking_guard()
returns trigger
language plpgsql
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
as $$
declare v_bad text;
begin
  select min(n.bank_transaction_id::text || ':' || n.seq) into v_bad
  from new_rows n
  cross join lateral (
    select t.organization_id, t.bank_account_id, t.direction, t.booking_date,
           case when t.kind = 'suspected_duplicate' then r.released_kind else t.kind end as kind,
           e.entry_type, e.effective_date, e.source_type, e.source_id, e.organization_id as entry_org,
           e.reverses_entry_id,
           (select l.kind from public.bank_debit_link l where l.bank_transaction_id = t.id) as link_kind,
           exists (select 1 from public.payment p where p.bank_transaction_id = t.id offset 0) as paid,
           (select x.creditor_bank_account_id from public.bank_transfer x where x.id = n.transfer_id) as tr_creditor,
           (select x.debtor_bank_account_id from public.bank_transfer x where x.id = n.transfer_id) as tr_debtor,
           (select x.kind from public.bank_transfer x where x.id = n.transfer_id) as tr_kind,
           (select x.entry_id from public.bank_transfer x where x.id = n.transfer_id) as tr_entry,
           (select count(*) from public.ledger_posting p
            where p.entry_id = n.entry_id
              and (select la.bank_account_id from public.ledger_account la where la.id = p.ledger_account_id)
                  = t.bank_account_id) as on_line_bank
    from public.bank_transaction t
    left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
    left join public.ledger_entry e on e.id = n.entry_id
    where t.id = n.bank_transaction_id
    offset 0) x
  where x.organization_id <> n.organization_id or x.bank_account_id <> n.bank_account_id
     or x.entry_org is distinct from n.organization_id or x.effective_date is distinct from x.booking_date
     or x.on_line_bank <> 1
     or x.kind is null
     -- a line explained without booking, or a payment's return or refund, is not also booked; a loss completes a
     -- return of what was left of its payment; a line that is a payment is booked by its cash_in, never in the funds
     or (x.link_kind is not null and not (n.kind = 'loss' and x.link_kind = 'return'))
     or x.paid
     or case n.kind
          when 'fee' then not (x.entry_type = 'bank_fee' and n.transfer_id is null
                               and x.source_type = 'bank_transaction' and x.source_id = n.bank_transaction_id::text
                               and ((x.direction = 'debit' and x.kind = 'other_debit')
                                    or (x.direction = 'credit' and x.kind = 'return')))
          when 'loss' then not (x.entry_type = 'servicer_loss' and n.transfer_id is null and x.direction = 'debit'
                                and x.kind = 'return' and x.source_type = 'bank_transaction'
                                and x.source_id = n.bank_transaction_id::text)
          when 'top_up' then not (x.entry_type = 'servicer_top_up' and x.direction = 'credit'
                                  and x.kind = 'own_transfer_in'
                                  and ((n.transfer_id is null and x.source_type = 'bank_transaction'
                                        and x.source_id = n.bank_transaction_id::text)
                                       or (n.transfer_id is not null and x.tr_kind = 'top_up'
                                           and x.tr_creditor = n.bank_account_id and x.source_type = 'bank_transfer'
                                           and x.source_id = n.transfer_id::text)))
          when 'payout' then not (x.entry_type = 'remittance' and x.direction = 'debit'
                                  and x.kind in ('transfer_out', 'other_debit', 'batch_unsplit')
                                  and n.transfer_id is not null and x.tr_kind = 'payout'
                                  and x.tr_debtor = n.bank_account_id and x.source_type = 'bank_transfer'
                                  and x.source_id = n.transfer_id::text)
          when 'unplanned_payout' then not (x.entry_type = 'remittance' and x.direction = 'debit'
                                            and x.kind in ('transfer_out', 'other_debit', 'batch_unsplit')
                                            and ((n.transfer_id is null and x.source_type = 'bank_transaction'
                                                  and x.source_id = n.bank_transaction_id::text)
                                                 or (n.transfer_id is not null and x.tr_kind = 'payout'
                                                     and x.tr_debtor = n.bank_account_id
                                                     and x.source_type = 'bank_transfer'
                                                     and x.source_id = n.transfer_id::text)))
          when 'sweep' then not (x.entry_type = 'servicer_sweep' and x.direction = 'debit'
                                 and x.kind in ('transfer_out', 'other_debit', 'batch_unsplit')
                                 and n.transfer_id is not null and x.tr_kind = 'sweep'
                                 and x.tr_debtor = n.bank_account_id and x.source_type = 'bank_transfer'
                                 and x.source_id = n.transfer_id::text)
          when 'unplanned_sweep' then not (x.entry_type = 'servicer_sweep' and x.direction = 'debit'
                                           and x.kind in ('transfer_out', 'other_debit', 'batch_unsplit')
                                           and ((n.transfer_id is null and x.source_type = 'bank_transaction'
                                                 and x.source_id = n.bank_transaction_id::text)
                                                or (n.transfer_id is not null and x.tr_kind = 'sweep'
                                                    and x.tr_debtor = n.bank_account_id
                                                    and x.source_type = 'bank_transfer'
                                                    and x.source_id = n.transfer_id::text)))
          when 'payout_returned' then not (x.entry_type = 'reversal' and x.direction = 'credit' and x.kind = 'return'
                                           and n.transfer_id is not null and x.tr_kind = 'payout'
                                           and x.tr_debtor = n.bank_account_id
                                           and x.reverses_entry_id is not distinct from x.tr_entry)
          when 'sweep_returned' then not (x.entry_type = 'reversal' and x.direction = 'credit' and x.kind = 'return'
                                          and n.transfer_id is not null and x.tr_kind = 'sweep'
                                          and x.tr_debtor = n.bank_account_id
                                          and x.reverses_entry_id is not distinct from x.tr_entry)
          when 'client_payment' then not (x.entry_type = 'client_payment_dedicated' and x.direction = 'credit'
                                          and x.kind = 'client_transfer_in' and n.transfer_id is null
                                          and x.source_type = 'bank_transaction'
                                          and x.source_id = n.bank_transaction_id::text)
          else true end;
  if v_bad is not null then
    raise exception 'bank line booking %: it does not match its line, entry or transfer', v_bad
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;

-- At commit (redefined from 20261111090000, plan §2.5): what a line's bookings and its M2b link (a return's or a
-- refund's cash_out) moved on its account's 5120 is its amount, signed — + for a credit, − for a debit (I19 per line;
-- the unsigned sum refused a return with charges: its reversal +N and its fee −(N − line)). Still one deferred row
-- trigger, but it checks only for the line's last booking (keyed: the line's bookings by its key), so a batch line of
-- 5,000 members is summed once, not 5,000 times.
create or replace function private.bank_line_booking_check()
returns trigger
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  t record;
  v_moved bigint;
begin
  if new.seq < (select max(b.seq) from public.bank_line_booking b where b.bank_transaction_id = new.bank_transaction_id)
  then
    return null;
  end if;
  select q.direction, q.amount_minor, q.bank_account_id into t from public.bank_transaction q
  where q.id = new.bank_transaction_id;
  v_moved := private.bank_line_cash_moved(new.bank_transaction_id, t.bank_account_id);
  if v_moved <> (case t.direction when 'credit' then t.amount_minor else -t.amount_minor end) then
    raise exception 'bank line %: booked % of its % %', new.bank_transaction_id, v_moved,
      case t.direction when 'credit' then '+' else '-' end, t.amount_minor
      using errcode = 'LG001';
  end if;
  return null;
end;
$$;

------------------------------------------------------------------------------------------
-- The M2b pass (redefined from 20261111090000): a credit returning our payout or sweep is no longer its candidate (the
-- funds pass books it); a batch line of one refund alone is (plan §2.2 [critic]: the M2b pass links it, never the
-- funds pass after the allocation lock); a link refuses our transfers' lines (§2.4 rule 5; review money-1: whatever
-- its kind — `own_transfer_line`) but a refund whose transfer is in a file handed out (the refund's trigger then admits
-- only a batch line of its own PmtInf in that file), and takes a batch line kept unsplit as a refund when it is that
-- PmtInf. Same settings.
------------------------------------------------------------------------------------------

create or replace function private.debit_candidates(p_organization_id uuid, p_after_date date, p_after_id uuid,
                                                    p_limit integer)
returns table (line_id uuid, line_kind text, direction text, bank_account_id uuid, amount_minor bigint,
               booking_date date, payment_id uuid, refund_request_id uuid, via text, cand_bank_account_id uuid,
               cand_amount_minor bigint, cand_left_minor bigint, cand_unallocated_minor bigint,
               cand_pending_minor bigint, cand_status text, cand_date date, cand_payment_status text,
               cand_free_from date)
language plpgsql
security definer
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
as $$
#variable_conflict use_column
begin
  drop table if exists pg_temp._dc_line;
  create temp table _dc_line on commit drop as
  select x.* from (
    select t.id, coalesce(r.released_kind, t.kind) as kind, t.direction, t.bank_account_id, t.amount_minor,
           t.booking_date, t.end_to_end_id, t.original_end_to_end_id, t.tx_id, null::uuid as single_refund
    from public.bank_transaction t
    left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
    where t.organization_id = p_organization_id
      and t.kind in ('return', 'refund_out', 'suspected_duplicate')
      and (p_after_date is null or (t.booking_date, t.id) > (p_after_date, p_after_id))
      and (t.kind <> 'suspected_duplicate' or r.decision = 'released')
      -- M2c-6b-1: a credit returning our payout or sweep (its RMT/SWP id) is the funds pass's
      and not (t.direction = 'credit'
               and coalesce(t.original_end_to_end_id, t.end_to_end_id) ~ '^(RMT|SWP)[0-9A-F]{12}$')
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id offset 0)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id offset 0)
    union all
    -- M2c-6b-1 (plan §2.2 [critic]): a batch line (no end-to-end id) whose PmtInf, in a file of the line's account
    -- handed out, holds one refund alone: that refund's debit, linked here as M2b links an RFD line (its trigger,
    -- private.refund_transfer_follow, accepts its own PmtInf in its current file)
    select t.id, t.kind, t.direction, t.bank_account_id, t.amount_minor, t.booking_date, t.end_to_end_id,
           t.original_end_to_end_id, t.tx_id, s.refund_transfer
    from public.bank_transaction t
    cross join lateral (select private.pmt_inf_single_refund(t.bank_account_id, t.payment_info_id) as refund_transfer
                        offset 0) s
    where t.organization_id = p_organization_id and t.direction = 'debit' and t.end_to_end_id is null
      and t.payment_info_id is not null and t.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$'
      and t.kind in ('other_debit', 'batch_unsplit')
      and (p_after_date is null or (t.booking_date, t.id) > (p_after_date, p_after_id))
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id offset 0)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id offset 0)
      and s.refund_transfer is not null) x
  where (x.direction = 'debit' and x.kind in ('return', 'refund_out')) or (x.direction = 'credit' and x.kind = 'return')
     or x.single_refund is not null
  order by x.booking_date, x.id
  limit greatest(coalesce(p_limit, 10000), 1);
  analyze pg_temp._dc_line;

  drop table if exists pg_temp._dc_cand;
  create temp table _dc_cand on commit drop as
  -- a return of a credit: the payment that carries its end-to-end id, or whose line carries its bank transaction id
  select x.id as line_id, c.payment_id, null::uuid as refund_request_id, c.via
  from pg_temp._dc_line x
  cross join lateral (
    select p.id as payment_id, 'end_to_end_id'::text as via
    from (select q.id, q.bank_account_id from public.payment q
          where q.end_to_end_id = coalesce(x.original_end_to_end_id, x.end_to_end_id) offset 0) p
    where p.bank_account_id = x.bank_account_id
    union
    select p.id, 'tx_id'
    from public.bank_transaction o
    cross join lateral (select q.id from public.payment q where q.bank_transaction_id = o.id offset 0) p
    where x.tx_id is not null and o.bank_account_id = x.bank_account_id and o.tx_id = x.tx_id and o.direction = 'credit'
  ) c
  where x.direction = 'debit' and x.kind = 'return'
  union all
  -- our refund: the request whose RFD id the debit carries; a refund that came back: the one the credit names
  select x.id, q.payment_id, q.id, 'end_to_end_id'
  from pg_temp._dc_line x
  cross join lateral (select r.id, r.payment_id, r.organization_id, r.bank_account_id from public.refund_request r
                      where r.end_to_end_id = case when x.direction = 'debit' then x.end_to_end_id
                                                   else coalesce(x.original_end_to_end_id, x.end_to_end_id) end
                      offset 0) q
  where (x.kind = 'refund_out' or (x.direction = 'credit' and x.kind = 'return'))
    and q.organization_id = p_organization_id and q.bank_account_id = x.bank_account_id   -- never another tenant's
  union all
  -- M2c-6b-1: the refund a single-refund batch line is (by its transfer)
  select x.id, q.payment_id, q.id, 'payment_info_id'
  from pg_temp._dc_line x
  cross join lateral (select r.id, r.payment_id, r.organization_id, r.bank_account_id from public.refund_request r
                      where r.transfer_id = x.single_refund offset 0) q
  where x.single_refund is not null
    and q.organization_id = p_organization_id and q.bank_account_id = x.bank_account_id;
  create index on pg_temp._dc_cand (line_id);
  analyze pg_temp._dc_cand;

  -- Each payment named, once: its position, its pending refunds, its free-from date (keyed lookups per payment).
  drop table if exists pg_temp._dc_pos;
  create temp table _dc_pos on commit drop as
  select x.payment_id, x.amount_minor - x.returned_minor as left_minor, x.unallocated_minor,
         coalesce((select sum(z.amount_minor) from public.refund_request z
                   where z.payment_id = x.payment_id and z.status = 'requested'), 0)::bigint as pending_minor,
         (select max(e.effective_date) from public.ledger_entry e
          join public.ledger_entry v on v.id = e.reverses_entry_id
          where e.payment_id = x.payment_id and e.effective_date > v.effective_date) as free_from
  from private.payment_positions(array(select distinct y.payment_id from pg_temp._dc_cand y
                                       where y.payment_id is not null)) x;
  alter table pg_temp._dc_pos add primary key (payment_id);
  analyze pg_temp._dc_pos;

  return query
  select x.id, x.kind, x.direction, x.bank_account_id, x.amount_minor, x.booking_date, c.payment_id, c.refund_request_id,
         c.via, coalesce(q.bank_account_id, p.bank_account_id), coalesce(q.amount_minor, p.amount_minor),
         pos.left_minor, pos.unallocated_minor, pos.pending_minor,
         coalesce(q.status, p.status), coalesce(q.executed_on, p.booking_date), p.status, pos.free_from
  from pg_temp._dc_line x
  left join pg_temp._dc_cand c on c.line_id = x.id
  left join lateral (select z.bank_account_id, z.amount_minor, z.status, z.booking_date from public.payment z
                     where z.id = c.payment_id offset 0) p on true
  left join lateral (select z.bank_account_id, z.amount_minor, z.status, z.executed_on from public.refund_request z
                     where z.id = c.refund_request_id offset 0) q on true
  left join pg_temp._dc_pos pos on pos.payment_id = c.payment_id
  order by x.booking_date, x.id, c.payment_id;
end;
$$;

create or replace function private.post_debit_links(p_organization_id uuid, p_strict boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_why record;
  r record;
  v_state text;
  v_msg text;
begin
  -- a refund (or its bounce) is the request's payment
  update pg_temp._debit_link l set payment_id = q.payment_id
  from public.refund_request q where q.id = l.refund_request_id and l.payment_id is null;
  analyze pg_temp._debit_link;

  perform 1 from public.account a
  where a.id in (select p.account_id from public.payment p
                 where p.id in (select l.payment_id from pg_temp._debit_link l where l.payment_id is not null))
  order by a.id for key share;
  perform 1 from public.payment p
  where p.id in (select l.payment_id from pg_temp._debit_link l where l.payment_id is not null)
  order by p.id for update;
  perform 1 from public.refund_request q
  where q.payment_id in (select l.payment_id from pg_temp._debit_link l where l.payment_id is not null)
  order by q.id for update;
  perform 1 from public.bank_account b
  where b.id in (select t.bank_account_id from public.bank_transaction t
                 where t.id in (select l.bank_transaction_id from pg_temp._debit_link l))
  order by b.id for share;
  perform pg_advisory_xact_lock(hashtext('payments:' || p_organization_id::text));
  -- M2c: the lines themselves (the lock every decision on a line takes: a booking in private.post_bank_bookings, an
  -- own credit released as a payment; review fix: a line was linked here and booked there at once, each not seeing
  -- the other). After the allocation lock: the job holds it while its funds pass locks lines.
  perform 1 from public.bank_transaction t
  where t.id = any (array(select l.bank_transaction_id from pg_temp._debit_link l))
  order by t.id for no key update;

  -- The facts, read under the locks. free_from: the latest reversal of the payment dated after the entry it reverses
  -- (a return, a refund that bounced, an allocation ops reversed later): until then its money was allocated or out, so
  -- nothing goes out of it before that date (I4; post_allocations' not_before). One keyed lookup per link (laterals
  -- holding only the key).
  drop table if exists pg_temp._dl;
  create temp table _dl on commit drop as
  select l.*, t.organization_id as line_org, t.bank_account_id as line_bank, t.direction, t.currency,
         coalesce(l.amount_minor, t.amount_minor) as line_minor, t.booking_date as line_date,
         coalesce(dr.released_kind, t.kind) as line_kind, t.end_to_end_id as line_e2e,
         coalesce(t.original_end_to_end_id, t.end_to_end_id) as line_returned_id,
         -- M2c-6b-1: a debit with no end-to-end id carrying the PmtInfId of one of our files (a batch line)
         coalesce(t.direction = 'debit' and t.end_to_end_id is null
                  and t.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$'
                  and exists (select 1 from public.transfer_file_item i
                              cross join lateral (select f.debtor_bank_account_id from public.transfer_file f
                                                  where f.id = i.file_id offset 0) f
                              where i.pmt_inf_id = t.payment_info_id and f.debtor_bank_account_id = t.bank_account_id),
                  false) as our_batch_line,
         -- review round 2 (L5, K1 with the switch on): that PmtInf has, in its current file, a member cancelled and not
         -- returned by the bank — the line may be that cancelled transfer's execution (the funds pass's P0,
         -- cancelled_transfer_debited); a refund linked to it would hide it
         coalesce(t.direction = 'debit' and t.end_to_end_id is null
                  and t.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$'
                  and exists (select 1 from public.transfer_file_item i
                              cross join lateral (select f.debtor_bank_account_id from public.transfer_file f
                                                  where f.id = i.file_id offset 0) f
                              cross join lateral (select m.status, m.transfer_file_id from public.bank_transfer m
                                                  where m.id = i.transfer_id offset 0) m
                              where i.pmt_inf_id = t.payment_info_id and f.debtor_bank_account_id = t.bank_account_id
                                and m.transfer_file_id = i.file_id and m.status = 'cancelled'
                                and not private.transfer_return_seen(i.transfer_id)),
                  false) as pmt_inf_cancelled,
         -- the request's transfer in a file handed out to the bank (its PmtInf the only batch line that can execute it)
         coalesce(rt.status = 'in_file' and rf.status in ('downloaded', 'sent'), false) as req_handed_out,
         (t.kind = 'suspected_duplicate' and dr.decision is distinct from 'released') as held,
         exists (select 1 from public.bank_debit_link x where x.bank_transaction_id = l.bank_transaction_id offset 0)
           as linked,
         -- booked in the funds, or an own credit released as a relayed debtor payment
         (exists (select 1 from public.bank_line_booking x where x.bank_transaction_id = l.bank_transaction_id offset 0)
          or exists (select 1 from public.bank_own_credit_release x
                     where x.bank_transaction_id = l.bank_transaction_id offset 0)) as booked,
         p.organization_id as pay_org, p.bank_account_id as pay_bank, p.booking_date as pay_date, p.status as pay_status,
         p.account_id, p.amount_minor as pay_minor, nb.d as free_from,
         q.payment_id as req_payment, q.status as req_status, q.amount_minor as req_minor, q.bank_account_id as req_bank,
         q.cash_out_entry_id as req_entry, q.executed_on as req_executed_on, q.prior_status as req_prior_status,
         q.prior_review_reason as req_prior_reason,
         0::bigint as allocated, 0::bigint as returned, 0::bigint as unallocated, 0::bigint as pending,
         null::text as why, null::uuid as cash_entry_id
  from pg_temp._debit_link l
  left join lateral (select x.organization_id, x.bank_account_id, x.direction, x.currency, x.amount_minor,
                            x.booking_date, x.kind, x.end_to_end_id, x.payment_info_id, x.original_end_to_end_id
                     from public.bank_transaction x where x.id = l.bank_transaction_id offset 0) t on true
  left join lateral (select x.decision, x.released_kind from public.bank_duplicate_resolution x
                     where x.bank_transaction_id = l.bank_transaction_id offset 0) dr on true
  left join lateral (select x.organization_id, x.bank_account_id, x.booking_date, x.status, x.account_id, x.amount_minor
                     from public.payment x where x.id = l.payment_id offset 0) p on true
  left join lateral (select x.payment_id, x.status, x.amount_minor, x.bank_account_id, x.cash_out_entry_id,
                            x.executed_on, x.prior_status, x.prior_review_reason, x.transfer_id
                     from public.refund_request x where x.id = l.refund_request_id offset 0) q on true
  left join lateral (select x.status, x.transfer_file_id from public.bank_transfer x where x.id = q.transfer_id
                     offset 0) rt on true
  left join lateral (select x.status from public.transfer_file x where x.id = rt.transfer_file_id offset 0) rf on true
  left join lateral (select max(e.effective_date) as d from public.ledger_entry e
                     join public.ledger_entry v on v.id = e.reverses_entry_id
                     where e.payment_id = l.payment_id and e.effective_date > v.effective_date) nb on true;
  update pg_temp._dl d set allocated = x.allocated_minor, returned = x.returned_minor, unallocated = x.unallocated_minor
  from private.payment_positions(array(select l.payment_id from pg_temp._debit_link l where l.payment_id is not null)) x
  where x.payment_id = d.payment_id;
  update pg_temp._dl d set pending = s.total
  from (select q.payment_id, sum(q.amount_minor) as total from public.refund_request q
        where q.payment_id in (select l.payment_id from pg_temp._debit_link l) and q.status = 'requested'
        group by q.payment_id) s
  where s.payment_id = d.payment_id;

  update pg_temp._dl d set why = case
    when d.line_org is distinct from p_organization_id then 'line_unknown'
    when d.linked then 'already_linked'
    when d.booked then 'already_booked'
    -- a part of a line (M2c: the return of what is left of a payment, its excess the servicer's loss) is ops' only
    when d.amount_minor is not null and (d.method <> 'ops' or d.kind <> 'return' or d.amount_minor <= 0) then 'bad_request'
    when d.held then 'held_duplicate'
    -- M2c-6b-1 (plan §2.4 rule 5 [critic]; review money-1): our payouts' and sweeps' lines — a debit carrying our
    -- RMT/SWP id, a batch line of one of our files (whatever kind the bank's statement gives it), a credit returning one
    -- of them — are only ever booked (private.post_bank_bookings: the job, or ops in M2c-6b-2), never a payment's
    -- return (nor its loss), a refund, a refund that came back or an explanation: one person's link would hide the
    -- payouts' debits, their returns' items and the P0 alerts (cancelled_transfer_debited, transfer_not_handed_out).
    -- The one link a batch line takes: a refund whose transfer is in a file handed out to the bank (downloaded or sent)
    -- — the refund a PmtInf of one refund alone is (private.pmt_inf_single_refund, the M2b pass's), or ops' link of a
    -- refund of a PmtInf of refunds — which private.refund_transfer_follow (M2c-6a round 6's G2 rule) then executes
    -- only by a batch line of its own PmtInf in that file, refusing any other (reissue_in_downloaded_file); never a
    -- manual refund (no transfer), nor one whose transfer is not handed out (nothing the bank could have debited).
    -- Review round 2: a line whose own or original id is one of ours, whatever its direction and kind (L4: a debit
    -- « return » naming our RMT id as its original included); and the refund exception only while its PmtInf has no
    -- member cancelled and not returned in its current file (L5: with the cancellation after download on, the line may
    -- be that cancelled transfer's debit — the funds pass reviews it cancelled_transfer_debited).
    when (coalesce(d.line_e2e ~ '^(RMT|SWP)[0-9A-F]{12}$', false)
          or coalesce(d.line_returned_id ~ '^(RMT|SWP)[0-9A-F]{12}$', false) or d.our_batch_line)
         and not (d.kind = 'refund' and d.our_batch_line and d.req_handed_out and not d.pmt_inf_cancelled)
      then 'own_transfer_line'
    -- our own transfers out and the credits from our own account or a client are never a payment's return, refund or
    -- refund that came back (whatever payment or request is named)
    when d.kind <> 'explained' and d.line_kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in')
      then 'not_a_return'
    when d.kind = 'explained' then case
      when d.payment_id is not null or d.refund_request_id is not null then 'bad_request'
      when d.direction = 'credit' and d.line_kind in ('debtor_credit', 'batch_unsplit') then 'payment_line'
      -- money that went back out for one of our payments is booked, never only explained: our refund (RFD id), or a
      -- return whose references name a payment of this bank account (end-to-end id, or the bank transaction id of the
      -- credit it takes back). The line waits in « À classer » (and the ageing alert) until it is linked (I9; review
      -- fix: a chargeback larger than what is left of its payment is never hidden as an explained gap, OQ-34). A
      -- return naming nothing of ours (e.g. a fee's direct debit the bank rejected) is explained with a motif.
      when d.direction = 'debit' and d.line_kind = 'refund_out' then 'not_explainable'
      -- (our payouts' and sweeps' lines: own_transfer_line above, whatever the kind)
      when d.direction = 'debit' and d.line_kind = 'return' and exists (
             select 1 from public.bank_transaction x
             where x.id = d.bank_transaction_id
               and (exists (select 1 from public.payment p
                            where p.end_to_end_id = coalesce(x.original_end_to_end_id, x.end_to_end_id)
                              and p.bank_account_id = x.bank_account_id)
                    or (x.tx_id is not null
                        and exists (select 1 from public.bank_transaction o join public.payment p on p.bank_transaction_id = o.id
                                    where o.bank_account_id = x.bank_account_id and o.tx_id = x.tx_id
                                      and o.direction = 'credit')))) then 'not_explainable'
      when nullif(btrim(d.reason), '') is null then 'reason_required' end
    when d.pay_org is distinct from p_organization_id then 'payment_unknown'
    when d.pay_bank is distinct from d.line_bank then 'other_bank_account'
    when d.kind = 'return' then case
      when d.direction <> 'debit' or d.line_kind not in ('return', 'refund_out', 'other_debit') then 'not_a_return'
      when d.refund_request_id is not null then 'bad_request'
      when d.pay_status = 'returned' then 'already_returned'
      when d.line_date < d.pay_date then 'before_payment'
      when d.line_date < d.free_from then 'before_previous_return'
      -- the job links exactly what is left (payments.debits): anything else, the payment changed since it read it
      when d.method = 'auto' and d.line_minor <> d.pay_minor - d.returned then 'payment_changed'
      when d.line_minor > d.pay_minor - d.returned then 'amount_exceeds'
      when d.line_minor < d.pay_minor - d.returned and d.pending > 0 then 'refund_pending'  -- partial: cancel it first
      when d.method = 'ops' and d.expected_left_minor is distinct from d.pay_minor - d.returned then 'payment_changed' end
    when d.kind = 'refund' then case
      when d.direction <> 'debit' or d.line_kind not in ('refund_out', 'other_debit', 'return', 'batch_unsplit')
        then 'not_a_refund'
      -- M2c-6b-1: a batch line kept unsplit is a refund only as one of our PmtInfs (of one refund alone)
      when d.line_kind = 'batch_unsplit' and not d.our_batch_line then 'not_a_refund'
      when d.req_status is distinct from 'requested' or d.req_payment is distinct from d.payment_id then 'refund_not_pending'
      when d.req_bank is distinct from d.line_bank then 'other_bank_account'
      when d.line_minor <> d.req_minor then 'amount_differs'
      when d.line_date < d.pay_date then 'before_payment'
      when d.line_date < d.free_from then 'before_previous_return'
      when d.line_minor > d.unallocated then 'amount_exceeds' end
    when d.kind = 'refund_returned' then case
      when d.direction <> 'credit' or d.line_kind <> 'return' then 'not_a_refund_return'
      when d.req_status is distinct from 'executed' or d.req_payment is distinct from d.payment_id then 'refund_not_executed'
      -- the bank took the payment back after the refund: where the money that came back goes is not decided (OQ)
      when d.pay_status = 'returned' then 'payment_returned'
      when d.line_minor <> d.req_minor then 'amount_differs'
      when d.line_date < d.req_executed_on then 'before_refund' end
  end
  where d.bank_transaction_id is not null;  -- (every row: PostgREST sessions refuse an UPDATE without WHERE)
  -- one link per payment per call (a later one waits for the next run)
  update pg_temp._dl d set why = 'payment_twice'
  where d.why is null and d.payment_id is not null
    and exists (select 1 from pg_temp._dl o where o.payment_id = d.payment_id and o.why is null and o.ord < d.ord);
  select d.why, d.bank_transaction_id into v_why from pg_temp._dl d where d.why is not null order by d.ord limit 1;
  if found and p_strict then
    if v_why.why = 'own_transfer_line' then
      raise exception 'debit link refused: %', v_why.why using errcode = 'check_violation',
        hint = 'Cette ligne est un débit ou un retour de nos propres virements (reversement, quote-part du cabinet, lot '
               'de notre fichier) : elle se comptabilise depuis le relevé, automatiquement ou par l''équipe (écran à '
               'venir). Elle ne se rattache pas à un paiement et ne se classe pas sans comptabilisation.';
    end if;
    raise exception 'debit link refused: %', v_why.why using errcode = 'check_violation';
  end if;
  insert into pg_temp._debit_skipped (bank_transaction_id, why)
  select d.bank_transaction_id, d.why from pg_temp._dl d where d.why is not null
  on conflict (bank_transaction_id) do update set why = excluded.why;
  delete from pg_temp._dl d where d.why is not null;
  analyze pg_temp._dl;

  if p_strict then
    begin
      perform private.debit_post_rows(p_organization_id);
      perform private.ledger_check_now();   -- M2c: a client's 4670 never in debit (LG008), raised here
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
      if v_state like 'LG%' or v_state like '22%' or v_state like '23%' then
        raise exception 'debit link refused: posting_failed (%: %)', v_state, left(v_msg, 500)
          using errcode = 'check_violation';
      end if;
      raise;
    end;
  elsif exists (select 1 from pg_temp._dl) then
    begin
      perform private.debit_post_rows(p_organization_id);   -- the whole chunk at once
      perform private.ledger_check_now();   -- M2c: a client's 4670 never in debit (LG008), raised here
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if not (v_state like 'LG%' or v_state like '22%' or v_state like '23%') then
        raise;  -- not the data's doing (a lock, the machine): the queue retries the run
      end if;
      -- A link the posting refuses (the chunk's subtransaction rolled back): each link is tried on its own in a
      -- subtransaction that is always rolled back (a try leaves nothing, not even its locks: the posting's working
      -- tables would otherwise hold some until commit, for every link); the ones refused go to ops, then the others
      -- are posted together (one link per payment: each posts as it did alone).
      drop table if exists pg_temp._dl_all;
      create temp table _dl_all on commit drop as select * from pg_temp._dl;
      create index on pg_temp._dl_all (ord);
      for r in select a.ord, a.bank_transaction_id, a.payment_id, a.refund_request_id from pg_temp._dl_all a
               order by a.ord loop
        begin
          delete from pg_temp._dl d where d.bank_transaction_id is not null;
          insert into pg_temp._dl select * from pg_temp._dl_all a where a.ord = r.ord;
          perform private.debit_post_rows(p_organization_id);
      perform private.ledger_check_now();   -- M2c: a client's 4670 never in debit (LG008), raised here
          raise exception 'debit link tried' using errcode = 'DL000';   -- posts on its own: undo the try
        exception when others then
          get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
          if v_state <> 'DL000' then
            if not (v_state like 'LG%' or v_state like '22%' or v_state like '23%') then
              raise;
            end if;
            insert into pg_temp._debit_failed (bank_transaction_id, candidates, detail)
            values (r.bank_transaction_id,
                    jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('payment_id', r.payment_id,
                                                                           'refund_request_id', r.refund_request_id))),
                    left(v_state || ': ' || v_msg, 2000))
            on conflict (bank_transaction_id) do nothing;
          end if;
        end;
      end loop;
      delete from pg_temp._dl d where d.bank_transaction_id is not null;
      insert into pg_temp._dl select * from pg_temp._dl_all a
      where not exists (select 1 from pg_temp._debit_failed f where f.bank_transaction_id = a.bank_transaction_id);
      if exists (select 1 from pg_temp._dl) then
        perform private.debit_post_rows(p_organization_id);
      perform private.ledger_check_now();   -- M2c: a client's 4670 never in debit (LG008), raised here
      end if;
    end;
  end if;

  return jsonb_build_object(
    'returns', (select count(*) from pg_temp._dl where kind = 'return'),
    'refunds', (select count(*) from pg_temp._dl where kind = 'refund'),
    'refunds_returned', (select count(*) from pg_temp._dl where kind = 'refund_returned'),
    'explained', (select count(*) from pg_temp._dl where kind = 'explained'),
    'skipped', (select count(*) from pg_temp._debit_skipped),
    'failed', (select count(*) from pg_temp._debit_failed));
end;
$$;

-- What a line can be linked to (redefined from 20261110120000; review round 2, L4/L5): on one of our payouts' and sweeps'
-- lines, only what private.post_debit_links accepts — on a batch line of one of our PmtInfs, the file-mode refunds of
-- that PmtInf (in its current file, handed out to the bank) of the line's amount, and none while that PmtInf has a member
-- cancelled and not returned (switch on); on a line whose own or original id is one of our RMT/SWP ids, nothing; never a
-- payment. Other lines as before. Same settings and grants.
create or replace function public.debit_link_options(p_bank_transaction_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
as $$
declare
  t public.bank_transaction;
  v_kind text;
  v_batch boolean;
begin
  select * into t from public.bank_transaction where id = p_bank_transaction_id
    and organization_id = any (private.money_staff_org_ids());
  if not found then
    return null;
  end if;
  select coalesce(r.released_kind, t.kind) into v_kind
  from (select 1) x left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id;
  -- our batch line, read as private.post_debit_links reads it
  v_batch := coalesce(t.direction = 'debit' and t.end_to_end_id is null
                      and t.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$'
                      and exists (select 1 from public.transfer_file_item i
                                  cross join lateral (select f.debtor_bank_account_id from public.transfer_file f
                                                      where f.id = i.file_id offset 0) f
                                  where i.pmt_inf_id = t.payment_info_id
                                    and f.debtor_bank_account_id = t.bank_account_id), false);
  if v_batch then
    return jsonb_build_object(
      'payments', '[]'::jsonb,
      'refunds', case when exists (
                          select 1 from public.transfer_file_item i
                          cross join lateral (select f.debtor_bank_account_id from public.transfer_file f
                                              where f.id = i.file_id offset 0) f
                          cross join lateral (select m.status, m.transfer_file_id from public.bank_transfer m
                                              where m.id = i.transfer_id offset 0) m
                          where i.pmt_inf_id = t.payment_info_id and f.debtor_bank_account_id = t.bank_account_id
                            and m.transfer_file_id = i.file_id and m.status = 'cancelled'
                            and not private.transfer_return_seen(i.transfer_id))
                      then '[]'::jsonb
                      else coalesce((
        select jsonb_agg(jsonb_build_object('refund_request_id', q.id, 'payment_id', q.payment_id,
                                            'amount_minor', q.amount_minor::text, 'end_to_end_id', q.end_to_end_id,
                                            'status', q.status, 'payee_name', q.payee_name,
                                            'payee_iban_end', right(q.payee_iban, 4), 'requested_at', q.requested_at)
                         order by q.requested_at desc, q.id)
        from (select y.file_id, y.transfer_id from public.transfer_file_item y
              where y.pmt_inf_id = t.payment_info_id offset 0) i
        cross join lateral (select f.debtor_bank_account_id, f.status from public.transfer_file f
                            where f.id = i.file_id offset 0) f
        cross join lateral (select m.kind, m.status, m.transfer_file_id from public.bank_transfer m
                            where m.id = i.transfer_id offset 0) m
        cross join lateral (select q.* from public.refund_request q where q.transfer_id = i.transfer_id offset 0) q
        where f.debtor_bank_account_id = t.bank_account_id and f.status in ('downloaded', 'sent')
          and m.kind = 'refund' and m.status = 'in_file' and m.transfer_file_id = i.file_id
          and q.status = 'requested' and q.bank_account_id = t.bank_account_id
          and q.amount_minor = t.amount_minor), '[]') end,
      'kind', v_kind);
  end if;
  if coalesce(t.end_to_end_id ~ '^(RMT|SWP)[0-9A-F]{12}$', false)
     or coalesce(coalesce(t.original_end_to_end_id, t.end_to_end_id) ~ '^(RMT|SWP)[0-9A-F]{12}$', false) then
    return jsonb_build_object('payments', '[]'::jsonb, 'refunds', '[]'::jsonb, 'kind', v_kind);
  end if;
  return jsonb_build_object(
    'payments', case when t.direction = 'debit' then coalesce((
      with y as (select p.id, p.amount_minor, p.booking_date, p.payer_name, p.status, p.account_id
                 from public.payment p
                 where p.bank_account_id = t.bank_account_id and p.booking_date <= t.booking_date
                   and p.status <> 'returned' and p.amount_minor >= t.amount_minor
                 order by (p.amount_minor = t.amount_minor) desc, p.booking_date desc, p.id
                 limit 60)
      select jsonb_agg(jsonb_build_object('payment_id', y.id, 'amount_minor', y.amount_minor::text,
                                          'booking_date', y.booking_date, 'payer_name', y.payer_name, 'status', y.status,
                                          'left_minor', (pos.amount_minor - pos.returned_minor)::text,
                                          'file_reference', a.external_ref)
                       order by (pos.amount_minor - pos.returned_minor = t.amount_minor) desc, y.booking_date desc, y.id)
      from y
      join private.payment_positions(array(select y2.id from y y2)) pos on pos.payment_id = y.id
      left join public.account a on a.id = y.account_id
      where pos.amount_minor - pos.returned_minor >= t.amount_minor
      ), '[]') else '[]'::jsonb end,
    'refunds', coalesce((
      select jsonb_agg(jsonb_build_object('refund_request_id', q.id, 'payment_id', q.payment_id,
                                          'amount_minor', q.amount_minor::text, 'end_to_end_id', q.end_to_end_id,
                                          'status', q.status, 'payee_name', q.payee_name,
                                          'payee_iban_end', right(q.payee_iban, 4), 'requested_at', q.requested_at)
                       order by q.requested_at desc)
      from (select * from public.refund_request q
            where q.bank_account_id = t.bank_account_id and q.amount_minor = t.amount_minor
              and q.status = case when t.direction = 'debit' then 'requested' else 'executed' end
            order by q.requested_at desc limit 20) q), '[]'),
    'kind', v_kind);
end;
$$;

-- « Débits et retours » (redefined from 20261111090000): a batch line of our files is listed « À classer » (the funds
-- pass's review reasons, M2c-6b-1), never among the fees; each line with its PmtInfId (review money-1: the page offers
-- no link on our batch lines, as it offers none on a line carrying our RMT/SWP id). Same settings; dropped and created
-- (a column added last).
drop function public.debit_queue(text, integer, integer);
create function public.debit_queue(p_tab text default 'a-classer', p_offset integer default 0,
                                   p_limit integer default 20)
returns table (bank_transaction_id uuid, statement_id uuid, bank_account_id uuid, direction text, kind text,
               amount_minor text, currency char(3), booking_date date, age_days integer, counterparty_name text,
               counterparty_iban_end text, remittance_text text, end_to_end_id text, original_end_to_end_id text,
               return_reason text, review_reason text, candidates jsonb, decision text, decided_at timestamptz,
               decided_payment_id uuid, total bigint, held_kind text, payment_info_id text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_orgs uuid[] := private.money_staff_org_ids();
  v_today date := private.paris_today();
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 100);
  v_total bigint;
begin
  drop table if exists pg_temp._dq;
  if p_tab = 'doublons' then
    create temp table _dq on commit drop as
    select t.*, null::text as eff_kind, null::text as dq_reason, null::jsonb as dq_candidates
    from public.bank_transaction t
    where t.organization_id = any (v_orgs) and t.kind = 'suspected_duplicate'
      and not exists (select 1 from public.bank_duplicate_resolution r where r.bank_transaction_id = t.id);
  elsif p_tab = 'frais' then
    create temp table _dq on commit drop as
    select t.*, null::text as eff_kind, null::text as dq_reason, null::jsonb as dq_candidates
    from public.bank_transaction t
    where t.organization_id = any (v_orgs) and t.kind = 'other_debit'
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id)
      -- M2c-6b-1: a batch line of our files is one of our transfers (« À classer »), never a fee
      and not (t.end_to_end_id is null and coalesce(t.payment_info_id, '') ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$')
      and not (t.direction = 'debit'
               and exists (select 1 from public.refund_request q
                           where q.bank_account_id = t.bank_account_id and q.amount_minor = t.amount_minor
                             and q.organization_id = t.organization_id and q.status = 'requested'));
  elsif p_tab = 'traites' then
    -- from the decisions (a few per day), never from the servicer's lines
    create temp table _dq on commit drop as
    select t.*, null::text as eff_kind, null::text as dq_reason, null::jsonb as dq_candidates
    from public.bank_transaction t
    where t.id in (select l.bank_transaction_id from public.bank_debit_link l where l.organization_id = any (v_orgs)
                   union
                   select k.bank_transaction_id from public.bank_line_booking k
                   where k.organization_id = any (v_orgs)
                   union
                   select c.bank_transaction_id from public.bank_own_credit_release c
                   where c.organization_id = any (v_orgs)
                   union
                   select r.bank_transaction_id from public.bank_duplicate_resolution r
                   where r.organization_id = any (v_orgs)
                     and not (r.decision = 'released' and r.released_kind in ('return', 'refund_out')
                              and not exists (select 1 from public.bank_debit_link l
                                              where l.bank_transaction_id = r.bank_transaction_id)));
  else
    create temp table _dq on commit drop as
    select t.*, coalesce(r.released_kind, t.kind) as eff_kind, null::text as dq_reason, null::jsonb as dq_candidates
    from public.bank_transaction t
    left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
    where t.organization_id = any (v_orgs) and t.kind in ('return', 'refund_out', 'suspected_duplicate')
      and (t.kind <> 'suspected_duplicate' or r.released_kind in ('return', 'refund_out'))
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id)
    union all
    -- M2c: our transfers out, credits from our own account or from a client (released duplicates of those kinds
    -- too), not booked, explained or released as a relayed debtor payment yet
    select t.*, coalesce(r.released_kind, t.kind), null::text, null::jsonb
    from public.bank_transaction t
    left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
    where t.organization_id = any (v_orgs)
      and (t.kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in')
           or (t.kind = 'suspected_duplicate'
               and r.released_kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in')))
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id)
      and not exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = t.id)
    union all
    -- M2c-6b-1: a batch line of our files (no end-to-end id, our PmtInfId) the debit job left to ops
    select t.*, t.kind, null::text, null::jsonb
    from public.bank_transaction t
    where t.organization_id = any (v_orgs) and t.direction = 'debit' and t.end_to_end_id is null
      and t.kind in ('other_debit', 'batch_unsplit') and t.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$'
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id)
    union all
    -- an other debit of a pending refund's amount on its bank account: maybe that refund (from the pending requests,
    -- a few, to the lines of their amount); not one booked already (review fix: a fee the job booked stayed listed,
    -- with no action that works)
    select t.*, t.kind, 'refund_amount_match', m.candidates
    from (select o.id, jsonb_agg(jsonb_build_object('refund_request_id', q.id, 'payment_id', q.payment_id)
                                 order by q.requested_at, q.id) as candidates
          from public.refund_request q
          join public.bank_transaction o
            on o.bank_account_id = q.bank_account_id and o.amount_minor = q.amount_minor and o.kind = 'other_debit'
           and o.direction = 'debit' and o.organization_id = q.organization_id
          where q.organization_id = any (v_orgs) and q.status = 'requested'
            and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = o.id)
            and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = o.id)
            and not (o.end_to_end_id is null and coalesce(o.payment_info_id, '') ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$')
          group by o.id) m
    join public.bank_transaction t on t.id = m.id;
  end if;
  select count(*) into v_total from pg_temp._dq;
  return query
  select t.id, t.statement_id, t.bank_account_id, t.direction, coalesce(t.eff_kind, t.kind), t.amount_minor::text,
         t.currency, t.booking_date, (v_today - t.booking_date)::integer, t.counterparty_name, right(t.counterparty_iban, 4),
         t.remittance_text, t.end_to_end_id, t.original_end_to_end_id, t.return_reason, coalesce(v.reason, t.dq_reason),
         coalesce((select jsonb_agg(c.v || coalesce(
                     (select jsonb_build_object('amount_minor', p.amount_minor::text, 'currency', p.currency,
                                                'booking_date', p.booking_date, 'payer_name', p.payer_name,
                                                'status', p.status, 'left_minor', (pos.amount_minor - pos.returned_minor)::text,
                                                'file_reference', a.external_ref)
                      from public.payment p
                      left join public.account a on a.id = p.account_id
                      cross join lateral private.payment_positions(array[p.id]) pos
                      where p.id = (c.v ->> 'payment_id')::uuid and p.organization_id = t.organization_id), '{}')
                   || coalesce((select jsonb_build_object('end_to_end_id', q.end_to_end_id, 'refund_status', q.status,
                                                          'refund_minor', q.amount_minor::text)
                                from public.refund_request q
                                where q.id = (c.v ->> 'refund_request_id')::uuid
                                  and q.organization_id = t.organization_id), '{}')
                     order by c.ord)
                   from jsonb_array_elements(coalesce(v.candidates, t.dq_candidates)) with ordinality c (v, ord)),
                  '[]'::jsonb),
         coalesce((select string_agg(k.kind, '+' order by k.seq) from public.bank_line_booking k
                   where k.bank_transaction_id = t.id),
                  case when c.bank_transaction_id is not null then 'relayed_payment' end, l.kind,
                  case r.decision when 'duplicate' then 'duplicate'
                                           when 'released' then 'released' end),
         coalesce(l.decided_at, c.decided_at, r.decided_at),
         coalesce(l.payment_id, (select p.id from public.payment p
                                 where c.bank_transaction_id is not null and p.bank_transaction_id = t.id)),
         v_total,
         -- a held duplicate: how the import read it (the « Libérer » sheet says what it becomes)
         case when t.kind = 'suspected_duplicate' then (select h.kind from private.held_line_kind(t.id) h) end,
         t.payment_info_id
  from (select * from pg_temp._dq x
        order by (case when p_tab = 'traites' then x.created_at end) desc nulls last, x.booking_date, x.id
        offset v_offset limit v_limit) t
  left join public.bank_debit_review v on v.bank_transaction_id = t.id
  left join public.bank_debit_link l on l.bank_transaction_id = t.id
  left join public.bank_own_credit_release c on c.bank_transaction_id = t.id
  left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
  order by (case when p_tab = 'traites' then t.created_at end) desc nulls last, t.booking_date, t.id;
end;
$$;

------------------------------------------------------------------------------------------
-- Debits of a cancelled transfer (plan §2.5; design §9.7: « a debit carrying the RMT id of a cancelled transfer », and
-- M2c-6a rounds 5–6: « a batch line that can contain a cancelled transfer »)
------------------------------------------------------------------------------------------

-- Whether this batch line (no end-to-end id) of a PmtInf of a file can hold this transfer: its amount is the
-- transfer's, alone or with other transfers of the PmtInf not debited on their own — private.batch_debit_may_hold's rule
-- (20261115090000) for one line. Keyed: the PmtInf's items of that file.
create or replace function private.batch_line_may_hold(p_bank_transaction_id uuid, p_file_id uuid, p_pmt_inf_id text,
                                                       p_transfer_id uuid)
returns boolean
language plpgsql
stable
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_line bigint;
  v_account uuid;
  v_amount bigint;
  v_others bigint[];
begin
  select x.amount_minor, x.bank_account_id into v_line, v_account from public.bank_transaction x
  where x.id = p_bank_transaction_id;
  select t.amount_minor into v_amount from public.bank_transfer t where t.id = p_transfer_id;
  if v_line = v_amount then
    return true;
  end if;
  if v_line < v_amount then
    return false;
  end if;
  select coalesce(array_agg(o.amount_minor order by o.amount_minor desc), '{}') into v_others
  from public.transfer_file_item i
  cross join lateral (select o.amount_minor, o.end_to_end_id from public.bank_transfer o
                      where o.id = i.transfer_id offset 0) o
  where i.file_id = p_file_id and i.pmt_inf_id = p_pmt_inf_id and i.transfer_id <> p_transfer_id
    and not private.transfer_own_debit_seen(v_account, o.end_to_end_id);
  return private.amounts_make_up(v_others, v_line - v_amount);
end;
$$;

-- The lines of the paying account that are a late debit of this transfer and that nothing resolved yet — neither
-- booked, nor linked, nor released as a payment; an « explained » line is NOT resolved (plan §2.5 [critic]: one
-- person's motif never silences a debit of a cancelled transfer; and post_debit_links refuses explaining such lines):
-- the debits carrying its end-to-end id or that of a transfer it re-issues (its replaces chain), and the batch lines
-- that can hold it per private.transfer_debited_before's two branches — of a PmtInf that held it in a downloaded file
-- superseded or rejected since (any such line), or, cancelled alone out of a live downloaded file, of its PmtInf there
-- booked after its cancellation's window (the next business day after its execution date). Keyed as
-- transfer_debited_before: the chain by id, each one's debits by its id, its items by transfer.
create or replace function private.transfer_late_lines(p_transfer_id uuid)
returns setof uuid
language plpgsql
stable
set search_path = ''
set enable_seqscan = off
as $$
declare
  t public.bank_transfer;
  v_account uuid;
  v_depth integer := 0;
begin
  select * into t from public.bank_transfer where id = p_transfer_id;
  v_account := t.debtor_bank_account_id;
  while t.id is not null and v_depth < 1000 loop
    return query
    select x.id
    from (select q.id, q.bank_account_id, q.direction from public.bank_transaction q
          where q.end_to_end_id = t.end_to_end_id offset 0) x
    where x.bank_account_id = v_account and x.direction = 'debit'
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = x.id offset 0)
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = x.id and l.kind <> 'explained'
                      offset 0)
      and not exists (select 1 from public.payment p where p.bank_transaction_id = x.id offset 0);
    return query
    select x.id
    from public.transfer_file_item i
    cross join lateral (select f.download_count, f.status from public.transfer_file f where f.id = i.file_id offset 0) f
    cross join lateral (select q.id, q.booking_date from public.bank_transaction q
                        where q.bank_account_id = v_account and q.payment_info_id = i.pmt_inf_id
                          and q.direction = 'debit' and q.end_to_end_id is null offset 0) x
    where i.transfer_id = t.id and f.download_count > 0
      and (f.status in ('superseded', 'rejected')
           or (t.status = 'cancelled' and f.status in ('downloaded', 'sent')
               and x.booking_date > private.next_business_day(i.execution_date)))
      and private.batch_line_may_hold(x.id, i.file_id, i.pmt_inf_id, t.id)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = x.id offset 0)
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = x.id and l.kind <> 'explained'
                      offset 0);
    exit when t.replaces_transfer_id is null;
    select * into t from public.bank_transfer where id = t.replaces_transfer_id;
    v_depth := v_depth + 1;
  end loop;
end;
$$;

------------------------------------------------------------------------------------------
-- Nightly checks and alerts (§15; plan §2.5)
------------------------------------------------------------------------------------------

-- The M2b refund links of a refund request (I20's refund rule: exactly one), read by the request's key whatever the
-- statistics (review T7: a correlated count over the whole link table per executed refund, every night).
create or replace function private.refund_debit_links(p_refund_request_id uuid)
returns bigint
language plpgsql
stable
set search_path = ''
set enable_seqscan = off
as $$
begin
  return (select count(*) from (select l.kind from public.bank_debit_link l
                                where l.refund_request_id = p_refund_request_id offset 0) l
          where l.kind = 'refund');
end;
$$;

-- run_payment_checks (redefined from 20261112090000, each check in the same single statement): I19 by the bookings'
-- 5120 postings (signed), bank_line_booked (each booked line booked whole, the deferred check's twin), I20
-- transfer_booked_once (per kind; its refund rule keyed by the request: private.refund_debit_links, only for the
-- refunds it judges); the rest unchanged.
create or replace function private.run_payment_checks(p_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run uuid;
  v_today date := private.paris_today();
  v_summary jsonb;
  v_violations integer;
  v_alerts integer;
begin
  if not exists (select 1 from public.organization o where o.id = p_organization_id and o.kind = 'servicer') then
    raise exception 'checks: unknown servicer %', p_organization_id using errcode = '22023';
  end if;
  insert into public.payment_check_run (organization_id) values (p_organization_id) returning id into v_run;
  drop table if exists pg_temp._chk;
  create temp table _chk (code text, severity text, subject_type text, subject_id uuid, currency char(3),
                          amount_minor bigint, count integer, oldest_days integer, details jsonb) on commit drop;

  -- Every check reads the books in ONE statement, so in one snapshot: an entry or a payment committed while the
  -- checks run (a link, a release, an allocation from a PostgREST session) is in every check or in none — never a gap
  -- between the cash read by one check and the payments read by another (review fix: the job runs READ COMMITTED,
  -- where each statement of a function sees the latest commits).
  insert into pg_temp._chk (code, severity, subject_type, subject_id, currency, amount_minor, count, oldest_days, details)
  with pos as materialized (
    -- Every payment's position from its tagged entries (one pass), and its pending refunds.
    select p.id, p.status, p.review_reason, p.account_id, p.amount_minor, p.currency, p.booking_date, p.bank_account_id,
           p.updated_at, coalesce(s.a, 0)::bigint as allocated, coalesce(s.r, 0)::bigint as returned,
           (p.amount_minor - coalesce(s.a, 0) - coalesce(s.r, 0))::bigint as unallocated,
           coalesce(q.pending, 0)::bigint as pending, coalesce(q.n, 0) as pending_n
    from public.payment p
    left join (select e.payment_id,
                      sum(lp.amount_minor) filter (where coalesce(t.entry_type, e.entry_type) in ('allocation', 'forward')) as a,
                      sum(lp.amount_minor) filter (where coalesce(t.entry_type, e.entry_type) = 'cash_out') as r
               from public.ledger_entry e
               left join public.ledger_entry t on t.id = e.reverses_entry_id
               join public.ledger_posting lp on lp.entry_id = e.id
               join public.ledger_account la on la.id = lp.ledger_account_id and la.book = 'unallocated_payment'
               where e.organization_id = p_organization_id and e.payment_id is not null
               group by e.payment_id) s on s.payment_id = p.id
    left join (select q.payment_id, sum(q.amount_minor) as pending, count(*) as n from public.refund_request q
               where q.organization_id = p_organization_id and q.status = 'requested' group by q.payment_id) q
      on q.payment_id = p.id
    where p.organization_id = p_organization_id
  )
  -- I8′: the dedicated-account fund closed per currency (5120 + 4710 + 4670 + 4679 = 0), the servicer's fund closed
  -- per currency (own_fund_identity), and the 4679 / 4689 mirror (fund_mirror, I12), from one pass over the funds.
  select x.code, 'violation'::text, 'servicer'::text, null::uuid, x.currency::char(3), x.total::bigint,
         null::integer, null::integer, x.details
  from (select f.currency, v.code, v.total, v.details
        from (select la.currency,
                     sum(lp.amount_minor) filter (where b.money_of = 'client') as client_total,
                     sum(lp.amount_minor) filter (where b.money_of = 'servicer') as servicer_total,
                     sum(lp.amount_minor) filter (where la.book in ('due_to_servicer', 'due_from_client_funds'))
                       as mirror_total,
                     sum(lp.amount_minor) filter (where la.book = 'client_money_cash') as cash,
                     sum(lp.amount_minor) filter (where la.book = 'unallocated_payment') as pool,
                     sum(lp.amount_minor) filter (where la.book = 'client_payable') as owed,
                     sum(lp.amount_minor) filter (where la.book = 'due_to_servicer') as servicer_share,
                     sum(lp.amount_minor) filter (where la.book = 'due_from_client_funds') as servicer_claim
              from public.ledger_account la
              join public.ledger_book b on b.code = la.book and b.money_of in ('client', 'servicer')
              join public.ledger_posting lp on lp.ledger_account_id = la.id
              where la.organization_id = p_organization_id and la.portfolio_id is null
              group by la.currency) f
        cross join lateral (values
          ('client_money_identity', coalesce(f.client_total, 0),
           jsonb_build_object('cash_minor', coalesce(f.cash, 0)::text, 'unallocated_minor', coalesce(f.pool, 0)::text,
                              'owed_minor', coalesce(f.owed, 0)::text,
                              'due_to_servicer_minor', coalesce(f.servicer_share, 0)::text)),
          ('own_fund_identity', coalesce(f.servicer_total, 0), '{}'::jsonb),
          ('fund_mirror', coalesce(f.mirror_total, 0),
           jsonb_build_object('due_to_servicer_minor', coalesce(f.servicer_share, 0)::text,
                              'due_from_client_funds_minor', coalesce(f.servicer_claim, 0)::text))
        ) v (code, total, details)) x
  where x.total <> 0

  union all
  -- I13: each client's 4670 never in debit, and its running balance = its postings (the commit guard's source).
  select 'client_payable_debit', 'violation', 'client', coalesce(p.client_organization_id, r.client_organization_id),
         coalesce(p.currency, r.currency), coalesce(p.total, 0)::bigint, null, null,
         jsonb_build_object('postings_minor', coalesce(p.total, 0)::text, 'running_minor', coalesce(r.balance_minor, 0)::text)
  from (select la.client_organization_id, la.currency, sum(lp.amount_minor) as total
        from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
        where la.organization_id = p_organization_id and la.book = 'client_payable'
        group by la.client_organization_id, la.currency) p
  full join (select c.client_organization_id, c.currency, c.balance_minor from private.client_payable_balance c
             where c.organization_id = p_organization_id) r
    on r.client_organization_id = p.client_organization_id and r.currency = p.currency
  where coalesce(p.total, 0) > 0 or coalesce(p.total, 0) <> coalesce(r.balance_minor, 0)

  union all
  -- I14 (completeness; M2c-4): what each client is owed = its items waiting in the pending queue (reserved by a
  -- draft or not) + the gross (N + D) of its runs approved and not booked yet.
  select 'remittance_completeness', 'violation', 'client',
         coalesce(r.client_organization_id, q.client_organization_id, f.client_organization_id),
         coalesce(r.currency, q.currency, f.currency),
         (-coalesce(r.balance_minor, 0) - coalesce(q.total, 0) - coalesce(f.inflight, 0))::bigint, null, null,
         jsonb_build_object('owed_minor', (-coalesce(r.balance_minor, 0))::text, 'pending_minor', coalesce(q.total, 0)::text,
                            'in_flight_minor', coalesce(f.inflight, 0)::text)
  from (select c.client_organization_id, c.currency, c.balance_minor from private.client_payable_balance c
        where c.organization_id = p_organization_id) r
  full join (select q.client_organization_id, q.currency, sum(q.amount_minor) as total from private.remittance_pending q
             where q.organization_id = p_organization_id group by q.client_organization_id, q.currency) q
    on q.client_organization_id = r.client_organization_id and q.currency = r.currency
  full join (select x.client_organization_id, x.currency, sum(x.net_minor + x.settlement_minor) as inflight
             from public.remittance_run x
             where x.organization_id = p_organization_id and x.status in ('approved', 'sent')
             group by x.client_organization_id, x.currency) f
    on f.client_organization_id = coalesce(r.client_organization_id, q.client_organization_id)
   and f.currency = coalesce(r.currency, q.currency)
  where -coalesce(r.balance_minor, 0) <> coalesce(q.total, 0) + coalesce(f.inflight, 0)

  union all
  -- I19, per dedicated account: its cash = what its payments brought in less what went back out to the payers
  -- (returns, refunds) + what its lines booked in the funds moved (top-ups in; fees, losses, payouts and sweeps out;
  -- returned payouts and sweeps in). Every 5120 movement of a funds entry comes from a bank line booked here. M2c-6b-1:
  -- what a booking moved is its entry's 5120 posting, signed (a return with charges books +N and −(N − line): the
  -- booking amount × the line's direction counted it twice).
  select 'bank_cash_identity', 'violation', 'bank_account', coalesce(c.bank_account_id, y.bank_account_id, k.bank_account_id),
         b.currency, (coalesce(c.cash, 0) - coalesce(y.held, 0) - coalesce(k.moved, 0))::bigint, null, null,
         jsonb_build_object('cash_minor', coalesce(c.cash, 0)::text, 'unallocated_minor', coalesce(y.unallocated, 0)::text,
                            'allocated_minor', coalesce(y.allocated, 0)::text,
                            'booked_lines_minor', coalesce(k.moved, 0)::text)
  from (select la.bank_account_id, sum(lp.amount_minor) as cash
        from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
        where la.organization_id = p_organization_id and la.book = 'client_money_cash'
        group by la.bank_account_id) c
  full join (select x.bank_account_id, sum(x.amount_minor - x.returned) as held, sum(x.unallocated) as unallocated,
                    sum(x.allocated) as allocated
             from pos x where x.bank_account_id is not null group by x.bank_account_id) y
    on y.bank_account_id = c.bank_account_id
  full join (select k.bank_account_id, sum(p.amount_minor) as moved
             from public.bank_line_booking k
             join public.ledger_posting p on p.entry_id = k.entry_id
             join public.ledger_account la on la.id = p.ledger_account_id and la.book = 'client_money_cash'
               and la.bank_account_id = k.bank_account_id
             where k.organization_id = p_organization_id
             group by k.bank_account_id) k on k.bank_account_id = coalesce(c.bank_account_id, y.bank_account_id)
  join public.bank_account b on b.id = coalesce(c.bank_account_id, y.bank_account_id, k.bank_account_id)
  where coalesce(c.cash, 0) <> coalesce(y.held, 0) + coalesce(k.moved, 0)

  union all
  -- bank_line_booked (M2c-6b-1): each booked line booked whole, signed — the commit-time check's nightly twin
  select 'bank_line_booked', 'violation', 'bank_transaction', l.id, l.currency, l.amount_minor, null, null,
         jsonb_build_object('moved_minor', m.moved::text, 'direction', l.direction)
  from (select distinct k.bank_transaction_id from public.bank_line_booking k
        where k.organization_id = p_organization_id) k
  cross join lateral (select q.id, q.currency, q.amount_minor, q.direction, q.bank_account_id
                      from public.bank_transaction q where q.id = k.bank_transaction_id offset 0) l
  cross join lateral (select private.bank_line_cash_moved(l.id, l.bank_account_id) as moved offset 0) m
  where m.moved <> case l.direction when 'credit' then l.amount_minor else -l.amount_minor end

  union all
  -- I20 transfer_booked_once (M2c-6b-1): a transfer is debited once and returned once, and its status is what its
  -- bookings say, per kind (plan §2.5 [critic]): a payout, sweep or top-up by bank_line_booking — booked or returned
  -- with exactly one debit booking whose entry is its entry, returned with its return booking, no booking while not
  -- booked; a refund by its request (the M2b RFD link: its cash_out the transfer's entry, one link; its bounce the
  -- transfer's return). A run booked with a payout has its transfer booked or returned.
  select 'transfer_booked_once', 'violation', 'bank_transfer', x.id, x.currency, x.amount_minor, null, null,
         jsonb_build_object('kind', x.kind, 'status', x.status, 'debit_bookings', x.debits,
                            'return_bookings', x.returns)
  from (select t.id, t.kind, t.status, t.currency, t.amount_minor, t.entry_id, t.return_entry_id,
               (select count(*) from public.bank_line_booking b where b.transfer_id = t.id
                  and b.kind in ('payout', 'sweep', 'top_up')) as debits,
               (select count(*) from public.bank_line_booking b where b.transfer_id = t.id
                  and b.kind in ('payout', 'sweep', 'top_up') and b.entry_id = t.entry_id) as debit_own,
               (select count(*) from public.bank_line_booking b where b.transfer_id = t.id
                  and b.kind in ('payout_returned', 'sweep_returned')) as returns,
               (select count(*) from public.bank_line_booking b where b.transfer_id = t.id
                  and b.kind in ('payout_returned', 'sweep_returned') and b.entry_id = t.return_entry_id) as return_own,
               q.cash_out_entry_id, q.bounce_entry_id,
               case when t.kind = 'refund' and t.status in ('booked', 'returned')
                    then private.refund_debit_links(q.id) end as refund_links
        from public.bank_transfer t
        left join public.refund_request q on q.transfer_id = t.id
        where t.organization_id = p_organization_id) x
  where x.debits > 1 or x.returns > 1
     or (x.kind in ('payout', 'sweep', 'top_up')
         and ((x.status in ('booked', 'returned') and x.debit_own <> 1)
              or (x.status = 'returned' and x.return_own <> 1)
              or (x.status not in ('booked', 'returned') and (x.debits > 0 or x.returns > 0))))
     or (x.kind = 'refund'
         and ((x.status in ('booked', 'returned')
               and (x.cash_out_entry_id is distinct from x.entry_id or x.refund_links <> 1))
              or (x.status = 'returned' and x.bounce_entry_id is distinct from x.return_entry_id)))
  union all
  select 'transfer_booked_once', 'violation', 'remittance_run', r.id, r.currency, r.net_minor, null, null,
         jsonb_build_object('number', r.number, 'transfer_status', t.status)
  from public.remittance_run r
  left join public.bank_transfer t on t.id = r.transfer_id
  where r.organization_id = p_organization_id and r.status = 'booked' and r.net_minor > 0
    and (t.status is null or t.status not in ('booked', 'returned'))

  union all
  -- I11: the cash booked for a statement day = its payments (released duplicates included).
  select 'cash_in_statement', 'violation', 'bank_statement', coalesce(ci.statement_id, pd.statement_id), null,
         (coalesce(ci.total, 0) - coalesce(pd.total, 0))::bigint, null, null,
         jsonb_build_object('date', coalesce(ci.d, pd.d), 'cash_in_minor', coalesce(ci.total, 0)::text,
                            'payments_minor', coalesce(pd.total, 0)::text)
  from (select e.source_id::uuid as statement_id, e.effective_date as d, sum(lp.amount_minor) as total
        from public.ledger_entry e
        join public.ledger_posting lp on lp.entry_id = e.id
        join public.ledger_account la on la.id = lp.ledger_account_id and la.book = 'client_money_cash'
        where e.organization_id = p_organization_id and e.entry_type = 'cash_in'
        group by e.source_id, e.effective_date) ci
  full join (select t.statement_id, p.booking_date as d, sum(p.amount_minor) as total
             from public.payment p join public.bank_transaction t on t.id = p.bank_transaction_id
             where p.organization_id = p_organization_id
             group by t.statement_id, p.booking_date) pd
    on pd.statement_id = ci.statement_id and pd.d = ci.d
  where coalesce(ci.total, 0) <> coalesce(pd.total, 0)

  union all
  -- I4, I5 and design §7: each payment's position against its status.
  select 'payment_position', 'violation', 'payment', c.id, c.currency, c.unallocated, null, v_today - c.booking_date,
         jsonb_build_object('status', c.status, 'allocated_minor', c.allocated::text,
                            'unallocated_minor', c.unallocated::text, 'returned_minor', c.returned::text,
                            'pending_refund_minor', c.pending::text)
  from pos c
  where c.unallocated < 0 or c.allocated < 0 or c.returned < 0
     or (c.status = 'allocated' and not (c.allocated > 0 and c.unallocated = 0))
     or (c.status = 'partially_allocated' and not (c.allocated > 0 and c.unallocated > 0))
     or (c.status in ('unmatched', 'matched') and not (c.allocated = 0 and c.unallocated > 0))
     or (c.status = 'unmatched' and c.account_id is not null)
     or (c.status = 'refunded' and not (c.allocated = 0 and c.unallocated = 0 and c.returned = c.amount_minor))
     or (c.status = 'returned' and not (c.allocated = 0 and c.unallocated = 0))
     or ((c.status = 'refund_pending') <> (c.pending_n > 0))
     or c.pending > c.unallocated

  union all
  -- the net allocated per (payment, file) is never negative
  select 'payment_negative_allocation', 'violation', 'payment', x.payment_id, null, x.total::bigint, null, null,
         jsonb_build_object('account_id', x.account_id)
  from (select e.payment_id, e.account_id, sum(lp.amount_minor) as total
        from public.ledger_entry e
        left join public.ledger_entry t on t.id = e.reverses_entry_id
        join public.ledger_posting lp on lp.entry_id = e.id
        join public.ledger_account la on la.id = lp.ledger_account_id and la.book = 'unallocated_payment'
        where e.organization_id = p_organization_id and e.payment_id is not null
          and coalesce(t.entry_type, e.entry_type) = 'allocation'
        group by e.payment_id, e.account_id) x
  where x.total < 0

  union all
  -- I6: no receivable a payment (or a credit note, or a payment made to the client) lowered is below zero now; no item
  -- below zero as a whole once such an entry touched it.
  select 'receivable_negative', 'violation', 'claim_item', x.claim_item_id, x.currency, x.balance::bigint, null, null,
         jsonb_build_object('component', x.component)
  from (select la.claim_item_id, la.component, la.currency, sum(lp.amount_minor) as balance
        from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
        where la.organization_id = p_organization_id and la.book = 'debtor_receivable'
          and exists (select 1 from public.ledger_posting q join public.ledger_entry e on e.id = q.entry_id
                      where q.ledger_account_id = la.id and q.amount_minor < 0
                        and (e.entry_type in ('allocation', 'netting')
                             or (e.entry_type = 'adjustment' and e.source_type = 'direct_payment')))
        group by la.claim_item_id, la.component, la.currency) x
  where x.balance < 0
  union all
  select 'item_negative', 'violation', 'claim_item', y.claim_item_id, y.currency, y.balance::bigint, null, null,
         '{}'::jsonb
  from (select la.claim_item_id, la.currency, sum(lp.amount_minor) as balance
        from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
        where la.organization_id = p_organization_id and la.book = 'debtor_receivable'
          and la.claim_item_id in (
            select l2.claim_item_id from public.ledger_account l2
            join public.ledger_posting q on q.ledger_account_id = l2.id
            join public.ledger_entry e on e.id = q.entry_id
            where l2.organization_id = p_organization_id and l2.book = 'debtor_receivable' and q.amount_minor < 0
              and (e.entry_type = 'allocation' or (e.entry_type = 'adjustment' and e.source_type = 'direct_payment')))
        group by la.claim_item_id, la.currency) y
  where y.balance < 0

  union all
  -- The owner-claim mirror (M2a risk #5): per portfolio, component and currency, 3100 = −Σ1100.
  select 'owner_claim_mirror', 'violation', 'portfolio', x.portfolio_id, x.currency, x.total::bigint, null, null,
         jsonb_build_object('component', x.component)
  from (select la.portfolio_id, la.component, la.currency, sum(lp.amount_minor) as total
        from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
        where la.organization_id = p_organization_id and la.book in ('debtor_receivable', 'owner_claim')
        group by la.portfolio_id, la.component, la.currency) x
  where x.total <> 0

  union all
  -- R124-6: one receipt number per payment on a file and a current version about its file (void once returned). A
  -- payment changed in the last hour may still be in the receipts queue.
  select y.code, 'violation', 'payment', y.id, null, null, null, v_today - y.booking_date,
         jsonb_build_object('status', y.status)
  from (select c.id, c.booking_date, c.status,
               case when r.payment_id is null and c.status <> 'returned' then 'receipt_missing'
                    when r.numbers > 1 then 'receipt_numbers'
                    when c.status = 'returned' and r.payment_id is not null and cur.kind <> 'void' then 'receipt_not_void'
                    when c.status <> 'returned' and r.payment_id is not null
                         and (cur.kind = 'void' or cur.account_id is distinct from c.account_id) then 'receipt_stale'
               end as code
        from pos c
        left join (select x.payment_id, count(distinct x.number) as numbers, max(x.version) as v
                   from public.receipt x where x.organization_id = p_organization_id group by x.payment_id) r
          on r.payment_id = c.id
        left join public.receipt cur on cur.payment_id = c.id and cur.version = r.v
        where c.account_id is not null and c.updated_at < now() - interval '1 hour'
          and not (c.status in ('matched', 'partially_allocated') and c.review_reason is null)) y
  where y.code is not null

  union all
  -- R124-5: one notification per entry that moves what a client is owed, one per payment held for a file, one per
  -- return of a payment on a file.
  select 'notification_missing', 'violation', 'ledger_entry', e.id, null, null, null, null,
         jsonb_build_object('entry_type', e.entry_type, 'payment_id', e.payment_id)
  from public.ledger_entry e
  left join public.ledger_entry t on t.id = e.reverses_entry_id
  where e.organization_id = p_organization_id and e.payment_id is not null
    and (e.entry_type in ('allocation', 'forward') or (e.entry_type = 'reversal' and t.entry_type in ('allocation', 'forward')))
    and not exists (select 1 from public.client_notification n where n.ledger_entry_id = e.id)
  union all
  select 'notification_missing', 'violation', 'payment', c.id, null, null, null, null,
         jsonb_build_object('kind', 'payment_held')
  from pos c
  where c.review_reason = 'hold_blocks_allocation' and c.account_id is not null
    and not exists (select 1 from public.client_notification n
                    where n.payment_id = c.id and n.account_id = c.account_id and n.kind = 'payment_held')
  union all
  select 'notification_missing', 'violation', 'payment', l.payment_id, null, null, null, null,
         jsonb_build_object('kind', 'payment_returned')
  from public.bank_debit_link l
  join public.payment p on p.id = l.payment_id
  where l.organization_id = p_organization_id and l.kind = 'return' and p.account_id is not null
    and not exists (select 1 from public.client_notification n where n.ledger_entry_id = l.cash_entry_id)

  union all
  -- Statements (I9): a camt.053 statement whose opening is not the previous closing (« relevé manquant »), and each
  -- bank account's balance at its last statement against the ledger cash plus the lines not booked.
  select 'statement_gap', 'alert', 'bank_statement', x.id, null, (x.opening_booked_minor - x.prev_closing)::bigint,
         null, null,
         jsonb_build_object('bank_account_id', x.bank_account_id, 'from_date', x.from_date, 'previous_to_date', x.prev_to)
  from (select s.id, s.bank_account_id, s.from_date, s.opening_booked_minor,
               lag(s.closing_booked_minor) over w as prev_closing, lag(s.to_date) over w as prev_to
        from public.bank_statement s
        where s.organization_id = p_organization_id and s.status = 'imported' and s.format = 'camt053'
        window w as (partition by s.bank_account_id order by s.from_date, s.to_date, s.finished_at)) x
  where x.prev_closing is not null and x.prev_to < x.from_date and x.opening_booked_minor <> x.prev_closing
  union all
  select 'bank_balance_gap', 'alert', 'bank_account', z.bank_account_id, z.currency,
         (z.closing - z.cash - z.unposted)::bigint, null, null,
         jsonb_build_object('as_of', z.to_date, 'closing_minor', z.closing::text, 'cash_minor', z.cash::text,
                            'unposted_minor', z.unposted::text, 'unposted_lines', z.unposted_lines)
  from (select l.bank_account_id, l.currency, l.to_date, l.closing_booked_minor as closing,
               coalesce((select sum(lp.amount_minor) from public.ledger_account la
                         join public.ledger_posting lp on lp.ledger_account_id = la.id and lp.effective_date <= l.to_date
                         where la.bank_account_id = l.bank_account_id and la.book = 'client_money_cash'), 0) as cash,
               u.minor as unposted, u.lines as unposted_lines
        from (select distinct on (s.bank_account_id) s.bank_account_id, s.currency, s.to_date, s.closing_booked_minor
              from public.bank_statement s
              where s.organization_id = p_organization_id and s.status = 'imported' and s.format = 'camt053'
              order by s.bank_account_id, s.to_date desc, s.finished_at desc) l
        cross join lateral private.bank_unposted(l.bank_account_id, l.to_date) u) z
  where z.closing - z.cash - z.unposted <> 0

  union all
  -- servicer_shortfall (§15, P0; review fix): the servicer owes the dedicated account more than the top-ups ordered
  -- cover — 4679 in debit (the fees and losses booked on the account are the servicer's cost, founder #8, #9) less
  -- the top-ups ordered and not booked yet: an approvisionnement from the own account is to order, for this amount.
  select 'servicer_shortfall', 'alert', 'servicer', null, s.currency, (s.owed - coalesce(o.ordered, 0))::bigint, null,
         null, jsonb_build_object('due_to_servicer_minor', s.owed::text,
                                  'top_ups_ordered_minor', coalesce(o.ordered, 0)::text)
  from (select la.currency, sum(lp.amount_minor) as owed
        from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
        where la.organization_id = p_organization_id and la.book = 'due_to_servicer'
        group by la.currency) s
  left join (select x.currency, sum(x.amount_minor) as ordered from public.bank_transfer x
             where x.organization_id = p_organization_id and x.kind = 'top_up' and x.status in ('ordered', 'in_file')
             group by x.currency) o on o.currency = s.currency
  where s.owed - coalesce(o.ordered, 0) > 0

  union all
  -- Ageing (alerts, one row per code with the oldest and up to 50 payments or lines).
  select x.code, 'alert', 'servicer', null, x.currency, x.total, x.n, x.oldest, jsonb_build_object('ids', x.ids)
  from (select 'unmatched_ageing' as code, c.currency, sum(c.unallocated)::bigint as total, count(*)::integer as n,
               max(v_today - c.booking_date) as oldest,
               (array_agg(c.id order by c.booking_date, c.id))[1:50] as ids
        from pos c
        where c.status = 'unmatched' and v_today - c.booking_date >= 20
        group by c.currency
        union all
        select 'unallocated_ageing', c.currency, sum(c.unallocated)::bigint, count(*)::integer,
               max(v_today - c.booking_date), (array_agg(c.id order by c.booking_date, c.id))[1:50]
        from pos c
        where c.account_id is not null and c.unallocated > 0 and c.status in ('matched', 'partially_allocated')
          and c.review_reason is not null and v_today - c.booking_date >= 20
        group by c.currency
        union all
        select 'refund_pending_ageing', q.currency, sum(q.amount_minor)::bigint, count(*)::integer,
               max(v_today - (q.requested_at at time zone 'Europe/Paris')::date),
               (array_agg(q.payment_id order by q.requested_at, q.id))[1:50]
        from public.refund_request q
        where q.organization_id = p_organization_id and q.status = 'requested'
          and v_today - (q.requested_at at time zone 'Europe/Paris')::date >= 5
        group by q.currency
        union all
        -- returns, our refunds, credits undoing a debit (released duplicates of those kinds) not linked — they can
        -- only be booked, never explained — and other debits of a pending refund's amount on its bank account
        select 'debit_unclassified', t.currency, sum(t.amount_minor)::bigint, count(*)::integer,
               max(v_today - t.booking_date), (array_agg(t.id order by t.booking_date, t.id))[1:50]
        from public.bank_transaction t
        left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
        where t.organization_id = p_organization_id
          and (t.kind in ('return', 'refund_out', 'transfer_out', 'own_transfer_in', 'client_transfer_in')
               or (t.kind = 'suspected_duplicate'
                   and r.released_kind in ('return', 'refund_out', 'transfer_out', 'own_transfer_in',
                                           'client_transfer_in'))
               or (t.kind = 'other_debit' and t.direction = 'debit'
                   and exists (select 1 from public.refund_request q
                               where q.bank_account_id = t.bank_account_id and q.amount_minor = t.amount_minor
                                 and q.organization_id = t.organization_id and q.status = 'requested')))
          and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id)
          and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id)
          and not exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = t.id)
          and v_today - t.booking_date >= 3
        group by t.currency
        union all
        select 'duplicate_unresolved', t.currency, sum(t.amount_minor)::bigint, count(*)::integer,
               max(v_today - t.booking_date), (array_agg(t.id order by t.booking_date, t.id))[1:50]
        from public.bank_transaction t
        where t.organization_id = p_organization_id and t.kind = 'suspected_duplicate'
          and not exists (select 1 from public.bank_duplicate_resolution r where r.bank_transaction_id = t.id)
          and v_today - t.booking_date >= 3
        group by t.currency
        union all
        select 'direct_payment_waiting', d.currency, sum(d.amount_minor)::bigint, count(*)::integer,
               max(v_today - (d.requested_at at time zone 'Europe/Paris')::date),
               (array_agg(d.id order by d.requested_at, d.id))[1:50]
        from public.direct_payment d
        where d.organization_id = p_organization_id and d.status = 'requested' and d.requested_at < now() - interval '1 hour'
        group by d.currency) x;

  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select v_run, p_organization_id, c.code, c.severity, c.subject_type, c.subject_id, c.currency, c.amount_minor, c.count,
         c.oldest_days, coalesce(c.details, '{}')
  from pg_temp._chk c;
  -- M2c-4: the runs' checks (I15–I18, I21, the deadline alerts, the reference data), then the counts of everything
  perform private.run_remittance_checks(v_run, p_organization_id);
  select coalesce(jsonb_object_agg(x.code, x.n), '{}') into v_summary
  from (select c.code, count(*) as n from public.payment_check_result c where c.run_id = v_run group by c.code) x;
  select count(*) filter (where c.severity = 'violation'), count(*) filter (where c.severity = 'alert')
  into v_violations, v_alerts from public.payment_check_result c where c.run_id = v_run;
  update public.payment_check_run
  set finished_at = clock_timestamp(), violations = v_violations, alerts = v_alerts, summary = v_summary
  where id = v_run;
  return jsonb_build_object('run_id', v_run, 'violations', v_violations, 'alerts', v_alerts, 'by_code', v_summary);
end;
$$;

-- run_transfer_checks (redefined from 20261115090000): the alerts of the debits' bookings (plan §2.5) —
-- cancelled_transfer_debited (P0: e2e and batch lines, private.transfer_late_lines), transfer_debited_twice and
-- transfer_not_handed_out (P0: the job's reviews), payout_returned and sweep_returned (P0 while waiting),
-- payout_overrun (an advance at a booking, open), bank_line_unbooked (our lines left to ops > 1 business day: an I9
-- gap), servicer_funds_unswept (> 2 business days), top_up_pending (> 1 business day). transfer_not_debited and
-- remittance_payout_not_executed stay: booked transfers and runs leave them by status. Same settings.
create or replace function private.run_transfer_checks(p_check_run_id uuid, p_organization_id uuid,
                                                       p_today date default null)
returns void
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_today date := coalesce(p_today, private.paris_today());
  v_now timestamptz := case when p_today is null or p_today = private.paris_today() then clock_timestamp()
                            else (p_today + time '23:59:59') at time zone 'Europe/Paris' end;
  v_bd2 date;   -- the second business day on or before today: a day before it is more than 1 business day ago
  v_bd3 date;
begin
  select c.day into v_bd2 from public.business_calendar c
  where c.scope = 'FR-conservative' and not c.closed and c.day <= v_today and c.day > v_today - 30
  order by c.day desc offset 1 limit 1;
  select c.day into v_bd3 from public.business_calendar c
  where c.scope = 'FR-conservative' and not c.closed and c.day <= v_today and c.day > v_today - 30
  order by c.day desc offset 2 limit 1;
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  with flight as materialized (   -- the transfers in flight, per paying account (one pass each, keyed)
    select b.id as bank_account_id, b.currency, x.transfer_id, x.amount_minor, x.execution_date
    from public.bank_account b
    cross join lateral private.transfers_in_flight(b.id) x
    where b.organization_id = p_organization_id and b.purpose = 'client_funds')
  select p_check_run_id, p_organization_id, u.code, 'alert', u.subject_type, u.subject_id, u.currency, u.amount_minor,
         u.count, u.oldest_days, coalesce(u.details, '{}')
  from (
    select 'transfer_not_filed' as code, 'bank_account' as subject_type, t.debtor_bank_account_id as subject_id,
           t.currency, sum(t.amount_minor)::bigint as amount_minor, count(*)::integer as count,
           max(v_today - (t.created_at at time zone 'Europe/Paris')::date) as oldest_days,
           jsonb_build_object('ids', (array_agg(t.id order by t.created_at, t.id))[1:50]) as details
    from public.bank_transfer t
    where t.organization_id = p_organization_id and t.status = 'ordered' and t.kind in ('payout', 'refund', 'sweep')
      and (t.created_at at time zone 'Europe/Paris')::date < v_bd2
      and exists (select 1 from public.bank_account b where b.id = t.debtor_bank_account_id
                    and b.purpose = 'client_funds')
    group by t.debtor_bank_account_id, t.currency
    union all
    select 'file_not_downloaded', 'transfer_file', f.id, f.currency, f.ctrl_sum_minor, f.nb_of_txs,
           v_today - (f.generated_at at time zone 'Europe/Paris')::date, jsonb_build_object('number', f.number)
    from public.transfer_file f
    where f.organization_id = p_organization_id and f.status = 'generated'
      and (f.generated_at at time zone 'Europe/Paris')::date < v_bd2
    union all
    select 'file_not_marked_sent', 'transfer_file', f.id, f.currency, f.ctrl_sum_minor, f.nb_of_txs,
           v_today - f.first_execution_date, jsonb_build_object('number', f.number,
                                                                'first_execution_date', f.first_execution_date)
    from public.transfer_file f
    where f.organization_id = p_organization_id and f.status = 'downloaded'
      and private.transfer_file_cutoff_at(f.id) <= v_now
      and not (exists (select 1 from public.transfer_file_item i
                       cross join lateral (select t.status from public.bank_transfer t where t.id = i.transfer_id
                                           offset 0) t
                       where i.file_id = f.id and t.status = 'cancelled')
               and not private.transfer_file_executed(f.id))
    union all
    select 'transfer_not_debited', 'bank_account', x.bank_account_id, x.currency, sum(x.amount_minor)::bigint,
           count(*)::integer, max(v_today - x.execution_date),
           jsonb_build_object('ids', (array_agg(x.transfer_id order by x.execution_date, x.transfer_id))[1:50])
    from flight x
    where x.execution_date < v_bd3
    group by x.bank_account_id, x.currency
    union all
    select 'transfer_file_failed', 'transfer_file', f.id, f.currency, f.ctrl_sum_minor, f.nb_of_txs,
           v_today - (f.closed_at at time zone 'Europe/Paris')::date,
           jsonb_build_object('number', f.number, 'error', f.error)
    from public.transfer_file f
    where f.organization_id = p_organization_id and f.status = 'failed'
      and exists (select 1 from public.transfer_file_item i join public.bank_transfer t on t.id = i.transfer_id
                  where i.file_id = f.id and t.status = 'ordered')
    union all
    select 'transfer_file_pending', 'transfer_file', f.id, f.currency, f.ctrl_sum_minor, f.nb_of_txs,
           v_today - (f.created_at at time zone 'Europe/Paris')::date,
           jsonb_build_object('number', f.number, 'created_at', f.created_at)
    from public.transfer_file f
    where f.organization_id = p_organization_id and f.status = 'pending'
      and f.created_at + interval '15 minutes' <= v_now
    union all
    select 'payee_name_mismatch', 'client_payout_account', c.payout_account_id, null, null, 1,
           v_today - (c.recorded_at at time zone 'Europe/Paris')::date,
           jsonb_build_object('client_id', c.client_organization_id, 'result', c.result, 'check_id', c.id)
    from public.payee_name_check c
    where c.organization_id = p_organization_id and c.cleared_at is null
      and private.payee_check_open(c.payout_account_id)
    union all
    select 'transfer_already_debited', 'bank_transfer', t.id, t.currency, t.amount_minor, 1,
           v_today - (t.created_at at time zone 'Europe/Paris')::date,
           jsonb_build_object('kind', t.kind, 'status', t.status, 'end_to_end_id', t.end_to_end_id, 'run_id', t.run_id,
                              'bank_account_id', t.debtor_bank_account_id)
    from public.bank_transfer t
    where t.organization_id = p_organization_id and t.kind in ('payout', 'refund')
      and (t.status = 'ordered' or (t.status = 'in_file' and t.replaces_transfer_id is not null))
      and exists (select 1 from public.bank_account b where b.id = t.debtor_bank_account_id
                    and b.purpose = 'client_funds')
      and private.transfer_debited_before(t.id)
    union all
    select 'transfer_already_debited', 'bank_transfer', t.id, t.currency, t.amount_minor, 1,
           v_today - (t.created_at at time zone 'Europe/Paris')::date,
           jsonb_build_object('kind', t.kind, 'status', t.status, 'end_to_end_id', t.end_to_end_id, 'run_id', t.run_id,
                              'bank_account_id', t.debtor_bank_account_id)
    from public.bank_account b
    cross join lateral private.debited_cancelled_sweeps(b.id) s (id)
    cross join lateral (select x.* from public.bank_transfer x where x.id = s.id offset 0) t
    where b.organization_id = p_organization_id and b.purpose = 'client_funds'
    union all
    -- review round 4 (G1): a cancelled payout or refund whose run or refund is still live, debited after all (cancelling
    -- the run or the refund is refused; M2c-6b books the debit). Keyed: the live runs and the waiting refunds.
    select 'transfer_already_debited', 'bank_transfer', t.id, t.currency, t.amount_minor, 1,
           v_today - (t.created_at at time zone 'Europe/Paris')::date,
           jsonb_build_object('kind', t.kind, 'status', t.status, 'end_to_end_id', t.end_to_end_id, 'run_id', t.run_id,
                              'bank_account_id', t.debtor_bank_account_id)
    from (select r.transfer_id from public.remittance_run r
          where r.organization_id = p_organization_id and r.status in ('approved', 'sent') and r.transfer_id is not null
          union
          select q.transfer_id from public.refund_request q
          where q.organization_id = p_organization_id and q.status = 'requested' and q.transfer_id is not null) l
    cross join lateral (select x.* from public.bank_transfer x where x.id = l.transfer_id offset 0) t
    where t.status = 'cancelled' and t.kind in ('payout', 'refund')
      and exists (select 1 from public.bank_account b where b.id = t.debtor_bank_account_id
                    and b.purpose = 'client_funds')
      and private.transfer_debited_before(t.id)
    union all
    select h.code, 'bank_transfer', t.id, t.currency, t.amount_minor, 1,
           v_today - (t.created_at at time zone 'Europe/Paris')::date,
           jsonb_build_object('kind', t.kind, 'end_to_end_id', t.end_to_end_id, 'run_id', t.run_id,
                              'bank_account_id', t.debtor_bank_account_id)
    from public.bank_transfer t
    cross join lateral (select 'payee_name_not_epc' as code where private.epc_name_empty(t.payee_name)
                        union all
                        select 'iban_not_sepa' where not private.iban_in_sepa(t.payee_iban)) h
    where t.organization_id = p_organization_id and t.status = 'ordered' and t.kind in ('payout', 'refund')
      and exists (select 1 from public.bank_account b where b.id = t.debtor_bank_account_id
                    and b.purpose = 'client_funds')
    union all
    -- M2c-6b-1 (P0): a debit of a cancelled transfer — its own id, or a batch line that can hold it
    -- (private.transfer_late_lines: private.transfer_debited_before's two branches) — not booked nor linked, one row per
    -- line, whatever the state of its run or refund (a cancelled one included: G1c); and a line the debit job left to
    -- ops for it. The source: the cancelled transfers that were in a downloaded file (their partial index).
    select 'cancelled_transfer_debited', 'bank_transaction', x.id, x.currency, x.amount_minor, 1,
           v_today - x.booking_date,
           jsonb_build_object('transfer_ids', l.transfer_ids, 'kinds', l.kinds, 'run_ids', l.run_ids,
                              'refund_request_ids', l.refund_ids, 'pmt_inf_id', x.payment_info_id,
                              'end_to_end_id', x.end_to_end_id)
    from (select z.line_id,
                 coalesce(jsonb_agg(distinct z.transfer_id) filter (where z.transfer_id is not null), '[]') as transfer_ids,
                 coalesce(jsonb_agg(distinct z.kind) filter (where z.kind is not null), '[]') as kinds,
                 coalesce(jsonb_agg(distinct z.run_id) filter (where z.run_id is not null), '[]') as run_ids,
                 coalesce(jsonb_agg(distinct z.refund_id) filter (where z.refund_id is not null), '[]') as refund_ids
          from (select ll.line_id, t.id as transfer_id, t.kind, t.run_id,
                       (select q.id from public.refund_request q
                        where q.transfer_id = t.id
                           or q.transfer_id = (select y.id from public.bank_transfer y where y.replaces_transfer_id = t.id)
                        limit 1) as refund_id
                from public.bank_account b
                cross join lateral (select q.id, q.kind, q.run_id from public.bank_transfer q
                                    where q.organization_id = p_organization_id and q.debtor_bank_account_id = b.id
                                      and q.status = 'cancelled' and q.transfer_file_id is not null offset 0) t
                cross join lateral private.transfer_late_lines(t.id) ll (line_id)
                where b.organization_id = p_organization_id and b.purpose = 'client_funds'
                  and exists (select 1 from public.transfer_file_item i
                              cross join lateral (select f.download_count from public.transfer_file f
                                                  where f.id = i.file_id offset 0) f
                              where i.transfer_id = t.id and f.download_count > 0)
                union all
                select v.bank_transaction_id, null::uuid, null::text, null::uuid, null::uuid
                from public.bank_debit_review v
                where v.organization_id = p_organization_id and v.reason = 'cancelled_transfer_debited') z
          group by z.line_id) l
    cross join lateral (select q.* from public.bank_transaction q where q.id = l.line_id offset 0) x
    where not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = x.id offset 0)
      and not exists (select 1 from public.bank_debit_link k where k.bank_transaction_id = x.id and k.kind <> 'explained'
                      offset 0)
    union all
    -- a second debit of a transfer booked or returned, a debit of a transfer never handed out (the bank has bytes we
    -- never served): the lines the debit job left to ops for it (P0; plan §2.3)
    select v.reason, 'bank_transaction', x.id, x.currency, x.amount_minor, 1, v_today - x.booking_date,
           jsonb_build_object('end_to_end_id', x.end_to_end_id, 'pmt_inf_id', x.payment_info_id,
                              'candidates', v.candidates)
    from public.bank_debit_review v
    cross join lateral (select q.* from public.bank_transaction q where q.id = v.bank_transaction_id offset 0) x
    where v.organization_id = p_organization_id and v.reason in ('transfer_debited_twice', 'transfer_not_handed_out')
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = x.id offset 0)
      and not exists (select 1 from public.bank_debit_link k where k.bank_transaction_id = x.id offset 0)
    union all
    -- a payout returned by the client's bank (P0 while its item waits to be paid again: drafted at once by the
    -- schedule, trigger payout_returned; the payout account `returned` until replaced or reconfirmed)
    select 'payout_returned', 'remittance_run', bt.run_id, q.currency, q.amount_minor, 1,
           v_today - (q.posted_at at time zone 'Europe/Paris')::date,
           jsonb_build_object('client_id', q.client_organization_id, 'transfer_id', bt.id,
                              'end_to_end_id', bt.end_to_end_id, 'draft_run_id', q.draft_run_id)
    from private.remittance_pending q
    cross join lateral (select e.reverses_entry_id from public.ledger_entry e where e.id = q.ledger_entry_id offset 0) e
    cross join lateral (select r.source_id from public.ledger_entry r
                        where r.id = e.reverses_entry_id and r.source_type = 'bank_transfer' offset 0) re
    cross join lateral (select t.id, t.run_id, t.end_to_end_id from public.bank_transfer t
                        where t.id = case when pg_input_is_valid(re.source_id, 'uuid') then re.source_id::uuid end
                        offset 0) bt
    where q.organization_id = p_organization_id and q.kind = 'payout_returned'
    union all
    -- a sweep returned by the own account's bank (P0 while the servicer's share is not swept again)
    select 'sweep_returned', 'bank_transfer', t.id, t.currency, t.amount_minor, 1, v_today - re.effective_date,
           jsonb_build_object('end_to_end_id', t.end_to_end_id, 'bank_account_id', t.debtor_bank_account_id)
    from public.bank_transfer t
    cross join lateral (select e.effective_date, e.posted_at from public.ledger_entry e
                        where e.id = t.return_entry_id offset 0) re
    where t.organization_id = p_organization_id and t.kind = 'sweep' and t.status = 'returned'
      and not exists (select 1 from public.bank_transfer s
                      where s.organization_id = t.organization_id and s.kind = 'sweep'
                        and s.debtor_bank_account_id = t.debtor_bank_account_id and s.created_at > re.posted_at
                        and s.status <> 'cancelled')
    union all
    -- an advance the servicer made at a payout's debit (the payout went beyond what the client was owed: a collection
    -- reversed after the approval), open until recovered (M2c-7's advance_open takes it over)
    select 'payout_overrun', 'client_advance', a.id, a.currency, (a.amount_minor - coalesce(s.settled, 0))::bigint, 1,
           v_today - (a.created_at at time zone 'Europe/Paris')::date,
           jsonb_build_object('client_id', a.client_organization_id, 'transfer_id', a.transfer_id,
                              'bank_transaction_id', a.bank_transaction_id)
    from public.client_advance a
    left join lateral (select sum(c.amount_minor) as settled from public.commission_settlement c
                       where c.document_kind = 'advance' and c.document_id = a.id) s on true
    where a.organization_id = p_organization_id and a.cause = 'payout_overrun'
      and a.amount_minor > coalesce(s.settled, 0)
    union all
    -- our transfer lines left to ops more than one business day (an I9 gap: 5120 and the bank differ by them)
    select 'bank_line_unbooked', 'bank_account', x.bank_account_id, x.currency, sum(x.amount_minor)::bigint,
           count(*)::integer, max(v_today - x.booking_date),
           jsonb_build_object('ids', (array_agg(x.id order by x.booking_date, x.id))[1:50],
                              'reasons', to_jsonb(array_agg(distinct v.reason)))
    from public.bank_debit_review v
    cross join lateral (select q.* from public.bank_transaction q where q.id = v.bank_transaction_id offset 0) x
    where v.organization_id = p_organization_id and x.booking_date < v_bd2
      and (x.kind = 'transfer_out'
           or (x.direction = 'debit' and x.end_to_end_id is null and x.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$')
           or (x.direction = 'credit' and x.kind = 'return'
               and coalesce(x.original_end_to_end_id, x.end_to_end_id) ~ '^(RMT|SWP)[0-9A-F]{12}$'))
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = x.id offset 0)
      and not exists (select 1 from public.bank_debit_link k where k.bank_transaction_id = x.id and k.kind <> 'explained'
                      offset 0)
    group by x.bank_account_id, x.currency
    union all
    -- the servicer's settled share on the dedicated account for more than two business days, no sweep ordered or in
    -- a file (§13 #8): −Σ4679 > 0 three business days ago and today
    select 'servicer_funds_unswept', 'servicer', null, s.currency, (-s.now_owed)::bigint, null, null,
           jsonb_build_object('due_to_servicer_minor', s.now_owed::text, 'as_of', v_bd3)
    from (select la.currency, sum(lp.amount_minor) as now_owed,
                 coalesce(sum(lp.amount_minor) filter (where lp.effective_date <= v_bd3), 0) as then_owed
          from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
          where la.organization_id = p_organization_id and la.book = 'due_to_servicer'
          group by la.currency) s
    where s.now_owed < 0 and s.then_owed < 0
      and not exists (select 1 from public.bank_transfer x
                      where x.organization_id = p_organization_id and x.kind = 'sweep' and x.currency = s.currency
                        and x.status in ('ordered', 'in_file'))
    union all
    -- a top-up ordered more than one business day ago, its credit not booked yet
    select 'top_up_pending', 'bank_transfer', t.id, t.currency, t.amount_minor, 1,
           v_today - (t.created_at at time zone 'Europe/Paris')::date,
           jsonb_build_object('end_to_end_id', t.end_to_end_id, 'bank_account_id', t.creditor_bank_account_id)
    from public.bank_transfer t
    where t.organization_id = p_organization_id and t.kind = 'top_up' and t.status in ('ordered', 'in_file')
      and (t.created_at at time zone 'Europe/Paris')::date < v_bd2) u;
end;
$$;

-- Whether a debit line of the paying account could still be this transfer's debit (review legal-texts#2: evidence of
-- absence before an in-flight payout is proven unpaid): a line not booked nor linked, booked from the transfer's
-- requested execution date to p_to, that carries its end-to-end id, or names its PmtInf in its current file with no
-- end-to-end id (a batch line, whatever its amount: one member may have been rejected), or carries neither reference
-- for exactly its amount (a CSV export without the « référence de bout en bout » column, a bank that drops it). Such a
-- line waits for ops (M2c-6b-2 books it, writing the breach row if the debit was late; classified as something else,
-- the next nightly check writes it). Keyed: the transfer by its key, the account's lines by (account, booking date).
create or replace function private.transfer_debit_may_be_seen(p_transfer_id uuid, p_to date)
returns boolean
language plpgsql
stable
set search_path = ''
set enable_seqscan = off
as $$
declare
  t public.bank_transfer;
  v_pmt_inf text;
begin
  select * into t from public.bank_transfer where id = p_transfer_id;
  if t.id is null or p_to is null or p_to < t.requested_execution_date then
    return false;
  end if;
  select i.pmt_inf_id into v_pmt_inf from public.transfer_file_item i
  where i.file_id = t.transfer_file_id and i.transfer_id = t.id;
  return exists (
    select 1
    from (select x.id, x.direction, x.end_to_end_id, x.payment_info_id, x.amount_minor, x.currency
          from public.bank_transaction x
          where x.bank_account_id = t.debtor_bank_account_id
            and x.booking_date between t.requested_execution_date and p_to offset 0) x
    where x.direction = 'debit'
      and (x.end_to_end_id = t.end_to_end_id
           or (x.end_to_end_id is null and x.payment_info_id = v_pmt_inf)
           or (x.end_to_end_id is null and x.payment_info_id is null and x.amount_minor = t.amount_minor
               and x.currency = t.currency))
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = x.id offset 0)
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = x.id offset 0));
end;
$$;

-- The runs' checks (the M2c-5b body of 20261114090000, which 20261115090000 renamed run_remittance_runs_checks; the
-- body unchanged but for two breach rows, plan §2.5 [critic]): an in-flight item's breach row is written only once the
-- paying account's statements cover its latest execution date without the payout's debit — and without a line that
-- could still be it (review legal-texts#2: private.transfer_debit_may_be_seen) —; a returned payout's item breached
-- while waiting, or paid again and breached in flight, is recorded `payout_returned` (Q7). Same settings.
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
begin
  select max(c.started_at) into v_since from public.payment_check_run c
  where c.organization_id = p_organization_id and c.id <> p_check_run_id and c.finished_at is not null;
  v_full := v_since is null or extract(isodow from v_today) = 7;
  v_failures := least(coalesce(v_since, clock_timestamp()), clock_timestamp() - interval '24 hours');

  with dl as materialized (     -- the collections waiting, of files under a mandate with terms (review legal#2)
    select * from private.pending_item_deadlines(p_organization_id) d where d.monitored),
  ol as materialized (          -- the collections of runs approved or sent, not debited by their date (legal#3)
    select * from private.inflight_overdue_lines(p_organization_id, v_today)),
  ua as materialized (          -- money matched to a file, not allocated (legal#7, perf#0)
    select * from private.unallocated_payment_deadlines(p_organization_id)),
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
  olc as materialized (
    select k.run_id, k.latest_execution_date,
           coalesce(t.status = 'ordered' or (t.status = 'in_file' and coalesce(t.download_count, 0) = 0)
                    or (private.statement_covers(t.debtor_bank_account_id, k.latest_execution_date,
                                                 k.latest_execution_date)
                        and not private.transfer_debit_seen(t.id)
                        and not private.transfer_debit_may_be_seen(t.id, k.latest_execution_date)), false) as proven
    from (select distinct o.run_id, o.latest_execution_date from ol o where not o.out_of_horizon) k
    left join lateral (select q.id, q.debtor_bank_account_id, q.status,
                              (select f.download_count from public.transfer_file f where f.id = q.transfer_file_id)
                                as download_count
                       from public.remittance_run r join public.bank_transfer q on q.id = r.transfer_id
                       where r.id = k.run_id offset 0) t on true),
  inflight_breach as (
    insert into public.remittance_deadline_breach (organization_id, client_organization_id, ledger_entry_id, payment_id,
                                                   run_id, deadline, latest_execution_date, requested_execution_date,
                                                   late_reason, blocked_reason)
    select p_organization_id, o.client_organization_id, o.ledger_entry_id, o.payment_id, o.run_id, o.deadline,
           o.latest_execution_date, o.requested_execution_date, o.late_reason,
           -- a returned payout paid again (Q7, review legal-texts#1): its line's kind, by the item's live line
           case when (select x.kind from public.remittance_line x
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
  select 'invoice_overdue', 'alert', 'commission_invoice', i.id, i.currency, o.open, null, v_today - i.due_date,
         jsonb_build_object('number', i.number, 'client_id', i.client_organization_id, 'settlement', i.settlement,
                            'due_date', i.due_date)
  from public.commission_invoice i
  cross join lateral (select private.document_open(i.id) as open) o
  where i.organization_id = p_organization_id and i.due_date is not null and i.due_date < v_today and o.open > 0
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

-- The pending items' deadlines (redefined from 20261112090000): + a payout that came back, held to its returned run's
-- earliest line date (design §9.2). Same settings.
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
                        offset 0) bt
    cross join lateral (select l.payment_id, l.encaissement_date, l.mandate_id, l.mandate_terms_id
                        from public.remittance_line l
                        where l.run_id = bt.run_id and l.amount_minor > 0 and not l.released
                          and l.latest_execution_date is not null and l.encaissement_date is not null
                        order by l.latest_execution_date, l.line_no limit 1) rl
    left join lateral (select mt.remittance_max_days as days from public.mandate_terms mt
                       where mt.mandate_id = rl.mandate_id and mt.valid_from <= rl.encaissement_date
                         and (mt.valid_to is null or rl.encaissement_date < mt.valid_to)
                       limit 1) t on true
    left join lateral (select mt.mandate_id, mt.remittance_max_days as days from public.mandate_terms mt
                       where rl.mandate_id is null and mt.id = rl.mandate_terms_id offset 0) ti on true
    where q.organization_id = p_organization_id and q.amount_minor > 0 and q.kind = 'payout_returned'
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

-- The lines of an approved run paid after their latest execution date (redefined from 20261112090000; review
-- legal-texts#1, Q7's default, OQ-36): as before — its late approval always, a breach row per item paid after the date
-- it is held to unless one was written, one month for a delay that cannot be met — and a returned payout paid again
-- (a line `payout_returned`, held to its returned run's date by the prepare) has its breach recorded « bloqué :
-- virement revenu impayé » (blocked_reason payout_returned), as the nightly check records it while it waits. Same
-- settings.
create or replace function private.remittance_late_lines(r public.remittance_run, p_paid_on date)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if r.earliest_latest_execution_date is null or p_paid_on <= r.earliest_latest_execution_date then
    return;   -- no line late (the header's earliest date is the lines' minimum)
  end if;
  with late as materialized (
    select l.ledger_entry_id, l.payment_id, l.deadline, l.latest_execution_date, l.unmeetable, l.encaissement_date,
           l.kind
    from public.remittance_line l
    where l.run_id = r.id and l.amount_minor > 0 and l.latest_execution_date < p_paid_on),
  m as materialized (   -- one month, once per distinct E of the unmeetable lines
    select k.e_date, d.deadline, d.latest_execution_date
    from (select distinct x.encaissement_date as e_date from late x
          where x.unmeetable and x.encaissement_date is not null) k
    cross join lateral private.remittance_deadline_or_null(k.e_date, 30) d)
  insert into public.remittance_deadline_breach (organization_id, client_organization_id, ledger_entry_id, payment_id,
                                                 run_id, deadline, latest_execution_date, requested_execution_date,
                                                 late_reason, blocked_reason)
  select r.organization_id, r.client_organization_id, l.ledger_entry_id, l.payment_id, r.id,
         case when l.unmeetable then m.deadline else l.deadline end,
         case when l.unmeetable then m.latest_execution_date else l.latest_execution_date end, p_paid_on, r.late_reason,
         case when l.kind = 'payout_returned' then 'payout_returned' end
  from late l left join m on l.unmeetable and m.e_date = l.encaissement_date
  where not l.unmeetable or m.latest_execution_date < p_paid_on   -- (a month the calendar cannot place: its alert)
  on conflict (ledger_entry_id) do nothing;
  insert into public.remittance_late_approval (run_id, ledger_entry_id, organization_id, client_organization_id,
                                               latest_execution_date, requested_execution_date, late_reason,
                                               approved_by)
  select r.id, l.ledger_entry_id, r.organization_id, r.client_organization_id, l.latest_execution_date, p_paid_on,
         r.late_reason, r.approval_requested_by
  from public.remittance_line l
  where l.run_id = r.id and l.amount_minor > 0 and l.latest_execution_date < p_paid_on;
end;
$$;

-- The client's statement (redefined from 20261114090000; review round 2, L1 — new:statement-late-cause): a returned
-- payout put back in a run keeps its R124-6 date (K2), so its line can be late; its cause is then `payout_returned`
-- (« virement revenu impayé, reversé à nouveau »), tested first — never a collection's « identifié tardivement » or
-- « validation tardive ». Same settings and grants; payloads drawn before keep their bytes (no line of this kind was
-- ever late before K2).
create or replace function private.remittance_statement_build(p_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
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
  v_follow jsonb;
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
         n.reason as nature_reason, x.encaissement_date, x.effective_date, x.deadline, x.commission_state,
         coalesce(pt.rules, '[]'::jsonb) as rules, coalesce(pt.rates, '[]'::jsonb) as rates,
         coalesce(pt.basis, 0) as basis, coalesce(inv.number, cn.number) as invoice, rc.number as receipt,
         la.ledger_entry_id is not null as late, lc.cause as late_cause
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
  -- why a line was paid after its latest execution date, from the data (review legal#6; the approver's reason stays
  -- in the back office): a payout of it that came back unpaid, paid again (M2c-6b-1 review round 2, L1: the line keeps
  -- the date of the run line it came from, K2), the mandate's delay could not be met (held to one month, R124-6), the
  -- collection reached the queue after its J-5 date (the deadline guard's margin, 5 business days before its latest
  -- execution date), or the approval came late
  left join lateral (select case when x.kind = 'payout_returned' then 'payout_returned'
                                 when x.unmeetable then 'unmeetable'
                                 when private.business_days_between((x.posted_at at time zone 'Europe/Paris')::date,
                                                                    x.latest_execution_date) < 5
                                 then 'identified_late'
                                 else 'approved_late' end as cause
                     where la.ledger_entry_id is not null offset 0) lc on true;

  select coalesce(jsonb_agg(jsonb_build_array(
           f.source_line_no, f.mandate, f.portfolio, f.file, f.debtor, f.items, f.components, f.kind, f.nature_reason,
           f.from_run, f.encaissement_date, f.effective_date, f.deadline, f.amount_minor::text, f.rules, f.rates,
           f.basis::text, f.commission_minor::text, f.commission_state, f.invoice, f.receipt, f.late, f.late_cause)
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
                    then f.nature_reason end as reason,
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
  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', s ->> 'kind', 'document_kind', i.kind, 'number', i.number, 'issue_date', i.issue_date,
           'amount_minor', s ->> 'amount') order by i.seq nulls last, s ->> 'document_id'), '[]')
  into v_earlier
  from jsonb_array_elements(case when v_cancelled then '[]'::jsonb
                                 else coalesce(r.settlement_plan -> 'settles', '[]') end) s
  left join lateral (select q.kind, q.number, q.issue_date, q.seq, q.run_id from public.commission_invoice q
                     where q.id = (s ->> 'document_id')::uuid offset 0) i on true
  where i.run_id is distinct from r.id and (s ->> 'amount')::bigint <> 0;

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

  -- the previous run's payout: what became of it (« Suivi »)
  select * into v_prev from public.remittance_run x where x.id = r.previous_run_id;
  if v_prev.id is not null then
    select jsonb_agg(jsonb_build_object(
             'number', v_prev.number, 'status', v_prev.status, 'net_minor', v_prev.net_minor::text,
             'transfer_status', t.status, 'requested_execution_date', t.requested_execution_date,
             'amount_minor', t.amount_minor::text,
             'debited_on', (select e.effective_date from public.ledger_entry e where e.id = t.entry_id),
             'returned_on', (select e.effective_date from public.ledger_entry e where e.id = t.return_entry_id),
             'booked_on', v_prev.booked_on))
    into v_follow
    from (select 1) one left join public.bank_transfer t on t.id = v_prev.transfer_id;
  end if;

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
    'schema', 1,
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
    'follow_up', coalesce(v_follow, '[]'),
    'not_remitted', jsonb_build_object('held', v_held, 'refunded', v_refunded),
    'position', v_position);

  return v_payload;
end;
$$;

-- What the client space shows (redefined from 20261113090000; review legal-texts#6): as before, and its runs whose
-- payout came back (their run stays booked, §9.7: « Virement débité de notre compte » would read as paid) —
-- `returned_runs`: each run's id, the date of the bank's return credit, the payout's amount (text) and `repaid_by` (review
-- round 2, L2: the number of the booked run that paid it again, or null), so the page says « Virement revenu impayé le
-- … : reversé à nouveau par le reversement … » once paid again, « … : son montant sera reversé par un prochain
-- reversement » before. The client cannot read bank_transfer (money staff only): it is read here, for the client's own
-- runs. Same settings.
create or replace function public.client_remittance_summary(p_client_organization_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c public.organization;
  v_owed jsonb;
  v_flight jsonb;
  v_returned jsonb;
  v_today date := private.paris_today();
begin
  select * into c from public.organization where id = p_client_organization_id;
  if not found or not (c.id = any (private.client_whole_org_ids())
                       or c.servicer_organization_id = any (private.money_staff_org_ids())) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('currency', x.currency, 'owed_minor', x.owed::text,
                                               'in_flight_gross_minor', x.gross::text, 'in_flight_runs', x.runs)
                            order by x.currency), '[]')
  into v_owed
  from (select coalesce(b.currency, f.currency) as currency, coalesce(-b.balance_minor, 0) as owed,
               coalesce(f.gross, 0) as gross, coalesce(f.runs, '[]'::jsonb) as runs
        from (select y.currency, y.balance_minor from private.client_payable_balance y
              where y.client_organization_id = c.id and y.balance_minor <> 0) b
        full join (select r.currency, sum(r.gross_minor) as gross,
                          jsonb_agg(jsonb_build_object(
                            'number', r.number, 'status', r.status,
                            'gross_minor', r.gross_minor::text, 'net_minor', r.net_minor::text,
                            'commission_minor', coalesce(r.commission_taken_minor, 0)::text,
                            'advance_minor', coalesce(r.advance_recovered_minor, 0)::text,
                            'refund_minor', coalesce(r.refund_minor, 0)::text,
                            'requested_execution_date', r.requested_execution_date)
                            order by r.approved_at, r.number) as runs
                   from public.remittance_run r
                   where r.client_organization_id = c.id and r.status in ('approved', 'sent')
                   group by r.currency) f on f.currency = b.currency) x;
  select coalesce(jsonb_agg(jsonb_build_object('number', r.number, 'status', r.status, 'currency', r.currency,
                                               'net_minor', r.net_minor::text,
                                               'requested_execution_date', r.requested_execution_date,
                                               'approved_on', (r.approved_at at time zone 'Europe/Paris')::date)
                            order by r.approved_at), '[]')
  into v_flight from public.remittance_run r
  where r.client_organization_id = c.id and r.status in ('approved', 'sent');
  -- the client's runs whose payout came back: the transfer by its key, the return's line by its booking; review round 2
  -- (L2): `repaid_by`, the number of the run whose live line holds the payout_returned item the return put back (its
  -- entry is the transfer's return entry: the live line by its key) once that run is booked — null until then
  select coalesce(jsonb_agg(jsonb_build_object('run_id', r.id, 'returned_on', x.returned_on,
                                               'amount_minor', t.amount_minor::text, 'repaid_by', p.number)
                            order by x.returned_on, r.number), '[]')
  into v_returned
  from public.remittance_run r
  cross join lateral (select q.id, q.status, q.amount_minor, q.return_entry_id from public.bank_transfer q
                      where q.id = r.transfer_id offset 0) t
  cross join lateral (select coalesce(
                               (select l.booking_date from public.bank_line_booking k
                                join public.bank_transaction l on l.id = k.bank_transaction_id
                                where k.transfer_id = t.id and k.kind = 'payout_returned' limit 1),
                               (select e.effective_date from public.ledger_entry e where e.id = t.return_entry_id))
                             as returned_on) x
  left join lateral (select y.number
                     from (select l.run_id from public.remittance_line l
                           where l.ledger_entry_id = t.return_entry_id and not l.released
                             and l.kind = 'payout_returned' offset 0) l
                     cross join lateral (select q.number, q.status from public.remittance_run q
                                         where q.id = l.run_id offset 0) y
                     where y.status = 'booked') p on true
  where r.client_organization_id = c.id and r.transfer_id is not null and t.status = 'returned';
  return jsonb_build_object('owed', v_owed, 'in_flight', v_flight, 'returned_runs', v_returned,
                            'next_run_day', private.next_scheduled_run_day(c.id, v_today + 1),
                            'today', v_today);
end;
$$;

-- The accounting export (redefined from 20261113090000): the document of the debits' entries — our transfer's
-- end-to-end id, a bank line's reference, an advance's cause (R123-174; plan §2.5 [critic]). Same settings.
create or replace function public.accounting_export_entries(p_from date, p_to date, p_after text default null,
                                                           p_limit integer default 1000)
returns table (effective_date date, entry_id uuid, entry_type text, source_type text, source_ref text,
               client_name text, account_number text, book text, debit_minor bigint, credit_minor bigint,
               currency char(3), posted_at timestamptz, page_key text)
language plpgsql
stable
security definer
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
set enable_seqscan = off
as $$
declare
  v_org uuid := (private.money_staff_org_ids())[1];
  v_limit integer := least(greatest(coalesce(p_limit, 1000), 1), 1000);
  v_date date;
  v_posted timestamptz;
  v_entry uuid;
  v_line integer;
begin
  if v_org is null then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    raise exception 'accounting export refused: period' using errcode = '22023';
  end if;
  if p_after is not null then
    begin
      v_date := split_part(p_after, '|', 1)::date;
      v_posted := (split_part(p_after, '|', 2) || '+00')::timestamptz;
      v_entry := split_part(p_after, '|', 3)::uuid;
      v_line := split_part(p_after, '|', 4)::integer;
    exception when others then
      raise exception 'accounting export refused: page' using errcode = '22023';
    end;
  end if;
  return query
  select p.effective_date, e.id, e.entry_type, e.source_type,
         coalesce(case e.source_type
                    when 'commission_invoice'
                      then (select i.number from public.commission_invoice i where i.id = e.source_id::uuid)
                    when 'remittance_run'
                      then (select x.number from public.remittance_run x where x.id = e.source_id::uuid)
                    -- M2c-6b-1 (plan §2.5 [critic], R123-174): our transfer by its end-to-end id, a bank line by its
                    -- bank reference, an advance by its cause
                    when 'bank_transfer'
                      then (select x.end_to_end_id from public.bank_transfer x where x.id = e.source_id::uuid)
                    when 'bank_transaction'
                      then (select coalesce(x.acct_svcr_ref, x.entry_ref, x.end_to_end_id, x.payment_info_id)
                            from public.bank_transaction x where x.id = e.source_id::uuid)
                    when 'client_advance'
                      then (select 'Avance ' || case x.cause when 'payout_overrun' then 'reversement au-delà du dû'
                                                             when 'double_payout' then 'reversement en double'
                                                             else 'retour après reversement' end
                            from public.client_advance x where x.id = e.source_id::uuid) end,
                  e.source_id),
         (select o.legal_name from public.organization o where o.id = la.client_organization_id),
         b.account_number, la.book,
         case when p.amount_minor > 0 then p.amount_minor else 0 end::bigint,
         case when p.amount_minor < 0 then -p.amount_minor else 0 end::bigint,
         p.currency, e.posted_at,
         to_char(p.effective_date, 'YYYY-MM-DD') || '|'
           || to_char(e.posted_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US') || '|' || e.id::text || '|'
           || lpad(p.line_no::text, 6, '0')
  from public.ledger_account la
  cross join lateral (select q.account_number from public.ledger_book q where q.code = la.book offset 0) b
  cross join lateral (select q.* from public.ledger_posting q
                      where q.ledger_account_id = la.id
                        and q.effective_date between greatest(p_from, coalesce(v_date, p_from)) and p_to
                      offset 0) p
  cross join lateral (select q.* from public.ledger_entry q where q.id = p.entry_id offset 0) e
  where la.organization_id = v_org and la.claim_item_id is null
    and la.book in ('servicer_revenue', 'vat_collected', 'vat_pending', 'bank_fees', 'servicer_losses',
                    'commission_receivable', 'client_advance_receivable', 'own_cash')
    and (p_after is null or (p.effective_date, e.posted_at, e.id, p.line_no) > (v_date, v_posted, v_entry, v_line))
  order by p.effective_date, e.posted_at, e.id, p.line_no
  limit v_limit;
end;
$$;

------------------------------------------------------------------------------------------
-- Privileges (restated for every function redefined here; the new ones internal, or the worker's)
------------------------------------------------------------------------------------------

revoke execute on function private.client_advance_guard(), private.pmt_inf_single_refund(uuid, text),
  private.bank_booking_candidates(uuid, date, uuid, integer), private.post_run_settlements(uuid[], date[]),
  private.bank_line_cash_moved(uuid, uuid), private.batch_line_may_hold(uuid, uuid, text, uuid),
  private.transfer_late_lines(uuid), private.bank_booking_begin(), private.bank_booking_post_rows(uuid),
  private.post_bank_bookings(uuid, boolean), private.apply_bank_bookings(uuid), private.bank_line_booking_guard(),
  private.bank_line_booking_check(), private.debit_candidates(uuid, date, uuid, integer),
  private.post_debit_links(uuid, boolean), private.run_payment_checks(uuid),
  private.run_remittance_runs_checks(uuid, uuid, date), private.run_transfer_checks(uuid, uuid, date),
  private.refund_debit_links(uuid), private.transfer_debit_may_be_seen(uuid, date)
  from public, anon, authenticated, service_role;
revoke execute on function private.pending_item_deadlines(uuid, boolean),
  private.remittance_late_lines(public.remittance_run, date), private.remittance_statement_build(uuid)
  from public, anon, authenticated;
-- the worker (service role): the debit job (its M2b pass and its funds pass), the checks job, the remittance schedule
-- (as granted by 20261110120000, 20261111090000 and 20261112090000)
grant execute on function private.bank_booking_begin(), private.bank_booking_candidates(uuid, date, uuid, integer),
  private.apply_bank_bookings(uuid), private.debit_candidates(uuid, date, uuid, integer),
  private.run_payment_checks(uuid), private.pending_item_deadlines(uuid, boolean),
  private.remittance_statement_build(uuid)
  to service_role;
revoke execute on function public.generate_transfer_file(text, uuid, text), public.debit_queue(text, integer, integer),
  public.accounting_export_entries(date, date, text, integer), public.client_remittance_summary(uuid),
  public.debit_link_options(uuid) from public, anon;
grant execute on function public.generate_transfer_file(text, uuid, text), public.debit_queue(text, integer, integer),
  public.accounting_export_entries(date, date, text, integer), public.client_remittance_summary(uuid),
  public.debit_link_options(uuid) to authenticated;

-- The debits on statements imported before this migration: the debit job books them at its next run (one message per
-- servicer with one of our transfer lines not booked).
select pgmq.send('payments', jsonb_build_object('type', 'process_debits', 'organization_id', x.organization_id))
from (select distinct t.organization_id from public.bank_transaction t
      where (t.kind = 'transfer_out'
             or (t.direction = 'debit' and t.end_to_end_id is null
                 and t.payment_info_id ~ '^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$')
             or (t.direction = 'credit' and t.kind = 'return'
                 and coalesce(t.original_end_to_end_id, t.end_to_end_id) ~ '^(RMT|SWP)[0-9A-F]{12}$'))
        and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id)) x;
