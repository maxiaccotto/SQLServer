/* ================================================================

   Post: "Borrar o mover registros en SQL Server sin bloqueos:
          caso real" (triggerdb.com)
   Autor: Maximiliano Accotto

   Demo completa y reproducible (no necesita AdventureWorks):

     1) Crea dos bases: TriggerDB_Demo_Depuracion (la operativa) y
        TriggerDB_Demo_Depuracion_Historico (donde se archiva).
     2) Carga 4.000.000 de ventas entre 2011 y 2014 (~1M por año).
     3) LA MALA PRÁCTICA: un DELETE de un año entero de una sola
        vez -> lock de TABLA y todos los usuarios bloqueados.
     4) Índice por la columna del filtro.
     5) EJEMPLO 1 - BORRAR por lotes (2011).
     6) EJEMPLO 2 - MOVER al histórico por lotes (2013).
     7) Validación.

   Los dos ejemplos usan el mismo patrón:
     - DELETE TOP (@Lote) en un WHILE, una sola instrucción por lote,
     - TF 1224 en la sesión para que los locks no escalen a la tabla,
     - sale cuando no quedan registros o cuando se pasa del tiempo
       máximo (si corta por tiempo, se vuelve a ejecutar y sigue),
     - la única diferencia entre borrar y mover es el OUTPUT INTO.

   ⚠️ ANTES DE CORRER:
   - Es un script de LABORATORIO. Ejecutalo por bloques (separados
     por GO), leyendo los resultados de cada paso.
   - Necesitás ~3 GB libres entre datos y log.
   - Las bases se ponen en RECOVERY SIMPLE solo para el demo.
   - DBCC TRACEON (1224) a nivel sesión requiere sysadmin.
   - Si ya lo corriste antes, el paso 1 dropea y recrea todo.
   ================================================================ */


/* ================================================================
   PASO 1 - Bases de demo
   ================================================================ */
USE master;
GO
IF DB_ID('TriggerDB_Demo_Depuracion') IS NOT NULL
BEGIN
    ALTER DATABASE TriggerDB_Demo_Depuracion SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE TriggerDB_Demo_Depuracion;
END;
IF DB_ID('TriggerDB_Demo_Depuracion_Historico') IS NOT NULL
BEGIN
    ALTER DATABASE TriggerDB_Demo_Depuracion_Historico SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE TriggerDB_Demo_Depuracion_Historico;
END;
GO
CREATE DATABASE TriggerDB_Demo_Depuracion;
CREATE DATABASE TriggerDB_Demo_Depuracion_Historico;
GO
ALTER DATABASE TriggerDB_Demo_Depuracion           SET RECOVERY SIMPLE;
ALTER DATABASE TriggerDB_Demo_Depuracion_Historico SET RECOVERY SIMPLE;
GO


/* ================================================================
   PASO 2 - Tablas y datos
   ================================================================ */
USE TriggerDB_Demo_Depuracion;
GO
CREATE TABLE dbo.Ventas
(
    VentaId        bigint IDENTITY(1,1) NOT NULL,
    ClienteId      int            NOT NULL,
    FechaVenta     datetime2(0)   NOT NULL,
    NumeroOrden    varchar(25)    NOT NULL,
    Total          decimal(19,4)  NOT NULL,
    Observaciones  varchar(200)   NULL,
    CONSTRAINT PK_Ventas PRIMARY KEY CLUSTERED (VentaId)
);
GO

-- Tabla destino del histórico (vacía, misma estructura).
-- OJO: el destino de un OUTPUT INTO no puede tener triggers
-- habilitados ni foreign keys.
USE TriggerDB_Demo_Depuracion_Historico;
GO
CREATE TABLE dbo.Ventas
(
    VentaId        bigint         NOT NULL,
    ClienteId      int            NOT NULL,
    FechaVenta     datetime2(0)   NOT NULL,
    NumeroOrden    varchar(25)    NOT NULL,
    Total          decimal(19,4)  NOT NULL,
    Observaciones  varchar(200)   NULL,
    CONSTRAINT PK_Ventas PRIMARY KEY CLUSTERED (VentaId)
);
GO

-- 4.000.000 de ventas, una cada ~31 segundos: ~1M por año.
USE TriggerDB_Demo_Depuracion;
GO
;WITH n AS
(
    SELECT TOP (4000000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn
    FROM sys.all_columns AS a
    CROSS JOIN sys.all_columns AS b
)
INSERT INTO dbo.Ventas WITH (TABLOCK)
       (ClienteId, FechaVenta, NumeroOrden, Total, Observaciones)
SELECT 1 + ABS(CHECKSUM(NEWID())) % 50000,
       DATEADD(SECOND, CAST(rn * 31 AS int), CAST('20110101' AS datetime2(0))),
       CONCAT('SO', RIGHT(CONCAT('000000000', rn), 9)),
       CAST(ABS(CHECKSUM(NEWID())) % 10000000 / 100.0 AS decimal(19,4)),
       REPLICATE('x', 100)
FROM n
ORDER BY rn;
GO

SELECT YEAR(FechaVenta) AS Anio, COUNT(*) AS Filas
FROM dbo.Ventas
GROUP BY YEAR(FechaVenta)
ORDER BY Anio;
GO


/* ================================================================
   PASO 3 - LA MALA PRÁCTICA: borrar todo de una
   Lo dejamos en una transacción abierta para mirar los locks.
   ================================================================ */
BEGIN TRANSACTION;

DELETE FROM dbo.Ventas
WHERE FechaVenta >= '20130101' AND FechaVenta < '20140101';

-- Aparece OBJECT / X: lock exclusivo sobre TODA la tabla.
SELECT resource_type, request_mode, COUNT(*) AS Locks
FROM sys.dm_tran_locks
WHERE request_session_id = @@SPID
GROUP BY resource_type, request_mode
ORDER BY Locks DESC;

/*  >>> En OTRA sesión ejecutá:
        SELECT COUNT(*) FROM TriggerDB_Demo_Depuracion.dbo.Ventas
        WHERE FechaVenta >= '20140101';
    Queda esperando aunque pide 2014, que nadie está borrando.  */
GO

-- Volvemos atrás (el ROLLBACK de un DELETE grande también tarda).
ROLLBACK TRANSACTION;
GO


/* ================================================================
   PASO 4 - Índice por la columna del filtro
   Sin índice, cada vuelta del loop recorre la tabla desde el
   principio para encontrar las filas a borrar.
   ================================================================ */
CREATE NONCLUSTERED INDEX IX_Ventas_FechaVenta
    ON dbo.Ventas (FechaVenta);
GO


/* ================================================================
   PASO 5 - EJEMPLO 1: BORRAR por lotes (2011)
   Para datos que no hace falta conservar.
   ================================================================ */
DBCC TRACEON (1224);   -- no escalan los locks en esta sesión

DECLARE @Desde      datetime2(0) = '20110101',
        @Hasta      datetime2(0) = '20120101',
        @Lote       int          = 50000,
        @MaxMinutos int          = 30,
        @Corte      datetime2(3);

SET @Corte = DATEADD(MINUTE, @MaxMinutos, SYSUTCDATETIME());

WHILE 1 = 1
BEGIN
    DELETE TOP (@Lote) FROM dbo.Ventas
    WHERE FechaVenta >= @Desde
      AND FechaVenta <  @Hasta;

    IF @@ROWCOUNT = 0 BREAK;                  -- no quedan registros
    IF SYSUTCDATETIME() >= @Corte BREAK;      -- se pasó del tiempo máximo

    WAITFOR DELAY '00:00:00.100';             -- respiro para el resto
END;

DBCC TRACEOFF (1224);
GO


/* ================================================================
   PASO 6 - EJEMPLO 2: MOVER al histórico por lotes (2013)
   El mismo loop, con OUTPUT INTO: borra y archiva en la misma
   instrucción. Si falla el insert en el histórico, no se borra.

   >>> Mientras corre, en OTRA sesión repetí la consulta de 2014:
       ahora responde al instante.
   ================================================================ */
DBCC TRACEON (1224);

DECLARE @Desde      datetime2(0) = '20130101',
        @Hasta      datetime2(0) = '20140101',
        @Lote       int          = 50000,
        @MaxMinutos int          = 30,
        @Corte      datetime2(3);

SET @Corte = DATEADD(MINUTE, @MaxMinutos, SYSUTCDATETIME());

WHILE 1 = 1
BEGIN
    DELETE TOP (@Lote) FROM dbo.Ventas
    OUTPUT deleted.VentaId, deleted.ClienteId, deleted.FechaVenta,
           deleted.NumeroOrden, deleted.Total, deleted.Observaciones
    INTO TriggerDB_Demo_Depuracion_Historico.dbo.Ventas
         (VentaId, ClienteId, FechaVenta, NumeroOrden, Total, Observaciones)
    WHERE FechaVenta >= @Desde
      AND FechaVenta <  @Hasta;

    IF @@ROWCOUNT = 0 BREAK;
    IF SYSUTCDATETIME() >= @Corte BREAK;

    WAITFOR DELAY '00:00:00.100';
END;

DBCC TRACEOFF (1224);
GO


/* ================================================================
   PASO 7 - Validación
   2011 y 2013 ya no están en la operativa; 2013 está en el
   histórico (~1M de filas); 2012 y 2014 intactos.
   ================================================================ */
SELECT YEAR(FechaVenta) AS Anio, COUNT(*) AS Filas
FROM dbo.Ventas
GROUP BY YEAR(FechaVenta)
ORDER BY Anio;

SELECT YEAR(FechaVenta) AS Anio, COUNT(*) AS Filas
FROM TriggerDB_Demo_Depuracion_Historico.dbo.Ventas
GROUP BY YEAR(FechaVenta)
ORDER BY Anio;
GO


/* ================================================================
   PASO 8 - Limpieza (descomentar para borrar las bases de demo)
   ================================================================ */
/*
USE master;
GO
ALTER DATABASE TriggerDB_Demo_Depuracion SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE TriggerDB_Demo_Depuracion;
ALTER DATABASE TriggerDB_Demo_Depuracion_Historico SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE TriggerDB_Demo_Depuracion_Historico;
GO
*/
