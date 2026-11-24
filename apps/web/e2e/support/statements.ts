import { expect, type Page } from "@playwright/test";
import { adminClient } from "./admin";

/** A statement's own page, as « Importer le relevé » opens it once the import is asked (never « Encaissements »). */
const OWN_PAGE = /\/backoffice\/encaissements\/releves\/([0-9a-f-]{36})$/;

/**
 * M2c-7c-1 (ADR-0014, carried low 2): after « Importer le relevé », THIS statement's own import — its page
 * /backoffice/encaissements/releves/<id> (the form goes there once its file is uploaded and the import asked), its
 * `bank_statement.status` in the database, then « Importé » on that page. The previous statement's « Importé » still
 * shown on « Encaissements » never passes for it: under load (PR #42's E2E) a spec matched it and went on while the
 * browser was still uploading, and its statement was never imported. Returns the statement's id. A duplicate
 * (`?deja=1`) is not an import: the specs that expect one assert it themselves.
 */
export async function expectOwnImport(page: Page, timeout = 60_000): Promise<string> {
  await expect(page).toHaveURL(OWN_PAGE, { timeout });
  const id = OWN_PAGE.exec(new URL(page.url()).pathname)?.[1];
  if (!id) throw new Error(`not a statement's page: ${page.url()}`);
  await expect
    .poll(
      async () => {
        const { data } = await adminClient().from("bank_statement").select("status").eq("id", id).maybeSingle();
        return data?.status ?? null;
      },
      { timeout },
    )
    .toBe("imported");
  await expect(page.getByTestId("statement-status")).toHaveText("Importé", { timeout });
  return id;
}
