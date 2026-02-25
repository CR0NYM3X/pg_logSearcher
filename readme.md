
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
/sysx/data/pg_log/resultados_user_log/
├── admin_db/
│   ├── seguimiento_revision.txt   # Historial de archivos procesados
│   ├── postgresql-251201.log      # Registros encontrados el día 01
│   └── postgresql-251202.log      # Registros encontrados el día 02
└── ventas_pos/
    ├── seguimiento_revision.txt
    └── postgresql-251201.log

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
 grep "connection authorized" /sysx/data/pg_log/resultados_user_log/admin_db/postgresql-251201.log
```text


### ✨ Características Clave

* **Búsqueda no destructiva:** Lee directamente de archivos comprimidos (`zcat`).
* **Aislamiento de datos:** Crea archivos `.log` individuales por cada día donde hubo actividad.
* **Control de integridad:** Reporta archivos procesados incluso si no hubo hallazgos para asegurar una revisión completa.
 
