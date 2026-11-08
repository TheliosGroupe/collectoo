/** Money is always integer minor units + ISO 4217 currency. Never floats. */
export type Money = { minor: bigint; currency: string };

/** Formats money for French debtor-facing copy, e.g. 123456 minor units EUR -> "1 234,56 €". */
export function formatMoneyFr({ minor, currency }: Money): string {
  const negative = minor < BigInt(0);
  const abs = negative ? -minor : minor;
  const units = abs / BigInt(100);
  const cents = (abs % BigInt(100)).toString().padStart(2, "0");
  const grouped = units.toString().replace(/\B(?=(\d{3})+(?!\d))/g, " ");
  const symbol = currency === "EUR" ? "€" : currency;
  return `${negative ? "-" : ""}${grouped},${cents} ${symbol}`;
}
