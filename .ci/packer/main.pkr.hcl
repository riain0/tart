packer {
  required_version = "~> 1.9"

  required_plugins {
    amazon = {
      version = ">= 1.2.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

#############
# Variables #
#############

variable "target_ami_name" {
  type = string

  description = "Common part of the name given to the AMI"
}

variable "tart_version" {
  type = string

  description = "The latest Tart version for pinning and tagging"
}

#########################
# AMI source definition #
#########################

locals {
  ami_name = format("%s-%s-arm64", var.target_ami_name, var.tart_version)
}

data "amazon-ami" "macos" {
  filters = {
    name = "amzn-ec2-macos-13.*-arm64"
  }
  owners = ["628277914472"]
  most_recent = true
}

source "amazon-ebs" "macos" {
  ami_name   = data.amazon-ami.macos.name
  source_ami = data.amazon-ami.macos.id

  instance_type = "mac2.metal"
  region        = "us-east-1"

  ena_support   = true
  ebs_optimized = true

  temporary_security_group_source_public_ip = true

  ssh_username = "ec2-user"
  ssh_timeout = "1h" # can take up to 40 minutes for the host to get provisioned

  launch_block_device_mappings {
    device_name = "/dev/sda1"

    delete_on_termination = true

    volume_type = "gp3"
    volume_size = 500
    iops        = 3000
    throughput  = 750
  }

  placement {
    tenancy = "host"
  }

  run_tags = {
    Name = local.ami_name
  }

  run_volume_tags = {
    Name = local.ami_name
  }

  temporary_iam_instance_profile_policy_document {
    Version = "2012-10-17"
    Statement {
      Action = [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:CompleteLayerUpload",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetAuthorizationToken"
      ]
      Effect   = "Allow"
      Resource = ["*"]
    }
  }

  // It takes a while for the created image to settle down from `Pending` to `Available`.
  // It seems that with default settings for amazon ebs builder is not enough and packer
  // build call ends randomly with:
  //
  // Error waiting for AMI: Failed with ResourceNotReady error, which can have a variety of causes.
  //   For help troubleshooting, check our docs: https://www.packer.io/docs/builders/amazon.html#resourcenotready-error
  //   original error: ResourceNotReady: exceeded wait attempts
  //
  // Looking at the logs and creation time attached to the image, increasing the waiting
  // time from 10 minutes (40 * 15sec) to 150 minutes (150 * 60sec) will hopefully resolve
  // this problem.
  aws_polling {
    max_attempts  = 150
    delay_seconds = 60
  }
}

###############################
# AMI provisioning definition #
###############################

build {
  name = "tart"

  sources = [
    "source.amazon-ebs.macos"
  ]

  provisioner "file" {
    source      = "./scripts/"
    destination = "/Users/ec2-user/scripts"
  }

  provisioner "shell" {
    scripts = [
      "./scripts/01_base_system_preparation.sh",
      "./scripts/02_docker_credentials_helper.sh",
      "./scripts/30_install_tart.sh",
      "./scripts/99_cleanup.sh",
    ]
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
