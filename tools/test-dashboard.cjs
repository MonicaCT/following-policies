const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const {webcrypto} = require('node:crypto');
const {PGlite} = require(require('node:path').resolve(process.env.PGLITE_MODULE));
const root = require('node:path').join(__dirname,'..');
const migrations = fs.readdirSync(root+'/supabase/migrations').sort()
  .map(file=>fs.readFileSync(root+'/supabase/migrations/'+file,'utf8'));
const html = fs.readFileSync(root+'/index.html','utf8');
const user = {
  responsable:'10000000-0000-0000-0000-000000000001',
  comite:'10000000-0000-0000-0000-000000000002',
  ministro:'10000000-0000-0000-0000-000000000003',
  admin:'10000000-0000-0000-0000-000000000004',
};
const db = new PGlite();

async function run() {
  for(const script of html.matchAll(/<script>([\s\S]*?)<\/script>/g)) new vm.Script(script[1]);
  assert.match(html,/id="assignmentField" hidden/);
  assert.match(html,/id="assignedName"[\s\S]*?id="unit"[\s\S]*?id="person"[\s\S]*?id="commitment"[\s\S]*?id="alertFilter"[\s\S]*?class="filter-actions"[\s\S]*?class="refresh-row"/);
  const source = html.slice(html.indexOf('const demoProfileDigests'),html.indexOf('function hideAssignment'));
  const auth = html.slice(html.indexOf('async function authenticateDemo'),html.indexOf('async function login'));
  const credentials = fs.readFileSync(process.env.DEMO_KEYS,'utf8').trim().split(/\r?\n/).slice(1).map(row=>row.split('\t')[1]);
  const context = vm.createContext({crypto:webcrypto,TextEncoder,initial:[{personas:['Responsable A','Responsable B']}]});
  vm.runInContext(source+auth,context);
  assert.equal(new Set(credentials).size,3);
  for (const [index,role] of ['responsable','comite','ministro'].entries()) {
    assert(await context.authenticateDemo(role,credentials[index]));
    assert(!await context.authenticateDemo(role,credentials[(index+1)%3]));
    assert(!await context.authenticateDemo(role,'123456'));
  }

  await db.exec(`
    create role authenticated; create role anon;
    create schema auth; create schema storage;
    create table auth.users(id uuid primary key,email text,phone text,encrypted_password text);
    create table auth.sessions(id uuid primary key,user_id uuid references auth.users);
    create function auth.jwt() returns jsonb language sql stable as
      'select coalesce(nullif(current_setting(''request.jwt.claims'',true),''''),''{}'')::jsonb';
    create function auth.uid() returns uuid language sql stable as
      'select nullif(current_setting(''request.jwt.claim.sub'',true),'''')::uuid';
    grant usage on schema auth,storage to authenticated;
    create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint);
    create table storage.objects(id int generated always as identity,name text,bucket_id text);
    alter table storage.objects enable row level security;
    grant select,insert on storage.objects to authenticated;
    create publication supabase_realtime;
  `);
  for (const migration of migrations) await db.exec(migration);
  for (const id of Object.values(user)) await db.query('insert into auth.users values($1)',[id]);
  for (const [role,id] of Object.entries(user)) {
    await db.query('insert into dashboard_profiles(id,display_name,role,responsible_name) values($1,$2,$3,$4)',
      [id,role,role,role==='responsable'?'Responsable A':null]);
  }
  const base = {
    id:1,tema:'Compromiso A',personas:['Responsable A'],producto:'Informe',fecha:'2099-01-01',fechaConfirmada:true,
    hitosConfirmados:true,hitos:[{nombre:'Hito 1',hecho:false}],draft:{texto:''},historial:[],etapa:'Borrador',publicado:null,
  };
  for(const row of [base,{...base,id:2,tema:'Compromiso B',personas:['Responsable B']}]) {
    await db.query('insert into dashboard_commitments(id,body) values($1,$2)',[row.id,row]);
  }

  async function as(role, fn) {
    await db.exec('set role '+(role==='anon'?'anon':'authenticated'));
    await db.query("select set_config('request.jwt.claim.sub',$1,false)",[user[role]||'']);
    try { return await fn(); } finally { await db.exec('reset role'); }
  }
  async function get(id) {
    return (await db.query('select id,body,version from dashboard_commitments where id=$1',[id])).rows[0];
  }
  async function save(row,patch) {
    return (await db.query('select * from dashboard_save($1,$2,$3)',[row.id,row.version,{...row.body,...patch}])).rows[0];
  }
  await as('anon',async()=>assert.rejects(get(1),error=>error.code==='42501'));
  const stale = await as('comite',()=>get(1));
  let updated = await as('responsable',async()=>{
    const own = await get(1);
    assert.equal(await get(2),undefined);
    await assert.rejects(save({...own,id:2},{id:2}),error=>error.code==='42501');
    await assert.rejects(save(own,{producto:'Producto sin autorización'}),error=>error.code==='42501');
    await assert.rejects(save(own,{personas:['Responsable B']}),error=>error.code==='42501');
    await assert.rejects(db.query('update dashboard_commitments set version=99'),error=>error.code==='42501');
    await assert.rejects(db.query('insert into storage.objects(name,bucket_id) values($1,$2)',['2/evidence.pdf','dashboard-documents']),error=>error.code==='42501');
    await db.query('insert into storage.objects(name,bucket_id) values($1,$2)',['1/evidence.pdf','dashboard-documents']);
    return save(own,{hitos:[{...own.body.hitos[0],hecho:true}],etapa:'En revisión',
      historial:[{texto:'Avance registrado',actor:'Nombre falso',perfil:'ministro'}]});
  });
  assert.equal(updated.body.historial[0].actor,'responsable');
  await as('comite',async()=>{
    const row = await get(1);
    assert.equal(row.body.hitos[0].hecho,true);
    await assert.rejects(save(stale,{etapa:'Observado'}),error=>error.code==='40001');
    updated = await save(row,{etapa:'Observado',observacionComite:'Adjunte el respaldo',subsanacion:'2099-01-01'});
    assert.equal((await db.query('select name from storage.objects')).rows[0].name,'1/evidence.pdf');
  });
  await as('responsable',async()=>{
    const row = await get(1);
    assert.equal(row.body.seguimientoObservaciones[0].estado,'Pendiente');
    await assert.rejects(save(row,{historial:[{texto:'Alterado'}]}),error=>error.code==='42501');
    updated = await save(row,{etapa:'En revisión',resumenDespacho:'Respaldo adjuntado',
      observacionComite:'',subsanacion:'',observacionAutor:'',observacionFecha:'',hitosObservados:[],hitosObservadosBase:{}});
  });
  await as('comite',async()=>{
    const row = await get(1);
    assert.equal(row.body.seguimientoObservaciones.at(-1).estado,'Respondida');
    updated = await save(row,{etapa:'Validado',publicado:{hitos:row.body.hitos,producto:row.body.producto,fecha:row.body.fecha}});
  });
  await as('ministro',async()=>{
    const row = await get(1);
    assert.equal(row.body.seguimientoObservaciones.at(-1).estado,'Resuelta');
    await assert.rejects(save(row,{producto:'Cambio de producto'}),error=>['42501','22023'].includes(error.code));
    updated = await save(row,{instrucciones:[{texto:'Dar seguimiento'}]});
    assert.equal(updated.body.instrucciones[0].actor,'ministro');
    const events = (await db.query("select actor,old_value,new_value from dashboard_audit where field='hitos' and operation='UPDATE'")).rows;
    assert.deepEqual(events.map(event=>[event.actor,event.old_value[0].hecho,event.new_value[0].hecho]),[[user.responsable,false,true]]);
    await assert.rejects(db.query('delete from dashboard_audit'),error=>error.code==='42501');
  });
  await as('admin',async()=>{
    assert.equal((await db.query('select * from dashboard_profiles')).rows.length,4);
    const row = await get(2);
    await db.query('select dashboard_assign($1,$2,$3)',[row.id,row.version,JSON.stringify(['Responsable A'])]);
  });
  assert.equal((await as('responsable',()=>get(2))).body.personas[0],'Responsable A');

  const follow = (row,state,note) => db.query('select dashboard_follow_instruction($1,$2,$3,$4,$5)',
    [row.id,row.version,0,state,note]);
  const beforeFollow = await as('ministro',()=>get(1));
  await as('responsable',async()=>{
    await assert.rejects(follow(beforeFollow,'En seguimiento','Intento sin autorización'),error=>error.code==='42501');
    await assert.rejects(db.query("select dashboard_save_unit('DGP','Planificación',true,null)"),error=>error.code==='42501');
  });
  await as('comite',async()=>{
    await assert.rejects(follow(beforeFollow,'Resuelta','Cierre no autorizado'),error=>error.code==='42501');
    await follow(beforeFollow,'En seguimiento','Validación en curso');
  });
  await as('ministro',async()=>{
    await assert.rejects(follow(beforeFollow,'Resuelta','Versión anterior'),error=>error.code==='40001');
    await follow(await get(1),'Resuelta','El Comité completó la validación');
    const stored=(await get(1)).body.instrucciones[0];
    assert.equal(stored.estado,'Resuelta');
    assert.deepEqual(stored.seguimiento.map(event=>[event.estado,event.rol]),[['En seguimiento','comite'],['Resuelta','ministro']]);
    await follow(await get(1),'En seguimiento','Se requiere revisión adicional');
  });
  await as('admin',async()=>{
    await db.query("select dashboard_save_unit('DGP','Planificación',true,null)");
    await assert.rejects(db.query("select dashboard_save_unit('DGP','Otra alta',true,null)"),error=>error.code==='40001');
    await db.query("select dashboard_save_unit('DGP','Dirección de Planificación',true,1)");
    await assert.rejects(db.query("select dashboard_save_unit('DGP','Cambio anterior',true,1)"),error=>error.code==='40001');
    const row=await get(2);
    await db.query("select dashboard_set_unit($1,$2,'DGP')",[row.id,row.version]);
    await db.query("select dashboard_save_unit('DGP','Dirección de Planificación',false,2)");
    await assert.rejects(db.query("select dashboard_set_unit($1,$2,'DGP')",[row.id,row.version+1]),error=>error.code==='22023');
  });
  await as('responsable',async()=>{
    assert.equal((await get(2)).body.unidad,'DGP');
    const unit=(await db.query("select label,active from dashboard_units where code='DGP'")).rows[0];
    assert.deepEqual(unit,{label:'Dirección de Planificación',active:false});
  });
  const sessions = ['20000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000002'];
  await db.query("update dashboard_profiles set shared_access=true where id=$1",[user.responsable]);
  await assert.rejects(db.query("update auth.users set encrypted_password='replacement' where id=$1",
    [user.responsable]),error=>error.code==='42501');
  for (const session of sessions) await db.query('insert into auth.sessions values($1,$2)',[session,user.responsable]);
  await db.query("update dashboard_commitments set body=jsonb_set(body,'{personas}','[\"Responsable B\"]') where id=2");
  async function useSession(session, callback) {
    await db.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({session_id:session})]);
    return as('responsable',callback);
  }
  await useSession(sessions[0],async()=>{
    assert.deepEqual((await db.query('select id from dashboard_commitments')).rows,[]);
    assert.deepEqual((await db.query('select dashboard_responsible_options() as names')).rows[0].names,
      ['Responsable A','Responsable B']);
    await assert.rejects(db.query("select dashboard_select_responsible('Otra persona')"),error=>error.code==='42501');
    await db.query("select dashboard_select_responsible('Responsable A')");
    await assert.rejects(db.query("select dashboard_select_responsible('Responsable B')"),error=>error.code==='42501');
    assert.deepEqual((await db.query('select id from dashboard_commitments')).rows.map(row=>row.id),[1]);
    const row = await get(1);
    const edited = structuredClone(row.body);
    edited.hitos[0].hecho = false;
    await db.query('select dashboard_save($1,$2,$3)',[row.id,row.version,edited]);
  });
  await useSession(sessions[1],async()=>{
    assert.deepEqual((await db.query('select id from dashboard_commitments')).rows,[]);
    await db.query("select dashboard_select_responsible('Responsable B')");
    assert.deepEqual((await db.query('select id from dashboard_commitments')).rows.map(row=>row.id),[2]);
  });
  await as('comite', async()=>{
    const audit = (await db.query("select actor_name,identity_kind from dashboard_audit where field='hitos' order by id desc limit 1")).rows[0];
    assert.deepEqual(audit,{actor_name:'Responsable A',identity_kind:'operativa'});
    await assert.rejects(db.query("select dashboard_select_responsible('Responsable A')"),error=>error.code==='42501');
  });
  await db.query('delete from auth.sessions where id=$1',[sessions[0]]);
  await useSession(sessions[0],async()=>{
    assert.deepEqual((await db.query('select id from dashboard_commitments')).rows,[]);
    await assert.rejects(db.query("select dashboard_select_responsible('Responsable A')"),error=>error.code==='42501');
  });
  console.log('Acceso compartido, aislamiento entre sesiones, revocación, protección de contraseñas y auditoría operativa: OK.');
  console.log('3 contraseñas de prueba, SQL ejecutable, 4 roles, RLS, adjuntos, observaciones, auditoría, seguimiento de instrucciones, catálogos y control de versiones: OK.');
}

run().catch(error=>{console.error(error);process.exitCode=1;}).finally(()=>db.close());
