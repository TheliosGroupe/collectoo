import Link from "next/link";
import type { ReactNode } from "react";

export function Page({ title, children }: { title: string; children: ReactNode }) {
  return (
    <main className="mx-auto flex min-h-screen w-full max-w-md flex-col gap-6 px-4 py-12">
      <h1 className="text-2xl font-semibold tracking-tight">{title}</h1>
      {children}
    </main>
  );
}

/** Back-office pages: full width on desktop, single column on a phone. */
export function WidePage({
  title,
  back,
  actions,
  children,
}: {
  title: string;
  back?: { href: string; label: string };
  actions?: ReactNode;
  children: ReactNode;
}) {
  return (
    <main className="mx-auto flex min-h-screen w-full max-w-5xl flex-col gap-6 px-4 py-8 sm:py-12">
      {back ? (
        <Link href={back.href} className="text-sm text-zinc-600 underline-offset-4 hover:underline dark:text-zinc-400">
          ← {back.label}
        </Link>
      ) : null}
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-2xl font-semibold tracking-tight">{title}</h1>
        {actions}
      </div>
      {children}
    </main>
  );
}

export function Section({ title, children, testId, id }: { title: string; children: ReactNode; testId?: string; id?: string }) {
  return (
    <section id={id} className="scroll-mt-4 rounded-lg border border-zinc-200 p-4 dark:border-zinc-800" data-testid={testId}>
      <h2 className="mb-3 font-medium">{title}</h2>
      {children}
    </section>
  );
}

const TONES = {
  neutral: "bg-zinc-100 text-zinc-800 dark:bg-zinc-800 dark:text-zinc-200",
  busy: "bg-sky-100 text-sky-900 dark:bg-sky-950 dark:text-sky-200",
  action: "bg-amber-100 text-amber-900 dark:bg-amber-950 dark:text-amber-200",
  ok: "bg-emerald-100 text-emerald-900 dark:bg-emerald-950 dark:text-emerald-200",
  error: "bg-red-100 text-red-900 dark:bg-red-950 dark:text-red-200",
} as const;

export function Badge({ tone, children, testId }: { tone: keyof typeof TONES; children: ReactNode; testId?: string }) {
  return (
    <span className={`inline-block rounded-full px-2.5 py-0.5 text-xs font-medium ${TONES[tone]}`} data-testid={testId}>
      {children}
    </span>
  );
}

/** Label / value pairs, two columns on a phone. */
export function Stats({ items }: { items: { label: string; value: ReactNode; testId?: string }[] }) {
  return (
    <dl className="grid grid-cols-2 gap-3 sm:grid-cols-4">
      {items.map((i) => (
        <div key={i.label} className="rounded-md bg-zinc-50 p-3 dark:bg-zinc-900">
          <dt className="text-xs text-zinc-600 dark:text-zinc-400">{i.label}</dt>
          <dd className="mt-1 font-medium tabular-nums" data-testid={i.testId}>
            {i.value}
          </dd>
        </div>
      ))}
    </dl>
  );
}

export const inputClass =
  "w-full rounded-md border border-zinc-300 px-3 py-2 text-base outline-none focus:border-zinc-900 dark:border-zinc-700 dark:bg-zinc-900";
export const buttonClass =
  "w-full rounded-md bg-zinc-900 px-4 py-2 font-medium text-white hover:bg-zinc-700 disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900";
export const inlineButtonClass =
  "rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-700 disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900";
export const dangerButtonClass =
  "rounded-md border border-red-300 px-4 py-2 text-sm font-medium text-red-800 hover:bg-red-50 dark:border-red-800 dark:text-red-200 dark:hover:bg-red-950";

export function ErrorNote({ children }: { children: ReactNode }) {
  return (
    <p role="alert" className="rounded-md bg-red-50 px-3 py-2 text-sm text-red-800 dark:bg-red-950 dark:text-red-200">
      {children}
    </p>
  );
}

export function InfoNote({ children }: { children: ReactNode }) {
  return (
    <p className="rounded-md bg-sky-50 px-3 py-2 text-sm text-sky-900 dark:bg-sky-950 dark:text-sky-200">{children}</p>
  );
}
