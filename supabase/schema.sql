-- =====================================================================
-- BARRETO MANUTENÇÃO — banco de dados no Supabase
-- Cole este arquivo inteiro no SQL Editor do projeto e clique em Run.
-- Pode rodar de novo sem perder dados (cria só o que falta e atualiza
-- as funções).
--
-- Princípio: o app LÊ as tabelas, mas só GRAVA através das funções
-- abaixo. É nas funções que ficam as regras de alçada, de cotações e a
-- numeração da OC, então ninguém contorna as regras pela tela.
-- =====================================================================


-- ---------------------------------------------------------------------
-- TABELAS
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id        uuid primary key references auth.users(id) on delete cascade,
  email     text,
  nome      text not null default '',
  perfil    text not null default 'motorista' check (perfil in ('motorista','mecanico','analista','gestor')),
  placa     text not null default '',
  ativo     boolean not null default true,
  telefone  text not null default '',
  criado_em timestamptz not null default now()
);
alter table public.profiles add column if not exists telefone text not null default '';

create table if not exists public.config (
  id                    int primary key default 1 check (id = 1),
  alcada_motorista      numeric(12,2) not null default 0,
  alcada_mecanico       numeric(12,2) not null default 300,
  alcada_analista       numeric(12,2) not null default 1000,
  faixa1                numeric(12,2) not null default 500,   -- até aqui: 1 cotação
  faixa2                numeric(12,2) not null default 2000,  -- até aqui: 2 cotações; acima: 3
  teto_emergencial      numeric(12,2) not null default 3000,
  prazo_regularizacao_h int not null default 48,
  tolerancia_nf         numeric(6,2) not null default 10
);
insert into public.config (id) values (1) on conflict (id) do nothing;

create table if not exists public.veiculos (
  id        uuid primary key default gen_random_uuid(),
  placa     text not null unique,
  descricao text not null default '',
  ativo     boolean not null default true
);

create table if not exists public.fornecedores (
  id         uuid primary key default gen_random_uuid(),
  nome       text not null,
  cnpj       text not null default '',
  cidade     text not null default '',
  telefone   text not null default '',
  categoria  text not null default 'Peças',
  provisorio boolean not null default false,
  criado_por uuid references public.profiles(id),
  criado_em  timestamptz not null default now()
);

create sequence if not exists public.manut_seq;

create table if not exists public.manutencoes (
  id                    uuid primary key default gen_random_uuid(),
  num                   text not null unique,
  placa                 text not null,
  descricao             text not null,
  tipo                  text not null default 'peca' check (tipo in ('peca','servico','ambos')),
  prioridade            text not null default 'urgente' check (prioridade in ('urgente','programada')),
  prioridade_confirmada boolean not null default false,
  aberto_por            uuid references public.profiles(id),
  aberto_em             timestamptz not null default now(),
  atendido_por          uuid references public.profiles(id),
  fotos                 text[] not null default '{}',
  encerrada_em          timestamptz,
  cancelada             boolean not null default false
);

create table if not exists public.historico (
  id            bigserial primary key,
  manutencao_id uuid not null references public.manutencoes(id) on delete cascade,
  em            timestamptz not null default now(),
  por           uuid references public.profiles(id),
  txt           text not null
);

create table if not exists public.compras (
  id             uuid primary key default gen_random_uuid(),
  manutencao_id  uuid not null references public.manutencoes(id) on delete cascade,
  descricao      text not null,
  tipo           text not null default 'peca' check (tipo in ('peca','servico','ambos')),
  status         text not null default 'cotacao' check (status in ('cotacao','reprovada','aprovacao','aprovada','cancelada')),
  escolhida_id   uuid,
  justificativa  text not null default '',
  dispensa       text,
  solicitada_em  timestamptz,
  solicitada_por uuid references public.profiles(id),
  oc_id          uuid,
  motivo_reprova text,
  criado_em      timestamptz not null default now()
);

create table if not exists public.cotacoes (
  id            uuid primary key default gen_random_uuid(),
  compra_id     uuid not null references public.compras(id) on delete cascade,
  fornecedor_id uuid not null references public.fornecedores(id),
  valor         numeric(12,2) not null check (valor > 0),
  prazo         text not null default '',
  pagamento     text not null default '',
  obs           text not null default '',
  anexo         text,
  por           uuid references public.profiles(id),
  em            timestamptz not null default now()
);

create table if not exists public.oc_seq (
  ano    int primary key,
  ultimo int not null default 0
);

create table if not exists public.ordens (
  id                     uuid primary key default gen_random_uuid(),
  num                    text not null unique,
  manutencao_id          uuid not null references public.manutencoes(id),
  compra_id              uuid not null references public.compras(id),
  placa                  text not null,
  fornecedor_id          uuid not null references public.fornecedores(id),
  valor                  numeric(12,2) not null,
  tipo                   text not null default 'peca',
  emergencial            boolean not null default false,
  aprovado_por           uuid references public.profiles(id),
  aprovado_em            timestamptz not null default now(),
  regularizar_ate        timestamptz,
  revisada_por           uuid references public.profiles(id),
  revisada_em            timestamptz,
  nf_numero              text,
  nf_valor               numeric(12,2),
  nf_foto                text,
  nf_por                 uuid references public.profiles(id),
  nf_em                  timestamptz,
  status                 text not null default 'aberta' check (status in ('aberta','recebida','divergente','cancelada')),
  divergencia_aceita_por uuid references public.profiles(id)
);

create index if not exists historico_manut_idx on public.historico (manutencao_id);
create index if not exists compras_manut_idx   on public.compras (manutencao_id);
create index if not exists cotacoes_compra_idx on public.cotacoes (compra_id);
create index if not exists ordens_manut_idx    on public.ordens (manutencao_id);

-- ---------------------------------------------------------------------
-- NOVO USUÁRIO → PERFIL
-- O primeiro usuário criado vira gestor; os demais entram como motorista
-- e o gestor ajusta o perfil no app (Cadastros › Usuários).
-- ---------------------------------------------------------------------
create or replace function public._novo_usuario() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, nome, telefone, perfil)
  values (new.id, new.email,
          coalesce(nullif(trim(new.raw_user_meta_data->>'nome'), ''), split_part(coalesce(new.email, ''), '@', 1)),
          coalesce(new.raw_user_meta_data->>'telefone', ''),
          case when exists (select 1 from public.profiles where perfil = 'gestor') then 'motorista' else 'gestor' end)
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public._novo_usuario();

-- usuários que já existiam antes deste script
insert into public.profiles (id, email, nome)
select u.id, u.email, split_part(coalesce(u.email, ''), '@', 1) from auth.users u
on conflict (id) do nothing;
update public.profiles set perfil = 'gestor'
where id = (select id from public.profiles order by criado_em limit 1)
  and not exists (select 1 from public.profiles where perfil = 'gestor');

-- ---------------------------------------------------------------------
-- FUNÇÕES DE APOIO
-- ---------------------------------------------------------------------
create or replace function public.eu_ativo() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and ativo)
$$;

create or replace function public._eu() returns public.profiles
language plpgsql stable security definer set search_path = public as $$
declare v public.profiles;
begin
  select * into v from public.profiles where id = auth.uid() and ativo;
  if not found then raise exception 'Seu usuário não tem acesso ao app. Fale com o gestor.'; end if;
  return v;
end $$;

-- alçada em R$; null = sem limite (gestor)
create or replace function public._alcada(p_perfil text) returns numeric
language sql stable security definer set search_path = public as $$
  select case p_perfil when 'gestor' then null
                       when 'analista' then alcada_analista
                       when 'mecanico' then alcada_mecanico
                       else alcada_motorista end
  from public.config where id = 1
$$;

create or replace function public._cot_necessarias(p_valor numeric) returns int
language sql stable security definer set search_path = public as $$
  select case when p_valor <= faixa1 then 1 when p_valor <= faixa2 then 2 else 3 end
  from public.config where id = 1
$$;

create or replace function public._log(p_manut uuid, p_txt text) returns void
language sql security definer set search_path = public as $$
  insert into public.historico (manutencao_id, por, txt) values (p_manut, auth.uid(), p_txt)
$$;

create or replace function public._brl(v numeric) returns text
language sql immutable as $$
  select 'R$ ' || replace(replace(replace(to_char(v, 'FM999G999G990D00'), ',', '#'), '.', ','), '#', '.')
$$;

create or replace function public._exigir(p_ok boolean, p_msg text) returns void
language plpgsql as $$
begin
  if not p_ok then raise exception '%', p_msg; end if;
end $$;

-- gera a OC (número sequencial por ano) a partir da cotação escolhida
create or replace function public._gerar_oc(p_compra uuid, p_emergencial boolean) returns uuid
language plpgsql security definer set search_path = public as $$
declare c public.compras; m public.manutencoes; q public.cotacoes; v_ano int; v_n int; v_id uuid; v_prazo int;
begin
  select * into c from public.compras where id = p_compra;
  select * into m from public.manutencoes where id = c.manutencao_id;
  select * into q from public.cotacoes where id = c.escolhida_id;
  perform public._exigir(q.id is not null, 'Escolha uma cotação.');
  v_ano := extract(year from (now() at time zone 'America/Sao_Paulo'))::int;
  insert into public.oc_seq (ano, ultimo) values (v_ano, 1)
    on conflict (ano) do update set ultimo = public.oc_seq.ultimo + 1
    returning ultimo into v_n;
  select prazo_regularizacao_h into v_prazo from public.config where id = 1;
  insert into public.ordens (num, manutencao_id, compra_id, placa, fornecedor_id, valor, tipo, emergencial, aprovado_por, regularizar_ate)
  values ('OC ' || lpad((v_ano % 100)::text, 2, '0') || '-' || lpad(v_n::text, 4, '0'),
          m.id, c.id, m.placa, q.fornecedor_id, q.valor, c.tipo, p_emergencial, auth.uid(),
          case when p_emergencial then now() + make_interval(hours => v_prazo) end)
  returning id into v_id;
  update public.compras set status = 'aprovada', oc_id = v_id where id = c.id;
  return v_id;
end $$;

-- confere a regra de cotações e a justificativa antes de aprovar/enviar
create or replace function public._validar_compra(p_compra uuid, p_perfil text, p_just text, p_disp text) returns void
language plpgsql security definer set search_path = public as $$
declare q public.cotacoes; v_n int; v_menor numeric; v_nec int;
begin
  select q2.* into q from public.cotacoes q2 join public.compras c on c.escolhida_id = q2.id where c.id = p_compra;
  perform public._exigir(q.id is not null, 'Escolha uma cotação.');
  select count(*), min(valor) into v_n, v_menor from public.cotacoes where compra_id = p_compra;
  v_nec := public._cot_necessarias(q.valor);
  if v_n < v_nec then
    perform public._exigir(coalesce(trim(p_disp), '') <> '' and p_perfil in ('analista', 'gestor'),
      format('Para %s a regra pede %s cotação(ões). Lance mais ou peça ao analista para dispensar.', public._brl(q.valor), v_nec));
  end if;
  if q.valor > v_menor then
    perform public._exigir(coalesce(trim(p_just), '') <> '', 'A cotação escolhida não é a menor. Informe a justificativa.');
  end if;
end $$;

-- ---------------------------------------------------------------------
-- AÇÕES DO APP (chamadas pela tela)
-- ---------------------------------------------------------------------
create or replace function public.criar_demanda(p_placa text, p_descricao text, p_tipo text, p_prioridade text, p_fotos text[], p_emerg jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); v_m uuid; v_c uuid; v_q uuid; v_oc uuid; v_valor numeric; v_teto numeric; v_n int;
begin
  perform public._exigir(coalesce(trim(p_placa), '') <> '', 'Escolha a placa.');
  perform public._exigir(coalesce(trim(p_descricao), '') <> '', 'Descreva o que está acontecendo.');
  insert into public.manutencoes (num, placa, descricao, tipo, prioridade, prioridade_confirmada, aberto_por, atendido_por, fotos)
  values ('M-' || lpad(nextval('public.manut_seq')::text, 4, '0'), upper(p_placa), trim(p_descricao), p_tipo,
          case when p_emerg is not null then 'urgente' else p_prioridade end,
          me.perfil = 'gestor' or p_emerg is not null, me.id,
          case when me.perfil = 'mecanico' then me.id end, coalesce(p_fotos, '{}'))
  returning id into v_m;
  v_n := coalesce(array_length(p_fotos, 1), 0);
  perform public._log(v_m, case when v_n > 0 then format('Abriu a demanda com %s foto(s)', v_n) else 'Abriu a demanda' end);

  if p_emerg is not null then
    v_valor := (p_emerg->>'valor')::numeric;
    perform public._exigir(v_valor > 0, 'Informe o valor da compra emergencial.');
    perform public._exigir(coalesce(trim(p_emerg->>'justificativa'), '') <> '', 'Diga por que a compra é emergencial.');
    perform public._exigir(exists (select 1 from public.fornecedores where id = (p_emerg->>'fornecedor_id')::uuid), 'Escolha o fornecedor.');
    insert into public.compras (manutencao_id, descricao, tipo, justificativa, dispensa, solicitada_em, solicitada_por)
    values (v_m, trim(p_descricao), p_tipo, trim(p_emerg->>'justificativa'), 'Compra emergencial', now(), me.id)
    returning id into v_c;
    insert into public.cotacoes (compra_id, fornecedor_id, valor, prazo, pagamento, por)
    values (v_c, (p_emerg->>'fornecedor_id')::uuid, v_valor, 'Imediato', coalesce(p_emerg->>'pagamento', ''), me.id)
    returning id into v_q;
    update public.compras set escolhida_id = v_q where id = v_c;
    select teto_emergencial into v_teto from public.config where id = 1;
    if v_valor <= v_teto then
      v_oc := public._gerar_oc(v_c, true);
      perform public._log(v_m, format('Compra emergencial: %s gerada na hora (%s)', (select num from public.ordens where id = v_oc), public._brl(v_valor)));
    else
      update public.compras set status = 'aprovacao' where id = v_c;
      perform public._log(v_m, format('Compra emergencial acima do teto de %s: enviada ao gestor como urgente', public._brl(v_teto)));
    end if;
  end if;
  return jsonb_build_object('manutencao_id', v_m, 'ordem_id', v_oc);
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
  perform public._exigir(me.perfil <> 'motorista', 'Motorista não assume atendimento.');
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

create or replace function public.nova_compra(p_manut uuid, p_descricao text, p_tipo text) returns uuid
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); v uuid;
begin
  perform public._exigir(me.perfil <> 'motorista', 'Motorista não lança cotação. Use a compra emergencial.');
  insert into public.compras (manutencao_id, descricao, tipo) values (p_manut, trim(p_descricao), p_tipo) returning id into v;
  perform public._log(p_manut, 'Nova compra: ' || trim(p_descricao));
  return v;
end $$;

create or replace function public.add_cotacao(p_compra uuid, p_fornecedor uuid, p_valor numeric, p_prazo text, p_pagamento text, p_obs text, p_anexo text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); c public.compras; v uuid;
begin
  perform public._exigir(me.perfil <> 'motorista', 'Motorista não lança cotação.');
  select * into c from public.compras where id = p_compra for update;
  perform public._exigir(c.status in ('cotacao', 'reprovada'), 'Esta compra não está mais em cotação.');
  perform public._exigir(p_valor > 0, 'Informe o valor.');
  insert into public.cotacoes (compra_id, fornecedor_id, valor, prazo, pagamento, obs, anexo, por)
  values (p_compra, p_fornecedor, p_valor, coalesce(p_prazo, ''), coalesce(p_pagamento, ''), coalesce(p_obs, ''), p_anexo, me.id)
  returning id into v;
  update public.compras set status = 'cotacao',
    escolhida_id = (select id from public.cotacoes where compra_id = p_compra order by valor, em limit 1)
  where id = p_compra;
  perform public._log(c.manutencao_id, format('Cotação %s: %s', (select nome from public.fornecedores where id = p_fornecedor), public._brl(p_valor)));
  return v;
end $$;

create or replace function public.remover_cotacao(p_cotacao uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); c public.compras;
begin
  perform public._exigir(me.perfil <> 'motorista', 'Sem permissão.');
  select c2.* into c from public.compras c2 join public.cotacoes q on q.compra_id = c2.id where q.id = p_cotacao for update of c2;
  perform public._exigir(c.status in ('cotacao', 'reprovada'), 'Esta compra não está mais em cotação.');
  delete from public.cotacoes where id = p_cotacao;
  update public.compras set escolhida_id = (select id from public.cotacoes where compra_id = c.id order by valor, em limit 1)
  where id = c.id and (escolhida_id = p_cotacao or escolhida_id is null);
  perform public._log(c.manutencao_id, 'Removeu uma cotação');
end $$;

create or replace function public.escolher_cotacao(p_compra uuid, p_cotacao uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu();
begin
  perform public._exigir(me.perfil <> 'motorista', 'Sem permissão.');
  update public.compras set escolhida_id = p_cotacao
  where id = p_compra and status in ('cotacao', 'reprovada')
    and exists (select 1 from public.cotacoes where id = p_cotacao and compra_id = p_compra);
end $$;

create or replace function public.enviar_aprovacao(p_compra uuid, p_justificativa text, p_dispensa text) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); c public.compras;
begin
  perform public._exigir(me.perfil <> 'motorista', 'Sem permissão.');
  select * into c from public.compras where id = p_compra for update;
  perform public._exigir(c.status in ('cotacao', 'reprovada'), 'Esta compra não está em cotação.');
  perform public._validar_compra(p_compra, me.perfil, coalesce(p_justificativa, c.justificativa), p_dispensa);
  update public.compras set status = 'aprovacao', solicitada_em = now(), solicitada_por = me.id, motivo_reprova = null,
    justificativa = coalesce(p_justificativa, justificativa), dispensa = coalesce(p_dispensa, dispensa)
  where id = p_compra;
  perform public._log(c.manutencao_id, format('Enviou %s para aprovação',
    public._brl((select valor from public.cotacoes where id = c.escolhida_id))));
end $$;

create or replace function public.aprovar(p_compra uuid, p_justificativa text default null, p_dispensa text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); c public.compras; v_valor numeric; v_alc numeric; v_oc uuid;
begin
  select * into c from public.compras where id = p_compra for update;
  perform public._exigir(c.status in ('cotacao', 'reprovada', 'aprovacao'), 'Esta compra não está aguardando aprovação.');
  select valor into v_valor from public.cotacoes where id = c.escolhida_id;
  perform public._exigir(v_valor is not null, 'Escolha uma cotação.');
  v_alc := public._alcada(me.perfil);
  perform public._exigir(me.perfil <> 'motorista' and (v_alc is null or v_valor <= v_alc),
    format('%s passa da sua alçada.', public._brl(v_valor)));
  if c.status in ('cotacao', 'reprovada') then
    perform public._validar_compra(p_compra, me.perfil, coalesce(p_justificativa, c.justificativa), p_dispensa);
    update public.compras set justificativa = coalesce(p_justificativa, justificativa), dispensa = coalesce(p_dispensa, dispensa),
      solicitada_em = coalesce(solicitada_em, now()), solicitada_por = coalesce(solicitada_por, me.id)
    where id = p_compra;
  end if;
  v_oc := public._gerar_oc(p_compra, false);
  perform public._log(c.manutencao_id, format('Aprovou e gerou %s (%s)', (select num from public.ordens where id = v_oc), public._brl(v_valor)));
  return v_oc;
end $$;

create or replace function public.reprovar(p_compra uuid, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); c public.compras; v_valor numeric; v_alc numeric;
begin
  select * into c from public.compras where id = p_compra for update;
  perform public._exigir(c.status = 'aprovacao', 'Esta compra não está aguardando aprovação.');
  perform public._exigir(coalesce(trim(p_motivo), '') <> '', 'Informe o motivo.');
  select valor into v_valor from public.cotacoes where id = c.escolhida_id;
  v_alc := public._alcada(me.perfil);
  perform public._exigir(me.perfil <> 'motorista' and (v_alc is null or v_valor <= v_alc), 'Valor acima da sua alçada.');
  update public.compras set status = 'reprovada', motivo_reprova = trim(p_motivo) where id = p_compra;
  perform public._log(c.manutencao_id, 'Reprovou: ' || trim(p_motivo));
end $$;

create or replace function public.cancelar_compra(p_compra uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); c public.compras;
begin
  perform public._exigir(me.perfil in ('analista', 'gestor'), 'Só analista ou gestor cancela compras.');
  select * into c from public.compras where id = p_compra for update;
  perform public._exigir(c.status <> 'aprovada', 'Compra já aprovada não pode ser cancelada aqui.');
  update public.compras set status = 'cancelada' where id = p_compra;
  perform public._log(c.manutencao_id, format('Cancelou a compra "%s"', c.descricao));
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
  return v_st;
end $$;

create or replace function public.aceitar_divergencia(p_ordem uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); o public.ordens;
begin
  perform public._exigir(me.perfil = 'gestor', 'Só o gestor aceita a diferença da NF.');
  update public.ordens set status = 'recebida', divergencia_aceita_por = me.id where id = p_ordem and status = 'divergente' returning * into o;
  if o.id is not null then perform public._log(o.manutencao_id, format('Aceitou a diferença da NF na %s', o.num)); end if;
end $$;

create or replace function public.revisar_emergencial(p_ordem uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); o public.ordens;
begin
  perform public._exigir(me.perfil = 'gestor', 'Só o gestor revisa compras emergenciais.');
  update public.ordens set revisada_por = me.id, revisada_em = now() where id = p_ordem and emergencial returning * into o;
  if o.id is not null then perform public._log(o.manutencao_id, format('Revisou a compra emergencial %s', o.num)); end if;
end $$;

create or replace function public.encerrar(p_manut uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu();
begin
  perform public._exigir(me.perfil <> 'motorista', 'Sem permissão.');
  perform public._exigir(not exists (
      select 1 from public.compras c left join public.ordens o on o.id = c.oc_id
      where c.manutencao_id = p_manut and c.status <> 'cancelada'
        and (c.status <> 'aprovada' or o.nf_em is null or o.status = 'divergente')),
    'Ainda há compras sem NF ou pendentes.');
  update public.manutencoes set encerrada_em = now() where id = p_manut;
  perform public._log(p_manut, 'Encerrou a manutenção');
end $$;

create or replace function public.reabrir(p_manut uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu();
begin
  perform public._exigir(me.perfil <> 'motorista', 'Sem permissão.');
  update public.manutencoes set encerrada_em = null where id = p_manut;
  perform public._log(p_manut, 'Reabriu a manutenção');
end $$;

create or replace function public.cancelar_manut(p_manut uuid, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu();
begin
  perform public._exigir(me.perfil in ('analista', 'gestor'), 'Só analista ou gestor cancela demandas.');
  perform public._exigir(coalesce(trim(p_motivo), '') <> '', 'Informe o motivo.');
  perform public._log(p_manut, 'Motivo do cancelamento: ' || trim(p_motivo));
  update public.manutencoes set cancelada = true where id = p_manut;
  perform public._log(p_manut, 'Cancelou a manutenção');
end $$;

create or replace function public.salvar_fornecedor(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); v uuid := nullif(p->>'id', '')::uuid; cad boolean := me.perfil in ('analista', 'gestor');
begin
  perform public._exigir(coalesce(trim(p->>'nome'), '') <> '', 'Informe o nome do fornecedor.');
  if v is null then
    insert into public.fornecedores (nome, cnpj, cidade, telefone, categoria, provisorio, criado_por)
    values (trim(p->>'nome'), coalesce(p->>'cnpj', ''), coalesce(p->>'cidade', ''), coalesce(p->>'telefone', ''),
            coalesce(nullif(p->>'categoria', ''), 'Peças'), not cad, me.id)
    returning id into v;
  else
    perform public._exigir(cad, 'Só analista ou gestor edita fornecedores.');
    update public.fornecedores set nome = trim(p->>'nome'), cnpj = coalesce(p->>'cnpj', ''), cidade = coalesce(p->>'cidade', ''),
      telefone = coalesce(p->>'telefone', ''), categoria = coalesce(nullif(p->>'categoria', ''), 'Peças'), provisorio = false
    where id = v;
  end if;
  return v;
end $$;

create or replace function public.salvar_veiculo(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); v uuid := nullif(p->>'id', '')::uuid;
begin
  perform public._exigir(me.perfil in ('analista', 'gestor'), 'Só analista ou gestor cadastra veículos.');
  perform public._exigir(length(coalesce(p->>'placa', '')) >= 7, 'Placa inválida.');
  if v is null then
    insert into public.veiculos (placa, descricao) values (upper(p->>'placa'), coalesce(p->>'descricao', '')) returning id into v;
  else
    update public.veiculos set placa = upper(p->>'placa'), descricao = coalesce(p->>'descricao', '') where id = v;
  end if;
  return v;
end $$;

create or replace function public.salvar_usuario(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); v uuid := (p->>'id')::uuid;
begin
  perform public._exigir(me.perfil = 'gestor', 'Só o gestor altera usuários.');
  perform public._exigir(p->>'perfil' in ('motorista', 'mecanico', 'analista', 'gestor'), 'Perfil inválido.');
  if v = me.id and (p->>'perfil' <> 'gestor' or coalesce((p->>'ativo')::boolean, true) = false) then
    perform public._exigir(exists (select 1 from public.profiles where perfil = 'gestor' and ativo and id <> me.id),
      'Você é o único gestor. Nomeie outro gestor antes de mudar o seu perfil.');
  end if;
  update public.profiles set nome = coalesce(nullif(trim(p->>'nome'), ''), nome), perfil = p->>'perfil',
    placa = coalesce(p->>'placa', ''), ativo = coalesce((p->>'ativo')::boolean, true)
  where id = v;
end $$;

create or replace function public.salvar_config(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu();
begin
  perform public._exigir(me.perfil = 'gestor', 'Só o gestor altera as regras.');
  perform public._exigir((p->>'faixa2')::numeric > (p->>'faixa1')::numeric, 'O valor de 2 cotações precisa ser maior que o de 1 cotação.');
  update public.config set
    alcada_motorista = (p->>'alcada_motorista')::numeric, alcada_mecanico = (p->>'alcada_mecanico')::numeric,
    alcada_analista = (p->>'alcada_analista')::numeric, faixa1 = (p->>'faixa1')::numeric, faixa2 = (p->>'faixa2')::numeric,
    teto_emergencial = (p->>'teto_emergencial')::numeric, prazo_regularizacao_h = greatest(1, (p->>'prazo_regularizacao_h')::int),
    tolerancia_nf = (p->>'tolerancia_nf')::numeric
  where id = 1;
end $$;

-- ---------------------------------------------------------------------
-- PERMISSÕES: leitura para usuários ativos; gravação só pelas funções
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['profiles','config','veiculos','fornecedores','manutencoes','historico','compras','cotacoes','ordens','oc_seq'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists ler on public.%I', t);
    execute format('revoke insert, update, delete on public.%I from anon, authenticated', t);
    if t <> 'oc_seq' then
      execute format('create policy ler on public.%I for select to authenticated using (public.eu_ativo())', t);
    end if;
  end loop;
end $$;

-- o perfil do próprio usuário precisa ser legível mesmo se inativo (para a tela avisar)
drop policy if exists ler_o_meu on public.profiles;
create policy ler_o_meu on public.profiles for select to authenticated using (id = auth.uid());

-- funções internas não podem ser chamadas pela tela
revoke execute on function public._eu(), public._alcada(text), public._cot_necessarias(numeric), public._log(uuid, text),
  public._gerar_oc(uuid, boolean), public._validar_compra(uuid, text, text, text), public._novo_usuario() from public, anon, authenticated;
-- funções do app: só usuários logados
revoke execute on function public.criar_demanda(text, text, text, text, text[], jsonb), public.definir_prioridade(uuid, text),
  public.atender(uuid), public.comentar(uuid, text), public.nova_compra(uuid, text, text),
  public.add_cotacao(uuid, uuid, numeric, text, text, text, text), public.remover_cotacao(uuid), public.escolher_cotacao(uuid, uuid),
  public.enviar_aprovacao(uuid, text, text), public.aprovar(uuid, text, text), public.reprovar(uuid, text), public.cancelar_compra(uuid),
  public.registrar_nf(uuid, text, numeric, text), public.aceitar_divergencia(uuid), public.revisar_emergencial(uuid),
  public.encerrar(uuid), public.reabrir(uuid), public.cancelar_manut(uuid, text), public.salvar_fornecedor(jsonb),
  public.salvar_veiculo(jsonb), public.salvar_usuario(jsonb), public.salvar_config(jsonb) from public, anon;
revoke execute on function public.eu_ativo() from public, anon;
grant execute on function public.criar_demanda(text, text, text, text, text[], jsonb), public.definir_prioridade(uuid, text),
  public.atender(uuid), public.comentar(uuid, text), public.nova_compra(uuid, text, text),
  public.add_cotacao(uuid, uuid, numeric, text, text, text, text), public.remover_cotacao(uuid), public.escolher_cotacao(uuid, uuid),
  public.enviar_aprovacao(uuid, text, text), public.aprovar(uuid, text, text), public.reprovar(uuid, text), public.cancelar_compra(uuid),
  public.registrar_nf(uuid, text, numeric, text), public.aceitar_divergencia(uuid), public.revisar_emergencial(uuid),
  public.encerrar(uuid), public.reabrir(uuid), public.cancelar_manut(uuid, text), public.salvar_fornecedor(jsonb),
  public.salvar_veiculo(jsonb), public.salvar_usuario(jsonb), public.salvar_config(jsonb), public.eu_ativo() to authenticated;

-- ---------------------------------------------------------------------
-- FOTOS (Storage): pasta privada, só usuários ativos veem e enviam
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fotos', 'fotos', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

drop policy if exists "fotos ler" on storage.objects;
create policy "fotos ler" on storage.objects for select to authenticated using (bucket_id = 'fotos' and public.eu_ativo());
drop policy if exists "fotos enviar" on storage.objects;
create policy "fotos enviar" on storage.objects for insert to authenticated with check (bucket_id = 'fotos' and public.eu_ativo());

-- ---------------------------------------------------------------------
-- TEMPO REAL: o app atualiza sozinho quando alguém mexe
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['manutencoes','historico','compras','cotacoes','ordens','fornecedores','veiculos','profiles','config'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when others then null;
    end;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- ALÇADA INDIVIDUAL (opcional; em branco vale a do perfil)
-- Aplicado no projeto como migração "alcada_individual".
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists alcada numeric(12,2);
-- funções _alcada_de, aprovar, reprovar e salvar_usuario atualizadas na migração.
