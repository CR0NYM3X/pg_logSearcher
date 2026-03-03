#!/bin/bash
# =============================================================================
# audit_pg_logs.sh  —  Auditoría de conexiones PostgreSQL desde logs comprimidos
# Optimizado: paralelismo multi-core + una sola descompresión por archivo
# =============================================================================

# ── Argumentos ────────────────────────────────────────────────────────────────
if [ "$#" -ne 2 ]; then
    echo "Uso: $0 /ruta/a/logs \"usuario1,usuario2,usuario3\""
    exit 1
fi

LOG_PATH="$1"
USUARIOS_RAW="$2"
RESULT_BASE_DIR="$LOG_PATH/resultados_user_log"
TEMP_DIR="$RESULT_BASE_DIR/.tmp_extracted"   # directorio temporal de trabajo

# ── Validaciones ──────────────────────────────────────────────────────────────
if [ ! -d "$LOG_PATH" ]; then
    echo "ERROR: La ruta '$LOG_PATH' no existe."
    exit 1
fi

# ── Preparar usuarios ─────────────────────────────────────────────────────────
IFS=',' read -r -a lista_usuarios <<< "$USUARIOS_RAW"

# Limpiar espacios en cada usuario
for i in "${!lista_usuarios[@]}"; do
    lista_usuarios[$i]=$(echo "${lista_usuarios[$i]}" | xargs)
done

# ── Detectar CPUs disponibles ─────────────────────────────────────────────────
NUM_CPUS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

echo "--- Iniciando Auditoría Detallada (Paralela) ---"
echo "    CPUs disponibles: $NUM_CPUS"
echo "    Usuarios a auditar: ${lista_usuarios[*]}"
echo "------------------------------------------------"

shopt -s nullglob
archivos=("$LOG_PATH"/postgresql-[0-9][0-9][0-9][0-9][0-9][0-9].tar.gz)

if [ ${#archivos[@]} -eq 0 ]; then
    echo "ADVERTENCIA: No se encontraron archivos .tar.gz en '$LOG_PATH'."
    exit 0
fi

echo "    Archivos encontrados: ${#archivos[@]}"
echo "------------------------------------------------"

# ── Crear estructura de directorios ───────────────────────────────────────────
mkdir -p "$TEMP_DIR"
for usuario in "${lista_usuarios[@]}"; do
    mkdir -p "$RESULT_BASE_DIR/$usuario"
done

# ── Construir patrón grep combinado ──────────────────────────────────────────
# Unimos todos los usuarios en un solo patrón para hacer UNA sola pasada por archivo
# Ejemplo: "user1\|user2\|user3"
patron_usuarios=$(IFS='|'; echo "${lista_usuarios[*]}")

# ── Función exportada: procesa UN archivo .tar.gz ─────────────────────────────
# Recibe: ruta completa del .tar.gz
# Estrategia: descomprime una sola vez → filtra líneas relevantes →
#             luego distribuye por usuario con awk (todo en memoria/pipe)
procesar_archivo() {
    local archivo="$1"
    local RESULT_BASE_DIR="$2"
    local TEMP_DIR="$3"
    local patron_usuarios="$4"
    # usuarios como cadena separada por espacio (reconstruimos array)
    local usuarios_str="$5"
    IFS=' ' read -r -a lista_usuarios <<< "$usuarios_str"

    local nombre_gz
    nombre_gz=$(basename "$archivo")
    local nombre_base="${nombre_gz%.tar.gz}"

    # Archivo temporal con líneas relevantes de TODOS los usuarios
    local tmp_file="$TEMP_DIR/${nombre_base}.filtered"

    # Una sola descompresión + filtro de líneas de conexión
    zcat "$archivo" \
        | grep -a -E "(connection authorized|connection received)" \
        | grep -a -iE "$patron_usuarios" \
        > "$tmp_file" 2>/dev/null

    # Si el archivo temporal está vacío, no hay nada que repartir
    if [ ! -s "$tmp_file" ]; then
        # Marcar VACÍO en tracking de cada usuario
        for usuario in "${lista_usuarios[@]}"; do
            local ts
            ts=$(date +%H:%M:%S)
            echo "[$ts] Archivo: $nombre_gz -> VACÍO" \
                >> "$RESULT_BASE_DIR/$usuario/seguimiento_revision.txt"
        done
        rm -f "$tmp_file"
        return
    fi

    # Distribuir líneas por usuario (una pasada del archivo temporal)
    for usuario in "${lista_usuarios[@]}"; do
        local destino_log="$RESULT_BASE_DIR/$usuario/${nombre_base}.log"
        local ts
        ts=$(date +%H:%M:%S)

        # grep case-insensitive sobre el archivo ya filtrado (mucho más rápido)
        grep -a -i "$usuario" "$tmp_file" > "$destino_log"

        if [ -s "$destino_log" ]; then
            echo "[$ts] Archivo: $nombre_gz -> ENCONTRADO" \
                >> "$RESULT_BASE_DIR/$usuario/seguimiento_revision.txt"
        else
            rm -f "$destino_log"
            echo "[$ts] Archivo: $nombre_gz -> VACÍO" \
                >> "$RESULT_BASE_DIR/$usuario/seguimiento_revision.txt"
        fi
    done

    # Limpiar temporal
    rm -f "$tmp_file"
}

export -f procesar_archivo

# ── Inicializar tracking files ANTES del paralelo ────────────────────────────
for usuario in "${lista_usuarios[@]}"; do
    TRACKING_FILE="$RESULT_BASE_DIR/$usuario/seguimiento_revision.txt"
    {
        echo "Reporte de revisión para el usuario: $usuario"
        echo "Fecha de ejecución: $(date)"
        echo "-------------------------------------------"
    } > "$TRACKING_FILE"
    echo "Procesando usuario: [$usuario]..."
done

# ── Lanzar procesamiento paralelo ─────────────────────────────────────────────
USUARIOS_STR="${lista_usuarios[*]}"   # string plano para pasar a subprocesos

printf '%s\n' "${archivos[@]}" \
    | xargs -P "$NUM_CPUS" -I{} bash -c \
        'procesar_archivo "$1" "$2" "$3" "$4" "$5"' \
        _ {} \
        "$RESULT_BASE_DIR" \
        "$TEMP_DIR" \
        "$patron_usuarios" \
        "$USUARIOS_STR"

# ── Limpiar directorio temporal ───────────────────────────────────────────────
rmdir "$TEMP_DIR" 2>/dev/null   # solo si quedó vacío (debería estarlo)

# ── Resumen final ─────────────────────────────────────────────────────────────
echo ""
echo "================================================"
echo " Proceso total completado en: $RESULT_BASE_DIR"
echo "================================================"
for usuario in "${lista_usuarios[@]}"; do
    TRACKING_FILE="$RESULT_BASE_DIR/$usuario/seguimiento_revision.txt"
    encontrados=$(grep -c "ENCONTRADO" "$TRACKING_FILE" 2>/dev/null || echo 0)
    vacios=$(grep    -c "VACÍO"      "$TRACKING_FILE" 2>/dev/null || echo 0)
    echo "  [$usuario]  Archivos con hits: $encontrados  |  Vacíos: $vacios"
    echo "  Revisar: $TRACKING_FILE"
    echo "-------------------------------------------"
done
