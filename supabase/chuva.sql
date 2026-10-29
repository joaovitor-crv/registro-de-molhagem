-- Controle de Poeira: informativo de chuva
-- O operador marca os pontos onde choveu e confirma. Cada ponto fica dispensado de molhagem
-- por 12 horas a partir da confirmação (ou até alguém encerrar a dispensa antes).
-- Rodar uma vez no SQL Editor do Supabase, depois de molhagem.sql.

create table if not exists molh_chuvas (
  id            bigint generated always as identity primary key,
  informada_em  timestamptz not null default now(),
  dispensa_ate  timestamptz not null,
  obs           text not null default '',
  criado_por    bigint references molh_usuarios(id),
  encerrado_por bigint references molh_usuarios(id),
  encerrado_em  timestamptz,
  criado_em     timestamptz not null default now()
);

create table if not exists molh_chuva_pontos (
  chuva_id bigint not null references molh_chuvas(id) on delete cascade,
  ponto_id bigint not null references molh_pontos(id),
  primary key (chuva_id, ponto_id)
);
create index if not exists molh_chuva_pontos_ponto_idx on molh_chuva_pontos(ponto_id);
create index if not exists molh_chuvas_ate_idx on molh_chuvas(dispensa_ate);

alter table molh_chuvas       enable row level security;
alter table molh_chuva_pontos enable row level security;

-- Informar chuva nos pontos marcados: dispensa de 12 h
create or replace function molh_informar_chuva(p_token text, p_pontos bigint[], p_obs text default '')
returns bigint language plpgsql security definer
set search_path = public as $$
declare u molh_usuarios; nid bigint; validos bigint[];
begin
  u := molh__sessao(p_token);
  if u.papel not in ('admin','operador') then raise exception 'SEM_PERMISSAO'; end if;
  select array_agg(distinct p.id) into validos
    from molh_pontos p where p.id = any(coalesce(p_pontos,'{}')) and p.ativo;
  if validos is null or array_length(validos,1) is null then raise exception 'CHUVA_SEM_PONTOS'; end if;
  insert into molh_chuvas(informada_em, dispensa_ate, obs, criado_por)
  values (now(), now() + interval '12 hours', left(coalesce(trim(p_obs),''),300), u.id)
  returning id into nid;
  insert into molh_chuva_pontos(chuva_id, ponto_id) select nid, unnest(validos);
  return nid;
end $$;

-- Encerrar a dispensa antes das 12 h (os pontos voltam a contar a partir de agora)
create or replace function molh_encerrar_chuva(p_token text, p_id bigint)
returns void language plpgsql security definer
set search_path = public as $$
declare u molh_usuarios;
begin
  u := molh__sessao(p_token);
  if u.papel not in ('admin','operador') then raise exception 'SEM_PERMISSAO'; end if;
  update molh_chuvas set dispensa_ate = now(), encerrado_por = u.id, encerrado_em = now()
   where id = p_id and dispensa_ate > now();
  if not found then raise exception 'CHUVA_ENCERRADA'; end if;
end $$;

-- Excluir um informativo lançado por engano (admin, ou o operador que lançou)
create or replace function molh_excluir_chuva(p_token text, p_id bigint)
returns void language plpgsql security definer
set search_path = public as $$
declare u molh_usuarios; dono bigint;
begin
  u := molh__sessao(p_token);
  select criado_por into dono from molh_chuvas where id = p_id;
  if not found then raise exception 'NAO_ENCONTRADO'; end if;
  if u.papel <> 'admin' and not (u.papel = 'operador' and dono = u.id) then raise exception 'SEM_PERMISSAO'; end if;
  delete from molh_chuvas where id = p_id;
end $$;

-- molh_dados passa a devolver também as chuvas do período
create or replace function molh_dados(p_token text, p_dias integer default 60)
returns jsonb language plpgsql security definer
set search_path = public as $$
declare u molh_usuarios; d integer := least(greatest(coalesce(p_dias,60),1),400);
begin
  u := molh__sessao(p_token);
  return jsonb_build_object(
    'perfil', molh__perfil(u),
    'agora', now(),
    'pontos', coalesce((select jsonb_agg(to_jsonb(p) order by p.nome) from molh_pontos p where p.ativo), '[]'),
    'frotas', coalesce((select jsonb_agg(to_jsonb(f) order by f.prefixo) from molh_frotas f where f.ativo), '[]'),
    'molhagens', coalesce((select jsonb_agg(jsonb_build_object(
        'id',m.id,'ponto_id',m.ponto_id,'frota_id',m.frota_id,'quando',m.quando,'volume_l',m.volume_l,
        'motorista',m.motorista,'condicao',m.condicao,'obs',m.obs,'criado_por',m.criado_por,
        'lancado_por',coalesce(us.nome,''),'trajeto_id',m.trajeto_id,'saida',t.saida,'origem',t.origem) order by m.quando desc)
      from molh_molhagens m left join molh_usuarios us on us.id = m.criado_por
      left join molh_trajetos t on t.id = m.trajeto_id
      where m.quando > now() - make_interval(days => d)), '[]'),
    'trajetos', coalesce((select jsonb_agg(jsonb_build_object(
        'id',t.id,'frota_id',t.frota_id,'destino_id',t.destino_id,'origem',t.origem,'saida',t.saida,'chegada',t.chegada,
        'status',t.status,'motorista',t.motorista,'obs',t.obs,'criado_por',t.criado_por,'lancado_por',coalesce(us.nome,'')) order by t.saida desc)
      from molh_trajetos t left join molh_usuarios us on us.id = t.criado_por
      where t.status = 'em_trajeto' or t.saida > now() - interval '24 hours'), '[]'),
    'chuvas', coalesce((select jsonb_agg(jsonb_build_object(
        'id',c.id,'informada_em',c.informada_em,'dispensa_ate',c.dispensa_ate,'obs',c.obs,
        'criado_por',c.criado_por,'lancado_por',coalesce(uc.nome,''),
        'encerrado_em',c.encerrado_em,'encerrado_por',coalesce(ue.nome,''),
        'pontos',coalesce((select jsonb_agg(cp.ponto_id) from molh_chuva_pontos cp where cp.chuva_id = c.id),'[]')
      ) order by c.informada_em desc)
      from molh_chuvas c left join molh_usuarios uc on uc.id = c.criado_por
      left join molh_usuarios ue on ue.id = c.encerrado_por
      where c.dispensa_ate > now() - make_interval(days => d)), '[]')
  );
end $$;

grant execute on function
  molh_informar_chuva(text,bigint[],text), molh_encerrar_chuva(text,bigint), molh_excluir_chuva(text,bigint),
  molh_dados(text,integer)
to anon;
