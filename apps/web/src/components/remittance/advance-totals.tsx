"use client";

import { createContext, type ReactNode, useContext, useEffect, useState } from "react";
import { Badge } from "@/components/ui";
import { advanceChip, parseAdvanceTotals } from "@/lib/remittance/advances";
import { createClient } from "@/lib/supabase/browser";

/**
 * M2c-7f-1 (H16, CCS-2): « Avance à récupérer » per client and currency, from public.client_advance_totals (the
 * servicer's 4112[c] balances), read once when the page opens: a client component's state outlives the page's
 * auto-refresh (router.refresh re-renders the server parts only), so the chip is never read again while a job runs.
 */
const Totals = createContext<Record<string, string>>({});

export function AdvanceTotalsProvider({ organizationId, children }: { organizationId: string | null; children: ReactNode }) {
  const [advances, setAdvances] = useState<Record<string, string>>({});
  useEffect(() => {
    if (!organizationId) return;
    let live = true;
    void createClient()
      .rpc("client_advance_totals", { p_organization_id: organizationId })
      .then(({ data }) => {
        const t = parseAdvanceTotals(data);
        if (live && t) setAdvances(t.advances);
      });
    return () => {
      live = false;
    };
  }, [organizationId]);
  return <Totals.Provider value={advances}>{children}</Totals.Provider>;
}

/** The chip of a client's open advances in this currency, or nothing. */
export function AdvanceChip({ clientId, currency, wrap = false }: { clientId: string; currency: string; wrap?: boolean }) {
  const text = advanceChip(useContext(Totals)[`${clientId}:${currency}`], currency);
  if (!text) return null;
  const chip = (
    <Badge tone="action" testId="advance-chip">
      {text}
    </Badge>
  );
  return wrap ? <span>{chip}</span> : chip;
}
