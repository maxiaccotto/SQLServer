# JSON en SQL Server — Benchmark de rendimiento

Scripts T-SQL usados para medir el costo real de guardar JSON embebido en una tabla transaccional vs. separarlo en una tabla aparte con su propio filegroup.

📖 Post completo con el análisis: **[Cómo Guardar JSON en SQL Server sin Romper el Rendimiento](https://triggerdb.com/como-guardar-json-en-sql-server-sin-romper-el-rendimiento/)**
🎥 Video con la demo completa: **[Ver en YouTube](https://youtu.be/66MMxku2D9Y)**

## Qué mide este benchmark

Sobre 5 millones de filas, se compara la misma tabla en dos versiones:

- **`Movimientos_ConJson`** — datos transaccionales + columnas JSON (`NVARCHAR(MAX)`) embebidas en la misma tabla.
- **`Movimientos` + `MovimientosAnexos`** — datos transaccionales separados del JSON, que vive en su propia tabla con filegroup dedicado.

Y se mide, para cada escenario:

- Lecturas lógicas y tiempo de ejecución (`STATISTICS IO` / `STATISTICS TIME`), con Clustered Index Scan e Index Seek.
- Tamaño real del clustered index de cada tabla (`sys.dm_db_partition_stats`).


## Resultado

| Escenario | Lecturas lógicas | Tiempo | Tamaño clustered index |
|---|---|---|---|
| JSON embebido | 52.716 | 462 ms | 19.604 MB |
| JSON separado | 33.723 | 129 ms | 259 MB |

---

*Por **Maximiliano Accotto** — especialista en SQL Server, Power BI y Microsoft Fabric. [triggerdb.com](https://www.triggerdb.com)*
