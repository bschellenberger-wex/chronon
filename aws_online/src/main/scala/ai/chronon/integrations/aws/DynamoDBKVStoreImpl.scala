package ai.chronon.integrations.aws

import scala.collection.JavaConverters._
import ai.chronon.online.KVStore.GetResponse
import ai.chronon.online.KVStore.TimedValue
import ai.chronon.online.{KVStore, Metrics}
import ai.chronon.online.Metrics.Context
import software.amazon.awssdk.core.SdkBytes
import software.amazon.awssdk.services.dynamodb.DynamoDbClient
import software.amazon.awssdk.services.dynamodb.model.AttributeValue
import software.amazon.awssdk.services.dynamodb.model.{BatchGetItemRequest, BatchGetItemResponse, GetItemRequest, KeysAndAttributes, ProvisionedThroughputExceededException, PutItemRequest, ResourceNotFoundException}
import scala.concurrent.{ExecutionContext, Future, Promise}
import scala.util.{Try, Failure}

import java.time.Instant
import java.util
import java.util.Collections
import java.util.concurrent.{ScheduledExecutorService, TimeUnit}
import scala.collection.Seq
import org.slf4j.{Logger, LoggerFactory}

class DynamoDBKVStoreImpl(
    dynamoDbClient: DynamoDbClient,
    scheduler: ScheduledExecutorService
)(implicit ec: ExecutionContext) extends KVStore {

  @transient override lazy val logger: Logger = LoggerFactory.getLogger(getClass)
  protected val metricsContext: Metrics.Context = Metrics.Context(Metrics.Environment.KVStore).withSuffix("dynamodb")

  private def prefixedTableName(dataset: String): String = {
    DynamoDBTableHelper.prefixedTableName(dataset)
  }

  override def create(dataset: String): Unit = {
    try {
      val tableName = DynamoDBTableHelper.createTableIfNotExists(dynamoDbClient, dataset)
      logger.info(s"Table ready: $tableName (dataset: $dataset)")
      metricsContext.increment("create.successes")
    } catch {
      case e: Exception =>
        logger.error(s"Error creating DynamoDB table for dataset: $dataset", e)
        metricsContext.increment("create.failures")
        throw e
    }
  }

  override def multiGet(requests: Seq[KVStore.GetRequest]): Future[Seq[KVStore.GetResponse]] = {
    val requestsByDataset = requests.groupBy(_.dataset)

    val allDatasetFutures = requestsByDataset.map { case (dataset, datasetRequests) =>
      val tableName = prefixedTableName(dataset)

      // Build getItemRequestPairs from all datasetRequests
      val getItemRequestPairs = datasetRequests.map { req =>
        // Warn if timestamp filter is provided (not supported in simplified store)
        if (req.afterTsMillis.isDefined) {
          logger.warn(s"Timestamp filter (afterTsMillis) is being ignored for dataset '$dataset'. This simplified KV store only supports partition key lookups.")
        }
        val keyAttributeMap = primaryKeyMap(req.keyBytes)
        (req, keyAttributeMap)
      }

      // Build BatchGetItem request for all GetItem requests
      if (getItemRequestPairs.isEmpty) {
        Future.successful(Seq.empty)
      } else {
        // Collect all keys into a list
        val keysList = getItemRequestPairs.map { case (_, keyAttributeMap) =>
          keyAttributeMap.asJava
        }.asJava

        // Build KeysAndAttributes
        val keysAndAttributes = KeysAndAttributes.builder()
          .keys(keysList)
          .build()

        // Build BatchGetItemRequest
        val batchGetRequest = BatchGetItemRequest.builder()
          .requestItems(Map(tableName -> keysAndAttributes).asJava)
          .build()

        // Call handleDynamoDbBatchGet
        handleDynamoDbBatchGet(metricsContext.withSuffix("multiget"), dataset)(batchGetRequest).map { response =>
          val defaultTimestamp = Instant.now().toEpochMilli

          // Get responses for this table
          val responseItems = if (response.hasResponses && response.responses().containsKey(tableName)) {
            response.responses().get(tableName)
          } else {
            Collections.emptyList[util.Map[String, AttributeValue]]()
          }

          // Create a Map for efficient lookup: keyed by dynamoTableKey (SdkBytes)
          val itemsByKey = new util.HashMap[SdkBytes, util.Map[String, AttributeValue]]()
          if (responseItems != null) {
            responseItems.asScala.foreach { item =>
              val keyAttr = item.get(AWSOnlineConstants.dynamoTableKey)
              if (keyAttr != null && keyAttr.b() != null) {
                itemsByKey.put(keyAttr.b(), item)
              }
            }
          }

          // Iterate over original getItemRequestPairs and build GetResponse for each
          getItemRequestPairs.map { case (req, _) =>
            val keyBytes = SdkBytes.fromByteArray(req.keyBytes)
            val item = itemsByKey.get(keyBytes)

            val responseList = if (item == null || item.isEmpty) {
              List.empty[util.Map[String, AttributeValue]].asJava
            } else {
              List(item).asJava
            }

            val resultValue = extractTimedValues(responseList, defaultTimestamp)
            GetResponse(req, resultValue)
          }
        }.recover { case e =>
          // On error, return Failure for all requests
          getItemRequestPairs.map { case (req, _) =>
            GetResponse(req, Failure(e))
          }
        }
      }
    }.toSeq

    Future.sequence(allDatasetFutures).map(_.flatten)
  }


  // multiPut code is currently NOT utilized and remains untested in a real environment, but remains here for reference.
  // Dynamo has restrictions on the number of requests per batch (and the payload size) as well as some partial
  // success behavior on batch writes which necessitates a bit more logic on our end to tie things together.
  // To keep things simple for now, we implement the multiput as a sequence of put calls.
  override def multiPut(keyValueDatasets: Seq[KVStore.PutRequest]): Future[Seq[Boolean]] = {
    val datasetToWriteRequests = keyValueDatasets.map { req =>
      val attributeMap: Map[String, AttributeValue] = buildAttributeMap(req.keyBytes, req.valueBytes)
      val tsMap =
        req.tsMillis.map(ts => Map(AWSOnlineConstants.dynamoTableTs -> AttributeValue.builder.n(ts.toString).build)).getOrElse(Map.empty)
      val tableName = prefixedTableName(req.dataset)

      val putItemReq =
        PutItemRequest.builder.tableName(tableName).item((attributeMap ++ tsMap).asJava).build()
      (req.dataset, putItemReq)
    }

    val futureResponses = datasetToWriteRequests.map { case (dataset, putItemRequest) =>
      handleDynamoDbOperation(metricsContext.withSuffix("multiput"), dataset) {
        dynamoDbClient.putItem(putItemRequest)
      }.map(_ => true).recover { case _ => false }
    }
    Future.sequence(futureResponses)
  }

  /**
   * BulkPut is for an optional implementation of uploading batch data to the KV Store.
   * This method is intentionally not implemented. See Spark2DynamoLoader for bulk load support.
   */
  override def bulkPut(sourceOfflineTable: String, destinationOnlineDataSet: String, partition: String): Unit = {
    throw new NotImplementedError(
      "bulkPut is not implemented. Use Spark2DynamoLoader for bulk data loading from Spark tables to DynamoDB."
    )
  }

  /**
   * Handles DynamoDB operations with error handling, metrics, and retry logic for transient errors.
   *
   * Implements exponential backoff retry for:
   * - ProvisionedThroughputExceededException (throttling)
   * - Transient errors (ServiceUnavailable, InternalServerError, RequestTimeout)
   *
   * @param context Metrics context for tracking operation performance
   * @param dataset Dataset name for error context
   * @param operation The DynamoDB operation to execute
   * @return Future[T] containing the result or failure
   */
  private def handleDynamoDbOperation[T](context: Context, dataset: String)(operation: => T): Future[T] = {
    val maxRetries = 3

    def attemptOperation(retryCount: Int): Future[T] = {
      Future {
        val startTs = System.currentTimeMillis()
        val result = operation
        context.distribution("latency", System.currentTimeMillis() - startTs)
        result
      }.recoverWith {
        case e: ProvisionedThroughputExceededException =>
          if (retryCount < maxRetries) {
            // Exponential backoff: 100ms, 200ms, 400ms
            val backoffMs = (100 * Math.pow(2, retryCount)).toLong
            logger.warn(s"Provisioned throughput exceeded on dataset '$dataset' (table: ${prefixedTableName(dataset)}, attempt ${retryCount + 1}/$maxRetries), retrying after ${backoffMs}ms", e)
            val promise = Promise[T]()
            scheduler.schedule(new Runnable {
              override def run(): Unit = {
                attemptOperation(retryCount + 1).onComplete(promise.complete)(ec)
              }
            }, backoffMs, TimeUnit.MILLISECONDS)
            promise.future
          } else {
            logger.error(s"Provisioned throughput exceeded as we are low on IOPS on dataset '$dataset' (table: ${prefixedTableName(dataset)}) after $maxRetries retries", e)
            context.increment("iops_error")
            Future.failed(e)
          }
        case e: ResourceNotFoundException =>
          logger.error(s"Unable to trigger operation on dataset '$dataset' (table: ${prefixedTableName(dataset)}) - table not found", e)
          context.increment("missing_table")
          Future.failed(e)
        case e: Exception =>
          // For other exceptions, check if they're transient (e.g., throttling, network errors)
          val isTransient = e.getMessage != null && (
            e.getMessage.contains("Throttling") ||
              e.getMessage.contains("ServiceUnavailable") ||
              e.getMessage.contains("InternalServerError") ||
              e.getMessage.contains("RequestTimeout")
            )

          if (isTransient && retryCount < maxRetries) {
            val backoffMs = (100 * Math.pow(2, retryCount)).toLong
            logger.warn(s"Transient error on dataset '$dataset' (table: ${prefixedTableName(dataset)}, attempt ${retryCount + 1}/$maxRetries), retrying after ${backoffMs}ms: ${e.getMessage}", e)
            val promise = Promise[T]()
            scheduler.schedule(new Runnable {
              override def run(): Unit = {
                attemptOperation(retryCount + 1).onComplete(promise.complete)(ec)
              }
            }, backoffMs, TimeUnit.MILLISECONDS)
            promise.future
          } else {
            logger.error(s"Error interacting with DynamoDB for dataset '$dataset' (table: ${prefixedTableName(dataset)}): ${e.getMessage}", e)
            context.increment("dynamodb_error")
            Future.failed(e)
          }
      }
    }

    attemptOperation(0)
  }

  /**
   * Handles DynamoDB BatchGetItem operations with error handling, metrics, and retry logic for transient errors.
   * Specifically handles UnprocessedKeys by retrying only those keys after backoff.
   *
   * @param context Metrics context for tracking operation performance
   * @param dataset Dataset name for error context
   * @param request The BatchGetItemRequest to execute
   * @return Future[BatchGetItemResponse] containing the result or failure
   */
  private def handleDynamoDbBatchGet(context: Context, dataset: String)(request: BatchGetItemRequest): Future[BatchGetItemResponse] = {
    val maxRetries = 3

    def attemptOperation(retryCount: Int, currentRequest: BatchGetItemRequest): Future[BatchGetItemResponse] = {
      Future {
        val startTs = System.currentTimeMillis()
        val result = dynamoDbClient.batchGetItem(currentRequest)
        context.distribution("latency", System.currentTimeMillis() - startTs)
        result
      }.flatMap { response =>
        // Check for unprocessed keys and retry if needed
        if (response.hasUnprocessedKeys && !response.unprocessedKeys().isEmpty && retryCount < maxRetries) {
          val backoffMs = (100 * Math.pow(2, retryCount)).toLong
          val unprocessedCount = response.unprocessedKeys().values().asScala.map(_.keys().size()).sum
          logger.warn(s"BatchGetItem returned $unprocessedCount unprocessed keys for dataset '$dataset' (table: ${prefixedTableName(dataset)}, attempt ${retryCount + 1}/$maxRetries), retrying after ${backoffMs}ms")
          val promise = Promise[BatchGetItemResponse]()
          scheduler.schedule(new Runnable {
            override def run(): Unit = {
              // Build a new request with only unprocessed keys
              val unprocessedRequest = BatchGetItemRequest.builder()
                .requestItems(response.unprocessedKeys())
                .build()
              attemptOperation(retryCount + 1, unprocessedRequest).flatMap { retryResponse =>
                // Merge the responses: combine items from both responses, deduplicating by primary key
                val mergedItems = new util.HashMap[String, util.List[util.Map[String, AttributeValue]]]()
                // Add items from original response
                if (response.hasResponses) {
                  response.responses().forEach { (tableName, items) =>
                    mergedItems.put(tableName, deduplicateItemsByKey(items))
                  }
                }
                // Add items from retry response, merging with existing items and deduplicating
                if (retryResponse.hasResponses) {
                  retryResponse.responses().forEach { (tableName, items) =>
                    val existing = mergedItems.getOrDefault(tableName, new util.ArrayList[util.Map[String, AttributeValue]]())
                    existing.addAll(items)
                    mergedItems.put(tableName, deduplicateItemsByKey(existing))
                  }
                }
                // Build merged response
                val mergedResponse = BatchGetItemResponse.builder()
                  .responses(mergedItems)
                  .unprocessedKeys(if (retryResponse.hasUnprocessedKeys) retryResponse.unprocessedKeys() else Collections.emptyMap())
                  .build()
                Future.successful(mergedResponse)
              }.onComplete(promise.complete)(ec)
            }
          }, backoffMs, TimeUnit.MILLISECONDS)
          promise.future
        } else {
          Future.successful(response)
        }
      }.recoverWith {
        case e: ProvisionedThroughputExceededException =>
          if (retryCount < maxRetries) {
            val backoffMs = (100 * Math.pow(2, retryCount)).toLong
            logger.warn(s"Provisioned throughput exceeded on dataset '$dataset' (table: ${prefixedTableName(dataset)}, attempt ${retryCount + 1}/$maxRetries), retrying after ${backoffMs}ms", e)
            val promise = Promise[BatchGetItemResponse]()
            scheduler.schedule(new Runnable {
              override def run(): Unit = {
                attemptOperation(retryCount + 1, currentRequest).onComplete(promise.complete)(ec)
              }
            }, backoffMs, TimeUnit.MILLISECONDS)
            promise.future
          } else {
            logger.error(s"Provisioned throughput exceeded as we are low on IOPS on dataset '$dataset' (table: ${prefixedTableName(dataset)}) after $maxRetries retries", e)
            context.increment("iops_error")
            Future.failed(e)
          }
        case e: ResourceNotFoundException =>
          logger.error(s"Unable to trigger operation on dataset '$dataset' (table: ${prefixedTableName(dataset)}) - table not found", e)
          context.increment("missing_table")
          Future.failed(e)
        case e: Exception =>
          val isTransient = e.getMessage != null && (
            e.getMessage.contains("Throttling") ||
              e.getMessage.contains("ServiceUnavailable") ||
              e.getMessage.contains("InternalServerError") ||
              e.getMessage.contains("RequestTimeout")
            )

          if (isTransient && retryCount < maxRetries) {
            val backoffMs = (100 * Math.pow(2, retryCount)).toLong
            logger.warn(s"Transient error on dataset '$dataset' (table: ${prefixedTableName(dataset)}, attempt ${retryCount + 1}/$maxRetries), retrying after ${backoffMs}ms: ${e.getMessage}", e)
            val promise = Promise[BatchGetItemResponse]()
            scheduler.schedule(new Runnable {
              override def run(): Unit = {
                attemptOperation(retryCount + 1, currentRequest).onComplete(promise.complete)(ec)
              }
            }, backoffMs, TimeUnit.MILLISECONDS)
            promise.future
          } else {
            logger.error(s"Error interacting with DynamoDB for dataset '$dataset' (table: ${prefixedTableName(dataset)}): ${e.getMessage}", e)
            context.increment("dynamodb_error")
            Future.failed(e)
          }
      }
    }

    attemptOperation(0, request)
  }

  private def extractTimedValues(response: util.List[util.Map[String, AttributeValue]],
                                 defaultTimestamp: Long): Try[Seq[TimedValue]] = {
    Try {
      if (response == null || response.isEmpty) {
        // Return empty sequence - this is a valid "not found" case
        logger.debug("DynamoDB query/GetItem returned empty result list")
        Seq.empty[TimedValue]
      } else {
        response.asScala.map { ddbResponseMap =>
          val responseMap = ddbResponseMap.asScala
          if (responseMap.isEmpty)
            throw new Exception("Empty response returned from DynamoDB")

          val valueBytes = responseMap.get(AWSOnlineConstants.dynamoTableValue).map(v => v.b().asByteArray())
          if (valueBytes.isEmpty) {
            val allKeys = responseMap.keys.mkString(", ")
            val errorMsg = s"DynamoDB response missing ${AWSOnlineConstants.dynamoTableValue}. Available keys: $allKeys"
            logger.error(errorMsg)
            throw new Exception(errorMsg)
          }

          val timestamp = responseMap.get(AWSOnlineConstants.dynamoTableTs).map(v => v.n().toLong).getOrElse(defaultTimestamp)
          TimedValue(valueBytes.get, timestamp)
        }
      }
    }
  }


  /**
   * Deduplicates DynamoDB items by their primary key (dynamoTableKey).
   * If duplicate keys are found, keeps the first occurrence and logs a warning.
   *
   * @param items List of DynamoDB items (Map[String, AttributeValue])
   * @return Deduplicated list of items
   */
  private def deduplicateItemsByKey(items: util.List[util.Map[String, AttributeValue]]): util.List[util.Map[String, AttributeValue]] = {
    val seenKeys = new util.HashSet[SdkBytes]()
    val deduplicated = new util.ArrayList[util.Map[String, AttributeValue]]()
    
    items.asScala.foreach { item =>
      val keyAttr = item.get(AWSOnlineConstants.dynamoTableKey)
      if (keyAttr != null && keyAttr.b() != null) {
        val keyBytes = keyAttr.b() // keyAttr.b() is already an SdkBytes
        if (seenKeys.contains(keyBytes)) {
          logger.warn(s"Duplicate key found in BatchGetItem response, keeping first occurrence")
        } else {
          seenKeys.add(keyBytes)
          deduplicated.add(item)
        }
      } else {
        // If item doesn't have a key, include it (shouldn't happen, but be defensive)
        logger.warn("Item in BatchGetItem response missing primary key, including anyway")
        deduplicated.add(item)
      }
    }
    
    deduplicated
  }

  private def primaryKeyMap(keyBytes: Array[Byte]): Map[String, AttributeValue] = {
    Map(AWSOnlineConstants.dynamoTableKey -> AttributeValue.builder.b(SdkBytes.fromByteArray(keyBytes)).build)
  }

  private def buildAttributeMap(keyBytes: Array[Byte], valueBytes: Array[Byte]): Map[String, AttributeValue] = {
    primaryKeyMap(keyBytes) ++
      Map(
        AWSOnlineConstants.dynamoTableValue -> AttributeValue.builder.b(SdkBytes.fromByteArray(valueBytes)).build
      )
  }

}
