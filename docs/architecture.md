# Arquitetura — Finance Platform

Desenho ponta a ponta da solução: contexto de negócio, bounded contexts, fluxo
síncrono de autorização, fluxo assíncrono de eventos, resiliência e trade-offs.
Diagramas em [`docs/diagrams/`](diagrams/); decisões em [`docs/adr/`](adr/).

## 1. Contexto de negócio

A plataforma endereça o problema de **autorização de transações** no cenário
Itaú/POD99: um serviço que decide, de forma síncrona e consistente, se uma
transação (débito, crédito, reserva, estorno) pode ser autorizada contra o
limite de um contrato — em escala de **~5.000 TPS no pico** e **~80 milhões de
contas**.

Restrições que moldam o desenho:

| Restrição | Consequência arquitetural |
| --------- | ------------------------- |
| Decisão síncrona de baixa latência | Caminho crítico curto: ALB → serviço → DynamoDB (sem hops desnecessários) |
| Proibido overspending sob concorrência | Reserva de limite **atômica** via conditional write ([ADR-003](adr/ADR-003-dynamodb-authorization-limit.md)) |
| Clientes reenviam requisições (timeout/retry) | Idempotência por `Idempotency-Key` + `request_hash` ([ADR-004](adr/ADR-004-idempotency-strategy.md)) |
| Estado e evento não podem divergir | Transactional outbox na mesma transação ([ADR-006](adr/ADR-006-transactional-outbox.md)) |
| ~80M contas, acesso por chave conhecida | DynamoDB single-table, PAY_PER_REQUEST, escala horizontal sem shard ([ADR-003](adr/ADR-003-dynamodb-authorization-limit.md)) |
| Consumidores independentes com picos próprios | EventBridge + uma fila SQS por consumer ([ADR-005](adr/ADR-005-eventbridge-sqs.md)) |
| Escala de 5k TPS com containers padronizados | ECS/Fargate + auto scaling ([ADR-002](adr/ADR-002-ecs-fargate-runtime.md)) |

Visão de contexto (atores e sistemas externos):
[`docs/diagrams/c4-context.md`](diagrams/c4-context.md).

## 2. Bounded contexts

| Contexto | Responsabilidade | Repo |
| -------- | ---------------- | ---- |
| **Authorization** | Decidir autorizações contra o limite do contrato; idempotência; emitir `TransacaoAutorizada` | `authorization-service` |
| **Accounting** | Registrar o ledger contábil das autorizações (idempotente por `event_id`) | `accounting-consumer` |
| **Fraud** | Avaliação antifraude do evento (mock configurável — escopo congelado) | `fraud-consumer` |
| **Notification** | Notificar o cliente/estabelecimento (gateway mock) | `notification-consumer` |
| **Contracts** (supporting) | Source of truth de OpenAPI + JSON Schema dos eventos; distribuído como package versionado ([ADR-008](adr/ADR-008-centralized-contract-registry.md)) | `finance-platform-contracts` |
| **Platform delivery** (este repo) | Terraform da stack AWS, docker-compose local, diagramas, ADRs, demo e CI | `finance-platform` |

Cada serviço segue Clean/Hexagonal ([ADR-001](adr/ADR-001-clean-hexagonal-architecture.md)):
domínio e use cases não conhecem AWS; adapters inbound (HTTP/SQS) e outbound
(DynamoDB/EventBridge) implementam ports. Integração entre contextos é
**exclusivamente por contrato versionado** (`TransacaoAutorizada` v1) — nunca
por banco ou código compartilhado.

## 3. Fluxo síncrono — autorização

Diagrama completo: [`docs/diagrams/sequence-authorization.md`](diagrams/sequence-authorization.md).

```text
Cliente ──HTTP──> ALB ──> authorization-service ──> DynamoDB single-table
                 (listener :80, health /health:3000)
```

> **Decisão registrada**: ALB **direto, sem API Gateway** — um único backend,
> sem roteamento/throttling por rota que justifiquem o hop extra; ver
> [`terraform/README.md`](../terraform/README.md#decisão-alb-direto-sem-api-gateway).
> (Divergência vs. enunciado do desafio, que menciona "API Gateway/ALB": a
> implementação adotou ALB e o trade-off está documentado.)

Passos do caminho crítico (1 round-trip de escrita no caso feliz):

1. **Validação de payload** contra o OpenAPI v1 — inválido → `422`
   (`application/problem+json`, RFC 7807).
2. **`computeRequestHash(payload)`** — a chave de idempotência é comprometida
   com o conteúdo ([ADR-004](adr/ADR-004-idempotency-strategy.md)).
3. **Idempotency acquire** — `PutItem IDEMPOTENCY#<key>` condicional
   (`attribute_not_exists`):
   - adquirida → segue;
   - já existe com **mesmo hash**, `CONCLUIDA` → replay: **`200`** com a
     resposta original (limite não é debitado de novo);
   - já existe com **hash divergente** → **`409`** (chave reutilizada);
   - `EM_ANDAMENTO` (concorrência) → **`409`** concorrência.
4. **Leitura do contrato** — `GetItem CONTRACT#<id>` (consistente):
   inativo → `409`; limite insuficiente → **`402`** (recusa determinística
   persistida via complete-failure; replay da mesma chave reproduz o 402).
5. **UMA `TransactWriteItems`** — tudo ou nada
   ([ADR-006](adr/ADR-006-transactional-outbox.md)):
   - update **condicional** do limite (`available_limit -= valor`) —
     barreira final contra overspending;
   - insert da **autorização** (`AUTH#<id>` + GSI de consulta);
   - update da **idempotência** → `CONCLUIDA` + resposta persistida;
   - insert do **evento de outbox** (`OUTBOX#<event_id>`, `TransacaoAutorizada`).
6. **Resposta `201 Created`** (+ `Location`). A resposta síncrona **não**
   depende de publish em event bus — não existe dual write.

Codificação HTTP do domínio: `201`/`200` (replay), `402` (limite), `409`
(conflitos), `422` (validação), `503` (infra/circuit breaker), `429`
(throttling — ver §5). Erros em RFC 7807.

## 4. Fluxo assíncrono — eventos

```text
DynamoDB Streams (INSERT OUTBOX#*)
  → Lambda outbox-relay (filtra entity=OUTBOX, preserva event_id)
  → EventBridge bus custom (regra TransacaoAutorizada)
  → fan-out: 3 filas SQS (accounting / fraud / notification) + 3 DLQs
  → consumers ECS Fargate (long polling, dedup por event_id)
```

Diagrama de containers: [`docs/diagrams/c4-container.md`](diagrams/c4-container.md);
topologia física: [`docs/diagrams/deployment-aws.md`](diagrams/deployment-aws.md).

- **Relay** ([ADR-006](adr/ADR-006-transactional-outbox.md)): event source
  mapping sobre Streams (`NEW_IMAGE`, `LATEST`); falha de `PutEvents` →
  throw → o Streams reentrega (at-least-once, `event_id` estável).
- **EventBridge** ([ADR-005](adr/ADR-005-eventbridge-sqs.md)): regra
  `transacao-autorizada-fanout` no bus `finance-platform-events` entrega o
  envelope (`detail` = payload do evento) às 3 filas. Um consumer lento ou
  fora do ar **não** bloqueia os demais.
- **Consumers** ([ADR-007](adr/ADR-007-at-least-once-idempotent-consumers.md)):
  validam o evento contra o schema v1, **deduplicam por `event_id`**
  (accounting: tabela `finance-platform-consumer-idempotency` com TTL —
  durável; fraud/notification: in-memory com backend DynamoDB opcional),
  processam e fazem `DeleteMessage` (ACK). Sem ACK, a visibilidade expira e a
  mensagem é reentregue; após `maxReceiveCount=5` → **DLQ** com alarme
  CloudWatch (`depth > 0` → SNS).

No **ambiente local** (`docker-compose/`), o `outbox-relay-local` lê os mesmos
Streams e faz o fan-out direto às 3 filas SQS do LocalStack com o **mesmo
envelope** — adapter equivalente permitido pelo ADR-006 (EventBridge é
LocalStack Pro).

## 5. Resiliência

| Mecanismo | Onde | Comportamento |
| --------- | ---- | ------------- |
| **Circuit breaker** | authorization-service (port `CircuitBreaker`, adapter in-memory) | dependência degradada → abre o circuito → falha rápido com **`503`** + `Retry-After` (problema de infra, não de negócio) |
| **Throttling** | adapter DynamoDB | `ThrottlingException` / `ProvisionedThroughputExceededException` → `ServicoIndisponivelError` → **`503`** + `Retry-After`. O OpenAPI também declara **`429`** (`problems/throttling`) como resposta contratada; o emissor de 429 (rate limiter na borda) é a evolução natural quando houver API Gateway/edge — **divergência documentada** entre contrato e implementação atual |
| **Retry com backoff** | AWS SDK (transient errors), relay (reentrega do Streams), SQS (visibility timeout `30s`) | retries automáticos no client SDK; reentrega de mensagens sem ACK; relay idempotente por `event_id` |
| **At-least-once + dedup** | toda a cadeia de eventos | nada assume exactly-once; efeito exactly-once **por `event_id`** via dedup nos consumers ([ADR-007](adr/ADR-007-at-least-once-idempotent-consumers.md)) |
| **DLQ + alarmes** | SQS (×3) + CloudWatch | mensagens não processáveis isoladas; alarme DLQ depth>0 e ALB 5xx>0 → SNS |
| **HA** | ECS Fargate 2 AZs, ALB multi-AZ, DynamoDB multi-AZ nativo | réplicas de tasks nas 2 subnets; sem single point of failure de compute |
| **Atomicidade** | `TransactWriteItems` | limite+autorização+idempotência+outbox commitam juntos ou nada muda |

## 6. Trade-offs

### Fargate vs Lambda (runtime) — [ADR-002](adr/ADR-002-ecs-fargate-runtime.md)

| | ECS/Fargate (escolhido) | Lambda |
| - | ---------------------- | ------ |
| Latência sob 5k TPS sustentados | conexões quentes, sem cold start no caminho crítico | cold starts e limites de concorrência exigem provisioned concurrency (custo) |
| Portabilidade | mesmo Dockerfile roda local (compose) e na AWS | runtime preso ao modelo FaaS |
| Scaling | auto scaling por métricas de CPU/fila | scale automático por request |
| Custo no piso | paga-se task mínima 24/7 | paga-se por uso (melhor para carga esparsa) |

EKS foi descartado por complexidade operacional desproporcional ao escopo.
A **Lambda é usada onde faz sentido**: o outbox-relay (evento-driven, carga
esparsa, sem estado).

### DynamoDB vs Aurora (persistência) — [ADR-003](adr/ADR-003-dynamodb-authorization-limit.md)

| | DynamoDB (escolhido) | Aurora PostgreSQL |
| - | -------------------- | ----------------- |
| Reserva atômica sob concorrência | conditional write/transação nativa, single-digit ms | `SELECT ... FOR UPDATE` funciona, mas serializa hot rows |
| Escala a 80M contas / 5k TPS | horizontal nativa, PAY_PER_REQUEST, sem shard | escala vertical + read replicas; particionamento é manual |
| Modelo de acesso | 100% por chave conhecida (contrato/id/chave) — encaixa single-table | SQL brilha em consultas ad-hoc/joins (não é o caso do caminho crítico) |
| Outbox | Streams nativo → relay | precisaria de logical replication ou polling |

Trade-off aceito: modelagem single-table menos expressiva para queries
secundárias (mitigada por GSI) em troca de previsibilidade de latência e
escala.

### EventBridge vs SNS / Kinesis / MSK — [ADR-005](adr/ADR-005-eventbridge-sqs.md)

| | EventBridge (escolhido) | SNS | Kinesis | MSK |
| - | ---------------------- | --- | ------- | --- |
| Fan-out para N consumers independentes | regra por detail-type → fila por consumer | também faz fan-out | shard é compartilhado (consumers competem) | tópicos, ok |
| Semântica | event bus com envelope rico (source/detail-type/time) | notificação simples | stream ordenado (overkill aqui) | Kafka completo |
| Replay/reentrega | via SQS (visibilidade + DLQ) | sem retry por assinante | retention + LTR | retention |
| Custo operacional | zero (managed) | zero | baixo | **alto** (brokers, tuning) |

Não há requisito de ordenação global nem de replay de stream; o acoplamento
é 1 evento → 3 reações independentes. SNS puro perde o envelope padronizado;
Kinesis/MSK adicionam custo/complexidade sem necessidade.

### Outbox vs dual write — [ADR-006](adr/ADR-006-transactional-outbox.md)

Dual write (banco ✓ + `PutEvents` ✗, ou inverso) permite estado sem evento ou
evento sem estado — inaceitável para movimentação financeira. O outbox grava a
**intenção de publicar** na mesma transação do estado; o relay entrega com
at-least-once e os consumers deduplicam por `event_id`. Custo: latência
adicional de publicação (assíncrona — irrelevante, pois a resposta HTTP não
depende dela) e a tabela de outbox na single-table (filtrada por
`entity=OUTBOX` no relay; TTL remove eventos publicados).

## 7. Onde cada decisão se materializa

| Decisão | Implementação |
| ------- | ------------- |
| ADR-001 Clean/Hexagonal | `src/domain`, `src/application`, `src/adapters/{inbound,outbound}` em cada serviço; domínio sem import AWS |
| ADR-002 Fargate | `terraform/ecs.tf` (cluster + 4 services), `terraform/alb.tf`, Dockerfiles nos repos |
| ADR-003 DynamoDB | `terraform/dynamodb.tf` (single-table + GSI + TTL + Streams); `DynamoDbLimitRepository` (conditional write) |
| ADR-004 Idempotência | acquire/complete no use case `AutorizarTransacaoUseCase`; itens `IDEMPOTENCY#` com `request_hash` |
| ADR-005 EventBridge+SQS | `terraform/eventbridge.tf`, `terraform/sqs.tf` (3 filas + 3 DLQs, redrive=5) |
| ADR-006 Outbox | `TransactWriteItems` com item `OUTBOX#`; `terraform/lambda.tf` (relay Streams→EventBridge); `docker-compose/outbox-relay-local` |
| ADR-007 Consumers idempotentes | dedup por `event_id` nos 3 consumers; tabela `finance-platform-consumer-idempotency` |
| ADR-008 Contracts | repo `finance-platform-contracts` (OpenAPI v1 + schema `TransacaoAutorizada` v1 + tests) |

## 8. Divergências documentadas

1. **ALB direto, sem API Gateway** — o enunciado cita "API Gateway/ALB"; a
   stack provisiona ALB puro (decisão e justificativa em
   [`terraform/README.md`](../terraform/README.md#decisão-alb-direto-sem-api-gateway)).
2. **`429` contratado, não emitido hoje** — o OpenAPI declara `429`
   (throttling) e `503`; a implementação atual mapeia throttling do DynamoDB e
   circuit breaker aberto para `503` + `Retry-After`. O 429 de borda entra com
   rate limiting no edge (API Gateway/ALB) sem quebra de contrato.
3. **`CONTRATO_INEXISTENTE` → `409`** (não `404`) — conflito de estado,
   alinhado ao OpenAPI que não declara 404 (ver README do authorization-service).
4. **EventBridge ausente no compose local** — LocalStack community não inclui
   EventBridge; o relay local faz fan-out direto às filas SQS com o mesmo
   envelope (`detail`), adapter equivalente previsto no ADR-006.
5. **Dedup in-memory em fraud/notification** — durável apenas no
   accounting-consumer (backend DynamoDB); os demais aceitam backend DynamoDB
   opcional (tabela já provisionada). Ver pendências no
   [`demo-script.md`](../demo-script.md).
