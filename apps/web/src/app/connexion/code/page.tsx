import { ErrorNote, Page, buttonClass, inputClass } from "@/components/ui";
import { verifyCode } from "../actions";

export default async function CodePage({ searchParams }: PageProps<"/connexion/code">) {
  const { email, erreur } = await searchParams;
  const address = typeof email === "string" ? email : "";
  return (
    <Page title="Vérification">
      <p className="text-zinc-600 dark:text-zinc-400">
        Si un compte existe pour <strong>{address}</strong>, un code vient d&apos;être envoyé.
      </p>
      {erreur ? <ErrorNote>Code incorrect ou expiré.</ErrorNote> : null}
      <form action={verifyCode} className="flex flex-col gap-4">
        <input type="hidden" name="email" value={address} />
        <label className="flex flex-col gap-1 text-sm font-medium">
          Code reçu par e-mail
          <input
            name="code"
            inputMode="numeric"
            autoComplete="one-time-code"
            pattern="[0-9 ]{6,8}"
            required
            className={inputClass}
          />
        </label>
        <button type="submit" className={buttonClass}>
          Se connecter
        </button>
      </form>
    </Page>
  );
}
