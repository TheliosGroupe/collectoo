import { expect, test, type Page } from "@playwright/test";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";
import { adminClient, createMandate, createMember, createTenant, type Tenant } from "./support/admin";
import { camt053, ibanFr, type Credit } from "./support/camt";
import { loginAsStaff } from "./support/session";
import { reviewShot } from "./screenshot";

/**
 * M2b-3 (M2-08): an ops manager boards a client file (40 synthetic invoices, the boarding E2E's fixture),
 * then imports the client-funds statement where debtors paid. The rules match what they are sure of (an RF
 * reference; an invoice number backed by the payer's name); the rest waits in « Paiements à traiter »:
 * a name and an amount (a suggestion, accepted in one tap), no information (ops search the file), two files
 * named (ops choose). A wrong file is then undone from « Rapprochés ». Synthetic names and IBANs.
 * Review fixes: a one-tap accept assigns only the file the sheet named (a rematch in between makes it skip,
 * and ops are told); the sheet words what the gating will do; a page past the last one leads back; the
 * phone sheet never runs off the screen.
 */
const BANK_IBAN = "FR7630004000031234567890143"; // synthetic
const DAY = "2026-11-02";
const FIXTURE = {
  name: "Créances novembre 2026.csv",
  mimeType: "text/csv",
  buffer: readFileSync(path.resolve(__dirname, "fixtures/factures-b2b.csv")),
};

type File = { id: string; ref: string; rf: string; debtor: string; items: { ref: string; due: bigint }[]; due: bigint };

let tenant: Tenant;

test.beforeAll(async () => {
  tenant = await createTenant();
  await createMandate(tenant);
  const { error } = await adminClient().from("bank_account").insert({
    organization_id: tenant.servicerId,
    iban: BANK_IBAN,
    currency: "EUR",
    label: "Fonds de tiers – Banque A",
    feed: "camt053",
    opened_on: "2026-01-01",
  });
  if (error) throw error;
});

async function boardAndConfirm(page: Page) {
  await page.goto("/backoffice/reprises/nouveau");
  await page.getByLabel("Date d'arrêté du portefeuille").fill("2026-09-30");
  await page.getByLabel("Fichiers").setInputFiles(FIXTURE);
  await page.getByLabel("Encours restant dû à la date d'arrêté (€)").fill("212 186,29");
  await page.getByLabel("Nombre de lignes du fichier").fill("40");
  await page.getByRole("button", { name: "Déposer et analyser" }).click();
  const status = page.getByTestId("batch-status");
  await expect(status).toHaveText("Mapping à valider", { timeout: 60_000 });
  await page.getByRole("button", { name: "Valider le mapping" }).click();
  await expect(status).toHaveText("Prêt à intégrer", { timeout: 60_000 });
  await page.getByRole("button", { name: "Intégrer le lot" }).click();
  await expect(status).toHaveText("Intégré, à confirmer", { timeout: 60_000 });
  await page.getByRole("button", { name: "Confirmer le lot" }).click();
  await expect(status).toHaveText("Confirmé", { timeout: 60_000 });
}

/** An embedded party: one object (PostgREST) or, as the untyped client sees it, a list. */
function partyName(party: { display_name: string } | { display_name: string }[] | null | undefined): string {
  const one = Array.isArray(party) ? party[0] : party;
  return one?.display_name ?? "";
}

/** The confirmed files as the bank's payers know them: reference, RF, debtor, what is still due. */
async function confirmedFiles(): Promise<File[]> {
  const admin = adminClient();
  const { data: accounts, error } = await admin
    .from("account")
    .select("id, external_ref")
    .eq("portfolio_id", tenant.portfolioId)
    .eq("status", "awaiting_first_letter")
    .order("external_ref");
  if (error) throw error;
  const ids = accounts.map((a) => a.id);
  const [{ data: refs }, { data: items }, { data: parties }] = await Promise.all([
    admin.from("payment_reference").select("account_id, rf").in("account_id", ids).eq("status", "active"),
    admin.from("claim_item").select("account_id, ref, original_minor, seller_paid_minor").in("account_id", ids),
    admin.from("account_party").select("account_id, party:party_id(display_name)").in("account_id", ids),
  ]);
  return accounts.map((a) => {
    const its = (items ?? [])
      .filter((i) => i.account_id === a.id)
      .map((i) => ({ ref: i.ref, due: BigInt(i.original_minor) - BigInt(i.seller_paid_minor ?? 0) }));
    return {
      id: a.id,
      ref: a.external_ref,
      rf: refs?.find((r) => r.account_id === a.id)?.rf ?? "",
      debtor: partyName((parties ?? []).find((p) => p.account_id === a.id)?.party),
      items: its,
      due: its.reduce((s, i) => s + i.due, BigInt(0)),
    };
  });
}

function credits(files: File[]): { credits: Credit[]; a: File; b: File; c: File; d: File } {
  const open = files.filter((f) => f.due > BigInt(0) && f.items.every((i) => i.due > BigInt(0)));
  const unique = open.filter((f) => open.filter((g) => g.due === f.due).length === 1);
  const [a, b, c, d] = [unique[0], unique[1], unique[2], unique[3]];
  return {
    a,
    b,
    c,
    d,
    credits: [
      // R1: the RF reference in the structured field
      { ref: "E2E-1", amountMinor: BigInt(10000), name: a.debtor.toUpperCase(), iban: ibanFr(1), rf: a.rf },
      // R3: an invoice number backed by the payer's name
      { ref: "E2E-2", amountMinor: BigInt(5000), name: b.debtor, iban: ibanFr(2), ustrd: [`REGLT FACT ${b.items[0].ref}`] },
      // R5: the exact balance and the debtor's name: only a suggestion
      { ref: "E2E-3", amountMinor: c.due, name: c.debtor, iban: ibanFr(3), ustrd: ["SOLDE"] },
      // R6: nothing to go on
      { ref: "E2E-4", amountMinor: BigInt(3700), name: "Inconnu Payeur", iban: ibanFr(4), ustrd: ["CADEAU"] },
      // two RF references: ops choose
      { ref: "E2E-5", amountMinor: BigInt(2500), name: "Parent Payeur", iban: ibanFr(5), ustrd: [`${a.rf} et ${b.rf}`] },
    ],
  };
}

test("ops resolve the payments the rules leave to them", async ({ page }, testInfo) => {
  test.setTimeout(300_000);
  await loginAsStaff(page, await createMember(tenant.servicerId, "ops_manager"));
  await boardAndConfirm(page);
  const { credits: paid, a, b, d } = credits(await confirmedFiles());

  // The statement: the import books the money, then the match job runs.
  await page.goto("/backoffice/encaissements");
  const form = page.getByTestId("statement-upload");
  await form.getByLabel("Relevé CAMT.053 (XML)").setInputFiles({
    name: "releve-novembre.xml",
    mimeType: "application/xml",
    buffer: Buffer.from(camt053(BANK_IBAN, DAY, paid), "utf-8"),
  });
  await form.getByRole("button", { name: "Importer le relevé" }).click();
  await expect(page.getByTestId("statement-status")).toHaveText("Importé", { timeout: 60_000 });
  const counts = page.getByTestId("match-counts");
  await expect(counts).toContainText("Rapprochés automatiquement 40 %", { timeout: 60_000 });
  await expect(counts).toContainText("2 sur 5 paiements");
  await counts.getByRole("link", { name: "· à traiter : 3" }).click();

  // The queue: oldest first, one card per payment, the reason and what to do.
  await expect(page).toHaveURL(/\/backoffice\/encaissements\/a-traiter$/);
  const cards = page.getByTestId("queue-card");
  await expect(cards).toHaveCount(3);
  // the remittance text itself ("solde" is also in every file label)
  const soldeText = page.getByTestId("queue-text").filter({ hasText: /^SOLDE$/ });
  const suggestion = cards.filter({ has: soldeText });
  const unknown = cards.filter({ hasText: "Inconnu Payeur" });
  const two = cards.filter({ hasText: "Parent Payeur" });
  await expect(suggestion.getByTestId("queue-reason")).toHaveText("Aucun dossier désigné");
  await expect(two.getByTestId("queue-reason")).toHaveText("Plusieurs dossiers possibles");
  await expect(two.getByTestId("queue-text").locator("mark")).toHaveCount(2); // both references read
  await expect(unknown.getByTestId("accept-suggestion")).toHaveCount(0);
  await reviewShot(page, testInfo, "m2-payments-queue");

  // A rematch proposes another file after the page was drawn (played here on the candidate row): the
  // sheet still names the file ops saw, so nothing is assigned, and the page says why.
  const admin = adminClient();
  const { data: line, error: lineError } = await admin
    .from("bank_transaction")
    .select("id")
    .eq("organization_id", tenant.servicerId)
    .eq("acct_svcr_ref", "E2E-3")
    .single();
  if (lineError) throw lineError;
  const { data: solde } = await admin.from("payment").select("id").eq("bank_transaction_id", line.id).single();
  const { data: shown } = await admin
    .from("payment_match_candidate")
    .select("account_id")
    .eq("payment_id", solde!.id)
    .eq("rank", 1)
    .single();
  const setRank1 = async (account: string) => {
    const { error } = await admin
      .from("payment_match_candidate")
      .update({ account_id: account })
      .eq("payment_id", solde!.id)
      .eq("rank", 1);
    if (error) throw error;
  };

  // A name and an amount: one tap, a sheet that says what will happen, then confirm.
  await suggestion.getByTestId("accept-suggestion").getByRole("button").first().click();
  const sheet = page.getByRole("dialog", { name: "Accepter la suggestion" });
  await expect(sheet).toContainText("sera rattaché au dossier");
  await expect(sheet.getByTestId("sheet-effect")).toContainText("Il sera imputé sur ses factures");
  await reviewShot(page, testInfo, "m2-payment-accept");
  await setRank1(a.id);
  await sheet.getByRole("button", { name: "Confirmer l'affectation" }).click();
  await expect(page.getByTestId("queue-notice")).toContainText(
    "Aucune suggestion acceptée ; 1 paiement ignoré : suggestion modifiée entre-temps (1)",
  );
  await expect(cards).toHaveCount(3);
  await expect(suggestion.getByTestId("accept-suggestion")).toContainText(`Affecter à ${a.ref}`); // what is proposed now
  await reviewShot(page, testInfo, "m2-payments-accept-skipped");
  // the next rematch proposes the first file again: accepted this time
  await setRank1(shown!.account_id);
  await page.reload();
  await suggestion.getByTestId("accept-suggestion").getByRole("button").first().click();
  await page.getByRole("dialog", { name: "Accepter la suggestion" }).getByRole("button", { name: "Confirmer l'affectation" }).click();
  await expect(page.getByTestId("queue-notice")).toContainText("1 suggestion acceptée.");
  await expect(cards).toHaveCount(2);

  // Two files named: ops choose the second.
  await two.getByTestId("queue-candidates").getByRole("listitem").filter({ hasText: b.ref }).getByRole("button", { name: "Choisir ce dossier" }).click();
  const choose = page.getByRole("dialog", { name: `Affecter à ${b.ref}` });
  await choose.getByRole("button", { name: "Confirmer l'affectation" }).click();
  await expect(cards).toHaveCount(1);

  // Nothing to go on: ops search the file by its reference, give a reason, confirm.
  await unknown.getByTestId("search-file").getByRole("button", { name: "Chercher un dossier" }).click();
  const search = page.getByRole("dialog", { name: "Affecter à un dossier" });
  await search.getByLabel("Dossier, facture, référence RF ou nom du débiteur").fill(d.ref);
  await search.getByRole("button", { name: "Chercher" }).click();
  await search.getByTestId("search-results").getByRole("radio").first().check();
  if (testInfo.project.name === "mobile") {
    // the sheet is never taller than the screen: it scrolls inside, the search box stays reachable
    const style = await search.evaluate((el) => {
      const css = getComputedStyle(el);
      return { overflowY: css.overflowY, maxHeight: css.maxHeight };
    });
    expect(style.overflowY).toBe("auto");
    expect(style.maxHeight).not.toBe("none");
    const box = await search.boundingBox();
    expect(box!.y).toBeGreaterThanOrEqual(0);
    expect(box!.y + box!.height).toBeLessThanOrEqual(page.viewportSize()!.height + 1);
  }
  await search.getByLabel("Motif (gardé dans l'historique)").fill("Courriel du débiteur du 02/11");
  await search.getByRole("button", { name: "Confirmer l'affectation" }).click();
  await expect(page.getByText("Aucun paiement à traiter")).toBeVisible();

  // « Rapprochés »: every payment has its file (and is allocated by the worker, M2b-4); a wrong one is taken
  // off from its page: the allocation reversed first, then the payment unassigned, with a reason.
  await page.getByTestId("queue-tabs").getByRole("link", { name: "Rapprochés" }).click();
  await expect(cards).toHaveCount(5);
  await reviewShot(page, testInfo, "m2-payments-matched");
  const accepted = cards.filter({ has: soldeText });
  await accepted.getByTestId("queue-payment-link").click();
  await expect(page.getByTestId("payment-status")).toHaveText("Imputé", { timeout: 60_000 });
  await page.getByTestId("reverse-allocation").getByRole("button").first().click();
  const reverse = page.getByRole("dialog", { name: "Annuler cette imputation" });
  await reverse.getByLabel("Motif interne (non transmis au client)").fill("Homonyme : autre débiteur");
  await reverse.getByRole("button", { name: "Confirmer l'annulation" }).click();
  await expect(page.getByTestId("payment-reason")).toHaveText("Imputation annulée");
  await page.getByTestId("unassign").getByRole("button", { name: "Désaffecter" }).click();
  const undo = page.getByRole("dialog", { name: "Désaffecter ce paiement" });
  await undo.getByLabel("Motif interne (non transmis au client)").fill("Homonyme : autre débiteur");
  await undo.getByRole("button", { name: "Confirmer" }).click();
  await expect(page.getByTestId("payment-status")).toHaveText("Sans dossier");
  await page.goto("/backoffice/encaissements/a-traiter?onglet=rapproches");
  await expect(cards).toHaveCount(4);
  await page.getByTestId("queue-tabs").getByRole("link", { name: "À traiter" }).click();
  await expect(cards).toHaveCount(1, { timeout: 30_000 });
  await expect(cards.first().getByTestId("queue-text")).toHaveText("SOLDE");

  // A file held for a collective proceeding: the sheet says the payment will be held, not allocated.
  // The payment searched onto d is allocated first: a hold placed before the worker allocates it holds it too
  // (rightly), and it would come back here to decide (the receipts jobs share the queue and can delay it).
  const { data: dLine, error: dLineError } = await admin
    .from("bank_transaction")
    .select("id")
    .eq("organization_id", tenant.servicerId)
    .eq("acct_svcr_ref", "E2E-4")
    .single();
  if (dLineError) throw dLineError;
  await expect
    .poll(
      async () => {
        const { data } = await admin.from("payment").select("status").eq("bank_transaction_id", dLine.id).single();
        return data?.status;
      },
      { timeout: 60_000 },
    )
    .toBe("allocated");
  const { data: proof, error: proofError } = await admin
    .from("document")
    .insert({
      organization_id: tenant.servicerId,
      client_organization_id: tenant.clientId,
      account_id: d.id,
      kind: "evidence",
      storage_path: `e2e/${randomUUID()}.pdf`,
      sha256: "a".repeat(64),
      mime_type: "application/pdf",
    })
    .select("id")
    .single();
  if (proofError) throw proofError;
  const { error: holdError } = await admin.from("account_hold").insert({
    organization_id: tenant.servicerId,
    client_organization_id: tenant.clientId,
    portfolio_id: tenant.portfolioId,
    account_id: d.id,
    kind: "collective_proceeding",
    scope: ["outbound", "payment_requests", "accruals"],
    evidence_document_id: proof.id,
    reason: "Jugement d'ouverture (E2E)",
  });
  if (holdError) throw holdError;
  await cards.first().getByTestId("search-file").getByRole("button", { name: "Chercher un dossier" }).click();
  const held = page.getByRole("dialog", { name: "Affecter à un dossier" });
  await held.getByLabel("Dossier, facture, référence RF ou nom du débiteur").fill(d.ref);
  await held.getByRole("button", { name: "Chercher" }).click();
  await held.getByTestId("search-results").getByRole("radio").first().check();
  await expect(held.getByTestId("sheet-effect")).toContainText(
    "Le dossier est bloqué (surendettement ou procédure collective) : le paiement sera mis en attente",
  );
  await expect(held.getByTestId("sheet-effect")).not.toContainText("imputé sur ses factures");
  await reviewShot(page, testInfo, "m2-payment-assign-held");
  await held.getByRole("button", { name: "Annuler" }).click();

  // A page past the last one (its payments were just resolved) says how many are left and leads back.
  // The count depends on the payments queue (matching, allocation and receipts jobs run in turn):
  // reload until the background jobs have settled rather than read a page rendered mid-way.
  // (A count of 2 means the hold reached d's payment before its allocation: see the wait above.)
  const pastEnd = page.getByTestId("queue-past-end");
  await expect(async () => {
    await page.goto("/backoffice/encaissements/a-traiter?page=2");
    await expect(pastEnd).toContainText("Plus rien sur cette page : 1 paiement à traiter au total.", { timeout: 2_000 });
    await expect(page.getByTestId("queue-tabs")).toContainText("À traiter (1)", { timeout: 2_000 });
  }).toPass({ timeout: 30_000 });
  await reviewShot(page, testInfo, "m2-payments-past-end");
  await pastEnd.getByRole("link", { name: "Revenir à la dernière page" }).click();
  await expect(page).toHaveURL(/\/backoffice\/encaissements\/a-traiter$/);
  await expect(cards).toHaveCount(1);
});

test("collectors do not see the payments to process", async ({ page }) => {
  test.setTimeout(90_000);
  await loginAsStaff(page, await createMember(tenant.servicerId, "collector"));
  await page.goto("/backoffice/encaissements/a-traiter");
  await expect(page.getByText("réservés aux administrateurs et aux responsables des opérations")).toBeVisible();
  await expect(page.getByTestId("queue-list")).toHaveCount(0);
});
