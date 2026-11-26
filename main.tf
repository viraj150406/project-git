terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # For a pipeline, use a remote backend so state persists between runs, e.g.:
  # backend "s3" {
  #   bucket = "my-tf-state-bucket"
  #   key    = "eks/cluster1/terraform.tfstate"
  #   region = "ap-south-1"
  # }
}

provider "aws" {
  region = "ap-south-1"
}

variable "k8s_version" {
  type    = string
  default = "1.35"
}

# ---------------------------------------------------------------
# Cluster IAM role
# ---------------------------------------------------------------
resource "aws_iam_role" "cluster1" {
  name = "eks-cluster-example987"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster1.name
}

# ---------------------------------------------------------------
# Networking (default VPC)
# ---------------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ---------------------------------------------------------------
# EKS cluster
# ---------------------------------------------------------------
resource "aws_eks_cluster" "cluster1" {
  name     = "cluster1"
  role_arn = aws_iam_role.cluster1.arn
  version  = var.k8s_version

  access_config {
    authentication_mode = "API"
  }

  vpc_config {
    subnet_ids = data.aws_subnets.default.ids
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy
  ]
}

# ---------------------------------------------------------------
# Worker node IAM role
# ---------------------------------------------------------------
resource "aws_iam_role" "worker_nodes" {
  name = "eks-worker-node-role-example987"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "worker_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.worker_nodes.name
}

resource "aws_iam_role_policy_attachment" "worker_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.worker_nodes.name
}

resource "aws_iam_role_policy_attachment" "worker_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.worker_nodes.name
}

# ---------------------------------------------------------------
# Ubuntu EKS AMI (Canonical) + launch template
# ---------------------------------------------------------------
data "aws_ami" "ubuntu_eks" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu-eks/k8s_${var.k8s_version}/images/hvm-ssd/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_launch_template" "ubuntu_nodes" {
  name_prefix = "eks-ubuntu-"
  image_id    = data.aws_ami.ubuntu_eks.id

  # Custom AMIs are not auto-bootstrapped, so join the cluster via user data
  user_data = base64encode(<<-EOT
    #!/bin/bash
    set -o xtrace
    /etc/eks/bootstrap.sh ${aws_eks_cluster.cluster1.name} \
      --apiserver-endpoint '${aws_eks_cluster.cluster1.endpoint}' \
      --b64-cluster-ca '${aws_eks_cluster.cluster1.certificate_authority[0].data}'
  EOT
  )

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = 30
      volume_type = "gp3"
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "eks-ubuntu-worker"
    }
  }
}

# ---------------------------------------------------------------
# Managed node group (Ubuntu)
# ---------------------------------------------------------------
resource "aws_eks_node_group" "worker_nodes" {
  cluster_name    = aws_eks_cluster.cluster1.name
  node_group_name = "worker-nodes"
  node_role_arn   = aws_iam_role.worker_nodes.arn
  subnet_ids      = data.aws_subnets.default.ids

  instance_types = ["c7i-flex.large"]

  launch_template {
    id      = aws_launch_template.ubuntu_nodes.id
    version = aws_launch_template.ubuntu_nodes.latest_version
  }

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.worker_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.worker_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.worker_AmazonEC2ContainerRegistryReadOnly
  ]
}

# ---------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------
output "cluster_name" {
  value = aws_eks_cluster.cluster1.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.cluster1.endpoint
}

output "ubuntu_ami_id" {
  value = data.aws_ami.ubuntu_eks.id
}
