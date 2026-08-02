#!/bin/bash
set -e

NEW_USER="hauke"

echo "=== 1. Creating User '${NEW_USER}' ==="
# Create user if it doesn't already exist
if ! id -u "${NEW_USER}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "${NEW_USER}"
  echo "User '${NEW_USER}' created."
fi

echo "=== 2. Setting Up Groups (sudo, docker) ==="
# Ensure 'docker' group exists before adding user
groupadd -f docker

# Add hauke to sudo and docker groups
usermod -aG sudo,docker "${NEW_USER}"

# Enable passwordless sudo for hauke
echo "${NEW_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${NEW_USER}"
chmod 0440 "/etc/sudoers.d/90-${NEW_USER}"

echo "=== 3. Copying SSH Authorized Keys from Root ==="
if [ -f /root/.ssh/authorized_keys ]; then
  mkdir -p "/home/${NEW_USER}/.ssh"
  cp /root/.ssh/authorized_keys "/home/${NEW_USER}/.ssh/authorized_keys"

  # Set strict SSH ownership & permissions
  chown -R "${NEW_USER}:${NEW_USER}" "/home/${NEW_USER}/.ssh"
  chmod 700 "/home/${NEW_USER}/.ssh"
  chmod 600 "/home/${NEW_USER}/.ssh/authorized_keys"
  echo "SSH keys copied to /home/${NEW_USER}/.ssh/authorized_keys"
else
  echo "WARNING: /root/.ssh/authorized_keys not found! Skipping key copy."
fi

echo "=== 4. Disabling SSH Password Authentication ==="
# Configure SSHD to reject password authentication
SSHD_CONFIG_DROPIN="/etc/ssh/sshd_config.d/50-no-passwords.conf"

if [ -d /etc/ssh/sshd_config.d ]; then
  cat << 'EOF' > "${SSHD_CONFIG_DROPIN}"
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
EOF
else
  # Fallback for older systems without drop-in directory support
  sed -i -E 's/^#?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
  sed -i -E 's/^#?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config
fi

# Restart SSH service to apply changes
systemctl restart ssh || systemctl restart sshd

echo "=== Setup complete for ${NEW_USER} ==="
