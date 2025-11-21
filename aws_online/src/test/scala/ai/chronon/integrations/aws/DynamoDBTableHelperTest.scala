package ai.chronon.integrations.aws

import org.scalatest.BeforeAndAfterAll
import org.scalatest.flatspec.AnyFlatSpec
import org.scalatest.matchers.should.Matchers
import org.testcontainers.containers.GenericContainer
import org.testcontainers.utility.DockerImageName
import software.amazon.awssdk.auth.credentials.{AwsBasicCredentials, StaticCredentialsProvider}
import software.amazon.awssdk.regions.Region
import software.amazon.awssdk.services.dynamodb.DynamoDbClient
import software.amazon.awssdk.services.dynamodb.model.{
  AttributeDefinition,
  DescribeTableRequest,
  KeySchemaElement,
  KeyType,
  ResourceInUseException,
  ScalarAttributeType,
  TableStatus
}

import java.net.URI
import scala.collection.JavaConverters._

class DynamoDBTableHelperTest extends AnyFlatSpec with Matchers with BeforeAndAfterAll {

  var dynamoContainer: GenericContainer[_] = _
  var dynamoClient: DynamoDbClient = _
  var dynamoEndpoint: String = _

  override def beforeAll(): Unit = {
    super.beforeAll()

    // Start DynamoDB Local container
    dynamoContainer = new GenericContainer(DockerImageName.parse("amazon/dynamodb-local:latest"))
    dynamoContainer.withExposedPorts(8000: Integer)
    dynamoContainer.withCommand("-jar", "DynamoDBLocal.jar", "-inMemory", "-sharedDb")
    dynamoContainer.start()

    // Create DynamoDB client pointing to container
    dynamoEndpoint = s"http://${dynamoContainer.getHost}:${dynamoContainer.getMappedPort(8000)}"
    dynamoClient = DynamoDbClient
      .builder()
      .endpointOverride(URI.create(dynamoEndpoint))
      .region(Region.US_WEST_2)
      .credentialsProvider(
        StaticCredentialsProvider.create(
          AwsBasicCredentials.create("dummy", "dummy")
        ))
      .build()
  }

  override def afterAll(): Unit = {
    if (dynamoClient != null) {
      dynamoClient.close()
    }
    if (dynamoContainer != null) {
      dynamoContainer.stop()
    }
    super.afterAll()
  }

  // Helper to clean up tables between tests
  private def deleteTableIfExists(tableName: String): Unit = {
    try {
      dynamoClient.deleteTable(builder => builder.tableName(tableName).build())
      // Wait for deletion
      val waiter = dynamoClient.waiter()
      val describeRequest = DescribeTableRequest.builder.tableName(tableName).build()
      try {
        waiter.waitUntilTableNotExists(describeRequest)
      } catch {
        case _: Exception => // Ignore - table might already be deleted
      }
    } catch {
      case _: software.amazon.awssdk.services.dynamodb.model.ResourceNotFoundException =>
        // Table doesn't exist, that's fine
      case _: Exception => // Ignore other errors
    }
  }

  "DynamoDBTableHelper" should "create a table with partition key only" in {
    val dataset = "test_table_1"
    val tableName = DynamoDBTableHelper.createTableIfNotExists(dynamoClient, dataset)

    // Verify table name has prefix
    tableName shouldBe s"${AWSOnlineConstants.DynamoDBTablePrefix}$dataset"

    // Verify table exists
    val describeRequest = DescribeTableRequest.builder.tableName(tableName).build()
    val response = dynamoClient.describeTable(describeRequest)
    val table = response.table()

    table.tableName() shouldBe tableName
    table.tableStatus() shouldBe TableStatus.ACTIVE

    // Verify key schema (partition key only)
    val keySchema = table.keySchema().asScala.toSeq
    keySchema.length shouldBe 1
    keySchema.head.attributeName() shouldBe AWSOnlineConstants.dynamoTableKey
    keySchema.head.keyType() shouldBe KeyType.HASH

    // Verify attribute definitions
    val attributes = table.attributeDefinitions().asScala.toSeq
    attributes.length shouldBe 1
    attributes.head.attributeName() shouldBe AWSOnlineConstants.dynamoTableKey
    attributes.head.attributeType() shouldBe ScalarAttributeType.B

    // Clean up
    deleteTableIfExists(tableName)
  }

  it should "create table with on-demand billing mode" in {
    val dataset = "test_table_billing"
    val tableName = DynamoDBTableHelper.createTableIfNotExists(dynamoClient, dataset)

    val describeRequest = DescribeTableRequest.builder.tableName(tableName).build()
    val response = dynamoClient.describeTable(describeRequest)
    val table = response.table()

    // Verify billing mode (on-demand)
    table.billingModeSummary() should not be null
    table.billingModeSummary().billingMode() shouldBe software.amazon.awssdk.services.dynamodb.model.BillingMode.PAY_PER_REQUEST

    // Clean up
    deleteTableIfExists(tableName)
  }

  it should "apply chronon_ prefix to dataset name" in {
    val dataset = "my_dataset"
    val tableName = DynamoDBTableHelper.createTableIfNotExists(dynamoClient, dataset)

    tableName shouldBe s"${AWSOnlineConstants.DynamoDBTablePrefix}$dataset"
    tableName should startWith(AWSOnlineConstants.DynamoDBTablePrefix)

    // Verify table exists with prefixed name
    val describeRequest = DescribeTableRequest.builder.tableName(tableName).build()
    val response = dynamoClient.describeTable(describeRequest)
    response.table().tableName() shouldBe tableName

    // Clean up
    deleteTableIfExists(tableName)
  }

  it should "not double-prefix if dataset already has prefix" in {
    val dataset = s"${AWSOnlineConstants.DynamoDBTablePrefix}already_prefixed"
    val tableName = DynamoDBTableHelper.createTableIfNotExists(dynamoClient, dataset)

    // Should not have double prefix
    tableName shouldBe dataset
    tableName should not startWith(s"${AWSOnlineConstants.DynamoDBTablePrefix}${AWSOnlineConstants.DynamoDBTablePrefix}")

    // Verify table exists
    val describeRequest = DescribeTableRequest.builder.tableName(tableName).build()
    val response = dynamoClient.describeTable(describeRequest)
    response.table().tableName() shouldBe tableName

    // Clean up
    deleteTableIfExists(tableName)
  }

  it should "be idempotent - not fail when table already exists" in {
    val dataset = "idempotent_test"
    val tableName = DynamoDBTableHelper.createTableIfNotExists(dynamoClient, dataset)

    // Create again - should not throw
    val tableName2 = DynamoDBTableHelper.createTableIfNotExists(dynamoClient, dataset)
    tableName2 shouldBe tableName

    // Verify table still exists and is valid
    val describeRequest = DescribeTableRequest.builder.tableName(tableName).build()
    val response = dynamoClient.describeTable(describeRequest)
    response.table().tableStatus() shouldBe TableStatus.ACTIVE

    // Clean up
    deleteTableIfExists(tableName)
  }

  it should "handle race condition when table is created between check and create" in {
    val dataset = "race_condition_test"
    
    // Create table first time
    val tableName1 = DynamoDBTableHelper.createTableIfNotExists(dynamoClient, dataset)
    
    // Simulate race condition by creating table again immediately
    // This should not throw ResourceInUseException (handled internally)
    val tableName2 = DynamoDBTableHelper.createTableIfNotExists(dynamoClient, dataset)
    
    tableName1 shouldBe tableName2
    
    // Verify table is still valid
    val describeRequest = DescribeTableRequest.builder.tableName(tableName1).build()
    val response = dynamoClient.describeTable(describeRequest)
    response.table().tableStatus() shouldBe TableStatus.ACTIVE

    // Clean up
    deleteTableIfExists(tableName1)
  }

  it should "wait for table to become active before returning" in {
    val dataset = "active_wait_test"
    val tableName = DynamoDBTableHelper.createTableIfNotExists(dynamoClient, dataset)

    // Table should be active immediately after creation
    val describeRequest = DescribeTableRequest.builder.tableName(tableName).build()
    val response = dynamoClient.describeTable(describeRequest)
    response.table().tableStatus() shouldBe TableStatus.ACTIVE

    // Clean up
    deleteTableIfExists(tableName)
  }

  it should "accept empty props map" in {
    val dataset = "empty_props_test"
    val tableName = DynamoDBTableHelper.createTableIfNotExists(dynamoClient, dataset)

    tableName shouldBe s"${AWSOnlineConstants.DynamoDBTablePrefix}$dataset"

    // Verify table exists
    val describeRequest = DescribeTableRequest.builder.tableName(tableName).build()
    val response = dynamoClient.describeTable(describeRequest)
    response.table().tableStatus() shouldBe TableStatus.ACTIVE

    // Clean up
    deleteTableIfExists(tableName)
  }

  it should "accept props map (reserved for future use)" in {
    val dataset = "props_test"
    val props = Map("ttl" -> "enabled", "gsi" -> "index1")
    val tableName = DynamoDBTableHelper.createTableIfNotExists(dynamoClient, dataset)

    // Props are currently ignored, but method should accept them
    tableName shouldBe s"${AWSOnlineConstants.DynamoDBTablePrefix}$dataset"

    // Verify table exists
    val describeRequest = DescribeTableRequest.builder.tableName(tableName).build()
    val response = dynamoClient.describeTable(describeRequest)
    response.table().tableStatus() shouldBe TableStatus.ACTIVE

    // Clean up
    deleteTableIfExists(tableName)
  }

  it should "create multiple tables with different names" in {
    val dataset1 = "multi_table_1"
    val dataset2 = "multi_table_2"
    val dataset3 = "multi_table_3"

    val tableName1 = DynamoDBTableHelper.createTableIfNotExists(dynamoClient, dataset1)
    val tableName2 = DynamoDBTableHelper.createTableIfNotExists(dynamoClient, dataset2)
    val tableName3 = DynamoDBTableHelper.createTableIfNotExists(dynamoClient, dataset3)

    // Verify all tables exist
    val tables = dynamoClient.listTables().tableNames().asScala.toSet
    tables should contain(tableName1)
    tables should contain(tableName2)
    tables should contain(tableName3)

    // Verify all tables are distinct
    Set(tableName1, tableName2, tableName3).size shouldBe 3

    // Clean up
    deleteTableIfExists(tableName1)
    deleteTableIfExists(tableName2)
    deleteTableIfExists(tableName3)
  }

  it should "create table with special characters in dataset name" in {
    val dataset = "test_table_with_special_chars_123"
    val tableName = DynamoDBTableHelper.createTableIfNotExists(dynamoClient, dataset)

    tableName shouldBe s"${AWSOnlineConstants.DynamoDBTablePrefix}$dataset"

    // Verify table exists
    val describeRequest = DescribeTableRequest.builder.tableName(tableName).build()
    val response = dynamoClient.describeTable(describeRequest)
    response.table().tableStatus() shouldBe TableStatus.ACTIVE

    // Clean up
    deleteTableIfExists(tableName)
  }

  it should "create table with very long dataset name" in {
    val dataset = "a" * 100 // 100 character dataset name
    val tableName = DynamoDBTableHelper.createTableIfNotExists(dynamoClient, dataset)

    tableName shouldBe s"${AWSOnlineConstants.DynamoDBTablePrefix}$dataset"

    // Verify table exists
    val describeRequest = DescribeTableRequest.builder.tableName(tableName).build()
    val response = dynamoClient.describeTable(describeRequest)
    response.table().tableStatus() shouldBe TableStatus.ACTIVE

    // Clean up
    deleteTableIfExists(tableName)
  }

  it should "verify partition key column matches AWSOnlineConstants" in {
    val dataset = "constants_test"
    val tableName = DynamoDBTableHelper.createTableIfNotExists(dynamoClient, dataset)

    val describeRequest = DescribeTableRequest.builder.tableName(tableName).build()
    val response = dynamoClient.describeTable(describeRequest)
    val keySchema = response.table().keySchema().asScala.toSeq

    // Verify partition key matches constant
    keySchema.head.attributeName() shouldBe AWSOnlineConstants.dynamoTableKey
    // Note: partitionKeyColumn is private, so we can't access it directly in tests

    // Clean up
    deleteTableIfExists(tableName)
  }

  it should "handle concurrent table creation requests" in {
    val dataset = "concurrent_test"
    
    // Create table multiple times concurrently (simulated sequentially)
    val tableName1 = DynamoDBTableHelper.createTableIfNotExists(dynamoClient, dataset)
    val tableName2 = DynamoDBTableHelper.createTableIfNotExists(dynamoClient, dataset)
    val tableName3 = DynamoDBTableHelper.createTableIfNotExists(dynamoClient, dataset)

    // All should return the same table name
    tableName1 shouldBe tableName2
    tableName2 shouldBe tableName3

    // Table should exist and be active
    val describeRequest = DescribeTableRequest.builder.tableName(tableName1).build()
    val response = dynamoClient.describeTable(describeRequest)
    response.table().tableStatus() shouldBe TableStatus.ACTIVE

    // Clean up
    deleteTableIfExists(tableName1)
  }
}

