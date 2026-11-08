import { expect, type Page } from "@playwright/test";
import { latestCode } from "./mailpit";
import { totp } from "./totp";

export async function loginWithEmailCode(page: Page, email: string) {
  await page.goto("/connexion");
  await page.getByLabel("Adresse e-mail").fill(email);
  const requestedAt = new Date();
  await page.getByRole("button", { name: "Recevoir un code" }).click();
  await expect(page).toHaveURL(/\/connexion\/code/);
  await page.getByLabel("Code reçu par e-mail").fill(await latestCode(email, requestedAt));
  await page.getByRole("button", { name: "Se connecter" }).click();
}

/** Staff login: email code, then TOTP enrolment; ends on the back-office at aal2. */
export async function loginAsStaff(page: Page, email: string) {
  await loginWithEmailCode(page, email);
  await expect(page).toHaveURL(/\/mfa$/);
  const secret = (await page.getByTestId("totp-secret").textContent())?.trim() ?? "";
  await page.getByLabel("Code à 6 chiffres").fill(totp(secret));
  await page.getByRole("button", { name: "Valider" }).click();
  await expect(page).toHaveURL(/\/backoffice$/);
}
