const fs = require('node:fs');
const path = require('node:path');
const root = path.join(__dirname,'..');
const [output] = process.argv.slice(2);
const {SUPABASE_URL:url,SUPABASE_PUBLISHABLE_KEY:publishableKey} = process.env;
const roleAccounts = Object.fromEntries(['responsable','comite','ministro'].map(role =>
  [role,process.env['SUPABASE_ROLE_'+role.toUpperCase()+'_EMAIL']?.trim().toLowerCase()]));
if (!output || !url || !/^sb_publishable_[A-Za-z0-9_-]+$/.test(publishableKey||'')) {
  throw new Error('Indique un directorio de salida nuevo y configure SUPABASE_URL y SUPABASE_PUBLISHABLE_KEY.');
}
if (Object.values(roleAccounts).some(email=>!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) ||
    new Set(Object.values(roleAccounts)).size!==3) {
  throw new Error('Configure las tres direcciones de las cuentas de rol. Deben ser distintas.');
}
const parsed = new URL(url);
if (parsed.protocol!=='https:' || !parsed.hostname.endsWith('.supabase.co') ||
    parsed.username || parsed.password || parsed.pathname!=='/' || parsed.search || parsed.hash) {
  throw new Error('Use la URL HTTPS del proyecto Supabase.');
}
const destination = path.resolve(output);
if (fs.existsSync(destination)) throw new Error('El directorio de salida debe ser nuevo.');
const source = fs.readFileSync(path.join(root,'index.html'),'utf8');
const start = source.indexOf('const RAW=');
const end = source.indexOf('const matrix = RAW',start);
if (start<0 || end<=start) throw new Error('No se encontró la matriz de la copia de prueba.');
const html = (source.slice(0,start)+'const RAW=[];\n'+source.slice(end))
  .replace(/const demoProfileDigests = \{[\s\S]*?\};/,'const demoProfileDigests = {};')
  .replace('const institutionalBuild = false;', 'const institutionalBuild = true;');
fs.mkdirSync(destination,{recursive:true});
fs.writeFileSync(path.join(destination,'index.html'),html);
fs.copyFileSync(path.join(root,'backend.js'),path.join(destination,'backend.js'));
fs.writeFileSync(path.join(destination,'backend-config.js'),'window.DASHBOARD_CONFIG = '+JSON.stringify({
  url:parsed.origin,publishableKey,roleAccounts
})+';\n');
fs.writeFileSync(path.join(destination,'.nojekyll'),'');
