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
};

function esc(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function amount(minor: bigint): string {
  const cents = (minor % BigInt(100)).toString().padStart(2, "0");
  return `${minor / BigInt(100)}.${cents}`;
}

function mod97(text: string): bigint {
  const digits = [...text].map((c) => (/[A-Z]/.test(c) ? String(c.charCodeAt(0) - 55) : c)).join("");
  return BigInt(digits) % BigInt(97);
}

/** A synthetic French IBAN with valid check digits, from a number (deterministic). */
export function ibanFr(n: number): string {
  const bban = `3000400003${String(n).padStart(11, "0")}${String((n * 7) % 97).padStart(2, "0")}`;
  const check = BigInt(98) - mod97(`${bban}FR00`);
  return `FR${check.toString().padStart(2, "0")}${bban}`;
}

export function camt053(iban: string, day: string, credits: Credit[]): string {
  const total = credits.reduce((s, c) => s + c.amountMinor, BigInt(0));
  const bal = (code: string, minor: bigint) =>
    `<Bal><Tp><CdOrPrtry><Cd>${code}</Cd></CdOrPrtry></Tp><Amt Ccy="EUR">${amount(minor)}</Amt>` +
    `<CdtDbtInd>CRDT</CdtDbtInd><Dt><Dt>${day}</Dt></Dt></Bal>`;
  const entries = credits.map((c) => {
    const remittance =
      (c.ustrd ?? []).map((u) => `<Ustrd>${esc(u)}</Ustrd>`).join("") +
      (c.rf ? `<Strd><CdtrRefInf><Tp><CdOrPrtry><Cd>SCOR</Cd></CdOrPrtry></Tp><Ref>${esc(c.rf)}</Ref></CdtrRefInf></Strd>` : "");
    return (
      `<Ntry><Amt Ccy="EUR">${amount(c.amountMinor)}</Amt><CdtDbtInd>CRDT</CdtDbtInd><Sts><Cd>BOOK</Cd></Sts>` +
      `<BookgDt><Dt>${day}</Dt></BookgDt><ValDt><Dt>${day}</Dt></ValDt><AcctSvcrRef>N${esc(c.ref)}</AcctSvcrRef>` +
      `<BkTxCd><Domn><Cd>PMNT</Cd><Fmly><Cd>RCDT</Cd><SubFmlyCd>ESCT</SubFmlyCd></Fmly></Domn></BkTxCd>` +
      `<NtryDtls><TxDtls><Refs><AcctSvcrRef>${esc(c.ref)}</AcctSvcrRef><EndToEndId>NOTPROVIDED</EndToEndId></Refs>` +
      `<Amt Ccy="EUR">${amount(c.amountMinor)}</Amt><CdtDbtInd>CRDT</CdtDbtInd>` +
      `<RltdPties><Dbtr><Pty><Nm>${esc(c.name)}</Nm></Pty></Dbtr><DbtrAcct><Id><IBAN>${c.iban}</IBAN></Id></DbtrAcct></RltdPties>` +
      (remittance ? `<RmtInf>${remittance}</RmtInf>` : "") +
      `</TxDtls></NtryDtls></Ntry>`
    );
  });
  return (
    `<?xml version="1.0" encoding="UTF-8"?>\n` +
    `<Document xmlns="urn:iso:std:iso:20022:tech:xsd:camt.053.001.08"><BkToCstmrStmt>` +
    `<GrpHdr><MsgId>MSG-E2E-${day}</MsgId><CreDtTm>${day}T20:00:00</CreDtTm></GrpHdr>` +
    `<Stmt><Id>STMT-E2E-${day}</Id><ElctrncSeqNb>1</ElctrncSeqNb><CreDtTm>${day}T20:00:00</CreDtTm>` +
    `<FrToDt><FrDtTm>${day}T00:00:00</FrDtTm><ToDtTm>${day}T23:59:59</ToDtTm></FrToDt>` +
    `<Acct><Id><IBAN>${iban}</IBAN></Id><Ccy>EUR</Ccy></Acct>` +
    bal("OPBD", BigInt(0)) +
    bal("CLBD", total) +
    entries.join("") +
    `</Stmt></BkToCstmrStmt></Document>\n`
  );
}
