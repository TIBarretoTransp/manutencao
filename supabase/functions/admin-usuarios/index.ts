// Função segura para o gestor criar usuários e redefinir senhas pelo app.
// Roda no Supabase com a chave de serviço, que nunca vai para o navegador.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

// Domínio interno: o login por celular vira <ddd+numero>@tel.barretomanutencao.app
const DOMINIO = "tel.barretomanutencao.app";
const PERFIS = ["motorista", "mecanico", "analista", "financeiro", "gestor"];

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

function normTel(v: unknown): string | null {
  let d = String(v ?? "").replace(/\D/g, "");
  if (d.startsWith("55") && (d.length === 12 || d.length === 13)) d = d.slice(2);
  return d.length === 10 || d.length === 11 ? d : null;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    // quem está pedindo precisa ser gestor ativo
    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: quem, error: eu } = await admin.auth.getUser(token);
    if (eu || !quem?.user) return json({ erro: "Sua sessão expirou. Entre de novo no app." }, 401);
    const { data: me } = await admin.from("profiles").select("perfil, ativo").eq("id", quem.user.id).single();
    if (!me || me.perfil !== "gestor" || !me.ativo) return json({ erro: "Só o gestor pode gerenciar usuários." }, 403);

    const b = await req.json();

    if (b.acao === "criar") {
      const nome = String(b.nome ?? "").trim();
      const tel = normTel(b.telefone);
      const senha = String(b.senha ?? "");
      const perfil = PERFIS.includes(b.perfil) ? b.perfil : "motorista";
      if (!nome) return json({ erro: "Informe o nome." }, 400);
      if (!tel) return json({ erro: "Celular inválido. Use DDD + número, por exemplo 15 99999-0000." }, 400);
      if (senha.length < 6) return json({ erro: "A senha provisória precisa ter pelo menos 6 caracteres." }, 400);

      const { data, error } = await admin.auth.admin.createUser({
        email: `${tel}@${DOMINIO}`,
        password: senha,
        email_confirm: true,
        user_metadata: { nome, telefone: tel },
      });
      if (error) {
        const dup = /already|registered|exists/i.test(error.message);
        return json({ erro: dup ? "Já existe um usuário com esse celular." : error.message }, 400);
      }
      const { error: pe } = await admin.from("profiles")
        .update({ nome, telefone: tel, perfil, placa: String(b.placa ?? "") })
        .eq("id", data.user!.id);
      if (pe) return json({ erro: pe.message }, 500);
      return json({ ok: true, id: data.user!.id });
    }

    if (b.acao === "senha") {
      const senha = String(b.senha ?? "");
      if (!b.id) return json({ erro: "Usuário não informado." }, 400);
      if (senha.length < 6) return json({ erro: "A senha precisa ter pelo menos 6 caracteres." }, 400);
      const { error } = await admin.auth.admin.updateUserById(String(b.id), { password: senha });
      if (error) return json({ erro: error.message }, 400);
      return json({ ok: true });
    }

    return json({ erro: "Ação inválida." }, 400);
  } catch (e) {
    return json({ erro: String((e as Error)?.message ?? e) }, 500);
  }
});
