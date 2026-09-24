# ADR-006 — Transactional Outbox para consistência entre estado e eventos

- **Status:** Accepted
- **Data:** 2026-09-24
- **Escopo:** Finance Platform

## Contexto

O Authorization Service precisa persistir o resultado da autorização/reserva e publicar `TransacaoAutorizada`.

Uma implementação ingênua produz dual write:

```text
1. DynamoDB write
2. EventBridge PutEvents
```

Isso permite falhas como:

```text
DynamoDB ✓
EventBridge ✗
```

Nesse cenário, a autorização existe, mas consumidores nunca recebem o evento.

A ordem inversa possui problema equivalente:

```text
EventBridge ✓
DynamoDB ✗
```

Não será utilizada uma distributed transaction envolvendo DynamoDB e EventBridge.

## Decisão

Adotar o padrão **Transactional Outbox**.

A alteração de estado e o registro do evento a publicar deverão participar da mesma transação DynamoDB.

Conceitualmente:

```text
TransactWriteItems
      |
      +-- update Limit
      |
      +-- create Authorization
      |
      +-- persist Idempotency result
      |
      +-- create Outbox Event
```

Após commit:

```text
Outbox
  |
  v
publisher / DynamoDB Streams integration
  |
  v
EventBridge
```

## Publicação

O mecanismo concreto poderá utilizar DynamoDB Streams e um componente de integração/publicação para encaminhar os registros Outbox ao EventBridge.

O requisito essencial desta decisão é:

> o request de autorização não deve depender de um dual write não atômico entre banco e event bus.

A implementação local poderá utilizar um adapter equivalente para demonstrar o comportamento sem exigir toda a infraestrutura AWS.

## Identificação

Cada evento terá `event_id` globalmente único.

O mesmo `event_id` deverá ser preservado durante retries de publicação.

## Falhas

Se EventBridge estiver temporariamente indisponível:

1. autorização permanece persistida;
2. Outbox permanece registrada;
3. publicação pode ser repetida;
4. consumers continuam protegidos por idempotência.

## Garantias

A estratégia não oferece exactly-once delivery.

Ela oferece:

- atomicidade entre mudança de estado e registro da intenção de publicação;
- publicação retryable;
- at-least-once;
- consumidores idempotentes.

## Alternativas consideradas

### Persistir e chamar EventBridge diretamente

Rejeitada como única estratégia devido ao problema de dual write.

### Publicar primeiro e persistir depois

Rejeitada pelo mesmo motivo, invertido.

### Distributed transaction / 2PC

Rejeitada pela complexidade e ausência de suporte/necessidade apropriada entre os componentes selecionados.

## Consequências positivas

- reduz risco de perda de eventos;
- elimina dual write não atômico no caminho crítico;
- permite retry;
- integra bem com consumidores idempotentes.

## Consequências negativas

- maior complexidade;
- consistência com consumidores é eventual;
- requer mecanismo de publicação da Outbox;
- pode gerar publicação duplicada, que deve ser tolerada.

## Status

Accepted.
