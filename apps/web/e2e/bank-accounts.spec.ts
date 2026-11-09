import { expect, test } from "@playwright/test";
import { createMember, createTenant, type Tenant } from "./support/admin";
import { loginAsStaff } from "./support/session";
import { reviewShot } from "./screenshot";


/**
 * M2b-1: the dedicated client-funds bank account (CPCE R124-2) is registered and closed by an
 * admin; ops managers only read it. M2c-1: one active client-funds account per currency, the
 * servicer's own account, and a top-up of the dedicated account ordered from it (our TOP id).
 * IBANs are synthetic (valid check digits, no real account).
 */
let tenant: Tenant;

test.beforeAll(async () => {
  tenant = await createTenant();
});

test("an admin registers the client-funds account, then closes an account opened by mistake", async ({ page }, testInfo) => {
  test.setTimeout(120_000);
  await loginAsStaff(page, await createMember(tenant.servicerId, "admin"));
  await page.getByTestId("bank-accounts-link").click();
  await expect(page).toHaveURL(/\/backoffice\/parametres\/comptes-bancaires$/);
  await expect(page.getByText("Aucun compte bancaire enregistré")).toBeVisible();

  const form = page.getByTestId("add-bank-account");
  await form.getByLabel("Libellé").fill("Fonds de tiers – Banque A");
  await form.getByLabel("IBAN").fill("fr76 3000 4000 0312 3456 7890 144");
  await form.getByLabel("BIC (facultatif)").fill("bnpafrppxxx");
  await form.getByRole("button", { name: "Ajouter le compte" }).click();
  await expect(form.getByRole("alert")).toContainText("IBAN invalide");

  // Pasted from a bank PDF: non-breaking spaces between the groups.
  await form.getByLabel("IBAN").fill("fr76\u00a03000\u00a04000\u00a00312 3456 7890 143");
  await form.getByRole("button", { name: "Ajouter le compte" }).click();
  const list = page.getByTestId("bank-accounts");
  await expect(list.getByTestId("iban")).toHaveText("FR76 3000 4000 0312 3456 7890 143");
  await expect(list).toContainText("Fonds de tiers – Banque A");
  await expect(list).toContainText("BNPAFRPPXXX");
  await expect(list).toContainText("Actif");
  await expect(form.getByLabel("IBAN")).toHaveValue("");

  // M2c-1: one active client-funds account per currency (founder #14)
  await form.getByLabel("Libellé").fill("Deuxième compte dédié");
  await form.getByLabel("IBAN").fill("FR3430001007940000000001001");
  await form.getByRole("button", { name: "Ajouter le compte" }).click();
  await expect(form.getByRole("alert")).toContainText("déjà actif dans cette devise");

  // M2c-1: the servicer's own account (no statement feed)
  const own = page.getByTestId("add-own-account");
  await own.getByLabel("Libellé").fill("Compte propre – Banque A");
  await own.getByLabel("IBAN").fill("FR7030001007940000000002002");
  await own.getByRole("button", { name: "Ajouter le compte propre" }).click();
  await expect(list.getByTestId("bank-account")).toHaveCount(2);
  const ownCard = list.getByTestId("bank-account").filter({ hasText: "Compte propre – Banque A" });
  await expect(ownCard.getByTestId("purpose")).toHaveText("Compte propre du cabinet · EUR");
  await expect(ownCard).toContainText("Non importés (compte propre)");
  await own.getByLabel("IBAN").fill("FR7030001007940000000002002");
  await own.getByLabel("Libellé").fill("Doublon");
  await own.getByRole("button", { name: "Ajouter le compte propre" }).click();
  await expect(own.getByRole("alert")).toContainText("déjà enregistré");
  await reviewShot(page, testInfo, "m2-bank-accounts");

  // A top-up of the dedicated account from the own account: our TOP reference, nothing booked yet
  await ownCard.getByText("Approvisionner « Fonds de tiers – Banque A »").click();
  const topUp = ownCard.getByTestId("top-up");
  await topUp.getByLabel("Montant (EUR)").fill("200,00");
  await topUp.getByLabel("Motif (interne)").fill("Frais bancaires du mois");
  await topUp.getByRole("button", { name: "Demander l'approvisionnement" }).click();
  const topUps = page.getByTestId("top-ups");
  await expect(topUps.getByTestId("top-up-row")).toHaveCount(1);
  await expect(topUps.getByTestId("top-up-ref")).toHaveText(/^TOP[0-9A-F]{12}$/);
  await expect(topUps).toContainText("À exécuter depuis le compte propre");
  await expect(topUps).toContainText("200,00");
  await reviewShot(page, testInfo, "m2c-top-up");

  // A second account, registered by mistake (in another currency), then closed (no money on it).
  await form.getByLabel("Libellé").fill("Compte ouvert par erreur");
  await form.getByLabel("IBAN").fill("FR1420041010050500013M02606");
  await form.getByLabel("Devise").selectOption("USD");
  await form.getByLabel("Format des relevés").selectOption("csv");
  await form.getByRole("button", { name: "Ajouter le compte" }).click();
  await expect(list.getByTestId("bank-account")).toHaveCount(3);

  const mistaken = list.getByTestId("bank-account").filter({ hasText: "Compte ouvert par erreur" });
  await mistaken.getByText("Clôturer ce compte").click();
  await mistaken.getByLabel("Motif de la clôture").fill("Ouvert par erreur");
  await mistaken.getByLabel(/4 derniers caractères/).fill("0000");
  await mistaken.getByRole("button", { name: "Clôturer le compte" }).click();
  await expect(mistaken.getByRole("alert")).toContainText("4 derniers caractères");
  await mistaken.getByLabel(/4 derniers caractères/).fill("2606");
  await mistaken.getByRole("button", { name: "Clôturer le compte" }).click();
  await expect(mistaken).toContainText("Clôturé");
  await expect(mistaken.getByTestId("closed-on")).toContainText("Ouvert par erreur");
  await reviewShot(page, testInfo, "m2-bank-account-closed");
});

test("an ops manager reads the bank accounts but cannot add one", async ({ page }) => {
  test.setTimeout(90_000);
  await loginAsStaff(page, await createMember(tenant.servicerId, "ops_manager"));
  await page.goto("/backoffice/parametres/comptes-bancaires");
  await expect(page.getByText("Seuls les administrateurs ajoutent ou clôturent un compte.")).toBeVisible();
  await expect(page.getByTestId("add-bank-account")).toHaveCount(0);
});
