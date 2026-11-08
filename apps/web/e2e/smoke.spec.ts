import { expect, test } from "@playwright/test";
import { reviewShot } from "./screenshot";

test("home page renders the three surfaces", async ({ page }, testInfo) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Collectoo" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Espace débiteur" })).toBeVisible();
  await reviewShot(page, testInfo, "m0-home");
});
