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
import { expectOwnImport } from "./support/statements";

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
  await loginAsStaff(
    page,
    await createMember(tenant.servicerId, "ops_manager"),
  );
  const credits: Credit[] = [
    // a debtor's payment (no file yet): the amount the old page offered to link our transfer out to
    {
      ref: "OC-1",
      amountMinor: BigInt(100000),
      name: "MARTIN JEAN",
      iban: ibanFr(41),
    },
    // from the servicer's own account, no top-up ordered: a debtor's payment the servicer relays
    {
      ref: "OC-2",
      amountMinor: BigInt(30000),
      name: "CABINET COLLECTOO",
      iban: OWN_IBAN,
      ustrd: ["VERSEMENT DEBITEUR"],
    },
  ];
  // our transfer out (RMT reference): rendered with its end-to-end id, as a transfer the bank executed
  const debits: Debit[] = [
    {
      ref: "OC-3",
      amountMinor: BigInt(50000),
      kind: "refund",
      e2e: "RMT0123456789AB",
      name: "CABINET",
    },
  ];
  await page.goto("/backoffice/encaissements");
  const form = page.getByTestId("statement-upload");
  await form.getByLabel("Relevé CAMT.053 (XML)").setInputFiles({
    name: "releve-compte-propre.xml",
    mimeType: "application/xml",
    buffer: Buffer.from(
      camt053Lines(BANK_IBAN, "2026-11-04", credits, debits, BigInt(0)),
      "utf-8",
    ),
  });
  await form.getByRole("button", { name: "Importer le relevé" }).click();
  await expectOwnImport(page);

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
  }
  // M2c-6b-1: our RMT debit is booked from the statement, never « explained » away (not_explainable); it waits for
  // ops as a P0 review (an RMT id no transfer of ours carries); our credit can still be explained
  await expect(transfer.getByTestId("explain")).toHaveCount(0);
  await expect(transfer.getByTestId("debit-review-p0")).toHaveCount(1);
  await expect(own.getByTestId("explain")).toHaveCount(1);
  await expect(own.getByTestId("book-top-up")).toHaveCount(1);

  // the credit relays a debtor's payment: it becomes a payment, with ops' motif
  await own
    .getByTestId("release-own-credit")
    .getByRole("button", {
      name: "Paiement d'un débiteur relayé par le cabinet",
    })
    .click();
  const sheet = page.getByRole("dialog", {
    name: "Paiement d'un débiteur relayé par le cabinet",
  });
  await expect(sheet.getByTestId("sheet-effect")).toContainText(
    "« Paiements à traiter »",
  );
  await expect(sheet.getByTestId("sheet-effect")).toContainText(
    "au 04/11/2026",
  );
  await sheet
    .getByLabel("Motif (interne)")
    .fill(
      "Virement de M. Martin reçu par erreur sur le compte propre le 03/11",
    );
  await reviewShot(page, testInfo, "m2c-own-credit-relay");
  await sheet.getByRole("button", { name: "Créer le paiement" }).click();
  await expect(rows).toHaveCount(1);
  await expect(rows).toContainText("Virement émis par le cabinet");

  // « Paiements à traiter »: the relayed payment waits to be assigned to the debtor's file
  await page.goto("/backoffice/encaissements/a-traiter");
  const relayed = page
    .getByTestId("queue-card")
    .filter({ hasText: "Versement relayé par le cabinet" });
  await expect(relayed).toHaveCount(1);
  await expect(relayed.getByTestId("queue-amount")).toContainText("300,00");
});

test("a debtor's payment relayed by the client, from its confirmed payout IBAN, becomes a payment", async ({
  page,
}, testInfo) => {
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
  await createConfirmedPayoutAccount(
    own,
    clientIban,
    own.clientName.toUpperCase(),
  );
  await loginAsStaff(page, await createMember(own.servicerId, "ops_manager"));

  const credits: Credit[] = [
    {
      ref: "CR-1",
      amountMinor: BigInt(12000),
      name: own.clientName.toUpperCase(),
      iban: clientIban,
      ustrd: ["REGLEMENT CLIENT DUPONT"],
    },
  ];
  await page.goto("/backoffice/encaissements");
  const form = page.getByTestId("statement-upload");
  await form.getByLabel("Relevé CAMT.053 (XML)").setInputFiles({
    name: "releve-client.xml",
    mimeType: "application/xml",
    buffer: Buffer.from(
      camt053Lines(bankIban, "2026-11-06", credits, [], BigInt(0)),
      "utf-8",
    ),
  });
  await form.getByRole("button", { name: "Importer le relevé" }).click();
  await expectOwnImport(page);

  // never taken for a debtor's payment automatically: the line waits in « À classer »
  await page.goto("/backoffice/encaissements/debits");
  const row = page
    .getByTestId("debit-row")
    .filter({ hasText: "Virement reçu d'un client" });
  await expect(row).toHaveCount(1, { timeout: 60_000 });
  await expect(row).toContainText("120,00");
  await expect(row.getByTestId("link-return")).toHaveCount(0);
  await expect(row.getByTestId("release-own-credit")).toHaveCount(0);
  await row
    .getByTestId("release-client-credit")
    .getByRole("button", {
      name: "Paiement d'un débiteur relayé par le client",
    })
    .click();
  const sheet = page.getByRole("dialog", {
    name: "Paiement d'un débiteur relayé par le client",
  });
  await expect(sheet.getByTestId("sheet-effect")).toContainText(
    "venant du compte de reversement d'un client",
  );
  await expect(sheet.getByTestId("sheet-effect")).toContainText(
    "au 06/11/2026",
  );
  await sheet
    .getByLabel("Motif (interne)")
    .fill(
      "Le client relaie le virement de M. Dupont reçu sur son compte le 05/11",
    );
  await reviewShot(page, testInfo, "m2c-client-credit-relay");
  await sheet.getByRole("button", { name: "Créer le paiement" }).click();
  await expect(page.getByTestId("debit-row")).toHaveCount(0);

  // « Paiements à traiter »: the relayed payment waits to be assigned to the debtor's file
  await page.goto("/backoffice/encaissements/a-traiter");
  const relayed = page
    .getByTestId("queue-card")
    .filter({ hasText: "Versement relayé par le client" });
  await expect(relayed).toHaveCount(1);
  await expect(relayed.getByTestId("queue-amount")).toContainText("120,00");
});

/**
 * Review M2c-6b-1 round 3 (M1, M2): one of our transfers coming back without the bank's return flag — the sweep's SWP
 * id on a credit from our own account, a payout's RMT id on a credit from the client's payout IBAN (as a CSV feed whose
 * label misses RETURN_RE reads them, or a camt.053 without a return code) — is neither a top-up nor a debtor's payment
 * relayed by the servicer or the client, nor classified without booking: the database refuses each (own_transfer_line)
 * and « À classer » offers none, saying what the line is (booked by ops with M2c-6b-2's line booking). Synthetic data.
 */
test("a credit carrying our SWP or RMT id, unflagged, is neither a top-up nor a relayed payment (review round 3)", async ({
  page,
}, testInfo) => {
  test.setTimeout(240_000);
  const own = await createTenant();
  await createMandate(own);
  const seed = Number.parseInt(own.clientId.slice(0, 6), 16);
  const bankIban = ibanFr(seed + 11);
  const ownIban = ibanFr(seed + 13);
  const clientIban = ibanFr(seed + 17);
  const { error } = await adminClient().from("bank_account").insert([
    {
      organization_id: own.servicerId,
      iban: bankIban,
      currency: "EUR",
      label: "Fonds de tiers – Banque S",
      purpose: "client_funds",
      feed: "camt053",
      opened_on: "2026-01-01",
    },
    {
      organization_id: own.servicerId,
      iban: ownIban,
      currency: "EUR",
      label: "Compte propre – Banque S",
      purpose: "own",
      feed: null,
      opened_on: "2026-01-01",
    },
  ]);
  if (error) throw error;
  await createConfirmedPayoutAccount(
    own,
    clientIban,
    own.clientName.toUpperCase(),
  );
  await loginAsStaff(page, await createMember(own.servicerId, "ops_manager"));

  const credits: Credit[] = [
    // the sweep back from our own account (its SWP id), unflagged: read as a credit from the own account
    {
      ref: "OR-1",
      amountMinor: BigInt(45000),
      name: "CABINET COLLECTOO",
      iban: ownIban,
      e2e: "SWP0123456789AB",
      ustrd: ["QUOTE-PART CABINET"],
    },
    // a payout back from the client's payout IBAN (its RMT id), unflagged: read as a credit from a client
    {
      ref: "OR-2",
      amountMinor: BigInt(27000),
      name: own.clientName.toUpperCase(),
      iban: clientIban,
      e2e: "RMT0A1B2C3D4E5F",
      ustrd: ["REVERSEMENT"],
    },
  ];
  await page.goto("/backoffice/encaissements");
  const form = page.getByTestId("statement-upload");
  await form.getByLabel("Relevé CAMT.053 (XML)").setInputFiles({
    name: "releve-retours-non-signales.xml",
    mimeType: "application/xml",
    buffer: Buffer.from(
      camt053Lines(bankIban, "2026-11-09", credits, [], BigInt(0)),
      "utf-8",
    ),
  });
  await form.getByRole("button", { name: "Importer le relevé" }).click();
  await expectOwnImport(page);

  await page.goto("/backoffice/encaissements/debits");
  const rows = page.getByTestId("debit-row");
  await expect(rows).toHaveCount(2, { timeout: 60_000 });
  const fromOwn = rows.filter({ hasText: "Virement reçu du compte propre" });
  const fromClient = rows.filter({ hasText: "Virement reçu d'un client" });
  await expect(fromOwn).toContainText("450,00");
  await expect(fromClient).toContainText("270,00");
  for (const row of [fromOwn, fromClient]) {
    await expect(row.getByTestId("book-top-up")).toHaveCount(0);
    await expect(row.getByTestId("release-own-credit")).toHaveCount(0);
    await expect(row.getByTestId("release-client-credit")).toHaveCount(0);
    await expect(row.getByTestId("explain")).toHaveCount(0);
    await expect(row.getByTestId("link-return")).toHaveCount(0);
    await expect(row.getByTestId("link-refund")).toHaveCount(0);
    await expect(row.getByTestId("debit-review")).toContainText(
      "c'est ce virement qui revient, sans que la banque l'ait signalé comme un retour",
    );
  }
  await reviewShot(page, testInfo, "m6b1-our-credit-unflagged");
});

/**
 * Review M2c-6b-1 round 4 (N1): the same transfers coming back from an IBAN that is neither ours nor a client's (or from
 * a CSV without the IBAN column) were read as debtors' credits and became payments to assign — our own money matched to
 * a debtor's file. Now the import reads them as returns (COMPLIANCE OQ-84): no payment in « Paiements à traiter »; in
 * « À classer », the debit job's reason worded for a credit (no transfer of ours by that id here), and no action.
 * Synthetic data.
 */
test("a credit carrying our SWP or RMT id from an unknown IBAN is a return, never a payment (review round 4)", async ({
  page,
}, testInfo) => {
  test.setTimeout(240_000);
  const own = await createTenant();
  await createMandate(own);
  const seed = Number.parseInt(own.clientId.slice(0, 6), 16);
  const bankIban = ibanFr(seed + 21);
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
  await loginAsStaff(page, await createMember(own.servicerId, "ops_manager"));

  const credits: Credit[] = [
    { ref: "UR-1", amountMinor: BigInt(45000), name: "BANQUE X", iban: ibanFr(seed + 23), e2e: "SWP0123456789AB", ustrd: ["RETOUR FONDS"] },
    { ref: "UR-2", amountMinor: BigInt(27000), name: "BANQUE Y", iban: ibanFr(seed + 29), e2e: "RMT0A1B2C3D4E5F", ustrd: ["REVERSEMENT"] },
  ];
  await page.goto("/backoffice/encaissements");
  const form = page.getByTestId("statement-upload");
  await form.getByLabel("Relevé CAMT.053 (XML)").setInputFiles({
    name: "releve-retours-iban-inconnu.xml",
    mimeType: "application/xml",
    buffer: Buffer.from(camt053Lines(bankIban, "2026-11-09", credits, [], BigInt(0)), "utf-8"),
  });
  await form.getByRole("button", { name: "Importer le relevé" }).click();
  await expectOwnImport(page);

  // no payment to assign
  await page.goto("/backoffice/encaissements/a-traiter");
  await expect(page.getByText("Aucun paiement à traiter : tous les encaissements sont rattachés à un dossier.")).toBeVisible();

  // the debit job's funds pass leaves both to ops with why (reloaded until it has run)
  const unknown = "Crédit portant la référence d'un virement du cabinet (RMT, SWP) que Collectoo ne connaît pas";
  const rows = page.getByTestId("debit-row");
  await expect(async () => {
    await page.goto("/backoffice/encaissements/debits");
    await expect(rows).toHaveCount(2);
    await expect(rows.getByTestId("debit-review").filter({ hasText: unknown })).toHaveCount(2);
  }).toPass({ timeout: 90_000 });
  for (const row of [rows.filter({ hasText: "450,00" }), rows.filter({ hasText: "270,00" })]) {
    await expect(row).toContainText("Crédit annulant un débit");
    await expect(row.getByTestId("debit-review")).toContainText(unknown);
    for (const action of ["book-top-up", "release-own-credit", "release-client-credit", "explain", "link-return", "link-refund"])
      await expect(row.getByTestId(action)).toHaveCount(0);
  }
  await reviewShot(page, testInfo, "m6b1-our-credit-unknown-iban");
});
