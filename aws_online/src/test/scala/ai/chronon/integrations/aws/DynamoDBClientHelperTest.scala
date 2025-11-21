package ai.chronon.integrations.aws

import org.scalatest.flatspec.AnyFlatSpec
import org.scalatest.matchers.should.Matchers
import software.amazon.awssdk.services.dynamodb.DynamoDbClient

class DynamoDBClientHelperTest extends AnyFlatSpec with Matchers {

  "DynamoDBClientHelper" should "create a basic DynamoDB client" in {
    System.setProperty("aws.region", "us-east-1")
    try {
      val client = DynamoDBClientHelper.createClient()
      client shouldBe a [DynamoDbClient]
      client.close()
    } finally {
      System.clearProperty("aws.region")
    }
  }
}
