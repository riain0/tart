#!/bin/zsh

set -euo pipefail

source /etc/zprofile
source ~/.zshrc

set -x

echo "Installing Tart, Orchard and Cirrus CLI"

brew install cirruslabs/cli/tart cirruslabs/cli/orchard cirruslabs/cli/cirrus
brew pin cirruslabs/cli/tart 

# set SUID-bit for softnet
sudo chmod 04755 /opt/homebrew/bin/softnet

softnet --help
tart --version
orchard --version
cirrus --version
