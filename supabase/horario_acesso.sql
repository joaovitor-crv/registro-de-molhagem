-- Controle de Poeira: horário de acesso por usuário (operador e consulta).
-- Sem horário definido = acesso livre. Administradores sempre entram.
-- Turno que passa da meia-noite (ex.: 22:00 às 06:00) vale pelo dia em que começa.
alter table molh_usuarios add column if not exists acesso_inicio time;
alter table molh_usuarios add column if not exists acesso_fim time;
alter table molh_usuarios add column if not exists acesso_dias smallint[];  -- 0=dom ... 6=sáb; nulo = todos os dias

create or replace function molh__horario_txt(u molh_usuarios)
returns text language sql immutable as $$
  select case when u.acesso_inicio is null and u.acesso_dias is null then null else
    coalesce(to_char(u.acesso_inicio,'HH24:MI')||' às '||to_char(u.acesso_fim,'HH24:MI'),'qualquer hora')
    || coalesce(' · '||(select string_agg((array['dom','seg','ter','qua','qui','sex','sáb'])[d+1], ', ' order by d)
                         from unnest(u.acesso_dias) d), '')
  end
$$;

create or replace function molh__no_horario(u molh_usuarios)
returns boolean language plpgsql stable as $$
declare agora timestamp := now() at time zone 'America/Sao_Paulo'; t time := agora::time;
        dia int := extract(dow from agora)::int;
begin
  if u.papel = 'admin' then return true; end if;
  if u.acesso_inicio is not null and u.acesso_fim is not null then
    if u.acesso_inicio <= u.acesso_fim then
      if t < u.acesso_inicio or t > u.acesso_fim then return false; end if;
    elsif t < u.acesso_inicio then          -- turno que vira a noite
      if t > u.acesso_fim then return false; end if;
      dia := (dia + 6) % 7;                 -- depois da meia-noite conta o dia anterior
    end if;
  end if;
  if u.acesso_dias is not null and not (dia = any(u.acesso_dias)) then return false; end if;
  return true;
end $$;

create or replace function molh__sessao(p_token text)
returns molh_usuarios language plpgsql security definer
set search_path = public, extensions as $$
declare u molh_usuarios;
begin
  select us.* into u from molh_sessoes s join molh_usuarios us on us.id = s.usuario_id
   where s.token = p_token and s.expira_em > now() and us.ativo;
  if u.id is null then raise exception 'SESSAO_EXPIRADA'; end if;
  if not molh__no_horario(u) then
    delete from molh_sessoes where token = p_token;
    raise exception 'FORA_HORARIO' using detail = coalesce(molh__horario_txt(u),'');
  end if;
  update molh_sessoes set expira_em = now() + interval '30 days' where token = p_token;
  return u;
end $$;

create or replace function molh_login(p_usuario text, p_senha text)
returns jsonb language plpgsql security definer
set search_path = public, extensions as $$
declare u molh_usuarios; t text;
begin
  select * into u from molh_usuarios where usuario = lower(trim(p_usuario)) and ativo;
  if u.id is null or u.senha_hash <> crypt(coalesce(p_senha,''), u.senha_hash) then
    perform pg_sleep(0.5);
    raise exception 'LOGIN_INVALIDO';
  end if;
  if not molh__no_horario(u) then
    raise exception 'FORA_HORARIO' using detail = coalesce(molh__horario_txt(u),'');
  end if;
  delete from molh_sessoes where expira_em < now();
  t := encode(gen_random_bytes(32), 'hex');
  insert into molh_sessoes(token, usuario_id, expira_em) values (t, u.id, now() + interval '30 days');
  return jsonb_build_object('token', t, 'perfil', molh__perfil(u));
end $$;

create or replace function molh_usuarios_lista(p_token text)
returns jsonb language plpgsql security definer
set search_path = public as $$
declare u molh_usuarios;
begin
  u := molh__sessao(p_token);
  if u.papel <> 'admin' then raise exception 'SEM_PERMISSAO'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',x.id,'usuario',x.usuario,'nome',x.nome,'papel',x.papel,
    'ativo',x.ativo,'troca_senha',x.troca_senha,'criado_em',x.criado_em,
    'acesso_inicio',to_char(x.acesso_inicio,'HH24:MI'),'acesso_fim',to_char(x.acesso_fim,'HH24:MI'),
    'acesso_dias',x.acesso_dias,'horario',molh__horario_txt(x)) order by x.ativo desc, x.nome)
    from molh_usuarios x where not x.excluido), '[]');
end $$;

-- p_inicio e p_fim no formato 'HH:MM' (os dois ou nenhum); p_dias nulo = todos os dias. Tudo nulo = acesso livre.
create or replace function molh_salvar_horario(p_token text, p_id bigint, p_inicio text, p_fim text, p_dias smallint[])
returns void language plpgsql security definer
set search_path = public as $$
declare u molh_usuarios; ini time; fim time; dias smallint[];
begin
  u := molh__sessao(p_token);
  if u.papel <> 'admin' then raise exception 'SEM_PERMISSAO'; end if;
  if p_id = u.id then raise exception 'AUTO_HORARIO'; end if;
  if (nullif(p_inicio,'') is null) <> (nullif(p_fim,'') is null) then raise exception 'HORARIO_INVALIDO'; end if;
  begin ini := nullif(p_inicio,'')::time; fim := nullif(p_fim,'')::time;
  exception when others then raise exception 'HORARIO_INVALIDO'; end;
  if ini is not null and ini = fim then raise exception 'HORARIO_INVALIDO'; end if;
  select array_agg(distinct d order by d) into dias from unnest(p_dias) d where d between 0 and 6;
  if p_dias is not null and dias is null then raise exception 'DIAS_VAZIO'; end if;
  if array_length(dias,1) = 7 then dias := null; end if;
  update molh_usuarios set acesso_inicio = ini, acesso_fim = fim, acesso_dias = dias
   where id = p_id and not excluido;
  if not found then raise exception 'NAO_ENCONTRADO'; end if;
end $$;

revoke execute on function molh__no_horario(molh_usuarios) from public, anon, authenticated;
revoke execute on function molh__horario_txt(molh_usuarios) from public, anon, authenticated;
grant execute on function molh_salvar_horario(text,bigint,text,text,smallint[]) to anon;
