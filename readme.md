
# pg_logSearcher 🚀

**pg_logSearcher** es una utilidad ágil en Bash diseñada para la auditoría de usuarios en logs comprimidos de PostgreSQL. Permite extraer actividad específica de archivos históricos `.tar.gz` sin necesidad de descompresión manual, organizando los hallazgos en reportes estructurados.

## 🛠️ Instalación y Uso

1. **Dar permisos de ejecución:**
Antes de usar el script, asegúrate de otorgar los permisos necesarios:
```bash
chmod +x pg_logsearcher.sh

```


2. **Ejecutar la herramienta:**
Pasa como primer argumento la **ruta de los logs** y como segundo la **lista de usuarios** separados por comas (sin espacios):
```bash
./pg_logsearcher.sh /sysx/data/pg_log "admin_db,ventas_pos,monitor_apps"
```



## 📊 Flujo de Trabajo

Al ejecutarse, el script procesa cada archivo que cumpla el formato `postgresql-YYMMDD.tar.gz` y muestra el progreso en tiempo real:

```text
--- Iniciando Auditoría Detallada ---
Procesando usuario: [admin_db]...
  + Encontrado en postgresql-251201.tar.gz
  + Encontrado en postgresql-251202.tar.gz
Finalizado usuario: admin_db. Revisar seguimiento_revision.txt
-------------------------------------------
Procesando usuario: [ventas_pos]...
  + Encontrado en postgresql-251201.tar.gz
Finalizado usuario: ventas_pos. Revisar seguimiento_revision.txt
...
Proceso total completado en /sysx/data/pg_log/resultados_user_log

```

## 📂 Estructura de Resultados

Los resultados se almacenan automáticamente en una carpeta llamada `resultados_user_log` dentro de la ruta especificada, organizada por usuario:

```text
resultados_user_log - 10.0.0.100/  # Carpeta principal con la IP del servidor
├── reporte_general.txt            # Txt Reporte general de todos los usuarios y IPs encontradas
├── sysusariostest1/               # Carpeta con nombre del usuario
│   ├── seguimiento_revision.txt   # Txt con estatus de cada archivo log revisado.
│   ├── postgresql-251201.log      # Log con Registros encontrados el día 01
│   └── postgresql-251202.log      # Log con  Registros encontrados el día 02
│   └── ips_detectadas.txt         # Txt con IPs que se encontraron en todos los logs procesados
└── sysusariostest2/
    └── seguimiento_revision.txt


```

## 📝 Reporte de Seguimiento

Cada usuario cuenta con un archivo `seguimiento_revision.txt` que garantiza la trazabilidad de la auditoría, indicando qué archivos contenían datos y cuáles estaban vacíos:

```text
Reporte de revisión para el usuario: admin_db
Fecha de ejecución: Wed Feb 25 11:15:00 MST 2026
-------------------------------------------
[11:15:01] Archivo: postgresql-251201.tar.gz -> ENCONTRADO
[11:15:05] Archivo: postgresql-251202.tar.gz -> ENCONTRADO
[11:15:10] Archivo: postgresql-251203.tar.gz -> VACÍO

```

# Extraer Conexiones del usuarios
Puedes usar este filtro para ser mas especifico en caso de que quieras traer solo las conexiones 
```text
 grep -Ei "connection authorized|connection received" /sysx/data/pg_log/resultados_user_log/admin_db/postgresql-251201.log
```


----


### Mejoras que voy a aplicar

1. **Argumento opcional para controlar CPUs** → `$3`
2. **Validación** de que el número sea válido
3. **Modo seguro**: nunca usar más CPUs de las disponibles---

## Cómo se usa ahora

### Sin controlar CPUs (usa todos los disponibles)
```bash
./audit_pg_logs.sh /var/log/postgresql "postgres,appuser"
```

### Controlando cuántas CPUs usar
```bash
./audit_pg_logs.sh /var/log/postgresql "postgres,appuser" 4
```

### Si pones más CPUs de las que hay, te avisa y se ajusta solo
```bash
./audit_pg_logs.sh /var/log/postgresql "postgres,appuser" 99
# AVISO: Solicitaste 99 CPUs pero solo hay 8 disponibles.
#        Se usarán 8.
```

---

## Qué muestra al arrancar
```
╔══════════════════════════════════════════════════╗
║   Auditoría de Conexiones PostgreSQL             ║
╚══════════════════════════════════════════════════╝
  Ruta de logs    : /var/log/postgresql
  CPUs disponibles: 8
  CPUs a usar     : 4          ← ves exactamente cuántas usará
  Usuarios        : postgres appuser
  Archivos .tar.gz encontrados: 24
```

---

## Sobre la seguridad de tus archivos originales

El script **solo hace lectura** sobre los `.tar.gz` con `zcat`. Los únicos `rm` que existen son sobre archivos que el propio script creó:

| Archivo que borra | Cuándo | Dónde |
|---|---|---|
| `resultados_user_log/.tmp_extracted/*.filtered` | Al terminar cada archivo | Carpeta temporal del script |
| `resultados_user_log/usuario/*.log` vacíos | Si no encontró nada | Carpeta de resultados |

