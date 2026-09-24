# ADR-007 — At-least-once delivery e consumidores idempotentes

- **Status:** Accepted
- **Data:** 2026-09-24
- **Escopo:** Finance Platform

## Contexto

A arquitetura EventBridge/SQS pode entregar o mesmo evento mais de uma vez.

Falhas entre processamento e ACK também podem produzir reentrega.

Não é seguro assumir exactly-once delivery.

O contrato `TransacaoAutorizada` possui `event_id` globalmente único para deduplicação.

## Decisão

Assumir explicitamente semântica **at-least-once**.

Todo consumidor que produza efeito observável deverá ser idempotente usando `event_id`.

Fluxo:

```text
receive event
     |
     v
validate contract
     |
     v
event_id already processed?
     |
 +---+---+
 |       |
yes      no
 |       |
ACK    process
         |
         v
   mark processed
         |
         v
        ACK
```

## Falha

Se o processamento falhar:

```text
PROCESSING_FAILED
        |
        v
do not ACK/delete
        |
        v
SQS redelivery
```

Depois de `maxReceiveCount`, a infraestrutura poderá enviar a mensagem à DLQ.

## Idempotency Repository

Consumers possuirão uma porta semelhante a:

```text
IdempotencyRepository

hasBeenProcessed(eventId)
markAsProcessed(eventId)
```

Testes isolados poderão utilizar implementação in-memory.

Produção poderá utilizar implementação persistente adequada, como DynamoDB.

## Atomicidade do consumer

Para consumidores que produzam efeitos financeiros reais, a verificação de idempotência e o efeito de negócio deverão ser projetados de forma atomicamente segura ou equivalente.

O mock atual demonstra o protocolo, mas não deve ser interpretado como implementação completa de ledger contábil.

## Reordenação

Consumers não deverão depender implicitamente da ordem de entrega.

Quando a ordem for requisito de negócio, ela deverá ser tratada explicitamente pelo bounded context e poderá exigir mudança de tecnologia/configuração.

## Testes obrigatórios

Cada consumer deverá testar:

```text
same event_id delivered twice
```

Resultado:

```text
business effect count = 1
```

Também deverá testar que uma falha:

```text
não marca event_id como processado
não confirma a mensagem
```

## Alternativas consideradas

### Exactly-once end-to-end

Rejeitada como premissa arquitetural.

Garantias exactly-once distribuídas são complexas e frequentemente se reduzem a at-least-once + processamento idempotente no efeito de negócio.

### Deduplicação apenas da SQS

Rejeitada como garantia suficiente. A aplicação precisa proteger seus próprios efeitos de negócio.

## Consequências positivas

- comportamento resiliente a retries;
- tolerância a duplicações;
- protocolo explícito;
- falhas recuperáveis.

## Consequências negativas

- consumidores precisam manter estado de deduplicação;
- efeitos externos precisam ser desenhados para idempotência;
- implementação é mais complexa que processamento ingênuo.

## Status

Accepted.
