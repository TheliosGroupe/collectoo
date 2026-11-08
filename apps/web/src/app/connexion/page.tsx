import { ErrorNote, Page, buttonClass, inputClass } from "@/components/ui";
import { requestCode } from "./actions";

export default async function LoginPage({ searchParams }: PageProps<"/connexion">) {
  const { erreur } = await searchParams;
  return (
    <Page title="Connexion">
      <p className="text-zinc-600 dark:text-zinc-400">
        Saisissez votre adresse e-mail. Nous vous enverrons un code à usage unique.
      </p>
      {erreur ? <ErrorNote>Adresse e-mail invalide.</ErrorNote> : null}
      <form action={requestCode} className="flex flex-col gap-4">
        <label className="flex flex-col gap-1 text-sm font-medium">
          Adresse e-mail
          <input name="email" type="email" autoComplete="email" required className={inputClass} />
        </label>
        <button type="submit" className={buttonClass}>
          Recevoir un code
        </button>
      </form>
    </Page>
  );
}
