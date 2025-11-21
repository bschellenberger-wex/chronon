package ai.chronon.integrations.aws

import ai.chronon.online.{
  Api,
  ExternalSourceRegistry,
  GroupByServingInfoParsed,
  KVStore,
  LoggableResponse,
  StreamDecoder
}
import ai.chronon.api.{Constants, StructType}
import org.slf4j.{Logger, LoggerFactory}
import software.amazon.awssdk.services.dynamodb.DynamoDbClient
import scala.concurrent.ExecutionContext
import scala.util.Try
import java.util.concurrent.{Executors, ExecutorService, ScheduledExecutorService, TimeUnit}

/**
 * AWS/DynamoDB implementation of Chronon's Api interface.
 * 
 * This provides:
 * - DynamoDBKVStoreImpl as the KVStore backend
 * - Basic StreamDecoder (can be extended for specific use cases)
 * - ExternalSourceRegistry for external data sources
 * - Logging support (can be extended to log to DynamoDB or CloudWatch)
 * 
 * Usage:
 * ```scala
 * val api = new ChrononAwsOnlineImpl(Map.empty)
 * val fetcher = api.buildJavaFetcher()
 * ```
 */
class ChrononAwsOnlineImpl(userConf: Map[String, String]) extends Api(userConf) {

  @transient lazy val registry: ExternalSourceRegistry = new ExternalSourceRegistry()

  @transient val logger: Logger = LoggerFactory.getLogger("ChrononAwsOnlineImpl")

  @transient lazy val dynamoDbClient: DynamoDbClient = {
    DynamoDBClientHelper.createClient()
  }

  // Create ScheduledExecutorService for non-blocking retry delays
  @transient private lazy val scheduler: ScheduledExecutorService = Executors.newScheduledThreadPool(2)
  
  // Dedicated thread pool for KVStore operations to avoid blocking ExecutionContext.global
  @transient private lazy val kvStoreExecutor: ExecutorService = Executors.newFixedThreadPool(16)
  
  // Execution context for Future operations - uses dedicated thread pool instead of global
  @transient implicit private lazy val executionContext: ExecutionContext = ExecutionContext.fromExecutor(kvStoreExecutor)

  // Cache the KVStore instance to share mutable state like tableSortKeyCache
  // This ensures that if multiple Fetchers are created from the same Api instance,
  // they share the same cache, avoiding redundant DescribeTable calls
  @transient private lazy val kvStore: KVStore = new DynamoDBKVStoreImpl(dynamoDbClient, scheduler)(executionContext)

  override def genKvStore: KVStore = kvStore

  /**
   * StreamDecoder for processing streaming mutations/events.
   * 
   * This is a basic implementation that can be extended for specific use cases.
   * For now, it throws NotImplementedError - implement based on your streaming format
   * (e.g., Avro, JSON, Protobuf).
   */
  override def streamDecoder(groupByServingInfoParsed: GroupByServingInfoParsed): StreamDecoder = {
    // TODO: Implement based on your streaming format
    // For now, throw NotImplementedError to indicate this needs to be implemented
    // when streaming is needed
    throw new NotImplementedError(
      "StreamDecoder not yet implemented for AWS. " +
      "Implement based on your streaming format (Avro, JSON, etc.)"
    )
  }

  /**
   * Log response to DynamoDB or CloudWatch.
   * 
   * For now, this is a no-op. Can be extended to:
   * - Log to a DynamoDB table
   * - Send to CloudWatch Logs
   * - Send to Kinesis Firehose
   */
  override def logResponse(resp: LoggableResponse): Unit = {
    // TODO: Implement logging to DynamoDB or CloudWatch
    // For now, just log to SLF4J
    logger.debug(
      s"LoggableResponse: joinName=${resp.joinName}, " +
      s"tsMillis=${resp.tsMillis}, schemaHash=${resp.schemaHash}"
    )
  }

  override def externalRegistry: ExternalSourceRegistry = registry

  /**
   * Closes all resources associated with this Api instance.
   * Safe to call multiple times - will only close resources that are still open.
   * 
   * This method:
   * - Shuts down the scheduler (ScheduledExecutorService) gracefully
   * - Shuts down the kvStoreExecutor (ExecutorService) gracefully
   * - Closes the DynamoDB client
   * 
   * All operations are wrapped in Try to ensure one failure doesn't prevent others from closing.
   */
  def close(): Unit = {
    logger.info("Closing ChrononAwsOnlineImpl resources...")

    // Shutdown scheduler if not already shut down
    Try {
      if (scheduler != null && !scheduler.isShutdown) {
        scheduler.shutdown()
        if (!scheduler.awaitTermination(5, TimeUnit.SECONDS)) {
          logger.warn("Scheduler did not terminate gracefully within 5 seconds, forcing shutdown")
          scheduler.shutdownNow()
          if (!scheduler.awaitTermination(2, TimeUnit.SECONDS)) {
            logger.error("Scheduler did not terminate after forced shutdown")
          }
        }
      }
    }.recover { case e: Exception =>
      logger.error("Error shutting down scheduler", e)
    }

    // Shutdown kvStoreExecutor if not already shut down
    Try {
      if (kvStoreExecutor != null && !kvStoreExecutor.isShutdown) {
        kvStoreExecutor.shutdown()
        if (!kvStoreExecutor.awaitTermination(5, TimeUnit.SECONDS)) {
          logger.warn("KVStore executor did not terminate gracefully within 5 seconds, forcing shutdown")
          kvStoreExecutor.shutdownNow()
          if (!kvStoreExecutor.awaitTermination(2, TimeUnit.SECONDS)) {
            logger.error("KVStore executor did not terminate after forced shutdown")
          }
        }
      }
    }.recover { case e: Exception =>
      logger.error("Error shutting down KVStore executor", e)
    }

    // Close DynamoDB client
    // Note: DynamoDbClient.close() should be idempotent, but we handle exceptions
    // gracefully in case the client is already closed or the connection pool is shut down
    Try {
      if (dynamoDbClient != null) {
        try {
          dynamoDbClient.close()
        } catch {
          case _: IllegalStateException =>
            // Connection pool already shut down or client already closed - this is fine
            logger.debug("DynamoDB client connection pool was already shut down")
          case e: Exception =>
            // Log other exceptions but don't fail the close operation
            logger.warn(s"Exception while closing DynamoDB client (may already be closed): ${e.getMessage}")
        }
      }
    }.recover { case e: Exception =>
      logger.error("Error closing DynamoDB client", e)
    }

    logger.info("ChrononAwsOnlineImpl resources closed")
  }
}

