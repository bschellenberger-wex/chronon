package ai.chronon.integrations.aws

import software.amazon.awssdk.services.dynamodb.DynamoDbClient

/**
 * Shared helper for creating DynamoDB clients.
 * 
 * Used by both ChrononAwsOnlineImpl and Spark2DynamoLoader to ensure
 * consistent client creation across the codebase.
 */
object DynamoDBClientHelper {
  
  /**
   * Creates a DynamoDB client with default configuration.
   * 
   * The client will use the default AWS credentials chain:
   * 1. Environment variables (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)
   * 2. Java system properties
   * 3. Web identity token from the environment
   * 4. Shared credentials file (~/.aws/credentials)
   * 5. Amazon ECS container credentials
   * 6. Amazon EC2 instance profile credentials
   * 
   * The client will use the default region from:
   * 1. AWS_DEFAULT_REGION or AWS_REGION environment variable
   * 2. aws.region system property
   * 3. Default region from AWS config file (~/.aws/config)
   * 
   * @return A configured DynamoDbClient instance
   */
  def createClient(): DynamoDbClient = {
    DynamoDbClient.builder().build()
  }
}

