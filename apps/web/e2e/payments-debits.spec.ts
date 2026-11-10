import { expect, test, type Page } from "@playwright/test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { adminClient, createMandate, createMember, createTenant, type Tenant } from "./support/admin";
import { camt053, camt053Lines, ibanFr, type Credit, type Debit } from "./support/camt";
import { loginAsStaff } from "./support/session";
import { reviewShot } from "./screenshot";

/**
 * M2b-6: money leaving the client-funds account. An ops manager boards three B2B files (synthetic), imports the statement
 * where Diallo paid 200,00 € too much and Rivière paid in full, asks for the refund of Diallo's overpayment (our RFD
 * reference, nothing booked yet), then imports the next statement: the refund's debit (linked and booked), the bank's
 * return of Rivière's payment (its allocation undone on the return date, the receipt cancelled, the client told), a fee
 * (not booked: an explained gap) and a return nobody can name, which ops classify on « Débits et retours ». Then a
 * payment the debtor made to the client directly, declared on the file page, and the nightly checks run on demand.
 * Synthetic data.
 */
const BANK_IBAN = ibanFr(565656);
const FIXTURE = {
  name: "Créances débits.csv",
  mimeType: "text/csv",
  buffer: readFileSync(path.resolve(__dirname, "fixtures/factures-imputation.csv")),
};

let tenant: Tenant;
const n = (text: string) => text.replace(/(\d) (\d)/g, "$1 $2");

test.beforeAll(async () => {
  tenant = await createTenant();
  await createMandate(tenant);
  const { error } = await adminClient().from("bank_account").insert({
    organization_id: tenant.servicerId,
    iban: BANK_IBAN,
    currency: "EUR",
    label: "Fonds de tiers – Banque D",
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

async function files(): Promise<Record<string, { id: string; rf: string }>> {
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
  return Object.fromEntries(
    accounts.map((a) => [a.external_ref, { id: a.id, rf: refs?.find((r) => r.account_id === a.id)?.rf ?? "" }]),
  );
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

async function statusOf(payment: string): Promise<string> {
  const { data } = await adminClient().from("payment").select("status").eq("id", payment).single();
  return data?.status ?? "";
}

async function importStatement(page: Page, name: string, xml: string) {
  await page.goto("/backoffice/encaissements");
  const form = page.getByTestId("statement-upload");
  await form.getByLabel("Relevé CAMT.053 (XML)").setInputFiles({ name, mimeType: "application/xml", buffer: Buffer.from(xml, "utf-8") });
  await form.getByRole("button", { name: "Importer le relevé" }).click();
  await expect(page.getByTestId("statement-status")).toHaveText("Importé", { timeout: 60_000 });
}

test("refund, bank return, lines to classify, direct payment and the checks", async ({ page }, testInfo) => {
  test.setTimeout(360_000);
  await loginAsStaff(page, await createMember(tenant.servicerId, "ops_manager"));
  await boardAndConfirm(page);
  const f = await files();
  const credits: Credit[] = [
    // 1 200,00 € on a 1 000,00 € file: 200,00 € left for the payer (founder #8)
    { ref: "DB-1", amountMinor: BigInt(120000), name: "DIALLO", iban: ibanFr(31), rf: f["C2929"].rf },
    // Rivière pays in full; its bank will take the money back
    { ref: "DB-2", amountMinor: BigInt(100000), name: "RIVIERE ET FILS", iban: ibanFr(32), rf: f["C3945"].rf, e2e: "E2E-RIV-0001" },
  ];
  await importStatement(page, "releve-debits-1.xml", camt053(BANK_IBAN, "2026-11-03", credits));

  // Diallo: the overpayment is refunded to the payer's IBAN; nothing is booked until the bank's debit
  const diallo = await paymentOf("DB-1");
  await page.goto(`/backoffice/encaissements/paiements/${diallo}`);
  await expect(page.getByTestId("payment-status")).toHaveText("Imputé en partie", { timeout: 60_000 });
  await page.getByTestId("request-refund").getByRole("button", { name: "Rembourser" }).click();
  const sheet = page.getByRole("dialog", { name: "Rembourser le payeur" });
  await expect(sheet.getByLabel("Montant à rembourser (€)")).toHaveValue("200,00");
  await expect(sheet.getByLabel(/Le payeur \(DIALLO, IBAN …/)).toBeChecked();
  await expect(sheet.getByLabel("Motif du remboursement")).toHaveValue("overpayment");
  await sheet.getByLabel("Précisions (internes)").fill("Trop-perçu signalé par le débiteur");
  await sheet.getByRole("button", { name: "Demander le remboursement" }).click();
  await expect(page.getByTestId("payment-status")).toHaveText("Remboursement demandé");
  const reference = (await page.getByTestId("refund-reference").textContent())?.trim() ?? "";
  expect(reference).toMatch(/^RFD[0-9A-F]{12}$/);
  await expect(page.getByTestId("refund-row")).toContainText("À exécuter dans la banque");
  await reviewShot(page, testInfo, "m2-payment-refund");

  // The next statement: the refund executed, Rivière's payment returned, a fee, a return nobody can name
  const debits: Debit[] = [
    { ref: "DB-3", amountMinor: BigInt(20000), kind: "refund", e2e: reference, name: "DIALLO" },
    { ref: "DB-4", amountMinor: BigInt(100000), kind: "return", e2e: "E2E-RIV-0001", name: "RIVIERE ET FILS" },
    { ref: "DB-5", amountMinor: BigInt(290), kind: "fee" },
    { ref: "DB-6", amountMinor: BigInt(5000), kind: "return", e2e: "E2E-INCONNU-01" },
    { ref: "DB-7", amountMinor: BigInt(1200), kind: "other" },
  ];
  await importStatement(page, "releve-debits-2.xml", camt053Lines(BANK_IBAN, "2026-11-05", [], debits, BigInt(220000)));
  const riviere = await paymentOf("DB-2");
  await expect.poll(() => statusOf(diallo), { timeout: 60_000 }).toBe("allocated");
  await expect.poll(() => statusOf(riviere), { timeout: 60_000 }).toBe("returned");

  await page.goto(`/backoffice/encaissements/paiements/${diallo}`);
  await expect(page.getByTestId("payment-status")).toHaveText("Imputé");
  await expect(page.getByTestId("refund-row")).toContainText("Exécuté");
  await expect(page.getByTestId("bank-line-row")).toContainText("Remboursement exécuté");

  // Rivière: allocation undone on the return date, receipt cancelled (final), the client told
  await page.goto(`/backoffice/encaissements/paiements/${riviere}`);
  await expect(page.getByTestId("payment-status")).toHaveText("Retourné par la banque");
  await expect(page.getByTestId("bank-line-row")).toContainText("Retour du paiement par la banque");
  await expect(page.getByTestId("bank-line-row")).toContainText("motif bancaire MD06");
  await expect(page.getByTestId("payment-entries")).toContainText("Imputation annulée");
  await expect(page.getByTestId("payment-entries")).toContainText("au 05/11/2026");
  await expect(page.getByTestId("receipt-version")).toHaveCount(2, { timeout: 60_000 });
  await expect(page.getByTestId("receipt-version").first()).toContainText("Annulée");
  await expect(page.getByTestId("payment-notifications")).toContainText("Paiement retourné par la banque");
  await expect(page.getByTestId("payment-allocation")).toContainText("Rien n'est imputé");
  await reviewShot(page, testInfo, "m2-payment-returned");

  // « Débits et retours »: the return nobody can name; the bank's coded charge booked by the job (M2c-1)
  await page.goto("/backoffice/encaissements");
  await expect(page.getByTestId("debits-link")).toContainText("1 à classer");
  await page.getByTestId("debits-link").click();
  await expect(page).toHaveURL(/\/backoffice\/encaissements\/debits$/);
  const row = page.getByTestId("debit-row");
  await expect(row).toHaveCount(1);
  await expect(row).toContainText(n("− 50,00 €"));
  await expect(row.getByTestId("debit-review")).toContainText("Aucun paiement ni remboursement");
  await reviewShot(page, testInfo, "m2-debits");
  await row.getByTestId("explain").getByRole("button", { name: "Classer sans comptabiliser" }).click();
  const explain = page.getByRole("dialog", { name: "Classer sans comptabiliser" });
  await explain.getByLabel("Explication (interne)").fill("Rejet d'un prélèvement de frais, hors fonds de tiers");
  await explain.getByRole("button", { name: "Classer" }).click();
  await expect(page.getByTestId("debit-list")).toContainText("Aucune ligne.");
  // M2c-1: a debit the bank did not code as a charge, booked by ops as a bank fee (the servicer's cost)
  await page.getByRole("link", { name: "Frais et autres débits" }).click();
  const fee = page.getByTestId("debit-row");
  await expect(fee).toHaveCount(1);
  await expect(fee).toContainText(n("− 12,00 €"));
  await reviewShot(page, testInfo, "m2c-debits-fees");
  await fee.getByTestId("book-fee").getByRole("button", { name: "Frais bancaires" }).click();
  const feeSheet = page.getByRole("dialog", { name: "Frais bancaires" });
  await expect(feeSheet.getByTestId("sheet-effect")).toContainText("à la charge du cabinet");
  await feeSheet.getByLabel("Motif (interne)").fill("Abonnement de banque en ligne");
  await feeSheet.getByRole("button", { name: "Comptabiliser" }).click();
  await expect(page.getByTestId("debit-list")).toContainText("Aucune ligne.");
  await page.getByRole("link", { name: "Traités" }).click();
  await expect(page.getByTestId("debit-row")).toHaveCount(5);
  await expect(page.getByTestId("debit-list")).toContainText("Frais bancaires (à la charge du cabinet)");
  await expect(page.getByTestId("debit-row").filter({ hasText: n("− 2,90 €") })).toContainText("Frais bancaires");

  // A payment the debtor made to the client directly: Verdier paid 300,00 € on F2026-00103, says the client's statement
  const verdier = f["C9313"].id;
  const { error: docError } = await adminClient().from("document").insert({
    organization_id: tenant.servicerId,
    client_organization_id: tenant.clientId,
    account_id: verdier,
    kind: "releve_client",
    storage_path: `e2e/${verdier}/releve-client.pdf`,
    sha256: "c".repeat(64),
    mime_type: "application/pdf",
  });
  if (docError) throw docError;
  await page.goto(`/backoffice/dossiers/${verdier}`);
  await page.getByTestId("direct-payment").getByRole("button", { name: "Déclarer un paiement direct au client" }).click();
  const direct = page.getByRole("dialog", { name: "Paiement reçu directement par le client" });
  await direct.getByLabel("Montant payé au client (€)").fill("300,00");
  await direct.getByLabel("Date du paiement (relevé du client)").fill("2026-10-20");
  await direct.getByLabel("F2026-00103").check();
  await direct.getByRole("combobox", { name: /^Relevé du client/ }).selectOption({ index: 1 });
  await direct.getByLabel("Motif (interne)").fill("Relevé du client du 31/10");
  await direct.getByRole("button", { name: "Enregistrer" }).click();
  await expect(page.getByTestId("direct-payment-status")).toHaveText("Comptabilisé", { timeout: 60_000 });
  await expect(page.getByTestId("direct-payment-lines")).toContainText("F2026-00103");
  await expect(page.getByTestId("direct-payment-lines")).toContainText("300,00");
  await reviewShot(page, testInfo, "m2-file-direct-payment");

  // The nightly checks, run now: the books hold
  await page.goto("/backoffice/encaissements/controles");
  await page.getByTestId("run-checks").getByRole("button", { name: "Lancer les contrôles" }).click();
  await expect
    .poll(
      async () => {
        await page.reload();
        return page.getByTestId("check-violations").count();
      },
      { timeout: 60_000 },
    )
    .toBe(1);
  await expect(page.getByTestId("check-violations")).toContainText("0");
  // M2c-1: the bank fees booked on the dedicated account are the servicer's cost: the checks ask for a top-up from the
  // own account (an alert, not a violation)
  await expect(page.getByTestId("check-results")).toContainText("Approvisionnement du compte dédié à demander");
  await reviewShot(page, testInfo, "m2-payment-checks");

  // the client was told of the return (R124-5; founder #13)
  const { data: told } = await adminClient().from("client_notification").select("kind, reason").eq("payment_id", riviere);
  expect((told ?? []).map((x) => `${x.kind}/${x.reason}`).sort()).toEqual([
    "payment_allocated/null",
    "payment_allocation_reversed/bank_return",
    "payment_returned/bank_return",
  ]);
});
