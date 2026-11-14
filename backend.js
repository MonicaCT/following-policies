(function () {
  const config = window.DASHBOARD_CONFIG;
  if (!config?.url || !config?.publishableKey) return;
  let client;
  let profile;
  let channel;
  const versions = new Map();
  const auditFields = 'id,commitment_id,actor_name,actor_role,identity_kind,happened_at,field,old_value,new_value,operation';

  async function initialize() {
    const { createClient } = await import('https://esm.sh/@supabase/supabase-js@2.49.4');
    client = createClient(config.url, config.publishableKey, {
      auth: { persistSession:false,detectSessionInUrl:false }
    });
  }

  function checked(result, message) {
    if (result.error) throw new Error(result.error.code === '40001'
      ? 'Otra persona modificó esta ficha. Copie su texto, cierre la ficha y vuelva a abrirla.'
      : message);
    return result.data;
  }

  async function loadProfile(user) {
    const access = checked(await client.from('dashboard_profiles')
      .select('display_name,role,responsible_name,shared_access').eq('id',user.id).single(),
    'Su cuenta aún no tiene un perfil activo.');
    return access;
  }

  window.dashboardBackend = {
    async connectRole(role, password) {
      if (!client) await initialize();
      const email = config.roleAccounts?.[role];
      if (!email) throw new Error('El acceso de este perfil aún no está configurado.');
      const {user} = checked(await client.auth.signInWithPassword({email,password}),
        'No se pudo iniciar sesión con la contraseña de este perfil.');
      try {
        const access = await loadProfile(user);
        if (access.role !== role || !access.shared_access) throw new Error('El perfil no está configurado correctamente.');
        profile = access;
        return profile;
      } catch (error) {
        await this.disconnect();
        throw error;
      }
    },
    async responsibleNames() {
      return checked(await client.rpc('dashboard_responsible_options'),
        'No se pudo consultar la lista de responsables.');
    },
    async selectResponsible(name) {
      checked(await client.rpc('dashboard_select_responsible',{p_name:name}),
        'No se pudo seleccionar el responsable.');
      profile = {...profile,display_name:name,responsible_name:name};
      return profile;
    },
    async sendCode(email) {
      if (!client) await initialize();
      checked(await client.auth.signInWithOtp({email, options:{shouldCreateUser:false}}),
        'No se pudo enviar el código a esta cuenta.');
    },
    async connect(email, token) {
      if (!client) await initialize();
      const result = checked(await client.auth.verifyOtp({email, token, type:'email'}),
        'El código es inválido o venció.');
      try {
        const access = await loadProfile(result.user);
        if (access.shared_access) throw new Error('Seleccione el perfil y acceda con su contraseña.');
        profile = access;
        return profile;
      } catch (error) {
        await this.disconnect();
        throw error;
      }
    },
    async records() {
      const records = [];
      const pageSize = 250;
      for (let offset = 0; ; offset += pageSize) {
        const page = checked(await client.from('dashboard_commitments').select('id,body,version')
          .order('id').range(offset,offset+pageSize-1), 'No se pudieron consultar las fichas compartidas.');
        records.push(...page);
        if (page.length < pageSize) break;
      }
      versions.clear();
      for (const record of records) versions.set(record.id, record.version);
      return records.map(record => record.body);
    },
    async save(previous, next) {
      const oldRows = new Map(previous.map(row=>[row.id,JSON.stringify(row)]));
      const changes = next.filter(row=>oldRows.get(row.id)!==JSON.stringify(row));
      if (!changes.length) return next;
      if (changes.length !== 1) throw new Error('Guarde una ficha por operación.');
      const [record] = changes;
      const stored = checked(await client.rpc('dashboard_save', {
        p_id:record.id, p_version:versions.get(record.id), p_body:record
      }).single(), 'No se pudieron guardar los cambios. Revise los permisos y el estado de la ficha.');
      versions.set(stored.id,stored.version);
      return next.map(row=>row.id===stored.id?stored.body:row);
    },
    subscribe(onUpdate) {
      channel = client.channel('dashboard-commitments')
        .on('postgres_changes',{event:'*',schema:'public',table:'dashboard_commitments'}, onUpdate)
        .on('postgres_changes',{event:'*',schema:'public',table:'dashboard_units'}, onUpdate)
        .subscribe(status => { if (status === 'SUBSCRIBED') onUpdate(); });
    },
    async disconnect() {
      if (channel) await client.removeChannel(channel);
      channel = null;
      profile = null;
      versions.clear();
      if (client) await client.auth.signOut({scope:'local'});
    },
    async units() {
      return checked(await client.from('dashboard_units').select('code,label,active,version').order('code'),
        'No se pudo consultar el catálogo de unidades.');
    },
    async saveUnit(code,label,active,version) {
      checked(await client.rpc('dashboard_save_unit',{p_code:code,p_label:label,p_active:active,p_version:version}),
        'No se pudo guardar la unidad. Revise el código y el nombre.');
    },
    async setUnit(id,code) {
      checked(await client.rpc('dashboard_set_unit',{p_id:id,p_version:versions.get(id),p_code:code}),
        'No se pudo asignar la unidad. Verifique que esté activa.');
    },
    async followInstruction(id,index,state,note) {
      checked(await client.rpc('dashboard_follow_instruction',{
        p_id:id,p_version:versions.get(id),p_index:index,p_state:state,p_note:note
      }), 'No se pudo actualizar la instrucción. Revise el estado y el motivo.');
    },
    async profiles() {
      return checked(await client.from('dashboard_profiles').select('id,display_name,role,responsible_name,active')
        .order('display_name'), 'No se pudieron listar los perfiles.');
    },
    async updateProfile(profile) {
      checked(await client.from('dashboard_profiles').upsert(profile), 'No se pudo guardar el perfil. Compruebe el UUID de Auth.');
    },
    async assign(id,names) {
      checked(await client.rpc('dashboard_assign',{p_id:id,p_version:versions.get(id),p_names:names}),
        'No se pudo guardar la asignación. Seleccione usuarios activos.');
    },
    async audit(id) {
      let query = client.from('dashboard_audit').select(auditFields)
        .order('id',{ascending:false}).limit(500);
      if (id !== undefined) query = query.eq('commitment_id',id);
      return checked(await query,'No se pudo consultar el historial de auditoría.');
    },
    async auditFor(ids) {
      const byCommitment = new Map();
      const pageSize = 250;
      for (let start = 0; start < ids.length; start += 50) {
        let before;
        for (;;) {
          let query = client.from('dashboard_audit').select(auditFields)
            .in('commitment_id',ids.slice(start,start+50)).order('id',{ascending:false}).limit(pageSize);
          if (before !== undefined) query = query.lt('id',before);
          const page = checked(await query,'No se pudo consultar el historial para la impresión.');
          for (const event of page) {
            if (!byCommitment.has(event.commitment_id)) byCommitment.set(event.commitment_id,[]);
            byCommitment.get(event.commitment_id).push(event);
          }
          if (page.length < pageSize) break;
          before = page.at(-1).id;
        }
      }
      return byCommitment;
    },
    async listDocuments(id) {
      return checked(await client.storage.from('dashboard-documents').list(String(id),{limit:100}),
        'No se pudieron consultar los documentos.');
    },
    async uploadDocument(id,file) {
      const filename = file.name.replace(/[\\/]/g,'_').replace(/[^A-Za-z0-9_. -]/g,'_');
      checked(await client.storage.from('dashboard-documents').upload(id + '/' + crypto.randomUUID() + '_' + filename,file),
        'No se pudo cargar un documento. Revise la lista antes de volver a intentarlo.');
    },
    async downloadDocument(path) {
      return checked(await client.storage.from('dashboard-documents').download(path),'No se pudo descargar el documento.');
    }
  };
})();
