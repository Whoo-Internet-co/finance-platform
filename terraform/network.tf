# ---------------------------------------------------------------------------
# Rede — VPC simples, 2 AZs, subnets públicas.
#
# Decisão de custo mínimo: SEM NAT Gateway e SEM VPC Endpoints.
# As tasks Fargate usam subnets públicas com assign_public_ip = true, o que
# permite pull de imagens (GHCR) e acesso às APIs AWS (DynamoDB/SQS/EventBridge)
# pela internet. Isso é adequado para a stack representativa do desafio;
# para produção, adicione subnets privadas + NAT/VPC endpoints.
# ---------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project_name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.project_name}-igw" }
}

resource "aws_subnet" "public" {
  count = length(var.availability_zones)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index) # 10.0.0.0/24, 10.0.1.0/24...
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${var.project_name}-public-${var.availability_zones[count.index]}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.project_name}-rt-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# Security Groups
# ---------------------------------------------------------------------------

# ALB: aceita HTTP da internet, fala apenas com as tasks.
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb"
  description = "ALB da plataforma — ingress HTTP, egress para tasks"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP da internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-sg-alb" }
}

# Tasks do Authorization Service: ingress HTTP apenas do ALB.
resource "aws_security_group" "authorization" {
  name        = "${var.project_name}-authorization"
  description = "Tasks do Authorization Service"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP do ALB"
    from_port       = var.authorization_port
    to_port         = var.authorization_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Egress total: acesso a DynamoDB, EventBridge e pull de imagens.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-sg-authorization" }
}

# Tasks dos consumers: sem ingress; egress total.
resource "aws_security_group" "consumers" {
  name        = "${var.project_name}-consumers"
  description = "Tasks dos consumers (accounting, fraud, notification)"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-sg-consumers" }
}