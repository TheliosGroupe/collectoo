import Link from "next/link";

const surfaces = [
  { href: "/debiteur", label: "Espace débiteur", text: "Consulter et régler votre dossier." },
  { href: "/client", label: "Espace client", text: "Suivre vos créances confiées." },
  { href: "/backoffice", label: "Back-office", text: "Réservé aux équipes Collectoo." },
];

export default function Home() {
  return (
    <main className="mx-auto flex min-h-screen w-full max-w-3xl flex-col gap-8 px-4 py-16">
      <h1 className="text-3xl font-semibold tracking-tight">Collectoo</h1>
      <p className="text-zinc-600 dark:text-zinc-400">Plateforme de recouvrement amiable.</p>
      <ul className="grid gap-4 sm:grid-cols-3">
        {surfaces.map((s) => (
          <li key={s.href} className="rounded-lg border border-zinc-200 p-4 dark:border-zinc-800">
            <Link href={s.href} className="font-medium underline-offset-4 hover:underline">
              {s.label}
            </Link>
            <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">{s.text}</p>
          </li>
        ))}
      </ul>
    </main>
  );
}
