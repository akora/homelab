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
ansible-playbook ansible/playbooks/baseline.yml --ask-become-pass
```

For this to run successfully, you need to provide the password for sudo.

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
