package ai.chronon.integrations.aws

import org.apache.spark.sql.{DataFrame, Row, SparkSession}
import org.apache.spark.sql.functions._
import ai.chronon.api.{Constants => ApiConstants}
import org.slf4j.LoggerFactory
import software.amazon.awssdk.core.SdkBytes
import software.amazon.awssdk.services.dynamodb.DynamoDbClient
import software.amazon.awssdk.services.dynamodb.model.{AttributeValue, BatchWriteItemRequest, PutRequest, ProvisionedThroughputExceededException, WriteRequest}

import scala.collection.JavaConverters._

object Spark2DynamoLoader {

  private val DYNAMO_BATCH_WRITE_LIMIT = 25 // DynamoDB BatchWriteItem hard limit
  @transient private lazy val driverLogger = LoggerFactory.getLogger(getClass)
  /**
   * Maps a Spark table name to a dataset name (following Spark2MongoLoader pattern).
   * The dataset name becomes the DynamoDB table name.
   */
  def deriveDataset(sparkTableName: String): String = {
    sparkTableName match {
      case tableName if tableName.endsWith("_logged_daily_stats_upload") => ApiConstants.LogStatsBatchDataset
      case tableName if tableName.endsWith("_daily_stats_upload") => ApiConstants.StatsBatchDataset
      case tableName if tableName.endsWith("_consistency_upload") => ApiConstants.ConsistencyMetricsDataset
      case tableName if tableName.endsWith("_upload") =>
        tableName.stripSuffix("_upload").split("\\.").lastOption.getOrElse(tableName).toUpperCase + "_BATCH"
      case _ => sparkTableName.toUpperCase + "_BATCH"
    }
  }

  /**
   * Applies DynamoDB table prefix to a dataset name.
   * Delegates to DynamoDBTableHelper.prefixedTableName for consistency.
   */
  def applyDynamoDBTablePrefix(dataset: String): String = {
    DynamoDBTableHelper.prefixedTableName(dataset)
  }

  /**
   * Transforms a DataFrame to match DynamoDB KVStore schema.
   * Handles base64 decoding for string columns and timestamp derivation.
   */
  def transformDataFrameForDynamoDB(baseDf: DataFrame, sparkTableName: String): DataFrame = {
    val keyColumn = if (baseDf.columns.contains(AWSOnlineConstants.sparkKeyColumn)) AWSOnlineConstants.sparkKeyColumn else AWSOnlineConstants.dynamoTableKey
    val valueColumn = if (baseDf.columns.contains(AWSOnlineConstants.sparkValueColumn)) AWSOnlineConstants.sparkValueColumn else AWSOnlineConstants.dynamoTableValue

    if (!baseDf.columns.contains(keyColumn) || !baseDf.columns.contains(valueColumn)) {
      throw new IllegalArgumentException(
        s"Table $sparkTableName must have key column ('${AWSOnlineConstants.sparkKeyColumn}' or '${AWSOnlineConstants.dynamoTableKey}') and value column ('${AWSOnlineConstants.sparkValueColumn}' or '${AWSOnlineConstants.dynamoTableValue}'). Available columns: ${baseDf.columns.mkString(", ")}"
      )
    }

    // Get the data types from the schema
    val keyColType = baseDf.schema(keyColumn).dataType
    val valColType = baseDf.schema(valueColumn).dataType

    // Explicitly convert key and value to BINARY
    val keyExpr = if (keyColType == org.apache.spark.sql.types.StringType) {
      unbase64(col(keyColumn))
    } else {
      col(keyColumn)
    }

    val valExpr = if (valColType == org.apache.spark.sql.types.StringType) {
      unbase64(col(valueColumn))
    } else {
      col(valueColumn)
    }

    // Determine timestamp column: use ts if present, otherwise fallback to ds + 1 day
    val tsExpr = if (baseDf.columns.contains(AWSOnlineConstants.sparkTsColumn)) {
      // Use ts column directly if present
      col(AWSOnlineConstants.sparkTsColumn).cast("bigint")
    } else if (baseDf.columns.contains(AWSOnlineConstants.sparkDsColumn)) {
      // Fallback: Convert ds (yyyy-MM-dd) to UTC start of day in epoch milliseconds, then add 1 day
      (unix_timestamp(col(AWSOnlineConstants.sparkDsColumn), "yyyy-MM-dd") * 1000 + AWSOnlineConstants.uploadSpanInMillis).cast("bigint")
    } else {
      throw new IllegalArgumentException(
        s"Table $sparkTableName must have either timestamp column ('${AWSOnlineConstants.sparkTsColumn}') or date partition column ('${AWSOnlineConstants.sparkDsColumn}') for timestamp derivation. Available columns: ${baseDf.columns.mkString(", ")}"
      )
    }

    baseDf.select(
      keyExpr.as(AWSOnlineConstants.dynamoTableKey),
      valExpr.as(AWSOnlineConstants.dynamoTableValue),
      tsExpr.as(AWSOnlineConstants.dynamoTableTs)
    )
  }

  def main(args: Array[String]): Unit = {
    if (args.length != 1) {
      println("Usage: Spark2DynamoLoader <table_name>")
      println("  table_name: Spark table to read from")
      println("  DynamoDB table name is derived from the table name pattern")
      sys.exit(1)
    }

    val sparkTableName = args(0)

    // Map table name to dataset (following Spark2MongoLoader pattern)
    val dataset = deriveDataset(sparkTableName)

    // Apply DynamoDB table prefix
    val dynamoTableName = applyDynamoDBTablePrefix(dataset)

    val spark = SparkSession.builder()
      .appName(s"Spark2DynamoLoader-${sparkTableName}")
      .getOrCreate()

    try {
      val baseDf = spark.read.table(sparkTableName)

      // Transform DataFrame to match DynamoDB KVStore schema
      val df = transformDataFrameForDynamoDB(baseDf, sparkTableName)

      // Ensure DynamoDB table exists using shared helper
      // Note: dataset name should NOT have prefix (createTableIfNotExists will add it)
      val datasetWithoutPrefix = if (dataset.startsWith(AWSOnlineConstants.DynamoDBTablePrefix)) {
        dataset.stripPrefix(AWSOnlineConstants.DynamoDBTablePrefix)
      } else {
        dataset
      }

      val dynamoClient = DynamoDBClientHelper.createClient()

      try {
        DynamoDBTableHelper.createTableIfNotExists(dynamoClient, datasetWithoutPrefix)
      } catch {
        case e: Exception =>
          driverLogger.error(s"Error ensuring DynamoDB table '$dynamoTableName' exists: ${e.getMessage}", e)
          throw new RuntimeException(s"Error ensuring table exists: ${e.getMessage}", e)
      } finally {
        dynamoClient.close()
      }

      // Write to DynamoDB using the distributed foreachPartition method
      writeDataFrameToDynamoDB(df, dynamoTableName)

    } catch {
      case e: Exception =>
        driverLogger.error(s"Error loading data from Spark table '$sparkTableName' to DynamoDB table '$dynamoTableName': ${e.getMessage}", e)
        sys.exit(1)
    } finally {
      spark.stop()
    }
  }


  private def repartitionForConcurrency(df: DataFrame, numPartitions: Option[Int]): DataFrame = {
    numPartitions match {
      case Some(n) => df.repartition(n)
      case None => df
    }
  }

  private def buildWriteRequests(batch: Seq[Row]): List[WriteRequest] = {
    batch.map { row =>
      val keyBytes = row.getAs[Array[Byte]](AWSOnlineConstants.dynamoTableKey)
      val valueBytes = row.getAs[Array[Byte]](AWSOnlineConstants.dynamoTableValue)
      val timestamp = Option(row.getAs[Long](AWSOnlineConstants.dynamoTableTs))

      if (keyBytes == null || keyBytes.isEmpty) {
        throw new IllegalArgumentException("keyBytes cannot be null or empty")
      }

      val attributeMap = Map(
        AWSOnlineConstants.dynamoTableKey ->
          AttributeValue.builder().b(SdkBytes.fromByteArray(keyBytes)).build(),
        AWSOnlineConstants.dynamoTableValue ->
          AttributeValue.builder().b(SdkBytes.fromByteArray(valueBytes)).build()
      ) ++ (
        timestamp.map { ts =>
          Map(AWSOnlineConstants.dynamoTableTs -> AttributeValue.builder().n(ts.toString).build())
        }.getOrElse(Map.empty[String, AttributeValue])
        )

      WriteRequest.builder()
        .putRequest(PutRequest.builder().item(attributeMap.asJava).build())
        .build()
    }.toList
  }

  private def writeBatchWithRetry(
                                   dynamoClient: DynamoDbClient,
                                   tableName: String,
                                   initialWriteRequests: List[WriteRequest],
                                   executorLogger: org.slf4j.Logger
                                 ): Unit = {
    var itemsToWrite = initialWriteRequests
    var retryCount = 0
    val maxRetries = 10
    var backoffMs = 100L

    while (itemsToWrite.nonEmpty && retryCount < maxRetries) {
      try {
        val batchRequest = BatchWriteItemRequest.builder()
          .requestItems(Map(tableName -> itemsToWrite.asJava).asJava)
          .build()

        val response = dynamoClient.batchWriteItem(batchRequest)

        if (response.hasUnprocessedItems && !response.unprocessedItems().isEmpty) {
          val unprocessed = response.unprocessedItems().get(tableName)
          if (unprocessed != null && !unprocessed.isEmpty) {
            itemsToWrite = unprocessed.asScala.toList
            retryCount += 1
            if (retryCount < maxRetries) {
              executorLogger.warn(
                s"BatchWriteItem returned ${itemsToWrite.size} unprocessed items for table '$tableName' " +
                  s"(attempt $retryCount/$maxRetries). Retrying after ${backoffMs}ms to allow DynamoDB auto-scaling."
              )
              Thread.sleep(backoffMs)
              backoffMs = Math.min(backoffMs * 2, 5000)
            }
          } else {
            itemsToWrite = List.empty
          }
        } else {
          itemsToWrite = List.empty
        }
      } catch {
        case e: ProvisionedThroughputExceededException =>
          retryCount += 1
          if (retryCount < maxRetries) {
            executorLogger.warn(
              s"ProvisionedThroughputExceededException for table '$tableName' " +
                s"(attempt $retryCount/$maxRetries). Retrying after ${backoffMs}ms.",
              e
            )
            Thread.sleep(backoffMs)
            backoffMs = Math.min(backoffMs * 2, 5000)
          } else {
            executorLogger.error(
              s"ProvisionedThroughputExceededException for table '$tableName' after $maxRetries retries. Failing task so Spark can retry.",
              e
            )
            throw e
          }
        case e: Exception =>
          executorLogger.error(
            s"Non-throttling error writing batch to DynamoDB table '$tableName': ${e.getMessage}",
            e
          )
          throw e
      }
    }

    if (itemsToWrite.nonEmpty) {
      val errorMsg = s"Failed to write ${itemsToWrite.size} items to DynamoDB table '$tableName' after $maxRetries retries. Spark will retry this partition."
      executorLogger.error(errorMsg)
      throw new RuntimeException(errorMsg)
    }
  }

  private def processPartition(
                                partitionOfRows: Iterator[Row],
                                tableName: String,
                                clientFactory: () => DynamoDbClient
                              ): Unit = {
    val executorLogger = LoggerFactory.getLogger(getClass)
    val dynamoClient = clientFactory()
    try {
      partitionOfRows.grouped(DYNAMO_BATCH_WRITE_LIMIT).foreach { batch =>
        val writeRequests = buildWriteRequests(batch)
        writeBatchWithRetry(dynamoClient, tableName, writeRequests, executorLogger)
      }
    } finally {
      dynamoClient.close()
    }
  }

  /**
   * Writes a DataFrame to DynamoDB in a distributed fashion using foreachPartition.
   * This ensures the work is done on executors, not the driver.
   *
   * Note: TTL is not used since we always overwrite data (latest value only).
   *
   * For On-Demand DynamoDB tables, use `numPartitions` to limit concurrency and avoid
   * initial throttling during "cold start" periods. Recommended values: 50-100 partitions
   * to balance parallelism with DynamoDB's auto-scaling capacity.
   *
   * @param df DataFrame to write
   * @param tableName DynamoDB table name
   * @param clientFactory Factory function to create DynamoDB clients (defaults to DynamoDBClientHelper.createClient)
   * @param numPartitions Optional number of partitions to repartition the DataFrame before writing.
   *                      If provided, the DataFrame will be repartitioned to control concurrency.
   *                      For On-Demand tables, set to 50-100 to avoid initial throttling.
   */
  def writeDataFrameToDynamoDB(
                                df: DataFrame,
                                tableName: String,
                                clientFactory: () => DynamoDbClient = () => DynamoDBClientHelper.createClient(),
                                numPartitions: Option[Int] = None
                              ): Unit = {
    val dfToWrite = repartitionForConcurrency(df, numPartitions)
    dfToWrite.foreachPartition { partitionOfRows: Iterator[Row] =>
      processPartition(partitionOfRows, tableName, clientFactory)
    }
  }
}
