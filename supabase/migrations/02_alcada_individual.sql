-- Alçada individual por usuário (em branco = alçada do perfil).
alter table public.profiles add column if not exists alcada numeric(12,2);
create or replace function public._alcada_de(p_id uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select case when p.perfil = 'gestor' then null
              when p.alcada is not null then p.alcada
              else public._alcada(p.perfil) end
  from public.profiles p where p.id = p_id
$$;
revoke execute on function public._alcada_de(uuid) from public, anon, authenticated;
-- aprovar, reprovar e salvar_usuario passaram a usar _alcada_de e o campo alcada.
