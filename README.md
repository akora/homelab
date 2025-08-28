# Homelab

## Generate SSH keypair

```bash
ssh-keygen -t ed25519 -f "~/.ssh/homelab_ed25519" -N "" -C "homelab access key"
```

## Copy SSH key to remote hosts

```bash
ssh-copy-id -i ~/.ssh/homelab_ed25519.pub akora@192.168.0.41
ssh-copy-id -i ~/.ssh/homelab_ed25519.pub akora@192.168.0.42
ssh-copy-id -i ~/.ssh/homelab_ed25519.pub akora@192.168.0.51
ssh-copy-id -i ~/.ssh/homelab_ed25519.pub akora@192.168.0.91
```

## Ping all hosts

```bash
ansible all -m ping
```

## Security Hardening

To avoid man-in-the-middle attacks, it's important to enable host key checking.

### Add Host Keys to known_hosts

```bash
ssh-keyscan -H 192.168.0.41 192.168.0.42 192.168.0.51 192.168.0.91 >> ~/.ssh/known_hosts
```

### Update Ansible Configuration

Update `ansible.cfg` to enable `host_key_checking`:

```ini
host_key_checking = True
```
