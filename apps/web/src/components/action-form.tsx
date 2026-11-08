"use client";

import { useRouter } from "next/navigation";
import { type FormEvent, type ReactNode, useState, useTransition } from "react";
import { ErrorNote } from "@/components/ui";
import { type ActionResult, errorText } from "@/lib/boarding/forms";

/**
 * Form calling a server action without a page reload: the fields keep their values when the
 * action fails (React's automatic form reset is avoided), the button shows the pending state
 * (no double submission) and the error is shown inline from a fixed list of messages.
 */
export function ActionForm({
  action,
  submitLabel,
  pendingLabel = "Patientez…",
  buttonClassName,
  className,
  resetOnSuccess = false,
  children,
}: {
  action: (formData: FormData) => Promise<ActionResult>;
  submitLabel: string;
  pendingLabel?: string;
  buttonClassName: string;
  className?: string;
  /** Empty the fields once the action succeeded (a form that adds a row). */
  resetOnSuccess?: boolean;
  children?: ReactNode;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);

  function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (pending) return;
    const form = event.currentTarget;
    const formData = new FormData(form);
    setError(null);
    startTransition(async () => {
      const result = await action(formData);
      if ("error" in result) setError(errorText(result.error));
      else {
        if (resetOnSuccess) form.reset();
        router.refresh();
      }
    });
  }

  return (
    <form onSubmit={onSubmit} className={className}>
      {children}
      {error ? <ErrorNote>{error}</ErrorNote> : null}
      <button type="submit" disabled={pending} aria-busy={pending} className={buttonClassName}>
        {pending ? pendingLabel : submitLabel}
      </button>
    </form>
  );
}
