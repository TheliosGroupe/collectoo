/**
 * IBAN and RF reference helpers for display and early feedback in forms. The database checks
 * again (private.iban_valid, private.rf_valid): it is the gate. No floats: the mod-97 remainder
 * is computed digit by digit on small integers.
 */

const IBAN_RE = /^[A-Z]{2}(0[2-9]|[1-8][0-9]|9[0-8])[0-9A-Z]{11,30}$/;
const RF_RE = /^RF(0[2-9]|[1-8][0-9]|9[0-8])[0-9A-Z]{1,21}$/;

/** What a person typed: ASCII spaces and line breaks removed, ASCII letters upper-cased. */
export function normaliseCode(text: string): string {
  return text.replace(/[ \t\n\r\f\v]/g, "").replace(/[a-z]/g, (c) => c.toUpperCase());
}

/** Remainder mod 97 of an alphanumeric string, letters as two digits (A = 10 … Z = 35). */
export function mod97(text: string): number {
  let r = 0;
  for (const c of text) {
    const v = Number.parseInt(c, 36);
    if (Number.isNaN(v) || c !== c.toUpperCase()) throw new Error("mod97 takes 0-9 and A-Z only");
    r = v >= 10 ? (r * 100 + v) % 97 : (r * 10 + v) % 97;
  }
  return r;
}

/** ISO 13616 IBAN length per country (SWIFT IBAN registry), identical to SQL and Python. */
export const IBAN_LENGTHS: Readonly<Record<string, number>> = {
  AD: 24,
  AE: 23,
  AL: 28,
  AT: 20,
  AZ: 28,
  BA: 20,
  BE: 16,
  BG: 22,
  BH: 22,
  BI: 27,
  BR: 29,
  BY: 28,
  CH: 21,
  CR: 22,
  CY: 28,
  CZ: 24,
  DE: 22,
  DJ: 27,
  DK: 18,
  DO: 28,
  EE: 20,
  EG: 29,
  ES: 24,
  FI: 18,
  FK: 18,
  FO: 18,
  FR: 27,
  GB: 22,
  GE: 22,
  GI: 23,
  GL: 18,
  GR: 27,
  GT: 28,
  HN: 28,
  HR: 21,
  HU: 28,
  IE: 22,
  IL: 23,
  IQ: 23,
  IS: 26,
  IT: 27,
  JO: 30,
  KW: 30,
  KZ: 20,
  LB: 28,
  LC: 32,
  LI: 21,
  LT: 20,
  LU: 20,
  LV: 21,
  LY: 25,
  MC: 27,
  MD: 24,
  ME: 22,
  MK: 19,
  MN: 20,
  MR: 27,
  MT: 31,
  MU: 30,
  NI: 28,
  NL: 18,
  NO: 15,
  OM: 23,
  PK: 24,
  PL: 28,
  PS: 29,
  PT: 25,
  QA: 29,
  RO: 24,
  RS: 22,
  RU: 33,
  SA: 24,
  SC: 31,
  SD: 18,
  SE: 24,
  SI: 19,
  SK: 24,
  SM: 27,
  SO: 23,
  ST: 25,
  SV: 28,
  TL: 23,
  TN: 24,
  TR: 26,
  UA: 29,
  VA: 22,
  VG: 24,
  XK: 20,
  YE: 30,
};

/** ISO 13616: a registry country, check digits 02-98, that country's exact length, ≡ 1 (mod 97). */
export function ibanValid(iban: string): boolean {
  return (
    IBAN_RE.test(iban) &&
    IBAN_LENGTHS[iban.slice(0, 2)] === iban.length &&
    mod97(iban.slice(4) + iban.slice(0, 4)) === 1
  );
}

/** A code typed or pasted in a form: any Unicode space removed (e.g. non-breaking spaces copied
 * from a bank PDF), then the shared normalisation. */
export function cleanTypedCode(text: string): string {
  return normaliseCode(text.replace(/\s/g, ""));
}

/** ISO 11649 RF creditor reference (upper case, no spaces). */
export function rfValid(ref: string): boolean {
  return RF_RE.test(ref) && mod97(ref.slice(4) + ref.slice(0, 4)) === 1;
}

/** Groups of four, as printed: FR76 3000 4000 0312 3456 7890 143, RF18 5390 0754 7034. */
export function groupsOfFour(code: string): string {
  return code.replace(/(.{4})(?=.)/g, "$1 ");
}
