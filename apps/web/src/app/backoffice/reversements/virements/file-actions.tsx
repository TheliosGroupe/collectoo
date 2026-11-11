"use client";

import { useState } from "react";
import { ActionForm } from "@/components/action-form";
import { buttonClass, dangerButtonClass, inputClass } from "@/components/ui";
import { ATTESTATION_LABEL } from "@/lib/remittance/transfers";
import { ConfirmSheet, secondaryClass } from "../../encaissements/a-traiter/queue-actions";
import { cancelFile, generateFile, recordPayeeMismatch } from "./actions";

/**
 * M2c-6a « Virements » sheets (design §17.3; the sheet states every effect before the command, §17.1): generate a
 * file, cancel one (an attestation once downloaded), report a payee name the bank's verification did not match.
 */
export function GenerateFile({
  accountId,
  effects,
  lateCount,
  idempotencyKey,
}: {
  accountId: string;
  effects: string[];
  lateCount: number;
  idempotencyKey: string;
}) {
  return (
    <ConfirmSheet label="Générer le fichier" title="Générer le fichier de virements" buttonClassName={buttonClass} testId="generate-file">
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

export function CancelFile({
  fileId,
  version,
  downloaded,
  idempotencyKey,
}: {
  fileId: string;
  version: number;
  downloaded: boolean;
  idempotencyKey: string;
}) {
  const [attestation, setAttestation] = useState("");
  return (
    <ConfirmSheet
      label={downloaded ? "Annuler (non déposé ou rejeté)" : "Annuler le fichier"}
      title={downloaded ? "Annuler un fichier téléchargé" : "Annuler le fichier"}
      buttonClassName={dangerButtonClass}
      testId="cancel-file"
    >
      {(close) => (
        <>
          <p className="text-sm" data-testid="cancel-file-effect">
            {downloaded
              ? "Le fichier a été téléchargé : il n'est annulé que si la banque n'a rien exécuté. Ses virements reviennent « à mettre dans un fichier » et partiront dans le prochain ; la quote-part du cabinet est recalculée. Refusé si un relevé montre déjà un débit de ce fichier."
              : "Le fichier n'a pas été téléchargé : il est remplacé. Ses virements reviennent « à mettre dans un fichier » ; la quote-part du cabinet est recalculée au prochain fichier."}
          </p>
          <ActionForm onDone={close} action={cancelFile} submitLabel="Annuler le fichier" buttonClassName={dangerButtonClass}>
            <input type="hidden" name="idempotency_key" value={idempotencyKey} />
            <input type="hidden" name="file_id" value={fileId} />
            <input type="hidden" name="expected_version" value={version} />
            {downloaded ? (
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
              </fieldset>
            ) : null}
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

export function PayeeMismatch({ transferId, fileId, idempotencyKey }: { transferId: string; fileId: string; idempotencyKey: string }) {
  return (
    <ConfirmSheet label="Nom non concordant" title="La banque signale un nom de bénéficiaire non concordant" buttonClassName={secondaryClass} testId="payee-mismatch">
      {(close) => (
        <>
          <p className="text-sm">
            La vérification du bénéficiaire de la banque a répondu « nom différent » ou « nom proche » pour ce virement. Le
            compte de reversement du client est bloqué jusqu&apos;à ce qu&apos;une autre personne vérifie le titulaire (ou
            qu&apos;un nouvel IBAN soit confirmé). Si la banque n&apos;a pas exécuté ce virement, annulez le reversement
            avec l&apos;attestation.
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
