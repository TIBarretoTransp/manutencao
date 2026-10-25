// Avisa os gestores no celular quando uma compra entra para aprovação.
// Chamada pelo app logo depois de enviar uma compra para aprovação.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const brl = (v: number) => v.toLocaleString("pt-BR", { style: "currency", currency: "BRL" });

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: quem } = await admin.auth.getUser(token);
    if (!quem?.user) return json({ erro: "Sessão expirada." }, 401);

    const { compra_id } = await req.json();
    const { data: c } = await admin.from("compras").select("id, status, descricao, escolhida_id, manutencao_id, solicitada_por").eq("id", compra_id).single();
    if (!c || c.status !== "aprovacao") return json({ ok: true, enviados: 0 });
    const [{ data: q }, { data: m }, { data: quemPediu }] = await Promise.all([
      admin.from("cotacoes").select("valor").eq("id", c.escolhida_id).single(),
      admin.from("manutencoes").select("num, placa, destino").eq("id", c.manutencao_id).single(),
      admin.from("profiles").select("nome").eq("id", c.solicitada_por ?? quem.user.id).single(),
    ]);

    const { data: segredos } = await admin.from("app_segredos").select("nome, valor").in("nome", ["vapid_publica", "vapid_privada", "vapid_contato"]);
    const s = Object.fromEntries((segredos ?? []).map((r: { nome: string; valor: string }) => [r.nome, r.valor]));
    webpush.setVapidDetails(s.vapid_contato || "mailto:contato@barretotransportes.com", s.vapid_publica, s.vapid_privada);

    const { data: gestores } = await admin.from("profiles").select("id").eq("perfil", "gestor").eq("ativo", true);
    const ids = (gestores ?? []).map((g: { id: string }) => g.id).filter((id: string) => id !== quem.user!.id);
    if (!ids.length) return json({ ok: true, enviados: 0 });
    const { data: subs } = await admin.from("push_inscricoes").select("endpoint, chaves").in("user_id", ids);

    const alvo = m?.destino === "estoque" ? "Estoque" : (m?.placa ?? "");
    const payload = JSON.stringify({
      title: `Aprovar ${brl(Number(q?.valor ?? 0))} · ${alvo}`,
      body: `${m?.num ?? ""} · ${c.descricao}${quemPediu?.nome ? " — " + quemPediu.nome : ""}`,
      tag: `aprovar-${c.id}`,
      url: "./#aprovar",
    });
    let enviados = 0;
    for (const sub of subs ?? []) {
      try {
        await webpush.sendNotification({ endpoint: sub.endpoint, keys: sub.chaves }, payload, { TTL: 60 * 60 * 24 });
        enviados++;
      } catch (e) {
        const code = (e as { statusCode?: number }).statusCode;
        if (code === 404 || code === 410) await admin.from("push_inscricoes").delete().eq("endpoint", sub.endpoint);
      }
    }
    return json({ ok: true, enviados });
  } catch (e) {
    return json({ erro: String((e as Error)?.message ?? e) }, 500);
  }
});
