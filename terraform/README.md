# Terraform — Finance Platform (meta-repo de entrega)

Stack AWS **representativa e implantável** com custo mínimo (free-tier friendly):
VPC sem NAT, Fargate 0.25 vCPU/512 MB, DynamoDB PAY_PER_REQUEST, Lambda 128 MB,
log groups com retenção de 7 dias.

## Arquitetura provisionada

```
Internet ──HTTP:80──> ALB ──/health, /v1/...──> ECS Fargate: authorization-service
                                                      │ TransactWriteItems
                                                      ▼
                                     DynamoDB single-table (PK/SK, gsi-auth,
                                     TTL `ttl`, Streams NEW_IMAGE)
                                                      │ DynamoDB Streams (INSERT OUTBOX#*)
                                                      ▼
                                     Lambda outbox-relay (Node 22)
                                                      │ PutEvents (event_id preservado)
                                                      ▼
                                     EventBridge custom bus ──regra TransacaoAutorizada──┐
                                                                                          │ fan-out
                       ┌──────────────────────────┬──────────────────────────┬────────────┘
                       ▼                          ▼                          ▼
              SQS accounting-queue       SQS fraud-queue          SQS notification-queue
              (+ DLQ, alarme)            (+ DLQ, alarme)          (+ DLQ, alarme)
                       ▼                          ▼                          ▼
              accounting-consumer        fraud-consumer           notification-consumer
              (ECS Fargate, dedup        (ECS Fargate,            (ECS Fargate,
              DynamoDB por event_id)     idempotente)             idempotente)
```

Arquivos:

| Arquivo            | Conteúdo                                                             |
| ------------------ | -------------------------------------------------------------------- |
| `main.tf`          | provider, versão, backend S3 opcional (comentado)                     |
| `variables.tf`     | todas as variáveis (imagens GHCR, sizing, SQS, nomes de tabela etc.)  |
| `network.tf`       | VPC 10.0.0.0/16, 2 AZs, subnets públicas, SGs (ALB/auth/consumers)    |
| `alb.tf`           | ALB + target group (health `/health` porta 3000) + listener HTTP:80   |
| `ecs.tf`           | cluster + 4 task definitions + 4 services (Fargate)                   |
| `dynamodb.tf`      | single-table do authorization + checkpoint + accounting + idempotency |
| `sqs.tf`           | 3 filas de consumo + 3 DLQs + redrive + queue policies (EventBridge)  |
| `eventbridge.tf`   | custom bus + regra de fan-out `TransacaoAutorizada` → 3 filas         |
| `lambda.tf`        | Lambda relay do outbox (Streams → EventBridge) + event source mapping |
| `iam.tf`           | roles least-privilege (execution, task auth, task consumers, relay)   |
| `cloudwatch.tf`    | 4 log groups ECS + alarmes DLQ depth>0 (×3) + ALB 5xx + SNS topic     |
| `outputs.tf`       | endpoints/ARNs/nomes úteis pós-apply                                  |

## Decisão: ALB direto, SEM API Gateway

O Authorization Service é exposto por um **Application Load Balancer direto**
(listener HTTP:80 → target group com health check `/health`). Justificativa:

1. **Menor superfície** — a API tem um único serviço backend; não há
   roteamento multi-serviço, throttling por rota, nem transformação de
   payload que justifiquem um gateway.
2. **Custo** — o ALB já é necessário para health check e balanceamento das
   tasks Fargate; uma HTTP API adicionaria custo por request sem benefício
   no escopo congelado (sem Cognito real — autenticação está fora de escopo).
3. **Contrato** — o OpenAPI (`openapi/authorization/v1`) define erros RFC 7807
   no próprio serviço; não há necessidade de mapping/autorização no gateway.
4. **Evolução** — se autenticação gerenciada for necessária no futuro, um
   Lambda Authorizer + HTTP API pode ser adicionado *na frente* do ALB sem
   alterar o serviço (o contrato não muda).

HTTPS (listener 443) exige certificado ACM — fora do escopo free-tier desta
entrega; documentado em `alb.tf`.

## Convenções assumidas vs. reais (reconciliação)

Os serviços `authorization-service` e `accounting-consumer` estão sendo
finalizados **em paralelo** em seus próprios repositórios. Estado lido durante
a construção desta stack (24/set) e divergências a reconciliar:

### Alinhado (lido do código real)

| Item                            | Fonte real                                                        | Stack                                                                 |
| ------------------------------- | ----------------------------------------------------------------- | --------------------------------------------------------------------- |
| Single-table PK/SK + `gsi-auth` | `authorization-service/src/adapters/outbound/dynamodb/DynamoDbTable.ts` | `dynamodb.tf`: PK/SK, GSI `gsi-auth` (gsi1_pk/gsi1_sk), TTL `ttl`, Streams `NEW_IMAGE` |
| Portas/health do authorization  | `.env.example` (`PORT=3000`) + OpenAPI                            | ALB target group `/health` porta 3000; `var.authorization_port`        |
| Envs dos consumers              | `fraud-consumer/.env.example`, `notification-consumer/.env.example` | task defs injetam `SQS_QUEUE_URL`, `AWS_REGION`, `SQS_WAIT_TIME_SECONDS`, `SQS_VISIBILITY_TIMEOUT`, `SQS_MAX_NUMBER_OF_MESSAGES`, `SERVICE_NAME` |
| Parser flat **ou** envelope     | `SqsMessageBodyParser` (aceita `detail` do EventBridge)           | EventBridge → SQS entrega envelope padrão com `detail` — compatível    |
| Outbox relay                    | ADR-006 autoriza adapter equivalente                              | Lambda Streams→EventBridge preserva `event_id` (fonte: `lambda/outbox-relay/index.js`) |

### Divergências assumidas (revisar na integração final)

1. **Nomes de tabela**: o `.env.example` do authorization-service usa defaults
   `DYNAMODB_TABLE=authorization-service` e
   `DYNAMODB_CHECKPOINT_TABLE=authorization-service-checkpoint`. A stack usa o
   prefixo da plataforma (`finance-platform-authorization`,
   `finance-platform-authorization-checkpoint`) e **injeta as envs via task
   definition**, sobrescrevendo os defaults. Se o serviço ignorar as envs,
   alinhar os `var.*_table_name` aos nomes do serviço.
2. **`EVENT_SOURCE`**: o `.env.example` do serviço tem default
   `authorization-service`; a stack/relay/regra usam
   `co.whoo-internet.finance.authorization` (convenção de domínios do
   CloudEvents mapping). O relay Lambda define o source por env própria e a
   task def do serviço também injeta o valor da stack — mas se o serviço
   publicar por conta própria (`RELAY_PUBLISHER=eventbridge`) com default
   diferente, a regra de fan-out não casará. **Na stack AWS o relay é a
   Lambda**; o publisher in-process do serviço deve permanecer desativado.
3. **Tabela de checkpoint**: na stack, o checkpoint do stream é gerenciado
   pelo event source mapping da Lambda — a tabela
   `finance-platform-authorization-checkpoint` é mantida para compatibilidade
   com o relay in-process do serviço (usado no docker-compose local).
4. **Idempotência dos consumers**: `fraud-consumer` e `notification-consumer`
   usam hoje `InMemoryIdempotencyRepository` (dedup perdida em restart —
   aceitável para demo com `desired_count=1`; ADR-007 prevê dedup durável).
   O `accounting-consumer` (em desenvolvimento) assumirá
   `IDEMPOTENCY_BACKEND=dynamodb` +
   `IDEMPOTENCY_TABLE=finance-platform-consumer-idempotency` — já provisionado
   e permitido nos task roles (todos os consumers têm acesso à tabela de
   idempotência, forward-compatible).
5. **Schema da tabela `finance-platform-accounting-entries`**: hash key
   `event_id` (assumido — ledger idempotente por evento). O repositório do
   accounting-consumer ainda estava vazio no momento desta stack; se o schema
   real divergir (ex.: GSIs por conta/período), ajustar `dynamodb.tf` e o IAM.
6. **Targets da regra EventBridge**: a especificação pedia a fila
   `finance-platform-accounting-queue` como "4º target"; no baseline ela **já
   era target** da regra. Estado final consistente: **3 targets**
   (accounting, fraud, notification), cada fila com sua DLQ (maxReceiveCount
   `var.sqs_max_receive_count`=5) e alarme de depth>0.
7. **HTTP inbound do authorization-service**: o repositório do serviço ainda
   não expunha o adapter HTTP (NestJS) no momento desta stack; ALB/task def
   assumem `GET /health` → 200 na porta 3000 (contrato OpenAPI v1:
   `POST /v1/contratos/{id_contrato}/autorizacoes`). Confirmar na integração.

## Como validar

```bash
cd terraform
terraform fmt -check
terraform init -backend=false
terraform validate
```

> Status da validação (24/set, terraform 1.5.7): `fmt -check` OK,
> `init -backend=false` OK, `validate` **Success**.
> `aws sts get-caller-identity` **falhou** — `~/.aws/credentials` não possui
> profile `[default]` (somente profiles nomeados: `paulopatto-student`,
> `paulopatto`, `voa`, `localstack`, `T10`, `neofin-*`). Para implantar,
> exporte `AWS_PROFILE=<profile>` (ou crie um `[default]`) e rode
> `aws sts get-caller-identity` antes do `terraform apply`.

## Como implantar

```bash
cd terraform

# 1. Credenciais — sem [default] em ~/.aws/credentials, escolha o profile:
export AWS_PROFILE=<seu-profile>
aws sts get-caller-identity

# 2. (Opcional) GHCR privado — crie o secret e informe o ARN:
#    formato: {"username":"<user>","password":"<PAT read:packages>"}
aws secretsmanager create-secret --name ghcr-credentials \
  --secret-string '{"username":"...","password":"..."}'
# export TF_VAR_repository_credentials_secret_arn=arn:aws:secretsmanager:...

# 3. (Opcional) backend remoto — ver bloco comentado em main.tf

# 4. Deploy
terraform init
terraform plan  -var="environment=dev"
terraform apply -var="environment=dev"

# 5. Testar
curl -s "http://$(terraform output -raw alb_dns_name)/health"

# 6. Assinar alarmes por e-mail
aws sns subscribe --topic-arn "$(terraform output -raw alarms_topic_arn)" \
  --protocol email --notification-endpoint voce@exemplo.com

# Teardown
terraform destroy
```

> Imagens: as task definitions apontam para
> `ghcr.io/whoo-internet-co/{authorization-service,accounting-consumer,fraud-consumer,notification-consumer}`
> com tag variável (`var.*_image`, default `:latest`). Pin a tag imutável em
> produção. Para imagens novas, force nova deployment com
> `aws ecs update-service --force-new-deployment` (tag `:latest` não dispara
> novo pull por si só).

## Custos (estimativa free-tier)

- **ALB**: ~US$ 16/mês (não há free tier para ALB) — maior custo da stack;
  para demo pontual, aplicar/destruir sob demanda.
- **Fargate**: 4 tasks 0.25 vCPU/512 MB ≈ US$ 9/mês se 24/7.
- **DynamoDB** PAY_PER_REQUEST, **SQS**, **EventBridge** (custom bus),
  **Lambda** relay: dentro do free tier para volume de demo.
- **CloudWatch**: logs com retenção 7 dias + 4 alarmes: alguns centavos.
