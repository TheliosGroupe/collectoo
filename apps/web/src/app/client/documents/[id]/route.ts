import { createClient } from "@/lib/supabase/server";
import { clientDocumentResponse } from "@/lib/remittance/client-document";

/** M2c-2: the client's RIB or signed mandate, for its administrators with access to the whole client (RLS decides). */
export async function GET(_request: Request, context: RouteContext<"/client/documents/[id]">) {
  const { id } = await context.params;
  const supabase = await createClient();
  const { data } = await supabase.auth.getClaims();
  if (!data?.claims?.sub) return new Response("Connexion requise.", { status: 401 });
  return clientDocumentResponse(supabase, id);
}
