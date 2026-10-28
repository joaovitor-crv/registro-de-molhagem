-- Controle de Poeira: excluir usuário (rodar uma vez no SQL Editor do Supabase)
alter table molh_usuarios add column if not exists excluido boolean not null default false;

create or replace function molh_usuarios_lista(p_token text)
returns jsonb language plpgsql security definer
set search_path = public as $$
declare u molh_usuarios;
begin
  u := molh__sessao(p_token);
  if u.papel <> 'admin' then raise exception 'SEM_PERMISSAO'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',x.id,'usuario',x.usuario,'nome',x.nome,'papel',x.papel,
    'ativo',x.ativo,'troca_senha',x.troca_senha,'criado_em',x.criado_em) order by x.ativo desc, x.nome)
    from molh_usuarios x where not x.excluido), '[]');
end $$;

-- Sem lançamentos: apaga de vez. Com lançamentos: some da lista e perde o acesso,
-- mas o nome continua aparecendo em "Lançado por" no histórico. O login fica livre para reuso.
create or replace function molh_excluir_usuario(p_token text, p_id bigint)
returns void language plpgsql security definer
set search_path = public as $$
declare u molh_usuarios;
begin
  u := molh__sessao(p_token);
  if u.papel <> 'admin' then raise exception 'SEM_PERMISSAO'; end if;
  if p_id = u.id then raise exception 'AUTO_EXCLUSAO'; end if;
  if not exists (select 1 from molh_usuarios where id = p_id and not excluido) then raise exception 'NAO_ENCONTRADO'; end if;
  delete from molh_sessoes where usuario_id = p_id;
  if exists (select 1 from molh_molhagens where criado_por = p_id)
     or exists (select 1 from molh_trajetos where criado_por = p_id or encerrado_por = p_id) then
    update molh_usuarios set excluido = true, ativo = false, usuario = usuario || '~' || id where id = p_id;
  else
    delete from molh_usuarios where id = p_id;
  end if;
end $$;

grant execute on function molh_excluir_usuario(text,bigint) to anon;
