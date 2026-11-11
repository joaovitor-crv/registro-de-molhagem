-- Editar molhagem (11/11/2026): o administrador corrige um registro do Histórico
-- (ponto, frota, data e hora, motorista, responsável pela informação e observação).
-- Guarda quem editou e quando. Rodar uma vez no SQL Editor do Supabase.

alter table molh_molhagens add column if not exists editado_em  timestamptz;
alter table molh_molhagens add column if not exists editado_por bigint references molh_usuarios(id);

create or replace function molh_editar_molhagem(p_token text, p_id bigint, p_ponto bigint, p_frota bigint,
  p_quando timestamptz, p_motorista text, p_responsavel text, p_obs text)
returns bigint language plpgsql security definer
set search_path = public as $$
declare u molh_usuarios; m molh_molhagens;
begin
  u := molh__sessao(p_token);
  if u.papel <> 'admin' then raise exception 'SEM_PERMISSAO'; end if;
  select * into m from molh_molhagens where id = p_id for update;
  if m.id is null then raise exception 'NAO_ENCONTRADO'; end if;
  -- ponto e frota: os atuais podem ficar mesmo se foram removidos; para trocar, só ativos
  if p_ponto is distinct from m.ponto_id and not exists (select 1 from molh_pontos where id = p_ponto and ativo) then raise exception 'PONTO_INVALIDO'; end if;
  if p_frota is distinct from m.frota_id and not exists (select 1 from molh_frotas where id = p_frota and ativo) then raise exception 'FROTA_INVALIDA'; end if;
  if p_quando is null or p_quando > now() + interval '5 minutes' then raise exception 'DATA_INVALIDA'; end if;
  update molh_molhagens set
    ponto_id    = p_ponto,
    frota_id    = p_frota,
    quando      = p_quando,
    motorista   = left(coalesce(trim(p_motorista),''),80),
    responsavel = left(coalesce(trim(p_responsavel),''),80),
    obs         = left(coalesce(trim(p_obs),''),300),
    editado_em  = now(),
    editado_por = u.id
  where id = p_id;
  return p_id;
end $$;

grant execute on function molh_editar_molhagem(text,bigint,bigint,bigint,timestamptz,text,text,text) to anon;
notify pgrst, 'reload schema';
