# Deploy AWS — stack Terraform

Topologia física da stack (`terraform/`): região única, VPC com 2 AZs e
subnets públicas (sem NAT — custo mínimo), ECS Fargate, ALB, DynamoDB,
Lambda, EventBridge, SQS e CloudWatch.

```mermaid
flowchart TB
  user(["👤 Cliente / Estabelecimento"])

  subgraph region["AWS Region (var.region — default us-east-1)"]
    subgraph vpc["VPC finance-platform — 10.0.0.0/16"]
      subgraph az1["AZ us-east-1a — subnet pública 10.0.0.0/24"]
        alb["🌐 ALB finance-platform-alb<br/>listener HTTP:80<br/>TG /health:3000 (ip)"]
        subgraph ecs1["ECS Fargate — cluster finance-platform"]
          authz["🟢 authorization-service<br/>0.25 vCPU / 512MB<br/>SG: ingress 3000 do ALB"]
          acct["🔵 accounting-consumer<br/>0.25 vCPU / 512MB<br/>SG consumers (sem ingress)"]
          fraud["🟣 fraud-consumer<br/>0.25 vCPU / 512MB"]
          notif["🟠 notification-consumer<br/>0.25 vCPU / 512MB"]
        end
      end
      az2["AZ us-east-1b — subnet pública 10.0.1.0/24<br/>(réplicas das tasks p/ HA)"]
    end

    igw["Internet Gateway<br/>(sem NAT/VPC endpoints — tasks com IP público)"]

    subgraph data["Dados & Eventos (managed, region-wide)"]
      ddb[("🗄 DynamoDB<br/>finance-platform-authorization<br/>PK/SK + gsi-auth + TTL + Streams NEW_IMAGE")]
      ckpt[("🗄 …-authorization-checkpoint")]
      entries[("🗄 …-accounting-entries")]
      idem[("🗄 …-consumer-idempotency (TTL)")]
      relay["⚡ Lambda outbox-relay<br/>Node 22, 128MB<br/>event source mapping (Streams, LATEST)"]
      bus["📡 EventBridge bus<br/>finance-platform-events<br/>regra transacao-autorizada-fanout"]
      subgraph sqs["SQS (3 filas + 3 DLQs, redrive=5)"]
        qa["accounting-queue"]:::q
        qf["fraud-queue"]:::q
        qn["notification-queue"]:::q
        dqa["accounting-queue-dlq"]:::dlq
        dqf["fraud-queue-dlq"]:::dlq
        dqn["notification-queue-dlq"]:::dlq
      end
    end

    subgraph obs["Observabilidade"]
      cw["📊 CloudWatch<br/>4 log groups /ecs/* + /aws/lambda/*<br/>retenção 7 dias"]
      alarms["🚨 Alarmes → SNS finance-platform-alarms<br/>DLQ depth>0 (×3) · ALB 5xx>0"]
    end

    ghcr[("🐙 GHCR<br/>ghcr.io/whoo-internet-co/*<br/>(secret opcional p/ repo privado)")]
  end

  user -->|"HTTP:80 POST /v1/contratos/{id}/autorizacoes<br/>+ Idempotency-Key"| alb
  alb --> authz
  authz <-->|"TransactWriteItems<br/>(limite+auth+idempotency+outbox)"| ddb
  ddb -->|Streams INSERT| relay
  relay -->|PutEvents| bus
  bus --> qa & qf & qn
  qa --> acct
  qf --> fraud
  qn --> notif
  qa -.->|maxReceive=5| dqa
  qf -.->|maxReceive=5| dqf
  qn -.->|maxReceive=5| dqn
  acct --> entries
  acct --> idem
  authz -.-> ckpt
  ghcr -.->|"pull (execution role)"| ecs1
  ecs1 --> igw --> user
  cw --- alarms

  classDef q fill:#e8f4ff,stroke:#4a90d9
  classDef dlq fill:#ffe8e8,stroke:#d94a4a
```

## Mapeamento arquivo → recursos

| Arquivo Terraform   | Recursos no diagrama                                       |
| ------------------- | ----------------------------------------------------------- |
| `network.tf`        | VPC, IGW, subnets, route table, SGs (alb/auth/consumers)    |
| `alb.tf`            | ALB, target group `/health:3000`, listener HTTP:80          |
| `ecs.tf`            | cluster, 4 task defs, 4 services, circuit breaker+rollback  |
| `dynamodb.tf`       | 4 tabelas (single-table, checkpoint, entries, idempotency)  |
| `lambda.tf`         | Lambda relay + event source mapping + log group             |
| `eventbridge.tf`    | bus custom + regra de fan-out + 3 targets                   |
| `sqs.tf`            | 3 filas + 3 DLQs + redrive + queue policies                 |
| `iam.tf`            | execution role, task roles, relay role (least privilege)    |
| `cloudwatch.tf`     | log groups ECS, alarmes DLQ/5xx, SNS topic                  |
| `outputs.tf`        | ALB DNS, filas, tabelas, bus, topic                         |

**Custo mínimo**: sem NAT (~US$ 32/mês evitados por AZ), sem VPC endpoints,
Container Insights desligado, Fargate 0.25/512 com desired_count=1, PAY_PER_REQUEST,
retenção de logs 7 dias. Único custo fixo relevante: ALB (~US$ 16/mês) —
para demo, `terraform apply` → usar → `terraform destroy`.
