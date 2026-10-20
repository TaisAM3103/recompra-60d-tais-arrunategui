# Recompra a 60 días - The Look eCommerce

Caso práctico para el proceso de Machine Learning Engineer. Autora: **Tais Arrunátegui Matos**.

El objetivo es identificar, al momento de su primera compra, qué clientes tienen más probabilidad de hacer una nueva orden en los 60 días siguientes. Incluye la preparación de datos en BigQuery, el modelo, las predicciones y una propuesta de cómo llevarlo a producción en AWS.

## Qué hay en el repo

```
sql/
  00a_calidad_fuentes.sql        controles de calidad de las tablas fuente
  00b_estados_y_fechas.sql       estados de orden y rango de fechas
  01_tabla_base.sql              tabla base (1 fila por cliente), parametrizada
  02_validacion_tabla_base.sql   controles sobre la tabla base
notebooks/
  recompra_60d.ipynb             todo el flujo, ejecutado y con resultados
docs/
  arquitectura.md                propuesta en AWS + Snowflake
  arquitectura_aws.png
models/
  modelo_recompra_60d.joblib     modelo + preprocesamiento
outputs/
  predicciones_muestra.csv       muestra: user_id, probabilidad, decil y acción
  predicciones_20250215.csv      predicciones completas para el corte 15/02/2025
  metricas.json
  figuras/
```

## Cómo correrlo

En **Colab**: abrir `notebooks/recompra_60d.ipynb` y usar *Entorno de ejecución → Ejecutar todo*. Pide iniciar sesión con una cuenta que tenga acceso a `bussiness-case-tyc` y clona este repo para leer los `.sql`.

En **local**:
```bash
pip install -r requirements.txt
gcloud auth application-default login
jupyter notebook notebooks/recompra_60d.ipynb
```

Los `.sql` también se pueden pegar directo en la consola de BigQuery. `00a`, `00b` y `02` corren tal cual. En `01` hay que reemplazar los parámetros: `@fecha_corte` por `DATE '2025-02-15'`, `@ventana_dias` por `60` y `@estados_excluidos` por `['Cancelled']`.

Todo se controla desde la celda `CONFIG` del notebook. El notebook escribe en el dataset `tais_arrunategui` (la tabla base y las predicciones), y se puede volver a correr con la misma fecha de corte sin duplicar resultados.

## Decisiones principales

- **Compra válida:** cualquier orden menos `Cancelled`. Las `Returned` sí cuentan, porque la devolución pasa después y no se conoce al momento de predecir.
- **Recompra:** otra orden válida dentro de (primera compra, primera compra + 60 días]. Cuento órdenes, no ítems.
- **Fecha de corte:** 15/02/2025, el día siguiente a la última orden del dataset.
- **Clientes con menos de 60 días al corte:** no entran al entrenamiento (su etiqueta está incompleta), pero son los que se puntúan.
- **Sin fuga de información:** solo variables conocidas en la primera compra. Fuera el estado de la orden, las fechas de envío, entrega y devolución, y la navegación posterior.
- **Evaluación:** split temporal con 60 días de separación entre train y test. PR AUC como métrica principal, más precision, recall y lift en el top 20%.

## Resultados en corto

- 72.027 clientes con primera compra; 63.538 con la ventana completa para entrenar y 8.489 para puntuar.
- Recompra a 60 días: 6,3% en promedio, aunque sube fuerte en 2024 (ver notebook).
- Logística y gradient boosting empatan (PR AUC ~0,22 contra 0,13 de la referencia). Contactando al 20% con mayor score se encuentra al 36% de los que recompran.

## Pendientes / limitaciones

Los datos son sintéticos, la evaluación usa una sola fecha de corte y el modelo predice quién recompra, no quién recompra por efecto de una campaña. Para lo último haría falta un piloto con grupo de control y luego un modelo de uplift.
