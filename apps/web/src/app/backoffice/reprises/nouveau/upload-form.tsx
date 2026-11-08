"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";
import { ErrorNote, InfoNote, buttonClass, inputClass } from "@/components/ui";
import { commandError, parseEurosToMinor } from "@/lib/boarding/forms";
import { createClient } from "@/lib/supabase/browser";

type Option = { id: string; label: string };

async function sha256Hex(file: File): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", await file.arrayBuffer());
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Creates the batch, registers each file, uploads it to its registered path (the storage policy
 * accepts nothing else), then submits the batch: the worker profiles it and proposes the mapping.
 */
export function UploadForm({ portfolios }: { portfolios: Option[] }) {
  const router = useRouter();
  // One key per form: a retry after a network error reuses the same batch.
  const [idempotencyKey] = useState(() => crypto.randomUUID());
  const [progress, setProgress] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function onSubmit(formData: FormData) {
    setError(null);
    const files = formData.getAll("files").filter((f): f is File => f instanceof File && f.size > 0);
    if (files.length === 0) return setError("Choisissez au moins un fichier.");
    const totalText = String(formData.get("control_total") ?? "").trim();
    const rowsText = String(formData.get("control_rows") ?? "").trim();
    const controlTotal = totalText ? parseEurosToMinor(totalText) : null;
    if (totalText && controlTotal === null) return setError("Montant total du cédant illisible (ex. 12 345,67).");
    if (totalText && !/^\d+$/.test(rowsText)) return setError("Indiquez aussi le nombre de lignes annoncé.");

    const supabase = createClient();
    const fail = (message: string) => {
      setProgress(null);
      setError(commandError(message));
    };
    setProgress("Création du lot…");
    const { data: batchId, error: e1 } = await supabase.rpc("create_boarding_batch", {
      p_idempotency_key: idempotencyKey,
      p_portfolio_id: String(formData.get("portfolio")),
      p_cut_off_date: String(formData.get("cut_off_date") ?? "") || undefined,
    });
    if (e1 || !batchId) return fail(e1?.message ?? "no batch");
    if (controlTotal !== null) {
      const { error: e2 } = await supabase.rpc("set_control_totals", {
        p_batch_id: batchId,
        // bigint travels as a decimal string: no float on the way.
        p_total_minor: controlTotal.toString() as unknown as number,
        p_rows: Number(rowsText),
      });
      if (e2) return fail(e2.message);
    }
    for (const [i, file] of files.entries()) {
      setProgress(`Envoi de ${file.name} (${i + 1}/${files.length})…`);
      const { data: registered, error: e3 } = await supabase.rpc("add_boarding_file", {
        p_batch_id: batchId,
        p_file_name: file.name,
        p_sha256: await sha256Hex(file),
        p_size_bytes: file.size,
      });
      if (e3 || !registered) return fail(e3?.message ?? "file not registered");
      const target = registered as { bucket: string; storage_path: string };
      const { error: e4 } = await supabase.storage
        .from(target.bucket)
        .upload(target.storage_path, file, { contentType: file.type || "application/octet-stream" });
      if (e4 && !e4.message.includes("exists")) return fail(e4.message);
    }
    setProgress("Analyse demandée…");
    const { error: e5 } = await supabase.rpc("submit_boarding_batch", { p_batch_id: batchId });
    if (e5) return fail(e5.message);
    router.push(`/backoffice/reprises/${batchId}`);
  }

  if (portfolios.length === 0) {
    return <InfoNote>Aucun portefeuille : créez d&apos;abord le portefeuille du client.</InfoNote>;
  }

  return (
    <form action={onSubmit} className="flex max-w-xl flex-col gap-4">
      <label className="flex flex-col gap-1 text-sm">
        Portefeuille
        <select name="portfolio" required className={inputClass}>
          {portfolios.map((p) => (
            <option key={p.id} value={p.id}>
              {p.label}
            </option>
          ))}
        </select>
      </label>
      <label className="flex flex-col gap-1 text-sm">
        Date d&apos;arrêté des données (facultatif)
        <input type="date" name="cut_off_date" className={inputClass} />
      </label>
      <label className="flex flex-col gap-1 text-sm">
        Fichiers (CSV, Excel, largeur fixe, zip de pièces)
        <input
          type="file"
          name="files"
          multiple
          required
          accept=".csv,.txt,.tsv,.xlsx,.dat,.prn,.zip"
          className={inputClass}
        />
      </label>
      <fieldset className="grid gap-3 sm:grid-cols-2">
        <legend className="mb-1 text-sm text-zinc-600 dark:text-zinc-400">
          Totaux annoncés par le cédant, pour le rapprochement (facultatif)
        </legend>
        <label className="flex flex-col gap-1 text-sm">
          Montant total (€)
          <input name="control_total" inputMode="decimal" placeholder="12 345,67" className={inputClass} />
        </label>
        <label className="flex flex-col gap-1 text-sm">
          Nombre de lignes
          <input name="control_rows" inputMode="numeric" placeholder="1200" className={inputClass} />
        </label>
      </fieldset>
      {error ? <ErrorNote>{error}</ErrorNote> : null}
      {progress ? <InfoNote>{progress}</InfoNote> : null}
      <button type="submit" disabled={progress !== null} className={buttonClass}>
        Déposer et analyser
      </button>
    </form>
  );
}
