import { createClient } from "@supabase/supabase-js";
import { supabaseEnv } from "./env";

/**
 * M2c-6a review T4 (money#3, security#2): no storage policy reads the private bucket `transfer-files`, so a transfer
 * file's bytes are read here, with the service role, by the download route only — and only after
 * `transfer_file_download` (with the caller's session) accepted the download: its role check, its re-run of the
 * generation's checks, the download recorded. The key is `SUPABASE_SECRET_KEY`, a server-side variable (never
 * `NEXT_PUBLIC_…`: Next.js never sends it to the browser); this module does nothing else. Without it (null), the route
 * reads with the caller's session, which only an older storage policy allowed.
 *
 * This is the one place apps/web holds the service role (ARCHITECTURE §13 « M2c-6a review T4 », to confirm by the
 * founder; the alternative, a policy reading a live file within seconds of the caller's recorded download, keeps the
 * key out of apps/web).
 */
export function transferFileReader(): ((path: string) => Promise<Buffer<ArrayBuffer> | null>) | null {
  const key = process.env.SUPABASE_SECRET_KEY;
  if (!key) return null;
  const admin = createClient(supabaseEnv().url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  return async (path) => {
    const { data, error } = await admin.storage.from("transfer-files").download(path);
    return error || !data ? null : Buffer.from(await data.arrayBuffer());
  };
}
