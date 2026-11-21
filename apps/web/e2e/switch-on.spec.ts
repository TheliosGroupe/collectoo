import { devices, expect, test, type Page } from "@playwright/test";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import {
  adminClient,
  createConfirmedPayoutAccount,
  createMandate,
  createMember,
  createTenant,
  type Tenant,
} from "./support/admin";
import { camt053, camt053Lines, ibanFr, type Credit } from "./support/camt";
import { loginAsStaff } from "./support/session";

/**
 * M2c-6b-3a-2 (plan m2c-6b-3 §3.7; ADR-0014 « M2c-6b-3a-2 »): the cancellation of a downloaded file with the switch
 * `downloaded_file_cancellation` **on**. The switch stays off everywhere else: no migration nor seed writes it; this spec
 * turns it on through `psql` on the local stack only (127.0.0.1:54322, never another stack), after asserting that it is
 * off, and back off in `finally`, asserting that it is off again at its end. Its one project (`switch-on`) runs after the
 * desktop and mobile projects, as one serial test that opens the phone's context itself (never two flips at once), so
 * no other spec ever reads the switch on.
 *
 * An ops manager boards B2B files, imports the statement where two of them paid, prepares and approves the client's run,
 * then generates and downloads its transfer file. With the switch off the file's page says it cannot be cancelled yet
 * (« en cours »); with it on, the same page offers « Demander l'annulation (non déposé ou rejeté) » — the file's card,
 * and each transfer's « Virement refusé par la banque ? » — and the sheet says what the cancellation would do and why
 * it cannot be asked today: the bank may still execute the file until the end of the business day after its execution
 * date, and only a statement of those days, produced after them, proves that nothing was debited. Asked anyway, it is
 * refused with those words and nothing changes. Then (review M2c-6b-3a-2 round 1, tests-5) time moves on — the file
 * dated back through psql, as pgTAP does — and the late predecessor is played through the pages: the cancellation
 * asked and confirmed by two people on the statements' evidence, the cancelled payout debited late all the same and
 * booked from « Débits et retours » as its run's payout (`latePredecessor`); then (M2c-6b-3b part 2) its collections held
 * to the last business day before today, the checks raise « remittance_breach_held » on « Contrôles », the R124-6 row
 * waiting for the statement of that day (`heldAlert`). Synthetic data.
 */
const BANK_IBAN = ibanFr(828282);
const SWITCH = "downloaded_file_cancellation";
const FIXTURE = {
  name: "Créances à annuler.csv",
  mimeType: "text/csv",
  buffer: readFileSync(path.resolve(__dirname, "fixtures/factures-imputation.csv")),
};

/** The local stack's database (`supabase status`), never another one: the switch is flipped only there. */
function localDb(): string {
  const url = process.env.DB_URL ?? "postgresql://postgres:postgres@127.0.0.1:54322/postgres";
  const u = new URL(url);
  if (!["127.0.0.1", "localhost"].includes(u.hostname) || u.port !== "54322")
    throw new Error(`switch-on.spec.ts flips the switch on the local stack only (127.0.0.1:54322), not ${u.host}`);
  return url;
}

function psql(sql: string): string {
  return execFileSync("psql", [localDb(), "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-c", sql], {
    encoding: "utf-8",
  }).trim();
}

/** The switch as stored (committed): « t » or « f ». */
function switchState(): string {
  return psql(`select enabled from private.feature_switch where key = '${SWITCH}'`);
}

function setSwitch(on: boolean): void {
  const state = psql(`update private.feature_switch set enabled = ${on} where key = '${SWITCH}' returning enabled`);
  expect(state, `the switch ${SWITCH} is ${on ? "on" : "off"}`).toBe(on ? "t" : "f");
}

/** Today in Europe/Paris (YYYY-MM-DD). */
function parisToday(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Paris" }).format(new Date());
}

/** The latest business day before today (as remittances.spec.ts: the collections' deadlines a month ahead). */
async function statementDay(): Promise<string> {
  const [y, m, d] = parisToday().split("-").map(Number);
  const yesterday = new Date(Date.UTC(y, m - 1, d - 1)).toISOString().slice(0, 10);
  const { data, error } = await adminClient()
    .from("business_calendar")
    .select("day")
    .eq("scope", "FR-conservative")
    .eq("closed", false)
    .lte("day", yesterday)
    .order("day", { ascending: false })
    .limit(1)
    .single();
  if (error) throw error;
  return data.day as string;
}

let tenant: Tenant;
let bankAccountId: string;

test.describe.configure({ mode: "serial" });

test.beforeAll(async () => {
  // critic 2-15: the switch is off when this spec starts — nothing before it left it on
  expect(switchState(), `${SWITCH} is off before the switch-on spec`).toBe("f");
  tenant = await createTenant();
  await createMandate(tenant);
  const { data, error } = await adminClient()
    .from("bank_account")
    .insert({
      organization_id: tenant.servicerId,
      iban: BANK_IBAN,
      currency: "EUR",
      label: "Fonds de tiers – Banque S",
      feed: "camt053",
      opened_on: "2026-01-01",
    })
    .select("id")
    .single();
  if (error) throw error;
  bankAccountId = data.id as string;
  await createConfirmedPayoutAccount(tenant, ibanFr(828283), "BOULANGERIE DURAND");
});

test.afterAll(() => {
  // the flip back, whatever happened in the test (it already did in its own `finally`), then the switch read once more
  setSwitch(false);
  expect(switchState(), `${SWITCH} is off after the switch-on spec`).toBe("f");
});

async function boardAndConfirm(page: Page) {
  await page.goto("/backoffice/reprises/nouveau");
  await page.getByLabel("Date d'arrêté du portefeuille").fill("2026-09-30");
  await page.getByLabel("Fichiers").setInputFiles(FIXTURE);
  await page.getByLabel("Encours restant dû à la date d'arrêté (€)").fill("4 800,00");
  await page.getByLabel("Nombre de lignes du fichier").fill("8");
  await page.getByRole("button", { name: "Déposer et analyser" }).click();
  const status = page.getByTestId("batch-status");
  await expect(status).toHaveText("Mapping à valider", { timeout: 60_000 });
  await page.getByRole("button", { name: "Valider le mapping" }).click();
  await expect(status).toHaveText("Prêt à intégrer", { timeout: 60_000 });
  await page.getByRole("button", { name: "Intégrer le lot" }).click();
  await expect(status).toHaveText("Intégré, à confirmer", { timeout: 60_000 });
  await page.getByRole("button", { name: "Confirmer le lot" }).click();
  await expect(status).toHaveText("Confirmé", { timeout: 60_000 });
}

async function rfOf(externalRef: string): Promise<string> {
  const admin = adminClient();
  const { data: account, error } = await admin
    .from("account")
    .select("id")
    .eq("portfolio_id", tenant.portfolioId)
    .eq("external_ref", externalRef)
    .single();
  if (error) throw error;
  const { data: ref } = await admin
    .from("payment_reference")
    .select("rf")
    .eq("account_id", account.id)
    .eq("status", "active")
    .single();
  return ref!.rf as string;
}

/** The client's run prepared now (or by the hourly schedule, if it came first) and approved from its page. */
async function prepareAndApprove(page: Page) {
  await page.goto("/backoffice/reversements");
  const waiting = page.getByTestId("prepare-row").filter({ hasText: tenant.clientName });
  const card = page.getByTestId("run-card").filter({ hasText: tenant.clientName });
  await expect(async () => {
    await page.reload();
    await expect(waiting.or(card)).toBeVisible({ timeout: 5_000 });
  }).toPass({ timeout: 90_000 });
  if (await waiting.isVisible()) {
    await waiting.getByRole("button", { name: "Préparer maintenant" }).click();
    await card.waitFor({ timeout: 15_000 }).catch(() => page.reload());
  }
  await expect(card.getByText("Brouillon", { exact: true })).toBeVisible({ timeout: 60_000 });
  await card.getByRole("link", { name: tenant.clientName }).click();
  await expect(page.getByTestId("run-status")).toHaveText("Brouillon");
  await page.getByTestId("run-select").check();
  await page.getByTestId("approve-open").click();
  const sheet = page.getByTestId("approve-sheet");
  const lateReason = sheet.getByLabel(/Motif du retard/);
  if (await lateReason.isVisible()) await lateReason.fill("Encaissement identifié tardivement (E2E)");
  await sheet.getByTestId("approve-confirm").click();
  await expect(page.getByTestId("run-status")).toHaveText("Validé — virement ordonné", { timeout: 60_000 });
}

/** A full-page screenshot under docs/screenshots/<name>-<desktop|mobile>.png (this one project takes both). */
async function shot(page: Page, name: string, viewport: "desktop" | "mobile"): Promise<void> {
  await page.screenshot({ path: path.resolve(__dirname, "../../../docs/screenshots", `${name}-${viewport}.png`), fullPage: true });
}

/**
 * The file's page with the switch on, in one viewport: the card offered, then the request sheet with its effect and the
 * statements' evidence (the days not over yet), filled; the screenshots of both. Returns the open sheet.
 */
async function readCancellation(page: Page, filePage: string, viewport: "desktop" | "mobile") {
  await page.goto(filePage);
  await expect(page.getByTestId("file-no-cancellation")).toHaveCount(0);
  const card = page.getByTestId("file-cancellation");
  await expect(card).toBeVisible();
  const ask = card.getByTestId("request-cancellation").getByRole("button");
  await expect(ask).toHaveText("Demander l'annulation (non déposé ou rejeté)");
  // each transfer the bank may have refused alone (folded while nobody asked)
  const item = page.getByTestId("file-items").getByTestId("file-item");
  await expect(item).toHaveCount(1);
  await expect(item.getByTestId("transfer-refused")).toContainText("Virement refusé par la banque ?");
  await expect(page.getByTestId("file-status")).toHaveText("Téléchargé — à déposer à la banque");
  await shot(page, "m2c-virement-telecharge", viewport);

  await ask.click();
  const sheet = page.getByRole("dialog", { name: "Demander l'annulation d'un fichier téléchargé" });
  await expect(sheet.getByTestId("cancel-effect")).toContainText(
    "il n'est annulé que si la banque n'a rien exécuté, relevé à l'appui, et une fois qu'une autre personne a confirmé",
  );
  await expect(sheet.getByTestId("cancel-effect")).toContainText("il reste compté dans le contrôle de trésorerie");
  await expect(sheet.getByTestId("cancel-evidence")).toHaveText(
    /^La banque peut encore exécuter ce fichier jusqu'à la fin du \d{2}\/\d{2}\/\d{4} : l'annulation se demande à partir du \d{2}\/\d{2}\/\d{4}, avec le relevé de ces journées importé après leur fin\.$/,
  );
  await sheet.getByLabel("Le fichier n'a pas été déposé à la banque").check();
  await sheet.getByLabel("Motif (interne)").fill("Fichier téléchargé par erreur, pas encore déposé (E2E)");
  await shot(page, "m2c-annulation-fichier", viewport);
  return sheet;
}

/** A statement imported through « Encaissements » (camt.053), waited until imported. */
async function importStatement(page: Page, name: string, xml: string): Promise<void> {
  await page.goto("/backoffice/encaissements");
  const form = page.getByTestId("statement-upload");
  await form.getByLabel("Relevé CAMT.053 (XML)").setInputFiles({ name, mimeType: "application/xml", buffer: Buffer.from(xml, "utf-8") });
  await form.getByRole("button", { name: "Importer le relevé" }).click();
  // (the statement's own page: « Encaissements » lists every statement of the servicer, each with its status)
  await expect(page).toHaveURL(/\/backoffice\/encaissements\/releves\/[0-9a-f-]{36}/, { timeout: 30_000 });
  await expect(page.getByTestId("statement-status")).toHaveText("Importé", { timeout: 60_000 });
}

/**
 * Review M2c-6b-3a-2 round 1 (tests-5; plan m2c-6b-3 §3.7): the late predecessor through the pages, the switch on.
 * Time moved on (as pgTAP's pg_temp.backdate and the scale test's _backdate): the downloaded file and its item are dated
 * back to the third business day before today, X, through psql on the local stack only; a statement of X and the next
 * business day, produced after them, is imported through the page (nothing executed). The cancellation is asked by one
 * ops manager (desktop) and confirmed by the other (phone): the payout x is cancelled and re-issued as y. Then today's
 * statement shows x's own debit all the same (the bank executed it late): « Débits et retours » lists it first (P0),
 * « Comptabiliser… » proposes it as its run's payout (the late predecessor), and booking it books the run, keeps x
 * « Annulé » and cancels y. Screenshots of the sheet and of the run page, mobile and desktop.
 */
async function latePredecessor(page: Page, mobile: Page, fileId: string, filePage: string): Promise<void> {
  const admin = adminClient();
  const { data: x, error } = await admin
    .from("bank_transfer")
    .select("id, end_to_end_id, amount_minor, run_id")
    .eq("transfer_file_id", fileId)
    .eq("kind", "payout")
    .single();
  if (error) throw error;
  const days = psql(
    `select string_agg(day::text, ',' order by day) from (select day from public.business_calendar
       where scope = 'FR-conservative' and not closed and day < private.paris_today() order by day desc limit 3) d`,
  ).split(",");
  const [dayX, dayY, after] = days; // X, the business day after it, and the one after that (still before today)
  psql(
    `begin;
     alter table public.transfer_file disable trigger transfer_file_guard;
     update public.transfer_file set first_execution_date = '${dayX}', last_execution_date = '${dayX}' where id = '${fileId}';
     alter table public.transfer_file enable always trigger transfer_file_guard;
     alter table public.transfer_file_item disable trigger transfer_file_item_append_only;
     update public.transfer_file_item set execution_date = '${dayX}' where file_id = '${fileId}';
     alter table public.transfer_file_item enable always trigger transfer_file_item_append_only;
     commit;`,
  );
  await importStatement(
    page,
    "releve-execution.xml",
    camt053Lines(BANK_IBAN, dayY, [], [], BigInt(0), { from: dayX, createdAt: `${after}T09:00:00` }),
  );

  // asked by this ops manager (desktop), confirmed by the other (phone)
  await page.goto(filePage);
  await page.getByTestId("file-cancellation").getByTestId("request-cancellation").getByRole("button").click();
  const ask = page.getByRole("dialog", { name: "Demander l'annulation d'un fichier téléchargé" });
  await expect(ask.getByTestId("cancel-evidence")).not.toContainText("La banque peut encore exécuter ce fichier");
  await ask.getByLabel("Le fichier n'a pas été déposé à la banque").check();
  await ask.getByLabel("Motif (interne)").fill("Fichier pas encore déposé, relevés à l'appui (E2E)");
  await ask.getByRole("button", { name: "Demander l'annulation", exact: true }).click();
  await expect(page.getByTestId("file-cancellation").getByTestId("cancel-wait")).toBeVisible({ timeout: 15_000 });
  await mobile.goto(filePage);
  await mobile.getByTestId("file-cancellation").getByTestId("confirm-cancellation").getByRole("button").click();
  await mobile
    .getByRole("dialog", { name: "Confirmer l'annulation du fichier" })
    .getByRole("button", { name: "Confirmer l'annulation" })
    .click();
  await expect(async () => {
    const { data: f } = await admin.from("transfer_file").select("status").eq("id", fileId).single();
    expect(f?.status).toBe("superseded");
  }).toPass({ timeout: 30_000 });
  const { data: y } = await admin
    .from("bank_transfer")
    .select("id, status")
    .eq("replaces_transfer_id", x.id as string)
    .single();
  expect(y?.status).toBe("ordered");

  // today's statement: x's own debit, the bank having executed it all the same
  const today = parisToday();
  await importStatement(
    page,
    "releve-execution-tardive.xml",
    camt053Lines(
      BANK_IBAN,
      today,
      [],
      [{ ref: "LP-1", amountMinor: BigInt(x.amount_minor as number), kind: "transfer", e2e: x.end_to_end_id as string, name: tenant.clientName }],
      BigInt(80001),
    ),
  );
  const amountFr = new Intl.NumberFormat("fr-FR", { minimumFractionDigits: 2 }).format(Number(x.amount_minor) / 100);
  const lateRow = (p: Page) =>
    p.getByTestId("debit-row").filter({ has: p.getByTestId("debit-review-p0") }).filter({ hasText: amountFr });
  for (const [p, viewport] of [
    [mobile, "mobile"],
    [page, "desktop"],
  ] as const) {
    await p.goto("/backoffice/encaissements/debits");
    await expect(async () => {
      await p.reload();
      await expect(lateRow(p)).toHaveCount(1, { timeout: 2_000 });
    }).toPass({ timeout: 60_000 });
    await lateRow(p).getByTestId("book-transfer-line").getByRole("button").click();
    const sheet = p.getByRole("dialog");
    await expect(sheet.getByTestId("transfer-line-proposal")).toContainText("Débit d'un reversement", { timeout: 15_000 });
    const effects = sheet.getByTestId("transfer-line-effects");
    await expect(effects).toContainText("l'import ne comptabilise jamais seul le débit d'un virement annulé");
    await expect(effects).toContainText("Débit d'un reversement — virement annulé, exécuté en retard");
    await expect(effects).toContainText("son virement reste « Annulé »");
    await expect(effects).toContainText("Son virement de remplacement, pas encore remis à la banque, est annulé.");
    await sheet.getByLabel("Motif (ce que montre le relevé ou la banque)").fill("La banque a exécuté le virement annulé (E2E)");
    await shot(p, "m2c-debit-reversement-annule", viewport);
  }
  // booked from the desktop sheet; the phone's stays unsent
  await page.getByRole("dialog").getByRole("button", { name: "Comptabiliser le débit" }).click();
  await expect(page.getByRole("dialog")).toHaveCount(0, { timeout: 15_000 });

  const { data: bookings } = await admin
    .from("bank_line_booking")
    .select("kind, transfer_id")
    .eq("transfer_id", x.id as string);
  expect(bookings).toEqual([{ kind: "payout", transfer_id: x.id }]);
  const { data: after1 } = await admin.from("bank_transfer").select("id, status").in("id", [x.id as string, y!.id as string]);
  expect(new Map((after1 ?? []).map((t) => [t.id, t.status]))).toEqual(
    new Map([
      [x.id, "cancelled"],
      [y!.id, "cancelled"],
    ]),
  );
  const { data: run } = await admin.from("remittance_run").select("status").eq("id", x.run_id as string).single();
  expect(run?.status).toBe("booked");

  // the run page: booked, the late predecessor's debit under its own reference
  const runPage = `/backoffice/reversements/${x.run_id as string}`;
  for (const [p, viewport] of [
    [mobile, "mobile"],
    [page, "desktop"],
  ] as const) {
    await p.goto(runPage);
    await expect(p.getByTestId("run-payout-notes")).toContainText(
      `sous la référence ${x.end_to_end_id as string} (virement annulé, exécuté en retard par la banque)`,
    );
    await shot(p, "m2c-reversement-debite-en-retard", viewport);
  }

  await heldAlert(page, mobile, x.run_id as string, after);
}

/**
 * M2c-6b-3b part 2 (ADR-0014 « M2c-6b-3b part 2 »; CPCE-08): « remittance_breach_held » on « Contrôles ». Time moved
 * on once more (as pgTAP's pg_temp.hold_to): the run's collections are held to `after`, the last business day before
 * today, through psql on the local stack only — the late predecessor's debit (today) is then after their latest
 * execution date. But the run's chain held another transfer handed out (x, executed from X) and no statement imported
 * covers `after` yet (the statement of that day was produced the same evening): the R124-6 row waits, and the checks,
 * run now from the page, raise the alert on the run, naming that day and what to do. Screenshots of the checks page,
 * mobile and desktop. The alert resolves itself the night the statement of `after` is imported (pgTAP 042).
 */
async function heldAlert(page: Page, mobile: Page, runId: string, after: string): Promise<void> {
  psql(
    `begin;
     alter table public.remittance_line disable trigger remittance_line_guard;
     update public.remittance_line set latest_execution_date = '${after}', deadline = '${after}' where run_id = '${runId}';
     alter table public.remittance_line enable always trigger remittance_line_guard;
     commit;`,
  );
  const [y, m, d] = after.split("-");
  const row = (p: Page) => p.locator('[data-testid="check-row"][data-code="remittance_breach_held"]');
  await page.goto("/backoffice/encaissements/controles");
  await page.getByTestId("run-checks").getByRole("button", { name: "Lancer les contrôles" }).click();
  await expect(async () => {
    await page.reload();
    await expect(row(page)).toHaveCount(1, { timeout: 2_000 });
  }).toPass({ timeout: 60_000 });
  await expect(row(page)).toContainText("Dépassement de délai non encore enregistré");
  await expect(row(page)).toContainText("le dépassement n'est pas encore enregistré");
  // review round 1 (dt-1): the statement of `after` is imported but was produced during that day — the day is named as
  // not covered, and ops are asked for a statement established after its end
  await expect(row(page)).toContainText(
    `Aucun relevé importé du compte de fonds de tiers ne couvre encore les jours ouvrés suivants : ${d}/${m}/${y}.`,
  );
  await expect(row(page)).toContainText("Importez un relevé de ces jours établi par la banque après leur fin");
  // (tests-ui-5) the oldest age, its noun agreeing with its number: today − `after`, in days
  const age = Number(psql(`select private.paris_today() - '${after}'::date`));
  await expect(row(page)).toContainText(new RegExp(`le plus ancien : ${age} jour${age > 1 ? "s" : ""}(?!s)`));
  await expect(row(page).getByRole("link", { name: "Ouvrir" })).toHaveAttribute("href", `/backoffice/reversements/${runId}`);
  // no row yet: the alert is its only trace
  const { data: rows } = await adminClient().from("remittance_deadline_breach").select("id").eq("run_id", runId);
  expect(rows).toEqual([]);
  for (const [p, viewport] of [
    [mobile, "mobile"],
    [page, "desktop"],
  ] as const) {
    if (p !== page) await p.goto("/backoffice/encaissements/controles");
    await expect(row(p)).toHaveCount(1);
    await shot(p, "m2c-controles-depassement-en-attente", viewport);
  }
}

test("with the switch on, a downloaded file offers its cancellation, asked only once the statements can prove it", async ({
  page,
  browser,
}) => {
  test.setTimeout(600_000);
  await loginAsStaff(page, await createMember(tenant.servicerId, "ops_manager"));
  await boardAndConfirm(page);
  const credits: Credit[] = [
    { ref: "SW-1", amountMinor: BigInt(50000), name: "DIALLO", iban: ibanFr(81), rf: await rfOf("C2929") },
    { ref: "SW-2", amountMinor: BigInt(30001), name: "RIVIERE ET FILS", iban: ibanFr(82), rf: await rfOf("C3945") },
  ];
  await page.goto("/backoffice/encaissements");
  const form = page.getByTestId("statement-upload");
  await form.getByLabel("Relevé CAMT.053 (XML)").setInputFiles({
    name: "releve-annulation.xml",
    mimeType: "application/xml",
    buffer: Buffer.from(camt053(BANK_IBAN, await statementDay(), credits), "utf-8"),
  });
  await form.getByRole("button", { name: "Importer le relevé" }).click();
  await expect(page.getByTestId("statement-status")).toHaveText("Importé", { timeout: 60_000 });
  await prepareAndApprove(page);

  // « Virements »: the payout in a file, generated and downloaded (not marked as sent)
  await page.goto("/backoffice/reversements/virements");
  const account = page.getByTestId("paying-account").filter({ hasText: "Fonds de tiers – Banque S" });
  await expect(account.getByTestId("transfer-row").filter({ hasText: tenant.clientName })).toHaveCount(1);
  await account.getByTestId("generate-file").getByRole("button", { name: "Générer le fichier" }).click();
  await page
    .getByRole("dialog", { name: "Générer le fichier de virements" })
    .getByRole("button", { name: "Générer", exact: true })
    .click();
  const fileRow = account.getByTestId("file-row").first();
  await expect(fileRow.getByTestId("file-status")).toHaveText("Prêt à télécharger", { timeout: 60_000 });
  await Promise.all([page.waitForEvent("download"), fileRow.getByTestId("file-download").click()]);
  await expect(fileRow.getByTestId("file-mark-sent")).toBeVisible({ timeout: 15_000 });
  const { data: file, error } = await adminClient()
    .from("transfer_file")
    .select("id, status")
    .eq("debtor_bank_account_id", bankAccountId)
    .single();
  if (error) throw error;
  expect(file.status).toBe("downloaded");
  const filePage = `/backoffice/reversements/virements/${file.id as string}`;

  // the switch off (as everywhere else): the downloaded file cannot be cancelled in Collectoo yet
  await page.goto(filePage);
  await expect(page.getByTestId("file-no-cancellation")).toContainText(
    "Un fichier téléchargé ne peut pas encore être annulé dans Collectoo",
  );
  await expect(page.getByTestId("file-cancellation")).toHaveCount(0);

  // a second ops manager on a phone (its own context), signed in before the flip: the flip lasts only the reading
  const phone = await browser.newContext({ ...devices["Pixel 7"], baseURL: test.info().project.use.baseURL });
  const mobile = await phone.newPage();
  await loginAsStaff(mobile, await createMember(tenant.servicerId, "ops_manager"));
  try {
    setSwitch(true);
    await readCancellation(mobile, filePage, "mobile");
    const sheet = await readCancellation(page, filePage, "desktop");
    // asked anyway: refused with the statement's rule, nothing recorded
    await sheet.getByRole("button", { name: "Demander l'annulation", exact: true }).click();
    await expect(sheet.getByRole("alert")).toContainText(
      "Importez d'abord le relevé du compte couvrant le jour d'exécution demandé et le jour ouvré suivant",
    );
    const { data: requests, error: e2 } = await adminClient()
      .from("transfer_cancellation_request")
      .select("id")
      .eq("file_id", file.id as string);
    if (e2) throw e2;
    expect(requests).toEqual([]);
    const { data: still } = await adminClient().from("transfer_file").select("status").eq("id", file.id as string).single();
    expect(still?.status).toBe("downloaded");

    await latePredecessor(page, mobile, file.id as string, filePage);
  } finally {
    setSwitch(false);
    await phone.close();
  }
  expect(switchState(), `${SWITCH} is off at the end of the test`).toBe("f");
  // the file, cancelled on the evidence while the switch was on, offers nothing more (replaced)
  await page.goto(filePage);
  await expect(page.getByTestId("file-status")).toHaveText(/Remplacé/);
  await expect(page.getByTestId("file-cancellation")).toHaveCount(0);
});
