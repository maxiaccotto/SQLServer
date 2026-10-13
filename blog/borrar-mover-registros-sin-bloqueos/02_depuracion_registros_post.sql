/* ================================================================
   Post: "Borrar o mover registros en SQL Server sin bloqueos:
          caso real" (triggerdb.com)
   Autor: Maximiliano Accotto

   Fragmentos que se muestran en el post, en orden. La demo
   completa (con creación de bases y datos) está en
   01_depuracion_registros_completo.sql.
   ================================================================ */


/* ----------------------------------------------------------------
   [A] Lo que NO hay que hacer: borrar todo de una
   SQL Server escala a un lock sobre TODA la tabla y nadie más
   puede usarla hasta que termine.
   ---------------------------------------------------------------- */
DELETE FROM dbo.Ventas
WHERE FechaVenta >= '20130101' AND FechaVenta < '20140101';


/* ----------------------------------------------------------------
   [B] Índice por la columna del filtro
   ---------------------------------------------------------------- */
CREATE NONCLUSTERED INDEX IX_Ventas_FechaVenta
    ON dbo.Ventas (FechaVenta);


/* ----------------------------------------------------------------
   [C] Ejemplo 1: BORRAR por lotes
   ---------------------------------------------------------------- */
DBCC TRACEON (1224);   -- no escalan los locks en esta sesión

DECLARE @Desde      datetime2(0) = '20130101',
        @Hasta      datetime2(0) = '20140101',
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


/* ----------------------------------------------------------------
   [D] Ejemplo 2: MOVER al histórico por lotes
   Igual al anterior, más el OUTPUT INTO.
   ---------------------------------------------------------------- */
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
    INTO Historico.dbo.Ventas
         (VentaId, ClienteId, FechaVenta, NumeroOrden, Total, Observaciones)
    WHERE FechaVenta >= @Desde
      AND FechaVenta <  @Hasta;

    IF @@ROWCOUNT = 0 BREAK;
    IF SYSUTCDATETIME() >= @Corte BREAK;

    WAITFOR DELAY '00:00:00.100';
END;

DBCC TRACEOFF (1224);
GO
