-- 01_tabla_base.sql
-- Tabla base: una fila por cliente con su primera compra, la etiqueta de recompra
-- a 60 dias y variables que se conocen en el momento de esa primera compra.
--
-- Parametros:
--   @fecha_corte        DATE           hasta donde "conozco" los datos (exclusiva)
--   @ventana_dias       INT64          60
--   @estados_excluidos  ARRAY<STRING>  ['Cancelled']
--
-- El notebook pasa los parametros y guarda el resultado en tais_arrunategui.base_recompra_60d
-- con WRITE_TRUNCATE. Para probarlo en la consola: @fecha_corte -> DATE '2025-02-15',
-- @ventana_dias -> 60, @estados_excluidos -> ['Cancelled'].
--
-- Granularidad:
--   users (1 x id) -> orders (1 x order_id) -> order_items (1 x item) -> products (1 x id)
--   events (1 x evento), se cruza por user_id
-- order_items y events se agregan ANTES de unir; si no, los joins multiplican clientes.
--
-- Las columnas aux_* son solo para analisis. Tienen info posterior a la primera compra,
-- asi que no entran al modelo.
WITH
params AS (
  SELECT
    TIMESTAMP(@fecha_corte)                                          AS corte_ts,
    TIMESTAMP_SUB(TIMESTAMP(@fecha_corte), INTERVAL @ventana_dias DAY) AS limite_observable_ts
),

-- 1) usuarios, dedup por si acaso
usuarios AS (
  SELECT
    id              AS user_id,
    age,
    gender,
    country,
    traffic_source,
    created_at      AS registro_ts
  FROM `bussiness-case-tyc.bussiness_case_ecommerce.users`
  WHERE id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY created_at) = 1
),

-- 2) ordenes validas: claves no nulas, sin canceladas, antes del corte
--    (esto saca tambien cualquier fecha futura) y con usuario existente
ordenes AS (
  SELECT
    o.order_id,
    o.user_id,
    o.created_at
  FROM `bussiness-case-tyc.bussiness_case_ecommerce.orders` AS o
  CROSS JOIN params
  WHERE o.order_id IS NOT NULL
    AND o.user_id IS NOT NULL
    AND o.created_at IS NOT NULL
    AND o.status NOT IN UNNEST(@estados_excluidos)
    AND o.created_at < params.corte_ts
    AND o.user_id IN (SELECT user_id FROM usuarios)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY o.order_id ORDER BY o.created_at) = 1
),

-- 3) numero las ordenes de cada cliente. si dos tienen el mismo timestamp desempato por order_id
ordenes_numeradas AS (
  SELECT
    order_id,
    user_id,
    created_at,
    ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY created_at, order_id) AS n_orden
  FROM ordenes
),

primera AS (
  SELECT
    user_id,
    order_id    AS primera_order_id,
    created_at  AS primera_compra_ts
  FROM ordenes_numeradas
  WHERE n_orden = 1
),

-- 4) etiqueta: hay otra orden valida en (primera compra, primera compra + ventana]?
--    se cuentan ordenes, no items (varios items de la misma orden no son recompra)
recompras AS (
  SELECT
    p.user_id,
    COUNTIF(n.created_at <= TIMESTAMP_ADD(p.primera_compra_ts, INTERVAL @ventana_dias DAY))
                                     AS n_ordenes_en_ventana,
    MIN(n.created_at)                AS segunda_orden_ts
  FROM primera AS p
  JOIN ordenes_numeradas AS n
    ON n.user_id = p.user_id
   AND n.n_orden > 1
  GROUP BY p.user_id
),

-- 5) items solo de las primeras ordenes. filtrar aca antes de agregar ahorra bastante
items_primera_orden AS (
  SELECT
    oi.order_id,
    oi.product_id,
    oi.sale_price
  FROM `bussiness-case-tyc.bussiness_case_ecommerce.order_items` AS oi
  WHERE oi.order_id IN (SELECT primera_order_id FROM primera)
    AND oi.sale_price IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY oi.id ORDER BY oi.created_at) = 1
),

productos AS (
  SELECT id AS product_id, category, department, brand, cost, retail_price
  FROM `bussiness-case-tyc.bussiness_case_ecommerce.products`
  WHERE id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY id) = 1
),

-- 5a) canasta de la primera orden
canasta AS (
  SELECT
    i.order_id,
    COUNT(*)                          AS n_items,
    COUNT(DISTINCT i.product_id)      AS n_productos,
    ROUND(SUM(i.sale_price), 2)       AS monto_total,
    ROUND(MAX(i.sale_price), 2)       AS precio_max_item,
    ROUND(SUM(i.sale_price - pr.cost), 2) AS margen_bruto,
    COUNT(DISTINCT pr.category)       AS n_categorias,
    COUNT(DISTINCT pr.brand)          AS n_marcas
  FROM items_primera_orden AS i
  LEFT JOIN productos AS pr USING (product_id)
  GROUP BY i.order_id
),

-- 5b) categoria principal = la de mayor monto dentro de la orden
categoria_principal AS (
  SELECT
    order_id,
    category    AS categoria_principal,
    department  AS departamento_principal
  FROM (
    SELECT i.order_id, pr.category, pr.department, SUM(i.sale_price) AS monto
    FROM items_primera_orden AS i
    JOIN productos AS pr USING (product_id)
    GROUP BY i.order_id, pr.category, pr.department
  )
  QUALIFY ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY monto DESC, category) = 1
),

-- 6) navegacion ANTES de la primera compra.
--    ojo: el filtro e.created_at < primera_compra_ts es el que evita la fuga
eventos_previos AS (
  SELECT
    e.user_id,
    COUNT(*)                                   AS n_eventos_previos,
    COUNT(DISTINCT e.session_id)               AS n_sesiones_previas,
    COUNTIF(e.event_type = 'product')          AS n_vistas_producto,
    COUNTIF(e.event_type = 'cart')             AS n_eventos_carrito,
    ROUND(TIMESTAMP_DIFF(MIN(p.primera_compra_ts), MIN(e.created_at), MINUTE) / 1440, 2)
                                               AS dias_primer_evento_a_compra
  FROM `bussiness-case-tyc.bussiness_case_ecommerce.events` AS e
  JOIN primera AS p
    ON e.user_id = p.user_id
  WHERE e.created_at < p.primera_compra_ts
  GROUP BY e.user_id
)

-- 7) final
SELECT
  -- id y contexto
  p.user_id,
  p.primera_order_id,
  p.primera_compra_ts,
  DATE(p.primera_compra_ts)                                   AS fecha_primera_compra,
  @fecha_corte                                                AS fecha_corte,
  @ventana_dias                                               AS ventana_dias,

  -- solo tiene etiqueta quien ya cumplio la ventana completa; el resto se puntua (scoring)
  IF(p.primera_compra_ts <= params.limite_observable_ts, 'entrenamiento', 'scoring')
                                                              AS conjunto,

  -- en scoring queda NULL, todavia no se sabe
  IF(p.primera_compra_ts <= params.limite_observable_ts,
     IF(COALESCE(r.n_ordenes_en_ventana, 0) > 0, 1, 0),
     NULL)                                                    AS recompra_60d,

  -- cliente
  u.age                                                       AS edad,
  u.gender                                                    AS genero,
  u.country                                                   AS pais,
  u.traffic_source                                            AS canal_adquisicion,
  DATE_DIFF(DATE(p.primera_compra_ts), DATE(u.registro_ts), DAY) AS dias_registro_a_compra,

  -- calendario
  EXTRACT(MONTH FROM p.primera_compra_ts)                     AS mes_primera_compra,
  EXTRACT(DAYOFWEEK FROM p.primera_compra_ts)                 AS dia_semana_primera_compra,

  -- canasta
  c.n_items,
  c.n_productos,
  c.monto_total,
  c.precio_max_item,
  c.margen_bruto,
  c.n_categorias,
  c.n_marcas,
  cp.categoria_principal,
  cp.departamento_principal,

  -- navegacion previa
  COALESCE(ev.n_eventos_previos, 0)                           AS n_eventos_previos,
  COALESCE(ev.n_sesiones_previas, 0)                          AS n_sesiones_previas,
  COALESCE(ev.n_vistas_producto, 0)                           AS n_vistas_producto,
  COALESCE(ev.n_eventos_carrito, 0)                           AS n_eventos_carrito,
  ev.dias_primer_evento_a_compra,

  -- auxiliares, NO van al modelo
  TIMESTAMP_DIFF(params.corte_ts, p.primera_compra_ts, DAY)   AS aux_dias_observados,
  IF(COALESCE(r.n_ordenes_en_ventana, 0) > 0, 1, 0)           AS aux_ya_recompro_al_corte,
  TIMESTAMP_DIFF(r.segunda_orden_ts, p.primera_compra_ts, DAY) AS aux_dias_a_segunda_orden

FROM primera AS p
CROSS JOIN params
JOIN usuarios                 AS u  ON u.user_id   = p.user_id
LEFT JOIN recompras           AS r  ON r.user_id   = p.user_id
LEFT JOIN canasta             AS c  ON c.order_id  = p.primera_order_id
LEFT JOIN categoria_principal AS cp ON cp.order_id = p.primera_order_id
LEFT JOIN eventos_previos     AS ev ON ev.user_id  = p.user_id
