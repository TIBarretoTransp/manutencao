-- DESTINO DA DEMANDA: tração, carreta ou estoque. Estoque não tem placa.
-- Aplicado no projeto barreto-manutencao em 25/10/2026.

alter table public.veiculos
  add column if not exists tipo text not null default 'tracao',
  add column if not exists marca text not null default '',
  add column if not exists ano_modelo text not null default '';
alter table public.veiculos add constraint veiculos_tipo_ck check (tipo in ('tracao','carreta'));

alter table public.manutencoes add column if not exists destino text not null default 'tracao';
alter table public.manutencoes alter column placa drop not null;
alter table public.manutencoes add constraint manut_destino_ck check (
  destino in ('tracao','carreta','estoque')
  and ((destino = 'estoque' and placa is null) or (destino <> 'estoque' and placa is not null)));
alter table public.ordens add column if not exists destino text not null default 'tracao';
alter table public.ordens alter column placa drop not null;

create or replace function public._checa_placa() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.destino = 'estoque' then new.placa := null; return new; end if;
  new.placa := upper(new.placa);
  if not exists (select 1 from public.veiculos where placa = new.placa and tipo = new.destino and ativo) then
    raise exception 'A placa % não está cadastrada como %.', new.placa, case new.destino when 'tracao' then 'tração' else 'carreta' end;
  end if;
  return new;
end $$;
revoke execute on function public._checa_placa() from public, anon, authenticated;
create or replace trigger checa_placa before insert or update of placa, destino on public.manutencoes
  for each row execute function public._checa_placa();

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
  insert into public.ordens (num, manutencao_id, compra_id, destino, placa, fornecedor_id, valor, tipo, emergencial, aprovado_por, regularizar_ate)
  values ('OC ' || lpad((v_ano % 100)::text, 2, '0') || '-' || lpad(v_n::text, 4, '0'),
          m.id, c.id, m.destino, m.placa, q.fornecedor_id, q.valor, c.tipo, p_emergencial, auth.uid(),
          case when p_emergencial then now() + make_interval(hours => v_prazo) end)
  returning id into v_id;
  update public.compras set status = 'aprovada', oc_id = v_id where id = c.id;
  return v_id;
end $$;
revoke execute on function public._gerar_oc(uuid, boolean) from public, anon, authenticated;

create or replace function public.abrir_demanda(p_destino text, p_placa text, p_descricao text, p_tipo text, p_prioridade text, p_fotos text[], p_emerg jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); v_m uuid; v_c uuid; v_q uuid; v_oc uuid; v_valor numeric; v_teto numeric; v_n int;
begin
  perform public._exigir(p_destino in ('tracao', 'carreta', 'estoque'), 'Escolha tração, carreta ou estoque.');
  perform public._exigir(p_destino = 'estoque' or coalesce(trim(p_placa), '') <> '', 'Escolha a placa.');
  perform public._exigir(coalesce(trim(p_descricao), '') <> '', 'Descreva o que é preciso.');
  perform public._exigir(p_destino = 'estoque' or exists (select 1 from public.veiculos where placa = upper(p_placa) and tipo = p_destino and ativo),
    format('A placa %s não está cadastrada como %s.', upper(p_placa), case p_destino when 'tracao' then 'tração' else 'carreta' end));
  if p_emerg is not null then
    perform public._exigir(coalesce((p_emerg->>'valor')::numeric, 0) > 0, 'Informe o valor da compra emergencial.');
    perform public._exigir(coalesce(trim(p_emerg->>'justificativa'), '') <> '', 'Diga por que a compra é emergencial.');
    perform public._exigir(exists (select 1 from public.fornecedores where id = nullif(p_emerg->>'fornecedor_id', '')::uuid), 'Escolha o fornecedor.');
  end if;
  insert into public.manutencoes (num, destino, placa, descricao, tipo, prioridade, prioridade_confirmada, aberto_por, atendido_por, fotos)
  values ('M-' || lpad(nextval('public.manut_seq')::text, 4, '0'), p_destino,
          case when p_destino = 'estoque' then null else upper(p_placa) end, trim(p_descricao), p_tipo,
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
revoke execute on function public.abrir_demanda(text, text, text, text, text, text[], jsonb) from public, anon;
grant execute on function public.abrir_demanda(text, text, text, text, text, text[], jsonb) to authenticated;
revoke execute on function public.criar_demanda(text, text, text, text, text[], jsonb) from authenticated;

create or replace function public.salvar_veiculo(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._eu(); v uuid := nullif(p->>'id', '')::uuid;
  pl text := upper(regexp_replace(coalesce(p->>'placa', ''), '[^A-Za-z0-9]', '', 'g'));
  tp text := coalesce(nullif(p->>'tipo', ''), 'tracao');
begin
  perform public._exigir(me.perfil in ('analista', 'gestor'), 'Só analista ou gestor cadastra veículos.');
  perform public._exigir(pl ~ '^[A-Z]{3}[0-9][A-Z0-9][0-9]{2}$', 'Placa inválida. Use o formato ABC1D23 ou ABC1234.');
  perform public._exigir(tp in ('tracao', 'carreta'), 'Escolha tração ou carreta.');
  if v is null then
    insert into public.veiculos (placa, tipo, marca, ano_modelo, descricao)
    values (pl, tp, coalesce(p->>'marca', ''), coalesce(p->>'ano_modelo', ''), '') returning id into v;
  else
    update public.veiculos set placa = pl, tipo = tp, marca = coalesce(p->>'marca', ''), ano_modelo = coalesce(p->>'ano_modelo', ''),
      ativo = coalesce((p->>'ativo')::boolean, true)
    where id = v;
  end if;
  return v;
end $$;
