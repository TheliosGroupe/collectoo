import { expect, test, type Page } from "@playwright/test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { adminClient, createConfirmedPayoutAccount, createMandate, createMember, createTenant, type Tenant } from "./support/admin";
import { camt053, ibanFr, type Credit } from "./support/camt";
import { loginAsStaff } from "./support/session";
import { reviewShot } from "./screenshot";

/**
 * M2c-4 « Reversements » (M2-14 core, M2-15 numbering; design §17.1–§17.2): an ops manager boards B2B files, imports
 * the dedicated account's statement where two of them paid, then, on « Reversements », prepares the client's run
 * (« Préparer maintenant »), reads it — the net in large type, the commission netted, the deadline chip, the lines
 * and « Pourquoi cette commission ? », the invoice to issue — approves it from the sticky bar (the sheet states every
 * effect), and finds it approved: the invoice numbered in the servicer's series, the payout ordered (nothing leaves
 * the dedicated account before the bank's debit, M2c-6). Phone-first. Synthetic data.
 */
const BANK_IBAN = ibanFr(434343);
const FIXTURE = {
  name: "Créances à reverser.csv",
  mimeType: "text/csv",
  buffer: readFileSync(path.resolve(__dirname, "fixtures/factures-imputation.csv")),
};

let tenant: Tenant;

/** Today in Europe/Paris (YYYY-MM-DD), the day `private.paris_today()` reads on the same machine. */
function parisToday(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Paris" }).format(new Date());
}

function addDays(isoDate: string, days: number): string {
  const [y, m, d] = isoDate.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + days)).toISOString().slice(0, 10);
}

/**
 * The statement's day (review M2c-4 tests-ui#0): the latest business day of `public.business_calendar` on or before
 * yesterday (Paris), never a fixed date. The collections' latest execution date (one month on, R124-6) is then about
 * four weeks ahead: the chip reads « Exécution au plus tard le », the default execution date (the next business day) is
 * never late, and the deadline guard (5 business days before it) is never due.
 */
async function statementDay(): Promise<string> {
  const { data, error } = await adminClient()
    .from("business_calendar")
    .select("day")
    .eq("scope", "FR-conservative")
    .eq("closed", false)
    .lte("day", addDays(parisToday(), -1))
    .order("day", { ascending: false })
    .limit(1)
    .single();
  if (error) throw error;
  return data.day as string;
}

test.beforeAll(async () => {
  tenant = await createTenant();
  await createMandate(tenant);
  const { error } = await adminClient().from("bank_account").insert({
    organization_id: tenant.servicerId,
    iban: BANK_IBAN,
    currency: "EUR",
    label: "Fonds de tiers – Banque R",
    feed: "camt053",
    opened_on: "2026-01-01",
  });
  if (error) throw error;
  await createConfirmedPayoutAccount(tenant, ibanFr(434344), "BOULANGERIE DURAND");
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
  const { data: ref } = await admin.from("payment_reference").select("rf").eq("account_id", account.id).eq("status", "active").single();
  return ref!.rf as string;
}

test("ops prepare, read and approve a client's remittance run", async ({ page }, testInfo) => {
  test.setTimeout(300_000);
  await loginAsStaff(page, await createMember(tenant.servicerId, "ops_manager"));
  await boardAndConfirm(page);
  const credits: Credit[] = [
    { ref: "RV-1", amountMinor: BigInt(50000), name: "DIALLO", iban: ibanFr(21), rf: await rfOf("C2929") },
    { ref: "RV-2", amountMinor: BigInt(30001), name: "RIVIERE ET FILS", iban: ibanFr(22), rf: await rfOf("C3945") },
  ];
  await page.goto("/backoffice/encaissements");
  const form = page.getByTestId("statement-upload");
  await form.getByLabel("Relevé CAMT.053 (XML)").setInputFiles({
    name: "releve-reversement.xml",
    mimeType: "application/xml",
    buffer: Buffer.from(camt053(BANK_IBAN, await statementDay(), credits), "utf-8"),
  });
  await form.getByRole("button", { name: "Importer le relevé" }).click();
  await expect(page.getByTestId("statement-status")).toHaveText("Importé", { timeout: 60_000 });

  // « Reversements »: the client's collections wait; prepare its run now. The hourly schedule (xx:07) may have
  // prepared it first on a run day of the mandate (the 1st, the 16th): its draft is then the one read and approved.
  await page.goto("/backoffice");
  await page.getByTestId("remittances-link").click();
  await expect(page).toHaveURL(/\/backoffice\/reversements$/);
  const waiting = page.getByTestId("prepare-row").filter({ hasText: tenant.clientName });
  const card = page.getByTestId("run-card").filter({ hasText: tenant.clientName });
  await expect(waiting.or(card)).toBeVisible({ timeout: 60_000 });
  if (await waiting.isVisible()) {
    await expect(waiting).toContainText("800,01");
    await waiting.getByRole("button", { name: "Préparer maintenant" }).click();
    // a click that lost the race to the schedule is refused (one run at a time) and the list stays: reload it
    await card.waitFor({ timeout: 15_000 }).catch(() => page.reload());
  }
  // the draft, prepared by the click or by the schedule (the page refreshes itself while it is prepared)
  await expect(card.getByText("Brouillon", { exact: true })).toBeVisible({ timeout: 60_000 });
  await expect(card).toContainText("brut 800,01");
  await expect(card.getByTestId("run-net")).toContainText("656,01");
  await expect(card).toContainText("commission 144,00 € TTC");
  await expect(card).toContainText("Exécution au plus tard le");
  await reviewShot(page, testInfo, "m2c-reversements");

  // the run's page: the lines, why each commission, the invoice to issue
  await card.getByRole("link", { name: tenant.clientName }).click();
  await expect(page.getByTestId("run-status")).toHaveText("Brouillon");
  await expect(page.getByTestId("run-lines").getByTestId("run-line")).toHaveCount(2);
  await page.getByTestId("run-line").first().getByText("Pourquoi cette commission ?").click();
  await expect(page.getByTestId("run-line").first()).toContainText("15 % sur");
  await expect(page.getByTestId("run-documents")).toContainText("(numérotée à la validation)");
  await reviewShot(page, testInfo, "m2c-reversement");

  // approve from the sticky bar: the sheet states every effect
  await page.getByTestId("run-select").check();
  await page.getByTestId("approve-open").click();
  const sheet = page.getByTestId("approve-sheet");
  await expect(sheet.getByTestId("approve-effects")).toContainText("1 virement depuis le compte dédié");
  await expect(sheet.getByTestId("approve-effects")).toContainText("1 facture sera numérotée");
  await reviewShot(page, testInfo, "m2c-reversement-validation");
  // never shown with a statement of yesterday; filled if a calendar ever makes the default date late
  const lateReason = sheet.getByLabel(/Motif du retard/);
  if (await lateReason.isVisible()) await lateReason.fill("Encaissement identifié tardivement (E2E)");
  await sheet.getByTestId("approve-confirm").click();
  await expect(page.getByTestId("run-status")).toHaveText("Validé — virement ordonné", { timeout: 60_000 });
  await expect(page.getByTestId("run-documents")).toContainText(/Facture FC-\d{4}-000001/);
  await expect(page.getByTestId("run-transfer")).toContainText("656,01");
  await expect(page.getByTestId("run-transfer")).toContainText("Ordonné");
  await reviewShot(page, testInfo, "m2c-reversement-valide");

  // « En cours »
  await page.goto("/backoffice/reversements?onglet=en-cours");
  await expect(page.getByTestId("run-row").filter({ hasText: tenant.clientName })).toContainText("Validé — virement ordonné");
});
