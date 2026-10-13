# Borrar o mover registros en SQL Server sin bloqueos

Cómo depurar millones de registros sin dejar a los usuarios bloqueados: en lugar de un `DELETE` de una sola vez, se borra (o se mueve a un histórico) por lotes, con una sola instrucción por lote y una salida por tiempo máximo. Nace de un caso real en un banco, donde un `DELETE` masivo en horario laboral bloqueó la operación.

📖 Post completo: **[Borrar o mover registros en SQL Server sin bloqueos: caso real](https://triggerdb.com/borrar-mover-registros-sql-server-sin-bloqueos/)**
🎥 Video con la demo: **[Ver en YouTube](https://youtu.be/KDtJyCqT0Lk)**

## Qué incluye

| Archivo | Qué hace |
|---|---|
| `01_depuracion_registros_completo.sql` | Demo completa y reproducible: crea dos bases, carga 4.000.000 de ventas, muestra el lock de tabla del `DELETE` masivo y ejecuta los dos ejemplos (borrar y mover) con su validación. |
| `02_depuracion_registros_post.sql` | Solo los fragmentos que se explican en el post: lo que no hay que hacer, el índice y los dos loops. |

## Requisitos

- SQL Server 2016 o superior.
- Permiso de `sysadmin` para `DBCC TRACEON (1224)` a nivel sesión.
- ~3 GB libres entre datos y log para la demo completa.

## Cómo usarlo

1. Abrí `01_depuracion_registros_completo.sql` en SSMS o Azure Data Studio y ejecutalo **por bloques** (separados por `GO`), leyendo el resultado de cada paso.
2. En los pasos que lo indican, abrí una segunda sesión para ver el bloqueo en vivo.
3. Para tu tabla, tomá el loop de `02_depuracion_registros_post.sql` y cambiá la tabla, el filtro, `@Lote` y `@MaxMinutos`.

La única diferencia entre **borrar** y **mover** es el `OUTPUT ... INTO` de la instrucción `DELETE`.

## A tener en cuenta

- Necesitás un índice por la columna del filtro: sin él, cada lote recorre la tabla desde el principio.
- Si el loop corta por tiempo, se vuelve a ejecutar y sigue desde donde quedó.
- La tabla destino del `OUTPUT INTO` no puede tener triggers habilitados ni foreign keys.
- En recovery FULL, coordiná la depuración con los backups de log para que el log no crezca.
- Las bases de la demo quedan en RECOVERY SIMPLE: es un laboratorio, no producción.

---
## Sobre el autor

**Maximiliano (Maxi) Accotto** es socio fundador de [TriggerDB Consulting](https://www.triggerdb.com)
y especialista en SQL Server y la plataforma de datos de Microsoft, con más de 20 años de experiencia.
Fue 14 veces Microsoft MVP en Data Platform y hoy es MVP Reconnect.

**TriggerDB** es una consultora especializada en SQL Server, Azure SQL, Power BI y Microsoft Fabric:
DBA, performance, migraciones, arquitectura de datos, IA empresarial y capacitaciones.
Oficinas en Buenos Aires y Miami.

🌐 [triggerdb.com](https://www.triggerdb.com) · 🎥 [YouTube](https://www.youtube.com/@maxiaccotto) ·
💼 [LinkedIn](https://www.linkedin.com/in/maxiaccotto/) · ✉️ info@triggerdb.com
