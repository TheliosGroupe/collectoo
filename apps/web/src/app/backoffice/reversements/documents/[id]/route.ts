import { staffSession } from "@/lib/auth/staff";
import { remittanceDocumentResponse } from "@/lib/remittance/remittance-file";

/** M2c-5: a statement's PDF or CSV, or an invoice's PDF, for money staff (RLS and the storage policy decide). */
export async function GET(_request: Request, context: RouteContext<"/backoffice/reversements/documents/[id]">) {
  const { id } = await context.params;
  const { supabase } = await staffSession();
  return remittanceDocumentResponse(supabase, id);
}
