import { staffSession } from "@/lib/auth/staff";
import { clientDocumentResponse } from "@/lib/remittance/client-document";

/** M2c-2: a client document (RIB, signed mandate, evidence) for money staff (RLS and the storage policy decide). */
export async function GET(_request: Request, context: RouteContext<"/backoffice/documents/[id]">) {
  const { id } = await context.params;
  const { supabase } = await staffSession();
  return clientDocumentResponse(supabase, id);
}
