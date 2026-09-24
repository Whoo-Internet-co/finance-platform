# ---------------------------------------------------------------------------
# EventBridge — custom event bus + regra de fan-out do TransacaoAutorizada
# para as 3 filas SQS (ADR-005).
#
# Fluxo: Authorization Service -> TransactWriteItems (inclui outbox)
#        -> DynamoDB Streams -> Lambda relay -> EventBridge
#        -> regra TransacaoAutorizada -> 3 SQS (Accounting/Fraud/Notification).
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_bus" "finance" {
  name = "${var.project_name}-events"
}

resource "aws_cloudwatch_event_rule" "transacao_autorizada" {
  name           = "${var.project_name}-transacao-autorizada-fanout"
  description    = "Roteia TransacaoAutorizada para as filas SQS dos consumers"
  event_bus_name = aws_cloudwatch_event_bus.finance.name

  event_pattern = jsonencode({
    source      = [var.event_source_prefix]
    detail-type = [var.event_detail_type]
  })
}

# --- Targets: Accounting / Fraud / Notification -----------------------------
# Sem Input Transformer: o EventBridge entrega o envelope padrão (o consumer
# extrai o payload de negócio do campo `detail`).

resource "aws_cloudwatch_event_target" "accounting" {
  rule           = aws_cloudwatch_event_rule.transacao_autorizada.name
  event_bus_name = aws_cloudwatch_event_bus.finance.name
  arn            = aws_sqs_queue.accounting.arn
}

resource "aws_cloudwatch_event_target" "fraud" {
  rule           = aws_cloudwatch_event_rule.transacao_autorizada.name
  event_bus_name = aws_cloudwatch_event_bus.finance.name
  arn            = aws_sqs_queue.fraud.arn
}

resource "aws_cloudwatch_event_target" "notification" {
  rule           = aws_cloudwatch_event_rule.transacao_autorizada.name
  event_bus_name = aws_cloudwatch_event_bus.finance.name
  arn            = aws_sqs_queue.notification.arn
}