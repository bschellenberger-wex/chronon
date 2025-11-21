package ai.chronon.integrations.aws

import ai.chronon.api.{Constants => ApiConstants}

import org.scalatest.flatspec.AnyFlatSpec
import org.scalatest.matchers.should.Matchers
import org.scalatest.BeforeAndAfterAll
import org.apache.spark.sql.{Row, SparkSession}
import org.apache.spark.sql.types._
import org.testcontainers.containers.GenericContainer
import org.testcontainers.utility.DockerImageName
import software.amazon.awssdk.auth.credentials.{AwsBasicCredentials, StaticCredentialsProvider}
import software.amazon.awssdk.regions.Region
import software.amazon.awssdk.services.dynamodb.DynamoDbClient
import software.amazon.awssdk.core.SdkBytes

import java.net.URI
import java.util.concurrent.{Executors, ScheduledExecutorService}
import scala.concurrent.{Await, ExecutionContext}
import scala.concurrent.duration._

class Spark2DynamoLoaderTest extends AnyFlatSpec with Matchers with BeforeAndAfterAll {

  var spark: SparkSession = _
  var dynamoContainer: GenericContainer[_] = _
  var dynamoClient: DynamoDbClient = _
  var dynamoEndpoint: String = _
  var scheduler: ScheduledExecutorService = _
  implicit var executionContext: ExecutionContext = _

  override def beforeAll(): Unit = {
    super.beforeAll()
    
    // Start Spark session
    spark = SparkSession.builder()
      .appName("Spark2DynamoLoaderTest")
      .master("local[1]")
      .config("spark.sql.warehouse.dir", "/tmp/spark-warehouse")
      .getOrCreate()
    
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
    
    // Initialize scheduler and execution context for DynamoDBKVStoreImpl
    scheduler = Executors.newScheduledThreadPool(1)
    executionContext = ExecutionContext.global
  }

  override def afterAll(): Unit = {
    if (scheduler != null) {
      scheduler.shutdown()
    }
    if (dynamoClient != null) {
      dynamoClient.close()
    }
    if (dynamoContainer != null) {
      dynamoContainer.stop()
    }
    if (spark != null) {
      spark.stop()
    }
    super.afterAll()
  }
  
  // Helper method to provide a client factory that returns our test client
  // No mocking needed - we use dependency injection via the clientFactory parameter
  // Important: The factory must create a new client each time (not capture an existing one)
  // because DynamoDbClient is not serializable, but the endpoint String is
  def withTestClientFactory[T](testCode: (() => DynamoDbClient) => T): T = {
    // Capture only the endpoint (serializable) and create a new client each time
    val endpoint = dynamoEndpoint
    val clientFactory: () => DynamoDbClient = () => {
      DynamoDbClient
        .builder()
        .endpointOverride(URI.create(endpoint))
        .region(Region.US_WEST_2)
        .credentialsProvider(
          StaticCredentialsProvider.create(
            AwsBasicCredentials.create("dummy", "dummy")
          )
        )
        .build()
    }
    testCode(clientFactory)
  }

  "Spark2DynamoLoader" should "map table names to correct dataset names" in {
    // Test the actual deriveDataset method
    Spark2DynamoLoader.deriveDataset("test_logged_daily_stats_upload") shouldBe ApiConstants.LogStatsBatchDataset
    Spark2DynamoLoader.deriveDataset("test_daily_stats_upload") shouldBe ApiConstants.StatsBatchDataset
    Spark2DynamoLoader.deriveDataset("test_consistency_upload") shouldBe ApiConstants.ConsistencyMetricsDataset
    Spark2DynamoLoader.deriveDataset("my_table_upload") shouldBe "MY_TABLE_BATCH"
    Spark2DynamoLoader.deriveDataset("db.my_table_upload") shouldBe "MY_TABLE_BATCH"
    Spark2DynamoLoader.deriveDataset("regular_table") shouldBe "REGULAR_TABLE_BATCH"
  }

  it should "apply DynamoDB table prefix correctly" in {
    // Test the actual applyDynamoDBTablePrefix method
    Spark2DynamoLoader.applyDynamoDBTablePrefix("MY_TABLE_BATCH") shouldBe "chronon_MY_TABLE_BATCH"
    Spark2DynamoLoader.applyDynamoDBTablePrefix("chronon_MY_TABLE_BATCH") shouldBe "chronon_MY_TABLE_BATCH"
    Spark2DynamoLoader.applyDynamoDBTablePrefix(ApiConstants.LogStatsBatchDataset) shouldBe s"chronon_${ApiConstants.LogStatsBatchDataset}"
  }

  it should "select correct key and value columns from DataFrame" in {
    // Create a test DataFrame with both snake_case and camelCase column names
    val testData = Seq(
      Row(Array[Byte](1, 2, 3), Array[Byte](4, 5, 6), 1000L, "2024-01-01")
    )
    
    val dfWithSnakeCase = spark.createDataFrame(
      spark.sparkContext.parallelize(testData),
      StructType(Seq(
        StructField(AWSOnlineConstants.sparkKeyColumn, BinaryType),
        StructField(AWSOnlineConstants.sparkValueColumn, BinaryType),
        StructField(AWSOnlineConstants.sparkTsColumn, LongType),
        StructField(AWSOnlineConstants.sparkDsColumn, StringType)
      ))
    )

    val dfWithCamelCase = spark.createDataFrame(
      spark.sparkContext.parallelize(testData),
      StructType(Seq(
        StructField(AWSOnlineConstants.dynamoTableKey, BinaryType),
        StructField(AWSOnlineConstants.dynamoTableValue, BinaryType),
        StructField(AWSOnlineConstants.dynamoTableTs, LongType),
        StructField(AWSOnlineConstants.sparkDsColumn, StringType)
      ))
    )

    // Test snake_case column selection
    val keyCol1 = if (dfWithSnakeCase.columns.contains(AWSOnlineConstants.sparkKeyColumn)) {
      AWSOnlineConstants.sparkKeyColumn
    } else {
      AWSOnlineConstants.dynamoTableKey
    }
    keyCol1 shouldBe AWSOnlineConstants.sparkKeyColumn

    // Test camelCase fallback
    val keyCol2 = if (dfWithCamelCase.columns.contains(AWSOnlineConstants.sparkKeyColumn)) {
      AWSOnlineConstants.sparkKeyColumn
    } else {
      AWSOnlineConstants.dynamoTableKey
    }
    keyCol2 shouldBe AWSOnlineConstants.dynamoTableKey
  }

  it should "transform DataFrame columns correctly for DynamoDB schema" in {
    // Create test data with binary key/value and timestamp
    val testData = Seq(
      Row(Array[Byte](1, 2, 3), Array[Byte](4, 5, 6), 1000L)
    )
    
    val baseDf = spark.createDataFrame(
      spark.sparkContext.parallelize(testData),
      StructType(Seq(
        StructField(AWSOnlineConstants.sparkKeyColumn, BinaryType),
        StructField(AWSOnlineConstants.sparkValueColumn, BinaryType),
        StructField(AWSOnlineConstants.sparkTsColumn, LongType)
      ))
    )

    // Test the actual transformDataFrameForDynamoDB method
    val transformedDf = Spark2DynamoLoader.transformDataFrameForDynamoDB(baseDf, "test_table")

    transformedDf.columns should contain allOf(
      AWSOnlineConstants.dynamoTableKey,
      AWSOnlineConstants.dynamoTableValue,
      AWSOnlineConstants.dynamoTableTs
    )

    val row = transformedDf.first()
    row.getAs[Array[Byte]](AWSOnlineConstants.dynamoTableKey) shouldBe Array[Byte](1, 2, 3)
    row.getAs[Array[Byte]](AWSOnlineConstants.dynamoTableValue) shouldBe Array[Byte](4, 5, 6)
    row.getAs[Long](AWSOnlineConstants.dynamoTableTs) shouldBe 1000L
  }

  it should "handle base64-encoded string columns" in {
    import java.util.Base64
    
    val keyBytes = Array[Byte](1, 2, 3)
    val valueBytes = Array[Byte](4, 5, 6)
    val keyBase64 = Base64.getEncoder.encodeToString(keyBytes)
    val valueBase64 = Base64.getEncoder.encodeToString(valueBytes)

    val testData = Seq(
      Row(keyBase64, valueBase64, 1000L)
    )
    
    val baseDf = spark.createDataFrame(
      spark.sparkContext.parallelize(testData),
      StructType(Seq(
        StructField(AWSOnlineConstants.sparkKeyColumn, StringType),
        StructField(AWSOnlineConstants.sparkValueColumn, StringType),
        StructField(AWSOnlineConstants.sparkTsColumn, LongType)
      ))
    )

    // Test the actual transformDataFrameForDynamoDB method with base64 strings
    val transformedDf = Spark2DynamoLoader.transformDataFrameForDynamoDB(baseDf, "test_table")

    val row = transformedDf.first()
    val decodedKey = row.getAs[Array[Byte]](AWSOnlineConstants.dynamoTableKey)
    val decodedValue = row.getAs[Array[Byte]](AWSOnlineConstants.dynamoTableValue)
    
    decodedKey shouldBe keyBytes
    decodedValue shouldBe valueBytes
  }

  it should "derive timestamp from ds column when ts column is missing" in {
    val testData = Seq(
      Row(Array[Byte](1, 2, 3), Array[Byte](4, 5, 6), "2024-01-01")
    )
    
    val baseDf = spark.createDataFrame(
      spark.sparkContext.parallelize(testData),
      StructType(Seq(
        StructField(AWSOnlineConstants.sparkKeyColumn, BinaryType),
        StructField(AWSOnlineConstants.sparkValueColumn, BinaryType),
        StructField(AWSOnlineConstants.sparkDsColumn, StringType)
      ))
    )

    // Test the actual transformDataFrameForDynamoDB method with ds column
    val transformedDf = Spark2DynamoLoader.transformDataFrameForDynamoDB(baseDf, "test_table")

    val row = transformedDf.first()
    val timestamp = row.getAs[Long](AWSOnlineConstants.dynamoTableTs)
    
    // Verify timestamp is derived from ds (should be start of day + 1 day in milliseconds)
    timestamp should be > 0L
    timestamp should be >= 1704067200000L // 2024-01-01 00:00:00 UTC in milliseconds
  }

  it should "throw error when required columns are missing" in {
    val testData = Seq(
      Row("value1", 1000L)
    )
    
    val baseDf = spark.createDataFrame(
      spark.sparkContext.parallelize(testData),
      StructType(Seq(
        StructField("other_column", StringType),
        StructField("ts", LongType)
      ))
    )

    // Test the actual transformDataFrameForDynamoDB method with missing columns
    val exception = intercept[IllegalArgumentException] {
      Spark2DynamoLoader.transformDataFrameForDynamoDB(baseDf, "test_table")
    }
    
    // The error message should show the actual column names that were selected
    // Since the DataFrame doesn't have key_bytes, it falls back to keyBytes
    exception.getMessage should include("keyBytes")
    exception.getMessage should include("valueBytes")
    // And it should show the available columns
    exception.getMessage should include("other_column")
    exception.getMessage should include("Available columns:")
  }

  it should "throw error when both ts and ds columns are missing" in {
    val testData = Seq(
      Row(Array[Byte](1, 2, 3), Array[Byte](4, 5, 6))
    )
    
    val baseDf = spark.createDataFrame(
      spark.sparkContext.parallelize(testData),
      StructType(Seq(
        StructField(AWSOnlineConstants.sparkKeyColumn, BinaryType),
        StructField(AWSOnlineConstants.sparkValueColumn, BinaryType)
      ))
    )

    // Test the actual transformDataFrameForDynamoDB method with missing timestamp columns
    val exception = intercept[IllegalArgumentException] {
      Spark2DynamoLoader.transformDataFrameForDynamoDB(baseDf, "test_table")
    }
    
    exception.getMessage should include(AWSOnlineConstants.sparkTsColumn)
    exception.getMessage should include(AWSOnlineConstants.sparkDsColumn)
  }

  it should "write DataFrame to DynamoDB using writeDataFrameToDynamoDB" in {
    withTestClientFactory { clientFactory =>
      // Create test data
      val testData = Seq(
        Row(Array[Byte](1, 2, 3), Array[Byte](4, 5, 6), 1000L),
        Row(Array[Byte](7, 8, 9), Array[Byte](10, 11, 12), 2000L)
      )
      
      val baseDf = spark.createDataFrame(
        spark.sparkContext.parallelize(testData),
        StructType(Seq(
          StructField(AWSOnlineConstants.sparkKeyColumn, BinaryType),
          StructField(AWSOnlineConstants.sparkValueColumn, BinaryType),
          StructField(AWSOnlineConstants.sparkTsColumn, LongType)
        ))
      )

      // Transform DataFrame
      val transformedDf = Spark2DynamoLoader.transformDataFrameForDynamoDB(baseDf, "test_table")
      
      // Create DynamoDB table first
      val dataset = "TEST_TABLE_BATCH"
      val tableName = "chronon_TEST_TABLE_BATCH"
      DynamoDBTableHelper.createTableIfNotExists(dynamoClient, dataset)
      
      // Verify table exists
      val tables = dynamoClient.listTables().tableNames()
      tables.contains(tableName) shouldBe true
      
      // Write to DynamoDB - using our test client factory
      Spark2DynamoLoader.writeDataFrameToDynamoDB(transformedDf, tableName, clientFactory)
      
      // Verify data was written by reading it back with DynamoDBKVStoreImpl
      val kvStore = new DynamoDBKVStoreImpl(dynamoClient, scheduler)(executionContext)
      
      val key1Bytes = Array[Byte](1, 2, 3)
      val key2Bytes = Array[Byte](7, 8, 9)
      val getReq1 = ai.chronon.online.KVStore.GetRequest(key1Bytes, dataset)
      val getReq2 = ai.chronon.online.KVStore.GetRequest(key2Bytes, dataset)

      val getResult = Await.result(kvStore.multiGet(Seq(getReq1, getReq2)), 10.seconds)
      
      getResult.length shouldBe 2
      
      // Validate first row
      val res1 = getResult.find(_.request.keyBytes.sameElements(key1Bytes)).get
      res1.values.isSuccess shouldBe true
      res1.values.get.head.bytes shouldBe Array[Byte](4, 5, 6)
      res1.values.get.head.millis shouldBe 1000L
      
      // Validate second row
      val res2 = getResult.find(_.request.keyBytes.sameElements(key2Bytes)).get
      res2.values.isSuccess shouldBe true
      res2.values.get.head.bytes shouldBe Array[Byte](10, 11, 12)
      res2.values.get.head.millis shouldBe 2000L
    }
  }

  it should "throw error when keyBytes is null or empty in writeDataFrameToDynamoDB" in {
    withTestClientFactory { clientFactory =>
      // Create test data with null key
      val testDataWithNullKey = Seq(
        Row(null, Array[Byte](4, 5, 6), 1000L)
      )
      
      val dfWithNullKey = spark.createDataFrame(
        spark.sparkContext.parallelize(testDataWithNullKey),
        StructType(Seq(
          StructField(AWSOnlineConstants.sparkKeyColumn, BinaryType, nullable = true),
          StructField(AWSOnlineConstants.sparkValueColumn, BinaryType),
          StructField(AWSOnlineConstants.sparkTsColumn, LongType)
        ))
      )

      val transformedDfWithNullKey = Spark2DynamoLoader.transformDataFrameForDynamoDB(dfWithNullKey, "test_table")
      
      // Create DynamoDB table
      val dataset = "TEST_WRITE_NULL_KEY"
      val tableName = "chronon_TEST_WRITE_NULL_KEY"
      DynamoDBTableHelper.createTableIfNotExists(dynamoClient, dataset)
      
      // Attempting to write should throw an exception (wrapped in SparkException)
      val exception1 = intercept[org.apache.spark.SparkException] {
        Spark2DynamoLoader.writeDataFrameToDynamoDB(transformedDfWithNullKey, tableName, clientFactory)
      }
      exception1.getCause.getMessage should include("keyBytes cannot be null or empty")
      
      // Create test data with empty key
      val testDataWithEmptyKey = Seq(
        Row(Array.empty[Byte], Array[Byte](4, 5, 6), 1000L)
      )
      
      val dfWithEmptyKey = spark.createDataFrame(
        spark.sparkContext.parallelize(testDataWithEmptyKey),
        StructType(Seq(
          StructField(AWSOnlineConstants.sparkKeyColumn, BinaryType),
          StructField(AWSOnlineConstants.sparkValueColumn, BinaryType),
          StructField(AWSOnlineConstants.sparkTsColumn, LongType)
        ))
      )

      val transformedDfWithEmptyKey = Spark2DynamoLoader.transformDataFrameForDynamoDB(dfWithEmptyKey, "test_table")
      
      // Attempting to write should throw an exception (wrapped in SparkException)
      val exception2 = intercept[org.apache.spark.SparkException] {
        Spark2DynamoLoader.writeDataFrameToDynamoDB(transformedDfWithEmptyKey, tableName, clientFactory)
      }
      exception2.getCause.getMessage should include("keyBytes cannot be null or empty")
    }
  }

  it should "write DataFrame with more rows than batch size (multiple batches)" in {
    withTestClientFactory { clientFactory =>
      // Create test data with more than 25 rows (batch limit) to test multiple batches
      // Using 50 rows to ensure at least 2 batches are written
      val numRows = 50
      val testData = (0 until numRows).map { i =>
        val keyBytes = Array[Byte](i.toByte, (i * 2).toByte, (i * 3).toByte)
        val valueBytes = Array[Byte]((i * 4).toByte, (i * 5).toByte, (i * 6).toByte)
        val timestamp = 1000L + i
        Row(keyBytes, valueBytes, timestamp)
      }
      
      val baseDf = spark.createDataFrame(
        spark.sparkContext.parallelize(testData),
        StructType(Seq(
          StructField(AWSOnlineConstants.sparkKeyColumn, BinaryType),
          StructField(AWSOnlineConstants.sparkValueColumn, BinaryType),
          StructField(AWSOnlineConstants.sparkTsColumn, LongType)
        ))
      )

      // Transform DataFrame
      val transformedDf = Spark2DynamoLoader.transformDataFrameForDynamoDB(baseDf, "test_table")
      
      // Create DynamoDB table first
      val dataset = "TEST_TABLE_BATCH"
      val tableName = "chronon_TEST_TABLE_BATCH"
      DynamoDBTableHelper.createTableIfNotExists(dynamoClient, dataset)
      
      // Write to DynamoDB - using our test client factory
      Spark2DynamoLoader.writeDataFrameToDynamoDB(transformedDf, tableName, clientFactory)
      
      // Verify all rows were written by reading them back with DynamoDBKVStoreImpl
      val kvStore = new DynamoDBKVStoreImpl(dynamoClient, scheduler)(executionContext)

      val allGetRequests = (0 until numRows).map { i =>
        val keyBytes = Array[Byte](i.toByte, (i * 2).toByte, (i * 3).toByte)
        ai.chronon.online.KVStore.GetRequest(keyBytes, dataset)
      }

      val getResult = Await.result(kvStore.multiGet(allGetRequests), 20.seconds)
      getResult.length shouldBe numRows

      // Build a map for efficient lookup
      val resultsMap = getResult.map { res =>
        SdkBytes.fromByteArray(res.request.keyBytes) -> res.values.get.head
      }.toMap

      // Verify each row's content
      (0 until numRows).foreach { i =>
        val expectedKeyBytes = Array[Byte](i.toByte, (i * 2).toByte, (i * 3).toByte)
        val expectedValueBytes = Array[Byte]((i * 4).toByte, (i * 5).toByte, (i * 6).toByte)
        val expectedTimestamp = 1000L + i

        val timedValue = resultsMap(SdkBytes.fromByteArray(expectedKeyBytes))
        timedValue.bytes shouldBe expectedValueBytes
        timedValue.millis shouldBe expectedTimestamp
      }
    }
  }
}
