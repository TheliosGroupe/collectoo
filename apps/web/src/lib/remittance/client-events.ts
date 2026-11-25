import { parseEurosToMinor } from "@/lib/boarding/forms";
import { frenchDate } from "@/lib/payments/bank-accounts";
import { money } from "@/lib/payments/statements";
import type { OpenDocuments } from "./settlements";
import { EVENT_KIND } from "./terms";

/**
 * M2c-7d-1 (plan docs/design/m2c-7-plan.md §6.1–§6.4): the client's events as « Événements du client » shows them (SQL's
 * public.client_events_view: what each event counts as, a seizure standing or released, an old row to qualify, who acts
 * for the client, the documents a declaration names), the payee the events require, who receives the letters, and the
 * forms' fields. Every rule is SQL's; these only word it, and never present the servicer's rule as the law's.
 */

export const REPRESENTATIVE_ROLE: Readonly<Record<string, string>> = {
  notary: "Notaire",
  heirs: "Héritiers",
  tutor: "Tuteur",
  curator: "Curateur",
  liquidator: "Liquidateur",
  administrator: "Administrateur judiciaire",
};

/** Which roles each event takes (the command checks again: role_mismatch). */
export const EVENT_ROLES: Readonly<Record<string, readonly string[]>> = {
  death: ["notary", "heirs"],
  guardianship: ["tutor"],
  curatorship: ["curator"],
  liquidation: ["liquidator"],
  proceeding_opened: ["administrator"],
};

export const PAYOUT_KIND: Readonly<Record<string, string>> = {
  client: "Le client",
  court_appointed: "Un mandataire de justice (liquidateur, administrateur)",
  estate: "Succession — compte du notaire, ou compte désigné par tous les héritiers",
  // (review round 1, TUI-7) C. civ. 427 al. 5 (read 2026-11-24): « exclusivement au moyen des comptes ouverts au nom de
  // celle-ci »; who makes it work depends on the measure (440; 472: the curator receives the income only in a curatelle
  // renforcée) — not stated here
  protected_adult: "Compte du majeur protégé, ouvert à son nom (art. 427 C. civ.)",
};

/** What the form says of an event's date or fields (texts read 2026-11-24: C. civ. 2006, 2007; C. com. R622-24). */
export const EVENT_HINT: Readonly<Record<string, string>> = {
  mandate_ended:
    "Date d'effet : pour une révocation, le jour où elle a été notifiée au cabinet (la désignation d'un nouveau mandataire vaut révocation « à compter du jour où elle a été notifiée », art. 2006 C. civ.) ; pour une renonciation du cabinet, le jour où elle a été notifiée au client (art. 2007 C. civ.).",
  publication:
    "Date de publication au BODACC (procédure collective ou liquidation) : le délai de déclaration des créances court de cette publication (art. R622-24 C. com.).",
  curatorship:
    "Une curatelle ne met pas fin au mandat (l'art. 2003 C. civ. nomme la tutelle) : le cabinet bloque pourtant les reversements jusqu'à la confirmation d'un compte au nom du client (règle du cabinet).",
};

/** The payee the events require (public.client_events_view.payee), in words. */
export function payeeRule(payee: { kind: string; event_kind: string } | null | undefined): string {
  if (!payee) return "";
  // (review round 1, MONEY-LAW-1) an old « Tutelle ou curatelle » row still to qualify: no account lifts it before
  if (payee.kind === "to_qualify")
    return "Reversements bloqués tant que la « Tutelle ou curatelle » enregistrée n'est pas précisée (« Préciser : tutelle ou curatelle », avec le jugement) : aucun compte ne lève ce blocage avant (règle du cabinet).";
  const which: Record<string, string> = {
    estate: "celui de la succession (compte du notaire, ou compte désigné par tous les héritiers), avec sa pièce",
    protected_adult: "un compte ouvert au nom du client (art. 427 C. civ.), avec le jugement",
    court_appointed: "celui du liquidateur, avec le jugement qui le nomme",
    client: "le compte du client, confirmé à nouveau",
  };
  return `Compte exigé : ${which[payee.kind] ?? payee.kind}, confirmé par un second administrateur après l'événement.`;
}

export type Representative = { role: string; name: string; address_lines: string[] };

export type ClientEvent = {
  id: string;
  kind: string;
  effective_kind: string | null;
  effective_date: string;
  recorded_on: string;
  publication_date: string | null;
  note: string | null;
  evidence_document_id: string;
  refers_to_event_id: string | null;
  standing: boolean | null;
  released_on: string | null;
  to_qualify: boolean;
  qualification: { kind: string; curatorship_event_id: string | null; evidence_document_id: string; recorded_on: string } | null;
  representative: (Representative & { recorded_on: string; evidence_document_id: string }) | null;
  representatives: number;
  declared: { document_kind: string; document_id: string; number: string | null; amount_minor: string }[];
};

export type Addressee = Representative & { copy: boolean };

export type ClientEvents = {
  events: ClientEvent[];
  payee: { kind: string; event_kind: string } | null;
  seizure_standing?: boolean;
  addressees: Addressee[];
  accounts: {
    payout_account_id: string;
    kind: string;
    holder_name: string;
    client_name: string;
    names_match: boolean | null;
    holder_attestation: string | null;
    authority_document_id: string | null;
  }[];
};

/** public.client_events_view's jsonb, or null when it is not that shape. */
export function parseClientEvents(v: unknown): ClientEvents | null {
  if (!v || typeof v !== "object") return null;
  const o = v as Record<string, unknown>;
  if (!Array.isArray(o.events) || !Array.isArray(o.addressees)) return null;
  return {
    events: o.events as ClientEvent[],
    payee: (o.payee as ClientEvents["payee"]) ?? null,
    seizure_standing: o.seizure_standing === true,
    addressees: o.addressees as Addressee[],
    accounts: Array.isArray(o.accounts) ? (o.accounts as ClientEvents["accounts"]) : [],
  };
}

/**
 * An event's line on « Événements du client »: its date, what it was recorded as — (review round 1, TUI-2) an old row
 * recorded as « Tutelle ou curatelle » keeps that name, with what it was qualified as, never « Tutelle » alone —, a
 * seizure standing or released, the BODACC publication, when it was recorded, the note.
 */
export function eventLine(e: ClientEvent): string {
  const old = e.to_qualify || e.qualification !== null;
  const label = !old
    ? (EVENT_KIND[e.kind] ?? e.kind)
    : e.to_qualify
      ? "Tutelle ou curatelle (à préciser)"
      : `Tutelle ou curatelle — précisé : ${e.qualification?.kind === "curatorship" ? "curatelle" : "tutelle"}`;
  const bits = [`${frenchDate(e.effective_date)} · ${label}`];
  if (e.kind === "seizure") bits.push(e.standing ? "en cours" : e.released_on ? `levée le ${frenchDate(e.released_on)}` : "levée");
  if (e.publication_date) bits.push(`publication au BODACC le ${frenchDate(e.publication_date)}`);
  bits.push(`enregistré le ${frenchDate(e.recorded_on)}`);
  if (e.note) bits.push(e.note);
  return bits.join(" · ");
}

/** The seizures a release may name: standing ones, earliest first. */
export function standingSeizures(events: ClientEvent[]): ClientEvent[] {
  return events
    .filter((e) => e.kind === "seizure" && e.standing === true)
    .sort((a, b) => a.effective_date.localeCompare(b.effective_date));
}

const ROLE_WORD: Readonly<Record<string, string>> = {
  notary: "notaire",
  heirs: "héritiers",
  tutor: "tuteur",
  curator: "curateur",
  liquidator: "liquidateur",
  administrator: "administrateur judiciaire",
};

/** Who receives the letters (private.client_addressee), one line each; a sentence when nobody is recorded. */
export function addresseeLines(addressees: Addressee[]): string[] {
  if (addressees.length === 0)
    return [
      "Personne n'est enregistré pour recevoir les courriers : indiquez qui agit pour le client (notaire ou héritiers, tuteur, curateur ou liquidateur ; une « Tutelle ou curatelle » enregistrée avant leur distinction se précise d'abord).",
    ];
  return addressees.map((a) => {
    const who = a.role === "client" ? a.name : `${a.name} (${ROLE_WORD[a.role] ?? a.role})`;
    return `${a.copy ? "Copie : " : ""}${who} — ${a.address_lines.join(", ")}`;
  });
}

/**
 * The documents a declaration may name: the client's open invoices and advances (« Ce que le client doit au cabinet »),
 * each with its open amount as the page shows it (the amount declared is typed: the command checks the document).
 */
export function declarableDocuments(
  owes: OpenDocuments | null,
): { kind: "invoice" | "advance"; id: string; label: string }[] {
  if (!owes) return [];
  return [
    ...owes.invoices.map((i) => ({
      kind: "invoice" as const,
      id: i.id,
      label: `Facture ${i.number} (reste ${money(i.open_minor, owes.currency)})`,
    })),
    ...owes.advances.map((a) => ({
      kind: "advance" as const,
      id: a.id,
      label: `Avance du ${frenchDate(a.created_on)} (reste ${money(a.open_minor, owes.currency)})`,
    })),
  ];
}

/** The person who acts for the client from the form (role, name, up to four address lines); null when no role. */
export function representativeFromForm(formData: FormData): Representative | null {
  const role = String(formData.get("rep_role") ?? "").trim();
  if (!role) return null;
  const lines = String(formData.get("rep_address") ?? "")
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l !== "");
  return { role, name: String(formData.get("rep_name") ?? "").trim(), address_lines: lines };
}

/** The documents a declaration names (« declared » = kind:id) and their amounts in euros, as minor units in text. */
export function declaredFromForm(formData: FormData): { document_kind: string; document_id: string; amount_minor: string }[] {
  return formData.getAll("declared").map((v) => {
    const [kind, id] = String(v).split(":");
    const minor = parseEurosToMinor(String(formData.get(`declared_amount_${id}`) ?? "").trim());
    return { document_kind: kind, document_id: id, amount_minor: minor === null ? "" : minor.toString() };
  });
}
