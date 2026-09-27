@echo off
setlocal EnableExtensions
chcp 65001 >nul
cls

echo =============================================================
echo  AtoM Portable + Asistente IA - INICIO
echo =============================================================
echo.

set "D=%~dp0"
set "D=%D:~0,-1%"
cd /d "%D%" || (
  echo ERROR: No se pudo entrar en la carpeta del paquete.
  pause
  exit /b 1
)

if not exist "docker-compose.yml" (
  echo ERROR: No se encontro docker-compose.yml en esta carpeta.
  echo Ejecute este archivo desde la carpeta AtomPortable.
  pause
  exit /b 1
)

if not exist ".env" (
  echo ERROR: No se encontro el fichero .env.
  echo Copie .env.example como .env y configure las contrasenas.
  pause
  exit /b 1
)

echo [1/6] Comprobando Docker Desktop...
docker info >nul 2>&1
if %errorlevel% neq 0 (
  echo ERROR: Docker Desktop no esta en ejecucion.
  echo Abra Docker Desktop y espere a que termine de arrancar.
  pause
  exit /b 1
)
echo Docker Desktop operativo.
echo.

echo [2/6] Comprobando imagenes necesarias...
call :ensure_image atom-portable:2.10.0 images\atom.tar
if %errorlevel% neq 0 goto :image_error

call :ensure_image atom-nginx:1.0 images\atom-nginx.tar
if %errorlevel% neq 0 goto :image_error

call :ensure_image asistente-ia:1.0 images\asistente.tar
if %errorlevel% neq 0 goto :image_error

call :ensure_image nginx:1.25-alpine images\nginx.tar
if %errorlevel% neq 0 goto :image_error

call :ensure_image docker.elastic.co/elasticsearch/elasticsearch-oss:7.10.2 images\elasticsearch.tar
if %errorlevel% neq 0 goto :image_error

call :ensure_image percona:8.0 images\percona.tar
if %errorlevel% neq 0 goto :image_error

call :ensure_image memcached:1.6-alpine images\memcached.tar
if %errorlevel% neq 0 goto :image_error

call :ensure_image artefactual/gearmand:1.1.22 images\gearmand.tar
if %errorlevel% neq 0 goto :image_error

echo Imagenes disponibles.
echo.

echo [3/6] Iniciando servicios con Docker Compose...
docker compose up -d
if %errorlevel% neq 0 (
  echo ERROR: docker compose up -d ha fallado.
  echo.
  docker compose ps
  echo.
  docker compose logs --tail=120
  pause
  exit /b 1
)
echo Servicios solicitados.
echo.

echo [4/6] Esperando servicios base...
call :wait_for_health percona MySQL 40 8
if %errorlevel% neq 0 goto :service_error

call :wait_for_health elasticsearch Elasticsearch 40 10
if %errorlevel% neq 0 goto :service_error

echo.
echo [5/6] Esperando a que AtoM responda por HTTP...
call :wait_for_http "http://localhost:8080" 36 10
if %errorlevel% neq 0 goto :http_error

echo.
echo [6/6] Comprobando asistente IA...
call :wait_for_http "http://localhost:8081" 12 5
if %errorlevel% neq 0 (
  echo ADVERTENCIA: AtoM responde, pero el asistente IA no responde en http://localhost:8081.
  echo Revise los logs con: docker compose logs --tail=120 asistente-ia
  echo.
) else (
  echo Asistente IA responde por HTTP.
)

echo.
echo =============================================================
echo  AtoM Portable esta en marcha
echo.
echo  AtoM:         http://localhost:8080
echo  Asistente IA: http://localhost:8081
echo.
echo  Usuario AtoM habitual:
echo  admin
echo  o el correo indicado en .env como ATOM_ADMIN_EMAIL
echo.
echo  Contrasena:
echo  la indicada en .env como ATOM_ADMIN_PASSWORD
echo.
echo  Para detener:
echo  3_detener_atom.bat
echo =============================================================
echo.

start "" "http://localhost:8080"
pause
exit /b 0


:ensure_image
set "IMAGE_NAME=%~1"
set "TAR_PATH=%~2"

docker image inspect "%IMAGE_NAME%" >nul 2>&1
if %errorlevel% equ 0 (
  echo OK: %IMAGE_NAME%
  exit /b 0
)

if exist "%TAR_PATH%" (
  echo Cargando %IMAGE_NAME% desde %TAR_PATH%...
  docker load -i "%TAR_PATH%"
  if %errorlevel% neq 0 (
    echo ERROR: No se pudo cargar %TAR_PATH%.
    exit /b 1
  )

  docker image inspect "%IMAGE_NAME%" >nul 2>&1
  if %errorlevel% neq 0 (
    echo ERROR: Tras cargar %TAR_PATH%, no aparece la imagen %IMAGE_NAME%.
    exit /b 1
  )

  echo OK: %IMAGE_NAME%
  exit /b 0
)

echo ERROR: Falta la imagen %IMAGE_NAME% y tampoco existe %TAR_PATH%.
echo Ejecute primero 1_preparar_atom.bat.
exit /b 1


:wait_for_health
set "SERVICE=%~1"
set "LABEL=%~2"
set "MAX_TRIES=%~3"
set "SLEEP_SECONDS=%~4"
set /a TRY=0

echo Esperando %LABEL%...

:wait_health_loop
set /a TRY+=1
set "CID="
set "STATUS="

for /f "tokens=*" %%i in ('docker compose ps -q %SERVICE% 2^>nul') do set "CID=%%i"

if "%CID%"=="" (
  echo %LABEL% todavia no tiene contenedor. Intento %TRY%/%MAX_TRIES%...
  if %TRY% GEQ %MAX_TRIES% goto :wait_health_timeout
  timeout /t %SLEEP_SECONDS% /nobreak >nul
  goto :wait_health_loop
)

for /f "tokens=*" %%s in ('docker inspect --format "{{.State.Health.Status}}" %CID% 2^>nul') do set "STATUS=%%s"

if /i "%STATUS%"=="healthy" (
  echo %LABEL% listo.
  exit /b 0
)

if /i "%STATUS%"=="unhealthy" (
  echo ERROR: %LABEL% esta en estado unhealthy.
  docker compose logs --tail=120 %SERVICE%
  exit /b 1
)

echo %LABEL% iniciando ^(estado: %STATUS%^). Intento %TRY%/%MAX_TRIES%...
if %TRY% GEQ %MAX_TRIES% goto :wait_health_timeout
timeout /t %SLEEP_SECONDS% /nobreak >nul
goto :wait_health_loop

:wait_health_timeout
echo ERROR: %LABEL% no alcanzo estado healthy.
echo.
docker compose ps
echo.
docker compose logs --tail=120 %SERVICE%
exit /b 1


:wait_for_http
set "URL=%~1"
set "MAX_TRIES=%~2"
set "SLEEP_SECONDS=%~3"
set /a TRY=0

:http_loop
set /a TRY+=1
curl.exe -I --max-time 8 "%URL%" >nul 2>&1
if %errorlevel% equ 0 (
  echo OK: %URL%
  exit /b 0
)

echo Sin respuesta todavia: %URL% ^(intento %TRY%/%MAX_TRIES%^)
if %TRY% GEQ %MAX_TRIES% exit /b 1
timeout /t %SLEEP_SECONDS% /nobreak >nul
goto :http_loop


:image_error
echo.
echo ERROR: Falta alguna imagen necesaria.
echo Ejecute primero 1_preparar_atom.bat.
pause
exit /b 1


:service_error
echo.
echo ERROR: Un servicio base no ha quedado listo.
echo.
docker compose ps
echo.
echo Logs recientes:
docker compose logs --tail=160
pause
exit /b 1


:http_error
echo.
echo ERROR: Percona y Elasticsearch estan listos, pero AtoM no responde en http://localhost:8080.
echo.
echo Estado de servicios:
docker compose ps
echo.
echo Logs recientes de AtoM:
docker compose logs --tail=200 atom
echo.
echo Logs recientes de Nginx:
docker compose logs --tail=200 nginx
echo.
pause
exit /b 1
