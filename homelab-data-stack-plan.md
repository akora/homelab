# `data_stack` (Postgres + Grafana + fuel collector) on zima-01

## Status: deployed (2026-06-19)

Postgres + Grafana + the weekly fuel-price collector are live on `zima-01`. This
doc previously described a more elaborate collector design (GHCR image, n8n
Schedule Trigger, `docker-socket-proxy`) that was never built — superseded by
the simpler approach below after review concluded the registry/CI/trigger
machinery wasn't worth it for a single-developer, pre-production stack.

## Context

`metrics-pipeline` (separate repo, `git.l4n.io/akora/metrics-pipeline`) owns
schema/dashboards-as-code and the collector Python source. `homelab` (GitHub
`akora/homelab`) owns the actual infra deployment via the `data_stack` Ansible
role, which clones `metrics-pipeline` and runs everything on `zima-01`.

Two spec open items resolved here:
- **O-3 (Traefik routing convention):** Traefik runs on `zima-01`
  (`ansible/playbooks/traefik.yml`). Grafana, co-located there, uses
  **docker-label** routing — matching Portainer/Homepage, not the
  file-provider pattern used for services on other hosts (Gitea, n8n).
- **O-4 (collector host placement):** the collector runs directly on
  `zima-01` as a host-level Python process (no separate Pi 5 placement, no
  container at all).

## How the fuel collector actually runs

No image, no registry, no n8n trigger. Just:

- Postgres' `5432` is published as `127.0.0.1:5432` only (never the LAN or a
  public interface — see the `ports:` entry in `templates/docker-compose.yml.j2`).
- A plain Python venv lives at `data_stack_collector_venv`
  (`/opt/docker/data-stack/config/collector-venv`), built by the role via
  `python3 -m venv` + `pip install -e .` against the cloned
  `metrics-pipeline` checkout.
- A small wrapper script (`templates/run-fuel-collector.sh.j2`, deployed to
  `data_stack_collector_script`) exports the DB env vars
  (`DB_HOST=127.0.0.1`, etc. — required names verified against
  `metrics-pipeline/lib/config.py`) and execs the collector module, forwarding
  any args (`--backfill`, `--dry-run`).
- `ansible.builtin.cron` schedules it weekly (`data_stack_collector_schedule`,
  default Thursday 20:00) via a dedicated `/etc/cron.d/data-stack-fuel-collector`
  file, logging to `/var/log/data-stack-fuel-collector.log`.
- Both `cron` and `python3-venv` are installed by the role if missing — neither
  was present on the base zima-01 image.

**One-time history backfill** (already run, not automated — same shape as the
original plan, just without `docker compose run`):
```
ssh zima-01
sudo /opt/docker/data-stack/config/run-fuel-collector.sh --backfill
```
Populated 2142 rows (2005–2026, euro95 + diesel) on first run.

**Known dependency:** the regular (non-backfill) weekly run converts EUR to
HUF using the `exchange_rates` table, which the n8n EUR/HUF workflow hasn't
been built yet to populate (see `metrics-pipeline` SPECIFICATION.md §6.1/§6.2).
Until that exists, the weekly cron run will fail loudly (by design — it
refuses to write an unconverted price) rather than silently land bad data.

## `templates/docker-compose.yml.j2`

Postgres and Grafana only — no `collector` service. Postgres gained:
```yaml
ports:
  - "127.0.0.1:{{ data_stack_postgres_port }}:5432"
```

## Vault

Existing keys reused, no new ones needed for the collector (it uses
`data_stack_postgres_metrics_rw_password`, already defined):
```
vault_data_stack_postgres_password
vault_data_stack_metrics_rw_password
vault_data_stack_grafana_ro_password
vault_data_stack_grafana_admin_password
```

## Known gaps (documented, not solved here)

- **Post-bootstrap migrations (spec O-7):** `/docker-entrypoint-initdb.d` only
  runs on an empty data directory. A future schema change won't auto-apply
  after first boot — revisit with a dedicated `migrate` one-off run when a
  real schema change is needed.
- **n8n EUR/HUF workflow:** not yet built; blocks the weekly (non-backfill)
  collector run from succeeding. Backfill doesn't need it (uses the EC's own
  embedded historical rate instead).
- **`data_stack_metrics_pipeline_ref` tracks `main`:** deliberate, see
  `metrics-pipeline` memory/feedback on avoiding pinning ceremony pre-production.
  Revisit if a risky schema change ever needs careful rollback.

## Verification performed

1. `ansible-playbook ansible/playbooks/data-stack.yml` — idempotent on repeat run.
2. `docker ps` on `zima-01`: `data-stack-postgres` and `data-stack-grafana` running.
3. `https://grafana.l4n.io/api/health` — healthy.
4. Backfill run: `select fuel_type, count(*), min(ts), max(ts), avg(price) from fuel_prices group by fuel_type;` — 1071 rows each for euro95/diesel, 2005-01-03 to 2026-06-15, average ~400 HUF/L (plausible).
