# ---------------------------------------------------------------------------
# ALB — interface HTTP da API do Authorization Service.
#
# Decisão: ALB direto (SEM API Gateway HTTP API). Justificativa no
# terraform/README.md — menor superfície, zero custo adicional, health check
# nativo e roteamento simples; autenticação mínima (API key) pode ser adicionada
# no futuro por um Lambda Authorizer no API Gateway sem alterar o serviço.
# ---------------------------------------------------------------------------

resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection       = false
  idle_timeout                     = 60
  drop_invalid_header_fields       = true

  tags = { Name = "${var.project_name}-alb" }
}

resource "aws_lb_target_group" "authorization" {
  name        = "${var.project_name}-auth-tg"
  port        = var.authorization_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = var.authorization_health_check_path
    port                = var.authorization_port
    protocol            = "HTTP"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = { Name = "${var.project_name}-auth-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.authorization.arn
  }

  # Nota: listener HTTPS exige certificado ACM (fora do escopo free-tier);
  # em produção, adicione listener 443 com certificate_arn.
}