/**
 * Route gating decided from verified JWT claims. This is UX only: the database (RLS) is the
 * real gate, and staff read nothing there below MFA level aal2.
 */
export type SessionClaims = {
  sub?: string;
  aal?: string;
  is_internal?: boolean;
};

export type AccessDecision =
  | { kind: "allow" }
  | { kind: "redirect"; to: "/connexion" | "/mfa" | "/client" | "/backoffice" };

export function decideAccess(pathname: string, claims: SessionClaims | null): AccessDecision {
  const isBackoffice = pathname === "/backoffice" || pathname.startsWith("/backoffice/");
  const isClient = pathname === "/client" || pathname.startsWith("/client/");
  const isMfa = pathname === "/mfa";

  if (!isBackoffice && !isClient && !isMfa) return { kind: "allow" };
  if (!claims?.sub) return { kind: "redirect", to: "/connexion" };

  const internal = claims.is_internal === true;
  if (isMfa) return internal ? { kind: "allow" } : { kind: "redirect", to: "/client" };
  if (isBackoffice) {
    if (!internal) return { kind: "redirect", to: "/client" };
    if (claims.aal !== "aal2") return { kind: "redirect", to: "/mfa" };
    return { kind: "allow" };
  }
  // Client space: internal staff belong in the back-office.
  return internal ? { kind: "redirect", to: "/backoffice" } : { kind: "allow" };
}

/** Where to land after a successful login. */
export function homeFor(claims: SessionClaims): "/backoffice" | "/client" {
  return claims.is_internal === true ? "/backoffice" : "/client";
}
