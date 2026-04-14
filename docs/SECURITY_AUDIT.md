# Auditoría de Seguridad — atom-portable-asistente-ia

**Fecha:** 14 de abril de 2026 (actualización)
**Auditoría inicial:** 13 de abril de 2026

## Contexto

Este despliegue está diseñado para uso local en equipos Windows con Docker
Desktop, orientado a profesionales del sector archivístico / GLAM en
contextos de formación, talleres, demostraciones y pruebas técnicas.

El modelo de amenaza asume un equipo personal o de trabajo en red local.
No está diseñado para ser accesible desde internet.

---

## Resumen de estado

| # | Severidad | Problema | Estado |
|---|-----------|----------|--------|
| C1 | CRÍTICA | Contraseñas hardcodeadas en compose y BAT | ✅ Corregido |
| C2 | CRÍTICA | .env con contraseñas reales en historial Git | ⚠️ Mitigado |
| A1 | ALTA | Puertos expuestos a toda la red (0.0.0.0) | ✅ Corregido (v1) |
| A2 | ALTA | Sin cabeceras de seguridad en nginx | ✅ Corregido (v1) |
| A3 | ALTA | URL de Ollama sin validación | ✅ Corregido (v1) |
| A4 | ALTA | Sin límite de texto en asistente IA | ✅ Corregido (v1) |
| A5 | ALTA | Sin CSP en asistente IA | ✅ Corregido (v1) |
| A6 | ALTA | Sin restricciones de seguridad en contenedores | ✅ Corregido |
| M1 | MEDIA | atom_worker sin volumen uploads | ✅ Corregido (v1) |
| M2 | MEDIA | Sin .gitignore en raíz del repo | ✅ Corregido |
| M3 | MEDIA | Docker images por tag, no digest | ⚠️ Aceptado |
| M4 | MEDIA | Elasticsearch OSS 7.10.2 fin de vida | ⚠️ Aceptado |
| B1 | BAJA | Google Fonts en INSTRUCCIONES.html | Pendiente |
| B2 | BAJA | Contraseña admin visible en pantalla | ✅ Corregido |

---

## Detalle de correcciones (v2 — 14 abril 2026)

### C1. Contraseñas hardcodeadas en compose y BAT

**Problema:** El docker-compose.yml contenía valores por defecto visibles
en un repositorio público:
```
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-AtomRoot2024!}
MYSQL_PASSWORD=${ATOM_MYSQL_PASSWORD:-AtomPass2024!}
```
El script 1_preparar_atom.bat tenía las contraseñas en texto claro:
```
--database-password=AtomPass2024!
--admin-password=Admin2024!
```

**Corrección:**
- docker-compose.yml usa `${MYSQL_ROOT_PASSWORD}` y `${ATOM_MYSQL_PASSWORD}`
  sin valores por defecto (requiere .env obligatorio).
- 1_preparar_atom.bat lee contraseñas desde .env con `for /f`.
- El script verifica que las contraseñas no contienen "CAMBIAR" antes
  de continuar.
- 2_iniciar_atom.bat ya no muestra credenciales en pantalla.

### C2. .env con contraseñas reales en historial Git

**Problema:** El commit `ced3774` contiene el fichero .env original con
`ATOM_MYSQL_PASSWORD=AtomPass2024!`. Aunque .env se eliminó del HEAD,
sigue accesible en el historial de Git.

**Mitigación:**
- .gitignore (raíz y AtomPortable/) excluye .env.
- .env.example contiene solo placeholders.
- Las contraseñas expuestas (`AtomPass2024!`, `AtomRoot2024!`, `Admin2024!`)
  deben considerarse COMPROMETIDAS y no usarse nunca.
- Para limpieza completa del historial se requiere `git filter-branch`
  o BFG Repo-Cleaner, lo cual reescribe todo el historial y es destructivo.

### A6. Sin restricciones de seguridad en contenedores

**Problema:** Ningún servicio tenía restricciones de seguridad del kernel
ni límites de recursos.

**Corrección:**
- `security_opt: no-new-privileges:true` en todos los servicios.
- Límites de memoria y CPU (`deploy.resources.limits`) en todos los servicios.
- `read_only: true` + `tmpfs` en el contenedor asistente-ia (estático).
- Nombres de contenedor explícitos (`container_name`) para facilitar
  verificación y monitorización.

### M2. Sin .gitignore en raíz del repo

**Problema:** Solo existía `.gitignore` dentro de `AtomPortable/`.
Ficheros en la raíz del repo no estaban protegidos.

**Corrección:** `.gitignore` en la raíz del repo cubriendo .env,
atom-src/, uploads/, images/, datos/ y ficheros del sistema operativo.

### B2. Contraseña admin visible en pantalla

**Problema:** `2_iniciar_atom.bat` mostraba `(admin / Admin2024!)` en
la consola cada vez que se iniciaba AtoM.

**Corrección:** Ahora dice "Credenciales: las que configuró en .env".

---

## Riesgos aceptados

### M3. Docker images por tag, no digest

Las imágenes usan tags como `percona:8.0` que pueden cambiar sin aviso.
Para un entorno de formación sin conexión a internet (imágenes guardadas
en .tar), el riesgo real es mínimo. En producción se recomendaría fijar
por SHA digest.

### M4. Elasticsearch OSS 7.10.2 fin de vida

Esta versión ya no recibe parches de seguridad. Es un requisito de
AtoM 2.10.0, no actualizable sin cambiar de versión de AtoM. El riesgo
se mitiga porque Elasticsearch no publica puertos al host y solo es
accesible desde la red interna Docker.

---

## Qué NO cubre este endurecimiento

- **Acceso físico al equipo** o al disco USB portable.
- **Malware en el host** con privilegios de administrador.
- **Vulnerabilidades zero-day** en Docker, AtoM, o dependencias.
- **Exposición a internet** (este despliegue NO está diseñado para ello).
- **Cifrado de datos en reposo** (los volúmenes Docker no están cifrados).

---

## Verificación post-despliegue

```powershell
# Verificar que servicios internos NO publican puertos:
docker port atom-percona         # Debe estar VACÍO
docker port atom-elasticsearch   # Debe estar VACÍO
docker port atom-memcached       # Debe estar VACÍO
docker port atom-gearmand        # Debe estar VACÍO

# Verificar que AtoM y Asistente solo escuchan en localhost:
docker port atom-nginx           # Debe mostrar 127.0.0.1:8080
docker port atom-asistente-ia    # Debe mostrar 127.0.0.1:8081

# Verificar restricciones de seguridad:
docker inspect atom-percona --format '{{.HostConfig.SecurityOpt}}'
# Debe mostrar [no-new-privileges]
```

---

## Checklist de primer arranque

- [ ] He copiado `.env.example` como `.env`
- [ ] He cambiado `MYSQL_ROOT_PASSWORD` por una contraseña fuerte
- [ ] He cambiado `ATOM_MYSQL_PASSWORD` por una contraseña fuerte
- [ ] He cambiado `ATOM_ADMIN_PASSWORD` por una contraseña fuerte
- [ ] He ejecutado `1_preparar_atom.bat` sin errores
- [ ] He ejecutado `2_iniciar_atom.bat`
- [ ] He verificado que `docker port atom-percona` está vacío
- [ ] He accedido a http://localhost:8080 y funciona
- [ ] He cambiado la contraseña de admin desde la interfaz de AtoM
