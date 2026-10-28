-- Controle de Poeira: ponto em stand-by (some do painel e dos PDFs, histórico preservado)
alter table molh_pontos add column if not exists pausado boolean not null default false;

create or replace function molh_pausar_ponto(p_token text, p_id bigint, p_pausar boolean)
returns void language plpgsql security definer
set search_path = public as $$
declare u molh_usuarios;
begin
  u := molh__sessao(p_token);
  if u.papel not in ('admin','operador') then raise exception 'SEM_PERMISSAO'; end if;
  update molh_pontos set pausado = coalesce(p_pausar, true) where id = p_id and ativo;
  if not found then raise exception 'NAO_ENCONTRADO'; end if;
end $$;

grant execute on function molh_pausar_ponto(text,bigint,boolean) to anon;
