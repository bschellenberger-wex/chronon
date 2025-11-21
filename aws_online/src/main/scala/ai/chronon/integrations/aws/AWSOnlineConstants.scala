package ai.chronon.integrations.aws

import ai.chronon.api.{Constants => ApiConstants}
import java.util.concurrent.TimeUnit

/**
 * Constants for AWS/DynamoDB online implementation.
 *
 * This consolidates all magic values used across the aws_online module,
 * following the pattern from the MongoDB quickstart implementation.
 */
object AWSOnlineConstants {

  // ============================================================================
  // DynamoDB Table Configuration
  // ============================================================================

  /** DynamoDB table prefix for KVStore tables */
  val DynamoDBTablePrefix: String = "chronon_"

  // ============================================================================
  // Table Column Names (DynamoDB attribute names)
  // ============================================================================

  /** Partition key column name in DynamoDB tables */
  val dynamoTableKey = "keyBytes"

  /** Value column name in DynamoDB tables */
  val dynamoTableValue = "valueBytes"

  /** Timestamp/sort key column name in DynamoDB tables */
  val dynamoTableTs: String = "ts"

  // ============================================================================
  // Spark Table Column Names (input format - snake_case)
  // ============================================================================

  /** Key column name in Spark tables (snake_case variant) */
  val sparkKeyColumn = "key_bytes"

  /** Value column name in Spark tables (snake_case variant) */
  val sparkValueColumn = "value_bytes"

  /** Timestamp column name in Spark tables */
  val sparkTsColumn = ApiConstants.TimeColumn // "ts"

  /** Date partition column name in Spark tables */
  val sparkDsColumn = "ds"

  /** Upload span: 1 day in milliseconds, used when deriving timestamp from ds column */
  val uploadSpanInMillis: Long = TimeUnit.DAYS.toMillis(1)
}

