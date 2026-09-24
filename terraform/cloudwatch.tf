# ---------------------------------------------------------------------------
# CloudWatch — observabilidade mínima e gratuita.
#
#   Log groups (retenção var.log_retention_days):
#     /ecs/finance-platform-authorization
#     /ecs/finance-platform-accounting-consumer
#     /ecs/finance-platform-fraud-consumer
#     /ecs/finance-platform-notification-consumer
#     (o log group da Lambda relay é criado em lambda.tf)
#
#   Alarmes (ação: SNS topic finance-platform-alarms):
#     DLQ depth > 0  x3 (accounting/fraud/notification) — qualquer mensagem
#                        em DLQ indica falha de processamento (ADR-007)
#     ALB 5xx > 0    x1 — erros do Authorization Service vistos pelo ALB
#
# Para receber e-mail:
#   aws sns subscribe --topic-arn <arn do topic> --protocol email \
#     --notification-endpoint voce@exemplo.com
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "alarms" {
  name = "${var.project_name}-alarms"

  tags = { Name = "${var.project_name}-alarms" }
}

locals {
  ecs_log_groups = {
    authorization = "/ecs/${var.project_name}-authorization"
    accounting    = "/ecs/${var.project_name}-accounting-consumer"
    fraud         = "/ecs/${var.project_name}-fraud-consumer"
    notification  = "/ecs/${var.project_name}-notification-consumer"
  }

  dlq_alarms = {
    accounting   = aws_sqs_queue.accounting_dlq
    fraud        = aws_sqs_queue.fraud_dlq
    notification = aws_sqs_queue.notification_dlq
  }
}

resource "aws_cloudwatch_log_group" "ecs" {
  for_each = local.ecs_log_groups

  name              = each.value
  retention_in_days = var.log_retention_days

  tags = { Name = each.value }
}

# --- DLQ depth > 0 -----------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "dlq_depth" {
  for_each = local.dlq_alarms

  alarm_name          = "${var.project_name}-${each.key}-dlq-depth"
  alarm_description   = "DLQ ${each.key} com mensagens — consumer falhou ao processar (maxReceiveCount atingido)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]

  dimensions = {
    QueueName = each.value.name
  }

  tags = { Name = "${var.project_name}-${each.key}-dlq-depth" }
}

# --- ALB 5xx ------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.project_name}-alb-5xx"
  alarm_description   = "ALB retornou 5xx — erro no Authorization Service ou target fora do ar"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }

  tags = { Name = "${var.project_name}-alb-5xx" }
}
