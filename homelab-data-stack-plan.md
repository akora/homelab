# Plan: `data_stack` (Postgres + Grafana + fuel collector) on zima-01

## Context

This continues work that started in the `metrics-pipeline` repo (separately developed app layer: collectors, DB migrations, Grafana provisioning JSON — already built and tested, 10/10 tests passing for the `fuel_eu_bulletin` EU Oil Bulletin collector). That repo's `SPECIFICATION.md` defines a two-repo split: `metrics-pipeline` owns schema/dashboards-as-code, while `homelab` (GitHub `akora/homelab`, branch `main`) owns the actual infra deployment via Ansible.

The piece that was never built is the homelab side: a `data_stack` role that stands up Postgres + Grafana on `zima-01` (the ZimaBoard), sourcing schema/dashboards from `metrics-pipeline` at a pinned ref, and wiring up the weekly fuel-price collector run. This plan covers that role plus the supporting playbook, vault entries, and a documented (non-Ansible) n8n trigger.

Two open spec items get resolved here based on how the homelab repo actually deploys things, not guessed:
- **O-3 (Traefik routing convention):** Traefik itself runs on `zima-01` (`ansible/playbooks/traefik.yml` targets `hosts: zima-01`). Services co-located with Traefik (Portainer, Homepage) use **docker-label** routing; services on other hosts (Gitea on rpi5-01, n8n on rpi4-02) use the **file-provider** dynamic-config pattern, because Traefik's docker provider can't see labels on a different host's socket. Since Grafana also lives on `zima-01`, it uses docker-label routing — no new file goes into `ansible/roles/traefik/templates/`.
- **O-4 (collector host placement):** Decided — co-locate the collector on `zima-01` (not Pi 5), so it talks to Postgres over the internal Docker network with no LAN-exposed DB port.

Scheduling decision: triggered by an **n8n Schedule trigger** (n8n runs on `rpi4-02`), per explicit choice, even though that means the trigger workflow itself isn't version-controlled in the homelab repo (n8n workflows live only in its own SQLite DB there — accepted tradeoff). The mechanism reuses infrastructure that already exists: **`docker-socket-proxy`** is already deployed on every host in the `homelab` Ansible group, including `zima-01`, with its port published to the LAN (`192.168.0.91:2375`) and `POST` already enabled (used today for Watchtower-style container control, e.g. by Homepage's auto-discovery). So n8n just needs one HTTP Request node hitting `POST http://192.168.0.91:2375/containers/<name>/start` — no new SSH credential, no new proxy.

Image source decision: the collector pulls a **pre-built image from a registry** (not built via Ansible — there's no precedent for Ansible-driven `docker build` anywhere in the homelab repo; everything else just pulls a tag). This means `metrics-pipeline` needs a small CI addition (out of scope for the homelab repo, called out as a prerequisite below) to publish `ghcr.io/akora/metrics-pipeline:<tag>` on each release tag. The git clone of `metrics-pipeline` is still required regardless — it's how `migrations/` and `grafana/provisioning/` get onto disk for bind-mounting; only the collector's *image* comes from the registry instead of being locally built.

## Prerequisite (this repo: metrics-pipeline)

Before the registry pull will work, `metrics-pipeline` needs a GitHub Actions workflow that builds the existing `Dockerfile` and pushes `ghcr.io/akora/metrics-pipeline:<tag>` on each pushed tag (using the built-in `GITHUB_TOKEN` with `packages: write` permission). Also check GHCR package visibility after the first push — GHCR packages default to **private** even when the parent repo is public, so the package needs to be explicitly set public (or `homelab`'s pull needs a `~/.docker/config.json` login on `zima-01`, which is more setup than it's worth for a LAN-only homelab). This blocks the `data_stack` role's collector service from actually starting until it exists.

## New role: `ansible/roles/data_stack/` (in the homelab repo)

Mirrors the structure of `ansible/roles/gitea/` and `ansible/roles/n8n/` (both reviewed directly).

**`defaults/main.yml`** — new variables, following the `gitea_*`/`n8n_*` naming convention:
```yaml
data_stack_metrics_pipeline_repo: "https://github.com/akora/metrics-pipeline.git"
data_stack_metrics_pipeline_ref: "v0.1.0"          # pinned tag; bump to upgrade schema/dashboards
data_stack_clone_directory: "/opt/metrics-pipeline"

data_stack_postgres_data_directory: "/opt/docker/data-stack/postgres-data"
data_stack_grafana_data_directory: "/opt/docker/data-stack/grafana-data"
data_stack_config_directory: "/opt/docker/data-stack/config"

data_stack_network_name: "data-stack-net"          # internal only, not external
data_stack_traefik_network_name: "traefik-net"      # joined only by grafana

data_stack_postgres_image: "postgres:16"
data_stack_postgres_user: "postgres"                # bootstrap superuser only
data_stack_postgres_password: "{{ vault_data_stack_postgres_password }}"
data_stack_postgres_metrics_rw_password: "{{ vault_data_stack_metrics_rw_password }}"
data_stack_postgres_grafana_ro_password: "{{ vault_data_stack_grafana_ro_password }}"
data_stack_postgres_db: "metrics"

data_stack_grafana_image: "grafana/grafana-oss:latest"
data_stack_grafana_admin_password: "{{ vault_data_stack_grafana_admin_password }}"
data_stack_grafana_http_port: "3000"
data_stack_grafana_domain: "{{ vault_service_domains.grafana }}"
data_stack_grafana_root_url: "https://{{ data_stack_grafana_domain }}/"
data_stack_grafana_traefik_certresolver: "cloudflare"

data_stack_collector_image: "ghcr.io/akora/metrics-pipeline:{{ data_stack_metrics_pipeline_ref }}"
data_stack_collector_container_name: "data-stack-fuel-collector"

data_stack_homepage_integration: true
data_stack_homepage_name: "Grafana"
data_stack_homepage_icon: "si-grafana"
data_stack_homepage_description: "Metrics Dashboards"
```

**`tasks/check_docker.yml`** — copy of `ansible/roles/gitea/tasks/check_docker.yml` verbatim (verifies docker / docker compose available).

**`tasks/main.yml`** — sequence, mirroring gitea's structure:
1. `include_tasks: check_docker.yml`
2. Create directories (`data_stack_postgres_data_directory`, `data_stack_grafana_data_directory`, `data_stack_config_directory`), mode 0755 — same pattern as gitea's directory block.
3. Create the internal `data_stack_network_name` network — use the same `shell: docker network ls | grep` + `docker network create` idiom as gitea/n8n/syncthing (matches majority convention; traefik's `community.docker.docker_network` module is the minority pattern).
4. Clone `metrics-pipeline` at the pinned ref:
   ```yaml
   - name: Clone metrics-pipeline at pinned ref
     ansible.builtin.git:
       repo: "{{ data_stack_metrics_pipeline_repo }}"
       dest: "{{ data_stack_clone_directory }}"
       version: "{{ data_stack_metrics_pipeline_ref }}"
       force: yes
   ```
5. Template `docker-compose.yml.j2` → `{{ data_stack_config_directory }}/docker-compose.yml`.
6. Deploy via `community.docker.docker_compose_v2` (`project_src: {{ data_stack_config_directory }}`, `state: present`) — do not set `recreate: always` (would risk unnecessary Postgres/Grafana restarts); a plain apply is enough since changing `data_stack_metrics_pipeline_ref` or the compose file naturally triggers recreation of the affected service.
7. Force the collector container to a stopped state after every apply, since `docker_compose_v2` starts all defined services by default and this one must NOT auto-run:
   ```yaml
   - name: Ensure collector container is stopped (triggered on-demand by n8n)
     community.docker.docker_container:
       name: "{{ data_stack_collector_container_name }}"
       state: stopped
   ```
8. Status/debug tasks: `docker ps | grep` for postgres/grafana, display `data_stack_grafana_root_url` — mirrors gitea's tail end.

**`templates/docker-compose.yml.j2`** — three services. **Hard constraint, verified directly from `metrics-pipeline/grafana/provisioning/datasources/postgres.yml`:** that file hardcodes `url: postgres:5432` and is bind-mounted read-only (Ansible cannot template it). Docker Compose's automatic network-internal DNS alias is the **service key**, not `container_name` — so the Postgres service in the compose file must be named exactly `postgres:`, regardless of what `container_name:` is set to.

```yaml
services:
  postgres:
    image: "{{ data_stack_postgres_image }}"
    container_name: data-stack-postgres
    restart: unless-stopped
    networks: [data-stack-net]        # no traefik-net, no ports: — never exposed
    environment:
      POSTGRES_DB: "{{ data_stack_postgres_db }}"
      POSTGRES_USER: "{{ data_stack_postgres_user }}"
      POSTGRES_PASSWORD: "{{ data_stack_postgres_password }}"
      PG_METRICS_RW_PASSWORD: "{{ data_stack_postgres_metrics_rw_password }}"   # required name, verified in migrations/0000_roles.sh
      PG_GRAFANA_RO_PASSWORD: "{{ data_stack_postgres_grafana_ro_password }}"   # required name, verified in migrations/0000_roles.sh
    volumes:
      - "{{ data_stack_postgres_data_directory }}:/var/lib/postgresql/data"
      - "{{ data_stack_clone_directory }}/migrations:/docker-entrypoint-initdb.d:ro"
    labels:
      - "traefik.enable=false"   # defensive; not on traefik-net anyway

  grafana:
    image: "{{ data_stack_grafana_image }}"
    container_name: data-stack-grafana
    restart: unless-stopped
    depends_on: [postgres]
    networks: [data-stack-net, traefik-net]
    environment:
      GF_SECURITY_ADMIN_PASSWORD: "{{ data_stack_grafana_admin_password }}"
      GF_SERVER_ROOT_URL: "{{ data_stack_grafana_root_url }}"
      GRAFANA_DB_PASSWORD: "{{ data_stack_postgres_grafana_ro_password }}"      # required name, verified in provisioning/datasources/postgres.yml
    volumes:
      - "{{ data_stack_grafana_data_directory }}:/var/lib/grafana"
      - "{{ data_stack_clone_directory }}/grafana/provisioning:/etc/grafana/provisioning:ro"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.grafana.rule=Host(`{{ data_stack_grafana_domain }}`)"
      - "traefik.http.routers.grafana.entrypoints=websecure"
      - "traefik.http.routers.grafana.tls=true"
      - "traefik.http.routers.grafana.tls.certresolver={{ data_stack_grafana_traefik_certresolver }}"
      - "traefik.http.services.grafana.loadbalancer.server.port={{ data_stack_grafana_http_port }}"
      # homepage.* labels under {% if data_stack_homepage_integration %}, same pattern as n8n's compose template

  collector:
    image: "{{ data_stack_collector_image }}"
    container_name: "{{ data_stack_collector_container_name }}"
    restart: "no"               # explicit string; run-once, triggered externally
    networks: [data-stack-net]  # no traefik-net, no ports
    environment:
      DB_HOST: postgres
      DB_PORT: "5432"
      DB_NAME: "{{ data_stack_postgres_db }}"
      DB_USER: metrics_rw
      DB_PASSWORD: "{{ data_stack_postgres_metrics_rw_password }}"   # required names, verified in lib/config.py

networks:
  data-stack-net:
    driver: bridge
  traefik-net:
    external: true
```

No `handlers/` needed — Grafana's file-provider already polls provisioning for changes every 60s (`grafana/provisioning/dashboards/dashboards.yml: updateIntervalSeconds: 60`), so no restart-on-change handler is required.

## New playbook: `ansible/playbooks/data-stack.yml`

Mirrors `ansible/playbooks/gitea.yml`/`n8n.yml`:
```yaml
---
- name: Deploy data stack (Postgres, Grafana, fuel collector)
  hosts: zima-01
  become: true
  roles:
    - data_stack
```

## Vault additions: `ansible/inventory/group_vars/all/vault.yml` (in the homelab repo)

New keys (values to be generated, not placeholders shown here):
```
vault_data_stack_postgres_password
vault_data_stack_metrics_rw_password
vault_data_stack_grafana_ro_password
vault_data_stack_grafana_admin_password
```
Plus a new entry under the existing `vault_service_domains:` map: `grafana: "grafana.l4n.io"`. Mirror the same additions into `vault.yml.example` for documentation parity (that file is currently missing `grafana`, and also missing `web` which already exists in the real file — fix opportunistically while editing).

## n8n trigger (manual, documented, not Ansible-managed)

In the n8n UI (`rpi4-02`, n8n's own domain):
1. New workflow, e.g. "Fuel Price Collector — Weekly".
2. **Schedule Trigger**: weekly, Thursday evening (n8n's global timezone is already `Europe/Budapest` per `ansible/roles/n8n/defaults/main.yml`, no extra TZ config needed).
3. **HTTP Request** node: `POST http://192.168.0.91:2375/containers/data-stack-fuel-collector/start`, no body, no auth (the proxy has none — consistent with how Homepage/Watchtower already use it unauthenticated, LAN-only trust model). Expect `204` success; `304` if already running (non-fatal); `404` if the role hasn't been deployed yet.
4. Activate, then do one manual "Execute Workflow" test; confirm on `zima-01` with `docker ps -a` that the container reaches `Exited (0)` (it won't restart itself, since `restart: "no"`).

Write this up as a short runbook (e.g. `docs/data-stack.md` in the homelab repo) since it's the one piece of this feature that isn't reproducible from Ansible alone.

## One-time history backfill (manual, no automation)

After first deploy, run once on `zima-01`:
```
cd /opt/docker/data-stack/config
docker compose run --rm collector python -m collectors.fuel_eu_bulletin --backfill
```
(`docker compose run` spins up a throwaway container alongside the named one — doesn't conflict with the persistent `data-stack-fuel-collector` container Ansible manages.)

## Known gaps (documented, not solved here)

- **Post-bootstrap migrations (spec O-7):** `/docker-entrypoint-initdb.d` only runs on an empty data directory. A future `metrics-pipeline` schema change (new `0002_*.sql`) won't auto-apply after first boot. No fix in this plan; revisit when a real schema change is needed (e.g. a dedicated `migrate` one-off run, same shape as the backfill command).
- **Collector image staleness vs n8n's `/start`-only call:** bumping `data_stack_metrics_pipeline_ref` and re-running the playbook recreates the collector container with the new image (compose detects the image change); n8n's lightweight `/start` between Ansible runs always uses whatever image was last applied — expected, not a bug.
- **GHCR package visibility:** confirm `ghcr.io/akora/metrics-pipeline` is set public after the first CI push, or `zima-01` won't be able to pull without auth.

## Verification

1. Run `ansible-playbook ansible/playbooks/data-stack.yml` against `zima-01`; confirm idempotent on a second run (no unexpected changes reported).
2. `docker ps` on `zima-01`: `data-stack-postgres` and `data-stack-grafana` running; `data-stack-fuel-collector` present but `Exited`/stopped.
3. Visit `https://grafana.l4n.io` (or via Twingate) — confirm login with the admin password from vault, and that the `PostgreSQL` datasource (provisioned, non-editable) shows green "Save & Test."
4. Run the one-time backfill command above; confirm rows land in `fuel_prices` (`docker exec -it data-stack-postgres psql -U postgres -d metrics -c "select count(*) from fuel_prices;"`) and the fuel dashboard renders history.
5. Manually trigger the n8n workflow once; confirm the collector container runs and exits cleanly, and that a new weekly row appears without duplicating the backfill data (idempotent upsert, already covered by metrics-pipeline's own test suite).
