#!/bin/bash
# Install or update multica systemd services
# Usage: sudo ./install.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER="${MULTICA_USER:-yg}"
WORK_DIR="/home/${USER}/__work/multica"

echo "Installing multica systemd services for user: ${USER}"
echo "Working directory: ${WORK_DIR}"

# Ensure log directory exists
mkdir -p "${WORK_DIR}/logs"
chown -R "${USER}:${USER}" "${WORK_DIR}/logs"

# Copy service files
cp "${SCRIPT_DIR}/multica-server.service" /etc/systemd/system/multica-server.service
cp "${SCRIPT_DIR}/multica-daemon.service" /etc/systemd/system/multica-daemon.service

# Reload systemd
systemctl daemon-reload

# Enable services
systemctl enable multica-server.service
systemctl enable multica-daemon.service

echo "Services installed. Start with:"
echo "  sudo systemctl start multica-server.service"
echo "  sudo systemctl start multica-daemon.service"
