import { expect, test, type Page } from "@playwright/test";
import { execFileSync } from "node:child_process";
import { adminClient, createMember, createTenant, type Tenant } from "./support/admin";
import { camt053Lines, ibanFr, type Credit, type Debit } from "./support/camt";
import { loginAsStaff } from "./support/session";
import { reviewShot } from "./screenshot";
import { expectOwnImport } from "./support/statements";

/**
 * M2c-7e-1 (plan docs/design/m2c-7-plan.md §7.1, §7.2, §7.4; ADR-0014 « M2c-7e-1 »): the bank's coded charge on the
 * dedicated account is booked by the debit job (the servicer owes it, 4679); the hourly job (its `top_ups` message for
 * this servicer only, sent through psql on the local stack only, as the cron sends it at :37) orders the top-up
 * automatically (TOP…); « Virements » « Approvisionnements du compte dédié » lists it, generates the own account's
 * pain.001 file (debtor the own account, creditor the dedicated one, no cash check), downloads it and cancels it after
 * download (the switch off: an own-account file needs no second person — no client is paid by it). The next hour orders
 * it again; its credit arrives without the TOP reference and « Rattacher à TOP… » books it; the next hour closes the
 * period « Comptes bancaires » lists. Screenshots `m2c7-approvisionnements`, `m2c7-periodes-decouvert` (mobile + desktop).
 * Each test its own tenant (the tests run in parallel). The switch stays off. Synthetic data.
 */

const n = (text: string) => text.replace(/(\d) (\d)/g, "$1 $2");

/** The local stack's database (`supabase status`), never another one. */
function localDb(): string {
  const url = process.env.DB_URL ?? "postgresql://postgres:postgres@127.0.0.1:54322/postgres";
  const u = new URL(url);
  if (!["127.0.0.1", "localhost"].includes(u.hostname) || u.port !== "54322")
    throw new Error(`top-ups.spec.ts sends the hourly message on the local stack only (127.0.0.1:54322), not ${u.host}`);
  return url;
}

function psql(sql: string): string {
  return execFileSync("psql", [localDb(), "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-c", sql], {
    encoding: "utf-8",
  }).trim();
}

/** The hourly job's message for this servicer only (private.queue_top_ups sends one per servicer). */
function hourlyTopUps(t: Tenant): void {
  const uuid = /^[0-9a-f-]{36}$/;
  if (!uuid.test(t.servicerId)) throw new Error("not a servicer id");
  psql(`select pgmq.send('remittances', jsonb_build_object('type', 'top_ups', 'organization_id', '${t.servicerId}'))`);
}

function parisDay(offset: number): string {
  const today = new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Paris" }).format(new Date());
  const [y, m, d] = today.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + offset)).toISOString().slice(0, 10);
}

async function topUps(t: Tenant): Promise<{ status: string; amount_minor: number; end_to_end_id: string }[]> {
  const { data, error } = await adminClient()
    .from("bank_transfer")
    .select("status, amount_minor, end_to_end_id")
    .eq("organization_id", t.servicerId)
    .eq("kind", "top_up")
    .order("created_at");
  if (error) throw error;
  return data as { status: string; amount_minor: number; end_to_end_id: string }[];
}

async function importStatement(page: Page, xml: string, name: string): Promise<void> {
  await page.goto("/backoffice/encaissements");
  const form = page.getByTestId("statement-upload");
  await form.getByLabel("Relevé CAMT.053 (XML)").setInputFiles({ name, mimeType: "application/xml", buffer: Buffer.from(xml, "utf-8") });
  await form.getByRole("button", { name: "Importer le relevé" }).click();
  await expectOwnImport(page);
}

test("the hourly top-up, the own account's file, its cancellation, « Rattacher à TOP… » and the period", async ({ page }, testInfo) => {
  test.setTimeout(300_000);
  const t = await createTenant();
  const seed = Number.parseInt(t.servicerId.slice(0, 6), 16);
  const bankIban = ibanFr(seed);
  const ownIban = ibanFr(seed + 3);
  const admin = adminClient();
  const { data: accounts, error } = await admin
    .from("bank_account")
    .insert([
      {
        organization_id: t.servicerId,
        iban: bankIban,
        currency: "EUR",
        label: "Fonds de tiers – Banque T",
        purpose: "client_funds",
        feed: "camt053",
        opened_on: "2026-01-01",
      },
      {
        organization_id: t.servicerId,
        iban: ownIban,
        currency: "EUR",
        label: "Compte propre – Banque T",
        purpose: "own",
        feed: null,
        opened_on: "2026-01-01",
      },
    ])
    .select("id, purpose");
  if (error) throw error;
  const own = accounts.find((a) => a.purpose === "own")!;
  const { error: settingsError } = await admin
    .from("servicer_billing_settings")
    .upsert({ organization_id: t.servicerId, own_bank_account_id: own.id }, { onConflict: "organization_id" });
  if (settingsError) throw settingsError;
  await loginAsStaff(page, await createMember(t.servicerId, "ops_manager"));

  // the bank's coded charge: booked by the debit job, at the servicer's charge (it owes the dedicated account 125,00 €)
  const credits: Credit[] = [{ ref: "TU-1", amountMinor: BigInt(20000), name: "MARTIN JEAN", iban: ibanFr(seed + 9) }];
  const debits: Debit[] = [{ ref: "TU-2", amountMinor: BigInt(12500), kind: "fee" }];
  await importStatement(page, camt053Lines(bankIban, parisDay(-2), credits, debits, BigInt(0)), "releve-frais.xml");
  await expect
    .poll(
      async () =>
        (await admin.from("ledger_entry").select("id").eq("organization_id", t.servicerId).eq("entry_type", "bank_fee")).data
          ?.length ?? 0,
      { timeout: 60_000 },
    )
    .toBe(1);

  // the hourly job orders it automatically
  hourlyTopUps(t);
  await expect.poll(async () => (await topUps(t)).map((x) => `${x.status}:${x.amount_minor}`), { timeout: 60_000 }).toEqual(["ordered:12500"]);
  const [first] = await topUps(t);
  expect(first.end_to_end_id).toMatch(/^TOP[0-9A-F]{12}$/);

  await page.goto("/backoffice/reversements/virements");
  const section = page.getByTestId("top-up-section");
  await expect(section).toContainText("Approvisionnements du compte dédié");
  const row = section.getByTestId("top-up-row").filter({ hasText: first.end_to_end_id });
  await expect(row).toContainText(n("125,00 €"));
  await expect(row).toContainText("commandé automatiquement");
  await expect(row.getByTestId("top-up-status")).toHaveText("À exécuter depuis le compte propre");
  await expect(section.getByTestId("top-up-needed")).toContainText("Rien à approvisionner en EUR");
  await reviewShot(page, testInfo, "m2c7-approvisionnements");

  // « Générer le fichier (compte propre) »: the worker writes it; downloaded, it debits the own account
  await section.getByTestId("generate-top-up-file").getByRole("button", { name: "Générer le fichier (compte propre)" }).click();
  const generate = page.getByRole("dialog", { name: "Générer le fichier du compte propre" });
  await expect(generate).toContainText("Aucun contrôle de solde");
  await generate.getByRole("button", { name: "Générer" }).click();
  const file = section.getByTestId("top-up-file").first();
  await expect(file.getByTestId("top-up-file-status")).toHaveText("Prêt à télécharger", { timeout: 60_000 });
  await expect(row.getByTestId("top-up-status")).toHaveText("Dans un fichier du compte propre");
  const href = await file.getByTestId("top-up-file-download").getAttribute("href");
  // the file as written (indented): its elements, without the indentation between them
  const xml = (await (await page.request.get(href!)).text()).replace(/>\s+</g, "><");
  expect(xml).toContain(`<EndToEndId>${first.end_to_end_id}</EndToEndId>`);
  expect(xml).toContain(`<DbtrAcct><Id><IBAN>${ownIban}</IBAN></Id>`);
  expect(xml).toContain(`<CdtrAcct><Id><IBAN>${bankIban}</IBAN></Id>`);
  await page.reload();
  await expect(file.getByTestId("top-up-file-status")).toHaveText("Téléchargé");

  // « Annuler le fichier » after download, the switch off: its top-ups are cancelled, the next hour orders again
  await file.getByTestId("cancel-top-up-file").getByRole("button", { name: "Annuler le fichier" }).click();
  const cancel = page.getByRole("dialog", { name: /^Annuler le fichier / });
  await expect(cancel.getByTestId("cancel-top-up-file-effect")).toContainText(
    "Les approvisionnements non comptabilisés de ce fichier sont annulés ; Collectoo recommande ce qui reste dû dans l'heure.",
  );
  await cancel.getByLabel("Motif (non déposé, refusé par la banque…)").fill("Fichier non déposé : virement fait à la main");
  await cancel.getByRole("button", { name: "Annuler le fichier" }).click();
  await expect(file.getByTestId("top-up-file-status")).toHaveText("Remplacé ou annulé");
  await expect(row.getByTestId("top-up-status")).toHaveText("Annulé");
  hourlyTopUps(t);
  await expect
    .poll(async () => (await topUps(t)).map((x) => `${x.status}:${x.amount_minor}`), { timeout: 60_000 })
    .toEqual(["cancelled:12500", "ordered:12500"]);

  // its credit arrives without the TOP reference: « Rattacher à TOP… » books it as the open top-up
  const ownCredit: Credit[] = [{ ref: "TU-3", amountMinor: BigInt(12500), name: "CABINET E2E", iban: ownIban }];
  await importStatement(page, camt053Lines(bankIban, parisDay(-1), ownCredit, [], BigInt(7500)), "releve-approvisionnement.xml");
  await page.goto("/backoffice/encaissements/debits");
  const credit = page.getByTestId("debit-row").filter({ hasText: "Virement reçu du compte propre" });
  await expect(credit).toHaveCount(1, { timeout: 60_000 });
  await credit.getByTestId("book-top-up-credit").getByRole("button", { name: "Rattacher à TOP…" }).click();
  const pick = page.getByRole("dialog", { name: "Rattacher à un approvisionnement" });
  await expect(pick.getByTestId("top-up-credit-option")).toHaveCount(1);
  await pick.getByLabel("Motif (ce que montre le relevé ou la banque)").fill("Virement du compte propre sans sa référence TOP");
  await pick.getByRole("button", { name: "Rattacher" }).click();
  await expect(credit).toHaveCount(0);
  await expect
    .poll(async () => (await topUps(t)).map((x) => x.status), { timeout: 30_000 })
    .toEqual(["cancelled", "booked"]);

  // the next hour finds nothing owed: the period closes
  hourlyTopUps(t);
  await expect
    .poll(
      () => psql(`select count(*) from private.servicer_shortfall_period where organization_id = '${t.servicerId}' and closed_at is not null`),
      { timeout: 60_000 },
    )
    .toBe("1");
  await page.goto("/backoffice/parametres/comptes-bancaires");
  const period = page.getByTestId("shortfall-period");
  await expect(period).toHaveCount(1);
  await expect(period).toContainText(/^Du \d{2}\/\d{2}\/\d{4} \d{2}:\d{2} au \d{2}\/\d{2}\/\d{4} \d{2}:\d{2} — jusqu'à 125,00\s€/);
  await expect(period).toContainText(n("Frais bancaires"));
  await reviewShot(page, testInfo, "m2c7-periodes-decouvert");
});
