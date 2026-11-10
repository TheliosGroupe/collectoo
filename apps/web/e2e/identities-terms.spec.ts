import { expect, test, type Locator, type Page, type TestInfo } from "@playwright/test";
import { CLIENT_SIREN, createMandate, createMember, createTenant } from "./support/admin";
import { ibanFr } from "./support/camt";
import { loginAsStaff, loginWithEmailCode } from "./support/session";
import { totp } from "./support/totp";
import { reviewShot } from "./screenshot";

/**
 * M2c-2 (CPCE-03, M2-13 data): the servicer's billing identity and settings (what receipts now print: SIREN, RCS,
 * registered office, C. com. R123-237/238); a client's identity and its mandate's money terms (R124-3 2°–4°) until its
 * portfolio is ready for confirmation (design §9.1); a payout IBAN proposed by ops with the client's RIB and confirmed
 * by a second person — the client's administrator, at aal2, typing the IBAN of its RIB (founder #10). Synthetic data.
 */

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

test("an admin completes a client's identity and its mandate's money terms: the portfolio becomes ready", async ({ page }, testInfo) => {
  test.setTimeout(150_000);
  const tenant = await createTenant();
  await createMandate(tenant, { complete: false }); // a version written before M2c-2: a rate only
  await loginAsStaff(page, await createMember(tenant.servicerId, "admin"));
  await page.getByTestId("clients-link").click();
  await expect(page.getByTestId("client-row").filter({ hasText: tenant.clientName })).toContainText("1 portefeuille à compléter");
  await page.getByRole("link", { name: tenant.clientName }).click();
  await expect(page).toHaveURL(/\/backoffice\/clients\/[0-9a-f-]+\/reversement$/);
  const readiness = page.getByTestId("client-readiness");
  await expect(readiness).toContainText("Barème de commission absent (R124-3 3°)");
  await expect(readiness).toContainText("Clause de garantie du mandat non renseignée");
  await expect(readiness).toContainText("Identité du client incomplète");

  // the client's identity: a professional established in mainland France
  const identity = page.getByTestId("client-identity-form");
  await identity.getByLabel("SIREN").fill(CLIENT_SIREN);
  await office(identity, "Siège social", "12 rue des Artisans", "69003", "Lyon");
  await identity.getByRole("button", { name: "Enregistrer l'identité" }).click();
  await expect(page.getByTestId("client-identity")).toContainText("Complète");

  // the signed amendment, the insurance clause (2°), then the money terms (3°, 4°) from today
  await joinDocument(page, "mandate_document", "Avenant-1");
  const mandate = page.getByTestId("mandate");
  await mandate.getByText("Clause de garantie").click();
  await mandate.getByLabel("Référence de la clause").fill("art. 9 — Garantie");
  await mandate.getByRole("button", { name: "Enregistrer la clause" }).click();
  await expect(mandate.getByTestId("insurance-clause")).toContainText("art. 9 — Garantie");

  await mandate.getByText("Nouvelles conditions financières").click();
  const terms = page.getByTestId("terms-form");
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
  await expect(versions.nth(1)).toContainText("en vigueur");
  await expect(versions.nth(1).getByTestId("schedule-words")).toContainText("Factures entre professionnels");
  await expect(versions.nth(1).getByTestId("schedule-words")).toContainText("15 %");
  await expect(versions.nth(1).getByTestId("schedule-words")).toContainText(
    "10 % jusqu'à 5 000,00 €, 6 % au-delà de 5 000,00 € encaissés sur le dossier ; minimum 30,00 € par dossier",
  );
  await expect(versions.nth(1).getByTestId("schedule-words")).toContainText("Commission compensée sur chaque reversement (art. 7.2)");
  await expect(versions.nth(0)).toContainText("terminée");
  await expect(readiness.getByTestId("portfolio-readiness")).toContainText("Prêt");
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
  await client.getByTestId("client-mfa-link").click();
  await expect(client).toHaveURL(/\/mfa\?next=/);
  const secret = (await client.getByTestId("totp-secret").textContent())?.trim() ?? "";
  await client.getByLabel("Code à 6 chiffres").fill(totp(secret));
  await client.getByRole("button", { name: "Valider" }).click();
  await expect(client).toHaveURL(/\/client\/mandat$/);
  const confirm = client.getByTestId("client-confirm-payout");
  await confirm.getByLabel("IBAN de votre RIB").fill(ibanFr(Number.parseInt(tenant.clientId.slice(0, 6), 16) + 1));
  await confirm.getByRole("button", { name: "Confirmer le nouvel IBAN" }).click();
  await expect(confirm.getByRole("alert")).toContainText("n'est pas celui proposé");
  await confirm.getByLabel("IBAN de votre RIB").fill(iban);
  await confirm.getByRole("button", { name: "Confirmer le nouvel IBAN" }).click();
  await expect(client.getByTestId("client-payout-account")).toContainText("Confirmé");
  await expect(client.getByTestId("client-payout-account")).toContainText("confirmé par le client, dans son espace");
  await reviewShot(client, testInfo, "m2c-client-mandat");
  await client.context().close();

  await page.reload();
  await expect(account.getByTestId("payout-status")).toHaveText("Confirmé");
  await expect(account).toContainText("Nouvel IBAN : premier virement à vérifier");
});
