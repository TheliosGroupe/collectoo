import { expect, test, type Browser, type Locator, type Page, type TestInfo } from "@playwright/test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { adminClient, createConfirmedPayoutAccount, createMandate, createMember, createTenant, type Tenant } from "./support/admin";
import { camt053, ibanFr, type Credit } from "./support/camt";
import { loginAsStaff } from "./support/session";
import { reviewShot } from "./screenshot";
import { expectOwnImport } from "./support/statements";

/**
 * M2c-7d-1 (plan docs/design/m2c-7-plan.md §6.4, §6.6 E2E; ADR-0014 « M2c-7d-1 »): a client's portfolio confirmed and a
 * collection allocated; then its death is recorded with the notary as the person who acts for it (the run is blocked:
 * « Décès du client : confirmez le compte du notaire … »); a payment received after the death is held for ops
 * (« Reçu après la fin du mandat ») and forwarded to the client without allocation; the notary's IBAN is proposed with
 * its attestation and confirmed by a second admin, who sees the holder's name beside the client's; the run is prepared
 * and approved. A seizure served on the servicer is recorded, listed as standing, then released (the release names
 * it). Screenshots `m2c7-evenement-client`, `m2c7-paiement-apres-fin-mandat`, `m2c7-beneficiaire-succession`,
 * `m2c7-saisie` (mobile + desktop). The switch stays off. Synthetic data.
 */
const BANK_IBAN = ibanFr(717171);
const PAYOUT_IBAN = ibanFr(717172);
const NOTARY_IBAN = ibanFr(717173);
const FIXTURE = {
  name: "Créances du client.csv",
  mimeType: "text/csv",
  buffer: readFileSync(path.resolve(__dirname, "fixtures/factures-imputation.csv")),
};
const PDF = (text: string) => ({ name: `${text}.pdf`, mimeType: "application/pdf", buffer: Buffer.from(`%PDF-1.4\n% ${text}\n%%EOF\n`) });

let tenant: Tenant;

function parisToday(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Paris" }).format(new Date());
}

function addDays(isoDate: string, days: number): string {
  const [y, m, d] = isoDate.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + days)).toISOString().slice(0, 10);
}

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
    label: "Fonds de tiers – Banque A",
    feed: "camt053",
    opened_on: "2026-01-01",
  });
  if (error) throw error;
  await createConfirmedPayoutAccount(tenant, PAYOUT_IBAN, tenant.clientName.toUpperCase());
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

async function importStatement(page: Page, file: string, xml: string) {
  await page.goto("/backoffice/encaissements");
  const form = page.getByTestId("statement-upload");
  await form.getByLabel("Relevé CAMT.053 (XML)").setInputFiles({ name: file, mimeType: "application/xml", buffer: Buffer.from(xml, "utf-8") });
  await form.getByRole("button", { name: "Importer le relevé" }).click();
  await expectOwnImport(page);
}

async function joinDocument(page: Page, kind: string, file: string) {
  const upload = page.getByTestId("client-document-upload");
  const details = page.getByTestId("client-documents").locator("details").filter({ has: upload });
  if (!(await upload.isVisible())) await details.locator("summary").click();
  await upload.getByLabel("Type de document").selectOption(kind);
  await upload.getByLabel(/^Fichier/).setInputFiles(PDF(file));
  await upload.getByRole("button", { name: "Joindre le document" }).click();
  await expect(page.getByTestId("client-document").filter({ hasText: `${file}.pdf` })).toBeVisible();
}

/** A select's option chosen by its text (its value read from the page). */
async function selectByText(select: Locator, text: RegExp) {
  const value = await select.locator("option", { hasText: text }).first().getAttribute("value");
  await select.selectOption(value ?? "");
}

async function secondAdmin(browser: Browser, testInfo: TestInfo): Promise<Page> {
  const use = testInfo.project.use;
  const context = await browser.newContext({
    baseURL: use.baseURL,
    viewport: use.viewport,
    userAgent: use.userAgent,
    deviceScaleFactor: use.deviceScaleFactor,
    isMobile: use.isMobile,
    hasTouch: use.hasTouch,
  });
  const page = await context.newPage();
  await loginAsStaff(page, await createMember(tenant.servicerId, "admin"));
  return page;
}

async function paymentOf(ref: string): Promise<string> {
  const { data: line, error } = await adminClient()
    .from("bank_transaction")
    .select("id")
    .eq("organization_id", tenant.servicerId)
    .eq("acct_svcr_ref", ref)
    .single();
  if (error) throw error;
  const { data: payment } = await adminClient().from("payment").select("id").eq("bank_transaction_id", line.id).single();
  return payment!.id as string;
}

test("a death with its notary: the payment after it held and forwarded, the notary's account confirmed by a second admin, the run approved; a seizure and its release", async ({
  page,
  browser,
}, testInfo) => {
  test.setTimeout(420_000);
  await loginAsStaff(page, await createMember(tenant.servicerId, "admin"));
  await boardAndConfirm(page);
  const day = await statementDay();
  const dayFr = day.split("-").reverse().join("/");
  const before: Credit[] = [{ ref: "EV-1", amountMinor: BigInt(50000), name: "DIALLO", iban: ibanFr(41), rf: await rfOf("C2929") }];
  await importStatement(page, "releve-avant-deces.xml", camt053(BANK_IBAN, day, before));

  // the client's death, with its evidence and the notary who acts for the estate
  const clientPage = `/backoffice/clients/${tenant.clientId}/reversement`;
  await page.goto(clientPage);
  await joinDocument(page, "client_status_evidence", "Acte-de-deces");
  await joinDocument(page, "payout_authority_evidence", "Attestation-du-notaire");
  await joinDocument(page, "payout_rib", "RIB-notaire");
  const events = page.getByTestId("client-events");
  const form = page.getByTestId("record-event-form");
  const openForm = async () => {
    // the summary toggles the form: opened only when it is not shown already
    if (!(await form.isVisible())) await events.getByText("Enregistrer un événement").click();
  };
  await openForm();
  await form.getByRole("combobox", { name: "Événement", exact: true }).selectOption("death");
  await form.getByLabel("Date d'effet").fill(day);
  await form.getByLabel("Justificatif").selectOption({ label: "Acte-de-deces.pdf" });
  await form.getByLabel("Rôle").selectOption("notary");
  await form.getByLabel("Nom", { exact: true }).fill("Me Claire Lenoir, notaire");
  await form.getByLabel("Adresse (une ligne par ligne, quatre au plus)").fill("3 place du Palais\n69002 Lyon");
  await expect(form).toContainText("pour une révocation, le jour où elle a été notifiée au cabinet");
  await form.getByRole("button", { name: "Enregistrer l'événement" }).click();
  const death = events.getByTestId("client-event").filter({ hasText: "Décès" });
  await expect(death).toContainText(dayFr);
  await expect(death.getByTestId("client-event-representative")).toContainText(
    "Me Claire Lenoir, notaire (notaire) — 3 place du Palais, 69002 Lyon",
  );
  await expect(events.getByTestId("client-addressees")).toContainText("Me Claire Lenoir, notaire (notaire)");
  await expect(events.getByTestId("client-payee-rule")).toContainText("Compte exigé : celui de la succession");
  await reviewShot(page, testInfo, "m2c7-evenement-client");

  // a payment received after the death: held for ops, then forwarded to the client without allocation
  const after: Credit[] = [{ ref: "EV-2", amountMinor: BigInt(30000), name: "DIALLO", iban: ibanFr(41), rf: await rfOf("C2929") }];
  await importStatement(page, "releve-apres-deces.xml", camt053(BANK_IBAN, day, after));
  const held = await paymentOf("EV-2");
  await page.goto(`/backoffice/encaissements/paiements/${held}`);
  await expect(page.getByTestId("payment-reason")).toHaveText("Reçu après la fin du mandat", { timeout: 30_000 });
  await expect(page.getByText(/à reverser au client \(ou à son bénéficiaire\) ou à restituer au payeur/)).toBeVisible();
  await reviewShot(page, testInfo, "m2c7-paiement-apres-fin-mandat");
  await page.getByTestId("forward").getByRole("button", { name: "Reverser au client" }).click();
  const forward = page.getByRole("dialog", { name: "Reverser au client sans imputation" });
  await forward.getByLabel(/^Motif/).fill("Reçu après le décès du client (E2E)");
  await forward.getByRole("button", { name: "Confirmer le reversement" }).click();
  await expect
    .poll(async () => (await adminClient().from("payment").select("status").eq("id", held).single()).data?.status, {
      timeout: 15_000,
    })
    .toBe("allocated");
  const { data: told } = await adminClient()
    .from("client_notification")
    .select("reason")
    .eq("payment_id", held)
    .eq("kind", "payment_forwarded")
    .single();
  expect(told?.reason).toBe("mandate_ended");

  // the notary's IBAN, with the attestation (an estate's account is in the office's name: no holder rule)
  await page.goto(clientPage);
  const payouts = page.getByTestId("payout-accounts");
  await payouts.getByText("Proposer un IBAN de reversement").click();
  const propose = page.getByTestId("propose-payout-form");
  await selectByText(propose.getByRole("combobox", { name: "RIB", exact: true }), /RIB-notaire\.pdf/);
  await propose.getByLabel(/^IBAN/).fill(NOTARY_IBAN);
  await propose.getByLabel(/^Titulaire/).fill("SCP LENOIR NOTAIRES");
  await propose.getByLabel("Compte de").selectOption("estate");
  await selectByText(propose.getByLabel("Pièce désignant qui peut recevoir"), /Attestation-du-notaire\.pdf/);
  await propose.getByRole("button", { name: "Proposer l'IBAN" }).click();
  await expect(payouts.getByTestId("payout-account").filter({ hasText: "En attente de confirmation" })).toBeVisible();

  // the second admin: the holder's name beside the client's, the attestation, then the IBAN read on the RIB
  const admin2 = await secondAdmin(browser, testInfo);
  await admin2.goto(clientPage);
  const pending = admin2.getByTestId("payout-account").filter({ hasText: "En attente de confirmation" });
  await expect(pending.getByTestId("payout-names")).toContainText(`Titulaire du RIB : SCP LENOIR NOTAIRES · Nom du client : ${tenant.clientName}`);
  await expect(pending).toContainText("Succession — compte du notaire, ou compte désigné par tous les héritiers");
  await expect(pending.getByRole("link", { name: "Pièce désignant qui peut recevoir" })).toBeVisible();
  await pending.getByText("Confirmer (second administrateur)").click();
  await pending.getByTestId("confirm-payout-form").getByLabel("IBAN lu sur le RIB").fill(NOTARY_IBAN);
  await reviewShot(admin2, testInfo, "m2c7-beneficiaire-succession");
  await pending.getByTestId("confirm-payout-form").getByRole("button", { name: "Confirmer l'IBAN" }).click();
  await expect(admin2.getByTestId("payout-account").filter({ hasText: "SCP LENOIR NOTAIRES" }).getByTestId("payout-status")).toHaveText(
    "Confirmé",
  );
  await admin2.context().close();

  // the run: prepared now that the estate's account is confirmed after the death, then approved
  await page.goto("/backoffice/reversements");
  const waiting = page.getByTestId("prepare-row").filter({ hasText: tenant.clientName });
  const card = page.getByTestId("run-card").filter({ hasText: tenant.clientName });
  await expect(async () => {
    await page.reload();
    await expect(waiting.or(card)).toBeVisible({ timeout: 5_000 });
  }).toPass({ timeout: 90_000 });
  if (await waiting.isVisible()) {
    await waiting.getByRole("button", { name: "Préparer maintenant" }).click();
    await card.waitFor({ timeout: 15_000 }).catch(() => page.reload());
  }
  await expect(card.getByText("Brouillon", { exact: true })).toBeVisible({ timeout: 60_000 });
  await card.getByRole("link", { name: tenant.clientName }).click();
  await page.waitForURL(/\/backoffice\/reversements\/[0-9a-f-]{36}$/);
  const runPage = page.url();
  const blocked = page.getByText(/Virement bloqué : Décès du client/);
  if (await blocked.isVisible()) {
    // a draft prepared before the confirmation (the schedule's): prepared again
    await page.getByRole("button", { name: "Actualiser" }).click();
  }
  await expect(blocked).toHaveCount(0, { timeout: 60_000 });
  await page.getByTestId("run-select").check();
  await page.getByTestId("approve-open").click();
  const sheet = page.getByTestId("approve-sheet");
  const lateReason = sheet.getByLabel(/Motif du retard/);
  if (await lateReason.isVisible()) await lateReason.fill("Encaissement identifié tardivement (E2E)");
  await sheet.getByTestId("approve-confirm").click();
  await expect(page.getByTestId("run-status")).toHaveText("Validé — virement ordonné", { timeout: 60_000 });
  const { data: run } = await adminClient().from("remittance_run").select("transfer_id").eq("client_organization_id", tenant.clientId).eq("status", "approved").single();
  const { data: transfer } = await adminClient().from("bank_transfer").select("payee_iban").eq("id", run!.transfer_id).single();
  expect(transfer?.payee_iban).toBe(NOTARY_IBAN);
  expect(runPage).toContain("/backoffice/reversements/");

  // a seizure served on the servicer: listed as standing (no payout and no set-off until it is released: M2c-7d-2),
  // then released
  await page.goto(clientPage);
  await joinDocument(page, "client_status_evidence", "Acte-de-saisie");
  await openForm();
  await form.getByRole("combobox", { name: "Événement", exact: true }).selectOption("seizure");
  await form.getByLabel("Date d'effet").fill(day);
  await form.getByLabel("Justificatif").selectOption({ label: "Acte-de-saisie.pdf" });
  await form.getByRole("button", { name: "Enregistrer l'événement" }).click();
  const seizure = events.getByTestId("client-event").filter({ hasText: "Saisie entre les mains du cabinet" });
  await expect(seizure).toContainText("en cours");
  await expect(events.getByTestId("client-payee-rule")).toContainText("Saisie entre les mains du cabinet");
  // M2c-7d-2 (plan §6.2.6, §6.2.9; [critic] L14): the set-off is barred too, whatever the run's net
  await expect(page.getByText("ni reversement ni compensation jusqu'à sa mainlevée", { exact: false })).toBeVisible();
  await reviewShot(page, testInfo, "m2c7-saisie");
  await joinDocument(page, "client_status_evidence", "Mainlevee");
  await openForm();
  await form.getByRole("combobox", { name: "Événement", exact: true }).selectOption("seizure_released");
  await form.getByLabel("Date d'effet").fill(parisToday());
  await form.getByLabel("Justificatif").selectOption({ label: "Mainlevee.pdf" });
  await form.getByLabel("Saisie levée").selectOption({ index: 1 });
  await form.getByRole("button", { name: "Enregistrer l'événement" }).click();
  await expect(seizure).toContainText("levée le");
});
