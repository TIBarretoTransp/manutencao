// Avisos no celular (web push).
//   evento "aprovacao"  → gestores e analistas: uma compra entrou para aprovação (cotada ou sem cotação)
//   evento "sem_cotacao" → gestores e analistas: alguém comprou sem cotação dentro da própria alçada
//   evento "decisao"    → quem pediu: a compra foi aprovada ou reprovada
// Chamada pelo app logo depois da ação.
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
    const eu = quem.user.id;

    const body = await req.json();
    const evento: string = body.evento ?? "aprovacao";
    const { data: c } = await admin.from("compras")
      .select("id, status, descricao, escolhida_id, manutencao_id, destino, placa, sem_cotacao, solicitada_por, oc_id, motivo_reprova")
      .eq("id", body.compra_id).single();
    if (!c) return json({ ok: true, enviados: 0 });

    const [{ data: q }, { data: m }, { data: pessoa }, { data: o }] = await Promise.all([
      admin.from("cotacoes").select("valor").eq("id", c.escolhida_id).single(),
      c.manutencao_id ? admin.from("manutencoes").select("id, num").eq("id", c.manutencao_id).single() : Promise.resolve({ data: null }),
      admin.from("profiles").select("nome").eq("id", eu).single(),
      c.oc_id ? admin.from("ordens").select("id, num").eq("id", c.oc_id).single() : Promise.resolve({ data: null }),
    ]);
    const alvo = c.destino === "estoque" ? "Estoque" : (c.placa ?? "");
    const valor = brl(Number(q?.valor ?? 0));
    const ref = m?.num ? `${m.num} · ` : "";

    let ids: string[] = [];
    let payload: Record<string, string> | null = null;
    if (evento === "aprovacao" && c.status === "aprovacao") {
      const { data: ps } = await admin.from("profiles").select("id").in("perfil", ["gestor", "analista"]).eq("ativo", true);
      ids = (ps ?? []).map((p: { id: string }) => p.id);
      payload = {
        title: `${c.sem_cotacao ? "Autorizar sem cotação" : "Aprovar"} ${valor} · ${alvo}`,
        body: `${ref}${c.descricao}${pessoa?.nome ? " — " + pessoa.nome : ""}`,
        tag: `aprovar-${c.id}`, url: "./#aprovar",
      };
    } else if (evento === "sem_cotacao" && c.status === "aprovada") {
      const { data: ps } = await admin.from("profiles").select("id").in("perfil", ["gestor", "analista"]).eq("ativo", true);
      ids = (ps ?? []).map((p: { id: string }) => p.id);
      payload = {
        title: `Compra sem cotação ${valor} · ${alvo}`,
        body: `${o?.num ?? ""} · ${ref}${c.descricao}${pessoa?.nome ? " — " + pessoa.nome : ""}`,
        tag: `semcot-${c.id}`, url: o ? `./#oc=${o.id}` : "./",
      };
    } else if (evento === "decisao" && c.solicitada_por && ["aprovada", "reprovada"].includes(c.status)) {
      ids = [c.solicitada_por];
      const aprovada = c.status === "aprovada";
      payload = {
        title: aprovada ? `${o?.num ?? "OC"} aprovada · ${valor}` : `Compra reprovada · ${alvo}`,
        body: aprovada ? `${ref}${c.descricao}. Informe o número ao fornecedor.` : `${ref}${c.descricao}. Motivo: ${c.motivo_reprova ?? ""}`,
        tag: `decisao-${c.id}`, url: aprovada && o ? `./#oc=${o.id}` : (m ? `./#os=${m.id}` : `./#compra=${c.id}`),
      };
    }
    ids = ids.filter((id) => id !== eu);
    if (!payload || !ids.length) return json({ ok: true, enviados: 0 });

    const { data: segredos } = await admin.from("app_segredos").select("nome, valor").in("nome", ["vapid_publica", "vapid_privada", "vapid_contato"]);
    const s = Object.fromEntries((segredos ?? []).map((r: { nome: string; valor: string }) => [r.nome, r.valor]));
    webpush.setVapidDetails(s.vapid_contato || "mailto:contato@barretotransportes.com", s.vapid_publica, s.vapid_privada);
    const { data: subs } = await admin.from("push_inscricoes").select("endpoint, chaves").in("user_id", ids);

    let enviados = 0;
    for (const sub of subs ?? []) {
      try {
        await webpush.sendNotification({ endpoint: sub.endpoint, keys: sub.chaves }, JSON.stringify(payload), { TTL: 60 * 60 * 24 });
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
