-- =============================================================================
-- 00a_calidad_fuentes.sql
-- Controles de calidad sobre las tablas fuente ANTES de construir la tabla base.
-- Salida: una fila por control con registros afectados, total y estado.
--
-- Cómo ejecutar: tal cual en la consola de BigQuery (no usa parámetros).
-- Solo lee las columnas necesarias de cada tabla (BigQuery cobra por columna leída).
-- =============================================================================
WITH
u AS (
  SELECT id, created_at
  FROM `bussiness-case-tyc.bussiness_case_ecommerce.users`
),
o AS (
  SELECT order_id, user_id, status, created_at, num_of_item
  FROM `bussiness-case-tyc.bussiness_case_ecommerce.orders`
),
oi AS (
  SELECT id, order_id, user_id, product_id, sale_price
  FROM `bussiness-case-tyc.bussiness_case_ecommerce.order_items`
),
p AS (
  SELECT id
  FROM `bussiness-case-tyc.bussiness_case_ecommerce.products`
),
-- Claves únicas para validar correspondencias sin multiplicar filas
u_unicos  AS (SELECT id, MIN(created_at) AS created_at FROM u WHERE id IS NOT NULL GROUP BY id),
o_unicas  AS (SELECT DISTINCT order_id, user_id FROM o WHERE order_id IS NOT NULL),
p_unicos  AS (SELECT DISTINCT id FROM p WHERE id IS NOT NULL),
items_por_orden AS (
  SELECT order_id, COUNT(*) AS n_items
  FROM oi
  WHERE order_id IS NOT NULL
  GROUP BY order_id
),

controles AS (
  -- 1) Duplicados en claves primarias (COUNT(col) ignora nulos; los nulos se miden aparte)
  SELECT '1 duplicados' AS tipo, 'users.id duplicado' AS control,
         COUNT(id) - COUNT(DISTINCT id) AS afectados, COUNT(*) AS total FROM u
  UNION ALL
  SELECT '1 duplicados', 'orders.order_id duplicado',
         COUNT(order_id) - COUNT(DISTINCT order_id), COUNT(*) FROM o
  UNION ALL
  SELECT '1 duplicados', 'order_items.id duplicado',
         COUNT(id) - COUNT(DISTINCT id), COUNT(*) FROM oi
  UNION ALL
  SELECT '1 duplicados', 'products.id duplicado',
         COUNT(id) - COUNT(DISTINCT id), COUNT(*) FROM p

  -- 2) Nulos en campos clave
  UNION ALL
  SELECT '2 nulos', 'users: id o created_at nulo',
         COUNTIF(id IS NULL OR created_at IS NULL), COUNT(*) FROM u
  UNION ALL
  SELECT '2 nulos', 'orders: order_id, user_id, status o created_at nulo',
         COUNTIF(order_id IS NULL OR user_id IS NULL OR status IS NULL OR created_at IS NULL), COUNT(*) FROM o
  UNION ALL
  SELECT '2 nulos', 'order_items: order_id, product_id o sale_price nulo',
         COUNTIF(order_id IS NULL OR product_id IS NULL OR sale_price IS NULL), COUNT(*) FROM oi

  -- 3) Registros sin correspondencia (integridad referencial)
  UNION ALL
  SELECT '3 sin correspondencia', 'orders sin usuario en users',
         COUNTIF(uu.id IS NULL), COUNT(*)
  FROM o LEFT JOIN u_unicos uu ON o.user_id = uu.id
  UNION ALL
  SELECT '3 sin correspondencia', 'order_items sin orden en orders',
         COUNTIF(ou.order_id IS NULL), COUNT(*)
  FROM oi LEFT JOIN (SELECT DISTINCT order_id FROM o_unicas) ou ON oi.order_id = ou.order_id
  UNION ALL
  SELECT '3 sin correspondencia', 'order_items sin producto en products',
         COUNTIF(pu.id IS NULL), COUNT(*)
  FROM oi LEFT JOIN p_unicos pu ON oi.product_id = pu.id
  UNION ALL
  SELECT '3 sin correspondencia', 'orders sin ítems en order_items',
         COUNTIF(ipo.order_id IS NULL), COUNT(*)
  FROM o LEFT JOIN items_por_orden ipo ON o.order_id = ipo.order_id

  -- 4) Consistencia de negocio
  UNION ALL
  SELECT '4 consistencia', 'orders.num_of_item distinto a ítems reales',
         COUNTIF(o.num_of_item != ipo.n_items), COUNT(*)
  FROM o JOIN items_por_orden ipo ON o.order_id = ipo.order_id
  UNION ALL
  SELECT '4 consistencia', 'order_items.user_id distinto al user_id de su orden',
         COUNTIF(oi.user_id != ou.user_id), COUNT(*)
  FROM oi JOIN o_unicas ou ON oi.order_id = ou.order_id
  UNION ALL
  SELECT '4 consistencia', 'orders con created_at en el futuro',
         COUNTIF(created_at > CURRENT_TIMESTAMP()), COUNT(*) FROM o
  UNION ALL
  SELECT '4 consistencia', 'orders anteriores al registro del usuario',
         COUNTIF(o.created_at < uu.created_at), COUNT(*)
  FROM o JOIN u_unicos uu ON o.user_id = uu.id
  UNION ALL
  SELECT '4 consistencia', 'order_items con sale_price <= 0',
         COUNTIF(sale_price <= 0), COUNT(*) FROM oi
)

SELECT
  tipo,
  control,
  afectados,
  total,
  ROUND(100 * SAFE_DIVIDE(afectados, total), 3) AS pct_afectados,
  IF(afectados = 0, 'OK', 'REVISAR') AS estado
FROM controles
ORDER BY tipo, control
