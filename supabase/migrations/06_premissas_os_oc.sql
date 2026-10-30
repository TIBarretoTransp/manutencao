-- =====================================================================
-- 06 · PREMISSAS FECHADAS (OS e OC separadas)
-- OS = demanda de manutenção de uma placa, com etapas:
--   aberta → triagem (gestor) → realizacao → aguardando_fechamento → fechada
-- OC = compra de insumo ou serviço. Nasce dentro de uma OS (herda a placa)
--   ou fora dela (vai para o estoque). O número sai na aprovação: C260001.
-- Sem compra emergencial: quando não dá para cotar, pede-se autorização
--   para comprar sem cotação, sempre dentro da alçada.
-- Sem NF no app: o financeiro confere a NF pelo número da OC em outro sistema.
-- =====================================================================

-- ---------- limpeza do modelo anterior ----------
drop function if exists public.criar_demanda(text, text, text, text, text[], jsonb);
drop function if exists public.abrir_demanda(text, text, text, text, text, text[], jsonb);
drop function if exists public.compra_emergencial(uuid, text, text, uuid, numeric, text, text);
drop function if exists public.registrar_nf(uuid, text, numeric, text);
drop function if exists public.aceitar_divergencia(uuid);
drop function if exists public.revisar_emergencial(uuid);
drop function if exists public.encerrar(uuid);
drop function if exists public.reabrir(uuid);
drop function if exists public.cancelar_manut(uuid, text);
drop function if exists public._encerrar_se_entregue(uuid);
drop function if exists public._cot_posterior_necessarias(numeric);
drop function if exists public._gerar_oc(uuid, boolean);
drop function if exists public._validar_compra(uuid, text, text, text);
drop function if exists public.enviar_aprovacao(uuid, text, text);
drop function if exists public.aprovar(uuid, text, text);
drop function if exists public.nova_compra(uuid, text, text);
drop function if exists public.cancelar_compra(uuid);

-- ---------- perfis: entra o financeiro ----------
alter table public.profiles drop constraint if exists profiles_perfil_check;
alter table public.profiles add constraint profiles_perfil_check
  check (perfil in ('motorista', 'mecanico', 'analista', 'financeiro', 'gestor'));

-- ---------- regras ----------
alter table public.config add column if not exists cot_min_valor numeric(12,2) not null default 200;
alter table public.config add column if not exists cot_qtd int not null default 3;
update public.config set alcada_motorista = 200, alcada_mecanico = 400, alcada_analista = 1000, cot_min_valor = 200, cot_qtd = 3 where id = 1;

-- ---------- numeração: S (serviço) e C (compra), por ano ----------
create table if not exists public.seq_doc (
  tipo   text not null check (tipo in ('S', 'C')),
  ano    int  not null,
  ultimo int  not null default 0,
  primary key (tipo, ano)
);
insert into public.seq_doc (tipo, ano, ultimo)
select 'C', ano, ultimo from public.oc_seq on conflict do nothing;

-- ---------- OS (tabela manutencoes) ----------
alter table public.manutencoes
  add column if not exists etapa text not null default 'aberta',
  add column if not exists km int,
  add column if not exists plano text not null default '',
  add column if not exists triagem_por uuid references public.profiles(id),
  add column if not exists concluida_por uuid references public.profiles(id),
  add column if not exists concluida_em timestamptz,
  add column if not exists fechada_por uuid references public.profiles(id);
alter table public.manutencoes drop constraint if exists manut_etapa_ck;
alter table public.manutencoes add constraint manut_etapa_ck
  check (etapa in ('aberta', 'triagem', 'realizacao', 'aguardando_fechamento', 'fechada', 'cancelada'));
update public.manutencoes set etapa = case when cancelada then 'cancelada' when encerrada_em is not null then 'fechada' else 'aberta' end;

-- renumera as OS de teste que já existiam (M-0001 → S260001)
do $$
declare r record; v_n int := 0; v_ano int := extract(year from (now() at time zone 'America/Sao_Paulo'))::int;
begin
  for r in select id from public.manutencoes where num not like 'S%' order by aberto_em loop
    v_n := v_n + 1;
    update public.manutencoes set num = 'S' || lpad((v_ano % 100)::text, 2, '0') || lpad(v_n::text, 4, '0') where id = r.id;
  end loop;
  if v_n > 0 then
    insert into public.seq_doc (tipo, ano, ultimo) values ('S', v_ano, v_n)
    on conflict (tipo, ano) do update set ultimo = greatest(public.seq_doc.ultimo, excluded.ultimo);
  end if;
end $$;

-- ---------- OC em cotação (tabela compras) ----------
alter table public.compras alter column manutencao_id drop not null;
alter table public.compras
  add column if not exists destino text not null default 'tracao',
  add column if not exists placa text,
  add column if not exists sem_cotacao boolean not null default false,
  add column if not exists whatsapp text not null default '',
  add column if not exists criado_por uuid references public.profiles(id),
  add column if not exists cancelada_motivo text;
update public.compras c set destino = m.destino, placa = m.placa from public.manutencoes m where m.id = c.manutencao_id;
alter table public.compras drop constraint if exists compras_destino_ck;
alter table public.compras add constraint compras_destino_ck check (
  (manutencao_id is null and destino = 'estoque' and placa is null) or
  (manutencao_id is not null and destino in ('tracao', 'carreta') and placa is not null));
create index if not exists compras_status_idx on public.compras (status);

-- ---------- OC aprovada (tabela ordens) ----------
alter table public.ordens alter column manutencao_id drop not null;
alter table public.ordens
  add column if not exists sem_cotacao boolean not null default false,
  add column if not exists whatsapp text not null default '',
  add column if not exists cancelada_por uuid references public.profiles(id),
  add column if not exists cancelada_em timestamptz,
  add column if not exists cancelada_motivo text;

-- ---------- histórico: da OS ou da OC de estoque ----------
alter table public.historico alter column manutencao_id drop not null;
alter table public.historico add column if not exists compra_id uuid references public.compras(id) on delete cascade;
create index if not exists historico_compra_idx on public.historico (compra_id);

-- =====================================================================
-- FUNÇÕES DE APOIO
-- =====================================================================
create or replace function public._num(p_tipo text) returns text
language plpgsql security definer set search_path = public as $$
declare v_ano int := extract(year from (now() at time zone 'America/Sao_Paulo'))::int; v_n int;
begin
  insert into public.seq_doc (tipo, ano, ultimo) values (p_tipo, v_ano, 1)
  on conflict (tipo, ano) do update set ultimo = public.seq_doc.ultimo + 1
  returning ultimo into v_n;
  return p_tipo || lpad((v_ano % 100)::text, 2, '0') || lpad(v_n::text, 4, '0');
end $$;

create or replace function public._alcada(p_perfil text) returns numeric
language sql stable security definer set search_path = public as $$
  select case p_perfil when 'gestor' then null
                       when 'analista' then alcada_analista
                       when 'mecanico' then alcada_mecanico
                       when 'motorista' then alcada_motorista
                       else 0 end
  from public.config where id = 1
$$;

create or replace function public._alcada_de(p_id uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select case when p.perfil = 'gestor' then null
              when p.perfil = 'financeiro' then 0
              when p.alcada is not null then p.alcada
              else public._alcada(p.perfil) end
  from public.profiles p where p.id = p_id
$$;

-- quantas cotações a compra precisa: abaixo do valor mínimo, 1; acima, 3
create or replace function public._cot_necessarias(p_valor numeric) returns int
language sql stable security definer set search_path = public as $$
  select case when p_valor < cot_min_valor then 1 else cot_qtd end from public.config where id = 1
$$;

-- histórico vai para a OS; OC de estoque tem o próprio histórico
create or replace function public._log_c(p_compra uuid, p_txt text) returns void
language sql security definer set search_path = public as $$
  insert into public.historico (manutencao_id, compra_id, por, txt)
  select c.manutencao_id, case when c.manutencao_id is null then c.id end, auth.uid(), p_txt
  from public.compras c where c.id = p_compra
$$;

-- quem pode cotar esta compra: na OS, mecânico, analista e gestor; no estoque, só analista e gestor
create or replace function public._pode_cotar(p_perfil text, p_compra uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select case when c.manutencao_id is null then p_perfil in ('analista', 'gestor')
              else p_perfil in ('mecanico', 'analista', 'gestor') end
  from public.compras c where c.id = p_compra
$$;

create or replace function public._os_ativa(p_os uuid) returns public.manutencoes
language plpgsql stable security definer set search_path = public as $$
declare m public.manutencoes;
begin
  select * into m from public.manutencoes where id = p_os;
  perform public._exigir(m.id is not null, 'OS não encontrada.');
  perform public._exigir(m.etapa in ('aberta', 'triagem', 'realizacao'),
    case m.etapa when 'aguardando_fechamento' then 'A OS está aguardando fechamento. Devolva para realização antes de comprar.'
                 else 'Esta OS está fechada ou cancelada.' end);
  return m;
end $$;

-- gera o número da OC a partir da cotação escolhida
create or replace function public._gerar_oc(p_compra uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare c public.compras; q public.cotacoes; v_id uuid; v_wa text;
begin
  select * into c from public.compras where id = p_compra;
  select * into q from public.cotacoes where id = c.escolhida_id;
  perform public._exigir(q.id is not null, 'Escolha uma cotação.');
  v_wa := coalesce(nullif(regexp_replace(c.whatsapp, '\D', '', 'g'), ''),
                   regexp_replace(coalesce((select whatsapp from public.fornecedores where id = q.fornecedor_id), ''), '\D', '', 'g'));
  insert into public.ordens (num, manutencao_id, compra_id, destino, placa, fornecedor_id, valor, tipo, sem_cotacao, whatsapp, aprovado_por)
  values (public._num('C'), c.manutencao_id, c.id, c.destino, c.placa, q.fornecedor_id, q.valor, c.tipo, c.sem_cotacao, v_wa, auth.uid())
  returning id into v_id;
  update public.compras set status = 'aprovada', oc_id = v_id where id = c.id;
  return v_id;
end $$;

-- confere a regra de cotações e a justificativa antes de aprovar ou enviar
create or replace function public._validar_compra(p_compra uuid, p_just text) returns void
language plpgsql security definer set search_path = public as $$
declare c public.compras; q public.cotacoes; v_n int; v_menor numeric; v_nec int;
begin
  select * into c from public.compras where id = p_compra;
  select * into q from public.cotacoes where id = c.escolhida_id;
  perform public._exigir(q.id is not null, 'Escolha uma cotação.');
  if c.sem_cotacao then return; end if;
  select count(*), min(valor) into v_n, v_menor from public.cotacoes where compra_id = p_compra and not posterior;
  v_nec := public._cot_necessarias(q.valor);
  perform public._exigir(v_n >= v_nec,
    format('Para %s a regra pede %s cotações. Lance as que faltam ou, se não der para cotar, peça autorização para comprar sem cotação na OS.', public._brl(q.valor), v_nec));
  if q.valor > v_menor then
    perform public._exigir(coalesce(trim(p_just), '') <> '', 'A cotação escolhida não é a menor. Informe a justificativa.');
  end if;
end $$;

-- a OC fecha quando foi entregue e, se comprada sem cotação (acima do mínimo), tem a cotação posterior
create or replace function public._fechar_oc(p_ordem uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ordens; v_post int; v_min numeric;
begin
  select * into o from public.ordens where id = p_ordem;
  if o.id is null or o.fechada_em is not null or o.status = 'cancelada' or o.entregue_em is null then return; end if;
  select cot_min_valor into v_min from public.config where id = 1;
  select count(*) into v_post from public.cotacoes where compra_id = o.compra_id and posterior;
  if not o.sem_cotacao or o.valor < v_min or v_post >= 1 then
    update public.ordens set fechada_em = now() where id = p_ordem;
    perform public._log_c(o.compra_id, format('%s fechada', o.num));
  end if;
end $$;

-- =====================================================================
-- OS
-- =====================================================================
create or replace function public.abrir_os(p_destino text, p_placa text, p_descricao text, p_prioridade text, p_fotos text[], p_km int default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); v uuid; v_n int;
begin
  perform public._exigir(p_destino in ('tracao', 'carreta'), 'A OS é sempre de uma placa: escolha tração ou carreta.');
  perform public._exigir(coalesce(trim(p_placa), '') <> '', 'Escolha a placa.');
  perform public._exigir(coalesce(trim(p_descricao), '') <> '', 'Descreva o que está acontecendo.');
  perform public._exigir(p_prioridade in ('urgente', 'programada'), 'Escolha urgente ou programada.');
  perform public._exigir(p_km is null or p_km >= 0, 'Quilometragem inválida.');
  perform public._exigir(exists (select 1 from public.veiculos where placa = upper(p_placa) and tipo = p_destino and ativo),
    format('A placa %s não está cadastrada como %s.', upper(p_placa), case p_destino when 'tracao' then 'tração' else 'carreta' end));
  insert into public.manutencoes (num, destino, placa, descricao, tipo, prioridade, prioridade_confirmada, aberto_por, atendido_por, fotos, km, etapa)
  values (public._num('S'), p_destino, upper(p_placa), trim(p_descricao), 'peca', p_prioridade, me.perfil = 'gestor', me.id,
          case when me.perfil = 'mecanico' then me.id end, coalesce(p_fotos, '{}'), p_km, 'aberta')
  returning id into v;
  v_n := coalesce(array_length(p_fotos, 1), 0);
  perform public._log(v, case when v_n > 0 then format('Abriu a OS com %s foto(s)', v_n) else 'Abriu a OS' end);
  return v;
end $$;

create or replace function public.iniciar_triagem(p_os uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); m public.manutencoes;
begin
  perform public._exigir(me.perfil = 'gestor', 'Só o gestor faz a triagem.');
  select * into m from public.manutencoes where id = p_os for update;
  perform public._exigir(m.etapa = 'aberta', 'Esta OS não está aguardando triagem.');
  update public.manutencoes set etapa = 'triagem', triagem_por = me.id where id = p_os;
  perform public._log(p_os, 'Iniciou a triagem');
end $$;

create or replace function public.concluir_triagem(p_os uuid, p_plano text, p_prioridade text) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); m public.manutencoes;
begin
  perform public._exigir(me.perfil = 'gestor', 'Só o gestor faz a triagem.');
  perform public._exigir(coalesce(trim(p_plano), '') <> '', 'Diga o que será feito e o que é preciso (estoque, compra ou serviço).');
  perform public._exigir(p_prioridade in ('urgente', 'programada'), 'Escolha urgente ou programada.');
  select * into m from public.manutencoes where id = p_os for update;
  perform public._exigir(m.etapa in ('aberta', 'triagem'), 'Esta OS já passou da triagem.');
  update public.manutencoes set etapa = 'realizacao', plano = trim(p_plano), prioridade = p_prioridade, prioridade_confirmada = true,
    triagem_por = me.id where id = p_os;
  perform public._log(p_os, format('Concluiu a triagem (%s): %s', p_prioridade, trim(p_plano)));
end $$;

create or replace function public.concluir_servico(p_os uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); m public.manutencoes;
begin
  perform public._exigir(me.perfil in ('mecanico', 'analista', 'gestor'), 'Só mecânico, analista ou gestor dá o ok do serviço.');
  select * into m from public.manutencoes where id = p_os for update;
  perform public._exigir(m.etapa = 'realizacao', 'A OS precisa estar em realização.');
  update public.manutencoes set etapa = 'aguardando_fechamento', concluida_por = me.id, concluida_em = now() where id = p_os;
  perform public._log(p_os, 'Deu o ok de serviço concluído');
end $$;

create or replace function public.devolver_os(p_os uuid, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); m public.manutencoes;
begin
  perform public._exigir(me.perfil in ('analista', 'gestor'), 'Só analista ou gestor devolve a OS.');
  perform public._exigir(coalesce(trim(p_motivo), '') <> '', 'Diga o que não foi resolvido.');
  select * into m from public.manutencoes where id = p_os for update;
  perform public._exigir(m.etapa = 'aguardando_fechamento', 'A OS não está aguardando fechamento.');
  update public.manutencoes set etapa = 'realizacao', concluida_por = null, concluida_em = null where id = p_os;
  perform public._log(p_os, 'Devolveu para realização: ' || trim(p_motivo));
end $$;

create or replace function public.fechar_os(p_os uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); m public.manutencoes;
begin
  perform public._exigir(me.perfil in ('analista', 'gestor'), 'Só analista ou gestor fecha a OS.');
  select * into m from public.manutencoes where id = p_os for update;
  perform public._exigir(m.etapa = 'aguardando_fechamento', 'A OS precisa estar aguardando fechamento.');
  perform public._exigir(not exists (select 1 from public.compras where manutencao_id = p_os and status in ('cotacao', 'reprovada', 'aprovacao')),
    'Há OC em cotação ou aguardando aprovação nesta OS. Aprove ou cancele antes de fechar.');
  perform public._exigir(not exists (select 1 from public.ordens where manutencao_id = p_os and status <> 'cancelada' and entregue_em is null),
    'Há OC sem entrega confirmada nesta OS.');
  update public.manutencoes set etapa = 'fechada', encerrada_em = now(), fechada_por = me.id where id = p_os;
  perform public._log(p_os, 'Fechou a OS: problema resolvido');
end $$;

create or replace function public.cancelar_os(p_os uuid, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); m public.manutencoes;
begin
  perform public._exigir(me.perfil in ('analista', 'gestor'), 'Só analista ou gestor cancela a OS.');
  perform public._exigir(coalesce(trim(p_motivo), '') <> '', 'Informe o motivo.');
  select * into m from public.manutencoes where id = p_os for update;
  perform public._exigir(m.etapa not in ('fechada', 'cancelada'), 'Esta OS já está fechada ou cancelada.');
  update public.compras set status = 'cancelada', cancelada_motivo = 'OS cancelada' where manutencao_id = p_os and status in ('cotacao', 'reprovada', 'aprovacao');
  update public.manutencoes set etapa = 'cancelada', cancelada = true where id = p_os;
  perform public._log(p_os, 'Cancelou a OS: ' || trim(p_motivo));
end $$;

create or replace function public.definir_prioridade(p_manut uuid, p_prioridade text) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu();
begin
  perform public._exigir(me.perfil = 'gestor', 'Só o gestor define a prioridade.');
  perform public._exigir(p_prioridade in ('urgente', 'programada'), 'Prioridade inválida.');
  update public.manutencoes set prioridade = p_prioridade, prioridade_confirmada = true where id = p_manut;
  perform public._log(p_manut, 'Definiu como ' || p_prioridade);
end $$;

create or replace function public.atender(p_manut uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu();
begin
  perform public._exigir(me.perfil in ('mecanico', 'analista', 'gestor'), 'Só mecânico, analista ou gestor assume o atendimento.');
  update public.manutencoes set atendido_por = me.id where id = p_manut;
  perform public._log(p_manut, 'Assumiu o atendimento');
end $$;

create or replace function public.comentar(p_manut uuid, p_txt text) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu();
begin
  perform public._exigir(coalesce(trim(p_txt), '') <> '', 'Escreva o comentário.');
  perform public._log(p_manut, 'Comentário: ' || trim(p_txt));
end $$;

-- =====================================================================
-- OC: abrir, cotar, aprovar
-- =====================================================================
-- p_os nulo = OC de estoque
create or replace function public.nova_compra(p_os uuid, p_descricao text, p_tipo text) returns uuid
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); m public.manutencoes; v uuid;
begin
  perform public._exigir(me.perfil in ('mecanico', 'analista', 'gestor'), 'Só mecânico, analista ou gestor abre OC.');
  perform public._exigir(coalesce(trim(p_descricao), '') <> '', 'Descreva o que será comprado.');
  perform public._exigir(p_tipo in ('peca', 'servico'), 'Escolha insumo/peça ou serviço.');
  if p_os is not null then
    m := public._os_ativa(p_os);
    insert into public.compras (manutencao_id, destino, placa, descricao, tipo, criado_por)
    values (m.id, m.destino, m.placa, trim(p_descricao), p_tipo, me.id) returning id into v;
  else
    insert into public.compras (manutencao_id, destino, placa, descricao, tipo, criado_por)
    values (null, 'estoque', null, trim(p_descricao), p_tipo, me.id) returning id into v;
  end if;
  perform public._log_c(v, 'Abriu OC: ' || trim(p_descricao) || case when p_os is null then ' (estoque)' else '' end);
  return v;
end $$;

create or replace function public.add_cotacao(p_compra uuid, p_fornecedor uuid, p_valor numeric, p_prazo text, p_pagamento text, p_obs text, p_anexo text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); c public.compras; v uuid;
begin
  select * into c from public.compras where id = p_compra for update;
  perform public._exigir(c.id is not null, 'OC não encontrada.');
  perform public._exigir(public._pode_cotar(me.perfil, p_compra),
    case when c.manutencao_id is null then 'OC de estoque é cotada pelo analista ou pelo gestor.' else 'Sem permissão para cotar.' end);
  perform public._exigir(c.status in ('cotacao', 'reprovada') and not c.sem_cotacao, 'Esta OC não está mais em cotação.');
  perform public._exigir(p_valor > 0, 'Informe o valor.');
  perform public._exigir(exists (select 1 from public.fornecedores where id = p_fornecedor), 'Escolha o fornecedor.');
  insert into public.cotacoes (compra_id, fornecedor_id, valor, prazo, pagamento, obs, anexo, por)
  values (p_compra, p_fornecedor, p_valor, coalesce(p_prazo, ''), coalesce(p_pagamento, ''), coalesce(p_obs, ''), p_anexo, me.id)
  returning id into v;
  update public.compras set status = 'cotacao',
    escolhida_id = (select id from public.cotacoes where compra_id = p_compra and not posterior order by valor, em limit 1)
  where id = p_compra;
  perform public._log_c(p_compra, format('Cotação %s: %s', (select nome from public.fornecedores where id = p_fornecedor), public._brl(p_valor)));
  return v;
end $$;

create or replace function public.remover_cotacao(p_cotacao uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); c public.compras;
begin
  select c2.* into c from public.compras c2 join public.cotacoes q on q.compra_id = c2.id where q.id = p_cotacao and not q.posterior for update of c2;
  perform public._exigir(c.id is not null and public._pode_cotar(me.perfil, c.id), 'Sem permissão.');
  perform public._exigir(c.status in ('cotacao', 'reprovada'), 'Esta OC não está mais em cotação.');
  delete from public.cotacoes where id = p_cotacao;
  update public.compras set escolhida_id = (select id from public.cotacoes where compra_id = c.id and not posterior order by valor, em limit 1)
  where id = c.id and (escolhida_id = p_cotacao or escolhida_id is null);
  perform public._log_c(c.id, 'Removeu uma cotação');
end $$;

create or replace function public.escolher_cotacao(p_compra uuid, p_cotacao uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu();
begin
  perform public._exigir(public._pode_cotar(me.perfil, p_compra), 'Sem permissão.');
  update public.compras set escolhida_id = p_cotacao
  where id = p_compra and status in ('cotacao', 'reprovada')
    and exists (select 1 from public.cotacoes where id = p_cotacao and compra_id = p_compra and not posterior);
end $$;

-- quem cotou fecha a compra: informa o WhatsApp de envio e manda para quem tem alçada
create or replace function public.enviar_aprovacao(p_compra uuid, p_justificativa text, p_whatsapp text) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); c public.compras;
begin
  select * into c from public.compras where id = p_compra for update;
  perform public._exigir(c.id is not null and public._pode_cotar(me.perfil, p_compra), 'Sem permissão.');
  perform public._exigir(c.status in ('cotacao', 'reprovada'), 'Esta OC não está em cotação.');
  update public.compras set justificativa = coalesce(nullif(trim(p_justificativa), ''), justificativa),
    whatsapp = coalesce(regexp_replace(p_whatsapp, '\D', '', 'g'), whatsapp) where id = p_compra;
  perform public._validar_compra(p_compra, coalesce(nullif(trim(p_justificativa), ''), c.justificativa));
  update public.compras set status = 'aprovacao', solicitada_em = now(), solicitada_por = me.id, motivo_reprova = null where id = p_compra;
  perform public._log_c(p_compra, format('Enviou %s para aprovação', public._brl((select valor from public.cotacoes where id = c.escolhida_id))));
end $$;

-- aprova: a própria compra (dentro da alçada) ou a que chegou para aprovação
create or replace function public.aprovar(p_compra uuid, p_justificativa text default null, p_whatsapp text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); c public.compras; v_valor numeric; v_alc numeric; v_oc uuid;
begin
  select * into c from public.compras where id = p_compra for update;
  perform public._exigir(c.id is not null, 'OC não encontrada.');
  perform public._exigir(c.status in ('cotacao', 'reprovada', 'aprovacao'), 'Esta OC não está aguardando aprovação.');
  select valor into v_valor from public.cotacoes where id = c.escolhida_id;
  perform public._exigir(v_valor is not null, 'Escolha uma cotação.');
  v_alc := public._alcada_de(me.id);
  perform public._exigir(me.perfil in ('mecanico', 'analista', 'gestor'), 'Seu perfil não aprova compras.');
  perform public._exigir(c.manutencao_id is not null or me.perfil in ('analista', 'gestor'), 'OC de estoque é aprovada pelo analista ou pelo gestor.');
  perform public._exigir(v_alc is null or v_valor <= v_alc, format('%s passa da sua alçada.', public._brl(v_valor)));
  if c.status in ('cotacao', 'reprovada') then
    perform public._exigir(public._pode_cotar(me.perfil, p_compra), 'Sem permissão.');
    update public.compras set justificativa = coalesce(nullif(trim(p_justificativa), ''), justificativa),
      whatsapp = coalesce(regexp_replace(p_whatsapp, '\D', '', 'g'), whatsapp),
      solicitada_em = coalesce(solicitada_em, now()), solicitada_por = coalesce(solicitada_por, me.id) where id = p_compra;
    perform public._validar_compra(p_compra, coalesce(nullif(trim(p_justificativa), ''), c.justificativa));
  elsif p_whatsapp is not null then
    update public.compras set whatsapp = regexp_replace(p_whatsapp, '\D', '', 'g') where id = p_compra;
  end if;
  v_oc := public._gerar_oc(p_compra);
  perform public._log_c(p_compra, format('%s %s e gerou %s', case when c.sem_cotacao then 'Autorizou a compra sem cotação de' else 'Aprovou' end,
    public._brl(v_valor), (select num from public.ordens where id = v_oc)));
  return v_oc;
end $$;

create or replace function public.reprovar(p_compra uuid, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); c public.compras; v_valor numeric; v_alc numeric;
begin
  select * into c from public.compras where id = p_compra for update;
  perform public._exigir(c.status = 'aprovacao', 'Esta OC não está aguardando aprovação.');
  perform public._exigir(coalesce(trim(p_motivo), '') <> '', 'Informe o motivo.');
  select valor into v_valor from public.cotacoes where id = c.escolhida_id;
  v_alc := public._alcada_de(me.id);
  perform public._exigir(me.perfil in ('mecanico', 'analista', 'gestor') and (v_alc is null or v_valor <= v_alc), 'Valor acima da sua alçada.');
  perform public._exigir(c.manutencao_id is not null or me.perfil in ('analista', 'gestor'), 'OC de estoque é aprovada pelo analista ou pelo gestor.');
  if c.sem_cotacao then
    -- pedido sem cotação reprovado: volta a ser uma OC normal, que precisa de cotação
    update public.compras set status = 'reprovada', sem_cotacao = false, motivo_reprova = trim(p_motivo) where id = p_compra;
  else
    update public.compras set status = 'reprovada', motivo_reprova = trim(p_motivo) where id = p_compra;
  end if;
  perform public._log_c(p_compra, 'Reprovou: ' || trim(p_motivo));
end $$;

-- pedido de autorização para comprar sem cotação (só dentro de uma OS; qualquer perfil)
create or replace function public.pedir_sem_cotacao(p_os uuid, p_descricao text, p_tipo text, p_fornecedor uuid, p_valor numeric,
  p_justificativa text, p_whatsapp text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); m public.manutencoes; v_c uuid; v_q uuid; v_oc uuid; v_alc numeric;
begin
  perform public._exigir(me.perfil <> 'financeiro', 'O financeiro não pede compras.');
  m := public._os_ativa(p_os);
  perform public._exigir(coalesce(trim(p_descricao), '') <> '', 'Diga o que vai comprar.');
  perform public._exigir(coalesce(p_valor, 0) > 0, 'Informe o valor.');
  perform public._exigir(coalesce(trim(p_justificativa), '') <> '', 'Diga por que não dá para cotar.');
  perform public._exigir(exists (select 1 from public.fornecedores where id = p_fornecedor), 'Escolha o fornecedor.');
  insert into public.compras (manutencao_id, destino, placa, descricao, tipo, sem_cotacao, justificativa, whatsapp, solicitada_em, solicitada_por, criado_por)
  values (m.id, m.destino, m.placa, trim(p_descricao), case when p_tipo in ('peca', 'servico') then p_tipo else 'peca' end, true,
          trim(p_justificativa), coalesce(regexp_replace(p_whatsapp, '\D', '', 'g'), ''), now(), me.id, me.id)
  returning id into v_c;
  insert into public.cotacoes (compra_id, fornecedor_id, valor, prazo, por) values (v_c, p_fornecedor, p_valor, 'Imediato', me.id) returning id into v_q;
  update public.compras set escolhida_id = v_q where id = v_c;
  if m.prioridade <> 'urgente' or not m.prioridade_confirmada then
    update public.manutencoes set prioridade = 'urgente', prioridade_confirmada = true where id = m.id;
  end if;
  perform public._log(m.id, format('Pediu para comprar sem cotação: %s, %s. Motivo: %s', trim(p_descricao), public._brl(p_valor), trim(p_justificativa)));
  v_alc := public._alcada_de(me.id);
  if v_alc is null or p_valor <= v_alc then
    v_oc := public._gerar_oc(v_c);
    perform public._log(m.id, format('Autorizou dentro da própria alçada e gerou %s', (select num from public.ordens where id = v_oc)));
  else
    update public.compras set status = 'aprovacao' where id = v_c;
  end if;
  return jsonb_build_object('compra_id', v_c, 'ordem_id', v_oc);
end $$;

create or replace function public.cancelar_compra(p_compra uuid, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); c public.compras;
begin
  select * into c from public.compras where id = p_compra for update;
  perform public._exigir(c.id is not null, 'OC não encontrada.');
  perform public._exigir(me.perfil in ('analista', 'gestor') or (c.criado_por = me.id and c.status in ('cotacao', 'reprovada')),
    'Só analista, gestor ou quem abriu a OC pode cancelar.');
  perform public._exigir(c.status in ('cotacao', 'reprovada', 'aprovacao'), 'OC já aprovada só pode ser cancelada pelo gestor, na tela da OC.');
  perform public._exigir(coalesce(trim(p_motivo), '') <> '', 'Informe o motivo.');
  update public.compras set status = 'cancelada', cancelada_motivo = trim(p_motivo) where id = p_compra;
  perform public._log_c(p_compra, format('Cancelou a OC "%s": %s', c.descricao, trim(p_motivo)));
end $$;

-- OC aprovada: só o gestor cancela, com motivo; o número fica marcado e nunca é reaproveitado
create or replace function public.cancelar_oc(p_ordem uuid, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); o public.ordens;
begin
  perform public._exigir(me.perfil = 'gestor', 'Só o gestor cancela uma OC aprovada.');
  perform public._exigir(coalesce(trim(p_motivo), '') <> '', 'Informe o motivo do cancelamento.');
  select * into o from public.ordens where id = p_ordem for update;
  perform public._exigir(o.id is not null and o.status <> 'cancelada', 'Esta OC já está cancelada.');
  update public.ordens set status = 'cancelada', cancelada_por = me.id, cancelada_em = now(), cancelada_motivo = trim(p_motivo) where id = p_ordem;
  update public.compras set cancelada_motivo = trim(p_motivo) where id = o.compra_id;
  perform public._log_c(o.compra_id, format('Cancelou a %s: %s', o.num, trim(p_motivo)));
end $$;

create or replace function public.confirmar_entrega(p_ordem uuid, p_foto text default null) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); o public.ordens;
begin
  select * into o from public.ordens where id = p_ordem for update;
  perform public._exigir(o.id is not null and o.status <> 'cancelada', 'OC não encontrada ou cancelada.');
  perform public._exigir(o.entregue_em is null, 'A entrega desta OC já foi confirmada.');
  perform public._exigir(coalesce(trim(p_foto), '') <> '', 'A foto da entrega é obrigatória.');
  update public.ordens set entregue_em = now(), entregue_por = me.id, entrega_foto = p_foto where id = p_ordem;
  perform public._log_c(o.compra_id, format('Confirmou a entrega da %s', o.num));
  perform public._fechar_oc(p_ordem);
end $$;

create or replace function public.add_cotacao_posterior(p_compra uuid, p_fornecedor uuid, p_valor numeric, p_prazo text, p_obs text, p_anexo text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); c public.compras; v uuid; v_pago numeric; v_dif numeric;
begin
  perform public._exigir(me.perfil in ('mecanico', 'analista', 'gestor'), 'Só mecânico, analista ou gestor lança cotação.');
  select * into c from public.compras where id = p_compra;
  perform public._exigir(c.status = 'aprovada' and c.sem_cotacao, 'Cotação posterior só vale para compra feita sem cotação.');
  perform public._exigir(p_valor > 0, 'Informe o valor.');
  perform public._exigir(exists (select 1 from public.fornecedores where id = p_fornecedor), 'Escolha o fornecedor.');
  insert into public.cotacoes (compra_id, fornecedor_id, valor, prazo, obs, anexo, por, posterior)
  values (p_compra, p_fornecedor, p_valor, coalesce(p_prazo, ''), coalesce(p_obs, ''), p_anexo, me.id, true) returning id into v;
  select valor into v_pago from public.cotacoes where id = c.escolhida_id;
  v_dif := v_pago - p_valor;
  perform public._log_c(p_compra, format('Cotação posterior %s: %s (%s)', (select nome from public.fornecedores where id = p_fornecedor), public._brl(p_valor),
    case when v_dif > 0 then 'pagamos ' || public._brl(v_dif) || ' a mais' when v_dif < 0 then 'pagamos ' || public._brl(-v_dif) || ' a menos' else 'mesmo valor' end));
  perform public._fechar_oc(c.oc_id);
  return v;
end $$;

-- =====================================================================
-- CADASTROS E REGRAS
-- =====================================================================
create or replace function public.salvar_usuario(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); v uuid := (p->>'id')::uuid;
begin
  perform public._exigir(me.perfil = 'gestor', 'Só o gestor altera usuários.');
  perform public._exigir(p->>'perfil' in ('motorista', 'mecanico', 'analista', 'financeiro', 'gestor'), 'Perfil inválido.');
  if v = me.id and (p->>'perfil' <> 'gestor' or coalesce((p->>'ativo')::boolean, true) = false) then
    perform public._exigir(exists (select 1 from public.profiles where perfil = 'gestor' and ativo and id <> me.id),
      'Você é o único gestor. Nomeie outro gestor antes de mudar o seu perfil.');
  end if;
  update public.profiles set nome = coalesce(nullif(trim(p->>'nome'), ''), nome), perfil = p->>'perfil',
    placa = coalesce(p->>'placa', ''), ativo = coalesce((p->>'ativo')::boolean, true), alcada = nullif(p->>'alcada', '')::numeric
  where id = v;
end $$;

create or replace function public.salvar_config(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu();
begin
  perform public._exigir(me.perfil = 'gestor', 'Só o gestor altera as regras.');
  perform public._exigir(coalesce((p->>'cot_min_valor')::numeric, -1) >= 0, 'Informe o valor mínimo para exigir cotações.');
  update public.config set
    alcada_motorista = coalesce((p->>'alcada_motorista')::numeric, alcada_motorista),
    alcada_mecanico  = coalesce((p->>'alcada_mecanico')::numeric, alcada_mecanico),
    alcada_analista  = coalesce((p->>'alcada_analista')::numeric, alcada_analista),
    cot_min_valor    = (p->>'cot_min_valor')::numeric
  where id = 1;
end $$;

-- =====================================================================
-- PERMISSÕES
-- =====================================================================
alter table public.seq_doc enable row level security;
revoke all on public.seq_doc from anon, authenticated;

revoke execute on function public._num(text), public._log_c(uuid, text), public._pode_cotar(text, uuid), public._os_ativa(uuid),
  public._gerar_oc(uuid), public._validar_compra(uuid, text), public._fechar_oc(uuid), public._alcada(text), public._alcada_de(uuid),
  public._cot_necessarias(numeric) from public, anon, authenticated;

revoke execute on function public.abrir_os(text, text, text, text, text[], int), public.iniciar_triagem(uuid), public.concluir_triagem(uuid, text, text),
  public.concluir_servico(uuid), public.devolver_os(uuid, text), public.fechar_os(uuid), public.cancelar_os(uuid, text),
  public.nova_compra(uuid, text, text), public.enviar_aprovacao(uuid, text, text), public.aprovar(uuid, text, text),
  public.pedir_sem_cotacao(uuid, text, text, uuid, numeric, text, text), public.cancelar_compra(uuid, text), public.cancelar_oc(uuid, text)
  from public, anon;
grant execute on function public.abrir_os(text, text, text, text, text[], int), public.iniciar_triagem(uuid), public.concluir_triagem(uuid, text, text),
  public.concluir_servico(uuid), public.devolver_os(uuid, text), public.fechar_os(uuid), public.cancelar_os(uuid, text),
  public.nova_compra(uuid, text, text), public.enviar_aprovacao(uuid, text, text), public.aprovar(uuid, text, text),
  public.pedir_sem_cotacao(uuid, text, text, uuid, numeric, text, text), public.cancelar_compra(uuid, text), public.cancelar_oc(uuid, text)
  to authenticated;
