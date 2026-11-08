import { expect, test } from "@playwright/test";
import { createMember, createTenant, type Tenant } from "./support/admin";
import { loginWithEmailCode } from "./support/session";
import { totp } from "./support/totp";
import { reviewShot } from "./screenshot";

let tenant: Tenant;

test.beforeAll(async () => {
  tenant = await createTenant();
});

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
  // Auth sends at most one code per address per second (supabase/config.toml max_frequency).
  await page.waitForTimeout(1_100);
  await loginWithEmailCode(page, email);
  await expect(page).toHaveURL(/\/mfa$/);
  await expect(page.getByTestId("totp-secret")).toHaveCount(0);
  await page.getByLabel("Code à 6 chiffres").fill(totp(secret));
  await page.getByRole("button", { name: "Valider" }).click();
  await expect(page).toHaveURL(/\/backoffice$/);
});
