import { Page } from "@/components/ui";
import { MfaForm } from "./mfa-form";

export default function MfaPage() {
  return (
    <Page title="Double authentification">
      <MfaForm />
    </Page>
  );
}
