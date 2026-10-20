# Recompra a 60 días — The Look eCommerce
**Caso práctico Machine Learning Engineer · Tais Lisette Arrunátegui Matos**

Identifica a los clientes con alta probabilidad de hacer una **nueva orden en los 60 días siguientes a su primera
compra**, desde la preparación de datos en BigQuery hasta las predicciones listas para negocio y la arquitectura
para producción en AWS.

## Estructura
```
sql/
  00a_calidad_fuentes.sql        Controles de calidad de las tablas fuente
  00b_estados_y_fechas.sql       Distribución de estados de orden y rango de fechas
  01_tabla_base.sql              Tabla base: 1 fila por cliente, etiqueta sin fuga (parametrizada)
  02_validacion_tabla_base.sql   Controles sobre la tabla base (críticos detienen el proceso)
notebooks/
  recompra_60d.ipynb             Pipeline completo: calidad → tabla base → EDA → modelo → predicciones
docs/
  arquitectura.md                Diseño AWS, Snowflake y optimización
  arquitectura_aws.png / .dot    Diagrama
models/modelo_recompra_60d.joblib   Modelo + transformaciones (se genera al ejecutar)
outputs/
  predicciones_muestra.csv       user_id, probabilidad de recompra, decil y acción
  predicciones_YYYYMMDD.csv      Predicciones completas de la fecha de corte
  metricas.json                  Métricas de evaluación
  figuras/                       Gráficos del análisis y del modelo
```

## Cómo ejecutar
**Google Colab**
1. Abrir `notebooks/recompra_60d.ipynb` en Colab (o el enlace de lectura compartido).
2. *Entorno de ejecución → Ejecutar todo*. La primera celda pide autenticarse con la cuenta que tiene acceso a
   `bussiness-case-tyc` y clona este repositorio para leer los `.sql`.

**Local**
```bash
pip install -r requirements.txt
gcloud auth application-default login
jupyter notebook notebooks/recompra_60d.ipynb    # Kernel → Restart & Run All
```

**Solo SQL (consola de BigQuery):** `00a` y `00b` se ejecutan tal cual. Para `01`, reemplazar
`@fecha_corte` por `DATE '2025-02-15'`, `@ventana_dias` por `60` y `@estados_excluidos` por `['Cancelled']`.

Toda la configuración está en la celda `CONFIG` (fecha de corte, ventana, estados excluidos, fracción de test,
capacidad de campaña, dataset destino). Re-ejecutar con la misma fecha de corte **no duplica resultados**: la tabla
base se reemplaza y las predicciones reemplazan solo su partición.

## Dependencias
Python 3.10+, `google-cloud-bigquery`, `db-dtypes`, `pandas`, `scikit-learn`, `matplotlib`, `joblib` (ver
`requirements.txt`). Acceso de lectura al dataset `bussiness-case-tyc.bussiness_case_ecommerce` y de escritura al
dataset `tais_arrunategui` (el notebook lo crea si no existe).

## Supuestos y decisiones
| Tema | Decisión |
|---|---|
| Compra válida | Toda orden excepto `Cancelled`. `Returned` cuenta: hubo decisión de compra. |
| Primera compra | Primera orden válida por `created_at`; desempate por `order_id`. |
| Recompra | Otra orden válida en (primera compra, primera compra + 60 días]. Se cuenta por **orden**, no por ítem. |
| Fecha de corte | Exclusiva. Por defecto, el 1er día del mes de la última orden observada; configurable. Descarta fechas futuras. |
| Clientes sin 60 días de historia | Sin etiqueta (no se entrenan); se puntúan como clientes a contactar. |
| Fuga de información | Solo variables conocidas en la primera compra (lista blanca). Excluidos: estado de la orden, fechas de envío/entrega/devolución, eventos posteriores. |
| Validación | Split temporal (cohortes recientes como test) con hueco de 60 días entre train y test. |
| Métricas | PR AUC (clase minoritaria) + precision, recall, F1 y lift en el top 20% contactable. |
| Referencia | Tasa histórica de recompra del segmento canal × departamento. |
| Tablas no usadas | `distribution_centers` e `inventory_items`: no aportan información disponible al momento de la primera compra. |

## Limitaciones
Datos sintéticos; el modelo predice quién recompra, no quién recompra *por* la campaña (eso requiere grupo de
control y modelo de uplift); una sola fecha de corte evaluada.
