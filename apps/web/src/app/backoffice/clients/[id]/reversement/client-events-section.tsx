import { randomUUID } from "node:crypto";
import { ActionForm } from "@/components/action-form";
import { InfoNote, Section, buttonClass, inputClass } from "@/components/ui";
import { frenchDate } from "@/lib/payments/bank-accounts";
import { money } from "@/lib/payments/statements";
import {
  EVENT_HINT,
  EVENT_ROLES,
  REPRESENTATIVE_ROLE,
  type ClientEvents,
  addresseeLines,
  eventLine,
  payeeRule,
  standingSeizures,
} from "@/lib/remittance/client-events";
import { EVENT_KIND } from "@/lib/remittance/terms";
import { qualifyProtectionEvent, recordClientEvent, setClientRepresentative } from "../../actions";

type Doc = { id: string; kind: string; file_name: string | null };
type Declarable = { kind: "invoice" | "advance"; id: string; label: string };

const ROLE_WORD: Readonly<Record<string, string>> = {
  notary: "notaire",
  heirs: "héritiers",
  tutor: "tuteur",
  curator: "curateur",
  liquidator: "liquidateur",
  administrator: "administrateur judiciaire",
};

function RepresentativeFields() {
  return (
    <fieldset className="flex flex-col gap-2 rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
      <legend className="px-1 text-sm font-medium">Personne qui agit pour le client</legend>
      <label className="flex flex-col gap-1 text-sm">
        Rôle
        <select name="rep_role" defaultValue="" className={inputClass}>
          <option value="">—</option>
          {Object.entries(REPRESENTATIVE_ROLE).map(([k, label]) => (
            <option key={k} value={k}>
              {label}
            </option>
          ))}
        </select>
      </label>
      <label className="flex flex-col gap-1 text-sm">
        Nom
        <input name="rep_name" maxLength={140} className={inputClass} />
      </label>
      <label className="flex flex-col gap-1 text-sm">
        Adresse (une ligne par ligne, quatre au plus)
        <textarea name="rep_address" rows={3} className={inputClass} />
      </label>
    </fieldset>
  );
}

/**
 * M2c-7d-1 (plan §6.4): « Événements du client » — each event with who acts for the client, a seizure standing or
 * released, an old « Tutelle ou curatelle » row to qualify; the payee the events require; who receives the letters; and
 * « Enregistrer un événement » with its new fields. Money staff read it (the names and addresses are personal data);
 * admins record.
 */
export function ClientEventsSection({
  clientId,
  view,
  evidence,
  authority,
  courtAccounts,
  declarable,
  isAdmin,
  today,
}: {
  clientId: string;
  view: ClientEvents;
  evidence: Doc[];
  authority: Doc[];
  courtAccounts: { id: string; holder_name: string; iban_masked: string }[];
  declarable: Declarable[];
  isAdmin: boolean;
  today: string;
}) {
  const standing = standingSeizures(view.events);
  const proofs = [...evidence, ...authority];
  return (
    <Section title="Événements du client" testId="client-events" id="evenements">
      {view.events.length === 0 ? (
        <p className="text-sm text-zinc-600 dark:text-zinc-400">Aucun événement enregistré.</p>
      ) : (
        <ul className="mb-3 flex flex-col gap-3 text-sm">
          {view.events.map((e) => (
            <li key={e.id} data-testid="client-event" className="flex flex-col gap-1">
              <span>
                {eventLine(e)} ·{" "}
                <a href={`/backoffice/documents/${e.evidence_document_id}`} className="underline underline-offset-4">
                  justificatif
                </a>
              </span>
              {e.representative ? (
                <span className="text-zinc-700 dark:text-zinc-300" data-testid="client-event-representative">
                  Personne qui agit pour le client : {e.representative.name} (
                  {ROLE_WORD[e.representative.role] ?? e.representative.role}) — {e.representative.address_lines.join(", ")}
                  {e.representatives > 1 ? ` (corrigé, ${e.representatives} enregistrements)` : ""}
                </span>
              ) : null}
              {e.declared.length > 0 ? (
                <span className="text-zinc-700 dark:text-zinc-300">
                  Déclaré :{" "}
                  {e.declared
                    .map((d) => `${d.document_kind === "invoice" ? (d.number ?? "facture") : "avance"} ${money(d.amount_minor, "EUR")}`)
                    .join(", ")}
                </span>
              ) : null}
              {isAdmin && e.effective_kind && EVENT_ROLES[e.effective_kind] ? (
                <details className="rounded-md border border-zinc-200 p-2 dark:border-zinc-800">
                  <summary className="cursor-pointer">
                    {e.representative ? "Corriger qui agit pour le client" : "Indiquer qui agit pour le client"}
                  </summary>
                  <ActionForm
                    action={setClientRepresentative}
                    submitLabel="Enregistrer"
                    pendingLabel="Enregistrement…"
                    buttonClassName={buttonClass}
                    className="mt-2 flex max-w-xl flex-col gap-2"
                    testId="representative-form"
                  >
                    <input type="hidden" name="event_id" value={e.id} readOnly />
                    <input type="hidden" name="client_organization_id" value={clientId} readOnly />
                    <input type="hidden" name="idempotency_key" value={randomUUID()} readOnly />
                    <RepresentativeFields />
                    <label className="flex flex-col gap-1 text-sm">
                      Pièce
                      <select name="evidence_document_id" className={inputClass}>
                        {proofs.map((d) => (
                          <option key={d.id} value={d.id}>
                            {d.file_name ?? "pièce"}
                          </option>
                        ))}
                      </select>
                    </label>
                  </ActionForm>
                </details>
              ) : null}
              {isAdmin && e.to_qualify ? (
                <details className="rounded-md border border-zinc-200 p-2 dark:border-zinc-800" open>
                  <summary className="cursor-pointer">Préciser : tutelle ou curatelle</summary>
                  <ActionForm
                    action={qualifyProtectionEvent}
                    submitLabel="Préciser"
                    pendingLabel="Enregistrement…"
                    buttonClassName={buttonClass}
                    className="mt-2 flex max-w-xl flex-col gap-2"
                    testId="qualify-form"
                  >
                    <input type="hidden" name="event_id" value={e.id} readOnly />
                    <input type="hidden" name="client_organization_id" value={clientId} readOnly />
                    <input type="hidden" name="idempotency_key" value={randomUUID()} readOnly />
                    <p className="text-sm text-zinc-600 dark:text-zinc-400">
                      Enregistré comme « Tutelle ou curatelle » : les reversements restent bloqués jusqu&apos;à ce que
                      vous précisiez. Une tutelle met fin au mandat (art. 2003 C. civ.) ; une curatelle ne le fait pas,
                      les reversements restent bloqués par règle du cabinet.
                    </p>
                    <label className="flex flex-col gap-1 text-sm">
                      Mesure
                      <select name="qualified_kind" className={inputClass}>
                        <option value="guardianship">Tutelle</option>
                        <option value="curatorship">Curatelle</option>
                      </select>
                    </label>
                    <label className="flex flex-col gap-1 text-sm">
                      Jugement
                      <select name="evidence_document_id" className={inputClass}>
                        {evidence.map((d) => (
                          <option key={d.id} value={d.id}>
                            {d.file_name ?? "justificatif"}
                          </option>
                        ))}
                      </select>
                    </label>
                  </ActionForm>
                </details>
              ) : null}
            </li>
          ))}
        </ul>
      )}
      <div className="mb-3 flex flex-col gap-1 text-sm">
        {view.payee || view.seizure_standing ? (
          <p data-testid="client-payee-rule">
            {payeeRule(view.payee)}
            {view.seizure_standing
              ? `${view.payee ? " " : ""}Saisie entre les mains du cabinet en cours : aucun virement de reversement jusqu'à la mainlevée enregistrée (règle du cabinet ; la saisie attribue au créancier saisissant la créance saisie, à concurrence des sommes pour lesquelles elle est pratiquée, art. L211-2 CPCE).`
              : ""}
          </p>
        ) : null}
        <div data-testid="client-addressees">
          <span className="font-medium">Demandes de remboursement d&apos;avance adressées à :</span>
          <ul className="list-disc pl-5">
            {addresseeLines(view.addressees).map((l) => (
              <li key={l}>{l}</li>
            ))}
          </ul>
        </div>
      </div>
      {isAdmin ? (
        <details className="rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
          <summary className="cursor-pointer text-sm font-medium">Enregistrer un événement</summary>
          {evidence.length === 0 ? (
            <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">Joignez d&apos;abord le justificatif (« Documents du client »).</p>
          ) : (
            <ActionForm
              action={recordClientEvent}
              submitLabel="Enregistrer l'événement"
              pendingLabel="Enregistrement…"
              buttonClassName={buttonClass}
              className="mt-3 flex max-w-xl flex-col gap-3"
              resetOnSuccess
              testId="record-event-form"
            >
              <input type="hidden" name="client_organization_id" value={clientId} readOnly />
              <input type="hidden" name="idempotency_key" value={randomUUID()} readOnly />
              <label className="flex flex-col gap-1 text-sm">
                Événement
                <select name="kind" className={inputClass}>
                  {Object.entries(EVENT_KIND).map(([k, label]) => (
                    <option key={k} value={k}>
                      {label}
                    </option>
                  ))}
                </select>
              </label>
              <label className="flex flex-col gap-1 text-sm">
                Date d&apos;effet
                <input type="date" name="effective_date" required max={today} className={inputClass} />
              </label>
              <p className="text-sm text-zinc-600 dark:text-zinc-400">{EVENT_HINT.mandate_ended}</p>
              <label className="flex flex-col gap-1 text-sm">
                Justificatif
                <select name="evidence_document_id" className={inputClass}>
                  {evidence.map((d) => (
                    <option key={d.id} value={d.id}>
                      {d.file_name ?? "justificatif"}
                    </option>
                  ))}
                </select>
              </label>
              <label className="flex flex-col gap-1 text-sm">
                Date de publication au BODACC (procédure collective ou liquidation, facultative)
                <input type="date" name="publication_date" max={today} className={inputClass} />
              </label>
              <RepresentativeFields />
              <label className="flex flex-col gap-1 text-sm">
                Saisie levée (mainlevée seulement)
                <select name="refers_to" defaultValue="" className={inputClass}>
                  <option value="">{standing.length === 0 ? "Aucune saisie en cours n'est enregistrée pour ce client." : "—"}</option>
                  {standing.map((s) => (
                    <option key={s.id} value={s.id}>
                      Saisie du {frenchDate(s.effective_date)}
                    </option>
                  ))}
                </select>
              </label>
              {declarable.length > 0 ? (
                <fieldset className="flex flex-col gap-2 rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
                  <legend className="px-1 text-sm font-medium">Créances déclarées (déclaration de créances seulement)</legend>
                  {declarable.map((d) => (
                    <div key={d.id} className="flex flex-wrap items-center gap-2 text-sm">
                      <label className="flex items-center gap-2">
                        <input type="checkbox" name="declared" value={`${d.kind}:${d.id}`} />
                        {d.label}
                      </label>
                      <label className="flex items-center gap-1">
                        Montant déclaré (€)
                        <input name={`declared_amount_${d.id}`} inputMode="decimal" className={`${inputClass} w-32`} />
                      </label>
                    </div>
                  ))}
                </fieldset>
              ) : null}
              {courtAccounts.length > 0 ? (
                <label className="flex flex-col gap-1 text-sm">
                  Compte du mandataire de justice (facultatif)
                  <select name="payout_account_id" defaultValue="" className={inputClass}>
                    <option value="">—</option>
                    {courtAccounts.map((p) => (
                      <option key={p.id} value={p.id}>
                        {p.holder_name} · {p.iban_masked}
                      </option>
                    ))}
                  </select>
                </label>
              ) : null}
              <label className="flex flex-col gap-1 text-sm">
                Note (facultative)
                <input name="note" maxLength={2000} className={inputClass} />
              </label>
              <InfoNote>
                Ce que font les événements, aujourd&apos;hui : un décès, une tutelle, une curatelle, une fin de mandat ou une
                liquidation bloquent les reversements jusqu&apos;à ce qu&apos;un second administrateur du cabinet confirme,
                après l&apos;événement, le compte qu&apos;ils exigent (succession : compte du notaire ou désigné par tous les
                héritiers ; tutelle ou curatelle : compte ouvert au nom du client, art. 427 C. civ. ; liquidation : compte
                du liquidateur ; fin de mandat : compte du client confirmé à nouveau), avec, sauf après une fin de mandat,
                la pièce qui désigne qui peut recevoir ; une « Tutelle ou curatelle » enregistrée avant leur distinction
                les bloque jusqu&apos;à ce qu&apos;elle soit précisée ; une saisie bloque les virements de reversement
                jusqu&apos;à sa mainlevée (les compensations ne sont pas encore bloquées : ne validez pas de reversement
                sans virement tant qu&apos;elle court). Après un décès, une
                tutelle ou une fin de mandat (art. 2003 C. civ.), les paiements reçus sont mis de côté : à reverser au client
                (ou à son bénéficiaire) sans commission, ou à restituer au payeur. Les demandes de remboursement
                d&apos;avance sont adressées à la personne qui agit pour le client, et l&apos;espace du client ne montre pas
                ces lettres (après une curatelle : au client, copie au curateur). Ces règles sont celles du cabinet, sauf ce que citent les articles : questions ouvertes OQ-41,
                OQ-93, OQ-94.
              </InfoNote>
            </ActionForm>
          )}
        </details>
      ) : null}
    </Section>
  );
}
