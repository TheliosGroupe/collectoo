import { redirect } from "next/navigation";
import { Page } from "@/components/ui";
import { type SessionClaims, afterMfa } from "@/lib/auth/access";
import { createClient } from "@/lib/supabase/server";
import { MfaForm } from "./mfa-form";

/** TOTP enrolment or verification: staff always; a client user to step up (M2c-2: confirming a payout IBAN). */
export default async function MfaPage({ searchParams }: { searchParams: Promise<{ next?: string }> }) {
  const supabase = await createClient();
  const { data } = await supabase.auth.getClaims();
  const claims = (data?.claims ?? null) as SessionClaims | null;
  if (!claims?.sub) redirect("/connexion");
  const { next } = await searchParams;
  return (
    <Page title="Double authentification">
      <MfaForm target={afterMfa(next, claims)} />
    </Page>
  );
}
