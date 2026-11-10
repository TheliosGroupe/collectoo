import { expect, test } from "@playwright/test";
import {
  adminClient,
  createConfirmedPayoutAccount,
  createMandate,
  createMember,
  createTenant,
  type Tenant,
} from "./support/admin";
import { camt053Lines, ibanFr, type Credit, type Debit } from "./support/camt";
import { loginAsStaff } from "./support/session";
import { reviewShot } from "./screenshot";

/**
 * M2c-1 review: our own transfers and credits on « Débits et retours ». A statement of the dedicated account carries a
 * debtor's payment, a transfer out with our RMT reference and a credit from the servicer's own account (no top-up
 * ordered). « À classer » offers no « Retour du paiement » nor refund link on our transfer or our credit (the database
 * refuses them), even though a payment of a larger amount is on the account. The credit is a debtor's payment the
 * servicer received on its own account: ops release it as « Paiement d'un débiteur relayé par le cabinet », with a
 * motif, and it waits in « Paiements à traiter » to be assigned. Review M2c-2: a credit from a client's confirmed payout
 * IBAN (read as the client's at import) may be a debtor's payment the client relays: « Paiement d'un débiteur relayé par
 * le client », the same sheet and the same command. Synthetic data.
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

test("a debtor's payment relayed by the client, from its confirmed payout IBAN, becomes a payment", async ({ page }, testInfo) => {
  test.setTimeout(240_000);
  // a tenant of its own: its dedicated account receives one statement here
  const own = await createTenant();
  await createMandate(own);
  const seed = Number.parseInt(own.clientId.slice(0, 6), 16);
  const bankIban = ibanFr(seed);
  const clientIban = ibanFr(seed + 7);
  const { error } = await adminClient().from("bank_account").insert({
    organization_id: own.servicerId,
    iban: bankIban,
    currency: "EUR",
    label: "Fonds de tiers – Banque R",
    purpose: "client_funds",
    feed: "camt053",
    opened_on: "2026-01-01",
  });
  if (error) throw error;
  await createConfirmedPayoutAccount(own, clientIban, own.clientName.toUpperCase());
  await loginAsStaff(page, await createMember(own.servicerId, "ops_manager"));

  const credits: Credit[] = [
    { ref: "CR-1", amountMinor: BigInt(12000), name: own.clientName.toUpperCase(), iban: clientIban, ustrd: ["REGLEMENT CLIENT DUPONT"] },
  ];
  await page.goto("/backoffice/encaissements");
  const form = page.getByTestId("statement-upload");
  await form.getByLabel("Relevé CAMT.053 (XML)").setInputFiles({
    name: "releve-client.xml",
    mimeType: "application/xml",
    buffer: Buffer.from(camt053Lines(bankIban, "2026-11-06", credits, [], BigInt(0)), "utf-8"),
  });
  await form.getByRole("button", { name: "Importer le relevé" }).click();
  await expect(page.getByTestId("statement-status")).toHaveText("Importé", { timeout: 60_000 });

  // never taken for a debtor's payment automatically: the line waits in « À classer »
  await page.goto("/backoffice/encaissements/debits");
  const row = page.getByTestId("debit-row").filter({ hasText: "Virement reçu d'un client" });
  await expect(row).toHaveCount(1, { timeout: 60_000 });
  await expect(row).toContainText("120,00");
  await expect(row.getByTestId("link-return")).toHaveCount(0);
  await expect(row.getByTestId("release-own-credit")).toHaveCount(0);
  await row.getByTestId("release-client-credit").getByRole("button", { name: "Paiement d'un débiteur relayé par le client" }).click();
  const sheet = page.getByRole("dialog", { name: "Paiement d'un débiteur relayé par le client" });
  await expect(sheet.getByTestId("sheet-effect")).toContainText("venant du compte de reversement d'un client");
  await expect(sheet.getByTestId("sheet-effect")).toContainText("au 06/11/2026");
  await sheet.getByLabel("Motif (interne)").fill("Le client relaie le virement de M. Dupont reçu sur son compte le 05/11");
  await reviewShot(page, testInfo, "m2c-client-credit-relay");
  await sheet.getByRole("button", { name: "Créer le paiement" }).click();
  await expect(page.getByTestId("debit-row")).toHaveCount(0);

  // « Paiements à traiter »: the relayed payment waits to be assigned to the debtor's file
  await page.goto("/backoffice/encaissements/a-traiter");
  const relayed = page.getByTestId("queue-card").filter({ hasText: "Versement relayé par le client" });
  await expect(relayed).toHaveCount(1);
  await expect(relayed.getByTestId("queue-amount")).toContainText("120,00");
});
