/**
 * Reads the one-time code from the newest email sent to `email` after `since` (local Mailpit).
 * `since` avoids picking up an older, already-used code.
 */
export async function latestCode(email: string, since: Date, timeoutMs = 15_000): Promise<string> {
  const base = process.env.MAILPIT_URL ?? "http://127.0.0.1:54324";
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const res = await fetch(`${base}/api/v1/search?query=${encodeURIComponent(`to:"${email}"`)}`);
    if (res.ok) {
      const list = (await res.json()) as { messages?: { ID: string; Created: string }[] };
      const fresh = (list.messages ?? [])
        .filter((m) => new Date(m.Created).getTime() >= since.getTime())
        .sort((a, b) => Date.parse(b.Created) - Date.parse(a.Created));
      if (fresh[0]) {
        const msg = (await (await fetch(`${base}/api/v1/message/${fresh[0].ID}`)).json()) as {
          Text?: string;
        };
        const code = msg.Text?.match(/\b(\d{6})\b/)?.[1];
        if (code) return code;
      }
    }
    await new Promise((r) => setTimeout(r, 300));
  }
  throw new Error(`no code received for ${email}`);
}
