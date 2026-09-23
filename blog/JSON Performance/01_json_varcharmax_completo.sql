/* ================================================================
  
   Post: "Buenas prácticas de JSON en SQL Server" (triggerdb.com)
   Autor: Maximiliano Accotto

    - dbo.Movimientos_ConJson  -> JSON ADENTRO de la tabla
       transaccional (NVARCHAR(MAX)), la mala práctica.
     - dbo.Movimientos + dbo.MovimientosAnexos -> JSON AFUERA,
       tabla transaccional angosta + tabla de anexos en su propio
       filegroup (FG_JSON), la buena práctica.

   Batería de pruebas, todas sobre 5.000.000 de filas base:

     1) Lectura — 3 etapas de índice: sin índice (Clustered Index
        Scan), índice no cubriente (Seek + Key Lookup), índice
        cubriente (Seek puro).
     2) Escritura — INSERT de un lote nuevo (1 escritura ancha vs
        2 escrituras angostas) y UPDATE que no toca el JSON.
     3) Tamaño real del clustered index de cada tabla (GB).
     4) Churn realista (reconciliación que hace crecer el JSON de
        salida) y su efecto en la fragmentación.
     5) Tiempo de REBUILD de los índices de la tabla caliente.
     6) Resumen final de tamaños.

   ⚠️ ANTES DE CORRER:
   - ~5.000.000 de filas con JSON de ~1-1.5 KB cada una, más los
     índices y el rebuild (que necesita espacio extra temporal).
     Calculá unos 30 GB libres en el disco de datos y de log.
   - La carga inicial + las 3 etapas de índice + el rebuild pueden
     tardar bien: dejalo correr de punta a punta o por bloques
     (separados por GO), anotando cada resultado.
   - Se pone la base en RECOVERY SIMPLE solo para simplificar el
     demo (no hace falta backuppear el log durante la carga masiva).
     Esto es SOLO para el ambiente de prueba, nunca para producción.
   - Si ya corriste los scripts anteriores en TriggerDB_Demo_JSON,
     este script dropea y recrea todo lo que necesita, no hace
     falta limpiar nada a mano antes.
   ================================================================ */


-- ================================================================
-- 0) Base de datos, filegroup y tamaños presizados
-- ================================================================
IF DB_ID('TriggerDB_Demo_JSON') IS NULL
BEGIN
    CREATE DATABASE TriggerDB_Demo_JSON;
END
GO

USE TriggerDB_Demo_JSON;
GO

ALTER DATABASE TriggerDB_Demo_JSON SET RECOVERY SIMPLE;
GO

IF NOT EXISTS (SELECT 1 FROM sys.filegroups WHERE name = 'FG_JSON')
BEGIN
    ALTER DATABASE TriggerDB_Demo_JSON ADD FILEGROUP FG_JSON;
END
GO

DECLARE @DataPath NVARCHAR(500) = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS NVARCHAR(500));

IF NOT EXISTS (SELECT 1 FROM sys.database_files WHERE name = 'TriggerDB_Demo_JSON_FG_JSON')
BEGIN
    DECLARE @sqlFg NVARCHAR(MAX) = N'
    ALTER DATABASE TriggerDB_Demo_JSON
    ADD FILE (
        NAME = TriggerDB_Demo_JSON_FG_JSON,
        FILENAME = ''' + @DataPath + N'TriggerDB_Demo_JSON_FG_JSON.ndf'',
        SIZE = 8192MB,
        FILEGROWTH = 512MB
    ) TO FILEGROUP FG_JSON;';
    EXEC sp_executesql @sqlFg;
END
GO

-- Presizar PRIMARY y el log para no pagar autogrowth todo el tiempo
DECLARE @PrimaryFile SYSNAME = (SELECT name FROM sys.master_files WHERE database_id = DB_ID('TriggerDB_Demo_JSON') AND type = 0 AND data_space_id = 1);
DECLARE @LogFile     SYSNAME = (SELECT name FROM sys.master_files WHERE database_id = DB_ID('TriggerDB_Demo_JSON') AND type = 1);

DECLARE @sqlSize NVARCHAR(MAX) = N'
ALTER DATABASE TriggerDB_Demo_JSON MODIFY FILE (NAME = ' + QUOTENAME(@PrimaryFile) + N', SIZE = 9216MB, FILEGROWTH = 512MB);
ALTER DATABASE TriggerDB_Demo_JSON MODIFY FILE (NAME = ' + QUOTENAME(@LogFile) + N', SIZE = 3072MB, FILEGROWTH = 512MB);';
EXEC sp_executesql @sqlSize;
GO


-- ================================================================
-- 1) Seed: 5.000.000 de filas con JSON tipo "factura completa"
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
-- 2) Las dos tablas a comparar: JSON adentro vs JSON afuera
-- ================================================================
DROP TABLE IF EXISTS dbo.MovimientosAnexos;
DROP TABLE IF EXISTS dbo.Movimientos;
DROP TABLE IF EXISTS dbo.Movimientos_ConJson;
GO

-- JSON ADENTRO (mala práctica)
CREATE TABLE dbo.Movimientos_ConJson
(
    MovimientoId    INT           NOT NULL PRIMARY KEY CLUSTERED,
    CuentaId        INT           NOT NULL,
    FechaMovimiento DATETIME2(0)  NOT NULL,
    TipoMovimiento  VARCHAR(10)   NOT NULL,
    Importe         DECIMAL(18,2) NOT NULL,
    Estado          VARCHAR(20)   NOT NULL,
    JsonEntrada     NVARCHAR(MAX) NULL,
    JsonSalida      NVARCHAR(MAX) NULL
);
GO

INSERT INTO dbo.Movimientos_ConJson (MovimientoId, CuentaId, FechaMovimiento, TipoMovimiento, Importe, Estado, JsonEntrada, JsonSalida)
SELECT MovimientoId, CuentaId, FechaMovimiento, TipoMovimiento, Importe, Estado, JsonEntrada, JsonSalida
FROM dbo.Seed_Movimientos_5M;
GO

-- JSON AFUERA (buena práctica): transaccional angosta + anexos en FG_JSON
CREATE TABLE dbo.Movimientos
(
    MovimientoId    INT           NOT NULL PRIMARY KEY CLUSTERED,
    CuentaId        INT           NOT NULL,
    FechaMovimiento DATETIME2(0)  NOT NULL,
    TipoMovimiento  VARCHAR(10)   NOT NULL,
    Importe         DECIMAL(18,2) NOT NULL,
    Estado          VARCHAR(20)   NOT NULL
);
GO

CREATE TABLE dbo.MovimientosAnexos
(
    MovimientoId INT NOT NULL PRIMARY KEY CLUSTERED,
    JsonEntrada  NVARCHAR(MAX) NULL,
    JsonSalida   NVARCHAR(MAX) NULL,
    CONSTRAINT FK_MovimientosAnexos_Movimientos
        FOREIGN KEY (MovimientoId) REFERENCES dbo.Movimientos(MovimientoId)
) ON FG_JSON;
GO

INSERT INTO dbo.Movimientos (MovimientoId, CuentaId, FechaMovimiento, TipoMovimiento, Importe, Estado)
SELECT MovimientoId, CuentaId, FechaMovimiento, TipoMovimiento, Importe, Estado
FROM dbo.Seed_Movimientos_5M;
GO

INSERT INTO dbo.MovimientosAnexos (MovimientoId, JsonEntrada, JsonSalida)
SELECT MovimientoId, JsonEntrada, JsonSalida
FROM dbo.Seed_Movimientos_5M;
GO

DROP TABLE IF EXISTS dbo.Seed_Movimientos_5M;   -- liberamos disco, ya no hace falta
GO


-- ================================================================
-- 3) LECTURA — ETAPA A: sin índice adicional (Clustered Index Scan)
-- ================================================================
CHECKPOINT; DBCC DROPCLEANBUFFERS;
GO

drop INDEX if exists IX_ConJson_CuentaId ON dbo.Movimientos_ConJson 
drop INDEX if exists IX_Movimientos_CuentaId ON dbo.Movimientos 

--PRINT '=== LECTURA A — CON JSON adentro — sin índice adicional ===';
--SET STATISTICS IO, TIME ON;
SELECT TOP (50) MovimientoId, CuentaId, FechaMovimiento, Importe, Estado
FROM dbo.Movimientos_ConJson
WHERE CuentaId = 42
ORDER BY FechaMovimiento DESC OPTION (RECOMPILE);
--SET STATISTICS IO, TIME OFF;
GO
--PRINT '=== LECTURA A — JSON afuera (Movimientos) — sin índice adicional ===';
SELECT TOP (50) MovimientoId, CuentaId, FechaMovimiento, Importe, Estado
FROM dbo.Movimientos
WHERE CuentaId = 42
ORDER BY FechaMovimiento DESC OPTION (RECOMPILE);

-- Tamaño y páginas por índice (clustered y non-clustered) para las tablas del ejercicio JSON
-- Correlo una vez en el escenario "JSON embebido" y otra vez en el escenario "JSON separado"
SELECT 
    OBJECT_NAME(i.object_id)                       AS Tabla,
   -- i.name                                          AS Indice,
    i.type_desc                                     AS TipoIndice,      -- CLUSTERED / NONCLUSTERED / HEAP
    ps.row_count                                    AS Filas,
    ps.used_page_count                              AS PaginasUsadas,
    ps.reserved_page_count                          AS PaginasReservadas,
    CAST((ps.used_page_count * 8) / 1024.0 AS DECIMAL(10,2))      AS TamanoUsadoMB
    --CAST((ps.reserved_page_count * 8) / 1024.0 AS DECIMAL(10,2))  AS TamanoReservadoMB
FROM sys.dm_db_partition_stats ps
INNER JOIN sys.indexes i 
    ON ps.object_id = i.object_id 
   AND ps.index_id  = i.index_id
WHERE OBJECT_NAME(i.object_id) IN ('Movimientos', 'Movimientos_ConJson')  
and i.type_desc ='Clustered' -- ajustá los nombres de tabla según el escenario
ORDER BY Tabla, TipoIndice DESC

sp_helpindex 'Movimientos_ConJson'
-- ================================================================
-- 4) LECTURA — ETAPA B: índice por CuentaId SIN INCLUDE (no cubriente)
-- ================================================================
CREATE NONCLUSTERED INDEX IX_ConJson_CuentaId ON dbo.Movimientos_ConJson (CuentaId) INCLUDE ([FechaMovimiento],[Importe],[Estado]);
CREATE NONCLUSTERED INDEX IX_Movimientos_CuentaId ON dbo.Movimientos (CuentaId) INCLUDE ([FechaMovimiento],[Importe],[Estado]);
GO

CHECKPOINT; DBCC DROPCLEANBUFFERS;
GO

PRINT '=== LECTURA B — CON JSON adentro — índice no cubriente (Seek + Key Lookup) ===';

SELECT TOP (50) MovimientoId, CuentaId, FechaMovimiento, Importe, Estado
FROM dbo.Movimientos_ConJson
WHERE CuentaId = 42
ORDER BY FechaMovimiento DESC OPTION (RECOMPILE);
--SET STATISTICS IO, TIME OFF;
GO
--PRINT '=== LECTURA A — JSON afuera (Movimientos) ';
SELECT TOP (50) MovimientoId, CuentaId, FechaMovimiento, Importe, Estado
FROM dbo.Movimientos
WHERE CuentaId = 42
ORDER BY FechaMovimiento DESC OPTION (RECOMPILE);

-- ================================================================
-- 8) Tamaño real del clustered index de cada tabla (GB)
-- ================================================================
SELECT
    OBJECT_NAME(ips.object_id)                                 AS Tabla,
    ips.avg_record_size_in_bytes,
    ips.page_count,
    ips.record_count,
    CAST(ips.page_count * 8.0 / 1024 / 1024 AS DECIMAL(10,2))  AS TamanioGB
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'DETAILED') ips
WHERE OBJECT_NAME(ips.object_id) IN ('Movimientos_ConJson', 'Movimientos', 'MovimientosAnexos')
  AND ips.index_id = 1
  AND ips.index_level = 0;
GO

-- ================================================================
-- 11) Tiempo de REBUILD de los índices de la tabla caliente
-- ================================================================
PRINT '=== REBUILD — Movimientos_ConJson (todos sus índices) ===';
SET STATISTICS TIME ON;
ALTER INDEX ALL ON dbo.Movimientos_ConJson REBUILD;
SET STATISTICS TIME OFF;
GO

PRINT '=== REBUILD — Movimientos (todos sus índices) ===';
SET STATISTICS TIME ON;
ALTER INDEX ALL ON dbo.Movimientos REBUILD;
SET STATISTICS TIME OFF;
GO

-- MovimientosAnexos se reconstruye aparte, en otra ventana, con
-- otra frecuencia — no es la tabla que se consulta todo el día.
-- PRINT '=== REBUILD — MovimientosAnexos (aparte) ===';
-- ALTER INDEX ALL ON dbo.MovimientosAnexos REBUILD;


-- ================================================================
-- 12) Resumen final de tamaños
-- ================================================================
EXEC sp_spaceused 'dbo.Movimientos_ConJson';
EXEC sp_spaceused 'dbo.Movimientos';
EXEC sp_spaceused 'dbo.MovimientosAnexos';
GO


-- ================================================================
-- Limpieza (opcional) — dejalo comentado hasta terminar con el post
-- ================================================================
-- DROP TABLE IF EXISTS dbo.MovimientosAnexos;
-- DROP TABLE IF EXISTS dbo.Movimientos;
-- DROP TABLE IF EXISTS dbo.Movimientos_ConJson;
