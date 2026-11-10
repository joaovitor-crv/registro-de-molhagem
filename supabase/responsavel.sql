-- Responsável pela informação (10/11/2026): quem passou a informação da molhagem ou da saída da frota
-- (ex.: motorista pelo rádio, encarregado). Fica na molhagem e no trajeto; ao concluir o trajeto, passa para a molhagem.
-- Rodar uma vez no SQL Editor do Supabase. Compatível com a página antiga (o parâmetro novo é opcional).

alter table molh_molhagens add column if not exists responsavel text not null default '';
alter table molh_trajetos  add column if not exists responsavel text not null default '';

-- Funções com o parâmetro novo (a assinatura antiga sai para não haver duas versões)
drop function if exists molh_registrar(text,bigint,bigint,timestamptz,integer,text,text,text);
create or replace function molh_registrar(p_token text, p_ponto bigint, p_frota bigint, p_quando timestamptz,
  p_volume integer, p_motorista text, p_condicao text, p_obs text, p_responsavel text default null)
returns bigint language plpgsql security definer
set search_path = public as $$
declare u molh_usuarios; nid bigint; tid bigint;
begin
  u := molh__sessao(p_token);
  if u.papel not in ('admin','operador') then raise exception 'SEM_PERMISSAO'; end if;
  if not exists (select 1 from molh_pontos where id = p_ponto and ativo) then raise exception 'PONTO_INVALIDO'; end if;
  if not exists (select 1 from molh_frotas where id = p_frota and ativo) then raise exception 'FROTA_INVALIDA'; end if;
  if p_quando is null or p_quando > now() + interval '5 minutes' then raise exception 'DATA_INVALIDA'; end if;
  if p_volume is not null and (p_volume < 0 or p_volume > 100000) then raise exception 'VOLUME_INVALIDO'; end if;
  -- Se a frota estava em trajeto, a molhagem lançada direto encerra o trajeto
  select id into tid from molh_trajetos
   where frota_id = p_frota and status = 'em_trajeto' and saida <= p_quando for update;
  if tid is not null then
    update molh_trajetos set status = 'concluido', chegada = p_quando, encerrado_por = u.id where id = tid;
  end if;
  insert into molh_molhagens(ponto_id, frota_id, quando, volume_l, motorista, condicao, obs, criado_por, trajeto_id, responsavel)
  values (p_ponto, p_frota, p_quando, p_volume, left(coalesce(trim(p_motorista),''),80),
          left(coalesce(p_condicao,''),40), left(coalesce(trim(p_obs),''),300), u.id, tid,
          left(coalesce(trim(p_responsavel),''),80))
  returning id into nid;
  return nid;
end $$;

drop function if exists molh_iniciar_trajeto(text,bigint,bigint,text,timestamptz,text,text);
create or replace function molh_iniciar_trajeto(p_token text, p_frota bigint, p_destino bigint, p_origem text,
  p_saida timestamptz, p_motorista text, p_obs text, p_responsavel text default null)
returns bigint language plpgsql security definer
set search_path = public as $$
declare u molh_usuarios; nid bigint;
begin
  u := molh__sessao(p_token);
  if u.papel not in ('admin','operador') then raise exception 'SEM_PERMISSAO'; end if;
  if not exists (select 1 from molh_frotas where id = p_frota and ativo) then raise exception 'FROTA_INVALIDA'; end if;
  if not exists (select 1 from molh_pontos where id = p_destino and ativo) then raise exception 'PONTO_INVALIDO'; end if;
  if p_saida is null or p_saida > now() + interval '5 minutes' then raise exception 'DATA_INVALIDA'; end if;
  if exists (select 1 from molh_trajetos where frota_id = p_frota and status = 'em_trajeto') then raise exception 'FROTA_EM_TRAJETO'; end if;
  insert into molh_trajetos(frota_id, destino_id, origem, saida, motorista, obs, criado_por, responsavel)
  values (p_frota, p_destino, coalesce(nullif(left(trim(p_origem),60),''),'Base'), p_saida,
          left(coalesce(trim(p_motorista),''),80), left(coalesce(trim(p_obs),''),300), u.id,
          left(coalesce(trim(p_responsavel),''),80))
  returning id into nid;
  return nid;
end $$;

-- Ao confirmar a chegada, a molhagem leva o responsável da saída
create or replace function molh_concluir_trajeto(p_token text, p_id bigint, p_chegada timestamptz, p_obs text)
returns bigint language plpgsql security definer
set search_path = public as $$
declare u molh_usuarios; t molh_trajetos; nid bigint;
begin
  u := molh__sessao(p_token);
  if u.papel not in ('admin','operador') then raise exception 'SEM_PERMISSAO'; end if;
  select * into t from molh_trajetos where id = p_id for update;
  if t.id is null then raise exception 'NAO_ENCONTRADO'; end if;
  if t.status <> 'em_trajeto' then raise exception 'TRAJETO_ENCERRADO'; end if;
  if p_chegada is null or p_chegada > now() + interval '5 minutes' or p_chegada < t.saida then raise exception 'CHEGADA_INVALIDA'; end if;
  update molh_trajetos set status = 'concluido', chegada = p_chegada, encerrado_por = u.id where id = t.id;
  insert into molh_molhagens(ponto_id, frota_id, quando, motorista, obs, criado_por, trajeto_id, responsavel)
  values (t.destino_id, t.frota_id, p_chegada, t.motorista,
          left(coalesce(nullif(trim(p_obs),''), t.obs),300), u.id, t.id, t.responsavel)
  returning id into nid;
  return nid;
end $$;

-- Dados do painel: inclui o responsável nas molhagens e nos trajetos
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
        'lancado_por',coalesce(us.nome,''),'trajeto_id',m.trajeto_id,'saida',t.saida,'origem',t.origem,
        'responsavel',m.responsavel) order by m.quando desc)
      from molh_molhagens m left join molh_usuarios us on us.id = m.criado_por
      left join molh_trajetos t on t.id = m.trajeto_id
      where m.quando > now() - make_interval(days => d)), '[]'),
    'trajetos', coalesce((select jsonb_agg(jsonb_build_object(
        'id',t.id,'frota_id',t.frota_id,'destino_id',t.destino_id,'origem',t.origem,'saida',t.saida,'chegada',t.chegada,
        'status',t.status,'motorista',t.motorista,'obs',t.obs,'criado_por',t.criado_por,'lancado_por',coalesce(us.nome,''),
        'responsavel',t.responsavel) order by t.saida desc)
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

-- mesmas permissões das versões anteriores
grant execute on function
  molh_registrar(text,bigint,bigint,timestamptz,integer,text,text,text,text),
  molh_iniciar_trajeto(text,bigint,bigint,text,timestamptz,text,text,text),
  molh_concluir_trajeto(text,bigint,timestamptz,text),
  molh_dados(text,integer) to anon, authenticated, service_role;
notify pgrst, 'reload schema';
