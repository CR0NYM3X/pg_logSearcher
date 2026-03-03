#!/bin/bash
# =============================================================================
# audit_pg_logs.sh  —  Auditoría de conexiones PostgreSQL desde logs comprimidos
# Optimizado: paralelismo multi-core + una sola descompresión por archivo
# Los archivos .tar.gz originales NUNCA son modificados ni eliminados.
#
# Detecta DOS escenarios de actividad:
#   [CONN] connection authorized / connection received  (log bien configurado)
#   [STMT] LOG:  statement: ...                        (log sin log_connections)
# En ambos casos el usuario se valida por el campo[7] exacto del header.
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
# Patrón: " usuario [0-9]"
# - Espacio a la izquierda  → evita capturar "mariajose" buscando "jose"
# - Espacio + dígito a la derecha → el PID siempre es número, garantiza
#   que el usuario no es parte de otra palabra como "jose-admin"
# Esto resuelve el problema de application_name con espacios, que haría
# fallar cualquier conteo de campos para ubicar al usuario en el header.
patron_usuarios=$(printf ' %s [0-9]|' "${lista_usuarios[@]}" | sed 's/|$//')

# ── Función exportada: procesa UN archivo .tar.gz ─────────────────────────────
#
# ESTRUCTURA DEL HEADER PostgreSQL:
#   <FECHA HORA TZ IP(PUERTO) APP_NAME DATABASE USUARIO PID SESSION_ID STATE>
#    [1]   [2]  [3]   [4]       [5]      [6]     [7]    [8]    [9]     [10]
#
# VALIDACIÓN EXACTA: awk compara campo[7] == usuario para evitar falsos positivos.
# Esto impide que un usuario cuyo nombre coincide con una base de datos genere
# una entrada errónea.
#
# EXTRACCIÓN DE IP: campo[4] tiene formato IP(PUERTO), se elimina (PUERTO).
#
# COMANDO DE LECTURA: tar xOf (no zcat) para evitar leer el header binario del tar.
#
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
    local tmp_file="$TEMP_DIR/${nombre_base}.filtered"

    # ── Paso 1: extraer el contenido del .tar.gz y pre-filtrar ───────────────
    # tar xOf extrae el contenido del archivo sin el header binario (a diferencia de zcat)
    # Se capturan líneas con cualquiera de los dos tipos de actividad que contengan
    # al menos uno de los usuarios buscados (filtro rápido, validación exacta en paso 2)
    tar xOf "$archivo" 2>/dev/null \
        | grep -a -E "(connection authorized|connection received|LOG:[[:space:]]+statement:)" \
        | grep -a -iE "$patron_usuarios" \
        > "$tmp_file"

    if [ ! -s "$tmp_file" ]; then
        for usuario in "${lista_usuarios[@]}"; do
            echo "[$(date +%H:%M:%S)] Archivo: $nombre_gz -> VACÍO" \
                >> "$RESULT_BASE_DIR/$usuario/seguimiento_revision.txt"
        done
        rm -f "$tmp_file"
        return
    fi

    # ── Paso 2: distribuir por usuario usando el mismo patrón exacto ────────
    # Se reutiliza el patrón " usuario [0-9]" para filtrar por usuario específico.
    # La IP se extrae del campo[4] del header con awk: este campo SIEMPRE es
    # la IP porque fecha(1)+hora(2)+tz(3) son fijos y la IP va justo después.
    for usuario in "${lista_usuarios[@]}"; do
        local destino_log="$RESULT_BASE_DIR/$usuario/${nombre_base}.log"
        local destino_ips="$RESULT_BASE_DIR/$usuario/ips_detectadas.tmp.${nombre_base}"
        local patron_usr=" ${usuario} [0-9]"

        grep -aiE "$patron_usr" "$tmp_file"         | awk '{
            line = $0
            sub(/^</, "", line)
            header = line
            sub(/>.*/, "", header)
            n = split(header, c, " ")
            print $0
            if (n >= 4) {
                ip = c[4]
                gsub(/\([^)]*\)/, "", ip)
                if (ip != "") print ip > "/dev/stderr"
            }
        }' > "$destino_log" 2> "$destino_ips"

        local ts
        ts=$(date +%H:%M:%S)

        if [ -s "$destino_log" ]; then
            echo "[$ts] Archivo: $nombre_gz -> ENCONTRADO" \
                >> "$RESULT_BASE_DIR/$usuario/seguimiento_revision.txt"
        else
            rm -f "$destino_log"
            echo "[$ts] Archivo: $nombre_gz -> VACÍO" \
                >> "$RESULT_BASE_DIR/$usuario/seguimiento_revision.txt"
        fi

        [ ! -s "$destino_ips" ] && rm -f "$destino_ips"
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

# ── Consolidar IPs por usuario: deduplicar, ordenar, quitar vacíos ───────────
for usuario in "${lista_usuarios[@]}"; do
    USER_FOLDER="$RESULT_BASE_DIR/$usuario"
    IP_FINAL="$USER_FOLDER/ips_detectadas.txt"
    tmp_ips=("$USER_FOLDER"/ips_detectadas.tmp.*)

    if [ ${#tmp_ips[@]} -gt 0 ] && [ -e "${tmp_ips[0]}" ]; then
        cat "${tmp_ips[@]}" 2>/dev/null \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
            | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n \
            | uniq \
            > "$IP_FINAL"
        rm -f "${tmp_ips[@]}"
        [ ! -s "$IP_FINAL" ] && rm -f "$IP_FINAL"
    fi
done

# ── Generar reporte general ───────────────────────────────────────────────────
REPORTE_GENERAL="$RESULT_BASE_DIR/reporte_general.txt"
FECHA_FIN=$(date)

{
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║         REPORTE GENERAL DE AUDITORÍA PostgreSQL               ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Fecha de ejecución : $FECHA_FIN"
    echo "  Ruta de logs       : $LOG_PATH"
    echo "  Archivos revisados : ${#archivos[@]}"
    echo "  Usuarios auditados : ${#lista_usuarios[@]}"
    echo "  CPUs utilizadas    : $NUM_CPUS de $CPUS_DISPONIBLES disponibles"
    echo ""
    echo "  Tipos de actividad detectados:"
    echo "    [CONN] connection authorized / connection received"
    echo "    [STMT] LOG: statement (actividad sin evento de conexión registrado)"
    echo ""

    # Clasificar usuarios
    usuarios_con_hits=()
    usuarios_sin_hits=()
    for usuario in "${lista_usuarios[@]}"; do
        TRACKING_FILE="$RESULT_BASE_DIR/$usuario/seguimiento_revision.txt"
        cnt=$(grep -c "ENCONTRADO" "$TRACKING_FILE" 2>/dev/null || true)
        cnt=$(echo "$cnt" | tr -d '[:space:]')
        if [ "${cnt:-0}" -gt 0 ] 2>/dev/null; then
            usuarios_con_hits+=("$usuario")
        else
            usuarios_sin_hits+=("$usuario")
        fi
    done

    # ── Sección CON actividad ─────────────────────────────────────────────────
    echo "════════════════════════════════════════════════════════════════"
    echo "  ✔  USUARIOS CON ACTIVIDAD DETECTADA  (${#usuarios_con_hits[@]} de ${#lista_usuarios[@]})"
    echo "════════════════════════════════════════════════════════════════"

    if [ ${#usuarios_con_hits[@]} -eq 0 ]; then
        echo ""
        echo "  (ningún usuario presentó actividad en los logs revisados)"
    else
        for usuario in "${usuarios_con_hits[@]}"; do
            TRACKING_FILE="$RESULT_BASE_DIR/$usuario/seguimiento_revision.txt"
            IP_FILE="$RESULT_BASE_DIR/$usuario/ips_detectadas.txt"
            encontrados=$(grep -c "ENCONTRADO" "$TRACKING_FILE" 2>/dev/null || echo 0)
            encontrados=$(echo "$encontrados" | tr -d '[:space:]')

            # Contar tipos de actividad revisando los .log generados
            conn_count=0
            stmt_count=0
            while IFS= read -r logfile; do
                if grep -qaE "connection authorized|connection received" "$logfile" 2>/dev/null; then
                    conn_count=$((conn_count + 1))
                fi
                if grep -qaE "LOG:[[:space:]]+statement:" "$logfile" 2>/dev/null; then
                    stmt_count=$((stmt_count + 1))
                fi
            done < <(find "$RESULT_BASE_DIR/$usuario" -maxdepth 1 -name "*.log" 2>/dev/null)

            echo ""
            echo "  ┌─ Usuario : $usuario"
            echo "  │  Archivos con actividad : $encontrados"
            [ "$conn_count" -gt 0 ] && echo "  │  [CONN] Archivos con connection events : $conn_count"
            [ "$stmt_count" -gt 0 ] && echo "  │  [STMT] Archivos con statements        : $stmt_count"
            echo "  │"
            echo "  │  Archivos donde se encontró actividad:"
            grep "ENCONTRADO" "$TRACKING_FILE" | while IFS= read -r linea; do
                nombre=$(echo "$linea" | grep -oP 'Archivo: \K[^\s]+')
                echo "  │    - $nombre"
            done
            echo "  │"

            # IPs detectadas
            if [ -s "$IP_FILE" ]; then
                ip_count=$(wc -l < "$IP_FILE" | tr -d ' ')
                echo "  │  IPs de origen detectadas ($ip_count única/s):"
                while IFS= read -r ip; do
                    if [[ "$ip" == "127.0.0.1" ]] || [[ "$ip" == "::1" ]]; then
                        echo "  │    • $ip  ← conexión local"
                    else
                        echo "  │    • $ip"
                    fi
                done < "$IP_FILE"
            else
                echo "  │  IPs de origen : no se pudieron extraer"
            fi

            echo "  │"
            echo "  │  Detalle completo : $RESULT_BASE_DIR/$usuario/seguimiento_revision.txt"
            echo "  └──────────────────────────────────────────────────────────────"
        done
    fi

    echo ""

    # ── Sección SIN actividad ─────────────────────────────────────────────────
    echo "════════════════════════════════════════════════════════════════"
    echo "  ✘  USUARIOS SIN ACTIVIDAD  (${#usuarios_sin_hits[@]} de ${#lista_usuarios[@]})"
    echo "════════════════════════════════════════════════════════════════"

    if [ ${#usuarios_sin_hits[@]} -eq 0 ]; then
        echo ""
        echo "  (todos los usuarios auditados tuvieron actividad registrada)"
    else
        echo ""
        echo "  ⚠  Los siguientes usuarios NO registraron ninguna conexión"
        echo "     ni actividad en ninguno de los ${#archivos[@]} archivos revisados."
        echo "     CANDIDATOS A ELIMINACIÓN:"
        echo ""
        for usuario in "${usuarios_sin_hits[@]}"; do
            echo "    ✘  $usuario"
        done
    fi

    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "  FIN DEL REPORTE"
    echo "════════════════════════════════════════════════════════════════"

} > "$REPORTE_GENERAL"

# ── Resumen en pantalla ───────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   Proceso Completado                             ║"
echo "╚══════════════════════════════════════════════════╝"
echo "  Resultados en: $RESULT_BASE_DIR"
echo ""
for usuario in "${lista_usuarios[@]}"; do
    TRACKING_FILE="$RESULT_BASE_DIR/$usuario/seguimiento_revision.txt"
    encontrados=$(grep -c "ENCONTRADO" "$TRACKING_FILE" 2>/dev/null | awk '{s+=$1} END{print s+0}')
    vacios=$(grep -c "VACÍO" "$TRACKING_FILE" 2>/dev/null | awk '{s+=$1} END{print s+0}')
    echo "  [$usuario]"
    echo "    Archivos con hits : $encontrados"
    echo "    Archivos vacíos   : $vacios"
    echo "    Seguimiento       : $TRACKING_FILE"
    echo "  ------------------------------------------"
done
echo ""
echo "  ► Reporte general: $REPORTE_GENERAL"
echo ""
