-- Controle de Poeira: tempo de dispensa por chuva escolhido pelo operador (6 ou 12 horas)
-- Rodar uma vez no SQL Editor do Supabase, depois de chuva.sql.
-- Substitui molh_informar_chuva(text,bigint[],text) por uma versão com p_horas (padrão 12).

drop function if exists molh_informar_chuva(text, bigint[], text);

create or replace function molh_informar_chuva(p_token text, p_pontos bigint[], p_obs text default '', p_horas integer default 12)
returns bigint language plpgsql security definer
set search_path = public as $$
declare u molh_usuarios; nid bigint; validos bigint[];
begin
  u := molh__sessao(p_token);
  if u.papel not in ('admin','operador') then raise exception 'SEM_PERMISSAO'; end if;
  if coalesce(p_horas, 12) not in (6, 12) then raise exception 'CHUVA_TEMPO_INVALIDO'; end if;
  select array_agg(distinct p.id) into validos
    from molh_pontos p where p.id = any(coalesce(p_pontos,'{}')) and p.ativo;
  if validos is null or array_length(validos,1) is null then raise exception 'CHUVA_SEM_PONTOS'; end if;
  insert into molh_chuvas(informada_em, dispensa_ate, obs, criado_por)
  values (now(), now() + make_interval(hours => coalesce(p_horas, 12)), left(coalesce(trim(p_obs),''),300), u.id)
  returning id into nid;
  insert into molh_chuva_pontos(chuva_id, ponto_id) select nid, unnest(validos);
  return nid;
end $$;

revoke all on function molh_informar_chuva(text,bigint[],text,integer) from public;
grant execute on function molh_informar_chuva(text,bigint[],text,integer) to anon;
