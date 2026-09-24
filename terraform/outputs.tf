# ---------------------------------------------------------------------------
# Outputs — endpoints e identificadores da stack
# ---------------------------------------------------------------------------

output "alb_dns_name" {
  description = "DNS name do ALB — base URL da API (http://<dns>/v1/contratos/...)"
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "Zone ID do ALB (para alias de domínio customizado)"
  value       = aws_lb.main.zone_id
}

output "ecs_cluster_name" {
  description = "Nome do cluster ECS"
  value       = aws_ecs_cluster.main.name
}

output "event_bus_name" {
  description = "Custom event bus (relay de outbox publica aqui)"
  value       = aws_cloudwatch_event_bus.finance.name
}

output "event_bus_arn" {
  description = "ARN do custom event bus"
  value       = aws_cloudwatch_event_bus.finance.arn
}

output "sqs_queue_urls" {
  description = "URLs das filas de consumo (injetadas como SQS_QUEUE_URL nos consumers)"
  value = {
    accounting   = aws_sqs_queue.accounting.id
    fraud        = aws_sqs_queue.fraud.id
    notification = aws_sqs_queue.notification.id
  }
}

output "sqs_dlq_urls" {
  description = "URLs das DLQs (alarme de depth > 0 configurado)"
  value = {
    accounting   = aws_sqs_queue.accounting_dlq.id
    fraud        = aws_sqs_queue.fraud_dlq.id
    notification = aws_sqs_queue.notification_dlq.id
  }
}

output "dynamodb_table_names" {
  description = "Tabelas DynamoDB da plataforma"
  value = {
    authorization        = aws_dynamodb_table.authorization.name
    authorization_ckpt   = aws_dynamodb_table.authorization_checkpoint.name
    accounting_entries   = aws_dynamodb_table.accounting_entries.name
    consumer_idempotency = aws_dynamodb_table.consumer_idempotency.name
  }
}

output "outbox_relay_function_name" {
  description = "Lambda relay do Transactional Outbox (DynamoDB Streams -> EventBridge)"
  value       = aws_lambda_function.outbox_relay.function_name
}

output "alarms_topic_arn" {
  description = "SNS topic dos alarmes — assine com: aws sns subscribe --protocol email"
  value       = aws_sns_topic.alarms.arn
}
