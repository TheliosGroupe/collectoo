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
 * and that nothing is booked until it is classified; the statement's page lists it to classify. A credit citing a
 * look-alike is a payment as before. Screenshot `m2c7-libelle-reference` (mobile + desktop).
 *
 * M2c-7e-3 (house rule R3; ADR-0014 « M2c-7e-3 »): the line now offers its exits and only them — « Oui, c'est son
 * retour », « Règlement du client », « Paiement d'un débiteur » (no « C'est cet approvisionnement »: it cites a payout),
 * none of the page's other actions (7e-2: no action at all) — and leaves « À classer » by exit (c): « Paiement d'un
 * débiteur » makes it a payment to assign, its payer the account that sent it. A second line, citing our top-up with
 * no sending account, has no return exit; « Règlement du client », the client named by ops (« Client qui rembourse »:
 * the line's IBAN is no client's confirmed payout account), books it (exit (b)). Screenshot
 * `m2c7-libelle-reference-client` (the sheet, mobile + desktop). The switch stays off. Synthetic data.
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

test("a credit citing our payout in its CSV label waits in « À classer » for its exits, then becomes a debtor's payment", async ({
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

  // « Débits et retours », « À classer »: what the label cites, and that the line waits for its exits — (M2c-7e-3, R3)
  // only them
  await page.goto("/backoffice/encaissements/debits");
  const row = page.getByTestId("debit-row").filter({ hasText: rmt });
  await expect(row).toHaveCount(1, { timeout: 60_000 });
  await expect(row).toContainText("Crédit citant notre référence");
  await expect(row.getByTestId("debit-review")).toContainText(
    n(`Le libellé cite notre virement ${rmt} (reversement, 1 250,00 €) : est-ce ce virement qui revient ?`),
  );
  await expect(row.getByTestId("debit-review")).toContainText(
    "Rien n'est comptabilisé tant que la ligne n'est pas classée : choisissez ce qu'elle est.",
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
  const exits = row.getByTestId("label-reference-exits");
  await expect(exits.getByRole("button")).toHaveText([
    "Oui, c'est son retour",
    "Règlement du client",
    "Paiement d'un débiteur",
  ]);
  await expect(row.getByTestId("label-reference-top-up")).toHaveCount(0);
  await expect(row.getByRole("button")).toHaveCount(3);
  await reviewShot(page, testInfo, "m2c7-libelle-reference");

  // nothing booked, no payment, after the page too
  const { data: bookings } = await admin.from("bank_line_booking").select("kind").eq("bank_transaction_id", held);
  expect(bookings).toEqual([]);

  // exit (c): « Paiement d'un débiteur » — a payment to assign, its payer the account that sent it
  await row.getByTestId("label-reference-debtor").getByRole("button", { name: "Paiement d'un débiteur" }).click();
  const sheet = page.getByRole("dialog", { name: "Paiement d'un débiteur" });
  await expect(sheet.getByTestId("sheet-effect")).toContainText(
    n("Le crédit de 1 250,00 € devient un paiement à affecter ; notre référence citée dans le libellé est ignorée."),
  );
  await sheet.getByLabel("Motif (interne)").fill("Le débiteur cite le virement par erreur (E2E)");
  await sheet.getByRole("button", { name: "Créer le paiement" }).click();
  await expect(async () => {
    await page.reload();
    await expect(page.getByTestId("debit-row").filter({ hasText: rmt })).toHaveCount(0, { timeout: 5_000 });
  }).toPass({ timeout: 60_000 });
  const { data: paid } = await admin
    .from("payment")
    .select("status, amount_minor, payer_iban")
    .eq("bank_transaction_id", held);
  expect(paid).toEqual([{ status: "unmatched", amount_minor: 125000, payer_iban: DEBTOR_IBAN }]);
  const { data: after } = await admin.from("bank_line_booking").select("kind").eq("bank_transaction_id", held);
  expect(after).toEqual([]);
  // « Traités »: the payment's note — (review round 1, TUI-1) and never that the line still waits
  await page.goto("/backoffice/encaissements/debits?onglet=traites");
  const done = page.getByTestId("debit-row").filter({ hasText: rmt });
  await expect(done).toContainText("Paiement d'un débiteur citant notre référence (vérifié par l'équipe)");
  await expect(done.getByTestId("debit-review")).toHaveCount(0);
  await expect(done).not.toContainText("Rien n'est comptabilisé");
});

test("a credit citing our top-up without a sending account is the client's payment once ops name the client", async ({
  page,
}, testInfo) => {
  test.setTimeout(180_000);
  const admin = adminClient();
  // the servicer's own account (where its share is swept) and our top-up of the dedicated account from it (TOP)
  const { data: own, error: ownError } = await admin
    .from("bank_account")
    .insert({
      organization_id: tenant.servicerId,
      purpose: "own",
      iban: ibanFr(595960),
      currency: "EUR",
      label: "Compte propre",
      opened_on: "2026-01-01",
    })
    .select("id")
    .single();
  if (ownError) throw ownError;
  const { error: settingsError } = await admin
    .from("servicer_billing_settings")
    .upsert({ organization_id: tenant.servicerId, own_bank_account_id: own.id }, { onConflict: "organization_id" });
  if (settingsError) throw settingsError;
  const top = `TOP${randomBytes(6).toString("hex").toUpperCase()}`;
  const { error } = await admin.from("bank_transfer").insert({
    organization_id: tenant.servicerId,
    kind: "top_up",
    debtor_bank_account_id: own.id,
    creditor_bank_account_id: bankId,
    currency: "EUR",
    amount_minor: 4700,
    payee_name: "Fonds de tiers",
    payee_iban: BANK_IBAN,
    end_to_end_id: top,
    remittance_info: `APPROVISIONNEMENT COMPTE DEDIE ${top}`,
    requested_execution_date: parisDay(),
  });
  if (error) throw error;

  await loginAsStaff(page, await createMember(tenant.servicerId, "ops_manager"));
  await page.goto("/backoffice/encaissements");
  const form = page.getByTestId("statement-upload");
  const csv =
    "Date;Libellé;Débit;Crédit;IBAN contrepartie\n" +
    `${frDay(parisDay())};VIR SEPA RECU /DE BOULANGERIE /MOTIF REGLEMENT ${top};;120,00;\n`;
  await form.getByLabel("Export CSV de la banque").setInputFiles({
    name: "releve-libelle-client.csv",
    mimeType: "text/csv",
    buffer: Buffer.from(csv, "utf-8"),
  });
  await form.getByRole("button", { name: "Importer le relevé" }).click();
  const statementId = await expectOwnImport(page);
  const { data: lines } = await admin
    .from("bank_transaction")
    .select("id, kind, reference_from_label")
    .eq("statement_id", statementId);
  expect(lines?.map((l) => [l.kind, l.reference_from_label])).toEqual([["label_reference", top]]);
  const held = lines![0].id as string;

  await page.goto("/backoffice/encaissements/debits");
  const row = page.getByTestId("debit-row").filter({ hasText: top });
  await expect(async () => {
    await page.reload();
    await expect(row).toHaveCount(1, { timeout: 5_000 });
  }).toPass({ timeout: 60_000 });
  // a top-up has no return; not its amount: not « C'est cet approvisionnement »
  await expect(row.getByTestId("label-reference-exits").getByRole("button")).toHaveText([
    "Règlement du client",
    "Paiement d'un débiteur",
  ]);

  // exit (b): no client's confirmed payout account sent it — ops name the client repaying
  await row.getByTestId("label-reference-client-open").click();
  const sheet = page.getByTestId("client-payment-line-sheet");
  await expect(sheet).toContainText("Notre référence citée dans le libellé est ignorée");
  await expect(sheet).toContainText(
    "Indiquez le client qui rembourse : le compte émetteur n'est pas un compte de reversement confirmé.",
  );
  await sheet.getByTestId("label-reference-client").selectOption({ label: tenant.clientName });
  await expect(sheet).toContainText(`${tenant.clientName} · ${n("120,00 €")} reçus le`);
  await expect(sheet.getByTestId("client-payment-effect")).toBeVisible({ timeout: 30_000 });
  await sheet.getByLabel("Motif").fill("Le client rembourse en citant notre approvisionnement (E2E)");
  await reviewShot(page, testInfo, "m2c7-libelle-reference-client");
  await sheet.getByTestId("client-payment-line-confirm").click();
  await expect(page.getByTestId("client-payment-line-done")).toContainText("Règlement du client enregistré", {
    timeout: 30_000,
  });
  const { data: bookings } = await admin.from("bank_line_booking").select("kind").eq("bank_transaction_id", held);
  expect(bookings).toEqual([{ kind: "client_payment" }]);
  const { data: payments } = await admin.from("payment").select("id").eq("bank_transaction_id", held);
  expect(payments).toEqual([]);

  // (review round 1, TUI-1 to TUI-3) « Traités » names the client's payment, and never says the line still waits nor
  // that it is not the top-up; the statement's page says it is booked
  await page.goto("/backoffice/encaissements/debits?onglet=traites");
  const done = page.getByTestId("debit-row").filter({ hasText: top });
  await expect(done).toContainText("Règlement du client (facture ou avance du cabinet)");
  await expect(done.getByTestId("debit-review")).toHaveCount(0);
  await expect(done).not.toContainText("client_payment");
  await page.goto(`/backoffice/encaissements/releves/${statementId}`);
  const line = page.getByTestId("line-list").getByRole("listitem").filter({ hasText: top });
  await expect(line).toContainText("Crédit citant notre référence");
  await expect(line).toContainText("Comptabilisé · règlement du client");
  await expect(line).not.toContainText("à classer");
});
