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

variable "region" {
  type = string

  description = "AWS region in which to build the image"
}

variable "host_resource_group_arn" {
  type = string

  description = "ARN of the host resource group used to spin-up AWS mac2.metal instances"
}

variable "license_configuration_arn" {
  type = string

  description = "ARN of the license configuration used to spin-up AWS mac2.metal isntaces"
}

variable "manifest_file" {
  type = string

  description = "Name of the file that will hold manifest with details of built AMI"
}

variable "source_ami_id" {
  type = string

  description = "ID of the source AMI we're building on top of"
}

variable "target_ami_name" {
  type = string

  description = "Common part of the name given to the AMI"
}

#########################
# AMI source definition #
#########################

locals {
  ami_name = format("%s-arm64-%s", var.target_ami_name, formatdate("YYYYMMDDhhmmssZ", timestamp()))
}

source "amazon-ebs" "macos" {
  ami_name = local.ami_name

  instance_type = "mac2.metal"
  region        = var.region

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
    host_resource_group_arn = var.host_resource_group_arn
    tenancy                 = "host"
  }

  license_specifications {
    license_configuration_request {
      license_configuration_arn = var.license_configuration_arn
    }
  }

  # We should be in control of when a newer version of MacOS AMI
  # is used as a base for our builds
  source_ami = var.source_ami_id

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
    source      = "./assets/"
    destination = "/Users/ec2-user/"
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
