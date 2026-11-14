const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {isDeepStrictEqual} = require('node:util');

const args = process.argv.slice(2);
const confirmed = args[0] === '--confirm';
if (confirmed) args.shift();
const [output, ...sources] = args;
if (!output || !sources.length) {
  console.error('Uso: node tools/prepare-import.cjs [--confirm] directorio exportacion1.json [exportacion2.json ...]');
  process.exit(2);
}

const html = fs.readFileSync(path.join(__dirname,'..','index.html'),'utf8');
const source = html.slice(html.indexOf('const RAW='),html.indexOf('function normalizeRecords'));
const seed = JSON.parse(vm.runInNewContext(source+
  'JSON.stringify(initial.map((row,i)=>({...row,anunciado:matrix[i].D,conflicto:matrix[i].E,entrega2026:matrix[i].F})))'));
const byName = new Map(seed.map(record=>[record.tema,record]));
const imported = new Map();
const conflicts = [];
let duplicates = 0;

fs.mkdirSync(output,{recursive:true});
for (const [index, filename] of sources.entries()) {
  const bytes = fs.readFileSync(filename);
  fs.writeFileSync(path.join(output,'source-'+(index+1)+'.json'),bytes,{flag:'wx'});
  const records = JSON.parse(bytes);
  if (!Array.isArray(records)) throw new Error('El archivo debe contener un arreglo de fichas: '+filename);
  for (const row of records) {
    const base = byName.get(row?.tema?.trim());
    if (!base || base.id!==Number(row.id) || !Array.isArray(row.historial) ||
        !Array.isArray(row.hitos) || row.hitos.length!==base.hitos.length ||
        !row.draft || typeof row.draft!=='object' || Array.isArray(row.draft)) {
      conflicts.push({type:'fila inválida o sin correspondencia',file:index+1,id:row?.id});
      continue;
    }
    const candidate = {...base,...row,id:base.id,tema:base.tema,personas:base.personas,responsable:base.responsable,
      anunciado:base.anunciado,conflicto:base.conflicto,entrega2026:base.entrega2026};
    if (isDeepStrictEqual(JSON.parse(JSON.stringify(candidate)),base)) continue;
    const previous = imported.get(base.id);
    if (previous) {
      if (isDeepStrictEqual(previous.record,candidate)) duplicates++;
      else conflicts.push({type:'versiones distintas',id:base.id,files:[previous.source,index+1],
        fields:[...new Set([...Object.keys(candidate),...Object.keys(previous.record)])]
          .filter(key=>!isDeepStrictEqual(candidate[key],previous.record[key]))});
    } else {
      imported.set(base.id,{record:candidate,source:index+1});
    }
  }
}
const report = {originals:seed.length,existing:imported.size,duplicates,conflicts,confirmation:confirmed};
fs.writeFileSync(path.join(output,'revision.json'),JSON.stringify(report,null,2),{flag:'wx'});
console.log(JSON.stringify(report));
if (conflicts.length) process.exit(1);
if (!confirmed) process.exit(0);

const merged = seed.map(base=>imported.get(base.id)?.record||base);
const encoded = Buffer.from(JSON.stringify(merged),'utf8').toString('hex');
const sql = [
  'begin;',
  'lock table public.dashboard_commitments in access exclusive mode;',
  "do $$ begin if exists(select 1 from public.dashboard_commitments) then raise exception 'La base ya tiene fichas'; end if; end $$;",
  'insert into public.dashboard_commitments(id,body)',
  "select (item->>'id')::bigint,item from jsonb_array_elements(convert_from(decode('"+encoded+"','hex'),'UTF8')::jsonb) item;",
  'commit;',
].join('\n');
fs.writeFileSync(path.join(output,'importacion.sql'),sql,{flag:'wx'});
