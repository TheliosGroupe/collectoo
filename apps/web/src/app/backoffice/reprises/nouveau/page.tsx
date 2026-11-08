import { WidePage } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import { UploadForm } from "./upload-form";

export default async function NewBatchPage() {
  const { supabase } = await staffSession();
  const { data: portfolios } = await supabase
    .from("portfolio")
    .select("id, name, client:client_organization_id(legal_name)")
    .order("name");
  const options = (portfolios ?? []).map((p) => ({
    id: p.id,
    label: `${p.client?.legal_name ?? "?"} · ${p.name}`,
  }));

  return (
    <WidePage title="Nouveau lot" back={{ href: "/backoffice/reprises", label: "Reprises" }}>
      <UploadForm portfolios={options} />
    </WidePage>
  );
}
