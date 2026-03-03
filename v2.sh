#!/bin/bash
# =============================================================================
# audit_pg_logs.sh  —  Auditoría de conexiones PostgreSQL desde logs comprimidos
# Optimizado: paralelismo multi-core + una sola descompresión por archivo
# Los archivos .tar.gz originales NUNCA son modificados ni eliminados.
# =============================================================================

# ── Argumentos ────────────────────────────────────────────────────────────────
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo ""
    echo "Uso: $0 /ruta/a/logs \"usuario1,usuario2,usuario3\" [num_cpus]"
    echo ""
    echo "  Argumentos:"
    echo "    1) /ruta/a/logs     → Carpeta donde están los .tar.gz de PostgreSQL"
    echo "    2) \"user1,user2\"    → Usuarios a buscar, separados por coma"
    echo "    3) num_cpus         → (Opcional) Núcleos a usar. Por defecto: todos los disponibles"
    echo ""
    echo "  Ejemplos:"
    echo "    $0 /var/log/postgresql \"postgres,appuser\""
    echo "    $0 /var/log/postgresql \"postgres,appuser\" 4"
    echo ""
    exit 1
fi

LOG_PATH="$1"
USUARIOS_RAW="$2"
CPU_ARG="${3:-}"
RESULT_BASE_DIR="$LOG_PATH/resultados_user_log"
TEMP_DIR="$RESULT_BASE_DIR/.tmp_extracted"

# ── Validaciones ──────────────────────────────────────────────────────────────
if [ ! -d "$LOG_PATH" ]; then
    echo "ERROR: La ruta '$LOG_PATH' no existe."
    exit 1
fi

if [ -n "$CPU_ARG" ]; then
    if ! [[ "$CPU_ARG" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: num_cpus debe ser un número entero positivo (recibido: '$CPU_ARG')."
        exit 1
    fi
fi

# ── Preparar usuarios ─────────────────────────────────────────────────────────
IFS=',' read -r -a lista_usuarios <<< "$USUARIOS_RAW"
for i in "${!lista_usuarios[@]}"; do
    lista_usuarios[$i]=$(echo "${lista_usuarios[$i]}" | xargs)
done

# ── Calcular CPUs a usar ──────────────────────────────────────────────────────
CPUS_DISPONIBLES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

if [ -n "$CPU_ARG" ]; then
    if [ "$CPU_ARG" -gt "$CPUS_DISPONIBLES" ]; then
        echo "AVISO: Solicitaste $CPU_ARG CPUs pero solo hay $CPUS_DISPONIBLES disponibles."
        echo "       Se usarán $CPUS_DISPONIBLES."
        NUM_CPUS=$CPUS_DISPONIBLES
    else
        NUM_CPUS=$CPU_ARG
    fi
else
    NUM_CPUS=$CPUS_DISPONIBLES
fi

# ── Encabezado ────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   Auditoría de Conexiones PostgreSQL             ║"
echo "╚══════════════════════════════════════════════════╝"
echo "  Ruta de logs    : $LOG_PATH"
echo "  CPUs disponibles: $CPUS_DISPONIBLES"
echo "  CPUs a usar     : $NUM_CPUS"
echo "  Usuarios        : ${lista_usuarios[*]}"
echo "  Resultados en   : $RESULT_BASE_DIR"
echo "--------------------------------------------------"

shopt -s nullglob
archivos=("$LOG_PATH"/postgresql-[0-9][0-9][0-9][0-9][0-9][0-9].tar.gz)

if [ ${#archivos[@]} -eq 0 ]; then
    echo "ADVERTENCIA: No se encontraron archivos .tar.gz en '$LOG_PATH'."
    exit 0
fi

echo "  Archivos .tar.gz encontrados: ${#archivos[@]}"
echo "--------------------------------------------------"
echo ""

# ── Crear estructura de directorios ───────────────────────────────────────────
# NOTA: Solo se crean carpetas dentro de resultados_user_log/
#       Los archivos originales .tar.gz NO se tocan en ningún momento.
mkdir -p "$TEMP_DIR"
for usuario in "${lista_usuarios[@]}"; do
    mkdir -p "$RESULT_BASE_DIR/$usuario"
done

# ── Construir patrón grep combinado ──────────────────────────────────────────
patron_usuarios=$(IFS='|'; echo "${lista_usuarios[*]}")

# ── Función exportada: procesa UN archivo .tar.gz ─────────────────────────────
# SEGURIDAD: Esta función SOLO escribe en $RESULT_BASE_DIR y $TEMP_DIR.
#            Lee los .tar.gz con zcat (lectura pura, sin modificar).
#            Solo elimina archivos .filtered y .log vacíos que ella misma creó.
procesar_archivo() {
    local archivo="$1"
    local RESULT_BASE_DIR="$2"
    local TEMP_DIR="$3"
    local patron_usuarios="$4"
    local usuarios_str="$5"
    IFS=' ' read -r -a lista_usuarios <<< "$usuarios_str"

    local nombre_gz
    nombre_gz=$(basename "$archivo")
    local nombre_base="${nombre_gz%.tar.gz}"

    # Archivo temporal dentro de .tmp_extracted/ (creado por este script)
    local tmp_file="$TEMP_DIR/${nombre_base}.filtered"

    # Lectura del .tar.gz original (solo lectura, no se modifica)
    zcat "$archivo" \
        | grep -a -E "(connection authorized|connection received)" \
        | grep -a -iE "$patron_usuarios" \
        > "$tmp_file" 2>/dev/null

    if [ ! -s "$tmp_file" ]; then
        for usuario in "${lista_usuarios[@]}"; do
            local ts
            ts=$(date +%H:%M:%S)
            echo "[$ts] Archivo: $nombre_gz -> VACÍO" \
                >> "$RESULT_BASE_DIR/$usuario/seguimiento_revision.txt"
        done
        rm -f "$tmp_file"
        return
    fi

    for usuario in "${lista_usuarios[@]}"; do
        local destino_log="$RESULT_BASE_DIR/$usuario/${nombre_base}.log"
        local ts
        ts=$(date +%H:%M:%S)

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

    rm -f "$tmp_file"
}

export -f procesar_archivo

# ── Inicializar tracking files ────────────────────────────────────────────────
for usuario in "${lista_usuarios[@]}"; do
    TRACKING_FILE="$RESULT_BASE_DIR/$usuario/seguimiento_revision.txt"
    {
        echo "Reporte de revisión para el usuario: $usuario"
        echo "Fecha de ejecución: $(date)"
        echo "CPUs utilizadas: $NUM_CPUS de $CPUS_DISPONIBLES disponibles"
        echo "-------------------------------------------"
    } > "$TRACKING_FILE"
    echo "  Procesando usuario: [$usuario]..."
done
echo ""

# ── Lanzar procesamiento paralelo ─────────────────────────────────────────────
USUARIOS_STR="${lista_usuarios[*]}"

printf '%s\n' "${archivos[@]}" \
    | xargs -P "$NUM_CPUS" -I{} bash -c \
        'procesar_archivo "$1" "$2" "$3" "$4" "$5"' \
        _ {} \
        "$RESULT_BASE_DIR" \
        "$TEMP_DIR" \
        "$patron_usuarios" \
        "$USUARIOS_STR"

# ── Limpiar directorio temporal ───────────────────────────────────────────────
rmdir "$TEMP_DIR" 2>/dev/null

# ── Resumen final ─────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   Proceso Completado                             ║"
echo "╚══════════════════════════════════════════════════╝"
echo "  Resultados en: $RESULT_BASE_DIR"
echo ""
for usuario in "${lista_usuarios[@]}"; do
    TRACKING_FILE="$RESULT_BASE_DIR/$usuario/seguimiento_revision.txt"
    encontrados=$(grep -c "ENCONTRADO" "$TRACKING_FILE" 2>/dev/null || echo 0)
    vacios=$(grep    -c "VACÍO"       "$TRACKING_FILE" 2>/dev/null || echo 0)
    echo "  [$usuario]"
    echo "    Archivos con hits : $encontrados"
    echo "    Archivos vacíos   : $vacios"
    echo "    Seguimiento       : $TRACKING_FILE"
    echo "  ------------------------------------------"
done
echo ""
