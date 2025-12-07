# Natteravnene Web

Local Dockerized WordPress environment focused on the Nightraven theme. Follow these steps to spin up and iterate on the site.

## Prerequisites
- Docker + Docker Compose plugin (v2)
- Bash-compatible shell
- `themes/nightraven/` tracked in Git as the source theme

## One-Time Setup
1. Clone this repository.
2. Ensure Docker Desktop/Engine is running.
3. Run the bootstrap script:
   ```bash
   ./install-wp.sh
   ```
   The script will:
   - Generate `.env` with random credentials
   - Render `docker-compose.yml` from `docker-compose.yml.template`
   - Launch `db`, `wordpress`, and a helper `wpcli` container
   - Install WordPress, default plugins, and copy `themes/nightraven/` into the container
   - Apply the Natteravnene color palette and site preferences
   - Stop the helper `wpcli` container, leaving WordPress + MariaDB running

## Day-to-Day Development
1. Start the stack (if not already running):
   ```bash
   docker compose up -d db wordpress wpcli
   ```
2. Access the site at [http://localhost:8080](http://localhost:8080).
3. Edit theme files under `themes/nightraven/` in your editor; rerun `./install-wp.sh` to sync changes into the container when needed, or manually copy files via `docker compose cp`.
4. Use shells as needed:
   - Build tools, npm, etc.:
     ```bash
     docker compose exec wordpress bash
     ```
   - WordPress CLI:
     ```bash
     docker compose exec wpcli wp <command>
     ```
5. Stop services when done:
   ```bash
   docker compose down
   ```

## Deployment Workflow
1. Export database:
   ```bash
   docker compose run --rm wpcli wp db export build/natteravnene.sql
   docker compose run --rm wpcli wp search-replace 'http://localhost:8080' 'https://prod-domain' --export=build/natteravnene-prod.sql
   ```
2. Upload `build/natteravnene-prod.sql` via phpMyAdmin (One.com).
3. Zip and upload only the theme directory via FTP:
   ```bash
   zip -r build/nightraven.zip themes/nightraven
   ```
   Extract/overwrite on the host.
4. Document any wp-config overrides required on One.com.

## Notes
- Never edit `wordpress/wp-content/themes/nightraven/` directly; that folder is regenerated from `themes/nightraven/`.
- `.env`, `db/`, `wordpress/`, and `docker-compose.yml` are ignored and can be deleted/recreated via `./install-wp.sh`.
