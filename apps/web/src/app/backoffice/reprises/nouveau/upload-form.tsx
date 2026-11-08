"use client";

import { useRouter } from "next/navigation";
import { type FormEvent, useRef, useState } from "react";
import { ErrorNote, InfoNote, buttonClass, inputClass } from "@/components/ui";
import { commandErrorCode, errorText, parseEurosToMinor } from "@/lib/boarding/forms";
import { createClient } from "@/lib/supabase/browser";

type Option = { id: string; label: string };

async function sha256Hex(file: File): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", await file.arrayBuffer());
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Creates the batch, registers each file, uploads it to its registered key (the storage policy
 * accepts nothing else), then submits the batch: the worker profiles it and proposes the mapping.
 *
 * Retries are safe: the idempotency key is kept while the inputs stay the same (same batch), a
 * file registered again returns its first registration, and a file already stored is skipped.
 * Changing any input starts a new batch.
 */
export function UploadForm({ portfolios }: { portfolios: Option[] }) {
  const router = useRouter();
  const attempt = useRef<{ signature: string; key: string } | null>(null);
  const [progress, setProgress] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); // keeps the chosen files and values if something fails
    if (progress !== null) return;
    setError(null);
    const formData = new FormData(event.currentTarget);
    const files = formData.getAll("files").filter((f): f is File => f instanceof File && f.size > 0);
    if (files.length === 0) return setError("Choisissez au moins un fichier.");
    if (!formData.get("cut_off_date")) return setError("Indiquez la date d'arrêté du portefeuille.");
    const portfolio = String(formData.get("portfolio") ?? "");
    const cutOff = String(formData.get("cut_off_date") ?? "");
    const totalText = String(formData.get("control_total") ?? "").trim();
    const rowsText = String(formData.get("control_rows") ?? "").trim();
    if (Boolean(totalText) !== Boolean(rowsText))
      return setError("Indiquez l'encours annoncé et le nombre de lignes, ou aucun des deux.");
    const controlTotal = totalText ? parseEurosToMinor(totalText) : null;
    if (totalText && (controlTotal === null || controlTotal < BigInt(0)))
      return setError("Encours annoncé illisible (ex. 12 345,67).");
    if (rowsText && !/^\d{1,9}$/.test(rowsText)) return setError("Nombre de lignes illisible.");

    // Totals are not part of it: set_control_totals overwrites them on the same draft batch.
    const signature = JSON.stringify([portfolio, cutOff, files.map((f) => [f.name, f.size, f.lastModified])]);
    if (attempt.current?.signature !== signature) attempt.current = { signature, key: crypto.randomUUID() };

    const supabase = createClient();
    const fail = (message: string) => {
      console.error("boarding upload failed", message);
      setProgress(null);
      setError(errorText(commandErrorCode(message)));
    };
    setProgress("Création du lot…");
    const { data: batchId, error: e1 } = await supabase.rpc("create_boarding_batch", {
      p_idempotency_key: attempt.current.key,
      p_portfolio_id: portfolio,
      p_cut_off_date: cutOff,
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
      const target = registered as { bucket: string; storage_path: string; uploaded: boolean };
      if (target.uploaded) continue; // stored during an earlier attempt
      const { error: e4 } = await supabase.storage
        .from(target.bucket)
        .upload(target.storage_path, file, { contentType: file.type || "application/octet-stream" });
      if (e4 && !/already exists|duplicate/i.test(e4.message)) return fail(e4.message);
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
    <form onSubmit={onSubmit} className="flex max-w-xl flex-col gap-4">
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
        Date d&apos;arrêté du portefeuille (cut-off du cédant)
        <input type="date" name="cut_off_date" required className={inputClass} />
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
          Totaux annoncés par le cédant, pour le rapprochement (facultatif, les deux ensemble)
        </legend>
        <label className="flex flex-col gap-1 text-sm">
          Encours restant dû à la date d&apos;arrêté (€)
          <input name="control_total" inputMode="decimal" placeholder="12 345,67" className={inputClass} />
        </label>
        <label className="flex flex-col gap-1 text-sm">
          Nombre de lignes du fichier
          <input name="control_rows" inputMode="numeric" placeholder="1200" className={inputClass} />
        </label>
      </fieldset>
      {error ? <ErrorNote>{error}</ErrorNote> : null}
      {progress ? (
        <div role="status" aria-live="polite">
          <InfoNote>{progress}</InfoNote>
        </div>
      ) : null}
      <button type="submit" disabled={progress !== null} className={buttonClass}>
        Déposer et analyser
      </button>
    </form>
  );
}
