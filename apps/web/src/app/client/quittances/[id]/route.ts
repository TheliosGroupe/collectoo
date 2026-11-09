import { receiptPdfResponse } from "@/lib/payments/receipt-file";
import { createClient } from "@/lib/supabase/server";

/** M2b-5: a receipt version's PDF for the client (RLS: its own portfolios only; design §6). */
export async function GET(_request: Request, context: RouteContext<"/client/quittances/[id]">) {
  const { id } = await context.params;
  const supabase = await createClient();
  const { data } = await supabase.auth.getClaims();
  if (!data?.claims?.sub) return new Response("Connexion requise.", { status: 401 });
  return receiptPdfResponse(supabase, id);
}
