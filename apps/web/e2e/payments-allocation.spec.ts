import { expect, test, type Page } from "@playwright/test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { adminClient, createMandate, createMember, createTenant, type Tenant } from "./support/admin";
import { camt053, ibanFr, type Credit } from "./support/camt";
import { loginAsStaff } from "./support/session";
import { reviewShot } from "./screenshot";

/**
 * M2b-4 (M2-09, M2-11): an ops manager boards three B2B files (synthetic invoices: one with a credit note),
 * imports the client-funds statement where they paid by their RF reference, and follows the allocation:
 * Verdier's payment waits for the credit note, applied from the file page in one tap (compensation invoked,
 * 1347), then pays the invoice it names, then due invoices oldest first; Diallo paid more than due: the rest
 * stays unallocated, never passed to the client; Rivière's payment is shared pro rata between two invoices
 * due the same day. A wrong allocation is reversed from the payment page and allocated again. Synthetic data.
 */
const BANK_IBAN = ibanFr(424242);
const DAY = "2026-11-02";
const FIXTURE = {
  name: "Créances avec avoir.csv",
  mimeType: "text/csv",
  buffer: readFileSync(path.resolve(__dirname, "fixtures/factures-imputation.csv")),
};

let tenant: Tenant;
/** An amount as the pages print it: thousands grouped by a narrow no-break space (formatMoneyFr). */
const n = (text: string) => text.replace(/(\d) (\d)/g, "$1\u202f$2");

test.beforeAll(async () => {
  tenant = await createTenant();
  await createMandate(tenant);
  const { error } = await adminClient().from("bank_account").insert({
    organization_id: tenant.servicerId,
    iban: BANK_IBAN,
    currency: "EUR",
    label: "Fonds de tiers – Banque B",
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

/** File id and RF reference per client account number, as the bank's payers know them. */
async function files(): Promise<Record<string, { id: string; rf: string }>> {
  const admin = adminClient();
  const { data: accounts, error } = await admin
    .from("account")
    .select("id, external_ref")
    .eq("portfolio_id", tenant.portfolioId);
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

/** The payment of a statement line (by the bank's line reference). */
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

test("ops follow how payments are allocated and act on them", async ({ page }, testInfo) => {
  test.setTimeout(300_000);
  await loginAsStaff(page, await createMember(tenant.servicerId, "ops_manager"));
  await boardAndConfirm(page);
  const f = await files();
  const verdier = f["C9313"];
  const credits: Credit[] = [
    // names the invoice F2026-00103; the file also has a credit note: it waits until ops apply it
    { ref: "AL-1", amountMinor: BigInt(200000), name: "VERDIER SAS", iban: ibanFr(11), ustrd: ["REGLT F2026-00103"], rf: verdier.rf },
    // 1 200,00 € on a 1 000,00 € file: 200,00 € over
    { ref: "AL-2", amountMinor: BigInt(120000), name: "DIALLO", iban: ibanFr(12), rf: f["C2929"].rf },
    // 300,01 € on two invoices due the same day: shared pro rata, the cent to the first by id
    { ref: "AL-3", amountMinor: BigInt(30001), name: "RIVIERE ET FILS", iban: ibanFr(13), rf: f["C3945"].rf },
  ];
  await page.goto("/backoffice/encaissements");
  const form = page.getByTestId("statement-upload");
  await form.getByLabel("Relevé CAMT.053 (XML)").setInputFiles({
    name: "releve-imputation.xml",
    mimeType: "application/xml",
    buffer: Buffer.from(camt053(BANK_IBAN, DAY, credits), "utf-8"),
  });
  await form.getByRole("button", { name: "Importer le relevé" }).click();
  await expect(page.getByTestId("statement-status")).toHaveText("Importé", { timeout: 60_000 });
  await expect(page.getByTestId("match-counts")).toContainText("Rapprochés automatiquement 100 %", { timeout: 60_000 });

  // The overpayment: allocated in part, the rest kept for the payer (founder #8)
  const diallo = await paymentOf("AL-2");
  await page.goto(`/backoffice/encaissements/paiements/${diallo}`);
  await expect(page.getByTestId("payment-status")).toHaveText("Imputé en partie", { timeout: 60_000 });
  await expect(page.getByTestId("payment-reason")).toHaveText("Trop-perçu");
  await expect(page.getByTestId("payment-allocated")).toContainText(n("1 000,00"));
  await expect(page.getByTestId("payment-unallocated")).toContainText("200,00");
  await expect(page.getByTestId("overpayment-note")).toContainText("n'est jamais reversé au client");
  await expect(page.getByTestId("payment-notifications")).toContainText("Informé de l'imputation");
  await reviewShot(page, testInfo, "m2-payment-overpayment");

  // Pro rata between two invoices due the same day
  await page.goto(`/backoffice/encaissements/paiements/${await paymentOf("AL-3")}`);
  await expect(page.getByTestId("payment-status")).toHaveText("Imputé", { timeout: 60_000 });
  const shares = await page.getByTestId("allocation-row").allTextContents();
  expect(shares.join(" ")).toContain("150,01");
  expect(shares.join(" ")).toContain("150,00");

  // Verdier: the credit note must be applied first (1347: compensation is invoked)
  const verdierPayment = await paymentOf("AL-1");
  await page.goto(`/backoffice/encaissements/paiements/${verdierPayment}`);
  await expect(page.getByTestId("payment-reason")).toHaveText("Avoir à appliquer", { timeout: 60_000 });
  await page.getByTestId("payment-file").getByRole("link").click();
  await expect(page).toHaveURL(new RegExp(`/backoffice/dossiers/${verdier.id}$`));
  const proposal = page.getByTestId("file-credit-note");
  await expect(proposal).toContainText("L'avoir F2026-00105 réglera F2026-00101 pour 200,00");
  await expect(proposal).toContainText("30/09/2026");
  await expect(page.getByTestId("file-balance")).toContainText(n("2 800,00"));
  await reviewShot(page, testInfo, "m2-file-credit-note");
  await proposal.getByRole("button", { name: "Appliquer l'avoir" }).click();
  const sheet = page.getByRole("dialog", { name: "Appliquer l'avoir" });
  await expect(sheet.getByTestId("sheet-effect")).toContainText("art. 1347");
  await sheet.getByRole("button", { name: "Confirmer" }).click();
  await expect(page.getByTestId("file-credit-note")).toHaveCount(0);

  // ... then the payment is allocated: F2026-00103 named first, then due invoices oldest first; F2026-00104 is
  // not due (15/12/2026) and is not reached
  await page.goto(`/backoffice/encaissements/paiements/${verdierPayment}`);
  await expect(page.getByTestId("payment-status")).toHaveText("Imputé", { timeout: 60_000 });
  const rows = page.getByTestId("allocation-row");
  await expect(rows).toHaveCount(3);
  await expect(rows.nth(0)).toContainText("F2026-00103");
  await expect(rows.nth(0)).toContainText("400,00");
  await expect(rows.nth(1)).toContainText("F2026-00101");
  await expect(rows.nth(1)).toContainText(n("1 300,00"));
  await expect(rows.nth(2)).toContainText("F2026-00102");
  await expect(rows.nth(2)).toContainText("300,00");
  await reviewShot(page, testInfo, "m2-payment-allocated");

  // A wrong allocation is reversed at its date (the client is told), then allocated again
  await page.getByTestId("reverse-allocation").getByRole("button").first().click();
  const reverse = page.getByRole("dialog", { name: "Annuler cette imputation" });
  await expect(reverse.getByTestId("sheet-effect")).toContainText(n("2 000,00"));
  await reviewShot(page, testInfo, "m2-payment-reverse-sheet");
  await reverse.getByLabel("Motif (gardé dans l'historique)").fill("Désignation à vérifier avec le débiteur");
  await reverse.getByRole("button", { name: "Confirmer l'annulation" }).click();
  await expect(page.getByTestId("payment-reason")).toHaveText("Imputation annulée");
  await expect(page.getByTestId("payment-allocation")).toContainText("Rien n'est imputé.");
  await expect(page.getByTestId("payment-notifications")).toContainText("Informé de l'annulation de l'imputation");
  await reviewShot(page, testInfo, "m2-payment-reversed");
  await page.getByTestId("reallocate").getByRole("button", { name: "Imputer" }).click();
  const again = page.getByRole("dialog", { name: "Imputer ce paiement" });
  await again.getByLabel("Motif (gardé dans l'historique)").fill("Désignation confirmée par le débiteur");
  await again.getByRole("button", { name: "Confirmer" }).click();
  await expect(page.getByTestId("payment-status")).toHaveText("Imputé", { timeout: 60_000 });
  await expect(rows).toHaveCount(3);

  // The file page: balances from the ledger, the payments
  await page.goto(`/backoffice/dossiers/${verdier.id}`);
  await expect(page.getByTestId("file-balance")).toHaveText(/^800,00/);
  await expect(page.getByTestId("file-rf")).toHaveText(verdier.rf.replace(/(.{4})(?=.)/g, "$1 "));
  await expect(page.getByTestId("file-payment")).toHaveCount(1);
  await reviewShot(page, testInfo, "m2-file");
});
