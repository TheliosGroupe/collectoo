import { expect, test } from "@playwright/test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { adminClient, createMember, createTenant, type Tenant } from "./support/admin";
import { loginAsStaff } from "./support/session";
import { reviewShot } from "./screenshot";

/**
 * M2b-2: an ops manager imports the client-funds account's camt.053 statements; the payments of each
 * statement day are booked at once; the same file again creates nothing; an overlapping statement adds
 * only its new lines. Files from `synth camt053 --lines 28 --seed 1161 --days 2 --overlap 1 --version 08`
 * (synthetic names and IBANs; the manifest next to each file is its ground truth).
 */
const FIXTURES = path.resolve(__dirname, "fixtures");
const IBAN = "FR7637786653800890947644808"; // synthetic, the fixtures' account
const FIRST = "camt053-s1161";
const OVERLAP = "camt053-s1161-overlap";

type Manifest = { lines: { direction: string; kind: string; booking_date: string }[] };

function manifest(name: string): Manifest {
  return JSON.parse(readFileSync(path.join(FIXTURES, `${name}.manifest.json`), "utf-8")) as Manifest;
}

function paidCount(m: Manifest): number {
  return m.lines.filter((l) => l.direction === "credit" && ["debtor_credit", "batch_unsplit"].includes(l.kind)).length;
}

let tenant: Tenant;

test.beforeAll(async () => {
  tenant = await createTenant();
  const { error } = await adminClient().from("bank_account").insert({
    organization_id: tenant.servicerId,
    iban: IBAN,
    currency: "EUR",
    label: "Fonds de tiers – Banque A",
    feed: "camt053",
    opened_on: "2026-01-01",
  });
  if (error) throw error;
});

async function importFile(page: import("@playwright/test").Page, name: string) {
  await page.goto("/backoffice/encaissements");
  const form = page.getByTestId("statement-upload");
  await form.getByLabel("Relevé CAMT.053 (XML)").setInputFiles(path.join(FIXTURES, `${name}.xml`));
  await form.getByRole("button", { name: "Importer le relevé" }).click();
  await expect(page).toHaveURL(/\/backoffice\/encaissements\/releves\/[0-9a-f-]{36}(\?deja=1)?$/);
}

test("an ops manager imports a statement, the same file again, then an overlapping one", async ({ page }, testInfo) => {
  test.setTimeout(180_000);
  await loginAsStaff(page, await createMember(tenant.servicerId, "ops_manager"));
  await page.getByTestId("statements-link").click();
  await expect(page).toHaveURL(/\/backoffice\/encaissements$/);
  await expect(page.getByText("Aucun relevé importé")).toBeVisible();

  const first = manifest(FIRST);
  await importFile(page, FIRST);
  await expect(page.getByTestId("statement-status")).toHaveText("Importé", { timeout: 60_000 });
  await expect(page.getByTestId("count-lines")).toHaveText(String(first.lines.length));
  await expect(page.getByTestId("count-known")).toHaveText("0");
  await expect(page.getByTestId("count-payments")).toContainText(`${paidCount(first)} ·`);
  await expect(page.getByTestId("bank-check")).toContainText("Solde de clôture rapproché ✓");
  await expect(page.getByTestId("cash-in").getByRole("listitem")).toHaveCount(2); // one cash entry per day
  const lines = page.getByTestId("line-list").getByRole("listitem");
  await expect(lines).toHaveCount(first.lines.length);
  await expect(lines.filter({ hasText: "Comptabilisé · à affecter" })).toHaveCount(paidCount(first));
  await reviewShot(page, testInfo, "m2-statement-imported");
  await page.getByRole("link", { name: "À classer" }).click();
  await expect(lines).toHaveCount(first.lines.length - paidCount(first));
  await expect(lines.first()).toContainText("Non comptabilisé · à classer");

  // The same file again: the page opens the statement already imported, nothing is booked twice.
  await importFile(page, FIRST);
  await expect(page.getByText("Ce fichier a déjà été déposé pour ce compte")).toBeVisible();

  // An overlapping statement (its first day was in the first one): only the new lines count.
  const overlap = manifest(OVERLAP);
  await importFile(page, OVERLAP);
  await expect(page.getByTestId("statement-status")).toHaveText("Importé", { timeout: 60_000 });
  const known = overlap.lines.filter((l) => l.booking_date === "2026-10-02").length;
  await expect(page.getByTestId("count-known")).toHaveText(String(known));
  await expect(page.getByText("Chevauche un relevé déjà importé")).toBeVisible();
  await expect(page.getByTestId("bank-check")).toContainText("Solde de clôture rapproché ✓");

  await page.goto("/backoffice/encaissements");
  await expect(page.getByTestId("statement-list").getByRole("listitem")).toHaveCount(2);
  await reviewShot(page, testInfo, "m2-statements");
});

test("collectors do not see bank statements", async ({ page }) => {
  test.setTimeout(90_000);
  await loginAsStaff(page, await createMember(tenant.servicerId, "collector"));
  await page.goto("/backoffice/encaissements");
  await expect(page.getByText("réservés aux administrateurs et aux responsables des opérations")).toBeVisible();
  await expect(page.getByTestId("statement-upload")).toHaveCount(0);
});
