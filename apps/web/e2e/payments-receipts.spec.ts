import { expect, test, type Page } from "@playwright/test";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";
import { adminClient, createMandate, createMember, createTenant, type Tenant } from "./support/admin";
import { camt053, ibanFr, type Credit } from "./support/camt";
import { loginAsStaff, loginWithEmailCode } from "./support/session";
import { reviewShot } from "./screenshot";

/**
 * M2b-5 (M2-10, M2-11): receipts and the client payment feed. An ops manager boards three B2B files (synthetic), imports
 * the client-funds statement where two of them paid by their RF reference, and finds each allocated payment's receipt
 * (R124-6) on its page: a PDF built from the ledger, its SHA-256 recorded; Diallo paid more than due (« Montant non
 * imputé »), Rivière's payment comes from a third party (never named). Reversing Rivière's allocation issues version 2.
 * The client then reads « Paiements reçus » in its space (R124-5): what was allocated and reversed, the amounts from the
 * ledger, the receipts; reading it records the delivery. Synthetic data.
 */
const BANK_IBAN = ibanFr(434343);
const DAY = "2026-11-03";
const FIXTURE = {
  name: "Créances quittances.csv",
  mimeType: "text/csv",
  buffer: readFileSync(path.resolve(__dirname, "fixtures/factures-imputation.csv")),
};

let tenant: Tenant;
/** An amount as the pages print it: thousands grouped by a narrow no-break space (formatMoneyFr). */
const n = (text: string) => text.replace(/(\d) (\d)/g, "$1 $2");

test.beforeAll(async () => {
  tenant = await createTenant();
  await createMandate(tenant);
  const { error } = await adminClient().from("bank_account").insert({
    organization_id: tenant.servicerId,
    iban: BANK_IBAN,
    currency: "EUR",
    label: "Fonds de tiers – Banque Q",
    feed: "camt053",
    opened_on: "2026-01-01",
  });
  if (error) throw error;
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

/** RF reference per client account number. */
async function references(): Promise<Record<string, string>> {
  const admin = adminClient();
  const { data: accounts, error } = await admin.from("account").select("id, external_ref").eq("portfolio_id", tenant.portfolioId);
  if (error) throw error;
  const { data: refs } = await admin
    .from("payment_reference")
    .select("account_id, rf")
    .in(
      "account_id",
      accounts.map((a) => a.id),
    )
    .eq("status", "active");
  return Object.fromEntries(accounts.map((a) => [a.external_ref, refs?.find((r) => r.account_id === a.id)?.rf ?? ""]));
}

async function paymentOf(ref: string): Promise<string> {
  const admin = adminClient();
  const { data: line, error } = await admin
    .from("bank_transaction")
    .select("id")
    .eq("organization_id", tenant.servicerId)
    .eq("acct_svcr_ref", ref)
    .single();
  if (error) throw error;
  const { data: p } = await admin.from("payment").select("id").eq("bank_transaction_id", line.id).single();
  return p!.id;
}

test("receipts on the payment page; the client reads its payment feed", async ({ page, browser }, testInfo) => {
  test.setTimeout(300_000);
  await loginAsStaff(page, await createMember(tenant.servicerId, "ops_manager"));
  await boardAndConfirm(page);
  const rf = await references();
  const credits: Credit[] = [
    // 1 200,00 € on a 1 000,00 € file: 200,00 € not allocated (kept for the payer)
    { ref: "QT-1", amountMinor: BigInt(120000), name: "DIALLO", iban: ibanFr(21), rf: rf["C2929"] },
    // paid for Rivière et Fils by someone else: the receipt says « Versement d'un tiers »
    { ref: "QT-2", amountMinor: BigInt(30001), name: "SCI DES LILAS POUR RIVIERE", iban: ibanFr(22), rf: rf["C3945"] },
  ];
  await page.goto("/backoffice/encaissements");
  const form = page.getByTestId("statement-upload");
  await form.getByLabel("Relevé CAMT.053 (XML)").setInputFiles({
    name: "releve-quittances.xml",
    mimeType: "application/xml",
    buffer: Buffer.from(camt053(BANK_IBAN, DAY, credits), "utf-8"),
  });
  await form.getByRole("button", { name: "Importer le relevé" }).click();
  await expect(page.getByTestId("statement-status")).toHaveText("Importé", { timeout: 60_000 });

  // Diallo: allocated in part; its receipt is issued from the ledger, PDF and SHA-256
  const diallo = await paymentOf("QT-1");
  await page.goto(`/backoffice/encaissements/paiements/${diallo}`);
  await expect(page.getByTestId("payment-status")).toHaveText("Imputé en partie", { timeout: 60_000 });
  const versions = page.getByTestId("receipt-version");
  await expect(versions).toHaveCount(1, { timeout: 60_000 });
  await expect(versions.first()).toContainText(/Q-\d{4}-\d{6} · Version 1/);
  await expect(versions.first()).toContainText("En vigueur");
  await expect(page.getByTestId("payment-receipt")).toContainText("sans solde restant dû");
  const href = await page.getByTestId("receipt-pdf").first().getAttribute("href");
  const pdf = await page.request.get(href!);
  expect(pdf.status()).toBe(200);
  expect(pdf.headers()["content-type"]).toBe("application/pdf");
  const bytes = await pdf.body();
  expect(bytes.subarray(0, 5).toString()).toBe("%PDF-");
  const { data: stored } = await adminClient().from("receipt").select("pdf_sha256, payload").eq("payment_id", diallo).single();
  expect(createHash("sha256").update(bytes).digest("hex")).toBe(stored!.pdf_sha256);
  const payload = stored!.payload as { totals: { unallocated_minor: string }; payer: { name: string | null } };
  expect(payload.totals.unallocated_minor).toBe("20000");
  expect(payload.payer.name).toBe("Diallo"); // a party to the file: named, by the party's own name (founder #15)
  await reviewShot(page, testInfo, "m2-payment-receipt");

  // Rivière: a third party paid (never named); reversing the allocation issues version 2
  const riviere = await paymentOf("QT-2");
  await page.goto(`/backoffice/encaissements/paiements/${riviere}`);
  await expect(page.getByTestId("payment-status")).toHaveText("Imputé", { timeout: 60_000 });
  await expect(page.getByTestId("receipt-version")).toHaveCount(1, { timeout: 60_000 });
  const { data: first } = await adminClient().from("receipt").select("payload").eq("payment_id", riviere).single();
  expect((first!.payload as { payer: unknown }).payer).toEqual({ name: null, third_party: true });
  await page.getByTestId("reverse-allocation").getByRole("button").first().click();
  const reverse = page.getByRole("dialog", { name: "Annuler cette imputation" });
  await reverse.getByLabel("Motif interne (non transmis au client)").fill("Payeur à vérifier");
  await reverse.getByRole("button", { name: "Confirmer l'annulation" }).click();
  await expect(page.getByTestId("payment-reason")).toHaveText("Imputation annulée");
  await expect(page.getByTestId("receipt-version")).toHaveCount(2, { timeout: 60_000 });
  await expect(page.getByTestId("receipt-version").first()).toContainText("Version 2 – remplace la version 1");
  await expect(page.getByTestId("receipt-pending")).toHaveCount(0); // the job ran: nothing more to wait for
  await expect(page.getByTestId("receipt-version").nth(1)).not.toContainText("En vigueur");
  await reviewShot(page, testInfo, "m2-payment-receipt-versions");

  // The client reads its feed (its own browser, same device): allocated, reversed; amounts from the ledger
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
  await client.getByTestId("client-payments-link").click();
  await expect(client).toHaveURL(/\/client\/paiements$/);
  const rows = client.getByTestId("feed-row");
  await expect(rows).toHaveCount(3);
  await expect(client.locator('[data-kind="payment_allocation_reversed"]')).toContainText("300,01");
  await expect(client.locator('[data-kind="payment_allocation_reversed"]')).toContainText("Imputation corrigée par nos services.");
  await expect(client.locator('[data-kind="payment_allocation_reversed"]')).not.toContainText("Payeur à vérifier");
  const dialloRow = client.locator('[data-kind="payment_allocated"]').filter({ hasText: "C2929" });
  await expect(dialloRow.getByTestId("feed-amount")).toContainText(n("1 000,00"));
  await expect(dialloRow.getByTestId("feed-lines")).toContainText("F2026-00201");
  await expect(dialloRow.getByTestId("feed-receipt")).toContainText(/Quittance Q-\d{4}-\d{6} · version 1/);
  await expect(client.getByTestId("feed-new")).toHaveCount(3);
  await reviewShot(client, testInfo, "m2-client-payments");
  const clientPdf = await client.request.get((await dialloRow.getByTestId("feed-receipt").getAttribute("href"))!);
  expect(clientPdf.status()).toBe(200);
  expect((await clientPdf.body()).subarray(0, 5).toString()).toBe("%PDF-");
  // reading the feed delivered it (R124-5): once
  await client.reload();
  await expect(rows).toHaveCount(3);
  await expect(client.getByTestId("feed-new")).toHaveCount(0);
  const { data: delivered } = await adminClient()
    .from("client_notification")
    .select("delivered_at")
    .eq("client_organization_id", tenant.clientId);
  expect(delivered!.length).toBe(3);
  expect(delivered!.every((x) => x.delivered_at !== null)).toBe(true);
  await context.close();

  // Ops see the delivery on the payment page
  await page.reload();
  await expect(page.getByTestId("payment-notifications")).toContainText("dans son espace client");
});
