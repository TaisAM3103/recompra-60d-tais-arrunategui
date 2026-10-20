-- 02_validacion_tabla_base.sql
-- Controles sobre la tabla base ya creada. Si falla uno 'critico' el notebook se detiene;
-- las advertencias solo se reportan.
WITH
b AS (
  SELECT * FROM `bussiness-case-tyc.tais_arrunategui.base_recompra_60d`
),
controles AS (
  SELECT 'critico' AS severidad, 'grano: 1 fila por cliente' AS control,
         COUNT(*) - COUNT(DISTINCT user_id) AS afectados FROM b
  UNION ALL
  SELECT 'critico', 'grano: 1 primera orden por cliente',
         COUNT(*) - COUNT(DISTINCT primera_order_id) FROM b
  UNION ALL
  SELECT 'critico', 'etiqueta nula en entrenamiento',
         COUNTIF(conjunto = 'entrenamiento' AND recompra_60d IS NULL) FROM b
  UNION ALL
  SELECT 'critico', 'etiqueta presente en scoring (debe ser nula)',
         COUNTIF(conjunto = 'scoring' AND recompra_60d IS NOT NULL) FROM b
  UNION ALL
  SELECT 'critico', 'etiqueta fuera de {0,1}',
         COUNTIF(recompra_60d NOT IN (0, 1)) FROM b
  UNION ALL
  SELECT 'critico', 'primera compra en o después del corte',
         COUNTIF(fecha_primera_compra >= fecha_corte) FROM b
  UNION ALL
  SELECT 'critico', 'entrenamiento sin ventana completa observada',
         COUNTIF(conjunto = 'entrenamiento'
                 AND primera_compra_ts > TIMESTAMP_SUB(TIMESTAMP(fecha_corte), INTERVAL ventana_dias DAY)) FROM b
  UNION ALL
  SELECT 'critico', 'scoring con ventana completa (debió ir a entrenamiento)',
         COUNTIF(conjunto = 'scoring'
                 AND primera_compra_ts <= TIMESTAMP_SUB(TIMESTAMP(fecha_corte), INTERVAL ventana_dias DAY)) FROM b
  UNION ALL
  SELECT 'critico', 'segunda orden anterior a la primera (días negativos)',
         COUNTIF(aux_dias_a_segunda_orden < 0) FROM b
  UNION ALL
  SELECT 'advertencia', 'primera orden sin ítems (canasta nula)',
         COUNTIF(n_items IS NULL) FROM b
  UNION ALL
  SELECT 'advertencia', 'compra anterior al registro del usuario',
         COUNTIF(dias_registro_a_compra < 0) FROM b
  UNION ALL
  SELECT 'advertencia', 'edad nula o fuera de rango [10, 100]',
         COUNTIF(edad IS NULL OR edad NOT BETWEEN 10 AND 100) FROM b
)
SELECT
  severidad,
  control,
  afectados,
  CASE
    WHEN afectados = 0          THEN 'OK'
    WHEN severidad = 'critico'  THEN 'FALLA'
    ELSE 'ALERTA'
  END AS estado
FROM controles
ORDER BY severidad, control
