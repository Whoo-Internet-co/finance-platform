# ---------------------------------------------------------------------------
# Lambda relay de outbox — DynamoDB Streams (tabela de outbox) -> EventBridge.
# ADR-006: a publicação é retryable e at-least-once; consumers deduplicam.
# ---------------------------------------------------------------------------

data "archive_file" "outbox_relay" {
  type        = "zip"
  source_file = "${path.module}/lambda/outbox-relay/index.js"
  output_path = "${path.module}/lambda/outbox-relay/index.zip"
}

resource "aws_lambda_function" "outbox_relay" {
  function_name    = "${var.project_name}-outbox-relay"
  description      = "Relay do Transactional Outbox: DynamoDB Streams -> EventBridge (ADR-006)"
  role             = aws_iam_role.outbox_relay.arn
  runtime          = var.lambda_runtime
  handler          = "index.handler"
  filename         = data.archive_file.outbox_relay.output_path
  source_code_hash = data.archive_file.outbox_relay.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      EVENT_BUS_NAME     = aws_cloudwatch_event_bus.finance.name
      EVENT_SOURCE       = var.event_source_prefix
      EVENT_DETAIL_TYPE  = var.event_detail_type
      AWS_REGION         = var.region
    }
  }

  tags = { Name = "${var.project_name}-outbox-relay" }
}

# Dispara a Lambda em todo INSERT na tabela de outbox (a partir de agora).
resource "aws_lambda_event_source_mapping" "outbox_stream" {
  event_source_arn  = aws_dynamodb_table.outbox.stream_arn
  function_name     = aws_lambda_function.outbox_relay.arn
  starting_position = "LATEST"
  batch_size        = 10
  maximum_retry_attempts        = 10
  maximum_record_age_in_seconds = 300
  bisect_batch_on_function_error = false
}

# Log group da Lambda (streams habilitado pela IAM).
resource "aws_cloudwatch_log_group" "outbox_relay" {
  name              = "/aws/lambda/${var.project_name}-outbox-relay"
  retention_in_days = var.log_retention_days

  tags = { Name = "${var.project_name}-outbox-relay-logs" }
}