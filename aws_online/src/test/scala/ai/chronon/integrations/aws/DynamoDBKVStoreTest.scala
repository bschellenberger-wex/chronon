package ai.chronon.integrations.aws

import ai.chronon.online.KVStore._
import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.module.scala.DefaultScalaModule
import org.scalatest.BeforeAndAfterAll
import org.scalatest.flatspec.AnyFlatSpec
import org.scalatest.matchers.should.Matchers.convertToAnyShouldWrapper
import org.testcontainers.containers.GenericContainer
import org.testcontainers.utility.DockerImageName
import software.amazon.awssdk.auth.credentials.{AwsBasicCredentials, StaticCredentialsProvider}
import software.amazon.awssdk.regions.Region
import software.amazon.awssdk.services.dynamodb.DynamoDbClient

import java.net.URI
import java.nio.charset.StandardCharsets
import scala.collection.Seq
import scala.concurrent.{Await, ExecutionContext}
import scala.concurrent.duration.DurationInt
import java.util.concurrent.{Executors, ScheduledExecutorService}

object DDBTestUtils {

  // different types of tables to store
  case class Model(modelId: String, modelName: String, online: Boolean)
}

class DynamoDBKVStoreTest extends AnyFlatSpec with BeforeAndAfterAll {

  import DDBTestUtils._

  var dynamoContainer: GenericContainer[_] = _
  var client: DynamoDbClient = _
  var kvStoreImpl: DynamoDBKVStoreImpl = _
  var scheduler: ScheduledExecutorService = _
  implicit var executionContext: ExecutionContext = _

  private val objectMapper = new ObjectMapper()
  objectMapper.registerModule(DefaultScalaModule)

  def modelKeyEncoder(model: Model): Array[Byte] = {
    objectMapper.writeValueAsString(model.modelId).getBytes(StandardCharsets.UTF_8)
  }

  def modelValueEncoder(model: Model): Array[Byte] = {
    objectMapper.writeValueAsString(model).getBytes(StandardCharsets.UTF_8)
  }

  override def beforeAll(): Unit = {
    // Create ScheduledExecutorService for non-blocking retry delays
    scheduler = Executors.newScheduledThreadPool(2)
    executionContext = ExecutionContext.global
    
    // Start the DynamoDB Local container
    dynamoContainer = new GenericContainer(DockerImageName.parse("amazon/dynamodb-local:latest"))
    dynamoContainer.withExposedPorts(8000: Integer)
    dynamoContainer.withCommand("-jar", "DynamoDBLocal.jar", "-inMemory", "-sharedDb")
    dynamoContainer.start()

    // Create the DynamoDbClient pointing to the container
    val dynamoEndpoint = s"http://${dynamoContainer.getHost}:${dynamoContainer.getMappedPort(8000)}"
    client = DynamoDbClient
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
    if (client != null) {
      client.close()
    }
    if (dynamoContainer != null) {
      dynamoContainer.stop()
    }
    if (scheduler != null) {
      scheduler.shutdown()
      if (!scheduler.awaitTermination(10, java.util.concurrent.TimeUnit.SECONDS)) {
        scheduler.shutdownNow()
      }
    }
  }

  // Test creation of a table with primary keys only (e.g. model)
  it should "create p key only table" in {
    val dataset = "models"
    val kvStore = new DynamoDBKVStoreImpl(client, scheduler)(executionContext)
    kvStore.create(dataset)

    // Verify that the table exists with prefix
    val expectedTableName = AWSOnlineConstants.DynamoDBTablePrefix + dataset
    val tables = client.listTables().tableNames()
    tables.contains(expectedTableName) shouldBe true

    // try another create for an existing table, should not fail
    kvStore.create(dataset)
  }

  // Test that table prefix is correctly applied
  it should "apply chronon_ prefix to all table names" in {
    val expectedPrefix = "chronon_"
    AWSOnlineConstants.DynamoDBTablePrefix shouldBe expectedPrefix

    val dataset1 = "test_dataset"
    val dataset2 = "another_table"
    val dataset3 = "prefixed_chronon_table" // Already has prefix
    
    val kvStore = new DynamoDBKVStoreImpl(client, scheduler)(executionContext)
    
    // Create tables
    kvStore.create(dataset1)
    kvStore.create(dataset2)
    kvStore.create(dataset3)
    
    val tables = client.listTables().tableNames()
    
    // Verify prefix is applied to unprefixed names
    val expectedTable1 = AWSOnlineConstants.DynamoDBTablePrefix + dataset1
    tables.contains(expectedTable1) shouldBe true
    tables.contains(dataset1) shouldBe false // Original name should not exist
    
    val expectedTable2 = AWSOnlineConstants.DynamoDBTablePrefix + dataset2
    tables.contains(expectedTable2) shouldBe true
    tables.contains(dataset2) shouldBe false // Original name should not exist
    
    // Verify already prefixed names are not double-prefixed
    val expectedTable3 = AWSOnlineConstants.DynamoDBTablePrefix + dataset3
    tables.contains(expectedTable3) shouldBe true
    // Should not have double prefix
    val doublePrefix = AWSOnlineConstants.DynamoDBTablePrefix + AWSOnlineConstants.DynamoDBTablePrefix + dataset3
    tables.contains(doublePrefix) shouldBe false
  }

  // Test write & read of a simple blob dataset
  it should "blob data round trip" in {
    val dataset = "models"
    val kvStore = new DynamoDBKVStoreImpl(client, scheduler)(executionContext)
    kvStore.create(dataset) // Will create table with "chronon_" prefix

    val model1 = Model("my_model_1", "test model 1", online = true)
    val model2 = Model("my_model_2", "test model 2", online = true)
    val model3 = Model("my_model_3", "test model 3", online = false)

    val putReq1 = buildModelPutRequest(model1, dataset)
    val putReq2 = buildModelPutRequest(model2, dataset)
    val putReq3 = buildModelPutRequest(model3, dataset)

    val putResults = Await.result(kvStore.multiPut(Seq(putReq1, putReq2, putReq3)), 1.minute)
    putResults shouldBe Seq(true, true, true)

    // let's try and read these
    val getReq1 = buildModelGetRequest(model1, dataset)
    val getReq2 = buildModelGetRequest(model2, dataset)
    val getReq3 = buildModelGetRequest(model3, dataset)

    val getResult1 = Await.result(kvStore.multiGet(Seq(getReq1)), 1.minute)
    val getResult2 = Await.result(kvStore.multiGet(Seq(getReq2)), 1.minute)
    val getResult3 = Await.result(kvStore.multiGet(Seq(getReq3)), 1.minute)

    validateExpectedModelResponse(model1, getResult1)
    validateExpectedModelResponse(model2, getResult2)
    validateExpectedModelResponse(model3, getResult3)
  }

  // Test batch get operations - validate that multiple requests in a single multiGet call work correctly
  it should "blob data round trip in a single batch" in {
    val dataset = "models_batch"
    val kvStore = new DynamoDBKVStoreImpl(client, scheduler)(executionContext)
    kvStore.create(dataset)

    val model1 = Model("batch_model_1", "batch test model 1", online = true)
    val model2 = Model("batch_model_2", "batch test model 2", online = true)
    val model3 = Model("batch_model_3", "batch test model 3", online = false)

    val putReq1 = buildModelPutRequest(model1, dataset)
    val putReq2 = buildModelPutRequest(model2, dataset)
    val putReq3 = buildModelPutRequest(model3, dataset)

    val putResults = Await.result(kvStore.multiPut(Seq(putReq1, putReq2, putReq3)), 1.minute)
    putResults shouldBe Seq(true, true, true)

    // Create 3 GetRequest objects
    val getReq1 = buildModelGetRequest(model1, dataset)
    val getReq2 = buildModelGetRequest(model2, dataset)
    val getReq3 = buildModelGetRequest(model3, dataset)

    // Call multiGet once with all 3 GetRequest objects
    val getResults = Await.result(kvStore.multiGet(Seq(getReq1, getReq2, getReq3)), 1.minute)

    // Assert that the resulting getResults has a length of 3
    getResults.length shouldBe 3

    // Validate that all 3 models are correctly returned from the batch
    val model1Results = getResults.filter(_.request == getReq1)
    val model2Results = getResults.filter(_.request == getReq2)
    val model3Results = getResults.filter(_.request == getReq3)

    validateExpectedModelResponse(model1, model1Results)
    validateExpectedModelResponse(model2, model2Results)
    validateExpectedModelResponse(model3, model3Results)
  }

  // Test write, query, overwrite and query data
  it should "overwrite existing blob data" in {
    val dataset = "models"
    val kvStore = new DynamoDBKVStoreImpl(client, scheduler)(executionContext)
    kvStore.create(dataset) // Will create table with "chronon_" prefix

    val model1 = Model("model_overwrite", "initial model", online = true)
    val putReq1 = buildModelPutRequest(model1, dataset)
    val putResult1 = Await.result(kvStore.multiPut(Seq(putReq1)), 1.minute)
    putResult1 shouldBe Seq(true)

    val getReq1 = buildModelGetRequest(model1, dataset)
    val getResult1 = Await.result(kvStore.multiGet(Seq(getReq1)), 1.minute)
    validateExpectedModelResponse(model1, getResult1)

    // Now overwrite with new data
    val model1Updated = Model("model_overwrite", "updated model", online = false)
    val putReq2 = buildModelPutRequest(model1Updated, dataset)
    val putResult2 = Await.result(kvStore.multiPut(Seq(putReq2)), 1.minute)
    putResult2 shouldBe Seq(true)

    val getReq2 = buildModelGetRequest(model1Updated, dataset)
    val getResult2 = Await.result(kvStore.multiGet(Seq(getReq2)), 1.minute)
    validateExpectedModelResponse(model1Updated, getResult2)
  }

  private def buildModelPutRequest(model: Model, dataset: String): PutRequest = {
    val keyBytes = modelKeyEncoder(model)
    val valueBytes = modelValueEncoder(model)
    PutRequest(keyBytes, valueBytes, dataset, None)
  }

  private def buildModelGetRequest(model: Model, dataset: String): GetRequest = {
    val keyBytes = modelKeyEncoder(model)
    GetRequest(keyBytes, dataset, None)
  }

  private def validateExpectedModelResponse(expectedModel: Model, response: Seq[GetResponse]): Unit = {
    response.length shouldBe 1
    for (
      tSeq <- response.head.values;
      tv <- tSeq
    ) {
      tSeq.length shouldBe 1
      val jsonStr = new String(tv.bytes, StandardCharsets.UTF_8)
      val returnedModel = objectMapper.readValue(jsonStr, classOf[Model])
      returnedModel shouldBe expectedModel
    }
  }

}

