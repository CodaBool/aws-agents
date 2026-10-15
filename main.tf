provider "aws" {
  region              = "us-east-1"
  allowed_account_ids = ["919759177803"]
}

terraform {
  # https://github.com/opentofu/opentofu/releases
  required_version = ">= v1.13.1, < 2.0.0"
  required_providers {
    aws = {
      # https://github.com/hashicorp/terraform-provider-aws/releases
      version = "< 7.0"
    }
  }
  backend "s3" {
    bucket = "codabool-tf"
    key    = "agents.tfstate"
    region = "us-east-1"
  }
}

locals {
  name   = "agents" # AMI name prefix ("agents-*" from `just ami`), key pair name
  subnet = "subnet-02bd6f23bd2e48675"
  ip     = "2600:1f18:1248:e300:fdde:c3dd:7e9c:8da0"
  # SSH is allowed only from your ipv4, IP=<addr> in .env (gitignored), `curl -4 ifconfig.co`
  ssh_ipv4 = ["${local.env.IP}/32"]
  # replace with your ipv6
  # ssh_ipv6 = ["/128", "/128"]
  # `just ami` uploads the disk here for the snapshot import, must match justfile
  ami_bucket = "codabool-agents-ami-import"
  # KEY=value lines of .env, comments and blank lines skipped
  # everything but local_only is sent to the host through SSM (aws_ssm_parameter.env)
  env        = { for t in regexall("(?m)^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", file("${path.module}/.env")) : t[0] => trimspace(t[1]) }
  local_only = ["IP"]
}


# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance
resource "aws_instance" "main" {
  # newest agents-* AMI. After `just ami-clean` there is none, and the provider rejects a null ami even with
  # ignore_changes, so fall back to a placeholder: ignored for the existing instance, a clear error on create
  ami           = try(data.aws_ami_ids.image.ids[0], "ami-none-run-just-ami")
  instance_type = "t4g.medium"
  subnet_id     = local.subnet # ipv6
  key_name      = local.name
  # too many things break without the ipv4
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.main.id]
  ipv6_addresses              = [local.ip]
  # for initial assignment
  # ipv6_address_count   = 1
  iam_instance_profile = local.name
  root_block_device {
    volume_size = 24
  }
  # the AMI disk is bib's default size, bootc-generic-growpart.service grows it to the volume on boot

  # force IMDSv2, hop limit 2 so containers can still reach IMDS
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }
  tags = {
    Name = local.name
  }
  # the OS updates in place from ghcr.io/codabool/aws-agents:latest (bootc)
  # a newer AMI must not replace the instance, use `tofu apply -replace=aws_instance.main` for that
  lifecycle {
    ignore_changes = [ami]
  }
}


# built by bootc-image-builder (`just ami`), it doesn't tag the AMI so match the name
# aws_ami_ids (newest first) instead of aws_ami, which errors when `just ami-clean` left none
data "aws_ami_ids" "image" {
  owners = ["self"]
  filter {
    name   = "name"
    values = ["${local.name}-*"]
  }
  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

data "aws_vpc" "default" {
  default = true
}

resource "aws_security_group" "main" {
  name   = local.name
  vpc_id = data.aws_vpc.default.id
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = local.ssh_ipv4
    # ipv6_cidr_blocks = local.ssh_ipv6
  }
  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    ipv6_cidr_blocks = ["::/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = local.name
  }
}


# no policies attached anymore, kept so the instance profile exists for later (SSM, CloudWatch agent, ...)
resource "aws_iam_role" "main" {
  name = local.name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = local.name
  role = aws_iam_role.main.name
}

# every .env key except local_only, as KEY=value lines (TUNNEL_TOKEN, DISCORD_TOKEN, ...)
# agent-secrets.service writes it to ~/src/agent/quadlets/.env on every boot
# the value also ends up in the tofu state (s3://codabool-tf)
resource "aws_ssm_parameter" "env" {
  name  = "/agents/env"
  type  = "SecureString" # default aws/ssm key, its key policy covers decrypt through SSM
  value = join("", [for k, v in local.env : "${k}=${v}\n" if !contains(local.local_only, k)])
  lifecycle {
    precondition {
      condition     = contains(keys(local.env), "TUNNEL_TOKEN")
      error_message = "add TUNNEL_TOKEN=<cloudflared token> to .env, tunnel.container needs it"
    }
  }
}

resource "aws_iam_role_policy" "ssm" {
  name = "ssm"
  role = aws_iam_role.main.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "ssm:GetParameter"
      Resource = aws_ssm_parameter.env.arn
    }]
  })
}

moved {
  from = aws_iam_role.cw_assume
  to   = aws_iam_role.main
}

output "private_dns" {
  value = aws_instance.main.private_dns
}

output "id" {
  value = aws_instance.main.id
}

# AMI import for bootc-image-builder (`just ami`), create first with `just bootstrap`
# https://docs.aws.amazon.com/vm-import/latest/userguide/required-permissions.html
resource "aws_s3_bucket" "ami_import" {
  bucket        = local.ami_bucket
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "ami_import" {
  bucket                  = aws_s3_bucket.ami_import.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# disk images are only needed during the import
resource "aws_s3_bucket_lifecycle_configuration" "ami_import" {
  bucket = aws_s3_bucket.ami_import.id
  rule {
    id     = "expire"
    status = "Enabled"
    expiration {
      days = 1
    }
  }
}

# ImportSnapshot requires a service role named exactly "vmimport"
resource "aws_iam_role" "vmimport" {
  name = "vmimport"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "vmie.amazonaws.com" }
      Condition = { StringEquals = { "sts:Externalid" = "vmimport" } }
    }]
  })
}

resource "aws_iam_role_policy" "vmimport" {
  name = "vmimport"
  role = aws_iam_role.vmimport.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.ami_import.arn, "${aws_s3_bucket.ami_import.arn}/*"]
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:ModifySnapshotAttribute",
          "ec2:CopySnapshot",
          "ec2:RegisterImage",
          "ec2:Describe*"
        ]
        Resource = "*"
      }
    ]
  })
}

output "ami" {
  value = aws_instance.main.ami
}

output "unused_amis" {
  description = "agents-* AMIs still registered (snapshot storage costs), remove with `just ami-clean`"
  value       = data.aws_ami_ids.image.ids
}

output "ipv4" {
  value = aws_instance.main.public_ip
}

output "ipv6" {
  value = aws_instance.main.ipv6_addresses[0]
}
