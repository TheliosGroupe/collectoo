import { expect, test, type Page } from "@playwright/test";
import { createMember, createTenant, type Tenant } from "./support/admin";
import { latestCode } from "./support/mailpit";
import { totp } from "./support/totp";
import { reviewShot } from "./screenshot";

let tenant: Tenant;

test.beforeAll(async () => {
  tenant = await createTenant();
});

async function loginWithEmailCode(page: Page, email: string) {
  await page.goto("/connexion");
  await page.getByLabel("Adresse e-mail").fill(email);
  const requestedAt = new Date();
  await page.getByRole("button", { name: "Recevoir un code" }).click();
  await expect(page).toHaveURL(/\/connexion\/code/);
  await page.getByLabel("Code reçu par e-mail").fill(await latestCode(email, requestedAt));
  await page.getByRole("button", { name: "Se connecter" }).click();
}

test("login page", async ({ page }, testInfo) => {
  await page.goto("/connexion");
  await expect(page.getByRole("heading", { name: "Connexion" })).toBeVisible();
  await reviewShot(page, testInfo, "m0-login");
});

test("anonymous visitors are sent to login", async ({ page }) => {
  await page.goto("/backoffice");
  await expect(page).toHaveURL(/\/connexion$/);
  await page.goto("/client");
  await expect(page).toHaveURL(/\/connexion$/);
});

test("client user logs in with an email code and sees only their organization", async ({ page }, testInfo) => {
  const email = await createMember(tenant.clientId, "client_viewer");
  await loginWithEmailCode(page, email);
  await expect(page).toHaveURL(/\/client$/);
  await expect(page.getByTestId("org-name")).toHaveText(tenant.clientName);
  await expect(page.getByTestId("portfolio-list")).toContainText(tenant.portfolioName);
  await reviewShot(page, testInfo, "m0-client-space");

  await page.goto("/backoffice");
  await expect(page).toHaveURL(/\/client$/);
});

test("staff must enrol TOTP before reaching the back-office", async ({ page }, testInfo) => {
  const email = await createMember(tenant.servicerId, "admin");
  await loginWithEmailCode(page, email);
  // Logged in at aal1: the back-office redirects to MFA enrolment.
  await expect(page).toHaveURL(/\/mfa$/);
  const secret = (await page.getByTestId("totp-secret").textContent())?.trim() ?? "";
  expect(secret).toMatch(/^[A-Z2-7]+=*$/);
  await reviewShot(page, testInfo, "m0-mfa-enrol");

  await page.getByLabel("Code à 6 chiffres").fill(totp(secret));
  await page.getByRole("button", { name: "Valider" }).click();
  await expect(page).toHaveURL(/\/backoffice$/);
  await expect(page.getByTestId("client-list")).toContainText(tenant.clientName);
  await reviewShot(page, testInfo, "m0-backoffice");

  // Logout, then a fresh login asks for the TOTP code again (verify step, no new enrolment).
  await page.getByRole("button", { name: "Se déconnecter" }).click();
  await expect(page).toHaveURL(/\/connexion$/);
  await loginWithEmailCode(page, email);
  await expect(page).toHaveURL(/\/mfa$/);
  await expect(page.getByTestId("totp-secret")).toHaveCount(0);
  await page.getByLabel("Code à 6 chiffres").fill(totp(secret));
  await page.getByRole("button", { name: "Valider" }).click();
  await expect(page).toHaveURL(/\/backoffice$/);
});
