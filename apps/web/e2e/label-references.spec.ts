import { expect, test } from "@playwright/test";
import { randomBytes } from "node:crypto";
import { adminClient, createMember, createTenant, type Tenant } from "./support/admin";
import { ibanFr } from "./support/camt";
import { loginAsStaff } from "./support/session";
import { reviewShot } from "./screenshot";
import { expectOwnImport } from "./support/statements";

/**
 * M2c-7e-2 (plan docs/design/m2c-7-plan.md §7.3, §7.4; ADR-0014 « M2c-7e-2 »): a CSV export of the dedicated account
 * whose credit cites, in its label only, the RMT reference of one of our payouts (a debtor repaying it, the client
 * quoting it, or the payout coming back unflagged — the label cannot say which). The import holds it under its own kind
 * (`label_reference`): no payment, nothing booked; the debit job reviews it; « Débits et retours » « À classer » says
 * what the label cites (« Le libellé cite notre virement RMT… (reversement, X €) : est-ce ce virement qui revient ? »)
 * and that the line waits, and offers no action (7e-3 brings the three exits); the statement's page lists it to
 * classify. A credit citing a look-alike is a payment as before. Screenshot `m2c7-libelle-reference` (mobile + desktop).
 * The switch stays off. Synthetic data.
 */

const n = (text: string) => text.replace(/ | /g, " ");

function parisDay(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Paris" }).format(new Date());
}
function frDay(iso: string): string {
  const [y, m, d] = iso.split("-");
  return `${d}/${m}/${y}`;
}

let tenant: Tenant;
let bankId: string;
const BANK_IBAN = ibanFr(595959);
const DEBTOR_IBAN = ibanFr(77);

test.beforeEach(async () => {
  tenant = await createTenant();
  const admin = adminClient();
  const { data: bank, error } = await admin
    .from("bank_account")
    .insert({
      organization_id: tenant.servicerId,
      iban: BANK_IBAN,
      currency: "EUR",
      label: "Fonds de tiers – Banque L",
      purpose: "client_funds",
      feed: "csv",
      opened_on: "2026-01-01",
    })
    .select("id")
    .single();
  if (error) throw error;
  bankId = bank.id;
});

test("a credit citing our payout in its CSV label waits in « À classer », neither a payment nor a return", async ({
  page,
}, testInfo) => {
  test.setTimeout(180_000);
  // one of our payouts of this account (a transfer of ours: its RMT reference)
  const rmt = `RMT${randomBytes(6).toString("hex").toUpperCase()}`;
  const { error } = await adminClient()
    .from("bank_transfer")
    .insert({
      organization_id: tenant.servicerId,
      client_organization_id: tenant.clientId,
      kind: "payout",
      debtor_bank_account_id: bankId,
      currency: "EUR",
      amount_minor: 125000,
      payee_name: tenant.clientName.slice(0, 70),
      payee_iban: ibanFr(78),
      end_to_end_id: rmt,
      remittance_info: "REVERSEMENT (test)",
      requested_execution_date: parisDay(),
    });
  if (error) throw error;

  await loginAsStaff(page, await createMember(tenant.servicerId, "ops_manager"));
  await page.goto("/backoffice/encaissements");
  const form = page.getByTestId("statement-upload");
  const day = frDay(parisDay());
  const csv =
    "Date;Libellé;Débit;Crédit;IBAN contrepartie\n" +
    `${day};VIR SEPA RECU /DE DUPONT JEAN /MOTIF REMBOURSEMENT ${rmt};;1250,00;${DEBTOR_IBAN}\n` +
    `${day};VIR SEPA RECU /DE DURAND /MOTIF FACTURE RMT0000000047BF;;80,00;${ibanFr(79)}\n`;
  await form.getByLabel("Export CSV de la banque").setInputFiles({
    name: "releve-libelle.csv",
    mimeType: "text/csv",
    buffer: Buffer.from(csv, "utf-8"),
  });
  await form.getByRole("button", { name: "Importer le relevé" }).click();
  const statementId = await expectOwnImport(page);

  // the held line: no payment; the look-alike: a payment, as before
  const admin = adminClient();
  const { data: lines } = await admin
    .from("bank_transaction")
    .select("id, kind, reference_from_label, line_no")
    .eq("statement_id", statementId)
    .order("line_no");
  expect(lines?.map((l) => [l.kind, l.reference_from_label])).toEqual([
    ["label_reference", rmt],
    ["debtor_credit", null],
  ]);
  const held = lines![0].id as string;
  const { data: payments } = await admin.from("payment").select("bank_transaction_id").eq("bank_transaction_id", held);
  expect(payments).toEqual([]);
  // the debit job's review, written by the job itself
  await expect
    .poll(
      async () =>
        (await admin.from("bank_debit_review").select("reason").eq("bank_transaction_id", held).maybeSingle()).data
          ?.reason ?? null,
      { timeout: 60_000 },
    )
    .toBe("label_reference");

  // the statement's page lists it to classify
  await expect(page.getByTestId("statement-status")).toHaveText("Importé");
  await expect(page.getByText("Crédit citant notre référence")).toBeVisible();

  // « Débits et retours », « À classer »: what the label cites, and that the line waits — no action
  await page.goto("/backoffice/encaissements/debits");
  const row = page.getByTestId("debit-row").filter({ hasText: rmt });
  await expect(row).toHaveCount(1, { timeout: 60_000 });
  await expect(row).toContainText("Crédit citant notre référence");
  await expect(row.getByTestId("debit-review")).toContainText(
    n(`Le libellé cite notre virement ${rmt} (reversement, 1 250,00 €) : est-ce ce virement qui revient ?`),
  );
  await expect(row.getByTestId("debit-review")).toContainText(
    "La ligne reste en attente : ni paiement ni retour tant qu'elle n'est pas classée.",
  );
  for (const action of [
    "explain",
    "link-return",
    "link-refund",
    "book-top-up",
    "release-own-credit",
    "book-transfer-line",
    "client-payment-line",
  ])
    await expect(row.getByTestId(action), action).toHaveCount(0);
  await expect(row.getByRole("button")).toHaveCount(0);
  await reviewShot(page, testInfo, "m2c7-libelle-reference");

  // nothing booked, no payment, after the page too
  const { data: bookings } = await admin.from("bank_line_booking").select("kind").eq("bank_transaction_id", held);
  expect(bookings).toEqual([]);
});
