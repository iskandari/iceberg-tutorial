from pyspark.sql import functions as F

vpts = spark.table("glue_catalog.vpts.data")

(vpts
 .where((F.col("year") == 2024) & (F.col("month") == 5) & (F.col("radar") == "KBUF"))
 .select("radar", "datetime", "height", "dens", "ff", "dd")
 .orderBy("datetime", "height")
 .show(100, truncate=False))

