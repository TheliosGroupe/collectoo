import { remittanceDocumentResponse } from "@/lib/remittance/remittance-file";
import { createClient } from "@/lib/supabase/server";

/** M2c-5: a statement (PDF, CSV) or an invoice's PDF for the client's members with access to the whole client (RLS and
 * the storage policy decide; an invoice's PDF only when the client accepted electronic invoices, CGI 289 VI). */
export async function GET(_request: Request, context: RouteContext<"/client/reversements/documents/[id]">) {
  const { id } = await context.params;
  const supabase = await createClient();
  const { data } = await supabase.auth.getClaims();
  if (!data?.claims?.sub) return new Response("Connexion requise.", { status: 401 });
  return remittanceDocumentResponse(supabase, id);
}
