# Dashboard de seguimiento de compromisos

## Estado y arquitectura

La copia de prueba usa `index.html`, `localStorage` para las fichas e IndexedDB para los adjuntos. La edición compartida por GitHub que existe en el código estaba condicionada a otra ruta. En la ruta de este repositorio, las fichas no se comparten entre equipos.

La rama incorpora un modo institucional optativo. PostgreSQL conserva las fichas en el formato usado por el dashboard. Las políticas de acceso por fila (RLS) filtran perfiles, fichas, auditoría y documentos. Las mutaciones pasan por una función PostgreSQL que valida el perfil, la asignación, los campos permitidos y la versión de la ficha. Un trigger genera la auditoría con el rol y el tipo de identidad. Realtime avisa de cambios y el cliente vuelve a consultar las fichas autorizadas. Si hay una ficha abierta, la actualización espera a que se cierre para evitar reemplazar el formulario durante la edición. La consulta periódica y el botón de actualización permiten recuperar eventos perdidos.

La página institucional ofrece tres accesos por contraseña. Supabase Auth valida las credenciales de las cuentas de rol. El responsable elige su nombre después de acceder. PostgreSQL liga la selección a su sesión y autoriza únicamente fichas asignadas al nombre seleccionado. La auditoría identifica las cuentas compartidas como identidades operativas. Las cuentas individuales por OTP se mantienen disponibles mediante `?acceso-individual=1`, incluida la administración. El Comité y el Despacho pueden consultar avances recientes. El Despacho conserva el proceso de validación previo al registro de una instrucción. Los administradores pueden gestionar perfiles, responsables asignados y el catálogo de unidades. El nombre de una unidad puede cambiar sin alterar su código ni las asignaciones existentes. Las unidades inactivas se conservan en las fichas históricas y quedan excluidas de nuevas asignaciones. Las cuentas de Auth se crean en Supabase. Las instrucciones ministeriales empiezan en Pendiente. Comité y Despacho pueden iniciar el seguimiento, y Despacho puede resolver o reabrir la instrucción. Cada cambio guarda el motivo, el autor y la fecha en el historial de la ficha.

- [Identidades y códigos por correo en Supabase](https://supabase.com/docs/guides/auth/auth-email-passwordless)
- [Políticas de acceso por fila](https://supabase.com/docs/guides/database/postgres/row-level-security)
- [Cambios de PostgreSQL con Realtime](https://supabase.com/docs/guides/realtime/postgres-changes)

## Configuración de Supabase en pruebas

1. Cree un proyecto de pruebas administrado por la institución. Aplique los archivos de `supabase/migrations/` en orden numérico desde SQL Editor o con `psql -v ON_ERROR_STOP=1 -f` usando una conexión administrativa segura. El esquema empieza sin fichas.
2. En **Authentication → Users**, cree tres cuentas de rol con correos técnicos distintos bajo control institucional y tres contraseñas nuevas, largas y distintas. Confirme las cuentas y desactive el registro público. Mantenga habilitadas las sesiones simultáneas para que cada dispositivo pueda acceder con su propia sesión. Los alias de correo son identificadores públicos de las cuentas. La administración entrega las contraseñas por su canal seguro.
3. En SQL Editor, vincule las cuentas de Auth mediante sus UUID:

   ```sql
   insert into public.dashboard_profiles (id, display_name, role, responsible_name, shared_access)
   values
     ('00000000-0000-0000-0000-000000000001', 'Responsables', 'responsable', 'Cuenta de rol', true),
     ('00000000-0000-0000-0000-000000000002', 'Comité', 'comite', null, true),
     ('00000000-0000-0000-0000-000000000003', 'Despacho del Ministro', 'ministro', null, true);
   ```

   Sustituya los tres UUID. La lista de nombres para la cuenta de Responsables se extrae de las fichas importadas. Para cuentas individuales, conserve `shared_access=false`, configure el SMTP institucional y añada `{{ .Token }}` a la plantilla de correo de enlace mágico. Cree un usuario Auth distinto para cada persona y configure `dashboard_profiles` con su UUID y rol. Use el nombre exacto de la ficha en `responsible_name` para responsables individuales. Use el rol `admin` con `responsible_name=null` para administración.

   Para rotar una credencial compartida, marque su perfil como inactivo en SQL Editor. Revoque sus sesiones en el canal administrativo (`delete from auth.sessions where user_id = 'UUID-de-la-cuenta'`), cambie la contraseña de la cuenta en Auth y reactive el perfil. Distribuya la nueva contraseña por el canal seguro.
4. Copie las variables públicas de `.env.example` al entorno de compilación. Conserve la conexión de PostgreSQL y cualquier credencial de administración fuera de la web. El bucket `dashboard-documents` es privado. Las descargas usan una sesión autenticada y las asignaciones de las fichas.
5. Cree una compilación de pruebas con `node tools/build-institutional.cjs ruta-nueva-de-salida`. La compilación omite la matriz y las huellas de prueba del HTML. Use un servidor HTTP local o una vista previa HTTPS. Abrir la copia de prueba `index.html` sin configuración pública conserva el almacenamiento local.

## Inventario, migración y respaldo

1. Antes del corte, en cada navegador o dispositivo de origen descargue un JSON con **Exportar fichas de este navegador** si el botón está disponible en la copia de prueba. Como alternativa, haga una copia de la clave `minedu-matriz-original` usando las herramientas del navegador, panel Aplicación o Almacenamiento, apartado Local Storage del dominio. Guarde el valor JSON completo en un archivo independiente. Inventaríe los adjuntos de IndexedDB, base `minedu-adjuntos-matriz-original`, almacén `archivos`. Descargue los documentos desde cada ficha y registre el ID de la ficha correspondiente. Incluya cualquier copia histórica compartida que la institución use como fuente.
2. Ejecute `node tools/prepare-import.cjs ruta-nueva archivo1.json archivo2.json`. El script copia cada entrada al directorio de revisión, identifica duplicados y muestra campos con discrepancias. Una copia base sin cambios no invalida el avance de otro navegador. Si dos fuentes cambiaron una misma ficha de manera distinta, compare ambas copias y resuelva con sus responsables. Conserve el historial y la evidencia pertinente al preparar el JSON conciliado. El proceso no escribe en ningún navegador.
3. Tras aprobar el informe, ejecute de nuevo con `--confirm` y otro directorio nuevo. Solo entonces se genera `importacion.sql`. Importa en una transacción a una tabla vacía y aborta si encuentra fichas existentes. Trate las exportaciones y el SQL generado como información institucional privada. Aplique el SQL mediante el canal administrativo de PostgreSQL. Compare el conteo, las asignaciones, fechas, hitos e historiales con la revisión. Suba los adjuntos inventariados al bucket privado desde las fichas autorizadas, compruebe que se descargan con el perfil correcto y conserve los archivos fuente.
4. Antes del corte final, exporte un respaldo del esquema y los datos con `pg_dump` o use las copias administradas por Supabase. Los objetos del bucket necesitan respaldo separado de sus metadatos en PostgreSQL. Pruebe la restauración de ambos en un proyecto aislado. Mantenga los archivos de origen y los datos locales hasta que se complete la conciliación.
5. Durante el corte final, coordine el cierre de ediciones de la copia local antes de tomar la última exportación. Revierta la publicación al artefacto anterior si falla el acceso después del corte. Conserve la base compartida y sus cambios para conciliar las ediciones posteriores.

## Publicación en GitHub Pages

1. Complete la conciliación y el respaldo, aplique las migraciones pendientes y pruebe el tablero con una base de ensayo. Mantenga la publicación anterior disponible durante la preparación.
2. En **Settings → Secrets and variables → Actions → Variables** del repositorio, configure las cinco variables públicas de `.env.example` que empiezan por `SUPABASE_`. Use la clave publicable del proyecto. Las contraseñas se crean en Auth. La conexión administrativa y el SQL de importación se manejan fuera de GitHub.
3. Cuando el proyecto de producción esté listo, en **Settings → Pages → Source** seleccione **GitHub Actions** antes de integrar la rama en `main`. El despliegue anterior se generó desde la raíz de `main`. El flujo manual publica únicamente la compilación institucional, que omite la matriz y las huellas de prueba. El historial público de GitHub aún puede contener la matriz que se versionó anteriormente.
4. Integre la rama en `main`. En **Actions → Publicar tablero institucional**, pulse **Run workflow** sobre `main`. Espere a que finalice `publicar`. Abra https://monicact.github.io/following-policies/ y verifique acceso, datos importados y sincronización con sesiones independientes.
5. Si falla el corte, vuelva a seleccionar el despliegue anterior. Conserve PostgreSQL, sus documentos y el historial de la ventana de publicación para la conciliación.


## Verificación

### Pruebas ejecutadas localmente

`tools/test-dashboard.cjs` ejecuta la migración en PostgreSQL mediante PGlite 0.3.15, con esquemas simulados de Auth y Storage. Configure `PGLITE_MODULE` con la ruta de `dist/index.cjs` del paquete y `DEMO_KEYS` con el archivo privado de contraseñas de prueba. Ejecute `node tools/test-dashboard.cjs`. Comprueba las tres claves, la sintaxis del frontend, cuatro roles, asignaciones, permisos de almacenamiento, auditoría, observaciones, transiciones de instrucciones, altas y asignaciones del catálogo de unidades y el rechazo de versiones desactualizadas. PGlite comprueba PostgreSQL. La integración hospedada de Auth, Storage, Realtime y GitHub Pages requiere las siguientes pruebas en el proyecto de ensayos.

### Pruebas pendientes en cuatro sesiones independientes

Abra cuatro perfiles de navegador o equipos. Use una ficha de prueba asignada a la sesión de Responsable:

1. Responsable guarda un avance y Comité ve el cambio sin pulsar Actualizar registros.
2. Comité envía una observación y Responsable la recibe sin actualizar manualmente. Responsable responde al reenviar y Comité valida y comprueba el historial.
3. Despacho consulta fichas validadas e historial y registra una instrucción. Admin comprueba el autor y los valores en Auditoría.
4. Responsable intenta guardar sobre otra ficha mediante la API con su propia sesión y PostgreSQL rechaza la operación. Compruebe también que una sesión anónima no puede descargar adjuntos privados.
5. Abra la misma ficha en dos sesiones de pruebas con acceso de escritura, guarde una y luego intente guardar la otra. La segunda debe recibir el aviso de conflicto y conservar la versión guardada por la primera.
6. Cierre sesión y entre desde un equipo distinto. Compruebe las fichas, la auditoría y la descarga de la evidencia. Pruebe pérdida de red, reconexión y guardado con una ficha abierta. Verifique el flujo en pantallas móviles.
7. Compruebe la recuperación desde correo y restaure un respaldo en un proyecto aislado.

## Archivos

- `index.html` conserva los formularios e indicadores. Reordena filtros y acciones, cambia el acceso de prueba, integra las sesiones institucionales y agrega la interfaz para auditoría y administración.
- `backend.js`, `backend-config.js` y `.env.example` integran el cliente y la configuración. `.github/workflows/pages.yml` habilita el despliegue manual.
- `supabase/migrations/` crea las tablas, políticas, funciones, trigger, bucket privado, catálogo de unidades y seguimiento de instrucciones, y habilita los eventos de Realtime.
- `tools/prepare-import.cjs` valida exportaciones, conserva copias y prepara la importación confirmada.
- `tools/build-institutional.cjs` produce el artefacto para GitHub Pages.
- `tools/test-dashboard.cjs` prueba el esquema y el acceso por perfiles localmente.
