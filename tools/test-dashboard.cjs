const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const {webcrypto} = require('node:crypto');
const {PGlite} = require(require('node:path').resolve(process.env.PGLITE_MODULE));
const root = require('node:path').join(__dirname,'..');
const migration = fs.readFileSync(root+'/supabase/migrations/202611140001_dashboard.sql','utf8');
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
    create table auth.users(id uuid primary key);
    create function auth.uid() returns uuid language sql stable as
      'select nullif(current_setting(''request.jwt.claim.sub'',true),'''')::uuid';
    grant usage on schema auth,storage to authenticated;
    create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint);
    create table storage.objects(id int generated always as identity,name text,bucket_id text);
    alter table storage.objects enable row level security;
    grant select,insert on storage.objects to authenticated;
    create publication supabase_realtime;
  `);
  await db.exec(migration);
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
  console.log('3 contraseñas de prueba, SQL ejecutable, 4 roles, RLS, adjuntos, observaciones, auditoría, instrucciones y control de versiones: OK.');
}

run().catch(error=>{console.error(error);process.exitCode=1;}).finally(()=>db.close());
