# Sequência — Autorização de transação (caminho feliz + outbox)

Caminho completo: `POST /v1/contratos/{id}/autorizacoes` → decisão síncrona →
outbox transacional → relay → EventBridge → SQS → consumers idempotentes.
Fontes: `AutorizarTransacaoUseCase.ts` (authorization-service), ADR-003/004/005/006/007.

```mermaid
sequenceDiagram
  autonumber
  actor C as Cliente
  participant ALB as ALB
  participant A as Authorization Service
  participant D as DynamoDB (single-table)
  participant S as DynamoDB Streams
  participant R as Lambda outbox-relay
  participant EB as EventBridge (bus custom)
  participant Q as SQS (accounting/fraud/notification)
  participant K as Consumer (×3)

  C->>ALB: POST /v1/contratos/CTR-1/autorizacoes<br/>Idempotency-Key: K1 + payload
  ALB->>A: forward (health /health já verde)

  Note over A: Valida payload (OpenAPI v1) → inválido: 422 (RFC 7807)
  Note over A: computeRequestHash(payload) — ADR-004

  rect rgb(235,245,255)
    Note over A,D: Idempotency acquire (atomic conditional write)
    A->>D: PutItem IDEMPOTENCY#K1 (status=EM_ANDAMENTO, request_hash) condition: attribute_not_exists
    alt chave já existe, MESMO hash, CONCLUIDA
      D-->>A: ConditionFailed → lê resposta persistida
      A-->>C: 200 (resultado original, header Idempotency-Key ecoado)
    else chave já existe, hash DIVERGENTE
      A-->>C: 409 conflito (chave reutilizada c/ payload diferente)
    else em andamento (concorrência)
      A-->>C: 409 concorrência (reenviar)
    else adquirida
      D-->>A: OK (K1 = EM_ANDAMENTO)
    end
  end

  A->>D: GetItem CONTRACT#CTR-1 / PROFILE#CTR-1 (leitura consistente)
  Note over A: Domínio: contrato inativo → 409;<br/>limite insuficiente → 402 (recusa determinística persistida via completeFailure)

  rect rgb(235,255,235)
    Note over A,D: UMA TransactWriteItems — tudo ou nada (ADR-006)
    A->>D: TransactWriteItems [<br/>  Update condicionado do limite (available_limit -= valor),<br/>  Put AUTH#AUT-1 (+ gsi1_pk/gsi1_sk),<br/>  Update IDEMPOTENCY#K1 → CONCLUIDA + response,<br/>  Put OUTBOX#EVT-1 (evento TransacaoAutorizada) ]
    D-->>A: commit OK
  end

  A-->>C: 201 Created + Location + AutorizacaoResponse
  Note over A,C: Resposta síncrona NÃO depende de publish (sem dual-write)

  D--)S: registros de stream (NEW_IMAGE)
  S--)R: batch de INSERTs (event source mapping, LATEST)
  Note over R: filtra entity=OUTBOX (ignora contrato/auth/idempotency da single-table)
  R->>EB: PutEvents (Source=co.whoo-internet.finance.authorization,<br/>DetailType=TransacaoAutorizada, Detail=payload, event_id preservado)
  Note over R: Falha PutEvents → throw → Streams reentrega (at-least-once)

  EB->>Q: regra de fan-out → 3 filas (envelope com detail)

  loop cada consumer (accounting, fraud, notification)
    Q--)K: ReceiveMessage (long polling)
    Note over K: parser: flat OU envelope.detail → valida schema v1
    K->>K: dedup por event_id (idempotente — ADR-007)
    alt event_id novo
      Note over K: accounting: PutItem ledger (entries) + dedup dynamodb;<br/>fraud: análise mock; notification: gateway mock
      K->>Q: DeleteMessage (ACK)
    else duplicata (retry/replay do relay)
      K->>Q: DeleteMessage (ACK sem efeito colateral)
    end
    Note over K,Q: erro sem ACK → visibilidade expira → retry;<br/>após maxReceiveCount=5 → DLQ (+ alarme depth>0)
  end
```

## Garantias

| Trecho                     | Semântica                          | Mecanismo                                   |
| -------------------------- | ---------------------------------- | ------------------------------------------- |
| HTTP → decisão             | síncrona                           | single-table + TransactWriteItems           |
| Estado ↔ intenção de evento| atômica                            | outbox na MESMA transação (ADR-006)         |
| Relay → EventBridge → SQS  | at-least-once                      | retry do Streams + `event_id` estável       |
| Consumers                  | efeito exactly-once *por event_id* | dedup idempotente (ADR-007)                 |
| Falha de consumo           | retry + DLQ + alarme               | visibility timeout + redrive (maxReceive=5) |
