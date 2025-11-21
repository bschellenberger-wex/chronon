package ai.chronon.integrations.aws

import org.apache.spark.sql.{DataFrame, SparkSession}
import scala.util.{Try, Success, Failure}

// $COVERAGE-OFF$ This utility is an exploratory/debug script not exercised in automated tests.
// It is excluded from coverage so it does not skew project metrics. Keep logic simple; no business code

/**
 * Polaris Catalog Explorer
 *
 * This Scala script connects to a Polaris catalog (configured via EMR Serverless),
 * explores its namespaces, schemas, and tables, and runs sample queries to verify
 * the connection and debug catalog access issues.
 *
 * Usage:
 *   PolarisCatalogExplorer [namespace_filter]
 *
 *   namespace_filter: Optional namespace to explore (e.g., "ben_test")
 *                      If not provided, explores all namespaces in all catalogs
 */
object PolarisCatalogExplorer {
  val CATALOG_NAME = "opencatalog"

  def main(args: Array[String]): Unit = {
    val namespaceFilter = if (args.length > 0) Some(args(0)) else None

    println(repeat("=", 80))
    println("Polaris Catalog Explorer")
    println(repeat("=", 80))
    println("Note: Catalog configuration is expected from EMR Serverless environment")
    println(repeat("-", 80))

    val spark = SparkSession.builder()
      .appName("PolarisCatalogExplorer")
      .getOrCreate()

    try {
      println("\n" + repeat("=", 60))
      println("Starting Catalog Exploration...")
      println(repeat("=", 60))

      // List all available catalogs
      println("\n📋 Available catalogs:")
      val catalogsDf = spark.sql("SHOW CATALOGS")
      catalogsDf.show(false)
      val allCatalogs = catalogsDf.collect().map(row => row.getString(0))

      // Check default catalog
      Try {
        val defaultCatalog = spark.sql("SELECT current_catalog()").collect()(0).getString(0)
        println(s"\n📋 Default catalog: $defaultCatalog")
        defaultCatalog
      } match {
        case Success(catalog) => println(s"✅ Default catalog is: $catalog")
        case Failure(e) => 
          println(s"⚠️  Could not determine default catalog: ${e.getMessage}")
      }

      // Filter out Spark's built-in catalog
      val catalogs = allCatalogs.filter(_ != "spark_catalog")
      if (allCatalogs.contains("spark_catalog")) {
        println(s"ℹ️  Filtering out built-in 'spark_catalog' (Spark's internal catalog)")
        println(s"   Focusing on external catalogs: ${catalogs.mkString(", ")}")
      }

      if (catalogs.isEmpty) {
        println("⚠️  No external catalogs found.")
      } else {
        println(s"\nFound ${catalogs.length} external catalog(s) to explore: ${catalogs.mkString(", ")}")
        
        var allTables = List.empty[String]
        
        for (catalog <- catalogs) {
          val catalogTables = exploreCatalog(spark, catalog, namespaceFilter)
          allTables = allTables ++ catalogTables
          println(s"\n📊 Catalog '$catalog' summary: ${catalogTables.length} tables found")
        }

        println("\n" + repeat("=", 60))
        if (allTables.isEmpty) {
          println("⚠️  No tables were found during exploration.")
        } else {
          println(s"✅ Catalog exploration complete. Found ${allTables.length} tables across all catalogs.")
          println(s"\nTables found:")
          allTables.foreach(table => println(s"  - $table"))
        }
        println(repeat("=", 60))
      }

    } catch {
      case e: Exception =>
        println(s"\n❌ A critical error occurred during catalog exploration:")
        e.printStackTrace()
    } finally {
      spark.stop()
      println("\nSpark session stopped.")
    }
  }

  /**
   * Explores a given catalog for namespaces and tables.
   */
  def exploreCatalog(spark: SparkSession, catalogName: String, namespaceFilter: Option[String]): List[String] = {
    println("\n" + repeat("=", 80))
    println(s"EXPLORING CATALOG: $catalogName")
    println(repeat("=", 80))

    var allTables = List.empty[String]

    Try {
      println(s"\nNamespaces in '$catalogName':")
      val namespacesDf = spark.sql(s"SHOW NAMESPACES IN $catalogName")
      namespacesDf.show(false)
      val namespaces = namespacesDf.collect().map(row => row.getString(0))

      if (namespaces.isEmpty) {
        println(s"⚠️  No namespaces found in catalog '$catalogName'.")
      } else {
        val filteredNamespaces = namespaceFilter match {
          case Some(filter) => namespaces.filter(_.contains(filter))
          case None => namespaces
        }

        if (namespaceFilter.isDefined && filteredNamespaces.isEmpty) {
          println(s"⚠️  No namespaces matching filter '${namespaceFilter.get}' found in catalog '$catalogName'.")
        } else {
          println(s"Exploring ${filteredNamespaces.length} namespace(s): ${filteredNamespaces.mkString(", ")}")
          for (namespace <- filteredNamespaces) {
            val namespaceTables = exploreNamespace(spark, catalogName, namespace)
            allTables = allTables ++ namespaceTables
          }
        }
      }
    } match {
      case Success(_) => // Already handled
      case Failure(e) =>
        println(s"❌ Error exploring catalog '$catalogName': ${e.getMessage}")
        e.printStackTrace()
    }

    allTables
  }

  /**
   * Explores a given namespace for schemas and tables.
   */
  def exploreNamespace(spark: SparkSession, catalogName: String, namespace: String): List[String] = {
    println(s"\n--- Exploring Namespace: $namespace ---")
    var tablesFound = List.empty[String]

    // Try to list tables directly in the namespace (flat hierarchy)
    Try {
      val tables = spark.catalog.listTables(s"$catalogName.$namespace")
      val tableNames = tables.collect().map(_.name).toList
      if (tableNames.nonEmpty) {
        println(s"Found ${tableNames.length} table(s) directly in namespace '$namespace': ${tableNames.mkString(", ")}")
        for (tableName <- tableNames) {
          val fullTableName = s"$catalogName.$namespace.$tableName"
          tablesFound = tablesFound :+ fullTableName
          analyzeTable(spark, fullTableName)
        }
      }
    } match {
      case Success(_) => // Already handled
      case Failure(e) =>
        println(s"Info: Could not list tables directly in namespace '$namespace'. " +
          s"This is expected if it only contains schemas. Error: ${e.getMessage}")
    }

    // Try to list schemas within the namespace (hierarchical structure)
    Try {
      val schemasDf = spark.sql(s"SHOW SCHEMAS IN $catalogName.$namespace")
      val schemas = schemasDf.collect().map(row => row.getString(0))
      if (schemas.nonEmpty) {
        println(s"Found ${schemas.length} schema(s) in namespace '$namespace': ${schemas.mkString(", ")}")
        for (schema <- schemas) {
          println(s"\n--- Exploring Schema: $schema ---")
          Try {
            val tablesInSchema = spark.catalog.listTables(schema)
            val tableNames = tablesInSchema.collect().map(_.name).toList
            println(s"Found ${tableNames.length} table(s) in schema '$schema': ${tableNames.mkString(", ")}")
            for (tableName <- tableNames) {
              val fullTableName = s"$schema.$tableName"
              tablesFound = tablesFound :+ fullTableName
              analyzeTable(spark, fullTableName)
            }
          } match {
            case Success(_) => // Already handled
            case Failure(e) =>
              println(s"❌ Error listing tables in schema '$schema': ${e.getMessage}")
              e.printStackTrace()
          }
        }
      }
    } match {
      case Success(_) => // Already handled
      case Failure(e) =>
        println(s"Info: Could not list schemas in namespace '$namespace'. " +
          s"This is expected for flat namespaces. Error: ${e.getMessage}")
    }

    tablesFound
  }

  /**
   * Analyzes a single table by describing it and showing sample data.
   */
  def analyzeTable(spark: SparkSession, fullTableName: String): Unit = {
    println(s"\n--- Analyzing Table: $fullTableName ---")

    // Try to describe the table
    Try {
      println(s"--- Description for $fullTableName ---")
      val descDf = spark.sql(s"DESCRIBE FORMATTED $fullTableName")
      descDf.show(false)
    } match {
      case Success(_) => // Already handled
      case Failure(e) =>
        println(s"⚠️  Could not describe table '$fullTableName': ${e.getMessage}")
    }

    // Try to read the table and show schema
    Try {
      val df = spark.read.table(fullTableName)
      println(s"--- Schema for $fullTableName ---")
      df.printSchema()
      
      println(s"--- Sample Data for $fullTableName (LIMIT 5) ---")
      df.limit(5).show(false)
    } match {
      case Success(_) => // Already handled
      case Failure(e) =>
        println(s"❌ Error reading table '$fullTableName': ${e.getMessage}")
        e.printStackTrace()
    }

    // Try reading via Iceberg format
    Try {
      println(s"--- Reading $fullTableName as Iceberg table ---")
      val icebergDf = spark.read.format("iceberg").load(fullTableName)
      println(s"Schema for $fullTableName (Iceberg):")
      icebergDf.printSchema()
      println(s"Sample data from $fullTableName (Iceberg, LIMIT 5):")
      icebergDf.limit(5).show(false)
    } match {
      case Success(_) => // Already handled
      case Failure(e) =>
        println(s"⚠️  Could not read table '$fullTableName' as Iceberg: ${e.getMessage}")
    }
  }
  // Helper to repeat strings (Scala 2.12 compatible). Only used for console formatting.
  private def repeat(str: String, n: Int): String = {
    if (n <= 0) "" else Iterator.fill(n)(str).mkString
  }
}
