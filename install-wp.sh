#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=".env"
SITE_URL_DEFAULT="http://localhost:8080"
SITE_TITLE_DEFAULT="Natteravnene Dev"
ADMIN_EMAIL_DEFAULT="utvikler@natteravnene.no"
DB_READY_RETRIES=30
DEFAULT_THEME="nightraven"
BASE_THEME="twentyeleven"
CUSTOM_THEME_NAME="Nightraven"
COMPOSE_TEMPLATE="docker-compose.yml.template"
COMPOSE_FILE="docker-compose.yml"
WORDPRESS_SALTS=(
  WORDPRESS_AUTH_KEY
  WORDPRESS_SECURE_AUTH_KEY
  WORDPRESS_LOGGED_IN_KEY
  WORDPRESS_NONCE_KEY
  WORDPRESS_AUTH_SALT
  WORDPRESS_SECURE_AUTH_SALT
  WORDPRESS_LOGGED_IN_SALT
  WORDPRESS_NONCE_SALT
)

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

random_hex() {
  local bytes="${1:-24}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
  else
    head -c "$bytes" /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$1"
}

cleanup() {
  if docker compose ps wpcli >/dev/null 2>&1; then
    docker compose stop wpcli >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

append_env_var() {
  local key="$1"
  local value="$2"
  local escaped=${value//"/\\"}
  printf '%s="%s"\n' "$key" "$escaped" >>"$ENV_FILE"
}

ensure_env_file() {
  if [[ -f "$ENV_FILE" ]]; then
    log "Found existing $ENV_FILE"
    return
  fi

  cat >"$ENV_FILE" <<EOF_ENV
# Auto-generated local credentials. Edit values to customize your setup.
MYSQL_ROOT_PASSWORD="$(random_hex 32)"
MYSQL_DATABASE="wp"
MYSQL_USER="wp"
MYSQL_PASSWORD="$(random_hex 32)"
SITE_URL="${SITE_URL_DEFAULT}"
SITE_TITLE="${SITE_TITLE_DEFAULT}"
ADMIN_USER="admin"
ADMIN_PASS="$(random_hex 16)"
ADMIN_EMAIL="${ADMIN_EMAIL_DEFAULT}"
WORDPRESS_AUTH_KEY="$(random_hex 64)"
WORDPRESS_SECURE_AUTH_KEY="$(random_hex 64)"
WORDPRESS_LOGGED_IN_KEY="$(random_hex 64)"
WORDPRESS_NONCE_KEY="$(random_hex 64)"
WORDPRESS_AUTH_SALT="$(random_hex 64)"
WORDPRESS_SECURE_AUTH_SALT="$(random_hex 64)"
WORDPRESS_LOGGED_IN_SALT="$(random_hex 64)"
WORDPRESS_NONCE_SALT="$(random_hex 64)"
EOF_ENV
  log "Created $ENV_FILE with random credentials"
}

set_env_default() {
  local key="$1"
  local value="$2"
  if [[ -z "${!key:-}" ]]; then
    printf -v "$key" '%s' "$value"
    export "$key"
    append_env_var "$key" "$value"
  fi
}

set_env_random_hex() {
  local key="$1"
  local bytes="$2"
  if [[ -z "${!key:-}" ]]; then
    local value
    value=$(random_hex "$bytes")
    printf -v "$key" '%s' "$value"
    export "$key"
    append_env_var "$key" "$value"
  fi
}

load_env_vars() {
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a

  set_env_default "MYSQL_DATABASE" "wp"
  set_env_default "MYSQL_USER" "wp"
  set_env_default "SITE_URL" "$SITE_URL_DEFAULT"
  set_env_default "SITE_TITLE" "$SITE_TITLE_DEFAULT"
  set_env_default "ADMIN_EMAIL" "$ADMIN_EMAIL_DEFAULT"
  set_env_default "ADMIN_USER" "admin"

  set_env_random_hex "MYSQL_ROOT_PASSWORD" 32
  set_env_random_hex "MYSQL_PASSWORD" 32
  set_env_random_hex "ADMIN_PASS" 16
  for salt_var in "${WORDPRESS_SALTS[@]}"; do
    set_env_random_hex "$salt_var" 64
  done
}

ensure_compose_file() {
  if [[ ! -f "$COMPOSE_TEMPLATE" ]]; then
    echo "Missing compose template: $COMPOSE_TEMPLATE" >&2
    exit 1
  fi

  cp "$COMPOSE_TEMPLATE" "$COMPOSE_FILE"
}

wait_for_database() {
  echo "Waiting for the database to become ready..."
  local attempt=1
  while (( attempt <= DB_READY_RETRIES )); do
    if docker compose exec -T db mariadb-admin ping -h 127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD" --silent >/dev/null 2>&1; then
      echo "Database is ready."
      return
    fi
    sleep 2
    ((attempt++))
  done
  echo "Database did not become ready after $DB_READY_RETRIES attempts." >&2
  exit 1
}

ensure_custom_theme() {
  local source_dir="themes/${DEFAULT_THEME}"
  if [[ ! -d "$source_dir" ]]; then
    echo "Missing source theme directory: $source_dir" >&2
    exit 1
  fi

  docker compose exec wordpress rm -rf "/var/www/html/wp-content/themes/${DEFAULT_THEME}" >/dev/null 2>&1 || true
  docker compose exec wordpress mkdir -p "/var/www/html/wp-content/themes/${DEFAULT_THEME}"
  docker compose cp "$source_dir/." wordpress:/var/www/html/wp-content/themes/${DEFAULT_THEME}/ >/dev/null
  docker compose exec wordpress chown -R www-data:www-data "/var/www/html/wp-content/themes/${DEFAULT_THEME}"
  docker compose exec wordpress find "/var/www/html/wp-content/themes/${DEFAULT_THEME}" -type d -exec chmod 775 {} \; >/dev/null
  docker compose exec wordpress find "/var/www/html/wp-content/themes/${DEFAULT_THEME}" -type f -exec chmod 664 {} \; >/dev/null
}

apply_theme_colors() {
  docker compose exec -T wpcli wp option update twentyeleven_theme_options --format=json <<'JSON'
{"color_scheme":"light","link_color":"#7AC3DA","theme_layout":"content-sidebar"}
JSON

  docker compose exec -T wpcli wp theme mod set background_color f5f7f7 >/dev/null
  docker compose exec -T wpcli wp theme mod set header_textcolor 222222 >/dev/null

  local css_payload
  css_payload=$(cat <<'CSS'
/* Natteravnene UI color system */
:root {
  --nr-color-primary: #7AC3DA;
  --nr-color-primary-dark: #1E3A3E;
  --nr-color-background: #F5F7F7;
  --nr-color-text: #222222;
  --nr-color-gray-ui: #E1E6E6;
  --nr-color-gray-text-secondary: #626969;
  --nr-color-accent: #FFB400;
}

body,
button,
input,
select,
textarea {
  background-color: var(--nr-color-background);
  color: var(--nr-color-text);
}

#page,
.entry-content,
.entry-summary,
.widget,
#secondary .widget,
article.post {
  background-color: #fff;
  border-color: var(--nr-color-gray-ui);
}

a,
.entry-title a,
.widget-area a {
  color: var(--nr-color-primary);
}

a:hover,
a:focus,
#access a:hover,
#access .current-menu-item > a,
#access .current_page_item > a {
  color: var(--nr-color-primary-dark);
}

#branding,
#access,
#access ul ul {
  background-color: var(--nr-color-primary-dark);
  color: #fff;
}

#branding a,
#branding h1,
#branding h2,
#access a {
  color: #fff;
}

.entry-meta,
.entry-meta a,
.widget-area .widget li,
.widget-area .widget p {
  color: var(--nr-color-gray-text-secondary);
}

.widget-title,
.entry-title {
  border-color: var(--nr-color-gray-ui);
}

button,
input[type="submit"],
input[type="button"],
input[type="reset"],
#respond input#submit,
a.button {
  background: var(--nr-color-accent);
  border-color: var(--nr-color-primary-dark);
  color: #1E3A3E;
}

button:hover,
input[type="submit"]:hover,
input[type="button"]:hover,
input[type="reset"]:hover,
#respond input#submit:hover,
a.button:hover {
  background: var(--nr-color-primary);
  color: #1E3A3E;
}

::selection {
  background: var(--nr-color-primary);
  color: #fff;
}

::-moz-selection {
  background: var(--nr-color-primary);
  color: #fff;
}
CSS
  )

  local css_post_id
  css_post_id=$(docker compose exec -T wpcli wp post list --post_type=custom_css --name="${DEFAULT_THEME}" --field=ID --format=ids | tr -d '\r')

  if [[ -z "$css_post_id" ]]; then
    css_post_id=$(docker compose exec -T wpcli wp post create \
      --post_type=custom_css \
      --post_name="${DEFAULT_THEME}" \
      --post_title="Additional CSS (${CUSTOM_THEME_NAME})" \
      --post_status=publish \
      --post_content="$css_payload" \
      --porcelain)
  else
    docker compose exec -T wpcli wp post update "$css_post_id" --post_content="$css_payload" >/dev/null
  fi

  docker compose exec -T wpcli wp eval "\$mods = get_option( 'theme_mods_${DEFAULT_THEME}', array() ); \$mods['custom_css_post_id'] = (int) ${css_post_id}; update_option( 'theme_mods_${DEFAULT_THEME}', \$mods );" >/dev/null
}

configure_site_preferences() {
  docker compose exec -T wpcli wp option update default_comment_status closed >/dev/null
  docker compose exec -T wpcli wp option update default_ping_status closed >/dev/null
  docker compose exec -T wpcli wp option update comment_moderation 1 >/dev/null
  docker compose exec -T wpcli wp option update show_avatars 0 >/dev/null
  docker compose exec -T wpcli wp option update classic-editor-replace classic >/dev/null 2>&1 || true
  docker compose exec -T wpcli wp option update classic-editor-allow-users 0 >/dev/null 2>&1 || true
}

require_command docker
log "Ensuring required files and configuration"
ensure_env_file
load_env_vars
ensure_compose_file

mkdir -p db wordpress

services=(db wordpress wpcli)
log "Starting containers: ${services[*]}"
docker compose up -d "${services[@]}"

log "Waiting for services to become ready"
wait_for_database
log "Applying filesystem permissions"
docker compose exec wordpress bash -lc '
  mkdir -p wp-content/uploads wp-content/upgrade &&
  chown -R www-data:www-data wp-content &&
  find wp-content -type d -exec chmod 775 {} \; &&
  find wp-content -type f -exec chmod 664 {} \;
' >/dev/null

if docker compose exec -T wpcli wp core is-installed >/dev/null 2>&1; then
  log "WordPress already installed"
else
  log "Installing WordPress core"
  docker compose exec -T wpcli wp core install \
    --url="${SITE_URL}" \
    --title="${SITE_TITLE}" \
    --admin_user="${ADMIN_USER}" \
    --admin_password="${ADMIN_PASS}" \
    --admin_email="${ADMIN_EMAIL}" \
    --skip-email
fi

log "Installing required plugins"
declare -a REQUIRED_PLUGINS=(
  "wordfence"
  "classic-editor"
  "tinymce-advanced"
  "simple-history"
  "disable-comments"
)

for plugin in "${REQUIRED_PLUGINS[@]}"; do
  if docker compose exec -T wpcli wp plugin is-installed "$plugin" >/dev/null 2>&1; then
    log "Plugin $plugin already present"
  else
    docker compose exec -T wpcli wp plugin install "$plugin" --activate
  fi
done

docker compose exec -T wpcli wp plugin activate "${REQUIRED_PLUGINS[@]}"

log "Ensuring custom theme state"
ensure_custom_theme
docker compose exec -T wpcli wp theme activate "${DEFAULT_THEME}"
log "Applying brand color system"
apply_theme_colors
log "Applying site preferences"
configure_site_preferences

log "Stopping wp-cli helper"
docker compose stop wpcli >/dev/null

log "Environment provisioning complete (db/wordpress left running)"
