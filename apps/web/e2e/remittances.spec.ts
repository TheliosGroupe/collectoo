import { expect, test, type Page } from "@playwright/test";
import { readFileSync } from "node:fs";
import path from "node:path";
import {
  adminClient,
  createConfirmedPayoutAccount,
  createMandate,
  createMember,
  createTenant,
  type Tenant,
} from "./support/admin";
import { camt053, camt053Lines, ibanFr, type Credit } from "./support/camt";
import { loginAsStaff, loginWithEmailCode } from "./support/session";
import { reviewShot } from "./screenshot";

/**
 * M2c-4 « Reversements » (M2-14 core, M2-15 numbering; design §17.1–§17.2): an ops manager boards B2B files, imports
 * the dedicated account's statement where two of them paid, then, on « Reversements », prepares the client's run
 * (« Préparer maintenant »), reads it — the net in large type, the commission netted, the deadline chip, the lines
 * and « Pourquoi cette commission ? », the invoice to issue — approves it from the sticky bar (the sheet states every
 * effect), and finds it approved: the invoice numbered in the servicer's series, the payout ordered (nothing leaves
 * the dedicated account before the bank's debit, M2c-6). M2c-5: the documents job draws the statement (PDF, CSV) and the
 * invoice's PDF; ops download them and the accountant's export; the client's administrator reads « Reversements » (what
 * is owed, the payout ordered, the statement) and « Factures » (the invoice, accepted electronically) in the client
 * space and downloads them. M2c-6a: the payout goes in a pain.001 file (« Virements »), downloaded once by a tap (the
 * page refreshes itself), the second time only past the warning (a refusal comes back to the file's page with it open:
 * review tests-ui#9), marked as sent; once downloaded it cannot be cancelled in Collectoo, the page says so (review
 * round 5, fail-closed until M2c-6b). M2c-6b-2c: the run page and « Virements » say when the payout was debited; the bank
 * debits it a second time and sends one copy back (one statement): ops book the second debit as « Virement hors
 * reversement » (P = 0 sheet: all of it the servicer's advance), then the copy back with « Virement revenu » (the
 * advance cancelled, nothing owed again); the client space reads « Virement débité de notre compte le … ». Phone-first.
 * Synthetic data.
 */
const BANK_IBAN = ibanFr(434343);
const FIXTURE = {
  name: "Créances à reverser.csv",
  mimeType: "text/csv",
  buffer: readFileSync(
    path.resolve(__dirname, "fixtures/factures-imputation.csv"),
  ),
};

let tenant: Tenant;

/** Today in Europe/Paris (YYYY-MM-DD), the day `private.paris_today()` reads on the same machine. */
function parisToday(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Paris" }).format(
    new Date(),
  );
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
  await createConfirmedPayoutAccount(
    tenant,
    ibanFr(434344),
    "BOULANGERIE DURAND",
  );
  // the client accepted electronic invoices in its mandate (CGI 289 VI): its invoices are served in the client space
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
  await page
    .getByLabel("Encours restant dû à la date d'arrêté (€)")
    .fill("4 800,00");
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
  const { data: ref } = await admin
    .from("payment_reference")
    .select("rf")
    .eq("account_id", account.id)
    .eq("status", "active")
    .single();
  return ref!.rf as string;
}

test("ops prepare, read and approve a client's remittance run", async ({
  page,
  browser,
}, testInfo) => {
  test.setTimeout(300_000);
  await loginAsStaff(
    page,
    await createMember(tenant.servicerId, "ops_manager"),
  );
  await boardAndConfirm(page);
  const credits: Credit[] = [
    {
      ref: "RV-1",
      amountMinor: BigInt(50000),
      name: "DIALLO",
      iban: ibanFr(21),
      rf: await rfOf("C2929"),
    },
    {
      ref: "RV-2",
      amountMinor: BigInt(30001),
      name: "RIVIERE ET FILS",
      iban: ibanFr(22),
      rf: await rfOf("C3945"),
    },
  ];
  await page.goto("/backoffice/encaissements");
  const form = page.getByTestId("statement-upload");
  await form.getByLabel("Relevé CAMT.053 (XML)").setInputFiles({
    name: "releve-reversement.xml",
    mimeType: "application/xml",
    buffer: Buffer.from(
      camt053(BANK_IBAN, await statementDay(), credits),
      "utf-8",
    ),
  });
  await form.getByRole("button", { name: "Importer le relevé" }).click();
  await expect(page.getByTestId("statement-status")).toHaveText("Importé", {
    timeout: 60_000,
  });

  // « Reversements »: the client's collections wait; prepare its run now. The hourly schedule (xx:07) may have
  // prepared it first on a run day of the mandate (the 1st, the 16th): its draft is then the one read and approved.
  await page.goto("/backoffice");
  await page.getByTestId("remittances-link").click();
  await expect(page).toHaveURL(/\/backoffice\/reversements$/);
  const waiting = page
    .getByTestId("prepare-row")
    .filter({ hasText: tenant.clientName });
  const card = page
    .getByTestId("run-card")
    .filter({ hasText: tenant.clientName });
  // the worker matches and allocates the statement's payments after « Importé »; the page refreshes itself only while
  // a run is in flight, so reload it until the client's collections are listed (or its run, prepared by the schedule)
  await expect(async () => {
    await page.reload();
    await expect(waiting.or(card)).toBeVisible({ timeout: 5_000 });
  }).toPass({ timeout: 90_000 });
  if (await waiting.isVisible()) {
    await expect(waiting).toContainText("800,01");
    await waiting.getByRole("button", { name: "Préparer maintenant" }).click();
    // a click that lost the race to the schedule is refused (one run at a time) and the list stays: reload it
    await card.waitFor({ timeout: 15_000 }).catch(() => page.reload());
  }
  // the draft, prepared by the click or by the schedule (the page refreshes itself while it is prepared)
  await expect(card.getByText("Brouillon", { exact: true })).toBeVisible({
    timeout: 60_000,
  });
  await expect(card).toContainText("brut 800,01");
  await expect(card.getByTestId("run-net")).toContainText("656,01");
  await expect(card).toContainText("commission 144,00 € TTC");
  await expect(card).toContainText("Exécution au plus tard le");
  await reviewShot(page, testInfo, "m2c-reversements");

  // the run's page: the lines, why each commission, the invoice to issue
  await card.getByRole("link", { name: tenant.clientName }).click();
  await expect(page.getByTestId("run-status")).toHaveText("Brouillon");
  await expect(
    page.getByTestId("run-lines").getByTestId("run-line"),
  ).toHaveCount(2);
  await page
    .getByTestId("run-line")
    .first()
    .getByText("Pourquoi cette commission ?")
    .click();
  await expect(page.getByTestId("run-line").first()).toContainText("15 % sur");
  await expect(page.getByTestId("run-documents")).toContainText(
    "(numérotée à la validation)",
  );
  await reviewShot(page, testInfo, "m2c-reversement");

  // approve from the sticky bar: the sheet states every effect
  await page.getByTestId("run-select").check();
  await page.getByTestId("approve-open").click();
  const sheet = page.getByTestId("approve-sheet");
  await expect(sheet.getByTestId("approve-effects")).toContainText(
    "1 virement depuis le compte dédié",
  );
  await expect(sheet.getByTestId("approve-effects")).toContainText(
    "1 facture sera numérotée",
  );
  await reviewShot(page, testInfo, "m2c-reversement-validation");
  // never shown with a statement of yesterday; filled if a calendar ever makes the default date late
  const lateReason = sheet.getByLabel(/Motif du retard/);
  if (await lateReason.isVisible())
    await lateReason.fill("Encaissement identifié tardivement (E2E)");
  await sheet.getByTestId("approve-confirm").click();
  await expect(page.getByTestId("run-status")).toHaveText(
    "Validé — virement ordonné",
    { timeout: 60_000 },
  );
  await expect(page.getByTestId("run-documents")).toContainText(
    /Facture FC-\d{4}-000001/,
  );
  await expect(page.getByTestId("run-transfer")).toContainText("656,01");
  await expect(page.getByTestId("run-transfer")).toContainText("Ordonné");

  // M2c-5: the documents job draws the statement and the invoice's PDF (the page refreshes itself until then)
  const statementPdf = page.getByTestId("run-statement-pdf");
  await expect(statementPdf).toBeVisible({ timeout: 60_000 });
  await expect(page.getByTestId("run-document-pdf")).toBeVisible();
  await expect(page.getByTestId("run-document-post")).toHaveCount(0);
  await reviewShot(page, testInfo, "m2c-reversement-valide");
  const pdf = await page.request.get(
    (await statementPdf.getAttribute("href"))!,
  );
  expect(pdf.status()).toBe(200);
  expect((await pdf.body()).subarray(0, 5).toString()).toBe("%PDF-");
  const csv = await page.request.get(
    (await page.getByTestId("run-statement-csv").getAttribute("href"))!,
  );
  expect(csv.status()).toBe(200);
  const csvText = (await csv.body()).toString("utf-8");
  expect(csvText.startsWith("\ufeffreleve;date_releve;mandat;")).toBe(true);
  expect(csvText).toContain(";500,00;50000;");
  expect(csvText).toContain(";300,01;30001;");
  const invoicePdf = await page.request.get(
    (await page.getByTestId("run-document-pdf").getAttribute("href"))!,
  );
  expect(invoicePdf.status()).toBe(200);
  expect((await invoicePdf.body()).subarray(0, 5).toString()).toBe("%PDF-");

  // « En cours »
  await page.goto("/backoffice/reversements?onglet=en-cours");
  await expect(
    page.getByTestId("run-row").filter({ hasText: tenant.clientName }),
  ).toContainText("Validé — virement ordonné");

  // the accountant's export: the invoice of the period and its entries
  await page.getByTestId("accounting-export-link").click();
  await expect(page).toHaveURL(/\/backoffice\/reversements\/comptabilite/);
  // review M2c-5 figures#7: the export counts settlements up to the period's last day, and says so
  await expect(page.getByTestId("export-documents-as-of")).toHaveText(
    /^Règlements et restes dus arrêtés au \d{2}\/\d{2}\/\d{4}\.$/,
  );
  await reviewShot(page, testInfo, "m2c-export-comptable");
  const exported = await page.request.get(
    (await page.getByTestId("export-documents").getAttribute("href"))!,
  );
  expect(exported.status()).toBe(200);
  const exportText = (await exported.body()).toString("utf-8");
  expect(exportText.startsWith("\ufeffnumero;type;date_emission;")).toBe(true);
  expect(exportText).toMatch(/FC-\d{4}-000001;facture;/);
  const entries = await page.request.get(
    (await page.getByTestId("export-entries").getAttribute("href"))!,
  );
  expect(entries.status()).toBe(200);
  expect((await entries.body()).toString("utf-8")).toContain(
    ";7060;Commissions de recouvrement;",
  );

  // the client space: « Reversements » and « Factures » (its administrator, its own browser)
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
  await loginWithEmailCode(
    client,
    await createMember(tenant.clientId, "client_admin"),
  );
  await expect(client).toHaveURL(/\/client$/);
  await client.getByTestId("client-remittances-link").click();
  await expect(client).toHaveURL(/\/client\/reversements$/);
  await expect(client.getByTestId("owed-today")).toContainText("800,01");
  // review M2c-5 (tests-ui#5, K2): the gross still owed is the ordered payout's, worded so, not an extra amount
  const inFlight = client.getByTestId("owed-in-flight");
  await expect(inFlight).toHaveCount(1);
  await expect(inFlight).toContainText(
    /dont 800,01\s€ compris dans le reversement RV-\d{4}-\d{6} ordonné/,
  );
  await expect(inFlight).toContainText(
    /656,01\s€ à virer ; 144,00\s€ de commission à compenser au débit du virement/,
  );
  await expect(client.getByTestId("next-run")).toContainText(
    /le \d{2}\/\d{2}\/\d{4}/,
  );
  const row = client.getByTestId("statement-row");
  await expect(row).toHaveCount(1);
  await expect(row).toContainText("656,01");
  // review M2c-5 (figures#1 = tests-ui#1, K7): the run's live status, not the one frozen in the statement
  await expect(row.getByTestId("statement-status")).toHaveText(
    "Virement ordonné",
  );
  await expect(row).not.toContainText("payé");
  const clientPdf = await client.request.get(
    (await row.getByTestId("statement-pdf").getAttribute("href"))!,
  );
  expect(clientPdf.status()).toBe(200);
  expect((await clientPdf.body()).subarray(0, 5).toString()).toBe("%PDF-");
  await client.getByTestId("client-invoices-link").click();
  await expect(client).toHaveURL(/\/client\/factures$/);
  const invoice = client.getByTestId("invoice-row");
  await expect(invoice).toHaveCount(1);
  await expect(invoice).toContainText(/Facture FC-\d{4}-000001/);
  await expect(invoice).toContainText("144,00");
  await expect(invoice).toContainText("à régler par compensation");
  await reviewShot(client, testInfo, "m2c-client-factures");
  const clientInvoice = await client.request.get(
    (await invoice.getByTestId("invoice-pdf").getAttribute("href"))!,
  );
  expect(clientInvoice.status()).toBe(200);
  await context.close();

  // M2c-6a « Virements »: the payout goes in a pain.001 file the worker writes; ops download it (the hash checked by
  // the route), a second download only past the warning, then « Marquer comme transmis ». Nothing is booked before
  // the bank's debit (M2c-6b).
  await page.goto("/backoffice/reversements");
  await page.getByTestId("transfers-link").click();
  await expect(page).toHaveURL(/\/backoffice\/reversements\/virements$/);
  const account = page
    .getByTestId("paying-account")
    .filter({ hasText: "Fonds de tiers – Banque R" });
  await expect(account.getByTestId("cash-check")).toContainText(
    "disponible pour un fichier",
  );
  const waitingTransfer = account
    .getByTestId("transfer-row")
    .filter({ hasText: tenant.clientName });
  await expect(waitingTransfer).toContainText("656,01");
  await expect(waitingTransfer).toContainText("BOULANGERIE DURAND");
  await expect(waitingTransfer.getByTestId("transfer-hold")).toHaveCount(0);
  await reviewShot(page, testInfo, "m2c-virements");
  await account
    .getByTestId("generate-file")
    .getByRole("button", { name: "Générer le fichier" })
    .click();
  const generate = page.getByRole("dialog", {
    name: "Générer le fichier de virements",
  });
  await expect(generate.getByTestId("generate-effects")).toContainText(
    "1 virement depuis Fonds de tiers – Banque R",
  );
  await expect(generate.getByTestId("generate-effects")).toContainText(
    "Rien n'est comptabilisé avant le débit",
  );
  await reviewShot(page, testInfo, "m2c-virements-generer");
  await generate.getByRole("button", { name: "Générer", exact: true }).click();
  const fileRow = account.getByTestId("file-row").first();
  // the transfer_file job writes it (the page refreshes itself meanwhile)
  await expect(fileRow.getByTestId("file-status")).toHaveText(
    "Prêt à télécharger",
    { timeout: 60_000 },
  );
  const href = (await fileRow
    .getByTestId("file-download")
    .getAttribute("href"))!;
  // review tests-ui#9: a tap downloads the file (the command first: its checks, the download recorded) and the page
  // refreshes itself — the warning and « Marquer comme transmis » appear with no manual reload
  const [download] = await Promise.all([
    page.waitForEvent("download"),
    fileRow.getByTestId("file-download").click(),
  ]);
  expect(download.suggestedFilename()).toMatch(/^TF-\d{4}-\d{6}\.xml$/);
  const body = readFileSync(await download.path()).toString("utf-8");
  expect(body).toContain(
    'xmlns="urn:iso:std:iso:20022:tech:xsd:pain.001.001.09"',
  );
  expect(body).toContain("<CtrlSum>656.01</CtrlSum>");
  expect(body).toContain("<BtchBookg>false</BtchBookg>");
  expect(body).toContain("<Nm>BOULANGERIE DURAND</Nm>");
  expect(body).toMatch(/<EndToEndId>RMT[0-9A-F]{12}<\/EndToEndId>/);
  expect(body).toMatch(
    /<Ustrd>REVERSEMENT RV-\d{4}-\d{6} FACTURE FC-\d{4}-000001<\/Ustrd>/,
  );
  await expect(fileRow.getByTestId("file-mark-sent")).toBeVisible({
    timeout: 15_000,
  });
  await expect(fileRow.getByTestId("file-status")).toHaveText(
    "Téléchargé — à déposer à la banque",
  );
  await expect(fileRow.getByTestId("download-warning")).toContainText(
    /Déjà téléchargé par .+ le \d{2}\/\d{2} à \d{2}:\d{2}/,
  );
  // a second download without the warning acknowledged is refused: back to the file's page (never a bare text page),
  // where the warning sheet is open with who downloaded it and when
  const twice = await page.request.get(href, { maxRedirects: 0 });
  expect(twice.status()).toBe(303);
  const back = twice.headers()["location"];
  // a path, resolved by the browser against its own origin (an absolute URL from `request.url` names `localhost`)
  expect(back).toMatch(
    /^\/backoffice\/reversements\/virements\/[0-9a-f-]{36}\?refus=already_downloaded$/,
  );
  await page.goto(back);
  await expect(page.getByTestId("download-again-warning")).toBeVisible();
  await expect(page.getByTestId("download-again-warning")).toContainText(
    "ne le déposez pas deux fois",
  );
  await page.goto(new URL(back, page.url()).pathname);
  await expect(
    page.getByTestId("file-items").getByTestId("file-item"),
  ).toHaveCount(1);
  await expect(
    page.getByTestId("file-downloads").getByTestId("file-download-row"),
  ).toHaveCount(1);
  // review tests-ui#6: « vérifié » once the ISO 20022 schemas are vendored, « non vérifié » until then
  await expect(page.getByTestId("file-integrity")).toContainText(
    /schéma XSD ISO 20022 (non )?vérifié/,
  );
  // review round 5 (fail-closed): a downloaded file cannot be cancelled in Collectoo until M2c-6b books its debits —
  // no « Demander l'annulation », no « Virement refusé par la banque »; the page says its transfers stay « en cours »
  const note = page.getByTestId("file-no-cancellation");
  await expect(note).toContainText(
    "Un fichier téléchargé ne peut pas encore être annulé dans Collectoo",
  );
  await expect(note).toContainText("« en cours »");
  await expect(page.getByTestId("file-cancellation")).toHaveCount(0);
  await expect(page.getByTestId("request-cancellation")).toHaveCount(0);
  await expect(page.getByTestId("confirm-cancellation")).toHaveCount(0);
  await expect(page.getByTestId("transfer-refused")).toHaveCount(0);
  await reviewShot(page, testInfo, "m2c-virement-telecharge");
  await page
    .getByTestId("file-mark-sent")
    .getByRole("button", { name: "Marquer comme transmis" })
    .click();
  await expect(page.getByTestId("file-status")).toHaveText(
    "Transmis à la banque",
  );
  await expect(page.getByTestId("file-no-cancellation")).toBeVisible();
  await expect(page.getByTestId("file-cancellation")).toHaveCount(0);
  await reviewShot(page, testInfo, "m2c-virement-fichier");
  // the run: its payout in the file, sent (not « payé » before the bank's debit)
  const filePage = page.url();
  await page
    .getByTestId("file-item")
    .getByRole("link", { name: /^RV-/ })
    .click();
  await expect(page.getByTestId("run-status")).toHaveText(
    "Fichier transmis à la banque",
  );
  await expect(page.getByTestId("run-transfer-file")).toContainText(
    "Transmis à la banque",
  );
  const runPage = page.url();

  // M2c-6b-1: the next statement shows the bank's debit of the payout (its RMT id): the debit job books the payout, the
  // run's settlement, the transfer and the run (« Débité », « Comptabilisé ») with no action from ops
  const e2e = body.match(/<EndToEndId>(RMT[0-9A-F]{12})<\/EndToEndId>/)![1];
  const opening = credits.reduce((s, c) => s + c.amountMinor, BigInt(0));
  await page.goto("/backoffice/encaissements");
  const debitForm = page.getByTestId("statement-upload");
  await debitForm.getByLabel("Relevé CAMT.053 (XML)").setInputFiles({
    name: "releve-debit-reversement.xml",
    mimeType: "application/xml",
    buffer: Buffer.from(
      camt053Lines(
        BANK_IBAN,
        await statementDay(),
        [],
        [
          {
            ref: "RV-DEBIT",
            amountMinor: BigInt(65601),
            kind: "transfer",
            e2e,
            name: "BOULANGERIE DURAND",
          },
        ],
        opening,
      ),
      "utf-8",
    ),
  });
  await debitForm.getByRole("button", { name: "Importer le relevé" }).click();
  // the import leads to the new statement's page (the encaissements page still shows the first one meanwhile)
  await expect(page).toHaveURL(
    /\/backoffice\/encaissements\/releves\/[0-9a-f-]{36}/,
    { timeout: 30_000 },
  );
  await expect(page.getByTestId("statement-status")).toHaveText("Importé", {
    timeout: 60_000,
  });
  await page.goto(runPage);
  await expect(async () => {
    await page.reload();
    await expect(page.getByTestId("run-status")).toHaveText("Comptabilisé", {
      timeout: 2_000,
    });
  }).toPass({ timeout: 60_000 });
  await expect(page.getByTestId("run-transfer-status")).toContainText("Débité");
  // M2c-6b-2c (plan §7.4): the dates, from public.remittance_run_payout
  const debitDay = await statementDay();
  const debitFr = debitDay.split("-").reverse().join("/");
  await expect(page.getByTestId("run-payout-notes")).toContainText(
    `Débité de notre compte le ${debitFr}`,
  );
  await expect(page.getByTestId("run-payout-notes")).toContainText(
    `Commission réglée par compensation le ${debitFr} : 144,00`,
  );
  await reviewShot(page, testInfo, "m2c-reversement-debite");
  await page.goto(filePage);
  await expect(page.getByTestId("file-item")).toContainText("Débité");
  await expect(page.getByTestId("file-item")).toContainText(
    `Débité le ${debitFr}`,
  );
  await reviewShot(page, testInfo, "m2c-virement-debite");

  // M2c-6b-2c (plan §8.4): the bank debits the payout a second time and sends one copy back, on one statement — the
  // job reviews the second debit transfer_debited_twice (P0) and the copy back return_debit_pending
  await page.goto("/backoffice/encaissements");
  const twiceForm = page.getByTestId("statement-upload");
  await twiceForm.getByLabel("Relevé CAMT.053 (XML)").setInputFiles({
    name: "releve-second-debit.xml",
    mimeType: "application/xml",
    buffer: Buffer.from(
      camt053Lines(
        BANK_IBAN,
        debitDay,
        [
          {
            ref: "RV-RETOUR",
            amountMinor: BigInt(65601),
            name: "BOULANGERIE DURAND",
            iban: ibanFr(434344),
            e2e,
            returned: true,
          },
        ],
        [
          {
            ref: "RV-DEBIT-2",
            amountMinor: BigInt(65601),
            kind: "transfer",
            e2e,
            name: "BOULANGERIE DURAND",
          },
        ],
        opening - BigInt(65601),
      ),
      "utf-8",
    ),
  });
  await twiceForm.getByRole("button", { name: "Importer le relevé" }).click();
  await expect(page).toHaveURL(
    /\/backoffice\/encaissements\/releves\/[0-9a-f-]{36}/,
    { timeout: 30_000 },
  );
  await expect(page.getByTestId("statement-status")).toHaveText("Importé", {
    timeout: 60_000,
  });
  await page.goto("/backoffice/encaissements/debits");
  const debitedTwice = page
    .getByTestId("debit-row")
    .filter({ has: page.getByTestId("debit-review-p0") })
    .filter({ hasText: "656,01" });
  await expect(async () => {
    await page.reload();
    await expect(debitedTwice).toHaveCount(1, { timeout: 2_000 });
  }).toPass({ timeout: 60_000 });
  // « Comptabiliser… »: the options are read when the sheet opens (never while the list renders)
  await debitedTwice.getByTestId("book-transfer-line").getByRole("button").click();
  const unplannedSheet = page.getByRole("dialog");
  const unplannedProposal = unplannedSheet.getByTestId("transfer-line-proposal");
  await expect(unplannedProposal).toContainText("Virement hors reversement", {
    timeout: 15_000,
  });
  await expect(unplannedSheet.getByTestId("transfer-line-effects")).toContainText(
    `Rien n'est déduit du prochain reversement de ${tenant.clientName} ; avance du cabinet de 656,01`,
  );
  await unplannedSheet
    .getByLabel("Motif (ce que montre le relevé ou la banque)")
    .fill("La banque confirme une double exécution (E2E)");
  await reviewShot(page, testInfo, "m2c-virement-hors-reversement");
  await unplannedSheet
    .getByRole("button", { name: "Comptabiliser le virement" })
    .click();
  await expect(unplannedSheet).toHaveCount(0, { timeout: 15_000 });
  // the copy back: the funds pass the command queued reads it again — the unplanned booking's return. (review 6b-2c T8)
  // Waited on what that re-read changes: its review becomes unplanned_payout_return (« exécuté hors de son ordre »);
  // the stale return_debit_pending already said « Virement revenu »
  const copyBack = page
    .getByTestId("debit-row")
    .filter({ hasText: "656,01" })
    .filter({ hasText: "exécuté hors de son ordre" })
    .filter({ hasNotText: "Comptabilisez d'abord ce débit" });
  await expect(async () => {
    await page.reload();
    await expect(copyBack).toHaveCount(1, { timeout: 2_000 });
  }).toPass({ timeout: 60_000 });
  await copyBack.getByTestId("book-transfer-line").getByRole("button").click();
  const returnSheet = page.getByRole("dialog");
  await expect(returnSheet.getByTestId("transfer-line-proposal")).toContainText(
    "Virement revenu",
    { timeout: 15_000 },
  );
  await expect(returnSheet.getByTestId("transfer-line-effects")).toContainText(
    `Le virement hors reversement du ${debitFr} (656,01`,
  );
  await expect(returnSheet.getByTestId("transfer-line-effects")).toContainText(
    `revient : l'avance du cabinet de 656,01`,
  );
  await expect(returnSheet.getByTestId("transfer-line-effects")).toContainText(
    `rien n'est de nouveau dû à ${tenant.clientName}`,
  );
  await returnSheet
    .getByLabel("Motif (ce que montre le relevé ou la banque)")
    .fill("Retour MD06 d'une des deux exécutions (E2E)");
  await reviewShot(page, testInfo, "m2c-virement-revenu");
  await returnSheet
    .getByRole("button", { name: "Comptabiliser le retour" })
    .click();
  await expect(returnSheet).toHaveCount(0, { timeout: 15_000 });
  await page.goto("/backoffice/encaissements/debits?onglet=traites");
  await expect(
    page.getByTestId("debit-row").filter({ hasText: "Virement hors reversement revenu" }),
  ).toHaveCount(1);
  await expect(
    page
      .getByTestId("debit-row")
      .filter({ hasText: /Virement hors reversement$|Virement hors reversement\s/ })
      .first(),
  ).toBeVisible();
  // (review 6b-2c T8) the run page says the second execution, with its date, and that it came back
  await page.goto(runPage);
  await expect(page.getByTestId("run-payout-notes")).toContainText(
    `La banque a exécuté le virement de ce reversement une seconde fois le ${debitFr} (656,01`,
  );
  await expect(page.getByTestId("run-payout-notes")).toContainText(
    `Ce virement hors reversement du ${debitFr} est revenu depuis : son retour est comptabilisé.`,
  );

  // the client space: the debit's date (plan §7.4, critic L6)
  const later = await browser.newContext({
    baseURL: use.baseURL,
    viewport: use.viewport,
    userAgent: use.userAgent,
    deviceScaleFactor: use.deviceScaleFactor,
    isMobile: use.isMobile,
    hasTouch: use.hasTouch,
  });
  const clientLater = await later.newPage();
  await loginWithEmailCode(
    clientLater,
    await createMember(tenant.clientId, "client_admin"),
  );
  await expect(clientLater).toHaveURL(/\/client$/);
  await clientLater.goto("/client/reversements");
  await expect(
    clientLater.getByTestId("statement-row").getByTestId("statement-status"),
  ).toHaveText(`Virement débité de notre compte le ${debitFr}`);
  await reviewShot(clientLater, testInfo, "m2c-client-reversements");
  await later.close();

  // review 6b-2c (pages-6, T8; plan §7.4, §7.5): the payee's bank sends the payout's planned copy back (flagged): the job
  // books the return — the run page says so and that the payout account is blocked; then the bank executes the payout
  // once more: « Virement hors reversement » with P = A (the sums its return put back are deducted, no advance)
  const statementOf = async (
    file: string,
    credits: Credit[],
    debits: Parameters<typeof camt053Lines>[3],
    from: bigint,
  ) => {
    await page.goto("/backoffice/encaissements");
    const form = page.getByTestId("statement-upload");
    await form.getByLabel("Relevé CAMT.053 (XML)").setInputFiles({
      name: file,
      mimeType: "application/xml",
      buffer: Buffer.from(camt053Lines(BANK_IBAN, debitDay, credits, debits, from), "utf-8"),
    });
    await form.getByRole("button", { name: "Importer le relevé" }).click();
    await expect(page).toHaveURL(
      /\/backoffice\/encaissements\/releves\/[0-9a-f-]{36}/,
      { timeout: 30_000 },
    );
    await expect(page.getByTestId("statement-status")).toHaveText("Importé", {
      timeout: 60_000,
    });
  };
  await statementOf(
    "releve-retour-reversement.xml",
    [
      {
        ref: "RV-RETOUR-2",
        amountMinor: BigInt(65601),
        name: "BOULANGERIE DURAND",
        iban: ibanFr(434344),
        e2e,
        returned: true,
      },
    ],
    [],
    opening - BigInt(65601),
  );
  await page.goto(runPage);
  await expect(async () => {
    await page.reload();
    await expect(page.getByTestId("run-payout-notes")).toContainText(
      `Virement revenu impayé le ${debitFr} : 656,01`,
      { timeout: 2_000 },
    );
  }).toPass({ timeout: 60_000 });
  await expect(page.getByTestId("run-payout-notes")).toContainText(
    "son compte de reversement est bloqué jusqu'à son remplacement ou sa reconfirmation",
  );
  await statementOf(
    "releve-troisieme-debit.xml",
    [],
    [
      {
        ref: "RV-DEBIT-3",
        amountMinor: BigInt(65601),
        kind: "transfer",
        e2e,
        name: "BOULANGERIE DURAND",
      },
    ],
    opening,
  );
  await page.goto("/backoffice/encaissements/debits");
  const debitedAgain = page
    .getByTestId("debit-row")
    .filter({ hasText: "656,01" })
    .filter({ has: page.getByTestId("book-transfer-line") });
  await expect(async () => {
    await page.reload();
    await expect(debitedAgain).toHaveCount(1, { timeout: 2_000 });
  }).toPass({ timeout: 60_000 });
  await debitedAgain.getByTestId("book-transfer-line").getByRole("button").click();
  const deductedSheet = page.getByRole("dialog");
  await expect(deductedSheet.getByTestId("transfer-line-proposal")).toContainText(
    "Virement hors reversement",
    { timeout: 15_000 },
  );
  await expect(deductedSheet.getByTestId("transfer-line-effects")).toContainText(
    `déjà reçus par ${tenant.clientName} seront déduits de son prochain reversement (sommes du reversement`,
  );
  await expect(deductedSheet.getByTestId("transfer-line-effects")).toContainText(
    "remises à reverser par le retour de son virement) ; avance du cabinet : 0,00",
  );
  await deductedSheet
    .getByLabel("Motif (ce que montre le relevé ou la banque)")
    .fill("La banque a exécuté de nouveau le virement revenu (E2E)");
  await reviewShot(page, testInfo, "m2c-virement-hors-reversement-deduit");
  await deductedSheet
    .getByRole("button", { name: "Comptabiliser le virement" })
    .click();
  await expect(deductedSheet).toHaveCount(0, { timeout: 15_000 });
  await page.goto(runPage);
  await expect(page.getByTestId("run-payout-notes")).toContainText(
    "comptabilisé hors reversement, avance du cabinet de 0,00",
  );
});
