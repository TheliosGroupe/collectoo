import { expect, test } from "@playwright/test";
import { randomUUID } from "node:crypto";
import path from "node:path";
import { adminClient, createMember, createTenant, type Tenant } from "./support/admin";
import { camt053Lines, ibanFr, type Credit, type Debit } from "./support/camt";
import { loginAsStaff } from "./support/session";

/**
 * M2c-6b-3b part 3 (ADR-0014 « M2c-6b-3b part 3 »; PR #39's known limit): « Contrôles » lists at most 200 results of a
 * check run and says what it leaves out. An ops manager imports a statement of 203 debits each carrying a transfer
 * reference of the form of ours that no transfer of ours has (an RMT id Collectoo never issued: the debit job reviews
 * each « Référence du cabinet inconnue », one result per line), then runs the checks: the page lists 200 results, says
 * above them how many the run holds, and under each check how many of its results are not listed — the run's own count
 * by code (`payment_check_run.summary`) minus the rows shown, never an amount; the rows of a check in one order (the
 * oldest first, then by subject). Screenshots of the top of the list and of its end, mobile and desktop. Synthetic data.
 * Review round 1 (tests-ui-2-unlisted-codes-untested): the statement also holds a credit nobody's file claims, a month
 * old — « Paiements sans dossier depuis 20 jours ou plus », a check whose code sorts after the unknown references': the
 * 200 results read end inside the unknown references, so that check is listed with none of its results, its count
 * said (« 1 résultat de ce contrôle n'est pas affiché. »), and the end-of-list screenshot shows it.
 */
const BANK_IBAN = ibanFr(747474);
const LINES = 203;
/** The statement's day: a month back (the credit's payment ages past « 20 jours », its Paris date). */
const DAY = new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Paris" }).format(new Date(Date.now() - 30 * 86_400_000));

let tenant: Tenant;

test.beforeAll(async () => {
  tenant = await createTenant();
  const { error } = await adminClient().from("bank_account").insert({
    organization_id: tenant.servicerId,
    iban: BANK_IBAN,
    currency: "EUR",
    label: "Fonds de tiers – Banque K",
    feed: "camt053",
    opened_on: "2026-01-01",
  });
  if (error) throw error;
});

/** The run's counts by code, as private.run_payment_checks wrote them when it finished. */
async function summary(): Promise<Record<string, number>> {
  const { data, error } = await adminClient()
    .from("payment_check_run")
    .select("summary, finished_at")
    .eq("organization_id", tenant.servicerId)
    .order("started_at", { ascending: false })
    .limit(1)
    .single();
  if (error) throw error;
  expect(data.finished_at).not.toBeNull();
  return data.summary as Record<string, number>;
}

test("« Contrôles » beyond its 200 results says, per check, how many are not listed", async ({ page }, testInfo) => {
  test.setTimeout(300_000);
  await loginAsStaff(page, await createMember(tenant.servicerId, "ops_manager"));
  const run = randomUUID().replace(/-/g, "").slice(0, 4).toUpperCase();
  const debits: Debit[] = Array.from({ length: LINES }, (_, k) => ({
    ref: `KC-${k}`,
    amountMinor: BigInt(1000 + k),
    kind: "transfer",
    e2e: `RMT${run}${k.toString(16).toUpperCase().padStart(8, "0")}`,
    name: "INCONNU",
  }));
  const total = debits.reduce((s, d) => s + d.amountMinor, BigInt(0));
  // a credit nobody's file claims (no reference): its payment stays « sans dossier »
  const credit: Credit = { ref: "KC-CREDIT", amountMinor: BigInt(12_345), name: "PAYEUR INCONNU", iban: ibanFr(737373) };
  await page.goto("/backoffice/encaissements");
  const form = page.getByTestId("statement-upload");
  await form.getByLabel("Relevé CAMT.053 (XML)").setInputFiles({
    name: "releve-references-inconnues.xml",
    mimeType: "application/xml",
    buffer: Buffer.from(camt053Lines(BANK_IBAN, DAY, [credit], debits, total), "utf-8"),
  });
  await form.getByRole("button", { name: "Importer le relevé" }).click();
  await expect(page.getByTestId("statement-status")).toHaveText("Importé", { timeout: 60_000 });
  // the debit job reviews every line « Référence du cabinet inconnue » (P0), books none
  await expect
    .poll(
      async () => {
        const { count } = await adminClient()
          .from("bank_debit_review")
          .select("bank_transaction_id", { count: "exact", head: true })
          .eq("organization_id", tenant.servicerId)
          .eq("reason", "transfer_unknown");
        return count;
      },
      { timeout: 90_000 },
    )
    .toBe(LINES);

  await page.goto("/backoffice/encaissements/controles");
  await page.getByTestId("run-checks").getByRole("button", { name: "Lancer les contrôles" }).click();
  await expect(async () => {
    await page.reload();
    await expect(page.getByTestId("check-cut")).toBeVisible({ timeout: 2_000 });
  }).toPass({ timeout: 60_000 });

  const counts = await summary();
  expect(counts.transfer_unknown).toBe(LINES);
  const all = Object.values(counts).reduce((s, x) => s + x, 0);
  const fr = (x: number) => new Intl.NumberFormat("fr-FR").format(x);
  await expect(page.getByTestId("check-cut")).toHaveText(
    `Seuls les 200 premiers résultats sont affichés, sur ${fr(all)} : le nombre de résultats non affichés est indiqué pour chaque contrôle.`,
  );
  await expect(page.getByTestId("check-row")).toHaveCount(200);
  // each check: its rows listed, the rest counted under them (or the check alone, none of its results listed)
  for (const [code, n] of Object.entries(counts)) {
    const listed = await page.locator(`[data-testid="check-row"][data-code="${code}"]`).count();
    const hidden = page.locator(`[data-testid="check-hidden"][data-code="${code}"]`);
    const unlisted = page.locator(`[data-testid="check-unlisted"][data-code="${code}"]`);
    if (listed === n) {
      await expect(hidden).toHaveCount(0);
      await expect(unlisted).toHaveCount(0);
    } else if (listed > 0) {
      const rest = n - listed;
      await expect(hidden).toHaveText(
        rest > 1
          ? `${fr(rest)} autres résultats de ce contrôle ne sont pas affichés.`
          : `${fr(rest)} autre résultat de ce contrôle n'est pas affiché.`,
      );
    } else {
      await expect(unlisted).toContainText(
        n > 1 ? `${fr(n)} résultats de ce contrôle ne sont pas affichés.` : `${fr(n)} résultat de ce contrôle n'est pas affiché.`,
      );
    }
  }
  // review round 1 (tests-ui-2): the cut falls before a check that has results — listed with none of them, counted
  expect(counts.unmatched_ageing).toBe(1);
  const late = page.locator('[data-testid="check-unlisted"][data-code="unmatched_ageing"]');
  await expect(late).toContainText("Paiements sans dossier depuis 20 jours ou plus");
  await expect(late).toContainText("1 résultat de ce contrôle n'est pas affiché.");
  await expect(page.locator('[data-testid="check-row"][data-code="unmatched_ageing"]')).toHaveCount(0);
  // the unknown references' rows in one order: one age, then by line (each « Ouvrir » leads to its line)
  const unknown = page.locator('[data-testid="check-row"][data-code="transfer_unknown"]');
  const shown = await unknown.count();
  expect(shown).toBeGreaterThan(0);
  expect(shown).toBeLessThan(LINES);
  const lines = await unknown.getByRole("link", { name: "Ouvrir" }).evaluateAll((links) =>
    links.map((a) => (a.getAttribute("href") ?? "").replace(/^.*#ligne-/, "")),
  );
  expect(lines).toEqual([...lines].sort());
  // the results not listed: no amount is said for them
  await expect(page.locator('[data-testid="check-hidden"], [data-testid="check-unlisted"]').filter({ hasText: "€" })).toHaveCount(0);

  const shot = (name: string) =>
    path.resolve(__dirname, "../../../docs/screenshots", `${name}-${testInfo.project.name}.png`);
  await page.getByTestId("check-cut").scrollIntoViewIfNeeded();
  await page.screenshot({ path: shot("m2c-controles-resultats-non-affiches") });
  await page.locator('[data-testid="check-hidden"], [data-testid="check-unlisted"]').last().scrollIntoViewIfNeeded();
  await page.screenshot({ path: shot("m2c-controles-resultats-non-affiches-fin") });
});
