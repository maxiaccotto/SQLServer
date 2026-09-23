/* ================================================================
   SCRIPT PARALELO (v3) — Solo UNA cosa: ¿conviene el tipo JSON
   nativo de SQL Server 2025 en vez de NVARCHAR(MAX)?
   Post: "Buenas prácticas de JSON en SQL Server" (triggerdb.com)
   Autor: Maximiliano Accotto

   Reordenando el enfoque: este script deja de mezclar dos preguntas
   distintas. La pregunta de "¿tabla separada o JSON adentro?" ya
   quedó resuelta y demostrada en 01_json_varcharmax_completo.sql —
   esa es la parte de buenas prácticas del post, y no se toca acá.

   Este script SOLO compara tipo de dato, dejando la arquitectura
   fija — un único diseño de tabla, con el JSON adentro (que ya
   tenés armado y cargado), en dos versiones:

     - dbo.Movimientos_ConJson       -> YA EXISTE, NVARCHAR(MAX) + CHECK ISJSON
     - dbo.Movimientos_ConJson_2025  -> NUEVA, mismo diseño, mismos datos,
                                         columnas JsonEntrada/JsonSalida
                                         como JSON nativo

   Ya NO se toca MovimientosAnexos ni se crea ninguna versión "_2025"
   de la arquitectura separada — eso sería repetir la comparación de
   arquitectura dos veces y mezclar las dos preguntas. Acá la única
   variable que cambia es el tipo de dato del JSON.

   Qué mide:
     1) Lectura — sin índice y con índice no cubriente.
     2) Tamaño real del clustered index (páginas y GB).
     3) Tiempo de REBUILD, corrido uno atrás del otro en la misma
        sesión para que la comparación sea fresca.
     4) Resumen final (sp_spaceused).

   Con esto alcanza para responder la pregunta de "¿me conviene el
   tipo de dato nativo o no?" sin la arquitectura como variable extra
   metida en el medio.

   Recordatorio de la documentación de Microsoft (ya confirmado):
     - El tipo JSON es GA en SQL Server 2025 (17.x), funciona en
       cualquier compatibility level.
     - NVARCHAR(MAX) -> JSON necesita CAST explícito.
     - JSON no puede ser columna clave de índice normal, solo INCLUDE
       (no nos afecta, nunca indexamos el JSON directamente).

   ⚠️ Requiere haber corrido antes 01_json_varcharmax_completo.sql
   (para que existan TriggerDB_Demo_JSON y Movimientos_ConJson).
   Regenera el seed de 5.000.000 de filas solo para cargar la tabla
   nueva, y lo vuelve a borrar al terminar.
   ================================================================ */


-- ================================================================
-- 0) Verificaciones — nada de bases, filegroups ni tablas de más
-- ================================================================
IF DB_ID('TriggerDB_Demo_JSON') IS NULL
BEGIN
    RAISERROR('No existe TriggerDB_Demo_JSON. Corré primero 01_json_varcharmax_completo.sql.', 16, 1);
    RETURN;
END
GO

USE TriggerDB_Demo_JSON;
GO

IF OBJECT_ID('dbo.Movimientos_ConJson', 'U') IS NULL
BEGIN
    RAISERROR('No existe dbo.Movimientos_ConJson. Corré primero 01_json_varcharmax_completo.sql.', 16, 1);
    RETURN;
END
GO


-- ================================================================
-- 1) Regenerar el seed de 5.000.000 de filas (mismo generador y
--    mismo JSON que el script 01), solo para cargar la tabla nueva
-- ================================================================
DROP TABLE IF EXISTS dbo.Seed_Movimientos_5M;
GO

;WITH L0 AS (SELECT 1 AS c UNION ALL SELECT 1),
L1 AS (SELECT 1 AS c FROM L0 a CROSS JOIN L0 b),
L2 AS (SELECT 1 AS c FROM L1 a CROSS JOIN L1 b),
L3 AS (SELECT 1 AS c FROM L2 a CROSS JOIN L2 b),
L4 AS (SELECT 1 AS c FROM L3 a CROSS JOIN L3 b),
L5 AS (SELECT 1 AS c FROM L4 a CROSS JOIN L4 b),
Numeros AS (
    SELECT TOP (5000000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM L5
)
SELECT
    n                                               AS MovimientoId,
    (n % 5000) + 1                                  AS CuentaId,
    DATEADD(SECOND, n, '2024-01-01')                 AS FechaMovimiento,
    CASE WHEN n % 2 = 0 THEN 'DEBITO' ELSE 'CREDITO' END AS TipoMovimiento,
    CAST((n % 10000) + 1 AS DECIMAL(18,2))           AS Importe,
    'PROCESADO'                                      AS Estado,
    N'{
        "origen": "APP_MOVIL",
        "canal": "' + CASE WHEN n % 3 = 0 THEN 'TRANSFERENCIA' WHEN n % 3 = 1 THEN 'DEBITO_AUTOMATICO' ELSE 'CAJERO' END + N'",
        "cliente": {
            "id": ' + CAST(n AS NVARCHAR(10)) + N',
            "nombre": "Cliente Demo ' + CAST(n AS NVARCHAR(10)) + N'",
            "email": "cliente' + CAST(n AS NVARCHAR(10)) + N'@demo.com",
            "direccion": "Av. Siempre Viva ' + CAST(n % 9999 AS NVARCHAR(10)) + N', CABA",
            "telefono": "+54911' + RIGHT('00000000' + CAST(n AS NVARCHAR(10)), 8) + N'"
        },
        "detalle": [
            {"concepto": "Producto A", "cantidad": 2, "precioUnitario": 150.00, "subtotal": 300.00},
            {"concepto": "Producto B", "cantidad": 1, "precioUnitario": 89.90,  "subtotal": 89.90},
            {"concepto": "Producto C", "cantidad": 5, "precioUnitario": 12.50,  "subtotal": 62.50},
            {"concepto": "Producto D", "cantidad": 3, "precioUnitario": 45.00,  "subtotal": 135.00},
            {"concepto": "Envio",      "cantidad": 1, "precioUnitario": 25.00,  "subtotal": 25.00},
            {"concepto": "Comision",   "cantidad": 1, "precioUnitario": 12.50,  "subtotal": 12.50},
            {"concepto": "Impuesto",   "cantidad": 1, "precioUnitario": 3.10,   "subtotal": 3.10}
        ],
        "metadata": {
            "ip": "192.168.1.' + CAST(n % 255 AS NVARCHAR(3)) + N'",
            "dispositivo": "iOS 17",
            "appVersion": "4.2.1",
            "sessionId": "sess-' + CAST(n AS NVARCHAR(10)) + N'-' + CAST(n % 97 AS NVARCHAR(10)) + N'"
        }
    }'                                               AS JsonEntrada,
    N'{
        "resultado": "OK",
        "codigoAutorizacion": "AUTH-' + CAST(n AS NVARCHAR(10)) + N'",
        "tiempoProcesamientoMs": ' + CAST((n % 300) + 20 AS NVARCHAR(10)) + N',
        "validaciones": [
            {"regla": "SALDO_SUFICIENTE", "resultado": true},
            {"regla": "CUENTA_ACTIVA", "resultado": true},
            {"regla": "LIMITE_DIARIO", "resultado": true}
        ]
    }'                                               AS JsonSalida
INTO dbo.Seed_Movimientos_5M
FROM Numeros;
GO


-- ================================================================
-- 2) Única tabla nueva: mismo diseño que Movimientos_ConJson,
--    JSON nativo en vez de NVARCHAR(MAX)
-- ================================================================
DROP TABLE IF EXISTS dbo.Movimientos_ConJson_2025;
GO

CREATE TABLE dbo.Movimientos_ConJson_2025
(
    MovimientoId    INT           NOT NULL PRIMARY KEY CLUSTERED,
    CuentaId        INT           NOT NULL,
    FechaMovimiento DATETIME2(0)  NOT NULL,
    TipoMovimiento  VARCHAR(10)   NOT NULL,
    Importe         DECIMAL(18,2) NOT NULL,
    Estado          VARCHAR(20)   NOT NULL,
    JsonEntrada     JSON NULL,
    JsonSalida      JSON NULL
);
GO

-- CAST explícito: NVARCHAR(MAX) -> JSON no es una conversión implícita
INSERT INTO dbo.Movimientos_ConJson_2025 (MovimientoId, CuentaId, FechaMovimiento, TipoMovimiento, Importe, Estado, JsonEntrada, JsonSalida)
SELECT MovimientoId, CuentaId, FechaMovimiento, TipoMovimiento, Importe, Estado,
       CAST(JsonEntrada AS JSON), CAST(JsonSalida AS JSON)
FROM dbo.Seed_Movimientos_5M;
GO

DROP TABLE IF EXISTS dbo.Seed_Movimientos_5M;
GO


-- ================================================================
-- 3) LECTURA — ETAPA A: sin índice adicional
-- ================================================================
CHECKPOINT; DBCC DROPCLEANBUFFERS;
GO

DROP INDEX IF EXISTS IX_ConJson_CuentaId ON dbo.Movimientos_ConJson
DROP INDEX IF EXISTS IX_ConJson2025_CuentaId ON dbo.Movimientos_ConJson_2025

PRINT '=== LECTURA A — Movimientos_ConJson (NVARCHAR(MAX)) — sin índice adicional ===';

SELECT TOP (50) MovimientoId, CuentaId, FechaMovimiento, Importe, Estado
FROM dbo.Movimientos_ConJson
WHERE CuentaId = 42
ORDER BY FechaMovimiento DESC OPTION (RECOMPILE);

SELECT TOP (50) MovimientoId, CuentaId, FechaMovimiento, Importe, Estado
FROM dbo.Movimientos_ConJson_2025
WHERE CuentaId = 42
ORDER BY FechaMovimiento DESC OPTION (RECOMPILE);
GO


-- ================================================================
-- 4) LECTURA — ETAPA B: índice por CuentaId SIN INCLUDE (no cubriente)
-- ================================================================
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_ConJson_CuentaId' AND object_id = OBJECT_ID('dbo.Movimientos_ConJson'))
    CREATE NONCLUSTERED INDEX IX_ConJson_CuentaId ON dbo.Movimientos_ConJson (CuentaId);
GO

CREATE NONCLUSTERED INDEX IX_ConJson2025_CuentaId ON dbo.Movimientos_ConJson_2025 (CuentaId);
GO

CHECKPOINT; DBCC DROPCLEANBUFFERS;
GO

--PRINT '=== LECTURA B — Movimientos_ConJson (NVARCHAR(MAX)) — índice no cubriente ===';
SELECT TOP (50) MovimientoId, CuentaId, FechaMovimiento, Importe, Estado
FROM dbo.Movimientos_ConJson
WHERE CuentaId = 42
ORDER BY FechaMovimiento DESC OPTION (RECOMPILE);
GO

--PRINT '=== LECTURA B — Movimientos_ConJson_2025 (JSON nativo) — índice no cubriente ===';
SELECT TOP (50) MovimientoId, CuentaId, FechaMovimiento, Importe, Estado
FROM dbo.Movimientos_ConJson_2025
WHERE CuentaId = 42
ORDER BY FechaMovimiento DESC OPTION (RECOMPILE);
GO


-- ================================================================
-- 5) Tamaño real del clustered index — las dos versiones, una
--    al lado de la otra
-- ================================================================
SELECT
    OBJECT_NAME(ips.object_id)                                 AS Tabla,
    ips.avg_record_size_in_bytes,
    ips.page_count,
    ips.record_count,
    CAST(ips.page_count * 8.0 / 1024 / 1024 AS DECIMAL(10,2))  AS TamanioGB
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'DETAILED') ips
WHERE OBJECT_NAME(ips.object_id) IN ('Movimientos_ConJson', 'Movimientos_ConJson_2025')
  AND ips.index_id = 1
  AND ips.index_level = 0
ORDER BY Tabla;
GO


-- ================================================================
-- 6) Tiempo de REBUILD — viejo vs nativo, uno atrás del otro,
--    en la misma sesión, para que sea una comparación fresca
-- ================================================================
PRINT '=== REBUILD — Movimientos_ConJson (NVARCHAR(MAX)) ===';
SET STATISTICS TIME ON;
ALTER INDEX ALL ON dbo.Movimientos_ConJson REBUILD;
SET STATISTICS TIME OFF;
GO

PRINT '=== REBUILD — Movimientos_ConJson_2025 (JSON nativo) ===';
SET STATISTICS TIME ON;
ALTER INDEX ALL ON dbo.Movimientos_ConJson_2025 REBUILD;
SET STATISTICS TIME OFF;
GO


-- ================================================================
-- 7) Resumen final de tamaños
-- ================================================================
EXEC sp_spaceused 'dbo.Movimientos_ConJson';
EXEC sp_spaceused 'dbo.Movimientos_ConJson_2025';
GO


-- ================================================================
-- Limpieza (opcional) — solo la tabla nueva de este script
-- ================================================================
-- DROP TABLE IF EXISTS dbo.Movimientos_ConJson_2025;
