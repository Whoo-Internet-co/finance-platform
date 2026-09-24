# ADR-004 — Estratégia de idempotência das operações mutantes

- **Status:** Accepted
- **Data:** 2026-09-24
- **Escopo:** Finance Platform

## Contexto

Operações financeiras podem ser reenviadas por clientes devido a:

- timeout;
- retry automático;
- falha de rede;
- incerteza sobre o resultado da primeira tentativa.

Uma repetição não pode gerar uma segunda autorização ou uma segunda reserva de limite.

A API exige o header:

```http
Idempotency-Key: <UUID>
```

## Decisão

Toda operação mutante relevante deverá possuir controle de idempotência persistente.

Para autorização, será armazenado conceitualmente:

```text
idempotency_key
request_hash
status
response
created_at
expires_at
```

## Comportamento

### Primeira requisição

```text
Idempotency-Key: ABC
        ↓
acquire key atomically
        ↓
execute authorization
        ↓
persist result
        ↓
201 Created
```

### Retry equivalente

```text
Idempotency-Key: ABC
same semantic payload
        ↓
return original result
        ↓
200 OK
```

Nenhuma nova reserva ou autorização é criada.

### Mesma chave com payload diferente

```text
Idempotency-Key: ABC
different request hash
        ↓
409 Conflict
```

A mesma chave não poderá representar comandos semanticamente diferentes.

## Concorrência

A criação/aquisição da chave precisa ser atômica.

Duas requisições simultâneas usando a mesma chave não podem executar o caso de uso duas vezes.

DynamoDB Conditional Write ou TransactWriteItems será utilizado para garantir exclusividade.

## Request Hash

Um hash determinístico da representação canônica dos dados semanticamente relevantes será utilizado para detectar reutilização indevida da chave.

Metadados não semânticos não deverão alterar o hash sem necessidade.

## Expiração

Registros poderão possuir TTL.

O período exato será configurável e deverá ser definido conforme requisitos regulatórios e operacionais antes de produção.

## Alternativas consideradas

### Idempotência somente em memória

Rejeitada para produção porque não funciona corretamente com múltiplas instâncias ou reinícios.

Pode ser utilizada como adapter de testes.

### Confiar apenas no ID da autorização

Rejeitada porque o cliente ainda poderia disparar múltiplos comandos antes de conhecer o ID gerado.

## Consequências positivas

- retries seguros;
- evita double processing;
- resposta original recuperável;
- comportamento determinístico.

## Consequências negativas

- armazenamento adicional;
- definição de TTL;
- necessidade de canonicalização/hash;
- concorrência sobre a criação da chave precisa ser tratada.

## Status

Accepted.
