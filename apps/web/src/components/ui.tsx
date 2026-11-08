import type { ReactNode } from "react";

export function Page({ title, children }: { title: string; children: ReactNode }) {
  return (
    <main className="mx-auto flex min-h-screen w-full max-w-md flex-col gap-6 px-4 py-12">
      <h1 className="text-2xl font-semibold tracking-tight">{title}</h1>
      {children}
    </main>
  );
}

export const inputClass =
  "w-full rounded-md border border-zinc-300 px-3 py-2 text-base outline-none focus:border-zinc-900 dark:border-zinc-700 dark:bg-zinc-900";
export const buttonClass =
  "w-full rounded-md bg-zinc-900 px-4 py-2 font-medium text-white hover:bg-zinc-700 disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900";

export function ErrorNote({ children }: { children: ReactNode }) {
  return (
    <p role="alert" className="rounded-md bg-red-50 px-3 py-2 text-sm text-red-800 dark:bg-red-950 dark:text-red-200">
      {children}
    </p>
  );
}
