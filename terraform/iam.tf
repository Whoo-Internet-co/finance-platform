# ---------------------------------------------------------------------------
# IAM — roles least-privilege.
#
# Roles:
#   ecs_execution    -> ECS agent (pull de imagem GHCR, logs CloudWatch)
#   authorization    -> DynamoDB single-table (TransactWriteItems: contrato +
#                       autorização + idempotência + outbox na mesma tabela)
#   accounting/fraud/notification -> SQS (Receive/Delete na própria fila) +
#                      DynamoDB (idempotência dos consumers; accounting: + ledger)
#   outbox_relay     -> DynamoDB Streams (single-table) + EventBridge PutEvents
# ---------------------------------------------------------------------------

# --- Trust policies ---------------------------------------------------------

data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# --- ECS execution role -----------------------------------------------------

resource "aws_iam_role" "ecs_execution" {
  name               = "${var.project_name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
}

# Política gerenciada padrão do ECS (pull de imagem + logs CloudWatch).
resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# --- Authorization Service task role ---------------------------------------

resource "aws_iam_role" "authorization_task" {
  name               = "${var.project_name}-authorization-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
}

data "aws_iam_policy_document" "authorization_task" {
  # Single-table REAL do authorization-service (DynamoDbTable.ts):
  # contratos, autorizações, idempotência e outbox convivem na mesma tabela
  # (PK/SK), consultados via TransactWriteItems + GSI gsi-auth.
  statement {
    sid    = "DynamoDBAuthorizationSingleTable"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:Query",
      "dynamodb:DeleteItem",
      "dynamodb:ConditionCheckItem",
      "dynamodb:TransactWriteItems",
      "dynamodb:BatchWriteItem",
    ]
    resources = [
      aws_dynamodb_table.authorization.arn,
      "${aws_dynamodb_table.authorization.arn}/index/*",
    ]
  }

  # Checkpoint do relay in-process do serviço (na stack AWS o relay é a Lambda;
  # mantido para compatibilidade — ver terraform/README.md divergência 3).
  statement {
    sid       = "DynamoDBRelayCheckpoint"
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.authorization_checkpoint.arn]
  }
}

resource "aws_iam_role_policy" "authorization_task" {
  name   = "${var.project_name}-authorization-task"
  role   = aws_iam_role.authorization_task.id
  policy = data.aws_iam_policy_document.authorization_task.json
}

# --- Consumer task roles (SQS na própria fila + idempotência) ----------------

locals {
  consumer_roles = {
    accounting   = { queue = aws_sqs_queue.accounting, dlq = aws_sqs_queue.accounting_dlq }
    fraud        = { queue = aws_sqs_queue.fraud, dlq = aws_sqs_queue.fraud_dlq }
    notification = { queue = aws_sqs_queue.notification, dlq = aws_sqs_queue.notification_dlq }
  }
}

resource "aws_iam_role" "consumer_task" {
  for_each = local.consumer_roles

  name               = "${var.project_name}-${each.key}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
}

data "aws_iam_policy_document" "consumer_task" {
  for_each = local.consumer_roles

  statement {
    sid    = "SqsReceiveDelete"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [each.value.queue.arn]
  }

  statement {
    sid       = "DynamoDbConsumerIdempotency"
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.consumer_idempotency.arn]
  }

  # Accounting: ledger finance-platform-accounting-entries
  # (IDEMPOTENCY_BACKEND=dynamodb — ver terraform/README.md divergências 4/5).
  dynamic "statement" {
    for_each = each.key == "accounting" ? [1] : []
    content {
      sid       = "DynamoDbAccountingEntries"
      effect    = "Allow"
      actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"]
      resources = [aws_dynamodb_table.accounting_entries.arn]
    }
  }
}

resource "aws_iam_role_policy" "consumer_task" {
  for_each = local.consumer_roles

  name   = "${var.project_name}-${each.key}-task"
  role   = aws_iam_role.consumer_task[each.key].id
  policy = data.aws_iam_policy_document.consumer_task[each.key].json
}

# --- Outbox Relay Lambda role -----------------------------------------------

resource "aws_iam_role" "outbox_relay" {
  name               = "${var.project_name}-outbox-relay"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "outbox_relay" {
  statement {
    sid    = "DynamoDbStreamsRead"
    effect = "Allow"
    actions = [
      "dynamodb:GetRecords",
      "dynamodb:GetShardIterator",
      "dynamodb:DescribeStream",
      "dynamodb:ListStreams",
    ]
    resources = [aws_dynamodb_table.authorization.stream_arn]
  }

  statement {
    sid       = "EventBridgePutEvents"
    effect    = "Allow"
    actions   = ["events:PutEvents"]
    resources = [aws_cloudwatch_event_bus.finance.arn]
  }

  statement {
    sid       = "CloudWatchLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "outbox_relay" {
  name   = "${var.project_name}-outbox-relay"
  role   = aws_iam_role.outbox_relay.id
  policy = data.aws_iam_policy_document.outbox_relay.json
}