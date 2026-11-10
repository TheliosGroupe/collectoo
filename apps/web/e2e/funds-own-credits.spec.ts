import { expect, test } from "@playwright/test";
import { adminClient, createMandate, createMember, createTenant, type Tenant } from "./support/admin";
import { camt053Lines, ibanFr, type Credit, type Debit } from "./support/camt";
import { loginAsStaff } from "./support/session";
import { reviewShot } from "./screenshot";

/**
 * M2c-1 review: our own transfers and credits on « Débits et retours ». A statement of the dedicated account carries a
 * debtor's payment, a transfer out with our RMT reference and a credit from the servicer's own account (no top-up
 * ordered). « À classer » offers no « Retour du paiement » nor refund link on our transfer or our credit (the database
 * refuses them), even though a payment of a larger amount is on the account. The credit is a debtor's payment the
 * servicer received on its own account: ops release it as « Paiement d'un débiteur relayé par le cabinet », with a
 * motif, and it waits in « Paiements à traiter » to be assigned. Synthetic data.
 */
const BANK_IBAN = ibanFr(575757);
const OWN_IBAN = ibanFr(585858);
const n = (text: string) => text.replace(/(\d) (\d)/g, "$1 $2");

let tenant: Tenant;

test.beforeAll(async () => {
  tenant = await createTenant();
  await createMandate(tenant);
  const admin = adminClient();
  const { error } = await admin.from("bank_account").insert([
    {
      organization_id: tenant.servicerId,
      iban: BANK_IBAN,
      currency: "EUR",
      label: "Fonds de tiers – Banque F",
      purpose: "client_funds", // a bulk insert sends every column: unset ones would be null, not their default
      feed: "camt053",
      opened_on: "2026-01-01",
    },
    {
      organization_id: tenant.servicerId,
      iban: OWN_IBAN,
      currency: "EUR",
      label: "Compte propre – Banque F",
      purpose: "own",
      feed: null,
      opened_on: "2026-01-01",
    },
  ]);
  if (error) throw error;
});

test("our own transfers offer no payment links; a debtor's payment relayed by the servicer becomes a payment", async ({
  page,
}, testInfo) => {
  test.setTimeout(240_000);
  await loginAsStaff(page, await createMember(tenant.servicerId, "ops_manager"));
  const credits: Credit[] = [
    // a debtor's payment (no file yet): the amount the old page offered to link our transfer out to
    { ref: "OC-1", amountMinor: BigInt(100000), name: "MARTIN JEAN", iban: ibanFr(41) },
    // from the servicer's own account, no top-up ordered: a debtor's payment the servicer relays
    { ref: "OC-2", amountMinor: BigInt(30000), name: "CABINET COLLECTOO", iban: OWN_IBAN, ustrd: ["VERSEMENT DEBITEUR"] },
  ];
  // our transfer out (RMT reference): rendered with its end-to-end id, as a transfer the bank executed
  const debits: Debit[] = [{ ref: "OC-3", amountMinor: BigInt(50000), kind: "refund", e2e: "RMT0123456789AB", name: "CABINET" }];
  await page.goto("/backoffice/encaissements");
  const form = page.getByTestId("statement-upload");
  await form.getByLabel("Relevé CAMT.053 (XML)").setInputFiles({
    name: "releve-compte-propre.xml",
    mimeType: "application/xml",
    buffer: Buffer.from(camt053Lines(BANK_IBAN, "2026-11-04", credits, debits, BigInt(0)), "utf-8"),
  });
  await form.getByRole("button", { name: "Importer le relevé" }).click();
  await expect(page.getByTestId("statement-status")).toHaveText("Importé", { timeout: 60_000 });

  await page.goto("/backoffice/encaissements/debits");
  const rows = page.getByTestId("debit-row");
  await expect(rows).toHaveCount(2, { timeout: 60_000 });
  const transfer = rows.filter({ hasText: "Virement émis par le cabinet" });
  const own = rows.filter({ hasText: "Virement reçu du compte propre" });
  await expect(transfer).toContainText(n("− 500,00 €"));
  await expect(own).toContainText("300,00");
  // no « Retour du paiement » nor refund link on our transfer out or our credit (review M2c-1)
  for (const row of [transfer, own]) {
    await expect(row.getByTestId("link-return")).toHaveCount(0);
    await expect(row.getByTestId("link-refund")).toHaveCount(0);
    await expect(row.getByTestId("explain")).toHaveCount(1);
  }
  await expect(own.getByTestId("book-top-up")).toHaveCount(1);

  // the credit relays a debtor's payment: it becomes a payment, with ops' motif
  await own.getByTestId("release-own-credit").getByRole("button", { name: "Paiement d'un débiteur relayé par le cabinet" }).click();
  const sheet = page.getByRole("dialog", { name: "Paiement d'un débiteur relayé par le cabinet" });
  await expect(sheet.getByTestId("sheet-effect")).toContainText("« Paiements à traiter »");
  await expect(sheet.getByTestId("sheet-effect")).toContainText("au 04/11/2026");
  await sheet.getByLabel("Motif (interne)").fill("Virement de M. Martin reçu par erreur sur le compte propre le 03/11");
  await reviewShot(page, testInfo, "m2c-own-credit-relay");
  await sheet.getByRole("button", { name: "Créer le paiement" }).click();
  await expect(rows).toHaveCount(1);
  await expect(rows).toContainText("Virement émis par le cabinet");

  // « Paiements à traiter »: the relayed payment waits to be assigned to the debtor's file
  await page.goto("/backoffice/encaissements/a-traiter");
  const relayed = page.getByTestId("queue-card").filter({ hasText: "Versement relayé par le cabinet" });
  await expect(relayed).toHaveCount(1);
  await expect(relayed.getByTestId("queue-amount")).toContainText("300,00");
});
