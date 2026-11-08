"use server";

import { redirect } from "next/navigation";
import { decideAccess, homeFor, type SessionClaims } from "@/lib/auth/access";
import { createClient } from "@/lib/supabase/server";

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export async function requestCode(formData: FormData) {
  const email = String(formData.get("email") ?? "").trim().toLowerCase();
  if (!EMAIL.test(email)) redirect("/connexion?erreur=email");
  const supabase = await createClient();
  // Accounts are created by invitation only. The outcome is not revealed to the visitor.
  await supabase.auth.signInWithOtp({ email, options: { shouldCreateUser: false } });
  redirect(`/connexion/code?email=${encodeURIComponent(email)}`);
}

export async function verifyCode(formData: FormData) {
  const email = String(formData.get("email") ?? "").trim().toLowerCase();
  const token = String(formData.get("code") ?? "").replace(/\s/g, "");
  const supabase = await createClient();
  const { error } = await supabase.auth.verifyOtp({ email, token, type: "email" });
  if (error) redirect(`/connexion/code?email=${encodeURIComponent(email)}&erreur=code`);
  const { data } = await supabase.auth.getClaims();
  const claims = (data?.claims as SessionClaims) ?? {};
  // Go straight to the final page (e.g. MFA for staff) rather than chaining redirects.
  const home = homeFor(claims);
  const decision = decideAccess(home, claims);
  redirect(decision.kind === "redirect" ? decision.to : home);
}
