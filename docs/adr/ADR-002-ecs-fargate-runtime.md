# ADR-002 — ECS/Fargate como runtime dos serviços

- **Status:** Accepted
- **Data:** 2026-09-24
- **Escopo:** Finance Platform

## Contexto

A plataforma possui um caminho síncrono crítico de autorização de transações, com requisito de baixa latência e throughput de pico estimado em aproximadamente 5.000 TPS.

A arquitetura precisa escolher um runtime AWS entre alternativas como Lambda, ECS/Fargate e EKS.

Todos os serviços da solução serão containerizados e deverão ser executáveis localmente via Docker.

## Decisão

Adotar **Amazon ECS com AWS Fargate** como runtime principal dos workloads da plataforma.

Cada serviço executável possuirá seu próprio Dockerfile e será publicado como imagem OCI.

O Authorization Service será escalado horizontalmente por ECS Service/Auto Scaling.

Consumers assíncronos também poderão ser executados em ECS/Fargate, escalando de acordo com métricas das filas.

## Motivação

ECS/Fargate fornece:

- execução padronizada de containers;
- ausência de gerenciamento de servidores;
- processos continuamente aquecidos;
- controle explícito do runtime;
- horizontal scaling;
- integração nativa com CloudWatch, IAM e networking AWS;
- menor complexidade operacional que EKS.

## Alternativas consideradas

### AWS Lambda

É uma alternativa tecnicamente válida.

Poderia ser vantajosa para workloads event-driven e carga altamente variável. Provisioned Concurrency poderia reduzir impacto de cold starts.

Não foi escolhida como runtime principal devido ao perfil síncrono do Authorization Service, necessidade de controle do runtime e padronização da solução em containers continuamente disponíveis.

### Amazon EKS

Rejeitado para o escopo atual.

Kubernetes adicionaria complexidade operacional sem requisito que justifique:

- control plane Kubernetes;
- manifests;
- ingress;
- operators;
- cluster lifecycle.

EKS poderá ser reconsiderado caso requisitos organizacionais futuros demandem Kubernetes.

## Consequências positivas

- deployment uniforme;
- portabilidade local/AWS;
- controle do runtime;
- autoscaling;
- ausência de gestão de hosts EC2.

## Consequências negativas

- containers permanecem provisionados mesmo sem tráfego;
- scaling não é instantâneo;
- custo mínimo tende a ser superior ao de workloads Lambda esporádicos.

## Status

Accepted.
