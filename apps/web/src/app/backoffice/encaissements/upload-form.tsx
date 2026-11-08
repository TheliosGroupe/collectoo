"use client";

import { useRouter } from "next/navigation";
import { type FormEvent, useRef, useState } from "react";
import { ErrorNote, InfoNote, buttonClass, inputClass } from "@/components/ui";
import { acceptFor, uploadErrorText } from "@/lib/payments/statements";
import { createClient } from "@/lib/supabase/browser";

export type BankAccountOption = { id: string; label: string; feed: string; ibanEnd: string; currency: string };

async function sha256Hex(file: File): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", await file.arrayBuffer());
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Registers the statement, uploads the file to its registered key (the storage policy accepts
 * nothing else), then queues the import: the worker reads, checks and books it. Each step is a
 * quick command (the import itself is a background job).
 *
 * Retries are safe: the idempotency key is kept while the account and the file stay the same, the
 * same file for the same account is one statement (the page then opens it), and a file already
 * stored is not sent again.
 */
export function StatementUploadForm({ accounts }: { accounts: BankAccountOption[] }) {
  const router = useRouter();
  const attempt = useRef<{ signature: string; key: string; submitKey: string } | null>(null);
  const [accountId, setAccountId] = useState(accounts[0]?.id ?? "");
  const [progress, setProgress] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const account = accounts.find((a) => a.id === accountId) ?? accounts[0];

  async function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (progress !== null || !account) return;
    setError(null);
    const formData = new FormData(event.currentTarget);
    const file = formData.get("file");
    if (!(file instanceof File) || file.size === 0) return setError("Choisissez le fichier du relevé.");
    const signature = JSON.stringify([account.id, file.name, file.size, file.lastModified]);
    if (attempt.current?.signature !== signature)
      attempt.current = { signature, key: crypto.randomUUID(), submitKey: crypto.randomUUID() };

    const supabase = createClient();
    const fail = (message: string) => {
      console.error("statement upload failed", message);
      setProgress(null);
      setError(uploadErrorText(message));
    };
    setProgress("Enregistrement du relevé…");
    const { data, error: e1 } = await supabase.rpc("create_statement_upload", {
      p_idempotency_key: attempt.current.key,
      p_bank_account_id: account.id,
      p_file_name: file.name,
      p_sha256: await sha256Hex(file),
      p_size_bytes: file.size,
    });
    if (e1 || !data) return fail(e1?.message ?? "no statement");
    const target = data as { statement_id: string; bucket: string; storage_path: string; duplicate: boolean; uploaded: boolean };
    if (target.duplicate) {
      router.push(`/backoffice/encaissements/releves/${target.statement_id}?deja=1`);
      return;
    }
    if (!target.uploaded) {
      setProgress(`Envoi de ${file.name}…`);
      const { error: e2 } = await supabase.storage
        .from(target.bucket)
        .upload(target.storage_path, file, { contentType: file.type || "application/octet-stream" });
      if (e2 && !/already exists|duplicate/i.test(e2.message)) return fail(e2.message);
    }
    setProgress("Import demandé…");
    const { error: e3 } = await supabase.rpc("submit_statement_import", {
      p_idempotency_key: attempt.current.submitKey,
      p_statement_id: target.statement_id,
    });
    if (e3) return fail(e3.message);
    router.push(`/backoffice/encaissements/releves/${target.statement_id}`);
  }

  if (accounts.length === 0) {
    return (
      <InfoNote>
        Aucun compte de fonds de tiers actif : un administrateur l&apos;enregistre d&apos;abord dans « Comptes bancaires ».
      </InfoNote>
    );
  }

  return (
    <form onSubmit={onSubmit} className="flex max-w-xl flex-col gap-4" data-testid="statement-upload">
      <label className="flex flex-col gap-1 text-sm">
        Compte bancaire
        <select
          name="bank_account"
          value={account?.id}
          onChange={(e) => setAccountId(e.target.value)}
          className={inputClass}
        >
          {accounts.map((a) => (
            <option key={a.id} value={a.id}>
              {a.label} · …{a.ibanEnd}
            </option>
          ))}
        </select>
      </label>
      <label className="flex flex-col gap-1 text-sm">
        {account?.feed === "csv" ? "Export CSV de la banque" : "Relevé CAMT.053 (XML)"}
        <input type="file" name="file" required accept={acceptFor(account?.feed ?? "camt053")} className={inputClass} />
      </label>
      {account?.feed === "csv" ? (
        <p className="text-sm text-zinc-600 dark:text-zinc-400">
          Colonnes attendues : date d&apos;opération, libellé, montant (ou débit et crédit) ; facultatives : date de valeur,
          référence opération, devise. Un export CSV ne prouve pas le solde du compte : préférez le CAMT.053.
        </p>
      ) : null}
      {error ? <ErrorNote>{error}</ErrorNote> : null}
      {progress ? (
        <div role="status" aria-live="polite">
          <InfoNote>{progress}</InfoNote>
        </div>
      ) : null}
      <button type="submit" disabled={progress !== null} className={buttonClass}>
        Importer le relevé
      </button>
    </form>
  );
}
