import { expect, test, type Locator, type Page, type TestInfo } from "@playwright/test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { CLIENT_SIREN, createMandate, createMember, createTenant, recordClientEvent } from "./support/admin";
import { ibanFr } from "./support/camt";
import { loginAsStaff, loginWithEmailCode } from "./support/session";
import { totp } from "./support/totp";
import { reviewShot } from "./screenshot";

/**
 * M2c-2 (CPCE-03, M2-13 data): the servicer's billing identity and settings (what receipts now print: SIREN, RCS,
 * registered office, C. com. R123-237/238); a client's identity and its mandate's money terms (R124-3 2°–4°) until its
 * portfolio is ready for confirmation (design §9.1); a payout IBAN proposed by ops with the client's RIB and confirmed
 * by a second person — the client's administrator, at aal2, typing the IBAN from its own records (founder #10; the
 * RIB sent to the servicer is not linked while the proposal waits, review M2c-2). New money terms start tomorrow at the
 * earliest (review M2c-2). The batch page lists what keeps a portfolio from being confirmed, client events included,
 * and offers no « Confirmer le lot » then. Synthetic data.
 */

const BATCH_FIXTURE = {
  name: "Créances à confirmer.csv",
  mimeType: "text/csv",
  buffer: readFileSync(path.resolve(__dirname, "fixtures/factures-imputation.csv")),
};

/** Tomorrow in Europe/Paris (YYYY-MM-DD): the earliest start of a new version of the money terms. */
function parisTomorrow(): string {
  const today = new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Paris" }).format(new Date());
  const [y, m, d] = today.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + 1)).toISOString().slice(0, 10);
}

const fr = (iso: string) => iso.split("-").reverse().join("/");

const PDF = (text: string) => ({ name: `${text}.pdf`, mimeType: "application/pdf", buffer: Buffer.from(`%PDF-1.4\n% ${text}\n%%EOF\n`) });

async function office(scope: Locator, legend: string, line1: string, postcode: string, city: string) {
  const group = scope.getByRole("group", { name: legend });
  await group.getByLabel("Adresse", { exact: true }).fill(line1);
  await group.getByLabel("Code postal").fill(postcode);
  await group.getByLabel("Ville", { exact: true }).fill(city);
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

test("an admin completes the servicer's billing identity and its billing settings", async ({ page }, testInfo) => {
  test.setTimeout(120_000);
  const tenant = await createTenant();
  await loginAsStaff(page, await createMember(tenant.servicerId, "admin"));
  await page.getByTestId("billing-settings-link").click();
  await expect(page).toHaveURL(/\/backoffice\/parametres\/facturation$/);
  await expect(page.getByTestId("identity-gaps")).toContainText("identité de facturation non saisie");

  const form = page.getByTestId("servicer-identity-form");
  await form.getByLabel("SIREN").fill("849 678 297");
  await form.getByLabel("Forme juridique").selectOption("SAS");
  await form.getByLabel("Capital social (€)").fill("10 000");
  await form.getByLabel("Ville du greffe (RCS)").fill("Paris");
  await form.getByLabel(/^N° de TVA/).fill("FR34849678297");
  await office(form, "Siège social", "10 rue de la Bourse", "75002", "Paris");
  await form.getByRole("button", { name: "Enregistrer l'identité" }).click();
  await expect(form.getByRole("alert")).toContainText("ne correspond pas au SIREN");
  await form.getByLabel(/^N° de TVA/).fill("FR 33 849678297");
  await form.getByRole("button", { name: "Enregistrer l'identité" }).click();

  const preview = page.getByTestId("issuer-preview");
  await expect(preview).toContainText("SAS au capital de 10 000 €");
  await expect(preview).toContainText("SIREN 849 678 297 · RCS Paris");
  await expect(preview).toContainText("Siège social : 10 rue de la Bourse, 75002 Paris");
  await expect(preview).toContainText("TVA intracommunautaire FR33849678297");

  const settings = page.getByTestId("billing-settings");
  await settings.getByText("Modifier les paramètres").click();
  const settingsForm = page.getByTestId("billing-settings-form");
  await settingsForm.getByLabel(/^Préfixe des factures/).fill("f");
  await settingsForm.getByRole("button", { name: "Enregistrer les paramètres" }).click();
  await expect(settingsForm.getByRole("alert")).toContainText("2 à 6 lettres majuscules");
  await settingsForm.getByLabel(/^Préfixe des factures/).fill("fc");
  await settingsForm.getByRole("button", { name: "Enregistrer les paramètres" }).click();
  await expect(page.getByTestId("invoice-prefix")).toContainText(/^FC-\d{4}-000001/);
  await expect(settings).toContainText("Sur les encaissements");
  await page.reload(); // the forms closed
  await expect(page.getByTestId("issuer-preview")).toBeVisible();
  await reviewShot(page, testInfo, "m2c-facturation");
});

test("an admin completes a client's identity and its mandate's money terms, which start tomorrow at the earliest", async ({
  page,
}, testInfo) => {
  test.setTimeout(150_000);
  const tenant = await createTenant();
  await createMandate(tenant, { complete: false }); // a version written before M2c-2: a rate only
  await loginAsStaff(page, await createMember(tenant.servicerId, "admin"));
  await page.getByTestId("clients-link").click();
  await expect(page.getByTestId("client-row").filter({ hasText: tenant.clientName })).toContainText("1 portefeuille à compléter");
  await reviewShot(page, testInfo, "m2c-clients");
  await page.getByRole("link", { name: tenant.clientName }).click();
  await expect(page).toHaveURL(/\/backoffice\/clients\/[0-9a-f-]+\/reversement$/);
  const readiness = page.getByTestId("client-readiness");
  await expect(readiness).toContainText("Barème de commission absent (R124-3 3°)");
  await expect(readiness).toContainText("Clause de garantie du mandat non renseignée");
  await expect(readiness).toContainText("Identité du client incomplète");

  // the client's identity: a professional established in mainland France — an explicit choice, never pre-ticked; a
  // client's liquidation is an event (« Événements du client »), not a box of its identity (review M2c-2)
  const identity = page.getByTestId("client-identity-form");
  await expect(identity.getByLabel("Oui, un professionnel")).not.toBeChecked();
  await expect(identity.getByLabel("Non", { exact: true })).not.toBeChecked();
  await expect(identity.getByRole("checkbox", { name: /liquidation/ })).toHaveCount(0);
  await expect(identity.getByTestId("client-liquidation-note")).toContainText("« Événements du client »");
  await identity.getByLabel("SIREN").fill(CLIENT_SIREN);
  await office(identity, "Siège social", "12 rue des Artisans", "69003", "Lyon");
  await identity.getByLabel("Oui, un professionnel").check();
  await identity.getByRole("button", { name: "Enregistrer l'identité" }).click();
  await expect(page.getByTestId("client-identity")).toContainText("Complète");

  // the signed amendment, the insurance clause (2°), then the money terms (3°, 4°) from tomorrow
  await joinDocument(page, "mandate_document", "Avenant-1");
  const mandate = page.getByTestId("mandate");
  await mandate.getByText("Clause de garantie").click();
  await mandate.getByLabel("Référence de la clause").fill("art. 9 — Garantie");
  await mandate.getByRole("button", { name: "Enregistrer la clause" }).click();
  await expect(mandate.getByTestId("insurance-clause")).toContainText("art. 9 — Garantie");

  await mandate.getByText("Nouvelles conditions financières").click();
  const terms = page.getByTestId("terms-form");
  const tomorrow = parisTomorrow();
  await expect(terms.getByLabel("En vigueur à partir du")).toHaveValue(tomorrow);
  await expect(terms.getByLabel("En vigueur à partir du")).toHaveAttribute("min", tomorrow);
  await terms.getByLabel("Clause de rémunération").fill("art. 6 — Rémunération (avenant 1)");
  await terms.getByLabel("Clause de reversement").fill("art. 7 — Reversements");
  await terms.getByLabel(/^Clause de compensation/).fill("art. 7.2");
  await terms.getByLabel(/^Barème de commission/).fill("{ pas du JSON");
  await terms.getByRole("button", { name: "Enregistrer la version" }).click();
  await expect(terms.getByRole("alert")).toContainText("n'est pas un JSON lisible");
  await terms.getByLabel(/^Barème de commission/).fill(
    JSON.stringify({
      schema: "commission-1",
      basis: {
        families: "all",
        forwards: { file_recalled: false, before_servicing_start: false, client_ratification: false },
        on_reversal: "credit",
      },
      rules: [
        {
          id: "b2b",
          tier_key: "b2b",
          label_fr: "Factures entre professionnels",
          match: { claim_types: ["b2b_invoice"] },
          rate: { kind: "flat", rate: "0.15" },
        },
        {
          id: "autres",
          tier_key: "autres",
          label_fr: "Autres créances",
          match: {},
          rate: { kind: "marginal", tiers: [{ up_to_minor: "500000", rate: "0.10" }, { up_to_minor: null, rate: "0.06" }] },
          min_per_file_minor: "3000",
        },
      ],
    }),
  );
  await terms.getByRole("button", { name: "Enregistrer la version" }).click();
  const versions = page.getByTestId("terms-version");
  await expect(versions).toHaveCount(2);
  await expect(versions.nth(1)).toContainText(`Du ${fr(tomorrow)} · à venir`);
  await expect(versions.nth(1).getByTestId("schedule-words")).toContainText("Factures entre professionnels");
  await expect(versions.nth(1).getByTestId("schedule-words")).toContainText("15 %");
  await expect(versions.nth(1).getByTestId("schedule-words")).toContainText(
    "10 % jusqu'à 5 000,00 €, 6 % au-delà de 5 000,00 € encaissés sur le dossier ; minimum 30,00 € par dossier",
  );
  await expect(versions.nth(1).getByTestId("schedule-words")).toContainText("Commission compensée sur chaque reversement (art. 7.2)");
  // the version in force (written before M2c-2) ends tonight: today's collections stay under it, so the portfolio is
  // ready only once the new version is in force — what is left are its gaps, not the identity nor the insurance clause
  await expect(versions.nth(0)).toContainText(`au ${fr(tomorrow)} (exclu) · en vigueur`);
  const left = readiness.getByTestId("portfolio-readiness");
  await expect(left).toContainText("À compléter");
  await expect(left).toContainText("Barème de commission absent (R124-3 3°)");
  await expect(left).not.toContainText("Clause de garantie du mandat non renseignée");
  await expect(left).not.toContainText("Identité du client incomplète");
  await page.reload(); // the forms closed
  await expect(page.getByTestId("terms-version")).toHaveCount(2);
  await reviewShot(page, testInfo, "m2c-conditions");
});

async function clientPage(browser: import("@playwright/test").Browser, testInfo: TestInfo): Promise<Page> {
  const use = testInfo.project.use;
  const context = await browser.newContext({
    baseURL: use.baseURL,
    viewport: use.viewport,
    userAgent: use.userAgent,
    deviceScaleFactor: use.deviceScaleFactor,
    isMobile: use.isMobile,
    hasTouch: use.hasTouch,
  });
  return context.newPage();
}

test("ops propose the client's payout IBAN with its RIB; the client's administrator confirms it at aal2", async ({ page, browser }, testInfo) => {
  test.setTimeout(150_000);
  const tenant = await createTenant();
  await createMandate(tenant);
  const iban = ibanFr(Number.parseInt(tenant.clientId.slice(0, 6), 16));
  await loginAsStaff(page, await createMember(tenant.servicerId, "ops_manager"));
  await page.goto(`/backoffice/clients/${tenant.clientId}/reversement`);
  await expect(page.getByTestId("portfolio-readiness")).toContainText("Prêt");
  await joinDocument(page, "payout_rib", "RIB-client");

  const payouts = page.getByTestId("payout-accounts");
  await payouts.getByText("Proposer un IBAN de reversement").click();
  const propose = page.getByTestId("propose-payout-form");
  await propose.getByLabel(/^IBAN/).fill(iban.replace(/(.{4})/g, "$1 "));
  await propose.getByLabel(/^Titulaire/).fill(tenant.clientName.toUpperCase());
  await propose.getByRole("button", { name: "Proposer l'IBAN" }).click();
  const account = payouts.getByTestId("payout-account");
  await expect(account).toHaveCount(1);
  await expect(account.getByTestId("payout-status")).toHaveText("En attente de confirmation");
  await expect(account.getByTestId("payout-iban")).toHaveText(`${iban.slice(0, 4)} •••• •••• ${iban.slice(-4)}`);
  await expect(page.getByTestId("confirm-payout-form")).toHaveCount(0); // an ops manager never confirms
  await reviewShot(page, testInfo, "m2c-client-iban");

  // The client's administrator, in its own browser: the step-up to aal2, then the IBAN read on its RIB
  const client = await clientPage(browser, testInfo);
  await loginWithEmailCode(client, await createMember(tenant.clientId, "client_admin"));
  await expect(client).toHaveURL(/\/client$/);
  await client.getByTestId("client-mandate-link").click();
  await expect(client.getByTestId("client-terms")).toContainText("Reversements deux fois par mois");
  // the client checks the IBAN against its own records: the RIB sent to the servicer is not linked (review M2c-2)
  await expect(client.getByTestId("client-payout-account").getByRole("link", { name: "RIB transmis" })).toHaveCount(0);
  await client.getByTestId("client-mfa-link").click();
  await expect(client).toHaveURL(/\/mfa\?next=/);
  const secret = (await client.getByTestId("totp-secret").textContent())?.trim() ?? "";
  await client.getByLabel("Code à 6 chiffres").fill(totp(secret));
  await client.getByRole("button", { name: "Valider" }).click();
  await expect(client).toHaveURL(/\/client\/mandat$/);
  const confirm = client.getByTestId("client-confirm-payout");
  await expect(client.getByTestId("client-payout-account").getByRole("link", { name: "RIB transmis" })).toHaveCount(0);
  await confirm.getByLabel("IBAN de votre compte").fill(ibanFr(Number.parseInt(tenant.clientId.slice(0, 6), 16) + 1));
  await confirm.getByRole("button", { name: "Confirmer le nouvel IBAN" }).click();
  await expect(confirm.getByRole("alert")).toContainText("n'est pas celui proposé");
  await confirm.getByLabel("IBAN de votre compte").fill(iban);
  await confirm.getByRole("button", { name: "Confirmer le nouvel IBAN" }).click();
  await expect(client.getByTestId("client-payout-account")).toContainText("Confirmé");
  await expect(client.getByTestId("client-payout-account")).toContainText("confirmé par le client, dans son espace");
  await expect(client.getByTestId("client-payout-account").getByRole("link", { name: "RIB transmis" })).toHaveCount(1);
  await reviewShot(client, testInfo, "m2c-client-mandat");
  await client.context().close();

  await page.reload();
  await expect(account.getByTestId("payout-status")).toHaveText("Confirmé");
  await expect(account).toContainText("Nouvel IBAN : premier virement à vérifier");
});

test("the batch page lists what keeps the portfolio from being confirmed, a client event with its date, and no « Confirmer le lot »", async ({
  page,
}, testInfo) => {
  test.setTimeout(180_000);
  const tenant = await createTenant();
  await createMandate(tenant, { complete: false }); // a version written before M2c-2, no client identity
  const admin = await createMember(tenant.servicerId, "admin");
  await recordClientEvent(tenant, "mandate_ended", "2026-01-20", admin);
  await loginAsStaff(page, await createMember(tenant.servicerId, "ops_manager"));

  await page.goto("/backoffice/reprises/nouveau");
  await page.getByLabel("Date d'arrêté du portefeuille").fill("2026-09-30");
  await page.getByLabel("Fichiers").setInputFiles(BATCH_FIXTURE);
  await page.getByLabel("Encours restant dû à la date d'arrêté (€)").fill("4 800,00");
  await page.getByLabel("Nombre de lignes du fichier").fill("8");
  await page.getByRole("button", { name: "Déposer et analyser" }).click();
  const status = page.getByTestId("batch-status");
  await expect(status).toHaveText("Mapping à valider", { timeout: 60_000 });
  await page.getByRole("button", { name: "Valider le mapping" }).click();
  await expect(status).toHaveText("Prêt à intégrer", { timeout: 60_000 });
  await page.getByRole("button", { name: "Intégrer le lot" }).click();
  await expect(status).toHaveText("Intégré, à confirmer", { timeout: 60_000 });

  // the confirmation gate (design §9.1), listed before anything is sent: the mandate's money terms, the client's
  // identity and the end of the mandate recorded for the client, with its date (review M2c-2)
  const gate = page.getByTestId("batch-readiness");
  await expect(gate).toContainText("Le lot ne peut pas encore être confirmé");
  await expect(gate).toContainText("Barème de commission absent (R124-3 3°)");
  await expect(gate).toContainText("Clause de garantie du mandat non renseignée (R124-3 2°)");
  await expect(gate).toContainText("Identité du client incomplète (SIREN, siège social)");
  await expect(gate).toContainText("Mandat terminé le 20/01/2026");
  await expect(gate.getByTestId("batch-readiness-client")).toHaveAttribute("href", `/backoffice/clients/${tenant.clientId}/reversement`);
  await expect(page.getByRole("button", { name: "Confirmer le lot" })).toHaveCount(0);
  await reviewShot(page, testInfo, "m2c-batch-readiness");

  // the client's page says the same, with the way to the event
  await gate.getByTestId("batch-readiness-client").click();
  await expect(page).toHaveURL(new RegExp(`/backoffice/clients/${tenant.clientId}/reversement$`));
  const readiness = page.getByTestId("portfolio-readiness");
  await expect(readiness).toContainText("Mandat terminé le 20/01/2026");
  await expect(readiness.getByRole("link", { name: "voir les événements" })).toHaveAttribute("href", "#evenements");
  await expect(page.getByTestId("client-event")).toContainText("Fin du mandat");
});
