import { staffSession } from "@/lib/auth/staff";
import { receiptPdfResponse } from "@/lib/payments/receipt-file";

/** M2b-5: a receipt version's PDF for staff (RLS: admins and ops managers, collectors their portfolios). */
export async function GET(_request: Request, context: RouteContext<"/backoffice/quittances/[id]">) {
  const { id } = await context.params;
  const { supabase } = await staffSession();
  return receiptPdfResponse(supabase, id);
}
