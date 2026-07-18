# Disposable e2e VPC — TEST SCOPE ONLY (that is why this lives under tests/,
# not infra/: it is not production surface). The mgmt and pilot modules take
# vpc_id/subnet_ids as required inputs because the repo deliberately owns no
# VPC; for the e2e (E2E_VPC=create in tests/e2e/run.sh) this module is a
# self-contained throwaway VPC the run owns end-to-end: created before the
# cluster modules, destroyed last, never touching any pre-existing VPC.
#
# State is local to this directory (no backend) — the VPC lives exactly as
# long as one e2e run, so remote state would outlive its purpose.

provider "aws" {
  region = var.region
}

locals {
  tags = {
    Name                = "synorg-e2e"
    "synorg.io/purpose" = "e2e-disposable"
    # EC2NodeClass subnet/SG discovery key (clusters/pilot/karpenter/) — an
    # externally-provided VPC must carry it or Karpenter finds no subnets.
    "karpenter.sh/discovery" = "synorg-pilot"
  }
  # EKS control planes require subnets in >= 2 AZs; take the first two
  # available AZs (typically <region>a / <region>b).
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

resource "aws_vpc" "e2e" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true # EKS requires VPC DNS resolution + hostnames
  enable_dns_hostnames = true

  tags = local.tags
}

resource "aws_internet_gateway" "e2e" {
  vpc_id = aws_vpc.e2e.id

  tags = local.tags
}

# TWO public subnets, one per AZ. Public + no NAT is a deliberate test-only
# tradeoff: a NAT gateway is the dominant standing cost of a throwaway VPC,
# and public nodes are acceptable for a disposable test VPC whose access is
# SG-restricted (the EKS modules manage the security groups). Production
# deploys keep requiring an operator-provided VPC with private subnets.
# karpenter.sh/discovery: the EC2NodeClasses (clusters/pilot/karpenter/)
# discover subnets and SGs by this tag; an externally-provided VPC must carry
# it or Karpenter sees "no subnets found" (found live).
resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.e2e.id
  cidr_block              = cidrsubnet(aws_vpc.e2e.cidr_block, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true # test-only: nodes get public IPs (no NAT)

  tags = local.tags
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.e2e.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.e2e.id
  }

  tags = local.tags
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
