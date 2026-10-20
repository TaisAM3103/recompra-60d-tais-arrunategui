# Arquitectura cloud — Recompra a 60 días

![Arquitectura AWS](arquitectura_aws.png)

Principio de diseño: **el mismo SQL y el mismo código del notebook pasan a producción sin reescribirse**.
Solo cambia quién los ejecuta. Se priorizan servicios administrados (sin servidores que mantener).

## 1. Carga y transformación
| Paso | Servicio | Decisión |
|---|---|---|
| Llegada de datos | **S3 raw** | Los sistemas fuente depositan archivos por tabla y fecha (`s3://.../raw/orders/dt=YYYY-MM-DD/`). |
| Catálogo | **Glue Data Catalog** (crawler) | Expone los archivos como tablas consultables. |
| Calidad de entrada | **Glue Data Quality** | Las mismas reglas de `00a_calidad_fuentes.sql`: claves únicas, nulos, integridad referencial. |
| Transformación | **Athena** (SQL, CTAS) | Ejecuta `01_tabla_base.sql` casi sin cambios. Elegido sobre Glue Spark porque el volumen es tabular y el equipo ya escribe SQL; se migra a Glue/EMR solo si Athena deja de alcanzar. |
| Capa curada | **S3 curated** (Parquet particionado por `fecha_corte`) | Columnar y particionado: cada ejecución lee solo lo que necesita. |

## 2. Ejecución programada, reentrenamiento y predicciones
- **EventBridge Scheduler** dispara mensualmente (día 1) un **SageMaker Pipeline** con los pasos del notebook:
  validar → construir tabla base → entrenar y evaluar con split temporal → **compuerta de calidad** → registrar → puntuar.
- **Compuerta:** el modelo nuevo se aprueba en **Model Registry** solo si su PR AUC en las cohortes recientes es
  mayor o igual que el del modelo en producción. Si no, se puntúa con la versión anterior. Así un mal reentrenamiento
  no llega a negocio.
- **Reentrenamiento** mensual (las etiquetas maduran a los 60 días); **scoring** puede ser semanal o diario para
  los clientes nuevos, reutilizando el último modelo aprobado.
- Equivalente simple si no se quiere SageMaker Pipelines: **Step Functions** + un contenedor en **ECS Fargate** que
  ejecuta las funciones del notebook.

## 3. Dónde se guardan las predicciones
- **S3** `predicciones/fecha_corte=YYYY-MM-DD/` (Parquet), con **reemplazo de la partición** en cada ejecución:
  re-ejecutar no duplica (igual que en el notebook).
- Expuestas como tabla en **Athena** y cargadas a **Snowflake** para el consumo del cliente (CRM, campañas, BI).
- Columnas: `user_id`, `probabilidad_recompra`, `decil`, `accion`, `fecha_corte`, `modelo_version`, `fecha_ejecucion`.
  La versión del modelo en cada fila permite trazar cualquier decisión comercial a su modelo.

## 4. Monitoreo de calidad de datos y del modelo
| Qué | Cómo | Alerta |
|---|---|---|
| Calidad de datos | Glue Data Quality + controles críticos de `02_validacion_tabla_base.sql` | Falla crítica → el pipeline se detiene, alerta SNS |
| Drift de variables | SageMaker Model Monitor (distribución de variables vs. entrenamiento) | Cambio significativo → SNS |
| Desempeño real | Cuando cierra la ventana de 60 días, se calcula la PR AUC y la captura del top 20% con la etiqueta real | Caída bajo umbral → revisión y reentrenamiento |
| Operación | CloudWatch: duración, errores, filas puntuadas | Ejecución fallida o 0 filas → SNS |

## 5. Versionamiento con GitHub
- Un repositorio con `sql/`, el código del pipeline, los tests y la **infraestructura como código** (Terraform o CDK).
- **GitHub Actions**: en cada *pull request* corre tests (validaciones de SQL sobre datos de prueba, lint);
  al hacer *merge* a `main` despliega la definición del pipeline. Autenticación a AWS por **OIDC** (sin llaves guardadas).
- Datos y modelos **no** van a Git: los modelos se versionan en Model Registry y cada predicción guarda `modelo_version`.

## Integración con Snowflake (opcional)
Dado que el cliente usa Snowflake, hay dos caminos y propongo el primero por simplicidad:

1. **Snowflake como destino de predicciones** (mínimo cambio): **storage integration** con S3 + **Snowpipe** carga
   cada partición de predicciones al llegar. Negocio consume una **vista** con permisos por rol.
2. **Snowflake como plataforma de datos** (si las fuentes ya viven allí): la tabla base se construye en Snowflake
   (mismo SQL: `QUALIFY` existe, `COUNTIF` → `COUNT_IF`, `TIMESTAMP_ADD` → `DATEADD`), con **Streams + Tasks** para
   procesar solo cohortes nuevas. SageMaker lee con el conector de Snowflake, o el entrenamiento se mueve a
   **Snowpark ML** para no sacar los datos.

En Snowflake con volumen: *clustering key* por fecha en `orders` y `events`, un *warehouse* dedicado al proceso de ML
que se suspende automáticamente, y aprovechar la caché de resultados en las consultas de calidad.

## Optimización del SQL con más volumen (BigQuery)
- Ya aplicado: lectura solo de columnas necesarias, filtros tempranos (ítems solo de primeras órdenes, eventos solo de
  clientes de la cohorte), agregación antes de los joins.
- A escala: particionar `orders`, `order_items` y `events` por `DATE(created_at)` y *clustering* por `user_id`;
  construir la tabla base **incrementalmente** (solo cohortes cuya ventana cerró desde la última ejecución) con `MERGE`.

## Equivalencias GCP ↔ AWS
| Rol | GCP (usado en el caso) | AWS (propuesta) |
|---|---|---|
| Almacenamiento | Cloud Storage | S3 |
| SQL analítico | BigQuery | Athena (o Redshift) |
| Orquestación | Cloud Scheduler + Vertex AI Pipelines | EventBridge + SageMaker Pipelines |
| Registro de modelos | Vertex AI Model Registry | SageMaker Model Registry |
| Monitoreo | Cloud Monitoring + Vertex Model Monitoring | CloudWatch + SageMaker Model Monitor |
