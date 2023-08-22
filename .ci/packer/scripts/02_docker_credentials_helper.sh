#!/bin/zsh

set -euo pipefail

source /etc/zprofile
source ~/.zshrc

set -x

brew install docker-credential-helper-ecr

mkdir -p ~/.docker

cat > ~/.docker/config.json <<EOF
{
  "credsStore": "ecr-login"
}
EOF
