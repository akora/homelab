# Building a Multi-Tier Home Lab

(!) IMPORTANT NOTE: I am fully aware that I'm exposing my username, some local paths and my internal network structure in the documentation and in the codebase. This is for educational purposes, I am OK with it.

To adjust the configuration to your own environment, please replace `akora` with your username and adjust the IP addresses and hostnames in the `hosts` file.

Let's begin!

## Generate SSH keypair

The very first thing you need to do is to generate an SSH keypair. This will be used to enable passwordless authentication and will also allow Ansible to work seamlessly.

```bash
ssh-keygen -t ed25519 -f "~/.ssh/homelab_ed25519" -N "" -C "homelab access key"
```

## Copy SSH key to remote hosts

Copy the public key to all remote hosts. This is manual, no need for a fancy script at this stage.

```bash
ssh-copy-id -i ~/.ssh/homelab_ed25519.pub akora@192.168.0.41
ssh-copy-id -i ~/.ssh/homelab_ed25519.pub akora@192.168.0.42
ssh-copy-id -i ~/.ssh/homelab_ed25519.pub akora@192.168.0.51
ssh-copy-id -i ~/.ssh/homelab_ed25519.pub akora@192.168.0.91
```

## Ping all hosts

Test connectivity and make sure everything is working.

```bash
ansible all -m ping
```

You should see SUCCESS for each host.

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

## Check OS versions

```bash
ansible all -m shell -a 'cat /etc/lsb-release | grep DISTRIB_DESCRIPTION'
```

At the time of writing, all hosts are running Ubuntu 24.04.3 LTS.

NEXT: reaching "baseline" level, Tier ONE!

## Tier ONE: Baseline Configuration

Run the baseline playbook:

```bash
ansible-playbook ansible/playbooks/baseline.yml
```

For the very first run you may need to add `--ask-become-pass` to the command.

This will apply the following changes:

- Update package cache
- Upgrade all packages
- Install common packages
- Configure locale
- Set system locale
- Set timezone to UTC
- Ensure sudo is installed
- Configure password-less sudo for admin user
- Secure SSH server
- Set kernel parameters for security

## Tier TWO: Docker Installation

Run the Docker playbook:

```bash
ansible-playbook -i ansible/inventory/hosts ansible/playbooks/docker.yml
```

This will apply the following changes:

- Install required packages for Docker
- Install Docker packages on ARM
- Install Docker packages on x86_64
- Create docker group
- Add admin user to docker group
- Install Docker Compose
- Create docker config directory
- Configure Docker daemon
- Enable and start Docker service
- Verify Docker installation
- Verify Docker Compose installation
- Create Docker Compose files directory
- Check existing ACLs for Docker Compose directory
- Set additional permissions for Docker Compose directory
- Ensure setfacl is installed (for ACL management)
