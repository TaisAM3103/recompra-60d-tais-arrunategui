-- =============================================================================
-- 00b_estados_y_fechas.sql
-- Distribución de estados de orden y rango de fechas.
-- Sirve para decidir (y justificar) qué estados cuentan como compra
-- y qué fecha de corte usar.
--
-- Cómo ejecutar: tal cual en la consola de BigQuery (no usa parámetros).
-- =============================================================================
SELECT
  status,
  COUNT(*)                                                AS n_ordenes,
  COUNT(DISTINCT user_id)                                 AS n_clientes,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)        AS pct_ordenes,
  MIN(created_at)                                         AS primera_orden,
  MAX(created_at)                                         AS ultima_orden,
  COUNTIF(created_at > CURRENT_TIMESTAMP())               AS ordenes_en_futuro
FROM `bussiness-case-tyc.bussiness_case_ecommerce.orders`
GROUP BY status
ORDER BY n_ordenes DESC
