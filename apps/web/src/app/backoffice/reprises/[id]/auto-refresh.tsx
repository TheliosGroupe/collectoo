"use client";

import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { InfoNote } from "@/components/ui";

/**
 * While the worker processes the batch, reload the server data every few seconds. Stops after
 * `maxMs` so a stalled worker does not keep the page polling forever.
 */
export function AutoRefresh({
  active,
  abandonable = true,
  everyMs = 2000,
  maxMs = 15 * 60_000,
}: {
  active: boolean;
  /** Whether staff can still abandon the batch (not while it is being integrated or confirmed). */
  abandonable?: boolean;
  everyMs?: number;
  maxMs?: number;
}) {
  const router = useRouter();
  const [expired, setExpired] = useState(false);
  useEffect(() => {
    if (!active) return;
    const started = Date.now();
    const timer = setInterval(() => {
      if (Date.now() - started > maxMs) {
        clearInterval(timer);
        setExpired(true);
        return;
      }
      router.refresh();
    }, everyMs);
    return () => clearInterval(timer);
  }, [active, everyMs, maxMs, router]);
  return active && expired ? (
    <InfoNote>
      Le traitement prend plus de temps que prévu. Rechargez la page plus tard ; s&apos;il reste bloqué,{" "}
      {abandonable ? "abandonnez le lot." : "contactez le support."}
    </InfoNote>
  ) : null;
}
