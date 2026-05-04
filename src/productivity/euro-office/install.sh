#!/usr/bin/env bash
# TAPPaaS Module: euro-office — Installation
#
# Euro-Office DocumentServer — collaborative document editing platform
#
# Creates the euro-office VM in Proxmox and applies initial configuration.
# It assumes that you are in the install directory.
#
# Usage: ./install.sh <vmname>
# Example: ./install.sh euro-office

. /home/tappaas/bin/install-vm.sh

# run the update script as all update actions is also needed at install time
. ./update.sh

echo ""
info "${GN}✓${CL} euro-office installation completed successfully."
