-- =====================================================================
-- TRELAS QUEBRADAS e DISTRIBUIÇÃO DOS CAMINHÕES POR FRENTE (25/11/2026)
-- Abas novas do Controle de Poeira. Mesmo login e perfis:
--   administrador e operador registram e alteram; consulta só acompanha.
-- Pode rodar de novo sem perder dados.
-- =====================================================================

-- ---------- Tabelas ----------
create table if not exists molh_cam_frentes (
  id        bigint generated always as identity primary key,
  nome      text not null,
  ordem     integer not null default 0,
  ativo     boolean not null default true,
  criado_em timestamptz not null default now()
);

create table if not exists molh_caminhoes (
  id             bigint generated always as identity primary key,
  prefixo        text not null,
  descricao      text not null default '',
  ativo          boolean not null default true,
  frente_id      bigint references molh_cam_frentes(id),
  status         text not null default 'vazio' check (status in ('carregado','vazio','parado')),
  motivo         text not null default '',
  status_desde   timestamptz not null default now(),
  atualizado_por bigint references molh_usuarios(id),
  criado_em      timestamptz not null default now()
);
create unique index if not exists molh_caminhoes_prefixo_uk on molh_caminhoes (lower(prefixo)) where ativo;

-- cada troca de frente ou de situação fica registrada (para o "últimas mudanças" e o tempo em cada situação)
create table if not exists molh_caminhoes_hist (
  id          bigint generated always as identity primary key,
  caminhao_id bigint not null references molh_caminhoes(id) on delete cascade,
  frente_id   bigint references molh_cam_frentes(id),
  status      text not null,
  motivo      text not null default '',
  quando      timestamptz not null default now(),
  usuario_id  bigint references molh_usuarios(id)
);
create index if not exists molh_caminhoes_hist_quando_idx on molh_caminhoes_hist (quando desc);

create table if not exists molh_trelas (
  id            bigint generated always as identity primary key,
  caminhao_id   bigint not null references molh_caminhoes(id),
  trela         text not null default '',
  frente_id     bigint references molh_cam_frentes(id),
  local         text not null default '',
  motivo        text not null default '',
  quebrou_em    timestamptz not null,
  status        text not null default 'aberta' check (status in ('aberta','resolvida')),
  resolvido_em  timestamptz,
  solucao       text not null default '',
  responsavel   text not null default '',
  obs           text not null default '',
  criado_por    bigint references molh_usuarios(id),
  resolvido_por bigint references molh_usuarios(id),
  criado_em     timestamptz not null default now()
);
create index if not exists molh_trelas_quebrou_idx on molh_trelas (quebrou_em desc);

alter table molh_cam_frentes    enable row level security;
alter table molh_caminhoes      enable row level security;
alter table molh_caminhoes_hist enable row level security;
alter table molh_trelas         enable row level security;
revoke all on molh_cam_frentes, molh_caminhoes, molh_caminhoes_hist, molh_trelas from anon, authenticated;

-- frentes iniciais (só se ainda não houver nenhuma)
insert into molh_cam_frentes (nome, ordem)
select v.nome, v.ordem from (values ('Frente 1',1),('Frente 2',2),('Frente 3',3),('Frente 5',5),('Frente 6',6)) v(nome,ordem)
where not exists (select 1 from molh_cam_frentes);

-- ---------- Leitura ----------
create or replace function molh_cam_dados(p_token text, p_dias integer default 30)
returns jsonb language plpgsql security definer set search_path = 'public' as $$
declare u molh_usuarios; d integer := least(greatest(coalesce(p_dias,30),1),365);
begin
  u := molh__sessao(p_token);
  return jsonb_build_object(
    'frentes', coalesce((select jsonb_agg(jsonb_build_object('id',f.id,'nome',f.nome,'ordem',f.ordem) order by f.ordem, f.nome) from molh_cam_frentes f where f.ativo), '[]'::jsonb),
    'caminhoes', coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'prefixo',c.prefixo,'descricao',c.descricao,'frente_id',c.frente_id,'status',c.status,
        'motivo',c.motivo,'status_desde',c.status_desde,'atualizado_por',(select nome from molh_usuarios where id = c.atualizado_por)) order by c.prefixo)
      from molh_caminhoes c where c.ativo), '[]'::jsonb),
    'hist', coalesce((select jsonb_agg(x order by x->>'quando' desc) from (
        select jsonb_build_object('id',h.id,'caminhao_id',h.caminhao_id,'frente_id',h.frente_id,'status',h.status,'motivo',h.motivo,'quando',h.quando,
          'por',(select nome from molh_usuarios where id = h.usuario_id)) x
        from molh_caminhoes_hist h where h.quando > now() - interval '24 hours' order by h.quando desc limit 300) s), '[]'::jsonb),
    'trelas', coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'caminhao_id',t.caminhao_id,'trela',t.trela,'frente_id',t.frente_id,'local',t.local,'motivo',t.motivo,
        'quebrou_em',t.quebrou_em,'status',t.status,'resolvido_em',t.resolvido_em,'solucao',t.solucao,'responsavel',t.responsavel,'obs',t.obs,
        'criado_por',(select nome from molh_usuarios where id = t.criado_por),'resolvido_por',(select nome from molh_usuarios where id = t.resolvido_por)) order by t.quebrou_em desc)
      from molh_trelas t where t.status = 'aberta' or t.quebrou_em > now() - make_interval(days => d)), '[]'::jsonb),
    'caminhoes_todos', coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'prefixo',c.prefixo)) from molh_caminhoes c), '[]'::jsonb),
    'frentes_todas', coalesce((select jsonb_agg(jsonb_build_object('id',f.id,'nome',f.nome)) from molh_cam_frentes f), '[]'::jsonb));
end $$;

-- ---------- Cadastros (administrador e operador) ----------
create or replace function molh_cam_salvar_caminhao(p_token text, p_id bigint, p_prefixo text, p_descricao text)
returns bigint language plpgsql security definer set search_path = 'public' as $$
declare u molh_usuarios; nid bigint; pref text := left(trim(coalesce(p_prefixo,'')),20);
begin
  u := molh__sessao(p_token);
  if u.papel not in ('admin','operador') then raise exception 'SEM_PERMISSAO'; end if;
  if pref = '' then raise exception 'PREFIXO_VAZIO'; end if;
  if exists (select 1 from molh_caminhoes where ativo and lower(prefixo) = lower(pref) and id is distinct from p_id) then raise exception 'CAMINHAO_EXISTE'; end if;
  if p_id is null then
    insert into molh_caminhoes (prefixo, descricao, atualizado_por) values (pref, left(coalesce(trim(p_descricao),''),60), u.id) returning id into nid;
    insert into molh_caminhoes_hist (caminhao_id, status, usuario_id) values (nid, 'vazio', u.id);
    return nid;
  end if;
  update molh_caminhoes set prefixo = pref, descricao = left(coalesce(trim(p_descricao),''),60) where id = p_id and ativo;
  if not found then raise exception 'NAO_ENCONTRADO'; end if;
  return p_id;
end $$;

create or replace function molh_cam_remover_caminhao(p_token text, p_id bigint)
returns void language plpgsql security definer set search_path = 'public' as $$
declare u molh_usuarios;
begin
  u := molh__sessao(p_token);
  if u.papel not in ('admin','operador') then raise exception 'SEM_PERMISSAO'; end if;
  update molh_caminhoes set ativo = false where id = p_id;
end $$;

create or replace function molh_cam_salvar_frente(p_token text, p_id bigint, p_nome text, p_ordem integer)
returns bigint language plpgsql security definer set search_path = 'public' as $$
declare u molh_usuarios; nid bigint; n text := left(trim(coalesce(p_nome,'')),40);
begin
  u := molh__sessao(p_token);
  if u.papel not in ('admin','operador') then raise exception 'SEM_PERMISSAO'; end if;
  if n = '' then raise exception 'NOME_VAZIO'; end if;
  if p_id is null then
    insert into molh_cam_frentes (nome, ordem) values (n, coalesce(p_ordem, 0)) returning id into nid; return nid;
  end if;
  update molh_cam_frentes set nome = n, ordem = coalesce(p_ordem, ordem) where id = p_id and ativo;
  if not found then raise exception 'NAO_ENCONTRADO'; end if;
  return p_id;
end $$;

create or replace function molh_cam_remover_frente(p_token text, p_id bigint)
returns void language plpgsql security definer set search_path = 'public' as $$
declare u molh_usuarios;
begin
  u := molh__sessao(p_token);
  if u.papel not in ('admin','operador') then raise exception 'SEM_PERMISSAO'; end if;
  update molh_cam_frentes set ativo = false where id = p_id;
  -- os caminhões que estavam nela ficam "sem frente"
  update molh_caminhoes set frente_id = null where frente_id = p_id;
end $$;

-- ---------- Distribuição: frente e situação do caminhão ----------
create or replace function molh_cam_status(p_token text, p_id bigint, p_frente bigint, p_status text, p_motivo text)
returns void language plpgsql security definer set search_path = 'public' as $$
declare u molh_usuarios; c molh_caminhoes; mot text := left(coalesce(trim(p_motivo),''),80);
begin
  u := molh__sessao(p_token);
  if u.papel not in ('admin','operador') then raise exception 'SEM_PERMISSAO'; end if;
  if p_status not in ('carregado','vazio','parado') then raise exception 'STATUS_INVALIDO'; end if;
  if p_frente is not null and not exists (select 1 from molh_cam_frentes where id = p_frente and ativo) then raise exception 'FRENTE_INVALIDA'; end if;
  select * into c from molh_caminhoes where id = p_id and ativo for update;
  if c.id is null then raise exception 'NAO_ENCONTRADO'; end if;
  if p_status <> 'parado' then mot := ''; end if;
  if c.frente_id is not distinct from p_frente and c.status = p_status and c.motivo = mot then return; end if;
  update molh_caminhoes set frente_id = p_frente, status = p_status, motivo = mot, atualizado_por = u.id,
         status_desde = case when c.status = p_status then status_desde else now() end
   where id = c.id;
  insert into molh_caminhoes_hist (caminhao_id, frente_id, status, motivo, usuario_id) values (c.id, p_frente, p_status, mot, u.id);
end $$;

-- ---------- Trelas quebradas ----------
create or replace function molh_trela_registrar(p_token text, p_caminhao bigint, p_trela text, p_frente bigint, p_local text, p_motivo text,
  p_quando timestamptz, p_responsavel text, p_obs text, p_marcar_parado boolean default true)
returns bigint language plpgsql security definer set search_path = 'public' as $$
declare u molh_usuarios; c molh_caminhoes; nid bigint;
begin
  u := molh__sessao(p_token);
  if u.papel not in ('admin','operador') then raise exception 'SEM_PERMISSAO'; end if;
  select * into c from molh_caminhoes where id = p_caminhao and ativo;
  if c.id is null then raise exception 'CAMINHAO_INVALIDO'; end if;
  if p_frente is not null and not exists (select 1 from molh_cam_frentes where id = p_frente) then raise exception 'FRENTE_INVALIDA'; end if;
  if p_quando is null or p_quando > now() + interval '5 minutes' or p_quando < now() - interval '30 days' then raise exception 'DATA_INVALIDA'; end if;
  if coalesce(trim(p_local),'') = '' then raise exception 'LOCAL_VAZIO'; end if;
  insert into molh_trelas (caminhao_id, trela, frente_id, local, motivo, quebrou_em, responsavel, obs, criado_por)
  values (c.id, left(coalesce(trim(p_trela),''),40), p_frente, left(trim(p_local),120), left(coalesce(trim(p_motivo),''),60), p_quando,
          left(coalesce(trim(p_responsavel),''),80), left(coalesce(trim(p_obs),''),300), u.id)
  returning id into nid;
  if coalesce(p_marcar_parado, true) then
    perform molh_cam_status(p_token, c.id, coalesce(p_frente, c.frente_id), 'parado', 'Trela quebrada');
  end if;
  return nid;
end $$;

create or replace function molh_trela_resolver(p_token text, p_id bigint, p_quando timestamptz, p_solucao text, p_status_caminhao text default null)
returns void language plpgsql security definer set search_path = 'public' as $$
declare u molh_usuarios; t molh_trelas; c molh_caminhoes;
begin
  u := molh__sessao(p_token);
  if u.papel not in ('admin','operador') then raise exception 'SEM_PERMISSAO'; end if;
  select * into t from molh_trelas where id = p_id for update;
  if t.id is null then raise exception 'NAO_ENCONTRADO'; end if;
  if t.status <> 'aberta' then raise exception 'TRELA_RESOLVIDA'; end if;
  if p_quando is null or p_quando > now() + interval '5 minutes' or p_quando < t.quebrou_em then raise exception 'DATA_INVALIDA'; end if;
  update molh_trelas set status = 'resolvida', resolvido_em = p_quando, solucao = left(coalesce(trim(p_solucao),''),200), resolvido_por = u.id where id = t.id;
  -- volta o caminhão para a situação escolhida (se ainda estiver parado por trela)
  if p_status_caminhao in ('carregado','vazio') then
    select * into c from molh_caminhoes where id = t.caminhao_id and ativo;
    if c.id is not null and c.status = 'parado' then perform molh_cam_status(p_token, c.id, c.frente_id, p_status_caminhao, ''); end if;
  end if;
end $$;

create or replace function molh_trela_excluir(p_token text, p_id bigint)
returns void language plpgsql security definer set search_path = 'public' as $$
declare u molh_usuarios;
begin
  u := molh__sessao(p_token);
  if u.papel <> 'admin' then raise exception 'SEM_PERMISSAO'; end if;
  delete from molh_trelas where id = p_id;
end $$;

-- a API do site usa a chave pública (papel anon)
grant execute on function molh_cam_dados(text, integer), molh_cam_salvar_caminhao(text, bigint, text, text), molh_cam_remover_caminhao(text, bigint),
  molh_cam_salvar_frente(text, bigint, text, integer), molh_cam_remover_frente(text, bigint), molh_cam_status(text, bigint, bigint, text, text),
  molh_trela_registrar(text, bigint, text, bigint, text, text, timestamptz, text, text, boolean), molh_trela_resolver(text, bigint, timestamptz, text, text),
  molh_trela_excluir(text, bigint) to anon;

-- =====================================================================
-- 25/11/2026 (2ª parte): trelas do caminhão, caminhões 60500–60556 e
-- "Aguardando socorro" com reboque OU caminhão, números digitados.
-- =====================================================================
alter table molh_caminhoes add column if not exists trelas text not null default '';
insert into molh_caminhoes (prefixo)
select g::text from generate_series(60500, 60556) g
where not exists (select 1 from molh_caminhoes c where c.ativo and lower(c.prefixo) = g::text);
alter table molh_trelas alter column caminhao_id drop not null;
alter table molh_trelas add column if not exists tipo text not null default 'reboque';
alter table molh_trelas add column if not exists carga text not null default '';
-- funções novas: molh_cam_salvar_trelas e molh_socorro_registrar; molh_cam_dados devolve trelas, tipo e carga
-- (texto completo aplicado pelas migrações molh_caminhoes_trelas_cadastro e molh_socorro_reboque_caminhao no Supabase)

-- 25/11/2026 (3ª parte): situações carregando e base, observação do caminhão (molh_cam_obs),
-- observação limpa ao mudar situação/frente. Migração no Supabase: molh_caminhoes_carregando_base_obs.
-- 25/11/2026 (4ª parte): carga do caminhão parado (carregado/vazio) em molh_caminhoes.carga, molh_cam_carga;
-- molh_cam_status limpa obs e carga ao mudar situação/frente. Migração: molh_caminhoes_carga_parado.

-- 25/11/2026 (migração molh_socorro_aguardando_editar): reboque consertado aguardando caminhão e edição do socorro
alter table molh_trelas add column if not exists aguardando_caminhao_em timestamptz;
-- molh_trela_aguardando(p_token, p_id, p_aguardando boolean default true): marca/desmarca "consertada, aguardando caminhão" (só registros abertos)
-- molh_socorro_editar(p_token, p_id, p_trela, p_caminhao, p_frente, p_local, p_motivo, p_carga, p_quando): edita o registro (admin/operador)
-- molh_cam_dados passou a devolver aguardando_caminhao_em em cada trela.
