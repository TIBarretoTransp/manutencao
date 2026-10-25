-- CICLO DA OC
-- Operação: a demanda encerra quando tudo foi ENTREGUE (peça chegou / serviço feito). Não espera NF.
-- Financeiro: a OC fecha quando tem NF e, se foi emergencial, cotação posterior para medir a diferença.

alter table public.fornecedores add column if not exists whatsapp text not null default '';
alter table public.ordens
  add column if not exists entregue_em  timestamptz,
  add column if not exists entregue_por uuid references public.profiles(id),
  add column if not exists entrega_foto text,
  add column if not exists fechada_em   timestamptz;
alter table public.cotacoes add column if not exists posterior boolean not null default false;

-- inscrições para aviso no celular (só a função de servidor lê)
create table if not exists public.push_inscricoes (
  endpoint  text primary key,
  user_id   uuid not null references public.profiles(id) on delete cascade,
  chaves    jsonb not null,
  criado_em timestamptz not null default now()
);
alter table public.push_inscricoes enable row level security;
revoke all on public.push_inscricoes from anon, authenticated;

create or replace function public.salvar_push(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu();
begin
  perform public._exigir(coalesce(p->>'endpoint', '') <> '', 'Inscrição inválida.');
  insert into public.push_inscricoes (endpoint, user_id, chaves) values (p->>'endpoint', me.id, p->'keys')
  on conflict (endpoint) do update set user_id = excluded.user_id, chaves = excluded.chaves, criado_em = now();
end $$;

create or replace function public.remover_push(p_endpoint text) returns void
language sql security definer set search_path = public as $$
  delete from public.push_inscricoes where endpoint = p_endpoint and user_id = auth.uid()
$$;

-- quantas cotações de referência a emergencial precisa depois (a própria compra conta como uma)
create or replace function public._cot_posterior_necessarias(p_valor numeric) returns int
language sql stable security definer set search_path = public as $$
  select greatest(1, public._cot_necessarias(p_valor) - 1)
$$;

-- fecha a OC quando tudo está em dia
create or replace function public._fechar_oc(p_ordem uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ordens; v_post int;
begin
  select * into o from public.ordens where id = p_ordem;
  if o.id is null or o.fechada_em is not null then return; end if;
  select count(*) into v_post from public.cotacoes where compra_id = o.compra_id and posterior;
  if o.entregue_em is not null and o.status = 'recebida'
     and (not o.emergencial or v_post >= public._cot_posterior_necessarias(o.valor)) then
    update public.ordens set fechada_em = now() where id = p_ordem;
    perform public._log(o.manutencao_id, format('%s fechada (entrega, NF%s em dia)', o.num, case when o.emergencial then ' e cotação posterior' else '' end));
  end if;
end $$;

-- encerra a demanda sozinha quando não há compra pendente e tudo foi entregue
create or replace function public._encerrar_se_entregue(p_manut uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.manutencoes where id = p_manut and encerrada_em is null and not cancelada)
     and exists (select 1 from public.compras where manutencao_id = p_manut and status = 'aprovada')
     and not exists (
       select 1 from public.compras c left join public.ordens o on o.id = c.oc_id
       where c.manutencao_id = p_manut and (c.status in ('cotacao', 'reprovada', 'aprovacao') or (c.status = 'aprovada' and o.entregue_em is null)))
  then
    update public.manutencoes set encerrada_em = now() where id = p_manut;
    perform public._log(p_manut, 'Manutenção encerrada: tudo entregue');
  end if;
end $$;

create or replace function public.confirmar_entrega(p_ordem uuid, p_foto text default null) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); o public.ordens;
begin
  select * into o from public.ordens where id = p_ordem for update;
  perform public._exigir(o.id is not null and o.status <> 'cancelada', 'OC não encontrada.');
  perform public._exigir(o.entregue_em is null, 'A entrega desta OC já foi confirmada.');
  update public.ordens set entregue_em = now(), entregue_por = me.id, entrega_foto = p_foto where id = p_ordem;
  perform public._log(o.manutencao_id, format('Confirmou a entrega da %s', o.num));
  perform public._fechar_oc(p_ordem);
  perform public._encerrar_se_entregue(o.manutencao_id);
end $$;

create or replace function public.registrar_nf(p_ordem uuid, p_numero text, p_valor numeric, p_foto text) returns text
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); o public.ordens; v_tol numeric; v_st text;
begin
  select * into o from public.ordens where id = p_ordem for update;
  perform public._exigir(o.id is not null and o.nf_em is null and o.status = 'aberta', 'Esta OC já tem NF registrada.');
  perform public._exigir(p_valor > 0, 'Informe o valor da NF.');
  perform public._exigir(coalesce(trim(p_numero), '') <> '' or p_foto is not null, 'Informe o número ou anexe a foto da NF.');
  select tolerancia_nf into v_tol from public.config where id = 1;
  v_st := case when p_valor > o.valor * (1 + v_tol / 100) then 'divergente' else 'recebida' end;
  update public.ordens set nf_numero = trim(p_numero), nf_valor = p_valor, nf_foto = p_foto, nf_por = me.id, nf_em = now(), status = v_st
  where id = p_ordem;
  perform public._log(o.manutencao_id, format('Registrou NF %s de %s na %s%s', coalesce(trim(p_numero), ''), public._brl(p_valor), o.num,
    case when v_st = 'divergente' then ' — acima da tolerância, foi para o gestor' else '' end));
  perform public._fechar_oc(p_ordem);
  return v_st;
end $$;

create or replace function public.aceitar_divergencia(p_ordem uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); o public.ordens;
begin
  perform public._exigir(me.perfil = 'gestor', 'Só o gestor aceita a diferença da NF.');
  update public.ordens set status = 'recebida', divergencia_aceita_por = me.id where id = p_ordem and status = 'divergente' returning * into o;
  if o.id is not null then
    perform public._log(o.manutencao_id, format('Aceitou a diferença da NF na %s', o.num));
    perform public._fechar_oc(p_ordem);
  end if;
end $$;

create or replace function public.add_cotacao_posterior(p_compra uuid, p_fornecedor uuid, p_valor numeric, p_prazo text, p_obs text, p_anexo text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); c public.compras; v uuid; v_pago numeric; v_dif numeric;
begin
  perform public._exigir(me.perfil <> 'motorista', 'Motorista não lança cotação.');
  select * into c from public.compras where id = p_compra;
  perform public._exigir(c.status = 'aprovada' and c.dispensa = 'Compra emergencial', 'Cotação posterior só vale para compra emergencial.');
  perform public._exigir(p_valor > 0, 'Informe o valor.');
  insert into public.cotacoes (compra_id, fornecedor_id, valor, prazo, obs, anexo, por, posterior)
  values (p_compra, p_fornecedor, p_valor, coalesce(p_prazo, ''), coalesce(p_obs, ''), p_anexo, me.id, true) returning id into v;
  select valor into v_pago from public.cotacoes where id = c.escolhida_id;
  v_dif := v_pago - p_valor;
  perform public._log(c.manutencao_id, format('Cotação posterior %s: %s (%s)', (select nome from public.fornecedores where id = p_fornecedor), public._brl(p_valor),
    case when v_dif > 0 then 'pagamos ' || public._brl(v_dif) || ' a mais' when v_dif < 0 then 'pagamos ' || public._brl(-v_dif) || ' a menos' else 'mesmo valor' end));
  perform public._fechar_oc(c.oc_id);
  return v;
end $$;

create or replace function public.encerrar(p_manut uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu();
begin
  perform public._exigir(me.perfil <> 'motorista', 'Sem permissão.');
  perform public._exigir(not exists (
      select 1 from public.compras c left join public.ordens o on o.id = c.oc_id
      where c.manutencao_id = p_manut and (c.status in ('cotacao', 'reprovada', 'aprovacao') or (c.status = 'aprovada' and o.entregue_em is null))),
    'Ainda há compras pendentes ou entregas não confirmadas.');
  update public.manutencoes set encerrada_em = now() where id = p_manut;
  perform public._log(p_manut, 'Encerrou a manutenção');
end $$;

create or replace function public.salvar_fornecedor(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); v uuid := nullif(p->>'id', '')::uuid; cad boolean := me.perfil in ('analista', 'gestor');
begin
  perform public._exigir(coalesce(trim(p->>'nome'), '') <> '', 'Informe o nome do fornecedor.');
  if v is null then
    insert into public.fornecedores (nome, cnpj, cidade, telefone, whatsapp, categoria, provisorio, criado_por)
    values (trim(p->>'nome'), coalesce(p->>'cnpj', ''), coalesce(p->>'cidade', ''), coalesce(p->>'telefone', ''), coalesce(p->>'whatsapp', ''),
            coalesce(nullif(p->>'categoria', ''), 'Peças'), not cad, me.id)
    returning id into v;
  else
    perform public._exigir(cad, 'Só analista ou gestor edita fornecedores.');
    update public.fornecedores set nome = trim(p->>'nome'), cnpj = coalesce(p->>'cnpj', ''), cidade = coalesce(p->>'cidade', ''),
      telefone = coalesce(p->>'telefone', ''), whatsapp = coalesce(p->>'whatsapp', ''),
      categoria = coalesce(nullif(p->>'categoria', ''), 'Peças'), provisorio = false
    where id = v;
  end if;
  return v;
end $$;

revoke execute on function public._cot_posterior_necessarias(numeric), public._fechar_oc(uuid), public._encerrar_se_entregue(uuid) from public, anon, authenticated;
revoke execute on function public.salvar_push(jsonb), public.remover_push(text), public.confirmar_entrega(uuid, text),
  public.add_cotacao_posterior(uuid, uuid, numeric, text, text, text) from public, anon;
grant execute on function public.salvar_push(jsonb), public.remover_push(text), public.confirmar_entrega(uuid, text),
  public.add_cotacao_posterior(uuid, uuid, numeric, text, text, text) to authenticated;

-- chaves do aviso no celular: só o servidor lê (sem acesso pelo app)
create table if not exists public.app_segredos (nome text primary key, valor text not null);
alter table public.app_segredos enable row level security;
revoke all on public.app_segredos from anon, authenticated;
