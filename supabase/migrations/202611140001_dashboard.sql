begin;
create table public.dashboard_profiles (
  id uuid primary key references auth.users on delete cascade,
  display_name text not null check (length(trim(display_name)) between 1 and 160),
  role text not null check (role in ('responsable','comite','ministro','admin')),
  responsible_name text,
  active boolean not null default true,
  check ((role = 'responsable') = (responsible_name is not null))
);

create table public.dashboard_commitments (
  id bigint primary key,
  body jsonb not null check (
    jsonb_typeof(body) = 'object' and body ?& array['id','tema','personas','hitos','historial','draft']
    and (body->>'id')::bigint = id and jsonb_typeof(body->'personas') = 'array'
    and jsonb_typeof(body->'hitos') = 'array' and jsonb_typeof(body->'historial') = 'array'
    and jsonb_typeof(body->'draft') = 'object'
  ),
  version bigint not null default 1,
  updated_at timestamptz not null default now()
);

create table public.dashboard_audit (
  id bigint generated always as identity primary key,
  commitment_id bigint not null references public.dashboard_commitments,
  actor uuid,
  actor_role text not null,
  actor_name text not null,
  happened_at timestamptz not null default clock_timestamp(),
  field text not null,
  old_value jsonb,
  new_value jsonb,
  operation text not null
);
create index dashboard_audit_by_commitment on public.dashboard_audit(commitment_id, id desc);

create function public.dashboard_role() returns text
language sql stable security definer set search_path = ''
as $$ select role from public.dashboard_profiles where id = auth.uid() and active $$;

create function public.dashboard_visible(data jsonb) returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(case p.role
    when 'responsable' then (data->'personas') ? p.responsible_name
    when 'comite' then true
    when 'ministro' then true
    when 'admin' then true
    else false end, false)
  from public.dashboard_profiles p where p.id = auth.uid() and p.active
$$;

alter table public.dashboard_profiles enable row level security;
alter table public.dashboard_commitments enable row level security;
alter table public.dashboard_audit enable row level security;

create policy profile_select on public.dashboard_profiles for select to authenticated
using ((id = auth.uid() and active) or public.dashboard_role() = 'admin');
create policy profile_admin on public.dashboard_profiles for all to authenticated
using (public.dashboard_role() = 'admin') with check (public.dashboard_role() = 'admin');
create policy commitment_select on public.dashboard_commitments for select to authenticated
using (public.dashboard_visible(body));
create policy audit_select on public.dashboard_audit for select to authenticated
using (exists(select 1 from public.dashboard_commitments c where c.id = commitment_id));

revoke all on public.dashboard_profiles, public.dashboard_commitments, public.dashboard_audit from anon, authenticated;
grant select, insert, update, delete on public.dashboard_profiles to authenticated;
grant select on public.dashboard_commitments, public.dashboard_audit to authenticated;
revoke execute on function public.dashboard_role(), public.dashboard_visible(jsonb) from public;
grant execute on function public.dashboard_role(), public.dashboard_visible(jsonb) to authenticated;

create function public.dashboard_save(p_id bigint, p_version bigint, p_body jsonb)
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
  select * into profile from public.dashboard_profiles where id = auth.uid() and active;
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
revoke execute on function public.dashboard_save(bigint,bigint,jsonb) from public;
grant execute on function public.dashboard_save(bigint,bigint,jsonb) to authenticated;

create function public.dashboard_audit_change() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  profile public.dashboard_profiles;
  previous jsonb := '{}';
begin
  select * into profile from public.dashboard_profiles where id=auth.uid() and active;
  if tg_op='UPDATE' then previous := old.body; end if;
  insert into public.dashboard_audit(commitment_id,actor,actor_role,actor_name,field,old_value,new_value,operation)
  select new.id,profile.id,coalesce(profile.role,'sistema'),coalesce(profile.display_name,'Migración'),
    changes.key,previous->changes.key,new.body->changes.key,tg_op
  from (select jsonb_object_keys(previous) as key union select jsonb_object_keys(new.body)) changes
  where (previous->changes.key) is distinct from (new.body->changes.key);
  return new;
end
$$;
create trigger dashboard_log after insert or update of body on public.dashboard_commitments
for each row execute function public.dashboard_audit_change();

create function public.dashboard_can_read_id(p_id bigint) returns boolean
language sql stable security definer set search_path = ''
as $$ select exists(select 1 from public.dashboard_commitments c where c.id=p_id and public.dashboard_visible(c.body)) $$;
revoke execute on function public.dashboard_can_read_id(bigint) from public;
grant execute on function public.dashboard_can_read_id(bigint) to authenticated;

insert into storage.buckets (id,name,public,file_size_limit) values ('dashboard-documents','dashboard-documents',false,20971520);
create policy dashboard_documents_read on storage.objects for select to authenticated
using (bucket_id='dashboard-documents' and public.dashboard_can_read_id(
  case when split_part(name,'/',1) ~ '^[0-9]{1,15}$' then split_part(name,'/',1)::bigint end));
create policy dashboard_documents_insert on storage.objects for insert to authenticated
with check (bucket_id='dashboard-documents' and public.dashboard_role()='responsable' and
  public.dashboard_can_read_id(case when split_part(name,'/',1) ~ '^[0-9]{1,15}$' then split_part(name,'/',1)::bigint end));

create function public.dashboard_assign(p_id bigint, p_version bigint, p_names jsonb) returns void
language plpgsql security definer set search_path = ''
as $$
declare updated bigint;
begin
  if public.dashboard_role() is distinct from 'admin' then
    raise exception using errcode='42501',message='Operación reservada a administradores.';
  end if;
  if jsonb_typeof(p_names) is distinct from 'array' or jsonb_array_length(p_names)=0 or exists (
    select 1 from jsonb_array_elements_text(p_names) names(name)
    where not exists (select 1 from public.dashboard_profiles p
      where p.active and p.role='responsable' and p.responsible_name=names.name)
  ) then raise exception using errcode='22023',message='Seleccione responsables activos.'; end if;
  update public.dashboard_commitments
    set body=jsonb_set(jsonb_set(body,'{personas}',p_names),'{responsable}',
      to_jsonb(array_to_string(array(select jsonb_array_elements_text(p_names)),' / '))),
      version=version+1,updated_at=clock_timestamp()
    where id=p_id and version=p_version returning id into updated;
  if updated is null then raise exception using errcode='40001',message='La ficha cambió.'; end if;
end
$$;
revoke execute on function public.dashboard_assign(bigint,bigint,jsonb) from public;
grant execute on function public.dashboard_assign(bigint,bigint,jsonb) to authenticated;

alter publication supabase_realtime add table public.dashboard_commitments;
commit;
