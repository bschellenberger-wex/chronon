package ai.chronon.integrations.aws

import software.amazon.awssdk.services.dynamodb.DynamoDbClient
import software.amazon.awssdk.services.dynamodb.model.{
  AttributeDefinition,
  BillingMode,
  CreateTableRequest,
  DescribeTableRequest,
  KeySchemaElement,
  KeyType,
  ResourceInUseException,
  ScalarAttributeType,
  TableStatus
}
import org.slf4j.{Logger, LoggerFactory}

/**
 * Shared helper for creating DynamoDB tables with consistent configuration.
 * 
 * This ensures both ChrononAwsOnlineImpl (via DynamoDBKVStoreImpl) and
 * Spark2DynamoLoader create tables uniformly with:
 * - On-demand billing mode (no provisioned capacity)
 * - Idempotent creation (doesn't fail if table exists)
 * - Consistent table structure (partition key only)
 *
 */
object DynamoDBTableHelper {
  
  private val log: Logger = LoggerFactory.getLogger(getClass)

  
  /**
   * Creates a DynamoDB table if it doesn't already exist (idempotent).
   * 
   * Tables are created with partition key only (no sort key).
   * 
   * @param client DynamoDB client
   * @param dataset Dataset name (will be prefixed with chronon_ prefix)
   * @return The full table name (with prefix)
   */
  def createTableIfNotExists(client: DynamoDbClient, dataset: String): String = {
    val tableName = prefixedTableName(dataset)
    
    // Check if table already exists
    if (tableExists(client, tableName)) {
      log.info(s"Table already exists: $tableName (dataset: $dataset)")
      return tableName
    }
    
    // Build attribute definitions (partition key only)
    val keyAttributes = Seq(
      AttributeDefinition.builder
        .attributeName(AWSOnlineConstants.dynamoTableKey)
        .attributeType(ScalarAttributeType.B)
        .build()
    )
    
    // Build key schema (partition key only)
    val keySchema = Seq(
      KeySchemaElement.builder
        .attributeName(AWSOnlineConstants.dynamoTableKey)
        .keyType(KeyType.HASH)
        .build()
    )
    
    // Create table request with on-demand billing mode
    val request = CreateTableRequest.builder
      .tableName(tableName)
      .attributeDefinitions(keyAttributes: _*)
      .keySchema(keySchema: _*)
      .billingMode(BillingMode.PAY_PER_REQUEST) // On-demand: no provisioned capacity
      .build()
    
    log.info(s"Creating DynamoDB table: $tableName (dataset: $dataset)")
    
    try {
      val response = client.createTable(request)
      
      // Wait for table to become active
      val waiter = client.waiter()
      val describeRequest = DescribeTableRequest.builder.tableName(tableName).build()
      val waiterResponse = waiter.waitUntilTableExists(describeRequest)
      
      if (waiterResponse.matched().exception().isPresent) {
        throw waiterResponse.matched().exception().get()
      }
      
      val tableDescription = waiterResponse.matched().response().get().table()
      log.info(s"Table created successfully: $tableName (status: ${tableDescription.tableStatus()})")
      tableName
      
    } catch {
      case _: ResourceInUseException =>
        // Table was created between our check and create call - this is fine
        log.info(s"Table already exists (race condition): $tableName")
        tableName
      case e: Exception =>
        log.error(s"Error creating DynamoDB table: $tableName", e)
        throw e
    }
  }
  
  /**
   * Checks if a DynamoDB table exists.
   * 
   * @param client DynamoDB client
   * @param tableName Full table name (with prefix)
   * @return true if table exists, false otherwise
   */
  private def tableExists(client: DynamoDbClient, tableName: String): Boolean = {
    try {
      val request = DescribeTableRequest.builder.tableName(tableName).build()
      val response = client.describeTable(request)
      val status = response.table().tableStatus()
      // Table exists if it's in any of these states
      status == TableStatus.ACTIVE || 
      status == TableStatus.CREATING || 
      status == TableStatus.UPDATING
    } catch {
      case _: software.amazon.awssdk.services.dynamodb.model.ResourceNotFoundException =>
        false
      case e: Exception =>
        // Log but don't fail - let create attempt handle it
        log.warn(s"Error checking if table exists: $tableName", e)
        false
    }
  }
  
  /**
   * Applies the chronon_ prefix to a dataset name if not already present.
   * 
   * @param dataset Dataset name
   * @return Prefixed table name
   */
  def prefixedTableName(dataset: String): String = {
    if (dataset.startsWith(AWSOnlineConstants.DynamoDBTablePrefix)) {
      dataset // Already prefixed
    } else {
      AWSOnlineConstants.DynamoDBTablePrefix + dataset
    }
  }
}

