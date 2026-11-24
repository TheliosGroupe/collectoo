import { expect, test, type Page } from "@playwright/test";
import { readFileSync } from "node:fs";
import path from "node:path";
import {
  adminClient,
  createConfirmedPayoutAccount,
  createMandate,
  createMember,
  createOtherClient,
  createTenant,
  type Tenant,
} from "./support/admin";
import { camt053, camt053Lines, ibanFr, type Credit, type Debit } from "./support/camt";
import { loginAsStaff } from "./support/session";
import { reviewShot } from "./screenshot";
import { expectOwnImport } from "./support/statements";

/**
 * M2b-6: money leaving the client-funds account. An ops manager boards three B2B files (synthetic), imports the statement
 * where Diallo paid 200,00 € too much and Rivière paid in full, asks for the refund of Diallo's overpayment (our RFD
 * reference, nothing booked yet), then imports the next statement: the refund's debit (linked and booked), the bank's
 * return of Rivière's payment (its allocation undone on the return date, the receipt cancelled, the client told), a fee
 * (not booked: an explained gap) and a return nobody can name, which ops classify on « Débits et retours ». Then a
 * payment the debtor made to the client directly, declared on the file page, a debit carrying an RMT id Collectoo never
 * issued (M2c-6b-2d), and the nightly checks run on demand. M2c-6b-2d (plan §8.4): two clients' payouts in one transfer
 * file, the lot debited short of one of them (« Débit d'un lot de reversements »), the other payout debited with the
 * bank's charge on an entry kept unsplit (« Comptabiliser d'après le détail du relevé »). Synthetic data.
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
  await expectOwnImport(page);
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
  // M2c-6a (founder #15): the refund goes in the next transfer file by default (its RFD debit books it all the same)
  await expect(page.getByTestId("refund-row")).toContainText("Dans le fichier de virements");
  // the page says so too: a refund the file pays is never executed in the bank as well (risk R4: paid twice)
  await expect(page.getByTestId("refund-instruction")).toContainText("prochain fichier de virements");
  await expect(page.getByTestId("refund-instruction")).toContainText("ne l'exécutez pas dans la banque");
  await reviewShot(page, testInfo, "m2-payment-refund");

  // M2c-6a review round 6: the refund goes in a transfer file, downloaded and marked as sent — the bank may pay it
  // now, so « Annuler » is no longer offered (with the cancellation after download off, it waits for its debit)
  await page.goto("/backoffice/reversements/virements");
  const account = page.getByTestId("paying-account").filter({ hasText: "Fonds de tiers – Banque D" });
  await account.getByTestId("generate-file").getByRole("button", { name: "Générer le fichier" }).click();
  await page.getByRole("dialog", { name: "Générer le fichier de virements" }).getByRole("button", { name: "Générer", exact: true }).click();
  const fileRow = account.getByTestId("file-row").first();
  await expect(fileRow.getByTestId("file-status")).toHaveText("Prêt à télécharger", { timeout: 60_000 });
  await Promise.all([page.waitForEvent("download"), fileRow.getByTestId("file-download").click()]);
  await expect(fileRow.getByTestId("file-mark-sent")).toBeVisible({ timeout: 15_000 });
  await fileRow.getByTestId("file-mark-sent").getByRole("button", { name: "Marquer comme transmis" }).click();
  await expect(fileRow.getByTestId("file-status")).toHaveText("Transmis à la banque", { timeout: 15_000 });
  await page.goto(`/backoffice/encaissements/paiements/${diallo}`);
  const inFile = page.getByTestId("refund-in-downloaded-file");
  await expect(inFile).toContainText("déjà téléchargé");
  await expect(inFile).toContainText("« en cours »");
  await expect(inFile).toContainText("ne peut pas être annulé d'ici là");
  await expect(page.getByTestId("cancel-refund")).toHaveCount(0);
  // review round 7 (N2): the banner names that file, not « the next file »
  await expect(page.getByTestId("refund-instruction")).toContainText(/il est dans le fichier de virements TF-\d{4}-\d{6}, déjà téléchargé/);
  await expect(page.getByTestId("refund-instruction")).not.toContainText("prochain fichier");
  await reviewShot(page, testInfo, "m2-payment-refund-file");

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

  // M2c-6b-2d (plan §2.6, §7.5): a debit carrying a reference of the form of ours that names no transfer of ours (an RMT
  // id Collectoo never issued): the debit job books nothing and reviews it « Référence du cabinet inconnue » (P0)
  // (the list then holds three statements: the import is followed to the new statement's own page)
  await importOn(
    page,
    "releve-debits-3.xml",
    camt053Lines(
      BANK_IBAN,
      "2026-11-06",
      [],
      [{ ref: "DB-8", amountMinor: BigInt(4500), kind: "transfer", e2e: "RMT00000000E2E1", name: "INCONNU" }],
      BigInt(93510),
    ),
  );
  await page.goto("/backoffice/encaissements/debits");
  const unknown = page
    .getByTestId("debit-row")
    .filter({ hasText: n("− 45,00 €") })
    .filter({ has: page.getByTestId("debit-review-p0") });
  await expect(async () => {
    await page.reload();
    await expect(unknown).toHaveCount(1, { timeout: 2_000 });
  }).toPass({ timeout: 60_000 });
  await expect(unknown).toContainText("référence de virement du cabinet (RMT, SWP) ou un lot que Collectoo ne connaît pas");

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
  // M2c-6b-2a/2c alerts (plan §2.6, §7.5): the unknown reference (P0) and our debit lines left to ops for more than a
  // business day (bank_line_unbooked)
  await expect(page.locator('[data-testid="check-row"][data-code="transfer_unknown"]')).toContainText(
    "Référence du cabinet inconnue",
  );
  await expect(page.locator('[data-testid="check-row"][data-code="bank_line_unbooked"]')).toContainText(
    "Débits du cabinet non comptabilisés",
  );
  await reviewShot(page, testInfo, "m2-payment-checks");

  // the client was told of the return (R124-5; founder #13)
  const { data: told } = await adminClient().from("client_notification").select("kind, reason").eq("payment_id", riviere);
  expect((told ?? []).map((x) => `${x.kind}/${x.reason}`).sort()).toEqual([
    "payment_allocated/null",
    "payment_allocation_reversed/bank_return",
    "payment_returned/bank_return",
  ]);
});

// ---------------------------------------------------------------------------------------------------------------------
// M2c-6b-2d (plan §8.4, §7.3, §7.5; ADR-0014 « M2c-6b-2c carry-overs (in 6b-2d) »): two clients' payouts approved into
// one transfer file share its lot (one PmtInf). The bank debits the lot short of one of them (one line, the lot's
// PmtInfId, no detail): the debit job books nothing (batch_partial) and ops book it « Débit d'un lot de reversements »
// (the only subset of the lot that makes the line: the first payout; the second « non débité par cette ligne »). The
// bank then debits the second payout with its charge on one entry (the ISO shape: the charge in Chrgs, the transfer's
// amount in its one detail), which the import keeps unsplit with that detail: ops book it « Comptabiliser d'après le
// détail du relevé » (its payout and the bank's fee). Each booking is read back from the ledger's bookings, the runs and
// « Traités ».

/** Today in Europe/Paris (YYYY-MM-DD). */
function parisToday(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Paris" }).format(new Date());
}

/** The latest business day before today (as remittances.spec.ts: the collections' deadlines a month ahead). */
async function lastBusinessDay(): Promise<string> {
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

/** An ISO 20022 amount (« 410.00 ») in minor units, as an exact integer (never a float). */
function minorOf(text: string): bigint {
  const [units, cents = ""] = text.split(".");
  return BigInt(units) * BigInt(100) + BigInt(cents.padEnd(2, "0"));
}

/** An amount as the pages print it (« 410,00 € », thousands with a narrow space). */
function euros(minor: bigint): string {
  const units = (minor / BigInt(100)).toString().replace(/\B(?=(\d{3})+(?!\d))/g, " ");
  return n(`${units},${(minor % BigInt(100)).toString().padStart(2, "0")} €`);
}

/** A boarding into one of the servicer's portfolios (several exist: chosen by its label). */
async function boardInto(page: Page, t: Tenant) {
  await page.goto("/backoffice/reprises/nouveau");
  await page.locator('select[name="portfolio"]').selectOption({ label: `${t.clientName} · ${t.portfolioName}` });
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

async function rfIn(t: Tenant, externalRef: string): Promise<string> {
  const admin = adminClient();
  const { data: account, error } = await admin
    .from("account")
    .select("id")
    .eq("portfolio_id", t.portfolioId)
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

/** A statement imported from « Encaissements »; the import leads to its own page once read. */
async function importOn(page: Page, name: string, xml: string) {
  await page.goto("/backoffice/encaissements");
  const form = page.getByTestId("statement-upload");
  await form
    .getByLabel("Relevé CAMT.053 (XML)")
    .setInputFiles({ name, mimeType: "application/xml", buffer: Buffer.from(xml, "utf-8") });
  await form.getByRole("button", { name: "Importer le relevé" }).click();
  await expect(page).toHaveURL(/\/backoffice\/encaissements\/releves\/[0-9a-f-]{36}/, { timeout: 30_000 });
  await expectOwnImport(page);
}

/** A client's run prepared now (or by the hourly schedule, if it came first) and approved from its page. */
async function prepareAndApprove(page: Page, t: Tenant): Promise<string> {
  await page.goto("/backoffice/reversements");
  const waiting = page.getByTestId("prepare-row").filter({ hasText: t.clientName });
  const card = page.getByTestId("run-card").filter({ hasText: t.clientName });
  await expect(async () => {
    await page.reload();
    await expect(waiting.or(card)).toBeVisible({ timeout: 5_000 });
  }).toPass({ timeout: 90_000 });
  if (await waiting.isVisible()) {
    await waiting.getByRole("button", { name: "Préparer maintenant" }).click();
    await card.waitFor({ timeout: 15_000 }).catch(() => page.reload());
  }
  await expect(card.getByText("Brouillon", { exact: true })).toBeVisible({ timeout: 60_000 });
  await card.getByRole("link", { name: t.clientName }).click();
  await expect(page.getByTestId("run-status")).toHaveText("Brouillon");
  const runPage = page.url();
  await page.getByTestId("run-select").check();
  await page.getByTestId("approve-open").click();
  const sheet = page.getByTestId("approve-sheet");
  const lateReason = sheet.getByLabel(/Motif du retard/);
  if (await lateReason.isVisible()) await lateReason.fill("Encaissement identifié tardivement (E2E)");
  await sheet.getByTestId("approve-confirm").click();
  await expect(page.getByTestId("run-status")).toHaveText("Validé — virement ordonné", { timeout: 60_000 });
  return runPage;
}

test("a lot debited short of one member, then an entry kept unsplit, booked from « Débits et retours »", async ({
  page,
}, testInfo) => {
  test.setTimeout(480_000);
  const durand = await createTenant();
  await createMandate(durand);
  const lilas = await createOtherClient(durand, `Fromagerie Lilas ${durand.clientName.slice(-8)}`);
  await createMandate(lilas);
  const LOT_IBAN = ibanFr(717171);
  const { data: bank, error } = await adminClient()
    .from("bank_account")
    .insert({
      organization_id: durand.servicerId,
      iban: LOT_IBAN,
      currency: "EUR",
      label: "Fonds de tiers – Banque L",
      feed: "camt053",
      opened_on: "2026-01-01",
    })
    .select("id")
    .single();
  if (error) throw error;
  await createConfirmedPayoutAccount(durand, ibanFr(717172), "BOULANGERIE DURAND");
  await createConfirmedPayoutAccount(lilas, ibanFr(717173), "FROMAGERIE LILAS");
  await loginAsStaff(page, await createMember(durand.servicerId, "ops_manager"));
  await boardInto(page, durand);
  await boardInto(page, lilas);

  // a payment for each client's file, then each client's run prepared and approved
  const day = await lastBusinessDay();
  const dayFr = day.split("-").reverse().join("/");
  const credits: Credit[] = [
    { ref: "LOT-1", amountMinor: BigInt(50000), name: "DIALLO", iban: ibanFr(41), rf: await rfIn(durand, "C2929") },
    { ref: "LOT-2", amountMinor: BigInt(30000), name: "RIVIERE ET FILS", iban: ibanFr(42), rf: await rfIn(lilas, "C3945") },
  ];
  await importOn(page, "releve-lot-1.xml", camt053Lines(LOT_IBAN, day, credits, [], BigInt(0)));
  const durandRun = await prepareAndApprove(page, durand);
  const lilasRun = await prepareAndApprove(page, lilas);

  // « Virements »: both payouts in one file, downloaded and marked as sent — one lot (PmtInf) holds both
  await page.goto("/backoffice/reversements/virements");
  const account = page.getByTestId("paying-account").filter({ hasText: "Fonds de tiers – Banque L" });
  await expect(account.getByTestId("transfer-row")).toHaveCount(2);
  await account.getByTestId("generate-file").getByRole("button", { name: "Générer le fichier" }).click();
  await page
    .getByRole("dialog", { name: "Générer le fichier de virements" })
    .getByRole("button", { name: "Générer", exact: true })
    .click();
  const fileRow = account.getByTestId("file-row").first();
  await expect(fileRow.getByTestId("file-status")).toHaveText("Prêt à télécharger", { timeout: 60_000 });
  const [download] = await Promise.all([page.waitForEvent("download"), fileRow.getByTestId("file-download").click()]);
  const xml = readFileSync(await download.path()).toString("utf-8");
  await expect(fileRow.getByTestId("file-mark-sent")).toBeVisible({ timeout: 15_000 });
  await fileRow.getByTestId("file-mark-sent").getByRole("button", { name: "Marquer comme transmis" }).click();
  await expect(fileRow.getByTestId("file-status")).toHaveText("Transmis à la banque", { timeout: 15_000 });
  const lots = [...xml.matchAll(/<PmtInf>([\s\S]*?)<\/PmtInf>/g)].map((m) => m[1]);
  const lot = lots.find((b) => (b.match(/<CdtTrfTxInf>/g) ?? []).length === 2);
  expect(lot, "one PmtInf holds both payouts").toBeDefined();
  const pmtInfId = /<PmtInfId>([^<]+)<\/PmtInfId>/.exec(lot!)![1];
  const payouts = [...lot!.matchAll(/<CdtTrfTxInf>([\s\S]*?)<\/CdtTrfTxInf>/g)].map((m) => ({
    e2e: /<EndToEndId>([^<]+)<\/EndToEndId>/.exec(m[1])![1],
    amount: minorOf(/<InstdAmt Ccy="EUR">([0-9.]+)<\/InstdAmt>/.exec(m[1])![1]),
    name: /<Cdtr>\s*<Nm>([^<]+)<\/Nm>/.exec(m[1])![1],
  }));
  const first = payouts.find((p) => p.name === "BOULANGERIE DURAND")!;
  const second = payouts.find((p) => p.name === "FROMAGERIE LILAS")!;

  // the bank debits the lot short of Lilas' payout: one line, the lot's PmtInfId, no detail
  await importOn(
    page,
    "releve-lot-2.xml",
    camt053Lines(
      LOT_IBAN,
      day,
      [],
      [{ ref: "LOT-DEBIT", amountMinor: first.amount, kind: "lot", pmtInfId, nbOfTxs: 1 }],
      BigInt(80000),
    ),
  );
  await page.goto("/backoffice/encaissements/debits");
  const lotRow = page
    .getByTestId("debit-row")
    .filter({ hasText: `− ${euros(first.amount)}` })
    .filter({ hasText: "Lot débité pour un autre montant que ses virements en cours" });
  await expect(async () => {
    await page.reload();
    await expect(lotRow).toHaveCount(1, { timeout: 2_000 });
  }).toPass({ timeout: 60_000 });
  await lotRow.getByTestId("book-transfer-line").getByRole("button").click();
  const lotSheet = page.getByRole("dialog");
  await expect(lotSheet.getByTestId("transfer-line-proposal")).toContainText("Débit d'un lot de reversements", {
    timeout: 15_000,
  });
  const members = lotSheet.getByTestId("transfer-line-members");
  await expect(members.locator("li")).toHaveCount(2);
  await expect(members.locator("li").filter({ hasText: durand.clientName })).toContainText("Dans cette ligne : débit");
  await expect(members.locator("li").filter({ hasText: lilas.clientName })).toContainText(
    "Dans cette ligne : non débité par cette ligne",
  );
  await expect(lotSheet.getByTestId("transfer-line-effects")).toContainText(`${euros(first.amount)} débités le ${dayFr}`);
  await lotSheet
    .getByLabel("Motif (ce que montre le relevé ou la banque)")
    .fill("La banque confirme un lot débité sans le virement de Lilas (E2E)");
  await reviewShot(page, testInfo, "m2c-debits-reversement");
  await lotSheet.getByRole("button", { name: "Comptabiliser le débit" }).click();
  await expect(lotSheet).toHaveCount(0, { timeout: 15_000 });

  // read back: the line's booking is Durand's payout, Durand's run booked, Lilas' still sent; « Traités » says so
  const admin = adminClient();
  // the account's one debit line of that amount (a line without details keeps its entry's reference, not ours)
  const lineOf = async (amount: bigint) => {
    const { data, error: e } = await admin
      .from("bank_transaction")
      .select("id")
      .eq("bank_account_id", bank.id)
      .eq("direction", "debit")
      .eq("amount_minor", amount.toString())
      .single();
    if (e) throw e;
    return data.id as string;
  };
  const transferOf = async (e2e: string) => {
    const { data, error: e } = await admin
      .from("bank_transfer")
      .select("id, status, run_id")
      .eq("end_to_end_id", e2e)
      .single();
    if (e) throw e;
    return data as { id: string; status: string; run_id: string };
  };
  const bookingsOf = async (line: string) => {
    const { data, error: e } = await admin
      .from("bank_line_booking")
      .select("kind, transfer_id, amount_minor::text")
      .eq("bank_transaction_id", line)
      .order("seq");
    if (e) throw e;
    return data as unknown as { kind: string; transfer_id: string | null; amount_minor: string }[];
  };
  const runStatus = async (run: string) => {
    const { data, error: e } = await admin.from("remittance_run").select("status").eq("id", run).single();
    if (e) throw e;
    return data.status as string;
  };
  // review 6b-2d round 1 (tests-4): what each booking posted, from the ledger — per entry, its postings as
  // « book@account:client amount » (the lot's dedicated account named `lot`, the client by tenant), by book
  const postingsOf = async (line: string) => {
    const { data: bk, error: e1 } = await admin
      .from("bank_line_booking")
      .select("kind, entry_id")
      .eq("bank_transaction_id", line)
      .order("seq");
    if (e1) throw e1;
    const out: Record<string, string[]> = {};
    for (const b of bk as { kind: string; entry_id: string }[]) {
      const { data: rows, error: e2 } = await admin
        .from("ledger_posting")
        .select("amount_minor::text, ledger_account_id")
        .eq("entry_id", b.entry_id);
      if (e2) throw e2;
      const postings = rows as unknown as { amount_minor: string; ledger_account_id: string }[];
      const { data: accounts, error: e3 } = await admin
        .from("ledger_account")
        .select("id, book, bank_account_id, client_organization_id")
        .in("id", [...new Set(postings.map((p) => p.ledger_account_id))]);
      if (e3) throw e3;
      const accountOf = new Map(
        (
          accounts as {
            id: string;
            book: string;
            bank_account_id: string | null;
            client_organization_id: string | null;
          }[]
        ).map((a) => [a.id, a]),
      );
      out[b.kind] = postings
        .map((p) => {
          const a = accountOf.get(p.ledger_account_id)!;
          const where = a.bank_account_id ? `@${a.bank_account_id === bank.id ? "lot" : a.bank_account_id}` : "";
          const who = a.client_organization_id
            ? `:${a.client_organization_id === durand.clientId ? "durand" : a.client_organization_id === lilas.clientId ? "lilas" : a.client_organization_id}`
            : "";
          return `${a.book}${where}${who} ${p.amount_minor}`;
        })
        .sort();
    }
    return out;
  };
  const durandTransfer = await transferOf(first.e2e);
  const lilasTransfer = await transferOf(second.e2e);
  expect(await bookingsOf(await lineOf(first.amount))).toEqual([
    { kind: "payout", transfer_id: durandTransfer.id, amount_minor: first.amount.toString() },
  ]);
  // the dedicated account of the lot moved by the line's amount, Durand's payable by its payout: nothing else
  expect(await postingsOf(await lineOf(first.amount))).toEqual({
    payout: [`client_money_cash@lot -${first.amount}`, `client_payable:durand ${first.amount}`].sort(),
  });
  expect([durandTransfer.status, lilasTransfer.status]).toEqual(["booked", "in_file"]);
  expect([await runStatus(durandTransfer.run_id), await runStatus(lilasTransfer.run_id)]).toEqual(["booked", "sent"]);
  await page.goto("/backoffice/encaissements/debits?onglet=traites");
  await expect(
    page
      .getByTestId("debit-row")
      .filter({ hasText: `− ${euros(first.amount)}` })
      .filter({ hasText: "Débit d'un reversement" }),
  ).toHaveCount(1);
  await page.goto(durandRun);
  await expect(page.getByTestId("run-status")).toHaveText("Comptabilisé");
  await expect(page.getByTestId("run-payout-notes")).toContainText(`Débité de notre compte le ${dayFr}`);
  await page.goto(lilasRun);
  await expect(page.getByTestId("run-status")).toHaveText("Fichier transmis à la banque");

  // the bank debits Lilas' payout with its charge (1,20 €) on one entry: the import keeps it unsplit with its detail
  const charge = BigInt(120);
  await importOn(
    page,
    "releve-lot-3.xml",
    camt053Lines(
      LOT_IBAN,
      day,
      [],
      [
        {
          ref: "LOT-CHARGED",
          amountMinor: second.amount + charge,
          kind: "charged",
          e2e: second.e2e,
          name: "FROMAGERIE LILAS",
          instructedMinor: second.amount,
          chargesMinor: charge,
        },
      ],
      BigInt(80000) - first.amount,
    ),
  );
  await page.goto("/backoffice/encaissements/debits");
  const unsplitRow = page
    .getByTestId("debit-row")
    .filter({ hasText: `− ${euros(second.amount + charge)}` })
    .filter({ has: page.getByTestId("book-transfer-line") });
  await expect(async () => {
    await page.reload();
    await expect(unsplitRow).toHaveCount(1, { timeout: 2_000 });
  }).toPass({ timeout: 60_000 });
  await expect(unsplitRow).toContainText("Comptabiliser d'après le détail du relevé");
  await unsplitRow.getByTestId("book-transfer-line").getByRole("button").click();
  const detailSheet = page.getByRole("dialog");
  const detail = detailSheet.getByTestId("transfer-line-proposal");
  await expect(detail).toContainText("Comptabiliser d'après le détail du relevé", { timeout: 15_000 });
  // an entry kept unsplit is checked again before it is booked
  await detail.getByRole("button", { name: "Vérifier" }).click();
  const effects = detailSheet.getByTestId("transfer-line-effects");
  await expect(effects).toContainText(`${euros(second.amount)} débités le ${dayFr}`);
  await expect(effects).toContainText(n("Frais bancaires de 1,20 € prélevés sur la même ligne, à la charge du cabinet"));
  await expect(effects).toContainText("frais indiqués par le relevé");
  await detailSheet
    .getByLabel("Motif (ce que montre le relevé ou la banque)")
    .fill("Le relevé détaille le virement de Lilas et les frais de la banque (E2E)");
  await reviewShot(page, testInfo, "m2c-debits-detail-releve");
  await detailSheet.getByRole("button", { name: "Comptabiliser", exact: true }).click();
  await expect(detailSheet).toHaveCount(0, { timeout: 15_000 });

  // read back: Lilas' payout and the bank's fee, from the statement's detail; Lilas' run booked; « Traités » says both
  expect(await bookingsOf(await lineOf(second.amount + charge))).toEqual([
    { kind: "payout", transfer_id: lilasTransfer.id, amount_minor: second.amount.toString() },
    { kind: "fee", transfer_id: null, amount_minor: charge.toString() },
  ]);
  // (tests-4) the payout from Lilas' payable, the 1,20 € fee the servicer's own cost (bank_fees, its claim on the
  // dedicated account's fund), the lot's account moved by the whole line
  expect(await postingsOf(await lineOf(second.amount + charge))).toEqual({
    payout: [`client_money_cash@lot -${second.amount}`, `client_payable:lilas ${second.amount}`].sort(),
    fee: [
      `bank_fees ${charge}`,
      `client_money_cash@lot -${charge}`,
      `due_from_client_funds -${charge}`,
      `due_to_servicer ${charge}`,
    ].sort(),
  });
  expect((await transferOf(second.e2e)).status).toBe("booked");
  expect(await runStatus(lilasTransfer.run_id)).toBe("booked");
  await page.goto("/backoffice/encaissements/debits?onglet=traites");
  await expect(
    page
      .getByTestId("debit-row")
      .filter({ hasText: `− ${euros(second.amount + charge)}` })
      .filter({ hasText: "Débit d'un reversement + Frais bancaires" }),
  ).toHaveCount(1);
  await page.goto(lilasRun);
  await expect(page.getByTestId("run-status")).toHaveText("Comptabilisé");
});
