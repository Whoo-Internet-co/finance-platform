# Deployment — Finance Platform (AWS)

Guia de deploy da stack Terraform (`terraform/`): pré-requisitos, variáveis,
passo a passo, verificação, smoke test, teardown e custos. Topologia:
[`docs/diagrams/deployment-aws.md`](diagrams/deployment-aws.md); visão geral
da solução: [`docs/architecture.md`](architecture.md).

> **Regra de ouro**: stack de demo — **`terraform destroy` após a demo**.
> O maior custo contínuo é o ALB (~US$ 0,55/dia) + Fargate (~US$ 1,18/dia
> com 4 tasks 24/7). Ver [Custos](#7-custos-estimativa).

## 1. Pré-requisitos

| Ferramenta | Versão testada | Verificação |
| ---------- | -------------- | ----------- |
| AWS CLI | v2 | `aws --version` |
| Terraform | **1.5.x** (validado com 1.5.7) | `terraform version` |
| Docker | qualquer recente | `docker version` |
| GitHub CLI (opcional) | recente | `gh --version` |

Credenciais AWS — **atenção**: esta máquina não possui profile `[default]` em
`~/.aws/credentials`; escolha um profile nomeado:

```bash
export AWS_PROFILE=<seu-profile>        # ex.: paulopatto-student
aws sts get-caller-identity             # DEVE funcionar antes do apply
```

Permissões mínimas do profile: IAM (criar roles/policies), VPC, EC2 (ALB/SG),
ECS, ECR (apenas para leitura de imagens, se espelho), DynamoDB, SQS,
EventBridge, Lambda, CloudWatch Logs/Métricas/Alarmes, SNS, Secrets Manager
(apenas se usar GHCR privado), S3 (apenas se ativar backend remoto).

Docker/GHCR — para pular/buildar imagens localmente:

```bash
echo "$GHCR_PAT" | docker login ghcr.io -u <seu-user> --password-stdin
# ou: gh auth token | docker login ghcr.io -u <seu-user> --password-stdin
```

As task definitions puxam `ghcr.io/whoo-internet-co/{authorization-service,
accounting-consumer,fraud-consumer,notification-consumer}` — ver
[§8 Imagens GHCR privadas](#8-imagens-ghcr-privadas-ecr-vs-repository_credentials).

## 2. Variáveis do Terraform

Todas em [`terraform/variables.tf`](../terraform/variables.tf), com defaults
funcionais para demo. As que você pode querer sobrescrever:

| Variável | Default | Quando mudar |
| -------- | ------- | ------------ |
| `region` | `us-east-1` | região-alvo (ajuste também `availability_zones`) |
| `environment` | `dev` | tag dev/staging/prod |
| `project_name` | `finance-platform` | prefixo de todos os recursos (evita colisão de nomes) |
| `authorization_image`, `accounting_image`, `fraud_image`, `notification_image` | `ghcr.io/whoo-internet-co/*:latest` | **pin de tag imutável** em produção; ou URL ECR se espelhar |
| `repository_credentials_secret_arn` | `""` (imagens públicas) | ARN do secret com PAT se as imagens GHCR forem privadas (§8) |
| `authorization_desired_count` / `consumer_desired_count` | `1` / `1` | escala (HA mínima: `2`) |
| `task_cpu` / `task_memory` | `256` / `512` | sizing Fargate (0.25 vCPU/512 MB — mínimo da demo) |
| `sqs_max_receive_count` / `sqs_visibility_timeout` / `sqs_receive_wait_time` | `5` / `30` / `20` | política de retry/DLQ e long polling |
| `*_table_name` (4 tabelas) | `finance-platform-*` | convenção de nomes (single-table auth, checkpoint, accounting-entries, consumer-idempotency) |
| `dynamodb_billing_mode` | `PAY_PER_REQUEST` | on-demand (free-tier friendly) |
| `log_retention_days` | `7` | retenção CloudWatch Logs |
| `event_source_prefix` / `event_detail_type` | `co.whoo-internet.finance.authorization` / `TransacaoAutorizada` | contrato de eventos — **não mudar sem atualizar consumers/regra** |

Backend remoto (state no S3) está **comentado** em `terraform/main.tf` —
para uso em equipe, descomente e crie o bucket antes do `init`.

## 3. Deploy — passo a passo

```bash
cd terraform

# 0. Credenciais (obrigatório nesta máquina)
export AWS_PROFILE=<seu-profile>
aws sts get-caller-identity

# 1. (Opcional) GHCR privado — criar o secret do PAT (ver §8)
# 2. (Opcional) backend remoto — descomentar bloco em main.tf

# 3. Init / plan / apply
terraform init
terraform plan  -var="environment=dev" -out=tfplan
terraform apply tfplan        # ~5 min; confirme com "yes" se não usar -out

# 4. Anote os outputs
terraform output
```

Outputs úteis (`terraform/outputs.tf`): `alb_dns_name`, `ecs_cluster_name`,
`event_bus_name`, `sqs_queue_urls`, `sqs_dlq_urls`, `dynamodb_table_names`,
`outbox_relay_function_name`, `alarms_topic_arn`.

Assinar alarmes por e-mail (DLQ depth>0 ×3 e ALB 5xx):

```bash
aws sns subscribe --topic-arn "$(terraform output -raw alarms_topic_arn)" \
  --protocol email --notification-endpoint voce@exemplo.com
# confirme a inscrição no e-mail recebido
```

## 4. Verificação pós-deploy

```bash
export ALB_URL="http://$(terraform -chdir=terraform output -raw alb_dns_name)"

# 1. ALB ativo e target healthy (aguarde ~2-3 min após o apply)
aws elbv2 describe-target-health \
  --target-group-arn "$(aws elbv2 describe-target-groups \
      --names finance-platform-auth-tg --query 'TargetGroups[0].TargetGroupArn' --output text)"

# 2. Health check do serviço
curl -s "$ALB_URL/health"          # esperado: 200 {"status":"ok",...}

# 3. Containers no ar
aws ecs list-tasks --cluster finance-platform
```

Se o health não sobe: `aws logs tail /ecs/finance-platform-authorization --follow`
(causas comuns: imagem GHCR inacessível → §8; envs divergentes →
`terraform/README.md` "Divergências assumidas").

## 5. Smoke test (contrato completo)

Seed de um contrato/limite (mesmo shape do
[`docker-compose/scripts/seed-contract.sh`](../docker-compose/scripts/seed-contract.sh),
apontando para a AWS real):

```bash
aws dynamodb put-item --table-name finance-platform-authorization --item '{
  "PK":              {"S": "CONTRACT#CTR-SMOKE-001"},
  "SK":              {"S": "PROFILE#CTR-SMOKE-001"},
  "entity":          {"S": "CONTRATO"},
  "id_contrato":     {"S": "CTR-SMOKE-001"},
  "available_limit": {"N": "1000"},
  "total_limit":     {"N": "1000"},
  "moeda":           {"S": "BRL"},
  "ativo":           {"BOOL": true},
  "updated_at":      {"S": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}
}'

# Happy path → 201
KEY=$(uuidgen)
curl -si -X POST "$ALB_URL/v1/contratos/CTR-SMOKE-001/autorizacoes" \
  -H 'Content-Type: application/json' -H "Idempotency-Key: $KEY" \
  -d '{"id_conta":"ACC-001","valor":100.00,"moeda":"BRL","tipo_operacao":"DEBITO","id_estabelecimento":"EST-123"}'

# Replay da mesma chave → 200 (mesmo id_autorizacao)
curl -si -X POST "$ALB_URL/v1/contratos/CTR-SMOKE-001/autorizacoes" \
  -H 'Content-Type: application/json' -H "Idempotency-Key: $KEY" \
  -d '{"id_conta":"ACC-001","valor":100.00,"moeda":"BRL","tipo_operacao":"DEBITO","id_estabelecimento":"EST-123"}'

# Cadeia assíncrona: relay → EventBridge → filas → consumers
aws logs tail /aws/lambda/finance-platform-outbox-relay --since 5m   # "relayed"
aws sqs get-queue-attributes \
  --queue-url "$(terraform -chdir=terraform output -json sqs_queue_urls | jq -r .fraud)" \
  --attribute-names ApproximateNumberOfMessages                        # 0 = consumido
aws dynamodb scan --table-name finance-platform-accounting-entries \
  --query 'Count'                                                       # ledger ≥ 1
```

Roteiro completo de demo (402, 409, 422, concorrência, dedup, DLQ):
[`demo-script.md`](../demo-script.md) com `BASE_URL=$ALB_URL`.

## 6. Teardown

```bash
cd terraform
terraform destroy        # confirme com "yes"
terraform output         # deve voltar vazio
```

- **Destrua logo após a demo** — ALB e Fargate cobram por hora, não por uso.
- O destroy remove VPC/ECS/DynamoDB/SQS/EventBridge/Lambda/CloudWatch da
  stack. O bucket de backend remoto (se ativado) e o secret do GHCR (§8)
  **não** são gerenciados pela stack — remova manualmente se necessário.
- Log groups são destruídos junto (retenção 7 dias já limita custo residual).

## 7. Custos (estimativa)

Stack mínima de demo (us-east-1, preços on-demand set/2026, volume de demo
dentro do free tier onde aplicável):

| Item | Configuração | Custo aproximado |
| ---- | ------------ | ---------------- |
| ECS Fargate | 4 tasks 0.25 vCPU/512 MB, 24/7 | **~US$ 1,18/dia** (4 × US$ 0,0123/h) |
| ALB | 1 ALB + LCU mínimo | **~US$ 0,55/dia** (US$ 0,0225/h) |
| DynamoDB | PAY_PER_REQUEST ×4 tabelas | free tier / centavos |
| SQS + EventBridge + Lambda relay | volume de demo | free tier |
| CloudWatch | 4 log groups (7 dias) + 4 alarmes | centavos |

**Total: ~US$ 1,20–1,75/dia** rodando 24/7 (a estimativa usual de
**~US$ 1,20–1,50/dia** considera demos de algumas horas, sem 24/7 cheio).
Uma demo de 4 horas custa **menos de US$ 0,40**. Por isso: `apply` → demo →
`destroy` no mesmo dia.

> Divergência documentada: `terraform/README.md` cita "Fargate ≈ US$ 9/mês" —
> esse valor corresponde a **~1 task** 24/7; com as 4 tasks da stack o valor
> real é ~US$ 35/mês se deixada ligada. Reforça a regra do destroy.

## 8. Imagens GHCR privadas: ECR vs repository_credentials

As task definitions assumem imagens em `ghcr.io/whoo-internet-co/*`. Se os
packages forem **privados**, o ECS precisa autenticar o pull. Duas opções:

### Opção A — Espelho no ECR (recomendada para produção)

```bash
aws ecr create-repository --repository-name authorization-service
gh auth token | docker login ghcr.io -u <seu-user> --password-stdin
docker pull ghcr.io/whoo-internet-co/authorization-service:<tag>
docker tag  ghcr.io/whoo-internet-co/authorization-service:<tag> \
  <acct>.dkr.ecr.<region>.amazonaws.com/authorization-service:<tag>
aws ecr get-login-password | docker login --username AWS --password-stdin <acct>.dkr.ecr.<region>.amazonaws.com
docker push <acct>.dkr.ecr.<region>.amazonaws.com/authorization-service:<tag>
# repita para os 3 consumers e aponte as variáveis:
terraform apply \
  -var="authorization_image=<acct>.dkr.ecr.<region>.amazonaws.com/authorization-service:<tag>"
```

Prós: sem PAT rotacionável, pull via IAM nativo do execution role, registry na
mesma região (mais rápido). Contras: passo extra de espelhamento (pode ser
automatizado no CI).

### Opção B — `repository_credentials` com PAT (mais rápida para demo)

A stack já suporta: defina `var.repository_credentials_secret_arn` com o ARN
de um secret no Secrets Manager contendo
`{"username":"<user>","password":"<PAT read:packages>"}`.

```bash
aws secretsmanager create-secret --name ghcr-credentials \
  --secret-string '{"username":"<user>","password":"ghp_xxx"}'
terraform apply -var="repository_credentials_secret_arn=$(aws secretsmanager describe-secret --secret-id ghcr-credentials --query ARN --output text)"
```

O Terraform adiciona `repositoryCredentials` às task definitions e concede
`secretsmanager:GetSecretValue` ao execution role (recurso condicional em
`terraform/ecs.tf`). Prós: zero espelhamento. Contras: PAT é credencial de
longa duração (rotacione/revogue após a demo:
`aws secretsmanager delete-secret --secret-id ghcr-credentials --force-delete-without-recovery`).

> Com o valor default vazio, as imagens são tratadas como **públicas** e
> nenhuma permissão extra é concedida.

### Imagem nova não sobe?

Tag `:latest` **não** dispara novo pull automaticamente. Force:

```bash
aws ecs update-service --cluster finance-platform \
  --service finance-platform-authorization --force-new-deployment
```

Em produção, use tags imutáveis (SHA) nas variáveis `*_image`.
