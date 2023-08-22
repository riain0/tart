#!/bin/zsh

set -euo pipefail

source /etc/zprofile
source ~/.zshrc

set -x

sudo diskutil apfs list
CONTAINER_ID=$(diskutil list physical external | awk '/Apple_APFS/ {print $7}')
DISK_ID=$(echo "${CONTAINER_ID}" | cut -d's' -f1-2)

# Resize disk. New disk size is only visible after reboot
echo 'y' | sudo diskutil repairDisk "${DISK_ID}"
sudo diskutil apfs resizeContainer "${CONTAINER_ID}" 0 || echo ""
sudo diskutil apfs list

# Setup language
echo export LANG=en_US.UTF-8 >> ~/.zshrc
echo export LC_ALL=en_US.UTF-8 >> ~/.zshrc

# Disable spotlight
sudo mdutil -a -i off

# Update brew
brew update
