@echo off
setlocal EnableExtensions
chcp 65001 >nul
cls

echo =============================================================
echo  AtoM Portable - PASO 1: PREPARACION
echo  Ejecutar solo UNA VEZ. Necesita internet (~30 min).
echo =============================================================
echo.

set "ATOM_VERSION=2.10.0"
set "D=%~dp0"
set "D=%D:~0,-1%"
set "ATOM_SRC=%D%\atom-src"
set "ATOM_ZIP=%D%\atom-src.zip"

cd /d "%D%" || (
  echo ERROR: No se pudo entrar en la carpeta del paquete.
  pause
  exit /b 1
)

if not exist "%D%\images" mkdir "%D%\images"
if not exist "%D%\uploads" mkdir "%D%\uploads"

echo [0/7] Comprobando Docker Desktop...
docker info >nul 2>&1
if %errorlevel% neq 0 (
  echo ERROR: Docker Desktop no esta en ejecucion.
  echo Abra Docker Desktop y espere a que termine de arrancar.
  pause
  exit /b 1
)
echo Docker Desktop operativo.
echo.

echo [0b/7] Leyendo configuracion .env...
call :load_env
if %errorlevel% neq 0 (
  pause
  exit /b 1
)
echo Configuracion .env leida correctamente.
echo.

echo === FASE 1: DESCARGAR Y CONSTRUIR IMAGENES ===
echo.

echo [1/7] Descargando imagenes de servicios ^(Docker Hub^)...
docker pull nginx:1.25-alpine
if %errorlevel% neq 0 goto :docker_pull_error
docker pull docker.elastic.co/elasticsearch/elasticsearch-oss:7.10.2
if %errorlevel% neq 0 goto :docker_pull_error
docker pull percona:8.0
if %errorlevel% neq 0 goto :docker_pull_error
docker pull memcached:1.6-alpine
if %errorlevel% neq 0 goto :docker_pull_error
docker pull artefactual/gearmand:1.1.22
if %errorlevel% neq 0 goto :docker_pull_error
echo Imagenes de servicios descargadas.
echo.

echo [2/7] Descargando y validando codigo fuente de AtoM %ATOM_VERSION%...
call :prepare_atom_source
if %errorlevel% neq 0 (
  echo ERROR: No se pudo preparar correctamente el codigo fuente de AtoM.
  pause
  exit /b 1
)
echo Codigo fuente listo y validado.
echo.

echo [2b/7] Aplicando compatibilidad de build para Sass...
call :patch_atom_source
if %errorlevel% neq 0 (
  echo ERROR: No se pudo aplicar la correccion de compatibilidad Sass.
  pause
  exit /b 1
)
echo Correccion Sass aplicada.
echo.

echo [3/7] Construyendo imagen de AtoM ^(10-20 min^)...
docker build -t atom-portable:2.10.0 "%ATOM_SRC%"
if %errorlevel% neq 0 (
  echo ERROR: Fallo la construccion de AtoM.
  echo Revise que la carpeta atom-src incluya vendor\yui y plugins\sfTranslatePlugin\css\l10n_client.css.
  pause
  exit /b 1
)
echo Imagen AtoM construida.
echo.

echo [4/7] Construyendo imagen de Nginx...
docker build -t atom-nginx:1.0 "%D%\config"
if %errorlevel% neq 0 (
  echo ERROR: Fallo la construccion de Nginx.
  pause
  exit /b 1
)
echo Imagen Nginx construida.
echo.

echo [5/7] Construyendo imagen del Asistente IA...
docker build -t asistente-ia:1.0 "%D%\asistente-ia"
if %errorlevel% neq 0 (
  echo ERROR: Fallo la construccion del Asistente IA.
  pause
  exit /b 1
)
echo Imagen Asistente IA lista.
echo.

echo [6/7] Guardando imagenes para uso offline...
docker save -o "%D%\images\atom.tar" atom-portable:2.10.0
if %errorlevel% neq 0 goto :docker_save_error
docker save -o "%D%\images\atom-nginx.tar" atom-nginx:1.0
if %errorlevel% neq 0 goto :docker_save_error
docker save -o "%D%\images\asistente.tar" asistente-ia:1.0
if %errorlevel% neq 0 goto :docker_save_error
docker save -o "%D%\images\nginx.tar" nginx:1.25-alpine
if %errorlevel% neq 0 goto :docker_save_error
docker save -o "%D%\images\elasticsearch.tar" docker.elastic.co/elasticsearch/elasticsearch-oss:7.10.2
if %errorlevel% neq 0 goto :docker_save_error
docker save -o "%D%\images\percona.tar" percona:8.0
if %errorlevel% neq 0 goto :docker_save_error
docker save -o "%D%\images\memcached.tar" memcached:1.6-alpine
if %errorlevel% neq 0 goto :docker_save_error
docker save -o "%D%\images\gearmand.tar" artefactual/gearmand:1.1.22
if %errorlevel% neq 0 goto :docker_save_error
echo Imagenes guardadas.
echo.

echo === FASE 2: INICIALIZAR BASE DE DATOS ===
echo.

echo [7/7] Iniciando MySQL, Elasticsearch, Memcached y Gearman...
docker compose up -d percona elasticsearch memcached gearmand
if %errorlevel% neq 0 (
  echo ERROR: No se pudieron iniciar los servicios base.
  pause
  exit /b 1
)

echo.
call :wait_for_health percona MySQL 40 8
if %errorlevel% neq 0 goto :base_service_error

call :wait_for_health elasticsearch Elasticsearch 40 10
if %errorlevel% neq 0 goto :base_service_error

echo.
echo Iniciando AtoM...
docker compose up -d atom atom_worker
if %errorlevel% neq 0 (
  echo ERROR: No se pudo iniciar AtoM.
  docker compose logs --tail=80 atom
  pause
  exit /b 1
)

echo Esperando a que AtoM termine de arrancar...
timeout /t 25 /nobreak >nul

echo Inicializando base de datos...
set "ATOM_ID="
FOR /F "tokens=*" %%i IN ('docker compose ps -q atom 2^>nul') DO set "ATOM_ID=%%i"

if "%ATOM_ID%"=="" (
  echo ERROR: No se pudo localizar el contenedor del servicio atom.
  docker compose ps
  pause
  exit /b 1
)

docker exec %ATOM_ID% php -d memory_limit=1G symfony tools:install ^
  --no-confirmation ^
  --database-host=percona ^
  --database-port=3306 ^
  --database-name=atom ^
  --database-user=atom ^
  --database-password="%ATOM_MYSQL_PASSWORD%" ^
  --search-host=elasticsearch ^
  --search-port=9200 ^
  --search-index=atom ^
  --admin-email="%ATOM_ADMIN_EMAIL%" ^
  --admin-username=admin ^
  --admin-password="%ATOM_ADMIN_PASSWORD%"

if %errorlevel% neq 0 (
  echo.
  echo La inicializacion ha fallado. Se reintentara una vez en 30 segundos...
  timeout /t 30 /nobreak >nul

  docker exec %ATOM_ID% php -d memory_limit=1G symfony tools:install ^
    --no-confirmation ^
    --database-host=percona ^
    --database-port=3306 ^
    --database-name=atom ^
    --database-user=atom ^
    --database-password="%ATOM_MYSQL_PASSWORD%" ^
    --search-host=elasticsearch ^
    --search-port=9200 ^
    --search-index=atom ^
    --admin-email="%ATOM_ADMIN_EMAIL%" ^
    --admin-username=admin ^
    --admin-password="%ATOM_ADMIN_PASSWORD%"
)

if %errorlevel% neq 0 (
  echo.
  echo ERROR: Fallo la inicializacion de la base de datos.
  echo Estado de servicios:
  docker compose ps
  echo.
  echo Ultimos logs de AtoM:
  docker compose logs --tail=80 atom
  echo.
  echo Los servicios se detendran para evitar un estado intermedio.
  docker compose down
  pause
  exit /b 1
)

docker compose down

echo.
echo =============================================================
echo  PREPARACION COMPLETADA
echo.
echo  Ahora ejecute: 2_iniciar_atom.bat
echo  AtoM: http://localhost:8080
echo  Usuario: %ATOM_ADMIN_EMAIL%
echo  Contrasena: la indicada en .env como ATOM_ADMIN_PASSWORD
echo  Asistente IA: http://localhost:8081
echo.
echo  IMPORTANTE: cambie la contrasena tras el primer acceso si es una instalacion real.
echo =============================================================
echo.
pause
exit /b 0


:load_env
if not exist "%D%\.env" (
  echo ERROR: No existe el fichero .env.
  echo Copie .env.example como .env y sustituya los valores CAMBIAR_ESTO por contrasenas reales.
  exit /b 1
)

for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%D%\.env") do (
  if not "%%A"=="" set "%%A=%%B"
)

if "%MYSQL_ROOT_PASSWORD%"=="" (
  echo ERROR: Falta MYSQL_ROOT_PASSWORD en .env.
  exit /b 1
)
if "%ATOM_MYSQL_PASSWORD%"=="" (
  echo ERROR: Falta ATOM_MYSQL_PASSWORD en .env.
  exit /b 1
)
if "%ATOM_ADMIN_EMAIL%"=="" set "ATOM_ADMIN_EMAIL=admin@atom.local"
if "%ATOM_ADMIN_PASSWORD%"=="" (
  echo ERROR: Falta ATOM_ADMIN_PASSWORD en .env.
  exit /b 1
)

if /i "%MYSQL_ROOT_PASSWORD%"=="CAMBIAR_ESTO" (
  echo ERROR: MYSQL_ROOT_PASSWORD sigue con el valor CAMBIAR_ESTO.
  exit /b 1
)
if /i "%ATOM_MYSQL_PASSWORD%"=="CAMBIAR_ESTO" (
  echo ERROR: ATOM_MYSQL_PASSWORD sigue con el valor CAMBIAR_ESTO.
  exit /b 1
)
if /i "%ATOM_ADMIN_PASSWORD%"=="CAMBIAR_ESTO" (
  echo ERROR: ATOM_ADMIN_PASSWORD sigue con el valor CAMBIAR_ESTO.
  exit /b 1
)

exit /b 0


:prepare_atom_source
set "SOURCE_OK=0"

if exist "%ATOM_SRC%\index.php" (
  call :validate_atom_source
  if "%SOURCE_OK%"=="1" (
    echo Codigo fuente ya descargado y validado.
    exit /b 0
  )

  echo La carpeta atom-src existente esta incompleta o corrupta.
  echo Se eliminara y se descargara de nuevo.
  rmdir /s /q "%ATOM_SRC%"
  if %errorlevel% neq 0 (
    echo ERROR: No se pudo eliminar la carpeta atom-src.
    exit /b 1
  )
)

if exist "%ATOM_ZIP%" del /f /q "%ATOM_ZIP%"

curl -L --fail --retry 3 --retry-delay 5 -o "%ATOM_ZIP%" "https://github.com/artefactual/atom/archive/refs/tags/v%ATOM_VERSION%.zip"
if %errorlevel% neq 0 (
  echo ERROR: Fallo la descarga del codigo fuente. Verifique la conexion.
  exit /b 1
)

echo Extrayendo codigo fuente...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -Force -Path '%ATOM_ZIP%' -DestinationPath '%D%'"
if %errorlevel% neq 0 (
  echo ERROR: Fallo la extraccion del ZIP.
  exit /b 1
)

if exist "%D%\atom-%ATOM_VERSION%" (
  if exist "%ATOM_SRC%" rmdir /s /q "%ATOM_SRC%"
  rename "%D%\atom-%ATOM_VERSION%" "atom-src"
)

if not exist "%ATOM_SRC%\index.php" (
  echo ERROR: No se encontro atom-src\index.php tras la extraccion.
  exit /b 1
)

call :validate_atom_source
if not "%SOURCE_OK%"=="1" (
  echo ERROR: El codigo fuente descargado no contiene todos los recursos necesarios.
  exit /b 1
)

if exist "%ATOM_ZIP%" del /f /q "%ATOM_ZIP%"
exit /b 0


:validate_atom_source
set "SOURCE_OK=1"

for %%F in (
  "index.php"
  "Dockerfile"
  "package.json"
  "webpack.config.js"
  "plugins\sfTranslatePlugin\css\l10n_client.css"
  "plugins\arDominionB5Plugin\scss\main.scss"
  "vendor\yui\autocomplete\autocomplete.js"
  "vendor\yui\connection\connection.js"
  "vendor\yui\datasource\datasource.js"
  "vendor\yui\yahoo-dom-event\yahoo-dom-event.js"
) do (
  if not exist "%ATOM_SRC%\%%~F" (
    echo FALTA: %%~F
    set "SOURCE_OK=0"
  )
)

exit /b 0


:patch_atom_source
set "L10N_CSS=%ATOM_SRC%\plugins\sfTranslatePlugin\css\l10n_client.css"
set "L10N_SCSS=%ATOM_SRC%\plugins\sfTranslatePlugin\css\l10n_client.scss"

if not exist "%L10N_CSS%" (
  echo ERROR: Falta %L10N_CSS%
  exit /b 1
)

copy /Y "%L10N_CSS%" "%L10N_SCSS%" >nul
if %errorlevel% neq 0 (
  echo ERROR: No se pudo crear l10n_client.scss a partir de l10n_client.css.
  exit /b 1
)

exit /b 0


:wait_for_health
set "SERVICE=%~1"
set "LABEL=%~2"
set "MAX_TRIES=%~3"
set "SLEEP_SECONDS=%~4"
set /a TRY=0

echo Esperando a que %LABEL% este listo...

:wait_health_loop
set /a TRY+=1
set "CID="
set "STATUS="

for /f "tokens=*" %%i in ('docker compose ps -q %SERVICE% 2^>nul') do set "CID=%%i"

if "%CID%"=="" (
  echo %LABEL% todavia no tiene contenedor asociado. Intento %TRY%/%MAX_TRIES%...
  timeout /t %SLEEP_SECONDS% /nobreak >nul
  if %TRY% GEQ %MAX_TRIES% goto :wait_health_timeout
  goto :wait_health_loop
)

for /f "tokens=*" %%s in ('docker inspect --format "{{.State.Health.Status}}" %CID% 2^>nul') do set "STATUS=%%s"

if /i "%STATUS%"=="healthy" (
  echo %LABEL% listo.
  exit /b 0
)

if /i "%STATUS%"=="unhealthy" (
  echo ERROR: %LABEL% esta en estado unhealthy.
  docker compose logs --tail=80 %SERVICE%
  exit /b 1
)

if "%STATUS%"=="" (
  echo %LABEL% iniciando ^(sin estado de salud aun^). Intento %TRY%/%MAX_TRIES%...
) else (
  echo %LABEL% iniciando ^(estado: %STATUS%^). Intento %TRY%/%MAX_TRIES%...
)

if %TRY% GEQ %MAX_TRIES% goto :wait_health_timeout
timeout /t %SLEEP_SECONDS% /nobreak >nul
goto :wait_health_loop

:wait_health_timeout
echo ERROR: %LABEL% no alcanzo el estado healthy dentro del tiempo esperado.
echo Estado de servicios:
docker compose ps
echo.
echo Ultimos logs de %LABEL%:
docker compose logs --tail=120 %SERVICE%
exit /b 1


:base_service_error
echo.
echo ERROR: Uno de los servicios base no esta listo.
echo Los servicios se detendran para evitar un estado intermedio.
docker compose down
pause
exit /b 1


:docker_pull_error
echo ERROR: Fallo la descarga de una imagen Docker.
pause
exit /b 1


:docker_save_error
echo ERROR: Fallo el guardado de una imagen Docker para uso offline.
pause
exit /b 1
