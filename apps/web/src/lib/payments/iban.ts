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

/** ISO 13616: country, check digits 02-98, 11 to 30 characters, ≡ 1 (mod 97) once rearranged. */
export function ibanValid(iban: string): boolean {
  return IBAN_RE.test(iban) && mod97(iban.slice(4) + iban.slice(0, 4)) === 1;
}

/** ISO 11649 RF creditor reference (upper case, no spaces). */
export function rfValid(ref: string): boolean {
  return RF_RE.test(ref) && mod97(ref.slice(4) + ref.slice(0, 4)) === 1;
}

/** Groups of four, as printed: FR76 3000 4000 0312 3456 7890 143, RF18 5390 0754 7034. */
export function groupsOfFour(code: string): string {
  return code.replace(/(.{4})(?=.)/g, "$1 ");
}
