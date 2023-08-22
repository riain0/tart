#!/bin/zsh

set -euo pipefail

source /etc/zprofile
source ~/.zshrc

set -x

echo "Installing tart"

brew install cirruslabs/cli/tart cirruslabs/cli/orchard cirruslabs/cli/cirrus

# set SUID-bit
sudo chmod 04755 /opt/homebrew/bin/softnet

tart --version
tart list
