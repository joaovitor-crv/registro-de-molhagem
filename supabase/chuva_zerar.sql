-- Controle de Poeira: opção "Zerar horas" ao informar chuva
-- p_horas = 0  -> a chuva conta como uma molhagem no horário informado (o relógio do ponto recomeça)
-- p_horas = 6 ou 12 -> o ponto fica dispensado por esse tempo
-- Rodar uma vez no SQL Editor do Supabase, depois de chuva_tempo.sql.

alter table molh_chuvas add column if not exists zera_relogio boolean not null default false;

create or replace function molh_informar_chuva(p_token text, p_pontos bigint[], p_obs text default '', p_horas integer default 12)
returns bigint language plpgsql security definer
set search_path = public as $$
declare u molh_usuarios; nid bigint; validos bigint[]; h integer := coalesce(p_horas, 12);
begin
  u := molh__sessao(p_token);
  if u.papel not in ('admin','operador') then raise exception 'SEM_PERMISSAO'; end if;
  if h not in (0, 6, 12) then raise exception 'CHUVA_TEMPO_INVALIDO'; end if;
  select array_agg(distinct p.id) into validos
    from molh_pontos p where p.id = any(coalesce(p_pontos,'{}')) and p.ativo;
  if validos is null or array_length(validos,1) is null then raise exception 'CHUVA_SEM_PONTOS'; end if;
  insert into molh_chuvas(informada_em, dispensa_ate, obs, criado_por, zera_relogio)
  values (now(), now() + make_interval(hours => h), left(coalesce(trim(p_obs),''),300), u.id, h = 0)
  returning id into nid;
  insert into molh_chuva_pontos(chuva_id, ponto_id) select nid, unnest(validos);
  return nid;
end $$;

-- molh_dados: devolve também se a chuva zerou o relógio ("zera")
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
        'zera',c.zera_relogio,
        'pontos',coalesce((select jsonb_agg(cp.ponto_id) from molh_chuva_pontos cp where cp.chuva_id = c.id),'[]')
      ) order by c.informada_em desc)
      from molh_chuvas c left join molh_usuarios uc on uc.id = c.criado_por
      left join molh_usuarios ue on ue.id = c.encerrado_por
      where c.dispensa_ate > now() - make_interval(days => d)), '[]')
  );
end $$;

revoke all on function molh_informar_chuva(text,bigint[],text,integer) from public;
grant execute on function molh_informar_chuva(text,bigint[],text,integer), molh_dados(text,integer) to anon;
