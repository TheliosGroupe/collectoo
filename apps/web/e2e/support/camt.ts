/**
 * A camt.053.001.08 statement of credits, for E2E tests that pay files boarded during the test (their RF
 * references are drawn at confirmation). Same shapes as the worker's synthetic renderer
 * (collectoo_worker.synth.camt053.render_camt053). Synthetic data only.
 */

export type Credit = {
  /** The bank's own line reference (AcctSvcrRef), unique per statement. */
  ref: string;
  amountMinor: bigint;
  name: string;
  iban: string;
  ustrd?: string[];
  /** Structured creditor reference (CdtrRefInf/Ref), e.g. an RF reference. */
  rf?: string;
  /** The payer's end-to-end id (NOTPROVIDED when absent). */
  e2e?: string;
  /** M2c-6b-2c: the bank's return of one of our transfers (a return code, its RMT id as the end-to-end id). */
  returned?: boolean;
};

/**
 * M2b-6: a debit of the statement — a payment's return (reversal, RtrInf reason), our refund (RFD…), a fee; M2c-6b-1:
 * our transfer (a payout's RMT…, the sweep's SWP…) as the bank debits it.
 */
export type Debit = {
  ref: string;
  amountMinor: bigint;
  kind: "return" | "refund" | "fee" | "other" | "transfer" | "lot" | "charged";
  /**
   * return: the end-to-end id of the credit it takes back; refund: our RFD reference; transfer: its RMT or SWP id;
   * charged: the RMT id of its one detail.
   */
  e2e?: string;
  name?: string;
  /** M2c-6b-2d, lot: one line for a PmtInf of our file, without its details (the worker's synth `partial` shape). */
  pmtInfId?: string;
  /** lot: the NbOfTxs the bank gives (default 1: what the line holds). */
  nbOfTxs?: number;
  /**
   * M2c-6b-2d, charged: the ISO shape of a charged transfer (the worker's synth `debit_charge_minor`): the entry is
   * `amountMinor` (the transfer + the charge), its one detail carries the transfer's amount as its instructed amount
   * (AmtDtls/TxAmt) and the entry the charge in `Chrgs` — the parser keeps it unsplit with that detail and charge.
   */
  instructedMinor?: bigint;
  chargesMinor?: bigint;
};

function esc(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function amount(minor: bigint): string {
  const cents = (minor % BigInt(100)).toString().padStart(2, "0");
  return `${minor / BigInt(100)}.${cents}`;
}

function mod97(text: string): bigint {
  const digits = [...text]
    .map((c) => (/[A-Z]/.test(c) ? String(c.charCodeAt(0) - 55) : c))
    .join("");
  return BigInt(digits) % BigInt(97);
}

/** A synthetic French IBAN with valid check digits, from a number (deterministic). */
export function ibanFr(n: number): string {
  const bban = `3000400003${String(n).padStart(11, "0")}${String((n * 7) % 97).padStart(2, "0")}`;
  const check = BigInt(98) - mod97(`${bban}FR00`);
  return `FR${check.toString().padStart(2, "0")}${bban}`;
}

export function camt053(iban: string, day: string, credits: Credit[]): string {
  return camt053Lines(iban, day, credits, [], BigInt(0));
}

/**
 * A one-day statement of credits and debits, from an opening balance (the previous statement's closing). With `period`
 * (review M2c-6b-3a-2 round 1, tests-5): a statement of `period.from` to `day` produced at `period.createdAt` (an ISO
 * date-time in Paris time, after those days: the statements' evidence of a cancellation counts a day only then).
 */
export function camt053Lines(
  iban: string,
  day: string,
  credits: Credit[],
  debits: Debit[],
  opening: bigint,
  period?: { from: string; createdAt: string },
): string {
  const total =
    opening +
    credits.reduce((s, c) => s + c.amountMinor, BigInt(0)) -
    debits.reduce((s, d) => s + d.amountMinor, BigInt(0));
  const bal = (code: string, minor: bigint) =>
    `<Bal><Tp><CdOrPrtry><Cd>${code}</Cd></CdOrPrtry></Tp><Amt Ccy="EUR">${amount(minor < BigInt(0) ? -minor : minor)}</Amt>` +
    `<CdtDbtInd>${minor < BigInt(0) ? "DBIT" : "CRDT"}</CdtDbtInd><Dt><Dt>${day}</Dt></Dt></Bal>`;
  const entries = credits.map((c) => {
    const remittance =
      (c.ustrd ?? []).map((u) => `<Ustrd>${esc(u)}</Ustrd>`).join("") +
      (c.rf
        ? `<Strd><CdtrRefInf><Tp><CdOrPrtry><Cd>SCOR</Cd></CdOrPrtry></Tp><Ref>${esc(c.rf)}</Ref></CdtrRefInf></Strd>`
        : "");
    return (
      `<Ntry><Amt Ccy="EUR">${amount(c.amountMinor)}</Amt><CdtDbtInd>CRDT</CdtDbtInd><Sts><Cd>BOOK</Cd></Sts>` +
      `<BookgDt><Dt>${day}</Dt></BookgDt><ValDt><Dt>${day}</Dt></ValDt><AcctSvcrRef>N${esc(c.ref)}</AcctSvcrRef>` +
      `<BkTxCd><Domn><Cd>PMNT</Cd><Fmly><Cd>${c.returned ? "ICDT" : "RCDT"}</Cd><SubFmlyCd>${c.returned ? "RRTN" : "ESCT"}</SubFmlyCd></Fmly></Domn></BkTxCd>` +
      `<NtryDtls><TxDtls><Refs><AcctSvcrRef>${esc(c.ref)}</AcctSvcrRef><EndToEndId>${esc(c.e2e ?? "NOTPROVIDED")}</EndToEndId></Refs>` +
      `<Amt Ccy="EUR">${amount(c.amountMinor)}</Amt><CdtDbtInd>CRDT</CdtDbtInd>` +
      `<RltdPties><Dbtr><Pty><Nm>${esc(c.name)}</Nm></Pty></Dbtr><DbtrAcct><Id><IBAN>${c.iban}</IBAN></Id></DbtrAcct></RltdPties>` +
      (remittance ? `<RmtInf>${remittance}</RmtInf>` : "") +
      (c.returned ? "<RtrInf><Rsn><Cd>AC04</Cd></Rsn></RtrInf>" : "") +
      `</TxDtls></NtryDtls></Ntry>`
    );
  });
  return (
    `<?xml version="1.0" encoding="UTF-8"?>\n` +
    `<Document xmlns="urn:iso:std:iso:20022:tech:xsd:camt.053.001.08"><BkToCstmrStmt>` +
    `<GrpHdr><MsgId>MSG-E2E-${period?.from ?? ""}${day}</MsgId><CreDtTm>${period?.createdAt ?? `${day}T20:00:00`}</CreDtTm></GrpHdr>` +
    `<Stmt><Id>STMT-E2E-${period?.from ?? ""}${day}</Id><ElctrncSeqNb>1</ElctrncSeqNb><CreDtTm>${period?.createdAt ?? `${day}T20:00:00`}</CreDtTm>` +
    `<FrToDt><FrDtTm>${period?.from ?? day}T00:00:00</FrDtTm><ToDtTm>${day}T23:59:59</ToDtTm></FrToDt>` +
    `<Acct><Id><IBAN>${iban}</IBAN></Id><Ccy>EUR</Ccy></Acct>` +
    bal("OPBD", opening) +
    bal("CLBD", total) +
    entries.join("") +
    debits.map(debitEntry(day)).join("") +
    `</Stmt></BkToCstmrStmt></Document>\n`
  );
}

/** A debit entry as banks write them (the worker's synthetic renderer writes the same shapes). */
function debitEntry(day: string): (d: Debit) => string {
  return (d) => {
    const code =
      d.kind === "return"
        ? ["PMNT", "RCDT", "RRTN"]
        : d.kind === "fee"
          ? ["PMNT", "MDOP", "FEES"]
          : ["PMNT", "ICDT", "ESCT"];
    const head =
      `<Ntry><Amt Ccy="EUR">${amount(d.amountMinor)}</Amt><CdtDbtInd>DBIT</CdtDbtInd>` +
      (d.kind === "return" ? "<RvslInd>true</RvslInd>" : "") +
      `<Sts><Cd>BOOK</Cd></Sts><BookgDt><Dt>${day}</Dt></BookgDt><ValDt><Dt>${day}</Dt></ValDt>` +
      `<AcctSvcrRef>N${esc(d.ref)}</AcctSvcrRef>` +
      `<BkTxCd><Domn><Cd>${code[0]}</Cd><Fmly><Cd>${code[1]}</Cd><SubFmlyCd>${code[2]}</SubFmlyCd></Fmly></Domn></BkTxCd>`;
    if (d.kind === "fee")
      return `${head}<AddtlNtryInf>FRAIS DE TENUE DE COMPTE</AddtlNtryInf></Ntry>`;
    // M2c-1: a debit the bank does not code as a charge (ops book it as a fee, or explain it)
    if (d.kind === "other")
      return `${head}<AddtlNtryInf>PRELEVEMENT ABONNEMENT BANQUE EN LIGNE</AddtlNtryInf></Ntry>`;
    // M2c-6b-2d: one line for a lot of our file, its PmtInfId and count, no detail
    if (d.kind === "lot")
      return (
        `${head}<NtryDtls><Btch><PmtInfId>${esc(d.pmtInfId ?? "")}</PmtInfId>` +
        `<NbOfTxs>${d.nbOfTxs ?? 1}</NbOfTxs></Btch></NtryDtls><AddtlNtryInf>VIREMENTS SEPA</AddtlNtryInf></Ntry>`
      );
    // M2c-6b-2d: our transfer charged on its own entry (the charge in Chrgs, the transfer's amount in its detail)
    if (d.kind === "charged")
      return (
        `${head}<Chrgs><Rcrd><Amt Ccy="EUR">${amount(d.chargesMinor ?? BigInt(0))}</Amt><CdtDbtInd>DBIT</CdtDbtInd>` +
        `<ChrgInclInd>true</ChrgInclInd></Rcrd></Chrgs>` +
        `<NtryDtls><TxDtls><Refs><AcctSvcrRef>${esc(d.ref)}</AcctSvcrRef><EndToEndId>${esc(d.e2e ?? "NOTPROVIDED")}</EndToEndId></Refs>` +
        `<AmtDtls><TxAmt><Amt Ccy="EUR">${amount(d.instructedMinor ?? BigInt(0))}</Amt></TxAmt></AmtDtls>` +
        (d.name ? `<RltdPties><Cdtr><Pty><Nm>${esc(d.name)}</Nm></Pty></Cdtr></RltdPties>` : "") +
        `<RmtInf><Ustrd>VIREMENT SEPA</Ustrd></RmtInf></TxDtls></NtryDtls></Ntry>`
      );
    return (
      head +
      `<NtryDtls><TxDtls><Refs><AcctSvcrRef>${esc(d.ref)}</AcctSvcrRef><EndToEndId>${esc(d.e2e ?? "NOTPROVIDED")}</EndToEndId></Refs>` +
      `<Amt Ccy="EUR">${amount(d.amountMinor)}</Amt><CdtDbtInd>DBIT</CdtDbtInd>` +
      (d.name
        ? `<RltdPties><Cdtr><Pty><Nm>${esc(d.name)}</Nm></Pty></Cdtr></RltdPties>`
        : "") +
      `<RmtInf><Ustrd>${d.kind === "return" ? "RETOUR MD06" : d.kind === "transfer" ? "VIREMENT SEPA" : "REMBOURSEMENT"}</Ustrd></RmtInf>` +
      (d.kind === "return" ? "<RtrInf><Rsn><Cd>MD06</Cd></Rsn></RtrInf>" : "") +
      `</TxDtls></NtryDtls></Ntry>`
    );
  };
}
