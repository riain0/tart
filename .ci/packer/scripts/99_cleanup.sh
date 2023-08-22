#!/bin/zsh

set -euo pipefail

source /etc/zprofile
source ~/.zshrc

set -x

# Remove ec2-macos-init history so everything runs again
# when launching an instance from this AMI
sudo rm -rf /usr/local/aws/ec2-macos-init/instances/*
cat /dev/null > .ssh/authorized_keys
