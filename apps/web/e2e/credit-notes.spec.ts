import { expect, test, type Page } from "@playwright/test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { adminClient, createConfirmedPayoutAccount, createMandate, createMember, createTenant, type Tenant } from "./support/admin";
import { camt053, ibanFr, type Credit } from "./support/camt";
import { loginAsStaff, loginWithEmailCode } from "./support/session";
import { reviewShot } from "./screenshot";

/**
 * M2c-5b « Émettre un avoir » (design §14.1, risk R2): a client whose mandate has no netting clause (its invoices are
 * due, no payout sets them off); an admin of the servicer boards its files, imports the statement where two of them
 * paid, prepares and approves its run (FC-…-000001, 120,00 € HT). On the invoice's page the admin types 30,00 € HT, a
 * reason category and a reason, reads the effect sheet (HT, VAT, TTC, what it takes off what the invoice owes, what is
 * left) and issues the credit note: FC-…-000002, in the servicer's series, the invoice's remaining HT 90,00 €. The
 * client's administrator reads it in « Factures »: « rectifie la facture FC-…-000001 » with its reason category, never
 * the reason the admin typed. Phone-first. Synthetic data.
 */
const BANK_IBAN = ibanFr(454545);
const FIXTURE = {
  name: "Créances avoir.csv",
  mimeType: "text/csv",
  buffer: readFileSync(path.resolve(__dirname, "fixtures/factures-imputation.csv")),
};

let tenant: Tenant;

function parisToday(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Paris" }).format(new Date());
}

function addDays(isoDate: string, days: number): string {
  const [y, m, d] = isoDate.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + days)).toISOString().slice(0, 10);
}

/** The latest business day on or before yesterday (Paris), as the remittances spec dates its statement. */
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
  await createMandate(tenant, { netting: false });
  const { error } = await adminClient().from("bank_account").insert({
    organization_id: tenant.servicerId,
    iban: BANK_IBAN,
    currency: "EUR",
    label: "Fonds de tiers – Banque A",
    feed: "camt053",
    opened_on: "2026-01-01",
  });
  if (error) throw error;
  await createConfirmedPayoutAccount(tenant, ibanFr(454546), "BOULANGERIE DURAND");
  const { error: e2 } = await adminClient()
    .from("billing_identity")
    .update({ invoice_acceptance_ref: "art. 11 — Factures électroniques" })
    .eq("organization_id", tenant.clientId);
  if (e2) throw e2;
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

test("an admin issues a manual credit note on an invoice and the client reads it", async ({ page, browser }, testInfo) => {
  test.setTimeout(300_000);
  await loginAsStaff(page, await createMember(tenant.servicerId, "admin"));
  await boardAndConfirm(page);
  const credits: Credit[] = [
    { ref: "AV-1", amountMinor: BigInt(50000), name: "DIALLO", iban: ibanFr(31), rf: await rfOf("C2929") },
    { ref: "AV-2", amountMinor: BigInt(30001), name: "RIVIERE ET FILS", iban: ibanFr(32), rf: await rfOf("C3945") },
  ];
  await page.goto("/backoffice/encaissements");
  const form = page.getByTestId("statement-upload");
  await form.getByLabel("Relevé CAMT.053 (XML)").setInputFiles({
    name: "releve-avoir.xml",
    mimeType: "application/xml",
    buffer: Buffer.from(camt053(BANK_IBAN, await statementDay(), credits), "utf-8"),
  });
  await form.getByRole("button", { name: "Importer le relevé" }).click();
  await expect(page.getByTestId("statement-status")).toHaveText("Importé", { timeout: 60_000 });

  // the client's run, prepared (by the click or the hourly schedule) and approved: its invoice is due (no netting)
  await page.goto("/backoffice/reversements");
  const waiting = page.getByTestId("prepare-row").filter({ hasText: tenant.clientName });
  const card = page.getByTestId("run-card").filter({ hasText: tenant.clientName });
  await expect(waiting.or(card)).toBeVisible({ timeout: 60_000 });
  if (await waiting.isVisible()) {
    await waiting.getByRole("button", { name: "Préparer maintenant" }).click();
    await card.waitFor({ timeout: 15_000 }).catch(() => page.reload());
  }
  await expect(card.getByText("Brouillon", { exact: true })).toBeVisible({ timeout: 60_000 });
  await expect(card.getByTestId("run-net")).toContainText("800,01");
  await card.getByRole("link", { name: tenant.clientName }).click();
  await expect(page.getByTestId("run-status")).toHaveText("Brouillon");
  await page.getByTestId("run-select").check();
  await page.getByTestId("approve-open").click();
  const sheet = page.getByTestId("approve-sheet");
  const lateReason = sheet.getByLabel(/Motif du retard/);
  if (await lateReason.isVisible()) await lateReason.fill("Encaissement identifié tardivement (E2E)");
  await sheet.getByTestId("approve-confirm").click();
  await expect(page.getByTestId("run-status")).toHaveText("Validé — virement ordonné", { timeout: 60_000 });

  // the invoice's page: what it still charges and owes
  const invoiceLink = page.getByTestId("run-document-link").filter({ hasText: /Facture FC-\d{4}-000001/ });
  await expect(invoiceLink).toBeVisible();
  const invoiceNumber = ((await invoiceLink.textContent()) ?? "").replace("Facture ", "").trim();
  await invoiceLink.click();
  await expect(page).toHaveURL(/\/backoffice\/reversements\/factures\/[0-9a-f-]{36}$/);
  await expect(page.getByTestId("invoice-remaining")).toContainText("120,00");
  await expect(page.getByTestId("invoice-open")).toContainText("144,00");
  await expect(page.getByTestId("invoice-files")).toContainText("Dossiers facturés (2)");
  await reviewShot(page, testInfo, "m2c5b-facture");

  // « Émettre un avoir »: the amount, the reason category, the reason; the effect sheet; then the credit note
  const panel = page.getByTestId("credit-note-form");
  await panel.getByLabel("Montant HT de l'avoir (€)").fill("30,00");
  await panel.getByLabel(/Erreur de conditions de rémunération/).check();
  await panel.getByLabel(/Motif détaillé/).fill("Taux négocié à 11,25 % non saisi dans les conditions (E2E)");
  await panel.getByTestId("credit-note-preview").click();
  const effect = page.getByTestId("credit-note-effect");
  await expect(effect).toBeVisible();
  await expect(effect).toContainText(/Avoir HT\s*30,00/);
  await expect(effect).toContainText(/TVA 20\s%\s*6,00/);
  await expect(effect).toContainText(/Avoir TTC\s*36,00/);
  await expect(effect).toContainText(/La facture devra encore \(TTC\)\s*108,00/);
  await expect(effect).toContainText(/Reste facturé après l'avoir \(HT\)\s*90,00/);
  await expect(effect).toContainText("Réparti sur 2 dossiers.");
  await reviewShot(page, testInfo, "m2c5b-avoir-effet");
  await page.getByTestId("credit-note-confirm").click();
  await expect(page.getByTestId("credit-note-issued")).toContainText(/Avoir FC-\d{4}-000002 émis/, { timeout: 30_000 });
  await expect(page.getByTestId("invoice-remaining")).toContainText("90,00");
  await expect(page.getByTestId("invoice-open")).toContainText("108,00");
  const note = page.getByTestId("invoice-credit-note");
  await expect(note).toHaveCount(1);
  await expect(note).toContainText(/Avoir FC-\d{4}-000002/);
  await expect(note).toContainText("Avoir manuel : erreur de conditions de rémunération (taux, paliers ou minimum)");
  await reviewShot(page, testInfo, "m2c5b-avoir-emis");

  // the client's administrator: « Factures » shows the credit note and the invoice it rectifies, not the admin's text
  const use = testInfo.project.use;
  const context = await browser.newContext({
    baseURL: use.baseURL,
    viewport: use.viewport,
    userAgent: use.userAgent,
    deviceScaleFactor: use.deviceScaleFactor,
    isMobile: use.isMobile,
    hasTouch: use.hasTouch,
  });
  const client = await context.newPage();
  await loginWithEmailCode(client, await createMember(tenant.clientId, "client_admin"));
  await expect(client).toHaveURL(/\/client$/);
  await client.getByTestId("client-remittances-link").click();
  await expect(client).toHaveURL(/\/client\/reversements$/);
  await client.getByTestId("client-invoices-link").click();
  await expect(client).toHaveURL(/\/client\/factures$/);
  const rows = client.getByTestId("invoice-row");
  await expect(rows).toHaveCount(2);
  const creditRow = rows.filter({ hasText: /Avoir FC-\d{4}-000002/ });
  await expect(creditRow.getByTestId("invoice-rectifies")).toContainText(`rectifie la facture ${invoiceNumber} du`);
  await expect(creditRow.getByTestId("invoice-rectifies")).toContainText(
    "rectification d'une erreur de conditions de rémunération (taux, paliers ou minimum)",
  );
  await expect(creditRow).toContainText("36,00");
  await expect(client.getByText("11,25 %")).toHaveCount(0);
  await reviewShot(client, testInfo, "m2c5b-client-factures");
  await context.close();
});
