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
export function ActionForm<R extends ActionResult = ActionResult>({
  action,
  onDone,
  submitLabel,
  pendingLabel = "Patientez…",
  buttonClassName,
  className,
  resetOnSuccess = false,
  id,
  testId,
  children,
}: {
  action: (formData: FormData) => Promise<R>;
  /** Called with the action's result when it succeeded (before the page refreshes). */
  onDone?: (result: Extract<R, { ok: true }>) => void;
  submitLabel: string;
  pendingLabel?: string;
  buttonClassName: string;
  className?: string;
  /** Empty the fields once the action succeeded (a form that adds a row). */
  resetOnSuccess?: boolean;
  /** Fields elsewhere on the page join this form with `form={id}` (bulk selection). */
  id?: string;
  testId?: string;
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
        onDone?.(result as Extract<R, { ok: true }>);
        router.refresh();
      }
    });
  }

  return (
    <form onSubmit={onSubmit} className={className} id={id} data-testid={testId}>
      {children}
      {error ? <ErrorNote>{error}</ErrorNote> : null}
      <button type="submit" disabled={pending} aria-busy={pending} className={buttonClassName}>
        {pending ? pendingLabel : submitLabel}
      </button>
    </form>
  );
}
