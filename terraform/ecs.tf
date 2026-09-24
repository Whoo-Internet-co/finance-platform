# ---------------------------------------------------------------------------
# ECS / Fargate — cluster + 4 task definitions + 4 services (ADR-002).
#
#   authorization-service -> atrás do ALB (health check /health, porta 3000)
#   accounting-consumer   -> SQS finance-platform-accounting-queue (sem ALB)
#   fraud-consumer        -> SQS finance-platform-fraud-queue (sem ALB)
#   notification-consumer -> SQS finance-platform-notification-queue (sem ALB)
#
# Custo mínimo: 0.25 vCPU / 0.5 GB por task, desired_count = 1, sem autoscaling
# (o ADR-002 prevê autoscaling para produção; aqui mantemos o mínimo free-tier).
#
# Imagens: GHCR (tag variável por serviço). Para GHCR privado, defina
# var.repository_credentials_secret_arn com o ARN de um secret no Secrets
# Manager no formato {"username":"...","password":"..."} (token PAT com
# read:packages). Com o valor vazio (default), as imagens são puxadas como
# públicas e nenhuma permissão extra é concedida ao execution role.
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "main" {
  name = var.project_name

  setting {
    name  = "containerInsights"
    value = "disabled" # custo mínimo; habilite ("enabled") para observabilidade extra
  }

  tags = { Name = var.project_name }
}

locals {
  # repositoryCredentials só é incluído na definição do container quando um
  # secret ARN é informado (GHCR privado).
  repository_credentials = var.repository_credentials_secret_arn != "" ? {
    credentialsParameter = var.repository_credentials_secret_arn
  } : null

  log_driver = "awslogs"

  services = {
    authorization = {
      image      = var.authorization_image
      task_role  = aws_iam_role.authorization_task.arn
      log_group  = "/ecs/${var.project_name}-authorization"
      port       = var.authorization_port
      behind_alb = true
      environment = {
        SERVICE_NAME              = "authorization-service"
        PORT                      = tostring(var.authorization_port)
        AWS_REGION                = var.region
        ADAPTER_MODE              = "dynamodb"
        DYNAMODB_TABLE            = aws_dynamodb_table.authorization.name
        DYNAMODB_CHECKPOINT_TABLE = aws_dynamodb_table.authorization_checkpoint.name
        IDEMPOTENCY_TTL_SECONDS   = "86400"
        CONTRACTS_SCHEMA_PATH     = "contracts-vendored/events/transacao-autorizada/v1/schema.json"
        EVENT_BUS_NAME            = aws_cloudwatch_event_bus.finance.name
        EVENT_SOURCE              = var.event_source_prefix
      }
    }

    accounting = {
      image      = var.accounting_image
      task_role  = aws_iam_role.consumer_task["accounting"].arn
      log_group  = "/ecs/${var.project_name}-accounting-consumer"
      port       = null
      behind_alb = false
      environment = {
        SERVICE_NAME               = "accounting-consumer"
        AWS_REGION                 = var.region
        SQS_QUEUE_URL              = aws_sqs_queue.accounting.id
        SQS_WAIT_TIME_SECONDS      = tostring(var.sqs_receive_wait_time)
        SQS_VISIBILITY_TIMEOUT     = tostring(var.sqs_visibility_timeout)
        SQS_MAX_NUMBER_OF_MESSAGES = "10"
        ACCOUNTING_ENTRIES_TABLE   = aws_dynamodb_table.accounting_entries.name
        LEDGER_BACKEND             = "dynamodb"
        IDEMPOTENCY_BACKEND        = "dynamodb"
        IDEMPOTENCY_TABLE          = aws_dynamodb_table.consumer_idempotency.name
      }
    }

    fraud = {
      image      = var.fraud_image
      task_role  = aws_iam_role.consumer_task["fraud"].arn
      log_group  = "/ecs/${var.project_name}-fraud-consumer"
      port       = null
      behind_alb = false
      environment = {
        SERVICE_NAME               = "fraud-consumer"
        AWS_REGION                 = var.region
        SQS_QUEUE_URL              = aws_sqs_queue.fraud.id
        SQS_WAIT_TIME_SECONDS      = tostring(var.sqs_receive_wait_time)
        SQS_VISIBILITY_TIMEOUT     = tostring(var.sqs_visibility_timeout)
        SQS_MAX_NUMBER_OF_MESSAGES = "10"
        FRAUD_MOCK_RESULT          = "APPROVED"
      }
    }

    notification = {
      image      = var.notification_image
      task_role  = aws_iam_role.consumer_task["notification"].arn
      log_group  = "/ecs/${var.project_name}-notification-consumer"
      port       = null
      behind_alb = false
      environment = {
        SERVICE_NAME               = "notification-consumer"
        AWS_REGION                 = var.region
        SQS_QUEUE_URL              = aws_sqs_queue.notification.id
        SQS_WAIT_TIME_SECONDS      = tostring(var.sqs_receive_wait_time)
        SQS_VISIBILITY_TIMEOUT     = tostring(var.sqs_visibility_timeout)
        SQS_MAX_NUMBER_OF_MESSAGES = "10"
      }
    }
  }
}

# --- Task definitions -------------------------------------------------------

resource "aws_ecs_task_definition" "service" {
  for_each = local.services

  family                   = "${var.project_name}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu    # 256 = 0.25 vCPU
  memory                   = var.task_memory # 512 MB
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = each.value.task_role
  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([
    merge(
      {
        name      = each.key
        image     = each.value.image
        essential = true
        environment = [
          for k, v in each.value.environment : { name = k, value = v }
        ]
        logConfiguration = {
          logDriver = local.log_driver
          options = {
            awslogs-group         = each.value.log_group
            awslogs-region        = var.region
            awslogs-stream-prefix = "ecs"
          }
        }
      },
      each.value.port != null ? {
        portMappings = [
          {
            containerPort = each.value.port
            protocol      = "tcp"
          }
        ]
      } : {},
      local.repository_credentials != null ? {
        repositoryCredentials = local.repository_credentials
      } : {}
    )
  ])

  tags = { Name = "${var.project_name}-${each.key}" }
}

# --- Services ---------------------------------------------------------------

resource "aws_ecs_service" "authorization" {
  name            = "${var.project_name}-authorization"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.service["authorization"].arn
  desired_count   = var.authorization_desired_count
  launch_type     = "FARGATE"

  # Grace period: o ALB só exige health check verde após a subida do container.
  health_check_grace_period_seconds = 90

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.authorization.id]
    assign_public_ip = true # sem NAT: pull de imagem + APIs AWS via internet
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.authorization.arn
    container_name   = "authorization"
    container_port   = var.authorization_port
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener.http]

  tags = { Name = "${var.project_name}-authorization" }
}

resource "aws_ecs_service" "consumer" {
  for_each = toset(["accounting", "fraud", "notification"])

  name            = "${var.project_name}-${each.value}-consumer"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.service[each.value].arn
  desired_count   = var.consumer_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.consumers.id]
    assign_public_ip = true
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  tags = { Name = "${var.project_name}-${each.value}-consumer" }
}

# --- GHCR privado (opcional) -------------------------------------------------
# Se var.repository_credentials_secret_arn for definido, o execution role
# precisa ler o secret para autenticar o pull da imagem.

resource "aws_iam_role_policy" "ecs_execution_repository_credentials" {
  count = var.repository_credentials_secret_arn != "" ? 1 : 0

  name = "${var.project_name}-ecs-execution-ghcr"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadGhcrCredentials"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [var.repository_credentials_secret_arn]
      }
    ]
  })
}
