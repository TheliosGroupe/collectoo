import { redirect } from "next/navigation";
import type { SessionClaims } from "@/lib/auth/access";
import { createClient } from "@/lib/supabase/server";

/**
 * Back-office pages and actions: a signed-in staff session at aal2, else redirect.
 * The database (RLS + command checks) remains the real gate.
 */
export async function staffSession() {
  const supabase = await createClient();
  const { data } = await supabase.auth.getClaims();
  const claims = (data?.claims ?? null) as (SessionClaims & { email?: string }) | null;
  if (!claims?.sub) redirect("/connexion");
  if (claims.aal !== "aal2") redirect("/mfa");
  return { supabase, claims };
}
