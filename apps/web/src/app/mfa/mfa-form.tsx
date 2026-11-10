"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { ErrorNote, buttonClass, inputClass } from "@/components/ui";
import { createClient } from "@/lib/supabase/browser";

type Step =
  | { kind: "loading" }
  | { kind: "enroll"; factorId: string; qrCode: string; secret: string }
  | { kind: "verify"; factorId: string };

/** TOTP enrolment (first time) or verification (next logins). Staff need aal2 (GDPR art. 32); a client user steps up
 * to aal2 to confirm a payout IBAN (M2c-2, founder #10). Then back to `target` (a page of the user's own space). */
export function MfaForm({ target }: { target: string }) {
  const router = useRouter();
  const [step, setStep] = useState<Step>({ kind: "loading" });
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    const supabase = createClient();
    (async () => {
      const { data, error: listError } = await supabase.auth.mfa.listFactors();
      if (listError) return setError("Impossible de charger vos facteurs d'authentification.");
      const verified = data.totp.find((f) => f.status === "verified");
      if (verified) return setStep({ kind: "verify", factorId: verified.id });
      // Remove abandoned enrolments before starting a new one.
      for (const f of data.all.filter((f) => f.factor_type === "totp" && f.status !== "verified")) {
        await supabase.auth.mfa.unenroll({ factorId: f.id });
      }
      const { data: enrolled, error: enrollError } = await supabase.auth.mfa.enroll({
        factorType: "totp",
        friendlyName: "Collectoo",
      });
      if (enrollError) return setError("L'enrôlement a échoué. Réessayez.");
      setStep({
        kind: "enroll",
        factorId: enrolled.id,
        qrCode: enrolled.totp.qr_code,
        secret: enrolled.totp.secret,
      });
    })();
  }, []);

  async function onSubmit(formData: FormData) {
    if (step.kind === "loading") return;
    setBusy(true);
    setError(null);
    const code = String(formData.get("code") ?? "").replace(/\s/g, "");
    const supabase = createClient();
    const { error: verifyError } = await supabase.auth.mfa.challengeAndVerify({
      factorId: step.factorId,
      code,
    });
    setBusy(false);
    if (verifyError) return setError("Code incorrect. Vérifiez l'heure de votre téléphone.");
    router.replace(target);
    router.refresh();
  }

  if (step.kind === "loading") {
    return error ? <ErrorNote>{error}</ErrorNote> : <p>Chargement…</p>;
  }
  return (
    <div className="flex flex-col gap-4">
      {step.kind === "enroll" ? (
        <>
          <p className="text-zinc-600 dark:text-zinc-400">
            Scannez ce QR code avec votre application d&apos;authentification, puis saisissez le
            code à 6 chiffres.
          </p>
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={step.qrCode} alt="QR code d'enrôlement" className="h-48 w-48 self-center bg-white p-2" />
          <p className="break-all text-center font-mono text-xs" data-testid="totp-secret">
            {step.secret}
          </p>
        </>
      ) : (
        <p className="text-zinc-600 dark:text-zinc-400">
          Saisissez le code affiché par votre application d&apos;authentification.
        </p>
      )}
      {error ? <ErrorNote>{error}</ErrorNote> : null}
      <form action={onSubmit} className="flex flex-col gap-4">
        <label className="flex flex-col gap-1 text-sm font-medium">
          Code à 6 chiffres
          <input name="code" inputMode="numeric" autoComplete="one-time-code" required className={inputClass} />
        </label>
        <button type="submit" disabled={busy} className={buttonClass}>
          Valider
        </button>
      </form>
    </div>
  );
}
