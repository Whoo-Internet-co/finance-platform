# ---------------------------------------------------------------------------
# SQS — 3 filas de consumo + 3 DLQs (ADR-005/007).
# Redrive policy parametrizada (maxReceiveCount); consumers não fazem ACK em
# falha, então mensagens problemáticas vão à DLQ após N recebimentos.
# Queue policies permitem que o EventBridge envie mensagens (least privilege
# com aws:SourceArn = ARN da regra).
# ---------------------------------------------------------------------------

locals {
  consumer_queues = {
    accounting   = "accounting-queue"
    fraud        = "fraud-queue"
    notification = "notification-queue"
  }
}

resource "aws_sqs_queue" "accounting" {
  name                       = "${var.project_name}-${local.consumer_queues.accounting}"
  visibility_timeout_seconds = var.sqs_visibility_timeout
  receive_wait_time_seconds  = var.sqs_receive_wait_time
  message_retention_seconds  = 1209600 # 14 dias
}

resource "aws_sqs_queue" "accounting_dlq" {
  name                      = "${var.project_name}-${local.consumer_queues.accounting}-dlq"
  message_retention_seconds = 1209600 # 14 dias
}

resource "aws_sqs_queue_redrive_policy" "accounting" {
  queue_url = aws_sqs_queue.accounting.id
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.accounting_dlq.arn
    maxReceiveCount     = var.sqs_max_receive_count
  })
}

resource "aws_sqs_queue_policy" "accounting" {
  queue_url = aws_sqs_queue.accounting.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridge"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.accounting.arn
        Condition = {
          ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.transacao_autorizada.arn }
        }
      }
    ]
  })
}

resource "aws_sqs_queue" "fraud" {
  name                       = "${var.project_name}-${local.consumer_queues.fraud}"
  visibility_timeout_seconds = var.sqs_visibility_timeout
  receive_wait_time_seconds  = var.sqs_receive_wait_time
  message_retention_seconds  = 1209600
}

resource "aws_sqs_queue" "fraud_dlq" {
  name                      = "${var.project_name}-${local.consumer_queues.fraud}-dlq"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue_redrive_policy" "fraud" {
  queue_url = aws_sqs_queue.fraud.id
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.fraud_dlq.arn
    maxReceiveCount     = var.sqs_max_receive_count
  })
}

resource "aws_sqs_queue_policy" "fraud" {
  queue_url = aws_sqs_queue.fraud.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridge"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.fraud.arn
        Condition = {
          ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.transacao_autorizada.arn }
        }
      }
    ]
  })
}

resource "aws_sqs_queue" "notification" {
  name                       = "${var.project_name}-${local.consumer_queues.notification}"
  visibility_timeout_seconds = var.sqs_visibility_timeout
  receive_wait_time_seconds  = var.sqs_receive_wait_time
  message_retention_seconds  = 1209600
}

resource "aws_sqs_queue" "notification_dlq" {
  name                      = "${var.project_name}-${local.consumer_queues.notification}-dlq"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue_redrive_policy" "notification" {
  queue_url = aws_sqs_queue.notification.id
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.notification_dlq.arn
    maxReceiveCount     = var.sqs_max_receive_count
  })
}

resource "aws_sqs_queue_policy" "notification" {
  queue_url = aws_sqs_queue.notification.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridge"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.notification.arn
        Condition = {
          ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.transacao_autorizada.arn }
        }
      }
    ]
  })
}