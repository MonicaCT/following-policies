begin;

create table public.dashboard_units (
  code text primary key check (length(btrim(code)) between 1 and 160 and code=btrim(code)),
  label text not null check (length(btrim(label)) between 1 and 160),
  active boolean not null default true,
  version bigint not null default 1,
  updated_at timestamptz not null default clock_timestamp(),
  updated_by uuid not null
);
alter table public.dashboard_units enable row level security;
revoke all on public.dashboard_units from anon, authenticated;
grant select on public.dashboard_units to authenticated;
create policy dashboard_units_read on public.dashboard_units for select to authenticated
using (public.dashboard_role() is not null);

create function public.dashboard_save_unit(p_code text,p_label text,p_active boolean,p_version bigint)
returns void language plpgsql security definer set search_path=''
as $$
declare stored text;
begin
  if public.dashboard_role() is distinct from 'admin' then
    raise exception using errcode='42501',message='La administración de unidades requiere el perfil Administrador.';
  end if;
  if p_version is null then
    insert into public.dashboard_units(code,label,active,updated_by)
    values (btrim(p_code),btrim(p_label),p_active,auth.uid())
    on conflict (code) do nothing returning code into stored;
  else
    update public.dashboard_units set label=btrim(p_label),active=p_active,version=version+1,
      updated_at=clock_timestamp(),updated_by=auth.uid()
    where code=p_code and version=p_version returning code into stored;
  end if;
  if stored is null then
    raise exception using errcode='40001',message='Otra persona cambió el catálogo. Vuelva a abrirlo.';
  end if;
end
$$;
revoke execute on function public.dashboard_save_unit(text,text,boolean,bigint) from public;
grant execute on function public.dashboard_save_unit(text,text,boolean,bigint) to authenticated;

create function public.dashboard_set_unit(p_id bigint,p_version bigint,p_code text)
returns void language plpgsql security definer set search_path=''
as $$
declare stored bigint;
begin
  if public.dashboard_role() is distinct from 'admin' then
    raise exception using errcode='42501',message='La asignación de unidades requiere el perfil Administrador.';
  end if;
  if not exists (select 1 from public.dashboard_units where code=p_code and active) then
    raise exception using errcode='22023',message='Seleccione una unidad activa.';
  end if;
  update public.dashboard_commitments
    set body=jsonb_set(body,'{unidad}',to_jsonb(p_code)),version=version+1,updated_at=clock_timestamp()
    where id=p_id and version=p_version returning id into stored;
  if stored is null then
    raise exception using errcode='40001',message='Otra persona modificó esta ficha.';
  end if;
end
$$;
revoke execute on function public.dashboard_set_unit(bigint,bigint,text) from public;
grant execute on function public.dashboard_set_unit(bigint,bigint,text) to authenticated;

create function public.dashboard_follow_instruction(p_id bigint,p_version bigint,p_index integer,p_state text,p_note text)
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
  select * into profile from public.dashboard_profiles where id=auth.uid() and active;
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
revoke execute on function public.dashboard_follow_instruction(bigint,bigint,integer,text,text) from public;
grant execute on function public.dashboard_follow_instruction(bigint,bigint,integer,text,text) to authenticated;

alter publication supabase_realtime add table public.dashboard_units;
commit;
