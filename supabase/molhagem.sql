-- =====================================================================
-- CONTROLE DE MOLHAGEM — estrutura do banco (Supabase)
-- Cole este arquivo inteiro no Supabase > SQL Editor > New query > Run.
-- Pode rodar de novo sem perder dados (cria só o que falta).
-- Tudo usa o prefixo molh_ e não mexe nas tabelas do sistema fadiga.
--
-- ANTES DE RODAR: troque, lá no final, o usuário e a senha provisória
-- do administrador (procure por  >>> ADMINISTRADOR <<<).
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- Tabelas ----------
create table if not exists molh_usuarios (
  id          bigint generated always as identity primary key,
  usuario     text not null unique,
  nome        text not null,
  papel       text not null check (papel in ('admin','operador','consulta')),
  senha_hash  text not null,
  troca_senha boolean not null default true,
  ativo       boolean not null default true,
  criado_em   timestamptz not null default now()
);

create table if not exists molh_sessoes (
  token      text primary key,
  usuario_id bigint not null references molh_usuarios(id) on delete cascade,
  expira_em  timestamptz not null
);

create table if not exists molh_pontos (
  id            bigint generated always as identity primary key,
  nome          text not null,
  trecho        text not null default '',
  km            text not null default '',
  intervalo_min integer not null default 120 check (intervalo_min >= 15),
  ativo         boolean not null default true,
  criado_em     timestamptz not null default now()
);

create table if not exists molh_frotas (
  id           bigint generated always as identity primary key,
  prefixo      text not null,
  descricao    text not null default '',
  capacidade_l integer,
  ativo        boolean not null default true,
  criado_em    timestamptz not null default now()
);

create table if not exists molh_molhagens (
  id          bigint generated always as identity primary key,
  ponto_id    bigint not null references molh_pontos(id),
  frota_id    bigint not null references molh_frotas(id),
  quando      timestamptz not null,
  volume_l    integer,
  motorista   text not null default '',
  condicao    text not null default '',
  obs         text not null default '',
  criado_por  bigint references molh_usuarios(id),
  criado_em   timestamptz not null default now()
);
create index if not exists molh_molhagens_quando_idx on molh_molhagens (quando desc);
create index if not exists molh_molhagens_ponto_idx  on molh_molhagens (ponto_id, quando desc);

-- Frotas em trajeto: saída de um local (ex.: Base) até um ponto de molhagem
create table if not exists molh_trajetos (
  id            bigint generated always as identity primary key,
  frota_id      bigint not null references molh_frotas(id),
  destino_id    bigint not null references molh_pontos(id),
  origem        text not null default 'Base',
  saida         timestamptz not null,
  chegada       timestamptz,
  status        text not null default 'em_trajeto' check (status in ('em_trajeto','concluido','cancelado')),
  motorista     text not null default '',
  obs           text not null default '',
  criado_por    bigint references molh_usuarios(id),
  encerrado_por bigint references molh_usuarios(id),
  criado_em     timestamptz not null default now()
);
create unique index if not exists molh_trajetos_frota_ativa on molh_trajetos (frota_id) where status = 'em_trajeto';
create index if not exists molh_trajetos_saida_idx on molh_trajetos (saida desc);
alter table molh_molhagens add column if not exists trajeto_id bigint references molh_trajetos(id);

-- Ninguém acessa as tabelas direto pela internet: só pelas funções abaixo.
alter table molh_usuarios  enable row level security;
alter table molh_sessoes   enable row level security;
alter table molh_pontos    enable row level security;
alter table molh_frotas    enable row level security;
alter table molh_molhagens enable row level security;
alter table molh_trajetos  enable row level security;
revoke all on molh_usuarios, molh_sessoes, molh_pontos, molh_frotas, molh_molhagens, molh_trajetos from anon, authenticated;

-- ---------- Sessão (uso interno) ----------
create or replace function molh__sessao(p_token text)
returns molh_usuarios language plpgsql security definer
set search_path = public, extensions as $$
declare u molh_usuarios;
begin
  select us.* into u from molh_sessoes s join molh_usuarios us on us.id = s.usuario_id
   where s.token = p_token and s.expira_em > now() and us.ativo;
  if u.id is null then raise exception 'SESSAO_EXPIRADA'; end if;
  update molh_sessoes set expira_em = now() + interval '30 days' where token = p_token;
  return u;
end $$;

create or replace function molh__perfil(u molh_usuarios)
returns jsonb language sql immutable as $$
  select jsonb_build_object('id',u.id,'usuario',u.usuario,'nome',u.nome,'papel',u.papel,'troca_senha',u.troca_senha)
$$;

-- ---------- Regras de senha (uso interno) ----------
-- Mínimo 4 caracteres; letras e números bastam. Bloqueia senhas óbvias
-- (1234, 4321, 1111, abcd, senha...). O nome da pessoa pode ser usado como senha.
create or replace function molh__checar_senha(p_senha text, p_usuario text, p_nome text)
returns void language plpgsql immutable as $$
declare
  s text := lower(translate(coalesce(p_senha,''),'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇçÑñ','aaaaaaaaaaeeeeeeeeiiiiiiiioooooooooouuuuuuuuccnn'));
  nome text := lower(translate(coalesce(p_nome,''),'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇçÑñ','aaaaaaaaaaeeeeeeeeiiiiiiiioooooooooouuuuuuuuccnn'));
  login text := lower(coalesce(p_usuario,''));
  parte text; i int; passo int; seq boolean;
begin
  if length(s) < 4 then raise exception 'SENHA_CURTA'; end if;
  -- todos os caracteres iguais (1111, aaaa)
  if s ~ '^(.)\1*$' then raise exception 'SENHA_FRACA'; end if;
  -- sequência crescente ou decrescente (1234, 4321, abcd, 987654)
  if s ~ '^[0-9]+$' or s ~ '^[a-z]+$' then
    passo := ascii(substr(s,2,1)) - ascii(substr(s,1,1));
    if passo in (1,-1) then
      seq := true;
      for i in 2..length(s)-1 loop
        if ascii(substr(s,i+1,1)) - ascii(substr(s,i,1)) <> passo then seq := false; exit; end if;
      end loop;
      if seq then raise exception 'SENHA_FRACA'; end if;
    end if;
  end if;
  -- senhas conhecidas demais
  if s in ('senha','senha1','senha12','senha123','password','qwerty','qwer','asdf','abc123','admin','admin1','admin123',
           'molhagem','pipa','teste','teste1','teste123','mudar','mudar123','1q2w3e','1q2w3e4r','102030','112233','121212','123123')
    then raise exception 'SENHA_FRACA'; end if;
end $$;

-- ---------- Login / senha ----------
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
  delete from molh_sessoes where expira_em < now();
  t := encode(gen_random_bytes(32), 'hex');
  insert into molh_sessoes(token, usuario_id, expira_em) values (t, u.id, now() + interval '30 days');
  return jsonb_build_object('token', t, 'perfil', molh__perfil(u));
end $$;

create or replace function molh_sair(p_token text)
returns void language sql security definer
set search_path = public as $$ delete from molh_sessoes where token = p_token $$;

create or replace function molh_trocar_senha(p_token text, p_atual text, p_nova text)
returns jsonb language plpgsql security definer
set search_path = public, extensions as $$
declare u molh_usuarios;
begin
  u := molh__sessao(p_token);
  if u.senha_hash <> crypt(coalesce(p_atual,''), u.senha_hash) then raise exception 'SENHA_ATUAL_ERRADA'; end if;
  if p_nova = p_atual then raise exception 'SENHA_IGUAL'; end if;
  perform molh__checar_senha(p_nova, u.usuario, u.nome);
  update molh_usuarios set senha_hash = crypt(p_nova, gen_salt('bf')), troca_senha = false where id = u.id
  returning * into u;
  return molh__perfil(u);
end $$;

-- ---------- Leitura ----------
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
      where t.status = 'em_trajeto' or t.saida > now() - interval '24 hours'), '[]')
  );
end $$;

-- ---------- Molhagens ----------
create or replace function molh_registrar(p_token text, p_ponto bigint, p_frota bigint, p_quando timestamptz,
  p_volume integer, p_motorista text, p_condicao text, p_obs text)
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
  insert into molh_molhagens(ponto_id, frota_id, quando, volume_l, motorista, condicao, obs, criado_por, trajeto_id)
  values (p_ponto, p_frota, p_quando, p_volume, left(coalesce(trim(p_motorista),''),80),
          left(coalesce(p_condicao,''),40), left(coalesce(trim(p_obs),''),300), u.id, tid)
  returning id into nid;
  return nid;
end $$;

create or replace function molh_excluir_molhagem(p_token text, p_id bigint)
returns void language plpgsql security definer
set search_path = public as $$
declare u molh_usuarios; dono bigint;
begin
  u := molh__sessao(p_token);
  select criado_por into dono from molh_molhagens where id = p_id;
  if not found then raise exception 'NAO_ENCONTRADO'; end if;
  if u.papel <> 'admin' and not (u.papel = 'operador' and dono = u.id) then raise exception 'SEM_PERMISSAO'; end if;
  delete from molh_molhagens where id = p_id;
end $$;

-- ---------- Trajetos ----------
create or replace function molh_iniciar_trajeto(p_token text, p_frota bigint, p_destino bigint, p_origem text,
  p_saida timestamptz, p_motorista text, p_obs text)
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
  insert into molh_trajetos(frota_id, destino_id, origem, saida, motorista, obs, criado_por)
  values (p_frota, p_destino, coalesce(nullif(left(trim(p_origem),60),''),'Base'), p_saida,
          left(coalesce(trim(p_motorista),''),80), left(coalesce(trim(p_obs),''),300), u.id)
  returning id into nid;
  return nid;
end $$;

-- Fecha o trajeto e registra a molhagem no ponto de destino
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
  insert into molh_molhagens(ponto_id, frota_id, quando, motorista, obs, criado_por, trajeto_id)
  values (t.destino_id, t.frota_id, p_chegada, t.motorista,
          left(coalesce(nullif(trim(p_obs),''), t.obs),300), u.id, t.id)
  returning id into nid;
  return nid;
end $$;

create or replace function molh_cancelar_trajeto(p_token text, p_id bigint)
returns void language plpgsql security definer
set search_path = public as $$
declare u molh_usuarios; t molh_trajetos;
begin
  u := molh__sessao(p_token);
  if u.papel not in ('admin','operador') then raise exception 'SEM_PERMISSAO'; end if;
  select * into t from molh_trajetos where id = p_id for update;
  if t.id is null then raise exception 'NAO_ENCONTRADO'; end if;
  if t.status <> 'em_trajeto' then raise exception 'TRAJETO_ENCERRADO'; end if;
  update molh_trajetos set status = 'cancelado', encerrado_por = u.id where id = t.id;
end $$;

-- ---------- Cadastros (criar: admin e operador; alterar e remover: admin) ----------
create or replace function molh_salvar_ponto(p_token text, p_id bigint, p_nome text, p_trecho text, p_km text, p_intervalo integer)
returns bigint language plpgsql security definer
set search_path = public as $$
declare u molh_usuarios; nid bigint;
begin
  u := molh__sessao(p_token);
  -- operador pode criar; alterar continua só com o administrador
  if not (u.papel = 'admin' or (u.papel = 'operador' and p_id is null)) then raise exception 'SEM_PERMISSAO'; end if;
  if coalesce(trim(p_nome),'') = '' then raise exception 'NOME_VAZIO'; end if;
  if coalesce(p_intervalo,0) < 15 then raise exception 'INTERVALO_INVALIDO'; end if;
  if p_id is null then
    insert into molh_pontos(nome, trecho, km, intervalo_min)
    values (left(trim(p_nome),80), left(coalesce(trim(p_trecho),''),60), left(coalesce(trim(p_km),''),30), p_intervalo)
    returning id into nid;
  else
    update molh_pontos set nome = left(trim(p_nome),80), trecho = left(coalesce(trim(p_trecho),''),60),
      km = left(coalesce(trim(p_km),''),30), intervalo_min = p_intervalo where id = p_id and ativo returning id into nid;
    if nid is null then raise exception 'NAO_ENCONTRADO'; end if;
  end if;
  return nid;
end $$;

create or replace function molh_remover_ponto(p_token text, p_id bigint)
returns void language plpgsql security definer
set search_path = public as $$
declare u molh_usuarios;
begin
  u := molh__sessao(p_token);
  if u.papel <> 'admin' then raise exception 'SEM_PERMISSAO'; end if;
  update molh_pontos set ativo = false where id = p_id;   -- o histórico continua guardado
end $$;

create or replace function molh_salvar_frota(p_token text, p_id bigint, p_prefixo text, p_descricao text, p_capacidade integer)
returns bigint language plpgsql security definer
set search_path = public as $$
declare u molh_usuarios; nid bigint;
begin
  u := molh__sessao(p_token);
  -- operador pode criar; alterar continua só com o administrador
  if not (u.papel = 'admin' or (u.papel = 'operador' and p_id is null)) then raise exception 'SEM_PERMISSAO'; end if;
  if coalesce(trim(p_prefixo),'') = '' then raise exception 'PREFIXO_VAZIO'; end if;
  if p_id is null then
    insert into molh_frotas(prefixo, descricao, capacidade_l)
    values (upper(left(trim(p_prefixo),20)), left(coalesce(trim(p_descricao),''),60), p_capacidade)
    returning id into nid;
  else
    update molh_frotas set prefixo = upper(left(trim(p_prefixo),20)), descricao = left(coalesce(trim(p_descricao),''),60),
      capacidade_l = p_capacidade where id = p_id and ativo returning id into nid;
    if nid is null then raise exception 'NAO_ENCONTRADO'; end if;
  end if;
  return nid;
end $$;

create or replace function molh_remover_frota(p_token text, p_id bigint)
returns void language plpgsql security definer
set search_path = public as $$
declare u molh_usuarios;
begin
  u := molh__sessao(p_token);
  if u.papel <> 'admin' then raise exception 'SEM_PERMISSAO'; end if;
  update molh_frotas set ativo = false where id = p_id;
end $$;

-- ---------- Usuários (admin) ----------
create or replace function molh_usuarios_lista(p_token text)
returns jsonb language plpgsql security definer
set search_path = public as $$
declare u molh_usuarios;
begin
  u := molh__sessao(p_token);
  if u.papel <> 'admin' then raise exception 'SEM_PERMISSAO'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',x.id,'usuario',x.usuario,'nome',x.nome,'papel',x.papel,
    'ativo',x.ativo,'troca_senha',x.troca_senha,'criado_em',x.criado_em) order by x.ativo desc, x.nome) from molh_usuarios x), '[]');
end $$;

-- p_id nulo cria; p_senha preenchida define senha provisória (a pessoa troca no próximo acesso)
create or replace function molh_salvar_usuario(p_token text, p_id bigint, p_usuario text, p_nome text,
  p_papel text, p_senha text, p_ativo boolean)
returns bigint language plpgsql security definer
set search_path = public, extensions as $$
declare u molh_usuarios; nid bigint; login text := lower(trim(coalesce(p_usuario,'')));
begin
  u := molh__sessao(p_token);
  if u.papel <> 'admin' then raise exception 'SEM_PERMISSAO'; end if;
  if login !~ '^[a-z0-9._-]{3,40}$' then raise exception 'USUARIO_INVALIDO'; end if;
  if coalesce(trim(p_nome),'') = '' then raise exception 'NOME_VAZIO'; end if;
  if p_papel not in ('admin','operador','consulta') then raise exception 'PAPEL_INVALIDO'; end if;
  if coalesce(p_senha,'') <> '' then perform molh__checar_senha(p_senha, login, p_nome); end if;
  if exists (select 1 from molh_usuarios where usuario = login and id is distinct from p_id) then raise exception 'USUARIO_EXISTE'; end if;
  if p_id is null then
    if coalesce(p_senha,'') = '' then raise exception 'SENHA_CURTA'; end if;
    insert into molh_usuarios(usuario, nome, papel, senha_hash, troca_senha, ativo)
    values (login, left(trim(p_nome),80), p_papel, crypt(p_senha, gen_salt('bf')), true, true)
    returning id into nid;
  else
    if p_id = u.id and (p_papel <> 'admin' or not coalesce(p_ativo,true)) then raise exception 'AUTO_ALTERACAO'; end if;
    update molh_usuarios set usuario = login, nome = left(trim(p_nome),80), papel = p_papel,
      ativo = coalesce(p_ativo, ativo),
      senha_hash = case when coalesce(p_senha,'') <> '' then crypt(p_senha, gen_salt('bf')) else senha_hash end,
      troca_senha = case when coalesce(p_senha,'') <> '' then true else troca_senha end
    where id = p_id returning id into nid;
    if nid is null then raise exception 'NAO_ENCONTRADO'; end if;
    if not coalesce(p_ativo,true) or coalesce(p_senha,'') <> '' then delete from molh_sessoes where usuario_id = p_id; end if;
  end if;
  return nid;
end $$;

-- ---------- Permissões das funções ----------
revoke execute on function molh__sessao(text) from public, anon, authenticated;
revoke execute on function molh__perfil(molh_usuarios) from public, anon, authenticated;
revoke execute on function molh__checar_senha(text,text,text) from public, anon, authenticated;
grant execute on function
  molh_login(text,text), molh_sair(text), molh_trocar_senha(text,text,text), molh_dados(text,integer),
  molh_registrar(text,bigint,bigint,timestamptz,integer,text,text,text), molh_excluir_molhagem(text,bigint),
  molh_salvar_ponto(text,bigint,text,text,text,integer), molh_remover_ponto(text,bigint),
  molh_salvar_frota(text,bigint,text,text,integer), molh_remover_frota(text,bigint),
  molh_usuarios_lista(text), molh_salvar_usuario(text,bigint,text,text,text,text,boolean),
  molh_iniciar_trajeto(text,bigint,bigint,text,timestamptz,text,text), molh_concluir_trajeto(text,bigint,timestamptz,text),
  molh_cancelar_trajeto(text,bigint)
to anon;

-- ---------- >>> ADMINISTRADOR <<< ----------
-- Troque 'admin' e 'TroqueEstaSenha1' antes de rodar. No primeiro acesso a página pede uma senha nova.
insert into molh_usuarios(usuario, nome, papel, senha_hash, troca_senha)
values ('admin', 'Administrador', 'admin', extensions.crypt('TroqueEstaSenha1', extensions.gen_salt('bf')), true)
on conflict (usuario) do nothing;

notify pgrst, 'reload schema';
