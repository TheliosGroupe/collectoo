"use client";

import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { ActionForm } from "@/components/action-form";
import { buttonClass, dangerButtonClass, inlineButtonClass, inputClass } from "@/components/ui";
import { ATTESTATION_LABEL, type Cancellation, evidenceStatus, requestLine } from "@/lib/remittance/transfers";
import { ConfirmSheet, secondaryClass } from "../../encaissements/a-traiter/queue-actions";
import { cancelFile, confirmCancellation, generateFile, recordPayeeMismatch, requestCancellation } from "./actions";

/**
 * M2c-6a « Virements » sheets (design §17.3; the sheet states every effect before the command, §17.1): generate (or
 * regenerate) a file, cancel one not downloaded, ask for — then confirm, another person — the cancellation of a
 * downloaded file or of one of its transfers (review T1), report a payee name the bank's verification did not match;
 * the « Télécharger » link that refreshes the page (review tests-ui#9).
 */
export function GenerateFile({
  accountId,
  effects,
  lateCount,
  idempotencyKey,
  label = "Générer le fichier",
}: {
  accountId: string;
  effects: string[];
  lateCount: number;
  idempotencyKey: string;
  label?: string;
}) {
  return (
    <ConfirmSheet label={label} title="Générer le fichier de virements" buttonClassName={buttonClass} testId="generate-file">
      {(close) => (
        <>
          <ul className="flex list-disc flex-col gap-1 pl-5 text-sm" data-testid="generate-effects">
            {effects.map((e) => (
              <li key={e}>{e}</li>
            ))}
          </ul>
          <ActionForm onDone={close} action={generateFile} submitLabel="Générer" buttonClassName={buttonClass} testId="generate-confirm">
            <input type="hidden" name="idempotency_key" value={idempotencyKey} />
            <input type="hidden" name="bank_account_id" value={accountId} />
            <input type="hidden" name="late_required" value={lateCount > 0 ? "1" : "0"} />
            {lateCount > 0 ? (
              <label className="flex flex-col gap-1 text-sm">
                Motif du retard (enregistré sur le fichier ; payer tard vaut mieux que ne pas payer)
                <textarea name="late_reason" required maxLength={2000} className={inputClass} />
              </label>
            ) : null}
          </ActionForm>
        </>
      )}
    </ConfirmSheet>
  );
}

/**
 * « Régénérer » from a file's own page (review T2): the file was replaced at download (date passed, or a transfer no
 * longer passing the checks); a new one takes what passes today. The late reason is optional: without it, a transfer
 * after its deadline stays out of the file (the sheet says so).
 */
export function RegenerateFile({ accountId, effects, idempotencyKey }: { accountId: string; effects: string[]; idempotencyKey: string }) {
  return (
    <ConfirmSheet label="Régénérer le fichier" title="Régénérer le fichier de virements" buttonClassName={buttonClass} testId="regenerate-file">
      {(close) => (
        <>
          <ul className="flex list-disc flex-col gap-1 pl-5 text-sm" data-testid="regenerate-effects">
            {effects.map((e) => (
              <li key={e}>{e}</li>
            ))}
          </ul>
          <ActionForm onDone={close} action={generateFile} submitLabel="Générer" buttonClassName={buttonClass}>
            <input type="hidden" name="idempotency_key" value={idempotencyKey} />
            <input type="hidden" name="bank_account_id" value={accountId} />
            <input type="hidden" name="late_required" value="0" />
            <label className="flex flex-col gap-1 text-sm">
              Motif du retard, si des virements partent après leur date limite (facultatif)
              <textarea name="late_reason" maxLength={2000} className={inputClass} />
            </label>
          </ActionForm>
        </>
      )}
    </ConfirmSheet>
  );
}

/**
 * « Télécharger » (review tests-ui#9): the route serves the file as an attachment, so the browser stays on the page;
 * the page is refreshed shortly after so the download count, the warning and « Marquer comme transmis » appear. A
 * refusal is a redirect to the file's page, which says what happened.
 */
export function DownloadLink({ href, label, testId, className }: { href: string; label: string; testId: string; className?: string }) {
  const router = useRouter();
  const [clicked, setClicked] = useState(0);
  useEffect(() => {
    if (clicked === 0) return;
    const timers = [1500, 5000].map((ms) => setTimeout(() => router.refresh(), ms));
    return () => timers.forEach(clearTimeout);
  }, [clicked, router]);
  return (
    <a href={href} className={className ?? inlineButtonClass} data-testid={testId} onClick={() => setClicked((n) => n + 1)}>
      {label}
    </a>
  );
}

/** « Annuler le fichier » before download: it is replaced, its transfers wait for the next one. */
export function CancelFile({ fileId, version, idempotencyKey }: { fileId: string; version: number; idempotencyKey: string }) {
  return (
    <ConfirmSheet label="Annuler le fichier" title="Annuler le fichier" buttonClassName={dangerButtonClass} testId="cancel-file">
      {(close) => (
        <>
          <p className="text-sm" data-testid="cancel-file-effect">
            Le fichier n&apos;a pas été téléchargé : il est remplacé. Ses virements reviennent « à mettre dans un fichier » ; la
            quote-part du cabinet est recalculée au prochain fichier.
          </p>
          <ActionForm onDone={close} action={cancelFile} submitLabel="Annuler le fichier" buttonClassName={dangerButtonClass}>
            <input type="hidden" name="idempotency_key" value={idempotencyKey} />
            <input type="hidden" name="file_id" value={fileId} />
            <input type="hidden" name="expected_version" value={version} />
            <label className="flex flex-col gap-1 text-sm">
              Motif (interne)
              <input name="reason" required maxLength={2000} className={inputClass} />
            </label>
          </ActionForm>
        </>
      )}
    </ConfirmSheet>
  );
}

type Target = { kind: "file"; fileId: string; version: number; sent: boolean } | { kind: "transfer"; transferId: string; fileId: string; label: string };

function TargetFields({ target }: { target: Target }) {
  return target.kind === "file" ? (
    <>
      <input type="hidden" name="file_id" value={target.fileId} />
      <input type="hidden" name="expected_version" value={target.version} />
    </>
  ) : (
    <>
      <input type="hidden" name="transfer_id" value={target.transferId} />
      <input type="hidden" name="file_id" value={target.fileId} />
    </>
  );
}

function Evidence({ cancellation, what }: { cancellation: Cancellation; what: "file" | "transfer" }) {
  const e = evidenceStatus(cancellation.evidence, what);
  const tone =
    e.ready === false ? "text-red-800 dark:text-red-200" : e.ready ? "text-emerald-800 dark:text-emerald-200" : "text-zinc-700 dark:text-zinc-300";
  return (
    <p className={`text-sm ${tone}`} data-testid="cancel-evidence">
      {e.text}
    </p>
  );
}

/**
 * The two-step cancellation of a downloaded or sent file, or of one transfer the bank refused in it (review T1): the
 * sheet to ask (with the evidence the statements give, and the attestation for a file), the sheet to confirm someone
 * else's request, or — for the one who asked — that another person must confirm it.
 */
export function TwoStepCancellation({
  target,
  cancellation,
  idempotencyKey,
}: {
  target: Target;
  cancellation: Cancellation;
  idempotencyKey: string;
}) {
  const what = target.kind;
  const request = cancellation.request;
  const blocked = evidenceStatus(cancellation.evidence, what).ready === false;
  const testId = what === "file" ? "file-cancellation" : "transfer-cancellation";
  if (request?.requested_by_me)
    return (
      <div className="flex flex-col gap-1 text-sm" data-testid={testId}>
        <p data-testid="cancel-request">{requestLine(request)}.</p>
        <p className="text-zinc-600 dark:text-zinc-400" data-testid="cancel-wait">
          Une autre personne (administrateur ou responsable des opérations) doit confirmer l&apos;annulation ; rien ne change
          avant.
        </p>
      </div>
    );
  if (request)
    return (
      <div className="flex flex-col gap-2 text-sm" data-testid={testId}>
        <p data-testid="cancel-request">{requestLine(request)}.</p>
        <ConfirmSheet
          label="Confirmer l'annulation"
          title={what === "file" ? "Confirmer l'annulation du fichier" : "Confirmer l'annulation du virement"}
          buttonClassName={dangerButtonClass}
          testId="confirm-cancellation"
        >
          {(close) => (
            <>
              <p className="text-sm" data-testid="cancel-effect">
                {what === "file"
                  ? "Vous confirmez, en seconde personne, que la banque n'a exécuté aucun virement de ce fichier. Ses virements reviennent « à mettre dans un fichier » et partiront dans le prochain (nouveau numéro) ; la quote-part du cabinet est recalculée."
                  : `Vous confirmez, en seconde personne, que la banque n'a pas exécuté ce virement (${target.kind === "transfer" ? target.label : ""}). Il est annulé ; le reste du fichier est inchangé. Le reversement ou le remboursement peut ensuite être annulé.`}
              </p>
              <Evidence cancellation={cancellation} what={what} />
              <ActionForm onDone={close} action={confirmCancellation} submitLabel="Confirmer l'annulation" buttonClassName={dangerButtonClass}>
                <input type="hidden" name="idempotency_key" value={idempotencyKey} />
                <TargetFields target={target} />
              </ActionForm>
            </>
          )}
        </ConfirmSheet>
      </div>
    );
  return (
    <div data-testid={testId}>
      <ConfirmSheet
        label={what === "file" ? "Demander l'annulation (non déposé ou rejeté)" : "Demander l'annulation (refusé par la banque)"}
        title={what === "file" ? "Demander l'annulation d'un fichier téléchargé" : "Demander l'annulation de ce virement"}
        buttonClassName={what === "file" ? dangerButtonClass : secondaryClass}
        testId="request-cancellation"
      >
        {(close) => (
          <RequestForm target={target} cancellation={cancellation} blocked={blocked} idempotencyKey={idempotencyKey} close={close} />
        )}
      </ConfirmSheet>
    </div>
  );
}

function RequestForm({
  target,
  cancellation,
  blocked,
  idempotencyKey,
  close,
}: {
  target: Target;
  cancellation: Cancellation;
  blocked: boolean;
  idempotencyKey: string;
  close: () => void;
}) {
  const [attestation, setAttestation] = useState("");
  const what = target.kind;
  return (
    <>
      <p className="text-sm" data-testid="cancel-effect">
        {what === "file"
          ? "Le fichier a été téléchargé : il n'est annulé que si la banque n'a rien exécuté, relevé à l'appui, et une fois qu'une autre personne a confirmé. Ses virements reviennent alors « à mettre dans un fichier » et partiront dans le prochain. Jusque-là, rien ne change et il reste compté dans le contrôle de trésorerie."
          : "La banque a refusé ce virement seul (par exemple un nom de bénéficiaire non concordant) : il n'est annulé que si le relevé ne montre pas son débit (ou montre son rejet), et une fois qu'une autre personne a confirmé. Le reste du fichier est inchangé."}
      </p>
      <Evidence cancellation={cancellation} what={what} />
      <ActionForm onDone={close} action={requestCancellation} submitLabel="Demander l'annulation" buttonClassName={dangerButtonClass}>
        <input type="hidden" name="idempotency_key" value={idempotencyKey} />
        <TargetFields target={target} />
        {target.kind === "file" ? (
          <fieldset className="flex flex-col gap-2 text-sm">
            <legend className="mb-1">J&apos;atteste que :</legend>
            {Object.entries(ATTESTATION_LABEL).map(([value, label]) => (
              <label key={value} className="flex items-center gap-2">
                <input
                  type="radio"
                  name="attestation"
                  value={value}
                  required
                  checked={attestation === value}
                  onChange={() => setAttestation(value)}
                />
                {label}
              </label>
            ))}
            {target.sent ? (
              <span className="text-xs text-zinc-600 dark:text-zinc-400">
                Le fichier est marqué comme transmis : « non déposé » seulement si ce marquage était une erreur.
              </span>
            ) : null}
          </fieldset>
        ) : null}
        <label className="flex flex-col gap-1 text-sm">
          Motif (interne)
          <input name="reason" required maxLength={2000} className={inputClass} />
        </label>
        {blocked ? (
          <p className="text-xs text-zinc-600 dark:text-zinc-400">La demande sera refusée tant que le relevé ne le permet pas.</p>
        ) : null}
      </ActionForm>
    </>
  );
}

export function PayeeMismatch({ transferId, fileId, idempotencyKey }: { transferId: string; fileId: string; idempotencyKey: string }) {
  return (
    <ConfirmSheet label="Nom non concordant" title="La banque signale un nom de bénéficiaire non concordant" buttonClassName={secondaryClass} testId="payee-mismatch">
      {(close) => (
        <>
          <p className="text-sm">
            La vérification du bénéficiaire de la banque a répondu « nom différent » ou « nom proche » pour ce virement. Le
            compte de reversement du client est bloqué jusqu&apos;à ce qu&apos;une autre personne vérifie le titulaire (ou
            qu&apos;un nouvel IBAN soit confirmé). Si la banque n&apos;a pas exécuté ce virement, demandez son annulation
            (une autre personne la confirme, relevé à l&apos;appui), puis annulez le reversement.
          </p>
          <ActionForm onDone={close} action={recordPayeeMismatch} submitLabel="Enregistrer le signalement" buttonClassName={buttonClass}>
            <input type="hidden" name="idempotency_key" value={idempotencyKey} />
            <input type="hidden" name="transfer_id" value={transferId} />
            <input type="hidden" name="file_id" value={fileId} />
            <label className="flex flex-col gap-1 text-sm">
              Réponse de la banque
              <select name="result" required defaultValue="no_match" className={inputClass}>
                <option value="no_match">Nom différent</option>
                <option value="close_match">Nom proche</option>
              </select>
            </label>
            <label className="flex flex-col gap-1 text-sm">
              Nom proposé par la banque (s&apos;il y en a un)
              <input name="bank_name" maxLength={140} className={inputClass} />
            </label>
            <label className="flex flex-col gap-1 text-sm">
              Précisions (internes)
              <input name="note" required maxLength={2000} className={inputClass} />
            </label>
          </ActionForm>
        </>
      )}
    </ConfirmSheet>
  );
}
