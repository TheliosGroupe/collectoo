# Run Collectoo on your own machine

You need about 30 minutes the first time, most of it downloads. Everything runs locally on
synthetic data, with no real keys: the AI, e-mail and SMS providers are mocks.

## 1. Install the tools (once)

| Tool | Version | How |
|---|---|---|
| Docker | Docker Desktop (Mac, Windows) or Docker Engine (Linux), running | docker.com |
| Supabase CLI | 2.122.1 | Mac: `brew install supabase/tap/supabase`. Linux/WSL: the `.deb` or `.tar.gz` from github.com/supabase/cli/releases (tag v2.122.1) |
| Node.js | 22 | `nvm install 22`, or nodejs.org |
| uv (Python) | latest | `curl -LsSf https://astral.sh/uv/install.sh \| sh` (uv fetches Python 3.12 itself) |
| git, make | any | Mac: `xcode-select --install`. Ubuntu: `sudo apt install git make` |

**Windows:** install WSL2 with Ubuntu, then Docker Desktop with WSL integration turned on.
Run every command below in the Ubuntu terminal. Clone into your Linux home (`~`), not into
`/mnt/c/...`, which is very slow.

Give Docker at least 4 GB of memory (Docker Desktop → Settings → Resources).

## 2. Get the code and start the stack

```bash
git clone https://github.com/TheliosGroupe/collectoo.git
cd collectoo
git checkout main
make setup      # Python and web dependencies
make up         # local Supabase in Docker (the first run downloads a few GB of images)
make reset      # applies every migration and loads the synthetic seed
```

If the repository is private, `git clone` asks you to sign in: use `gh auth login` (GitHub CLI) or
an SSH key.

Write the web app's settings file. These are local stack values, not secrets:

```bash
eval "$(./scripts/local-env.sh)"
printf 'NEXT_PUBLIC_SUPABASE_URL=%s\nNEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=%s\n' \
  "$NEXT_PUBLIC_SUPABASE_URL" "$NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY" > apps/web/.env.local
```

## 3. Run it (two terminals)

```bash
# Terminal 1: the worker (file boarding, statement import, matching, background jobs)
make worker

# Terminal 2: the web app
cd apps/web && npm run dev
```

Open **http://127.0.0.1:3000**.

## 4. Log in

1. Type one of the e-mails below and ask for a code.
2. Open **Mailpit at http://127.0.0.1:54324** (the local mailbox) and read the 6-digit code.
3. **Staff accounts** (`@collectoo.test`) must set up two-factor login the first time: scan the
   QR code with an authenticator app (Google Authenticator, Microsoft Authenticator, 1Password…),
   then type its 6-digit code. Client accounts don't need it.

| E-mail | Who | Lands on |
|---|---|---|
| `admin@collectoo.test` | servicer admin | back office |
| `ops@collectoo.test` | servicer operations | back office |
| `collecteur@collectoo.test` | collector | back office |
| `admin@martin.test` | client admin (Martin) | client space |
| `lecture@martin.test` | client, read only | client space |
| `admin@lilas.test` | client admin (Lilas) | client space |

`make reset` wipes everything, two-factor set-ups included: you scan a new QR code afterwards.

## 5. Things to try

**Browse the seeded book** (`ops@collectoo.test`): Clients, then a portfolio's files (« dossiers »):
claims, payments, credit notes.

**Board a file** (« Reprises »):

```bash
make synth      # writes sample tapes to tmp/synth/eba (EU template) and tmp/synth/civil
```

Back office → Reprises → Nouveau, upload a file from `tmp/synth/`. The civil files come with a
manifest listing the defects planted in them, so you can check the review screen catches them.
The column mapping uses the mock AI.

**Import a bank statement** (« Encaissements »):

1. Paramètres → Comptes bancaires: add a bank account and note its IBAN.
2. Take 100 payment references from the seeded files, then generate a camt.053 statement that
   pays them:

   ```bash
   mkdir -p tmp/synth/bank
   docker exec supabase_db_collectoo psql -U postgres -Atc \
     "select rf from public.payment_reference where status = 'active' limit 100" > tmp/synth/bank/rf.txt
   cd worker && uv run synth camt053 --lines 200 --seed 1 --iban <YOUR_IBAN> \
     --references ../tmp/synth/bank/rf.txt --out ../tmp/synth/bank && cd ..
   ```

3. Encaissements: import the file from `tmp/synth/bank/`. Watch the matching, the « À traiter »
   queue (the lines it could not match), the allocations and receipts on a file, and the checks
   page.

**Client side** (`admin@martin.test`): the portfolio, the payments feed, the mandate.

**Remittances** (back office → a client → Reversement): billing identity, payout account (needs a
second person to approve) and mandate money terms. Remittance runs and invoices come in M2c-4.

## 6. Tests (optional)

```bash
make lint       # ruff, mypy, eslint, tsc
make test       # pytest, vitest, pgTAP
make e2e        # Playwright, desktop + mobile (stop `npm run dev` first; it builds the app)
```

## 7. Stop and troubleshoot

`make down` stops the stack and drops its data; `make up && make reset` brings it back.

| Symptom | Fix |
|---|---|
| `port ... already in use` | something else uses 54321–54324 or 3000: stop it, or `supabase stop --project-id <other>` |
| `make up` hangs on images | Docker isn't running, or has too little memory |
| No code in Mailpit | check the e-mail is one of the seeded ones; a code is valid for one hour |
| Upload stays « en attente » | the worker (terminal 1) isn't running |
| Login loops back to /connexion | `apps/web/.env.local` is missing or has an old key: redo step 2's `printf` and restart `npm run dev` |
