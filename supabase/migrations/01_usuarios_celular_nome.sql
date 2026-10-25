-- Nome e celular no perfil; o cadastro pelo app envia nome/telefone nos metadados.
alter table public.profiles add column if not exists telefone text not null default '';
-- (função _novo_usuario já atualizada em schema.sql)
