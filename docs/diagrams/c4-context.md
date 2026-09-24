# C4 Context — Finance Platform

Nível 1 (Contexto): quem usa a plataforma e com quais sistemas externos ela
se relaciona.

```mermaid
C4Context
  title Contexto — Finance Platform (POD99)

  Person(cliente, "Cliente / Estabelecimento", "Inicia transações (débito, crédito, reserva, estorno)")
  Person(ops, "Operações / Suporte", "Monitora alarmes, DLQs e logs")

  System_Boundary(platform, "Finance Platform") {
    System(authz, "Authorization Service", "Autoriza transações contra o limite do contrato (API REST, idempotente — OpenAPI v1)")
    System(acct, "Accounting Consumer", "Registra o ledger contábil das autorizações")
    System(fraud, "Fraud Consumer", "Avaliação antifraude (mock configurável — escopo congelado)")
    System(notif, "Notification Consumer", "Notifica o cliente (gateway mock)")
  }

  System_Ext(contracts, "Contract Registry", "finance-platform-contracts: OpenAPI + JSON Schema do evento TransacaoAutorizada v1 (ADR-008)")
  System_Ext(alerts, "Canal de Alertas", "E-mail via SNS (alarmes CloudWatch)")

  Rel(cliente, authz, "POST /v1/contratos/{id}/autorizacoes (+ Idempotency-Key)", "HTTPS/JSON")
  Rel(authz, contracts, "Valida payload/evento contra schema v1", "vendored no build")
  Rel(acct, contracts, "Valida evento consumido", "vendored no build")
  Rel(fraud, contracts, "Valida evento consumido", "vendored no build")
  Rel(notif, contracts, "Valida evento consumido", "vendored no build")
  Rel(platform, alerts, "Alarmes DLQ depth>0 e ALB 5xx", "SNS")
  Rel(ops, alerts, "Recebe/ tria alarmes", "e-mail")
```

> Nota de escopo (congelado): sem Cognito real, antifraude real, multi-region,
> EKS/Kinesis/service mesh. `Cliente` autentica fora do escopo da demo.

## Fluxo de valor em uma frase

O cliente pede uma autorização; o **Authorization Service** decide
sincronamente (limite + idempotência) e publica **TransacaoAutorizada**;
os três consumers reagem de forma independente, idempotente e assíncrona
(ADR-005/006/007).
