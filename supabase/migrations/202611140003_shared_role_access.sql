begin;

alter table public.dashboard_profiles add column shared_access boolean not null default false;
alter table public.dashboard_profiles add constraint dashboard_shared_roles
  check (not shared_access or role in ('responsable','comite','ministro'));
create unique index dashboard_shared_role_account on public.dashboard_profiles(role) where shared_access;
alter table public.dashboard_audit add column identity_kind text not null default 'historica'
  check (identity_kind in ('historica','operativa','individual','sistema'));

create schema if not exists dashboard_private;
create table dashboard_private.operational_sessions (
  session_id uuid primary key references auth.sessions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  responsible_name text not null
);
alter table dashboard_private.operational_sessions enable row level security;
revoke all on schema dashboard_private from public, anon, authenticated;

create function dashboard_private.protect_shared_credentials() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if (new.email,new.phone,new.encrypted_password) is distinct from
      (old.email,old.phone,old.encrypted_password) and
      exists(select 1 from public.dashboard_profiles where id=old.id and active and shared_access) then
    raise exception using errcode='42501',message='Pause el perfil compartido para rotar sus credenciales.';
  end if;
  return new;
end
$$;
revoke execute on function dashboard_private.protect_shared_credentials() from public, anon, authenticated;
create trigger dashboard_protect_shared_credentials
before update of email,phone,encrypted_password on auth.users
for each row execute function dashboard_private.protect_shared_credentials();

create function dashboard_private.session_active() returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists(select 1 from auth.sessions s
    where s.id=(auth.jwt()->>'session_id')::uuid and s.user_id=auth.uid())
$$;
revoke execute on function dashboard_private.session_active() from public, anon, authenticated;

create function public.dashboard_effective_profile() returns public.dashboard_profiles
language plpgsql stable security definer set search_path = ''
as $$
declare
  profile public.dashboard_profiles;
begin
  select * into profile from public.dashboard_profiles where id=auth.uid() and active;
  if profile.shared_access and not dashboard_private.session_active() then return null; end if;
  if profile.shared_access and profile.role='responsable' then
    select s.responsible_name into profile.responsible_name
      from dashboard_private.operational_sessions s
      where s.user_id=profile.id and s.session_id=(auth.jwt()->>'session_id')::uuid;
    profile.display_name := profile.responsible_name;
  end if;
  return profile;
end
$$;
revoke execute on function public.dashboard_effective_profile() from public, anon, authenticated;

create or replace function public.dashboard_role() returns text
language sql stable security definer set search_path = ''
as $$ select (public.dashboard_effective_profile()).role $$;

create or replace function public.dashboard_visible(data jsonb) returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(case p.role
    when 'responsable' then (data->'personas') ? p.responsible_name
    when 'comite' then true
    when 'ministro' then true
    when 'admin' then true
    else false end, false)
  from public.dashboard_effective_profile() p
$$;

create function public.dashboard_responsible_options() returns text[]
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not dashboard_private.session_active() or not exists(select 1 from public.dashboard_profiles
      where id=auth.uid() and active and role='responsable' and shared_access) then
    raise exception using errcode='42501',message='Acceso reservado a responsables.';
  end if;
  return array(select distinct n.name
    from public.dashboard_commitments c cross join lateral jsonb_array_elements_text(c.body->'personas') n(name)
    where nullif(trim(n.name),'') is not null order by n.name);
end
$$;

create function public.dashboard_select_responsible(p_name text) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  current_session uuid := (auth.jwt()->>'session_id')::uuid;
begin
  if current_session is null or p_name is null or not (p_name=any(public.dashboard_responsible_options())) then
    raise exception using errcode='42501',message='Seleccione un responsable de la lista.';
  end if;
  insert into dashboard_private.operational_sessions(session_id,user_id,responsible_name)
    values(current_session,auth.uid(),p_name) on conflict(session_id) do nothing;
  if not exists(select 1 from dashboard_private.operational_sessions
      where session_id=current_session and user_id=auth.uid() and responsible_name=p_name) then
    raise exception using errcode='42501',message='Cierre la sesión para elegir otro responsable.';
  end if;
end
$$;
revoke execute on function public.dashboard_responsible_options(), public.dashboard_select_responsible(text) from public, anon;
grant execute on function public.dashboard_responsible_options(), public.dashboard_select_responsible(text) to authenticated;

create or replace function public.dashboard_save(p_id bigint, p_version bigint, p_body jsonb)
returns public.dashboard_commitments
language plpgsql security definer set search_path = ''
as $$
declare
  profile public.dashboard_profiles;
  current_row public.dashboard_commitments;
  previous jsonb;
  allowed text[];
  removed_history jsonb;
  appended_history jsonb;
  authorized boolean;
  stage text;
  next_stage text;
  instructions jsonb;
  conversation jsonb;
begin
  profile := public.dashboard_effective_profile();
  select * into current_row from public.dashboard_commitments where id = p_id for update;
  if profile.id is null or current_row.id is null or not coalesce(public.dashboard_visible(current_row.body), false)
     or profile.role not in ('responsable','comite','ministro') then
    raise exception using errcode = '42501', message = 'Operación no autorizada.';
  end if;
  if p_version is distinct from current_row.version then
    raise exception using errcode = '40001', message = 'Otra persona modificó esta ficha. Recargue la ficha para editar la última versión.';
  end if;
  previous := current_row.body;
  stage := previous->>'etapa';
  next_stage := p_body->>'etapa';
  if jsonb_typeof(p_body) is distinct from 'object'
     or jsonb_typeof(p_body->'historial') is distinct from 'array'
     or jsonb_typeof(p_body->'hitos') is distinct from 'array'
     or jsonb_array_length(p_body->'hitos') <> jsonb_array_length(previous->'hitos')
     or pg_column_size(p_body) > 4000000 then
    raise exception using errcode = '22023', message = 'Formato de ficha inválido.';
  end if;
  if profile.role = 'responsable' then
    allowed := array['historial','etapa','hitos','producto','fecha','fechaConfirmada','hitosConfirmados','draft',
      'resumenDespacho','resumenActualizado','pendienteEnvio','envioParaFecha','fechaEnvio','solicitudBase',
      'observacionComite','subsanacion','observacionAutor','observacionFecha','hitosObservados','hitosObservadosBase'];
    authorized := coalesce(previous#>>'{solicitudBase,estado}' = 'Autorizada' and
      (previous#>>'{solicitudBase,hasta}')::date >= (now() at time zone 'America/La_Paz')::date,false);
    if (p_body->'producto' is distinct from previous->'producto' or
        p_body->'draft' is distinct from previous->'draft') and not authorized and
       coalesce((previous->>'fechaConfirmada')::boolean,false) and coalesce((previous->>'hitosConfirmados')::boolean,false) then
      raise exception using errcode = '42501', message = 'El producto y los datos base requieren autorización.';
    end if;
    if not authorized and (
      (previous->>'fechaConfirmada' = 'true' and (p_body->'fecha' is distinct from previous->'fecha' or p_body->'fechaConfirmada' is distinct from previous->'fechaConfirmada'))
      or (previous->>'hitosConfirmados' = 'true' and (p_body->'hitosConfirmados' is distinct from previous->'hitosConfirmados'
        or jsonb_path_query_array(p_body, '$.hitos[*].nombre') <> jsonb_path_query_array(previous, '$.hitos[*].nombre')))) then
      raise exception using errcode = '42501', message = 'El cronograma confirmado requiere autorización.';
    end if;
    if next_stage is distinct from stage and coalesce(next_stage,'') not in ('Borrador','En revisión') then
      raise exception using errcode = '42501', message = 'El responsable no puede establecer esta etapa.';
    end if;
    if p_body->'solicitudBase' is distinct from previous->'solicitudBase' and not coalesce(
      ((p_body#>>'{solicitudBase,estado}') = 'Pendiente' and coalesce(previous#>>'{solicitudBase,estado}','') <> 'Pendiente')
      or (authorized and p_body->'solicitudBase' = jsonb_set(previous->'solicitudBase','{estado}','"Atendida"')), false) then
      raise exception using errcode = '42501', message = 'La autorización corresponde al Comité.';
    end if;
    if (p_body->>'observacionComite' is distinct from previous->>'observacionComite'
        or p_body->>'subsanacion' is distinct from previous->>'subsanacion'
        or p_body->>'observacionAutor' is distinct from previous->>'observacionAutor'
        or p_body->>'observacionFecha' is distinct from previous->>'observacionFecha'
        or p_body->'hitosObservados' is distinct from previous->'hitosObservados'
        or p_body->'hitosObservadosBase' is distinct from previous->'hitosObservadosBase')
       and not coalesce(next_stage = 'En revisión' and p_body->>'observacionComite' in ('') and
         p_body->>'subsanacion' in ('') and p_body->>'observacionAutor' in ('') and p_body->>'observacionFecha' in ('') and
         p_body->'hitosObservados' = '[]'::jsonb and p_body->'hitosObservadosBase' = '{}'::jsonb, false) then
      raise exception using errcode = '42501', message = 'La observación solo puede cerrarse al reenviar la ficha.';
    end if;
  elsif profile.role = 'comite' then
    allowed := array['historial','etapa','revisor','validador','publicado','solicitudBase','observacionComite',
      'subsanacion','observacionAutor','observacionFecha','hitosObservados','hitosObservadosBase'];
    if not coalesce((stage in ('En revisión','Observado') or previous#>>'{solicitudBase,estado}'='Pendiente') and
       (next_stage='Observado' or (next_stage='Validado' and stage='En revisión' and
       coalesce(previous#>>'{solicitudBase,estado}','')<>'Pendiente')),false) then
      raise exception using errcode='42501',message='La ficha no está disponible para esta revisión.';
    end if;
    if next_stage = 'Validado' and (p_body->'solicitudBase' is distinct from previous->'solicitudBase' or
      p_body#>'{publicado,hitos}' is distinct from previous->'hitos' or
      p_body#>'{publicado,producto}' is distinct from previous->'producto' or
      p_body#>'{publicado,fecha}' is distinct from previous->'fecha') then
      raise exception using errcode='42501',message='La publicación debe coincidir con la ficha remitida.';
    end if;
    if next_stage = 'Observado' and (
      p_body->'publicado' is distinct from previous->'publicado' or
      (p_body->'solicitudBase' is distinct from previous->'solicitudBase' and
       not coalesce(previous#>>'{solicitudBase,estado}'='Pendiente' and p_body#>>'{solicitudBase,estado}' in ('Autorizada','Respondida'),false))) then
      raise exception using errcode='42501',message='La observación no puede modificar la versión publicada ni una autorización cerrada.';
    end if;
  else
    allowed := array['historial','instrucciones'];
    instructions := coalesce(previous->'instrucciones','[]'::jsonb);
    if jsonb_typeof(p_body->'instrucciones') is distinct from 'array'
       or jsonb_array_length(p_body->'instrucciones') <> jsonb_array_length(instructions)+1
       or ((p_body->'instrucciones') - jsonb_array_length(instructions)) <> instructions
       or length(trim(coalesce(p_body#>>'{instrucciones,-1,texto}',''))) not between 1 and 4000 then
      raise exception using errcode='22023',message='Registre una instrucción nueva sin alterar las anteriores.';
    end if;
    p_body := jsonb_set(p_body,'{instrucciones}',instructions || jsonb_build_array(jsonb_build_object(
      'texto',p_body#>>'{instrucciones,-1,texto}','estado','Pendiente','actor',profile.display_name,'fecha',clock_timestamp())));
    if previous->'publicado' is null or previous->'publicado' = 'null'::jsonb then
      raise exception using errcode='42501',message='La ficha todavía no está publicada.';
    end if;
  end if;
  if (p_body - allowed) is distinct from (previous - allowed) then
    raise exception using errcode = '42501', message = 'La operación modifica campos fuera del perfil autorizado.';
  end if;
  select coalesce(jsonb_agg(entry order by ord),'[]') into removed_history
    from jsonb_array_elements(p_body->'historial') with ordinality as h(entry,ord)
    where ord <= jsonb_array_length(previous->'historial');
  if removed_history is distinct from previous->'historial' then
    raise exception using errcode='42501', message='El historial guardado es inmutable.';
  end if;
  select coalesce(jsonb_agg(entry || jsonb_build_object('actor',profile.display_name,'perfil',profile.role,'fecha',clock_timestamp())
    order by ord),'[]') into appended_history
    from jsonb_array_elements(p_body->'historial') with ordinality as h(entry,ord)
    where ord > jsonb_array_length(previous->'historial') and jsonb_typeof(entry)='object';
  p_body := jsonb_set(p_body,'{historial}',removed_history || appended_history);
  if p_body = previous then return current_row; end if;
  conversation := coalesce(previous->'seguimientoObservaciones','[]'::jsonb);
  if profile.role='comite' and next_stage='Observado' then
    p_body := jsonb_set(p_body,'{seguimientoObservaciones}', conversation || jsonb_build_array(jsonb_build_object(
      'estado','Pendiente','texto',p_body->>'observacionComite','plazo',p_body->>'subsanacion',
      'actor',profile.display_name,'fecha',clock_timestamp())));
  elsif profile.role='responsable' and stage='Observado' and next_stage='En revisión' then
    p_body := jsonb_set(p_body,'{seguimientoObservaciones}', conversation || jsonb_build_array(jsonb_build_object(
      'estado','Respondida','texto',p_body->>'resumenDespacho','actor',profile.display_name,'fecha',clock_timestamp())));
  elsif profile.role='comite' and next_stage='Validado' and jsonb_array_length(conversation)>0 then
    p_body := jsonb_set(p_body,'{seguimientoObservaciones}', conversation || jsonb_build_array(jsonb_build_object(
      'estado','Resuelta','actor',profile.display_name,'fecha',clock_timestamp())));
  end if;

  update public.dashboard_commitments set body=p_body, version=version+1, updated_at=clock_timestamp()
    where id=p_id returning * into current_row;
  return current_row;
end
$$;
create or replace function public.dashboard_audit_change() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  profile public.dashboard_profiles;
  previous jsonb := '{}';
begin
  profile := public.dashboard_effective_profile();
  if tg_op='UPDATE' then previous := old.body; end if;
  insert into public.dashboard_audit(commitment_id,actor,actor_role,actor_name,identity_kind,field,old_value,new_value,operation)
  select new.id,profile.id,coalesce(profile.role,'sistema'),coalesce(profile.display_name,'Migración'),
    case when profile.shared_access then 'operativa' when profile.id is not null then 'individual' else 'sistema' end,
    changes.key,previous->changes.key,new.body->changes.key,tg_op
  from (select jsonb_object_keys(previous) as key union select jsonb_object_keys(new.body)) changes
  where (previous->changes.key) is distinct from (new.body->changes.key);
  return new;
end
$$;

create or replace function public.dashboard_follow_instruction(p_id bigint,p_version bigint,p_index integer,p_state text,p_note text)
returns void language plpgsql security definer set search_path=''
as $$
declare
  profile public.dashboard_profiles;
  row_data public.dashboard_commitments;
  instruction jsonb;
  prior text;
  trail jsonb;
  change_data jsonb;
begin
  profile := public.dashboard_effective_profile();
  if profile.id is null or profile.role not in ('comite','ministro') then
    raise exception using errcode='42501',message='El seguimiento corresponde al Comité y al Despacho.';
  end if;
  select * into row_data from public.dashboard_commitments where id=p_id for update;
  if row_data.id is null then
    raise exception using errcode='22023',message='No se encontró la ficha.';
  end if;
  if p_version is distinct from row_data.version then
    raise exception using errcode='40001',message='Otra persona modificó esta ficha. Vuelva a abrirla.';
  end if;
  if p_index is null or p_index<0 then
    raise exception using errcode='22023',message='Seleccione una instrucción.';
  end if;
  instruction := row_data.body#>array['instrucciones',p_index::text];
  prior := instruction->>'estado';
  if instruction is null or p_state is null or p_note is null or length(btrim(p_note)) not between 1 and 2000 then
    raise exception using errcode='22023',message='Seleccione una instrucción e indique el motivo del cambio.';
  end if;
  if not coalesce(
      (prior='Pendiente' and p_state='En seguimiento')
      or (profile.role='ministro' and prior in ('Pendiente','En seguimiento') and p_state='Resuelta')
      or (profile.role='ministro' and prior='Resuelta' and p_state='En seguimiento'),false) then
    raise exception using errcode='42501',message='El cambio de estado no está permitido.';
  end if;
  trail := coalesce(instruction->'seguimiento','[]'::jsonb);
  change_data := jsonb_build_object('anterior',prior,'estado',p_state,'nota',btrim(p_note),
    'actor',profile.display_name,'rol',profile.role,'fecha',clock_timestamp());
  instruction := instruction || jsonb_build_object('estado',p_state,'seguimiento',trail||jsonb_build_array(change_data));
  update public.dashboard_commitments
    set body=jsonb_set(body,array['instrucciones',p_index::text],instruction),version=version+1,updated_at=clock_timestamp()
    where id=p_id;
end
$$;

create or replace function public.dashboard_follow_instruction(p_id bigint,p_version bigint,p_index integer,p_state text,p_note text)
returns void language plpgsql security definer set search_path=''
as $$
declare
  profile public.dashboard_profiles;
  row_data public.dashboard_commitments;
  instruction jsonb;
  prior text;
  trail jsonb;
  change_data jsonb;
begin
  profile := public.dashboard_effective_profile();
  if profile.id is null or profile.role not in ('comite','ministro') then
    raise exception using errcode='42501',message='El seguimiento corresponde al Comité y al Despacho.';
  end if;
  select * into row_data from public.dashboard_commitments where id=p_id for update;
  if row_data.id is null then
    raise exception using errcode='22023',message='No se encontró la ficha.';
  end if;
  if p_version is distinct from row_data.version then
    raise exception using errcode='40001',message='Otra persona modificó esta ficha. Vuelva a abrirla.';
  end if;
  if p_index is null or p_index<0 then
    raise exception using errcode='22023',message='Seleccione una instrucción.';
  end if;
  instruction := row_data.body#>array['instrucciones',p_index::text];
  prior := instruction->>'estado';
  if instruction is null or p_state is null or p_note is null or length(btrim(p_note)) not between 1 and 2000 then
    raise exception using errcode='22023',message='Seleccione una instrucción e indique el motivo del cambio.';
  end if;
  if not coalesce(
      (prior='Pendiente' and p_state='En seguimiento')
      or (profile.role='ministro' and prior in ('Pendiente','En seguimiento') and p_state='Resuelta')
      or (profile.role='ministro' and prior='Resuelta' and p_state='En seguimiento'),false) then
    raise exception using errcode='42501',message='El cambio de estado no está permitido.';
  end if;
  trail := coalesce(instruction->'seguimiento','[]'::jsonb);
  change_data := jsonb_build_object('anterior',prior,'estado',p_state,'nota',btrim(p_note),
    'actor',profile.display_name,'rol',profile.role,'fecha',clock_timestamp());
  instruction := instruction || jsonb_build_object('estado',p_state,'seguimiento',trail||jsonb_build_array(change_data));
  update public.dashboard_commitments
    set body=jsonb_set(body,array['instrucciones',p_index::text],instruction),version=version+1,updated_at=clock_timestamp()
    where id=p_id;
end
$$;
commit;
