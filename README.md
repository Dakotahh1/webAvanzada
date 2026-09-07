# Laboratorio CI/CD — Ingeniería Web Avanzada

Repositorio con frontend Angular, integración continua mediante GitHub Actions y entrega continua hacia un ambiente de staging simulado con Terraform.

**Rama principal:** `main` · **Rama de trabajo:** `devops/ci-cd`

---

## Índice

- [Parte I — Repositorio y frontend](#parte-i--repositorio-y-frontend) (P1–P4)
- [Parte II — Integración Continua](#parte-ii--integración-continua) (P5–P9)
- [Parte III — Secretos y configuración](#parte-iii--secretos-y-configuración) (P10–P12)
- [Parte IV — Entrega Continua con Terraform](#parte-iv--entrega-continua-con-terraform) (P13–

---

## Parte I — Repositorio y frontend

### Pregunta 1 — ¿Por qué no se recomienda desarrollar directamente sobre `main`?

Porque `main` debe mantenerse siempre en un estado estable y desplegable. Trabajar en una rama separada permite:

- **Validar antes de integrar.** El workflow `ci.yml` está configurado con `on: pull_request`. Si se hicieran commits directos a `main`, la validación automática nunca se ejecutaría.
- **Revisión mediante Pull Request.** El PR es el punto de control donde se revisa el cambio y se verifican los checks antes de aceptarlo.
- **Aislar el trabajo en progreso.** Un cambio a medio terminar no afecta a nadie más y puede descartarse sin ensuciar el historial de la rama principal.
- **Proteger el despliegue.** En este laboratorio, un push sobre `main` dispara `cd.yml`. Commitear directo a `main` desplegaría código sin haber sido validado nunca.

### Pregunta 2 — ¿Qué problema se evita al utilizar `--skip-git`?

Se evita crear un **repositorio Git anidado**. Sin ese flag, Angular CLI inicializa su propio `.git` dentro de `frontend/`, quedando dos repositorios independientes uno dentro del otro.

Las consecuencias son concretas:

- Git no versiona el contenido de un repositorio interno como archivos normales. Lo registra como un **gitlink** (una referencia a un commit externo), igual que un submódulo.
- En GitHub la carpeta `frontend` aparecería como un ícono gris vacío, sin contenido navegable.
- El paso `actions/checkout` del CI no descargaría el código del frontend, y `npm ci` fallaría inmediatamente por no encontrar el `package.json`.

Como el repositorio principal ya fue inicializado al clonarlo, `--skip-git` mantiene un solo historial para todo el proyecto.

### Pregunta 3 — ¿Qué verifica `npm run build`?

Verifica que el proyecto **compila correctamente para producción**, algo distinto de que las pruebas pasen:

- Resolución de todas las importaciones y dependencias
- Verificación de tipos de TypeScript
- Compilación AOT de los templates de los componentes
- Generación de los bundles optimizados (minificación, tree-shaking)

Las pruebas se ejecutan en modo desarrollo con compilación JIT, así que pueden pasar aunque el build de producción falle. Son dos validaciones complementarias, y por eso el pipeline ejecuta ambas.

Este paso local es el equivalente exacto de la etapa *Construir Angular* del workflow, lo que cumple el criterio del laboratorio: antes de automatizar una tarea en CI, debe poder ejecutarse localmente.

### Pregunta 4 — ¿Qué utilidad tiene revisar `git status` o `git diff --cached` antes del commit?

Permiten confirmar **qué información quedará versionada** antes de que el commit sea permanente:

| Comando | Qué muestra |
|---|---|
| `git status` | Archivos preparados, modificados y no rastreados |
| `git diff --cached` | El contenido exacto de los cambios que entrarán al commit |

Su valor práctico:

- Detectar archivos que se colaron por accidente: `.env`, `node_modules/`, `dist/`, claves privadas
- Evitar commits incompletos (archivos que se olvidó agregar)
- Confirmar que el `.gitignore` está funcionando

Es especialmente importante porque **un secreto commiteado queda en el historial de forma permanente**, incluso si se borra después. Revisar antes es mucho más barato que corregir después.

---

## Parte II — Integración Continua

### Pregunta 5 — ¿Qué evento activa el workflow `ci.yml`?

El evento `pull_request` dirigido a la rama `main`:

```yaml
on:
  pull_request:
    branches: [main]
```

El workflow se ejecuta en dos momentos:

1. Al **abrir** el Pull Request (actividad `opened`)
2. En **cada push posterior** a la rama de origen mientras el PR siga abierto (actividad `synchronize`)

Ese segundo caso es el que permite el ciclo de trabajo del laboratorio: se provoca un fallo, se hace push, el pipeline vuelve a correr solo, se corrige, y se valida de nuevo sin cerrar ni reabrir el PR.

Importante: el workflow **no** se activa con pushes directos a `main`. Esa es la función de `cd.yml`.

### Pregunta 6 — En `runs-on: ubuntu-latest`, ¿qué representa `ubuntu-latest`?

Es una **etiqueta de runner alojado por GitHub**: identifica el tipo de máquina virtual donde se ejecutará el job.

Características relevantes:

- Es una VM **limpia**, creada desde cero para cada ejecución y destruida al terminar. No conserva estado entre corridas.
- Viene con software preinstalado: Git, Node.js, Docker, navegadores, herramientas de compilación.
- `latest` apunta a la última versión estable de Ubuntu soportada por GitHub Actions, y **cambia con el tiempo**. Por eso, en proyectos que necesitan reproducibilidad estricta, se prefiere fijar una versión concreta como `ubuntu-24.04`.
- **No tiene entorno gráfico.** Es un servidor sin pantalla, lo que obliga a ejecutar los navegadores en modo headless durante las pruebas.

Que la VM sea efímera y limpia es justamente lo que da valor al CI: garantiza que el proyecto compila desde cero y no depende de configuraciones particulares del equipo de un desarrollador.

### Pregunta 7 — Orden de las etapas del job `frontend` y por qué `npm ci` va antes de las pruebas

**Orden de ejecución:**

1. **Obtener código** — `actions/checkout@v4` descarga el repositorio en el runner
2. **Configurar Node.js** — `actions/setup-node@v4` instala Node 20 y habilita el caché de npm
3. **Instalar dependencias** — `npm ci`
4. **Ejecutar pruebas** — `npm test -- --watch=false`
5. **Construir Angular** — `npm run build`

**Por qué `npm ci` va antes de las pruebas:**

Sin `node_modules` no existen ni Angular, ni Karma, ni Jasmine, ni el compilador de TypeScript. Las pruebas no tendrían con qué ejecutarse. El runner llega completamente vacío: `node_modules` está excluido por `.gitignore` y no viaja en el repositorio, por lo que debe reconstruirse en cada corrida.

**Por qué `npm ci` y no `npm install`:**

| | `npm ci` | `npm install` |
|---|---|---|
| Fuente de versiones | `package-lock.json` (exacto) | Puede resolver versiones nuevas |
| `node_modules` previo | Lo elimina y reinstala | Lo actualiza incrementalmente |
| Lock desincronizado | Falla | Modifica el lock |
| Uso recomendado | Automatización / CI | Desarrollo local |

`npm ci` garantiza que el pipeline instale **exactamente** las mismas versiones que se usaron localmente. Sin eso, el pipeline podría fallar (o pasar) por razones ajenas al código.

### Pregunta 8 — ¿Qué etapa falla y qué ocurre con las siguientes?

Falla la etapa **Ejecutar pruebas**. Al modificar la aserción para esperar `'Título incorrecto'`, la prueba compara contra el `<h1>` real (`Catálogo de Recursos`), no coincide, y Jasmine reporta el fallo.

**Qué ocurre después:**

- El comando termina con **exit code 1**
- Los pasos siguientes (**Construir Angular**) **no se ejecutan**: quedan marcados como *skipped* en la interfaz
- El job completo se marca como *failed*
- El check del Pull Request queda en **rojo ❌**

El motivo es el comportamiento por defecto de GitHub Actions: los pasos se ejecutan **secuencialmente**, y el primer paso que falla **aborta el resto del job**. Es un diseño intencional conocido como *fail fast*: no tiene sentido gastar tiempo construyendo un artefacto cuyo código ya se sabe defectuoso.

### Pregunta 9 — ¿Debería integrarse el PR mientras el pipeline está fallando?

**No.** Justificación:

- **El check rojo es información objetiva**, no una advertencia opcional. Indica que el código no cumple las validaciones que el propio equipo definió.
- **Se rompería `main`.** Esa rama debe mantenerse siempre estable, porque es la referencia desde la que trabajan todos y de la que parte cualquier despliegue.
- **Se desplegaría código roto.** En este laboratorio, integrar el PR genera un push sobre `main` que dispara `cd.yml` automáticamente. El código defectuoso llegaría a staging sin intervención humana.
- **El costo de corrección crece con el tiempo.** Arreglar el problema en la rama, antes de integrar, es mucho más barato que revertir un merge o corregir sobre `main` con otros ya trabajando encima.
- **Se degrada la confianza en el pipeline.** Un equipo que se acostumbra a integrar con checks rojos termina ignorándolos, y el CI deja de cumplir su función.

El flujo correcto es: corregir en la rama → push → esperar el check verde → recién ahí integrar. En equipos reales esto se refuerza con **branch protection rules**, que bloquean técnicamente el merge hasta que los checks pasen.

---

## Parte III — Secretos y configuración

### Pregunta 10 — Clasificación de elementos (4 pts)

| Elemento | Clasificación | Justificación |
|---|---|---|
| `package.json` | **Versionable** | Manifiesto del proyecto. Debe estar en el repositorio e ser idéntico para todos. Sin él, el proyecto no se puede reconstruir. |
| `API_URL` pública | **Variable / configuración** | No es secreta (es pública por definición), pero cambia entre ambientes: dev, staging y producción apuntan a URLs distintas. → GitHub Variables |
| `AWS_REGION` | **Variable / configuración** | No es secreta: identifica una región, no otorga acceso. Cambia según el ambiente. → GitHub Variables |
| `DB_PASSWORD` | **Secreto / no versionable** | Credencial de acceso directo a la base de datos. Su filtración compromete todos los datos. → GitHub Secrets |
| `API_TOKEN` | **Secreto / no versionable** | Credencial de autenticación. Permite actuar en nombre del sistema ante terceros. → GitHub Secrets |
| `terraform.tfstate` | **Secreto / no versionable** | Registra el estado real de la infraestructura y **puede almacenar valores sensibles en texto plano**, incluso los marcados como `sensitive`. Además genera conflictos de merge si dos personas lo versionan. → Backend remoto (S3, Terraform Cloud) |

**Regla práctica para distinguirlos:**

- ¿Es igual para todos y necesario para reconstruir el proyecto? → **versionable**
- ¿Cambia según el ambiente pero no otorga acceso a nada? → **variable/configuración**
- ¿Su filtración permitiría a un tercero acceder o actuar en el sistema? → **secreto**

### Pregunta 11 — ¿Por qué un token no debe escribirse dentro de `ci.yml`, `cd.yml` o un archivo TypeScript?

Porque esos archivos **se versionan en Git**, y eso trae consecuencias en cadena:

- **Queda en el historial de forma permanente.** Cualquiera con acceso al repositorio puede recuperarlo, incluso después de borrarlo del archivo actual.
- **Se propaga a cada clon.** Cada persona que clone el repositorio se lleva una copia del secreto en su máquina.
- **Riesgo de exposición pública.** Si el repositorio se hace público o se hace un fork, el secreto queda expuesto. Existen bots que rastrean GitHub buscando credenciales en commits.
- **Aparecería en los logs.** Sin usar `secrets`, GitHub no tiene forma de saber que ese valor es sensible y no lo enmascararía en la salida del workflow.
- **Rotar la credencial exigiría un commit.** Cambiar un secreto debería ser una operación administrativa, no un cambio de código con revisión y despliegue.

**Caso especialmente grave: el frontend.** Un archivo TypeScript del frontend se **compila y se envía al navegador del usuario**. El secreto queda en el bundle JavaScript descargable, visible para cualquier visitante con abrir las herramientas de desarrollo. No hay ninguna forma de ocultar un secreto en código de cliente.

La alternativa correcta es inyectar el valor en tiempo de ejecución mediante `secrets`, manteniéndolo fuera del código versionado.

### Pregunta 12 — Si un secreto real fue commiteado y luego se agrega a `.gitignore`, ¿queda solucionado?

**No, no queda solucionado.** `.gitignore` solo evita que archivos **no rastreados** se agreguen en el futuro. No tiene ningún efecto sobre:

- Archivos que Git ya está rastreando (los sigue versionando normalmente)
- El historial de commits ya existente

El secreto sigue recuperable con `git log`, `git show` o navegando el historial en GitHub. Debe considerarse **comprometido desde el momento en que se hizo push**.

**Acciones necesarias, en orden de prioridad:**

1. **Rotar o revocar la credencial inmediatamente.** Es lo primero y lo más importante. Genera un valor nuevo e invalida el anterior. Aunque el historial se limpiara perfectamente, ya no hay garantía de que nadie lo haya copiado.
2. **Dejar de rastrear el archivo:** `git rm --cached archivo` y commitear el cambio. Recién ahí `.gitignore` empieza a aplicar.
3. **Reescribir el historial** con `git filter-repo` o BFG Repo-Cleaner, seguido de un push forzado. Esto elimina el secreto de los commits antiguos.
4. **Coordinar con el equipo.** La reescritura del historial obliga a todos a resincronizar sus clones, y los clones antiguos siguen conteniendo el secreto.
5. **Revisar los registros de acceso** del servicio afectado, por si la credencial alcanzó a usarse.

El punto clave: **la limpieza técnica no revierte la exposición**. El paso 1 es obligatorio; los demás reducen el daño residual.

---

## Parte IV — Entrega Continua con Terraform

### Pregunta 13 — Diferencia entre `terraform validate`, `plan` y `apply`

| Comando | Qué hace | Consulta la infraestructura | Modifica algo |
|---|---|---|---|
| `validate` | Revisa que la configuración sea sintácticamente correcta y coherente internamente | No | No |
| `plan` | Compara el estado deseado (código) con el estado actual y muestra el conjunto de cambios | Sí | No |
| `apply` | Ejecuta realmente los cambios | Sí | **Sí** |

**`terraform validate`** — Verifica sintaxis HCL, tipos de variables, referencias a recursos inexistentes y atributos inválidos. Es análisis estático puro: no se conecta a ningún proveedor ni lee el estado. Requiere un `terraform init` previo para conocer los esquemas de los providers.

**`terraform plan`** — Lee el estado actual, lo compara con lo declarado en el código y produce el plan de ejecución, indicando qué recursos se **crearán**, **modificarán** o **destruirán**. Es una operación de solo lectura y funciona como vista previa: permite detectar destrucciones accidentales antes de que ocurran.

**`terraform apply`** — Ejecuta el plan y actualiza el archivo de estado. Es el único de los tres que produce cambios reales. Con `-auto-approve` omite la confirmación interactiva, lo que es necesario en un pipeline automatizado pero peligroso al ejecutarlo a mano.

**Escala de riesgo:** `validate` (nulo) → `plan` (solo lectura) → `apply` (escritura).

Por eso el workflow los ejecuta en ese orden: cada etapa filtra errores más baratos antes de llegar a la única que puede causar daño.

### Pregunta 14 — ¿Por qué `ci.yml` usa `pull_request` y `cd.yml` usa `push` sobre `main`?

Porque responden a **dos preguntas distintas en dos momentos distintos** del ciclo de vida del cambio:

**`ci.yml` con `pull_request`** → *"¿Este cambio es correcto?"*

- Se ejecuta **antes** de integrar, sobre un cambio que todavía es una propuesta
- Valida sin afectar a nadie: si falla, `main` sigue intacta
- Su resultado alimenta la decisión de aceptar o rechazar el PR
- Se ejecuta muchas veces, en cada iteración de la rama

**`cd.yml` con `push` sobre `main`** → *"Esto ya fue aprobado, entrégalo."*

- Se ejecuta **después** de integrar, sobre código que ya pasó el control de calidad
- Un push a `main` solo debería ocurrir por un merge de PR aprobado, así que el evento actúa como señal de que existe una versión lista para desplegar
- Se ejecuta pocas veces, solo cuando algo se acepta oficialmente

**Qué pasaría si se invirtieran:**

- Si `cd.yml` se activara con `pull_request`, se desplegaría código no revisado y aún en discusión, cada vez que alguien abre un PR
- Si `ci.yml` se activara solo con `push` sobre `main`, los errores se detectarían cuando ya están integrados, es decir, demasiado tarde

Esta separación es la distinción fundamental entre **integración** continua (verificar candidatos) y **entrega** continua (publicar lo aprobado).

### Pregunta 15 — ¿Qué función cumple Terraform en este flujo de CD?

Terraform es la herramienta de **Infraestructura como Código (IaC)**: describe el ambiente de destino en archivos versionados, en lugar de configurarlo manualmente.

En este laboratorio concreto, `infra/main.tf` define un recurso `terraform_data` que, mediante un provisioner `local-exec`, copia el build de Angular (`frontend/dist/frontend/browser/`) hacia la carpeta `staging/`, simulando el despliegue a un ambiente. La salida `deployment_path` expone la ruta resultante.

**Lo que aporta al flujo:**

- **Declaratividad.** Se describe el estado deseado, no la secuencia de pasos para llegar a él. Terraform calcula la diferencia.
- **Idempotencia.** Ejecutarlo varias veces converge siempre al mismo resultado, sin efectos acumulativos.
- **Reproducibilidad.** El ambiente se reconstruye igual todas las veces, sin depender de la memoria o los pasos manuales de una persona.
- **Versionado del ambiente.** La infraestructura evoluciona junto al código, con el mismo historial, los mismos PRs y la misma revisión.
- **Parametrización por ambiente.** La variable `environment` se alimenta desde GitHub mediante `TF_VAR_environment: ${{ vars.APP_ENV }}`. El atributo `triggers_replace` hace que el recurso se recree si ese valor cambia. El mismo código sirve para staging y producción cambiando solo la variable.

Aquí el despliegue es una simulación local, pero la estructura es idéntica a un caso real, donde los mismos comandos crearían buckets S3, máquinas virtuales, registros DNS o certificados.

### Pregunta 16 — ¿Por qué usar `${{ secrets.DEMO_TOKEN }}` en lugar del valor directo?

Porque el valor se **inyecta en tiempo de ejecución** y nunca queda escrito en el repositorio. Las ventajas concretas:

- **Separación entre código y credenciales.** El `cd.yml` describe *qué* necesita (`DEMO_TOKEN`), no *cuál es* su valor. El archivo puede revisarse, compartirse o hacerse público sin riesgo.
- **Enmascaramiento automático en los logs.** GitHub sabe que ese valor es sensible y lo reemplaza por `***` en toda la salida del workflow. Si se escribiera directamente, aparecería en texto plano en cada ejecución.
- **Almacenamiento cifrado y unidireccional.** Una vez guardado, el secreto no se puede volver a leer desde la interfaz, ni siquiera por el dueño del repositorio. Solo se puede reemplazar.
- **Rotación sin tocar el código.** Cambiar la credencial es editar un campo en Settings. No requiere commit, ni PR, ni despliegue.
- **Control de acceso.** Los secretos pueden restringirse por entorno, exigir aprobación manual, y no se exponen a workflows disparados desde forks externos.
- **Trazabilidad.** GitHub registra cuándo se creó y actualizó cada secreto.

En el workflow, el paso *Verificar secreto configurado* ejecuta `test -n "$DEMO_TOKEN"`, que falla si la variable está vacía. Es una comprobación defensiva: detiene el pipeline temprano y con un mensaje claro si el secreto no fue configurado, en lugar de fallar más adelante con un error confuso.

---
