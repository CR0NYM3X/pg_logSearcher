#!/bin/bash

# Comprobar argumentos
if [ "$#" -ne 2 ]; then
    echo "Uso: $0 /ruta/a/logs \"usuario1,usuario2,usuario3\""
    exit 1
fi

LOG_PATH=$1
USUARIOS_RAW=$2
RESULT_BASE_DIR="$LOG_PATH/resultados_user_log"

# Validar ruta
if [ ! -d "$LOG_PATH" ]; then
    echo "ERROR: La ruta '$LOG_PATH' no existe."
    exit 1
fi

# Convertir cadena de usuarios a array
IFS=',' read -r -a lista_usuarios <<< "$USUARIOS_RAW"

echo "--- Iniciando Auditoría Detallada ---"

# Habilitar nullglob para manejar archivos
shopt -s nullglob
archivos=("$LOG_PATH"/postgresql-[0-9][0-9][0-9][0-9][0-9][0-9].tar.gz)

for usuario in "${lista_usuarios[@]}"; do
    usuario_trim=$(echo "$usuario" | xargs)
    USER_FOLDER="$RESULT_BASE_DIR/$usuario_trim"
    
    # Crear la carpeta del usuario de inmediato
    mkdir -p "$USER_FOLDER"
    
    # Archivo de control para saber qué se revisó
    TRACKING_FILE="$USER_FOLDER/seguimiento_revision.txt"
    echo "Reporte de revisión para el usuario: $usuario_trim" > "$TRACKING_FILE"
    echo "Fecha de ejecución: $(date)" >> "$TRACKING_FILE"
    echo "-------------------------------------------" >> "$TRACKING_FILE"

    echo "Procesando usuario: [$usuario_trim]..."

    for archivo in "${archivos[@]}"; do
        nombre_gz=$(basename "$archivo")
        nombre_log="${nombre_gz%.tar.gz}.log"
        DESTINO_LOG="$USER_FOLDER/$nombre_log"

        # Buscar y guardar directamente en el archivo .log
        # Usamos un archivo temporal para verificar si hubo matches
        zcat "$archivo" | grep -i -a "$usuario_trim" > "$DESTINO_LOG"

        # Validar si el archivo tiene contenido
        if [ -s "$DESTINO_LOG" ]; then
            echo "[$(date +%H:%M:%S)] Archivo: $nombre_gz -> ENCONTRADO" >> "$TRACKING_FILE"
            echo "  + Encontrado en $nombre_gz"
        else
            # Si está vacío, lo borramos y marcamos como vacío en el seguimiento
            rm "$DESTINO_LOG"
            echo "[$(date +%H:%M:%S)] Archivo: $nombre_gz -> VACÍO" >> "$TRACKING_FILE"
        fi
    done
    echo "Finalizado usuario: $usuario_trim. Revisar $TRACKING_FILE"
    echo "-------------------------------------------"
done

echo "Proceso total completado en $RESULT_BASE_DIR"
