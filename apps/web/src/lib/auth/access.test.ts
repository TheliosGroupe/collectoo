import { describe, expect, it } from "vitest";
import { afterMfa, decideAccess, homeFor } from "./access";

const staff = { sub: "u1", is_internal: true, aal: "aal1" };
const staffMfa = { ...staff, aal: "aal2" };
const client = { sub: "u2", is_internal: false, aal: "aal1" };

describe("decideAccess", () => {
  it("leaves public pages alone", () => {
    expect(decideAccess("/", null)).toEqual({ kind: "allow" });
    expect(decideAccess("/connexion", null)).toEqual({ kind: "allow" });
  });
  it("sends anonymous users to login", () => {
    expect(decideAccess("/backoffice", null)).toEqual({ kind: "redirect", to: "/connexion" });
    expect(decideAccess("/client/dossiers", null)).toEqual({ kind: "redirect", to: "/connexion" });
  });
  it("requires MFA (aal2) for staff in the back-office", () => {
    expect(decideAccess("/backoffice", staff)).toEqual({ kind: "redirect", to: "/mfa" });
    expect(decideAccess("/backoffice/x", staffMfa)).toEqual({ kind: "allow" });
  });
  it("keeps client users out of the back-office", () => {
    expect(decideAccess("/backoffice", client)).toEqual({ kind: "redirect", to: "/client" });
    expect(decideAccess("/client", client)).toEqual({ kind: "allow" });
  });
  it("lets client users reach the MFA page (M2c-2: a client administrator confirms a payout IBAN at aal2)", () => {
    expect(decideAccess("/mfa", client)).toEqual({ kind: "allow" });
    expect(decideAccess("/mfa", null)).toEqual({ kind: "redirect", to: "/connexion" });
  });
  it("sends back after MFA only to a page of the user's own space", () => {
    expect(afterMfa("/client/mandat", client)).toBe("/client/mandat");
    expect(afterMfa("/backoffice/x", client)).toBe("/client");
    expect(afterMfa("//evil.example/x", client)).toBe("/client");
    expect(afterMfa("https://evil.example", staffMfa)).toBe("/backoffice");
    expect(afterMfa(undefined, staffMfa)).toBe("/backoffice");
    expect(afterMfa("/backoffice/clients", staffMfa)).toBe("/backoffice/clients");
  });
  it("routes staff from the client space to the back-office", () => {
    expect(decideAccess("/client", staffMfa)).toEqual({ kind: "redirect", to: "/backoffice" });
  });
  it("does not match lookalike paths", () => {
    expect(decideAccess("/backofficeX", null)).toEqual({ kind: "allow" });
  });
});

describe("homeFor", () => {
  it("lands staff in the back-office and clients in the client space", () => {
    expect(homeFor(staff)).toBe("/backoffice");
    expect(homeFor(client)).toBe("/client");
  });
});
