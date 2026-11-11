/**
 * Public Supabase settings. The secret/service key never reaches the browser; the server reads it in one place only,
 * the transfer file download after its command (`transfer-file-bytes.ts`, M2c-6a review T4).
 */
export function supabaseEnv(): { url: string; publishableKey: string } {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const publishableKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  if (!url || !publishableKey) {
    throw new Error("NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY must be set");
  }
  return { url, publishableKey };
}
