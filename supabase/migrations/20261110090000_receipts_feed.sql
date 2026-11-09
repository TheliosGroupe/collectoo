-- M2b-5 (M2-10, M2-11): receipts (CPCE R124-6) and the client payment feed (R124-5).
-- Design: docs/design/m2b-payments.md §6 (receipt), §10 (receipts and creditor notifications), §12, §13 (M2-10, M2-11);
-- decisions: docs/adr/0013-payments-allocation-client-money.md (founder #13–#15, #17, #18; M2b-5 addendum).
-- Forward-only: nothing of 20261109190000 or earlier is edited; the index of the client feed replaces
-- client_notification_client_idx.
--
-- What it adds:
--   * `receipt`: one receipt number per payment linked to a file (« Une quittance est remise au débiteur pour tout
--     paiement », R124-6), versioned: a new version only when what the receipt says changes (allocation, reversal,
--     forward, another file, a return), a `void` version when the payment leaves its file; every version kept
--     (append-only). The payload is built here from the ledger (amounts as text, integer minor units); the worker only
--     formats and renders it (deterministic PDF) and stores it in the private bucket `documents`, SHA-256 recorded;
--   * the receipts job is queued by the ledger (every payment-tagged entry) and by the payment (a file assigned or
--     taken off, a gate stamped), 200 payments per message, and once by this migration for the payments matched
--     before it (backfill);
--   * `client_payment_feed`: what the client is told (client_notification: allocated, forwarded, reversed, held), the
--     amounts read from the entries' postings, the receipt of each payment; a client member reading it marks the rows
--     delivered (portal delivery);
--   * read access: receipts, their document row and their PDF by money staff and whoever reads the portfolio (clients
--     included, design §6; collectors their portfolios, founder #18);
--   * `receipt_job_pending`: whether the payment page should wait for a version (a receipts job naming it is queued);
--   * a daily sweep of receipt PDFs no document names (an attempt that failed after its uploads).
-- No remaining balance on the receipt until M3 computes interest (founder #14); the payer is named, by the party's own
-- name, only when he is certainly a party to the file, otherwise « versement d'un tiers » (founder #15, GDPR art.
-- 5(1)(c)); no legal mention the law does not require (OQ-22 open: the content is the design's conservative list).
-- Review fixes (before the first deploy, edited in place): the payer rule, a void version when a payment was moved
-- before its job ran, a total order of the allocation lines, the feed's receipt per row and readable, receipt
-- documents scoped like receipts, the pending state and the sweep.

------------------------------------------------------------------------------------------
-- The payer's name, compared with the file's parties (founder #15). The payer is named only when he is certainly a
-- party (review M2b-5 #0/#14/#17), and then by the party's own name, never by the bank's string: a third party's name
-- never enters the payload.
------------------------------------------------------------------------------------------

-- The tokens of a name as a bank or a tape writes it, in order: upper case, accents and ligatures written out, « & »
-- read as ET, split on anything but letters and digits (titles, joining words and initials kept).
create or replace function private.name_tokens(p_name text)
returns text[]
language sql
immutable
parallel safe
set search_path = ''
as $$
  select coalesce(array_agg(t.w order by t.n), '{}')
  from regexp_split_to_table(
         upper(translate(
           replace(replace(replace(replace(replace(replace(replace(coalesce(p_name, ''),
             '&', ' ET '), 'Œ', 'OE'), 'œ', 'oe'), 'Æ', 'AE'), 'æ', 'ae'), 'ß', 'ss'), 'ẞ', 'SS'),
           'ÀÁÂÃÄÅàáâãäåÇçÈÉÊËèéêëÌÍÎÏìíîïÑñÒÓÔÕÖØòóôõöøÙÚÛÜùúûüÝýÿŸ',
           'AAAAAAaaaaaaCcEEEEeeeeIIIIiiiiNnOOOOOOooooooUUUUuuuuYyyY')),
         '[^A-Z0-9]+') with ordinality t (w, n)
  where t.w <> '';
$$;

-- The words of a name (its tokens): titles, legal forms and joining words dropped (the matching rules' list,
-- payments.matching NAME_NOISE), initials dropped; a set, sorted.
create or replace function private.name_words(p_tokens text[])
returns text[]
language sql
immutable
parallel safe
set search_path = ''
as $$
  select coalesce(array_agg(distinct w order by w), '{}')
  from unnest(p_tokens) w
  where length(w) > 1
    and w <> all (array['MR', 'MME', 'MLLE', 'MM', 'MMES', 'MRS', 'MONSIEUR', 'MADAME', 'MADEMOISELLE',
                        'OU', 'ET', 'LES', 'CHEZ',
                        'SAS', 'SASU', 'SARL', 'EURL', 'SA', 'SCI', 'SNC', 'SCP', 'SELARL', 'SELAS', 'EI',
                        'EIRL', 'STE', 'SOCIETE', 'ETS', 'ETABLISSEMENTS', 'CIE', 'GROUPE',
                        'EPOUX', 'EPOUSE', 'VEUVE', 'VVE']);
$$;

create or replace function private.name_word_set(p_name text)
returns text[]
language sql
immutable
parallel safe
set search_path = ''
as $$
  select private.name_words(private.name_tokens(p_name));
$$;

-- Is the payer certainly this party? Only when the bank's name says nothing the party's own name does not:
--   * the same words (titles, legal forms, joining words and initials aside);
--   * no joint or marital word the party's name does not hold (OU, ET, EPOUX, EPOUSE, VEUVE, VVE, MM, MMES, LES, CHEZ:
--     a joint account, a household, someone else's widow), and at most one title (« M MME »: two people);
--   * no initial the party's name does not hold (« J DURAND »; letters spelling a legal form, « S.A.R.L. », are not
--     initials; M is a title);
--   * a company: no title the company's name does not hold (« MME DURAND » is a person, not « Durand SA »);
--   * a person: at least two words, first name and surname, compared with first and last name when the last name is
--     known (never a surname alone, never an initial-only name such as « J. Dupont »).
-- Called per party of each receipt's file: the word sets are compared first (most payers stop there).
create or replace function private.payer_is_party(p_payer text, p_kind text, p_display_name text, p_first_name text,
                                                  p_last_name text)
returns boolean
language plpgsql
immutable
parallel safe
set search_path = ''
as $$
declare
  v_titles constant text[] := array['M', 'MR', 'MME', 'MLLE', 'MRS', 'MONSIEUR', 'MADAME', 'MADEMOISELLE'];
  v_joint constant text[] := array['OU', 'ET', 'EPOUX', 'EPOUSE', 'VEUVE', 'VVE', 'MM', 'MMES', 'LES', 'CHEZ'];
  v_forms constant text[] := array['SAS', 'SASU', 'SARL', 'EURL', 'SA', 'SCI', 'SNC', 'SCP', 'SELARL', 'SELAS', 'EI',
                                   'EIRL'];
  v_pay text[] := private.name_tokens(p_payer);
  v_own text[];
  v_words text[];
  v_run text[] := '{}';
  v_titled integer := 0;
  t text;
  i text;
begin
  if cardinality(v_pay) = 0 then
    return false;
  end if;
  v_own := private.name_tokens(case when p_kind = 'natural_person' and p_last_name is not null
                                    then concat_ws(' ', p_first_name, p_last_name) else p_display_name end);
  v_words := private.name_words(v_own);
  if cardinality(v_words) < (case when p_kind = 'natural_person' then 2 else 1 end)
     or private.name_words(v_pay) <> v_words then
    return false;
  end if;
  -- the payer's tokens in order, a sentinel last
  foreach t in array v_pay || array[''] loop
    if t = any (v_titles) then
      v_titled := v_titled + 1;
      if v_titled > 1 or (p_kind <> 'natural_person' and t <> all (v_own)) then
        return false;    -- two people, or a person rather than the company
      end if;
    end if;
    if t = any (v_joint) and t <> all (v_own) then
      return false;      -- a joint account, a household, a widow…
    end if;
    if t ~ '^[A-Z]$' then
      v_run := v_run || t;
      continue;
    end if;
    -- the end of a run of single letters: a legal form spelt out (S.A.R.L.), or initials (M is a title)
    if cardinality(v_run) > 0 and array_to_string(v_run, '') <> all (v_forms) then
      foreach i in array v_run loop
        if i <> 'M' and i <> all (v_own) then
          return false;  -- an initial the party's name does not have
        end if;
      end loop;
    end if;
    v_run := '{}';
  end loop;
  return true;
end;
$$;

------------------------------------------------------------------------------------------
-- Receipts (design §6, §10): append-only versions; current = the highest version of the payment.
------------------------------------------------------------------------------------------

-- Receipt numbers Q-AAAA-NNNNNN: one counter per servicer and year of issue (not claimed gapless: a number drawn by a
-- job that then fails is drawn again by its retry).
create table private.receipt_counter (
  organization_id uuid not null references public.organization (id),
  year integer not null check (year between 2000 and 9999),
  last_number bigint not null check (last_number >= 0),
  primary key (organization_id, year)
);

create table public.receipt (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null,
  portfolio_id uuid not null,
  -- the file this version is about (a void version: the file it cancels)
  account_id uuid not null,
  payment_id uuid not null references public.payment (id),
  number text not null check (number ~ '^Q-[0-9]{4}-[0-9]{6,}$'),
  version integer not null check (version >= 1),
  kind text not null check (kind in ('original', 'update', 'void')),
  recipient_party_id uuid references public.party (id),   -- the file's debtor (R124-6: « remise au débiteur »)
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),
  payload_sha256 text not null check (payload_sha256 ~ '^[0-9a-f]{64}$'),
  template_version text not null check (template_version ~ '^[a-z0-9.+/_-]{1,80}$'),
  renderer_version text not null check (renderer_version ~ '^[a-z0-9.+/_-]{1,80}$'),
  known_at timestamptz not null,       -- the ledger as read at this time (the job's start)
  document_id uuid not null unique references public.document (id),
  pdf_sha256 text not null check (pdf_sha256 ~ '^[0-9a-f]{64}$'),
  issued_at timestamptz not null default now(),
  constraint receipt_account_fk foreign key (account_id, organization_id, client_organization_id, portfolio_id)
    references public.account (id, organization_id, client_organization_id, portfolio_id),
  constraint receipt_version_uq unique (payment_id, version),
  constraint receipt_number_uq unique (organization_id, number, version),
  constraint receipt_kind check ((version = 1) = (kind = 'original')),
  constraint receipt_void check ((kind = 'void') = (payload ->> 'state' = 'void'))
);
create index receipt_portfolio_idx on public.receipt (portfolio_id);
create index receipt_client_idx on public.receipt (client_organization_id);
comment on table public.receipt is
  'R124-6 quittance per payment linked to a file: versions (append-only), payload from the ledger, PDF stored with SHA-256.';

-- Each new version follows the previous one of its payment (same number, no gap), says what its payment and file are,
-- and its document is its PDF (set-based over the new rows; keyed lookups whatever the statistics).
create or replace function private.receipt_guard()
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
  left join public.payment p on p.id = n.payment_id
  left join public.receipt prev on prev.payment_id = n.payment_id and prev.version = n.version - 1
  left join public.document d on d.id = n.document_id
  where p.organization_id is distinct from n.organization_id
     or (n.version > 1 and (prev.id is null or prev.number <> n.number))
     or (n.kind <> 'void' and p.account_id is distinct from n.account_id)
     or (n.kind = 'void' and prev.account_id is distinct from n.account_id)
     -- a version in force about another file is voided first (review #7): the first file's client keeps a void one
     or (n.kind = 'update' and prev.kind <> 'void' and prev.account_id is distinct from n.account_id)
     or d.organization_id is distinct from n.organization_id
     or d.client_organization_id is distinct from n.client_organization_id
     or d.account_id is distinct from n.account_id
     or d.kind is distinct from 'receipt' or d.sha256 is distinct from n.pdf_sha256
     or d.mime_type is distinct from 'application/pdf'
     or n.payload_sha256 <> encode(sha256(convert_to(n.payload::text, 'UTF8')), 'hex');
  if v_bad is not null then
    raise exception 'receipt %: it does not follow its payment''s receipts, file or document', v_bad
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;
create trigger receipt_guard after insert on public.receipt
  referencing new table as new_rows for each statement execute function private.receipt_guard();
alter table public.receipt enable always trigger receipt_guard;
create trigger receipt_append_only before update or delete or truncate on public.receipt
  for each statement execute function private.refuse_change();
alter table public.receipt enable always trigger receipt_append_only;

------------------------------------------------------------------------------------------
-- The payload (design §10), from the ledger and the payment's bank facts. Amounts are text (integer minor units);
-- nothing is computed by the worker beyond formatting. No remaining balance (founder #14), no review reason (a hold
-- reads « non imputé », neutral words), the first-letter reference empty until M4 (R124-4).
------------------------------------------------------------------------------------------

-- The receipt of a payment on its file: its recipient (the file's borrower: lowest name, then id) and its payload.
-- Keyed lookups whatever the statistics (hash and merge joins off): on a fresh database the totals scanned every
-- posting, ~3 ms a receipt.
create or replace function private.receipt_payload(p_payment_id uuid)
returns table (recipient_party_id uuid, payload jsonb)
language sql
stable
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
as $$
  select d.party_id,
         jsonb_build_object(
           'schema', 1,
           'state', 'issued',
           'issuer', jsonb_build_object('name', s.legal_name),
           'creditor', jsonb_build_object('name', c.legal_name),
           'file', jsonb_build_object('reference', a.external_ref),
           'debtor', jsonb_build_object('name', d.name),
           -- founder #15: named only if the payer is certainly a party to the file, by the party's own name
           'payer', jsonb_build_object('name', pp.name, 'third_party', pp.name is null),
           'payment', jsonb_build_object('amount_minor', p.amount_minor::text, 'currency', p.currency,
                                         'exponent', cur.minor_exponent, 'method', p.method,
                                         'booking_date', p.booking_date, 'value_date', p.value_date,
                                         'reference', p.end_to_end_id),
           'allocation', coalesce(l.lines, '[]'),
           'totals', jsonb_build_object(
             'allocated_minor', t.allocated::text,
             'forwarded_minor', t.forwarded::text,
             'returned_minor', t.returned::text,
             'unallocated_minor', (p.amount_minor - t.allocated - t.forwarded - t.returned)::text),
           'first_letter', null)
  from public.payment p
  join public.account a on a.id = p.account_id
  join public.organization s on s.id = p.organization_id
  join public.organization c on c.id = a.client_organization_id
  join public.currency cur on cur.code = p.currency
  cross join lateral (
    select (array_agg(ap.party_id order by pa.display_name, pa.id))[1] as party_id,
           (array_agg(pa.display_name order by pa.display_name, pa.id))[1] as name
    from public.account_party ap join public.party pa on pa.id = ap.party_id
    where ap.account_id = a.id and ap.role = 'borrower') d
  cross join lateral (
    select (array_agg(pa.display_name order by pa.display_name, pa.id)
              filter (where private.payer_is_party(p.payer_name, pa.kind, pa.display_name, pa.first_name,
                                                   pa.last_name)))[1] as name
    from public.account_party ap
    join public.party pa on pa.id = ap.party_id
    where ap.account_id = a.id and p.payer_name is not null) pp
  -- what the payment's entries moved out of 4710 (net of reversals): allocated, forwarded, returned (M2b-6)
  cross join lateral (
    select coalesce(sum(lp.amount_minor) filter (where x.k = 'allocation'), 0)::bigint as allocated,
           coalesce(sum(lp.amount_minor) filter (where x.k = 'forward'), 0)::bigint as forwarded,
           coalesce(sum(lp.amount_minor) filter (where x.k = 'cash_out'), 0)::bigint as returned
    from (select e.id, coalesce(r.entry_type, e.entry_type) as k from public.ledger_entry e
          left join public.ledger_entry r on r.id = e.reverses_entry_id
          where e.payment_id = p.id) x
    join public.ledger_posting lp on lp.entry_id = x.id
    join public.ledger_account la on la.id = lp.ledger_account_id and la.book = 'unallocated_payment') t
  -- the allocation per item and component, from the postings of the live allocation entries (net of reversals); the
  -- payment's own file first, in a total order (review #3: tied lines would change the hash with the plan). The
  -- component is a code: the locked template words it for the debtor (review #2), never the ledger's staff label.
  left join lateral (
    select jsonb_agg(jsonb_build_object('file_reference', fa.external_ref, 'item_ref', i.ref, 'item_kind', i.kind,
                                        'due_date', i.due_date, 'component', x.component,
                                        'amount_minor', x.amount::text)
                     order by (fa.id <> a.id), fa.external_ref, fa.id, i.due_date nulls last, i.ref, i.kind, i.id,
                              lc.sort_order) as lines
    from (select la.claim_item_id, la.component, -sum(lp.amount_minor) as amount
          from public.ledger_entry e
          left join public.ledger_entry r on r.id = e.reverses_entry_id
          join public.ledger_posting lp on lp.entry_id = e.id
          join public.ledger_account la on la.id = lp.ledger_account_id and la.book = 'debtor_receivable'
          where e.payment_id = p.id and coalesce(r.entry_type, e.entry_type) = 'allocation'
          group by la.claim_item_id, la.component
          having sum(lp.amount_minor) <> 0) x
    join public.claim_item i on i.id = x.claim_item_id
    join public.account fa on fa.id = i.account_id
    join public.ledger_component lc on lc.code = x.component) l on true
  where p.id = p_payment_id;
$$;

-- A void version keeps who issued it, for whom, the file, the debtor and the payment; nothing more. Applied to a void
-- payload it gives the same payload (the job is idempotent).
create or replace function private.receipt_void_payload(p_current jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object('schema', 1, 'state', 'void', 'issuer', p_current -> 'issuer',
                            'creditor', p_current -> 'creditor', 'file', p_current -> 'file',
                            'debtor', p_current -> 'debtor', 'payment', p_current -> 'payment',
                            'first_letter', p_current -> 'first_letter');
$$;

------------------------------------------------------------------------------------------
-- The receipts job (worker collectoo_worker.jobs.receipts), in its transaction, under the servicer's receipts lock:
--   receipt_begin() → receipt_prepare(org, ids) → the worker renders each PDF and uploads it → COPY into
--   pg_temp._receipt_pdf → receipt_issue(template, renderer).
------------------------------------------------------------------------------------------

-- Working tables of the caller (the worker COPYs into _receipt_pdf).
create or replace function private.receipt_begin()
returns void
language plpgsql
set search_path = ''
as $$
begin
  drop table if exists pg_temp._receipt_new;
  drop table if exists pg_temp._receipt_pdf;
  create temp table _receipt_new (
    payment_id uuid primary key,
    organization_id uuid not null,
    client_organization_id uuid not null,
    portfolio_id uuid not null,
    account_id uuid not null,
    recipient_party_id uuid,
    number text,
    version integer not null,
    kind text not null,
    payload jsonb not null,
    payload_sha256 text not null,
    known_at timestamptz not null,
    storage_path text,
    ord bigint not null
  ) on commit drop;
  create temp table _receipt_pdf (
    payment_id uuid primary key,
    pdf_sha256 text not null check (pdf_sha256 ~ '^[0-9a-f]{64}$')
  ) on commit drop;
end;
$$;

-- The receipts to issue for these payments of the servicer: a version whenever the payload differs from the current
-- version's (same payload: nothing, the job is idempotent). A payment on its file gets its receipt unless it is ready
-- for allocation (the allocation follows and queues the job again); a payment whose current version is about another
-- file than its own now (it left its file, was moved to another before this job ran, or came back from the bank,
-- M2b-6) gets a void version first. Numbers are drawn for first versions, in processing order (booking date,
-- payment). Returns what the worker renders.
create or replace function private.receipt_prepare(p_organization_id uuid, p_payment_ids uuid[])
returns table (payment_id uuid, number text, version integer, kind text, known_at timestamptz, storage_path text,
               payload jsonb)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_year integer := extract(year from (now() at time zone 'Europe/Paris'))::integer;
  v_new bigint;
  v_last bigint;
begin
  if p_organization_id is null then
    raise exception 'receipts: servicer required' using errcode = '22023';
  end if;
  insert into pg_temp._receipt_new (payment_id, organization_id, client_organization_id, portfolio_id, account_id,
                                    recipient_party_id, number, version, kind, payload, payload_sha256, known_at, ord)
  select y.payment_id, p_organization_id, y.client, y.portfolio, y.account, y.recipient, y.cur_number,
         coalesce(y.cur_version, 0) + 1,
         case when y.cur_version is null then 'original' when y.state = 'void' then 'void' else 'update' end,
         y.payload, y.sha, now(), row_number() over (order by y.booking_date, y.payment_id)
  from (select x.*, encode(sha256(convert_to(x.payload::text, 'UTF8')), 'hex') as sha
        from (select p.id as payment_id, p.booking_date, s.state, cur.version as cur_version, cur.number as cur_number,
                     cur.payload_sha256 as cur_sha,
                     case when s.state = 'issued' then a.client_organization_id else cur.client_organization_id end
                       as client,
                     case when s.state = 'issued' then a.portfolio_id else cur.portfolio_id end as portfolio,
                     case when s.state = 'issued' then a.id else cur.account_id end as account,
                     case when s.state = 'issued' then b.recipient_party_id else cur.recipient_party_id end as recipient,
                     case when s.state = 'issued' then b.payload else private.receipt_void_payload(cur.payload) end
                       as payload
              from (select distinct u.id from unnest(p_payment_ids) u (id)) ids
              join public.payment p on p.id = ids.id and p.organization_id = p_organization_id
              left join public.account a on a.id = p.account_id
              left join lateral (select r.version, r.number, r.kind, r.payload, r.payload_sha256, r.account_id,
                                        r.client_organization_id, r.portfolio_id, r.recipient_party_id
                                 from public.receipt r where r.payment_id = p.id
                                 order by r.version desc limit 1) cur on true
              cross join lateral (
                select case
                  -- a version in force about another file than the payment's: void it first, whatever the payment's
                  -- state now (it left its file, came back from the bank, or was moved to another file before this
                  -- job ran: review #1)
                  when cur.kind is not null and cur.kind <> 'void'
                       and (p.account_id is null or p.status = 'returned' or cur.account_id is distinct from p.account_id)
                    then 'void'
                  when p.account_id is not null and p.status <> 'returned'
                       and not (p.status in ('matched', 'partially_allocated') and p.review_reason is null)
                    then 'issued'
                end as state) s
              left join lateral private.receipt_payload(p.id) b on s.state = 'issued'
              where s.state is not null) x) y
  where y.sha is distinct from y.cur_sha;

  -- A payment voided on a file it left while it is already on another: queued again, so the next run issues its new
  -- file's version (one version per payment and run). Ready for allocation there, the next run skips it and its
  -- allocation queues it.
  perform private.queue_receipts(coalesce(jsonb_agg(jsonb_build_object('organization_id', p_organization_id,
                                                                       'payment_id', r.payment_id)), '[]'))
  from pg_temp._receipt_new r
  join public.payment p on p.id = r.payment_id
  where r.kind = 'void' and p.account_id is not null and p.status <> 'returned';

  select count(*) into v_new from pg_temp._receipt_new r where r.number is null;
  if v_new > 0 then
    insert into private.receipt_counter (organization_id, year, last_number) values (p_organization_id, v_year, 0)
    on conflict on constraint receipt_counter_pkey do nothing;
    update private.receipt_counter c set last_number = c.last_number + v_new
    where c.organization_id = p_organization_id and c.year = v_year
    returning c.last_number - v_new into v_last;
    update pg_temp._receipt_new r
    set number = 'Q-' || v_year || '-' || lpad((v_last + z.n)::text, greatest(6, length((v_last + z.n)::text)), '0')
    from (select q.payment_id, row_number() over (order by q.ord) as n from pg_temp._receipt_new q
          where q.number is null) z
    where r.payment_id = z.payment_id;
  end if;
  update pg_temp._receipt_new r
  set storage_path = 'receipts/' || r.organization_id || '/' || substr(r.number, 3, 4) || '/' || r.number || '-v'
                     || r.version || '.pdf';
  return query
  select r.payment_id, r.number, r.version, r.kind, r.known_at, r.storage_path, r.payload
  from pg_temp._receipt_new r order by r.ord;
end;
$$;

-- Records the rendered receipts: one document (private bucket `documents`, SHA-256) and one receipt row each. Every
-- prepared receipt was rendered, nothing else. Returns how many were issued.
create or replace function private.receipt_issue(p_template_version text, p_renderer_version text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bad text;
  v_n integer;
begin
  select min(coalesce(r.payment_id, f.payment_id)::text) into v_bad
  from pg_temp._receipt_new r full join pg_temp._receipt_pdf f on f.payment_id = r.payment_id
  where r.payment_id is null or f.payment_id is null;
  if v_bad is not null then
    raise exception 'receipt of payment %: prepared and rendered receipts differ', v_bad using errcode = 'check_violation';
  end if;
  drop table if exists pg_temp._receipt_doc;
  create temp table _receipt_doc on commit drop as
  select r.payment_id, gen_random_uuid() as document_id from pg_temp._receipt_new r;
  insert into public.document (id, organization_id, client_organization_id, account_id, party_id, kind, storage_bucket,
                               storage_path, sha256, mime_type, file_name)
  select d.document_id, r.organization_id, r.client_organization_id, r.account_id, r.recipient_party_id, 'receipt',
         'documents', r.storage_path, f.pdf_sha256, 'application/pdf', r.number || '-v' || r.version || '.pdf'
  from pg_temp._receipt_new r
  join pg_temp._receipt_pdf f on f.payment_id = r.payment_id
  join pg_temp._receipt_doc d on d.payment_id = r.payment_id
  order by r.ord;
  insert into public.receipt (organization_id, client_organization_id, portfolio_id, account_id, payment_id, number,
                              version, kind, recipient_party_id, payload, payload_sha256, template_version,
                              renderer_version, known_at, document_id, pdf_sha256)
  select r.organization_id, r.client_organization_id, r.portfolio_id, r.account_id, r.payment_id, r.number, r.version,
         r.kind, r.recipient_party_id, r.payload, r.payload_sha256, p_template_version, p_renderer_version, r.known_at,
         d.document_id, f.pdf_sha256
  from pg_temp._receipt_new r
  join pg_temp._receipt_pdf f on f.payment_id = r.payment_id
  join pg_temp._receipt_doc d on d.payment_id = r.payment_id
  order by r.ord;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

------------------------------------------------------------------------------------------
-- What queues the receipts job (design §10: « runs after any change to an identified payment's position »), 200
-- payments per message (design §9), one firing per statement:
--   * every entry tagged with a payment (allocation, forward, reversal; cash_out in M2b-6);
--   * a payment given a file or taken off one, or stamped with another gate on the same status (held, nothing due…),
--     unless it is now ready for allocation (the allocation's entries queue it).
------------------------------------------------------------------------------------------

create or replace function private.queue_receipts(p_rows jsonb)
returns integer
language sql
security definer
set search_path = ''
as $$
  with sent as (
    select pgmq.send('payments', jsonb_build_object('type', 'receipts', 'organization_id', x.organization_id,
                                                    'payment_ids', x.ids)) as msg_id
    from (select y.organization_id, jsonb_agg(y.payment_id order by y.payment_id) as ids
          from (select d.organization_id, d.payment_id,
                       (row_number() over (partition by d.organization_id order by d.payment_id) - 1) / 200 as chunk
                from (select distinct (e ->> 'organization_id')::uuid as organization_id,
                                      (e ->> 'payment_id')::uuid as payment_id
                      from jsonb_array_elements(p_rows) e) d) y
          group by y.organization_id, y.chunk) x)
  select count(*)::integer from sent;
$$;

create or replace function private.receipts_after_entry()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.queue_receipts(coalesce(jsonb_agg(jsonb_build_object('organization_id', n.organization_id,
                                                                       'payment_id', n.payment_id)), '[]'))
  from new_rows n where n.payment_id is not null;
  return null;
end;
$$;
create trigger ledger_entry_receipts after insert on public.ledger_entry
  referencing new table as new_rows for each statement execute function private.receipts_after_entry();
alter table public.ledger_entry enable always trigger ledger_entry_receipts;

-- The two transition tables are joined: plpgsql caches the plan made for the session's first update (often a
-- handful of rows), and a nested loop reused for a 50k-row update compares every pair (minutes). Hash joins only.
create or replace function private.receipts_after_payment()
returns trigger
language plpgsql
security definer
set search_path = ''
set enable_nestloop = off
as $$
begin
  perform private.queue_receipts(coalesce(jsonb_agg(jsonb_build_object('organization_id', n.organization_id,
                                                                       'payment_id', n.id)), '[]'))
  from new_rows n join old_rows o on o.id = n.id
  where (n.account_id is not null or o.account_id is not null)
    and (n.account_id is distinct from o.account_id
         or (n.status = o.status and n.review_reason is distinct from o.review_reason))
    and not (n.status in ('matched', 'partially_allocated') and n.review_reason is null and n.account_id is not null);
  return null;
end;
$$;
-- Same trap in M2b-4's trigger (already applied): its joins of old and new rows get hash joins too.
alter function private.payment_after_update() set enable_nestloop = off;

create trigger payment_receipts after update on public.payment
  referencing old table as old_rows new table as new_rows
  for each statement execute function private.receipts_after_payment();
alter table public.payment enable always trigger payment_receipts;

-- Payments already on a file without a receipt (backfill: M2b-4 allocations are live), of every servicer or of one:
-- one job per 200 payments. Returns the number of jobs queued.
create or replace function private.queue_receipt_backfill(p_organization_id uuid default null)
returns integer
language sql
security definer
set search_path = ''
as $$
  select private.queue_receipts(coalesce(jsonb_agg(jsonb_build_object('organization_id', p.organization_id,
                                                                      'payment_id', p.id)), '[]'))
  from public.payment p
  where (p_organization_id is null or p.organization_id = p_organization_id)
    and p.account_id is not null
    and not (p.status in ('matched', 'partially_allocated') and p.review_reason is null)
    and not exists (select 1 from public.receipt r where r.payment_id = p.id);
$$;

------------------------------------------------------------------------------------------
-- The client payment feed (design §9, §10; R124-5, founder #17, #18): newest first, 50 per page (at most 200), the
-- cursor of the last row read (`after`). Amounts from the entry's 4670 postings (allocation, forward, reversal) or,
-- for a held payment, its amount; the items an allocation (or its reversal) credited; the payment's receipt as the
-- client last had it. Read by the client's members (their portfolios) and the servicer's admins and ops managers.
-- A client member reading rows marks them delivered (once; portal delivery, M2b-4's delivered_at). Each row links the
-- receipt of its own file, one the reader can read (review #8, #13).
------------------------------------------------------------------------------------------

drop index if exists public.client_notification_client_idx;
create index client_notification_feed_idx on public.client_notification (client_organization_id, created_at desc, id desc);

create or replace function public.client_payment_feed(p_client uuid, p_after text default null,
                                                      p_limit integer default 50)
returns table (notification_id uuid, cursor text, created_at timestamptz, kind text, reason text, account_id uuid,
               file_reference text, debtor_name text, amount_minor text, currency char(3), booking_date date,
               effective_date date, lines jsonb, receipt_id uuid, receipt_number text, receipt_version integer,
               receipt_kind text, delivered_at timestamptz, first_view boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_member boolean := p_client = any (private.client_org_ids());
  v_staff boolean := false;
  v_readable uuid[] := '{}';
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_at timestamptz;
  v_id uuid;
begin
  select coalesce(o.servicer_organization_id = any (private.money_staff_org_ids()), false) into v_staff
  from public.organization o where o.id = p_client;
  if not (v_member or coalesce(v_staff, false)) then
    raise exception 'client payment feed: not allowed' using errcode = '42501';
  end if;
  if v_member then
    v_readable := private.readable_portfolio_ids();
  end if;
  if p_after is not null then
    begin
      v_at := split_part(p_after, '|', 1)::timestamptz;
      v_id := split_part(p_after, '|', 2)::uuid;
    exception when others then
      raise exception 'client payment feed: unreadable cursor' using errcode = '22023';
    end;
  end if;
  return query
  with page as (
    select n.id, n.created_at, n.kind, n.reason, n.account_id, n.payment_id, n.ledger_entry_id, n.delivered_at
    from public.client_notification n
    where n.client_organization_id = p_client
      and (coalesce(v_staff, false) or n.portfolio_id is null or n.portfolio_id = any (v_readable))
      and (p_after is null or (n.created_at, n.id) < (v_at, v_id))
    order by n.created_at desc, n.id desc
    limit v_limit
  ), marked as (
    update public.client_notification c set delivered_at = now()
    from page
    where c.id = page.id and v_member and c.delivered_at is null
    returning c.id, c.delivered_at
  )
  select page.id,
         to_char(page.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') || '|' || page.id,
         page.created_at, page.kind, page.reason, page.account_id, a.external_ref,
         (select min(pa.display_name) from public.account_party ap join public.party pa on pa.id = ap.party_id
          where ap.account_id = page.account_id and ap.role = 'borrower'),
         coalesce(e.amount, p.amount_minor)::text, p.currency, p.booking_date, le.effective_date,
         coalesce(l.lines, '[]'::jsonb), r.id, r.number, r.version, r.kind,
         coalesce(m.delivered_at, page.delivered_at), m.id is not null
  from page
  left join marked m on m.id = page.id
  join public.payment p on p.id = page.payment_id
  left join public.account a on a.id = page.account_id
  left join public.ledger_entry le on le.id = page.ledger_entry_id
  left join lateral (select abs(sum(lp.amount_minor))::bigint as amount
                     from public.ledger_posting lp
                     join public.ledger_account la on la.id = lp.ledger_account_id and la.book = 'client_payable'
                     where lp.entry_id = page.ledger_entry_id) e on page.ledger_entry_id is not null
  left join lateral (select jsonb_agg(jsonb_build_object('item_ref', i.ref, 'item_kind', i.kind,
                                                         'due_date', i.due_date, 'component', la.component,
                                                         'amount_minor', abs(lp.amount_minor)::text)
                                      order by lp.line_no) as lines
                     from public.ledger_posting lp
                     join public.ledger_account la on la.id = lp.ledger_account_id and la.book = 'debtor_receivable'
                     join public.claim_item i on i.id = la.claim_item_id
                     where lp.entry_id = page.ledger_entry_id) l on page.ledger_entry_id is not null
  -- the receipt of the row's own file as this client last had it (another file's of the payment only when the row's
  -- file has none: an overpayment used on another file of the debtor), never one the reader cannot read (review #8,
  -- #13); one table, keyed by payment
  left join lateral (select x.id, x.number, x.version, x.kind from public.receipt x
                     where x.payment_id = page.payment_id and x.client_organization_id = p_client
                       and (coalesce(v_staff, false) or x.portfolio_id = any (v_readable))
                     order by (x.account_id is not distinct from page.account_id) desc, x.version desc
                     limit 1) r on true
  order by page.created_at desc, page.id desc;
end;
$$;

------------------------------------------------------------------------------------------
-- Read access (design §6; founder #18): receipts by money staff and whoever reads the portfolio (clients included,
-- collectors their portfolios); their PDF likewise (storage policy on the private bucket). No write policy.
------------------------------------------------------------------------------------------

alter table public.receipt enable row level security;
alter table private.receipt_counter enable row level security;
revoke all on public.receipt from public, anon, authenticated;
revoke all on private.receipt_counter from public, anon, authenticated;
grant select on public.receipt to authenticated;

create policy receipt_read on public.receipt for select to authenticated using (
  organization_id = any ((select private.money_staff_org_ids())::uuid[])
  or portfolio_id = any ((select private.readable_portfolio_ids())::uuid[]));

-- The PDF of a receipt the caller may read (keyed: document by bucket and path, receipt by document).
create or replace function private.can_read_receipt_object(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.document d join public.receipt r on r.document_id = d.id
    where d.storage_bucket = 'documents' and d.storage_path = p_name
      and (r.organization_id = any (private.money_staff_org_ids())
           or r.portfolio_id = any (private.readable_portfolio_ids())));
$$;
create policy receipt_object_read on storage.objects for select to authenticated
  using (bucket_id = 'documents' and name like 'receipts/%' and private.can_read_receipt_object(name));

-- A receipt's document row is read like its receipt (review #13): document_read lets every member of the client and
-- every staff member read the client's documents, a receipt is scoped by portfolio (founder #18). The subquery runs
-- under receipt_read, keyed by the unique document_id.
create policy document_receipt_scope on public.document as restrictive for select to authenticated
  using (kind <> 'receipt' or exists (select 1 from public.receipt r where r.document_id = document.id));

------------------------------------------------------------------------------------------
-- The payment page waits for a receipt version only while a receipts job naming the payment is queued, running or
-- waiting for a retry (review #18: a job that issues nothing, the payload unchanged, ends the wait). Money staff of the
-- payment's servicer only (null otherwise: the payment page is theirs).
------------------------------------------------------------------------------------------

create or replace function public.receipt_job_pending(p_payment_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from pgmq.q_payments q
                 where q.message ->> 'type' = 'receipts' and q.message -> 'payment_ids' ? p.id::text)
  from public.payment p
  where p.id = p_payment_id and p.organization_id = any (private.money_staff_org_ids());
$$;

------------------------------------------------------------------------------------------
-- Receipt PDFs that no document names (review #11): an attempt that failed after its uploads removes them itself, but
-- a killed worker or a failed removal leaves them. A daily job (`receipts_sweep`, one per servicer, pg_cron) lists
-- those of one servicer whose object is older than the given age, under the servicer's receipts lock (no job of the
-- servicer is uploading meanwhile), and the worker deletes them through Storage.
------------------------------------------------------------------------------------------

create or replace function private.receipt_orphan_objects(p_organization_id uuid, p_older_than interval,
                                                          p_limit integer)
returns setof text
language sql
stable
security definer
set search_path = ''
as $$
  select o.name
  from storage.objects o
  where o.bucket_id = 'documents' and o.name like 'receipts/' || p_organization_id::text || '/%'
    and greatest(o.created_at, o.updated_at) < now() - p_older_than
    and not exists (select 1 from public.document d where d.storage_bucket = 'documents' and d.storage_path = o.name)
  order by o.name
  limit greatest(coalesce(p_limit, 1000), 1);
$$;

create or replace function private.queue_receipt_sweep()
returns integer
language sql
security definer
set search_path = ''
as $$
  with sent as (
    select pgmq.send('payments', jsonb_build_object('type', 'receipts_sweep', 'organization_id', o.id)) as msg_id
    from public.organization o
    where o.kind = 'servicer')
  select count(*)::integer from sent;
$$;

select cron.schedule('receipts-sweep', '23 2 * * *', 'select private.queue_receipt_sweep()');

------------------------------------------------------------------------------------------
-- Privileges
------------------------------------------------------------------------------------------

revoke execute on function private.name_tokens(text), private.name_words(text[]), private.name_word_set(text),
  private.payer_is_party(text, text, text, text, text), private.receipt_guard(), private.receipt_payload(uuid),
  private.receipt_void_payload(jsonb), private.receipt_begin(), private.receipt_prepare(uuid, uuid[]),
  private.receipt_issue(text, text), private.queue_receipts(jsonb), private.receipts_after_entry(),
  private.receipts_after_payment(), private.queue_receipt_backfill(uuid), private.can_read_receipt_object(text),
  private.receipt_orphan_objects(uuid, interval, integer), private.queue_receipt_sweep()
  from public, anon, authenticated, service_role;
-- The worker (service_role) runs the receipts job and the sweep.
grant execute on function private.receipt_begin(), private.receipt_prepare(uuid, uuid[]),
  private.receipt_issue(text, text), private.receipt_orphan_objects(uuid, interval, integer) to service_role;
-- The storage policy runs as the reader.
grant execute on function private.can_read_receipt_object(text) to authenticated;
revoke execute on function public.client_payment_feed(uuid, text, integer) from public, anon;
grant execute on function public.client_payment_feed(uuid, text, integer) to authenticated;
revoke execute on function public.receipt_job_pending(uuid) from public, anon;
grant execute on function public.receipt_job_pending(uuid) to authenticated;

------------------------------------------------------------------------------------------
-- Backfill: payments matched before this migration (M2b-4 allocations, held payments) get their receipts.
------------------------------------------------------------------------------------------

select private.queue_receipt_backfill();
