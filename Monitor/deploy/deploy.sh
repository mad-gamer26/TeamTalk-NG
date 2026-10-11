#!/bin/sh
# Build and (re)start the monitor on your server:  deploy/deploy.sh
# Reads this deployment's settings from deploy/site/ (copy deploy/example/
# there and fill it in). First run also installs the systemd unit and the
# nginx site.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
site=${NGMON_SITE:-$here/deploy/site}
[ -f "$site/site.env" ] || { echo "No $site/site.env: copy deploy/example to deploy/site and fill it in" >&2; exit 1; }
. "$site/site.env"
host=${NGMON_HOST:?set NGMON_HOST in site.env}
url=${NGMON_URL:?set NGMON_URL in site.env}
nginx_site=${NGMON_NGINX_SITE:-ngmon}
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -R "$here/Cargo.toml" "$here/Cargo.lock" "$here/src" "$stage/"
mkdir "$stage/deploy"
cp "$site/ngmon.toml" "$site/ngmon.service" "$site/nginx.conf" "$stage/deploy/"
tar -C "$stage" -czf - Cargo.toml Cargo.lock src deploy | ssh "$host" 'rm -rf ~/ngmon/src-new && mkdir -p ~/ngmon/src-new && tar -C ~/ngmon/src-new -xzf -'
ssh "$host" "NGINX_SITE='$nginx_site' URL='$url' sh -s" <<'REMOTE'
set -eu
export PATH=$HOME/.cargo/bin:$PATH
cd ~/ngmon
rm -rf src-build && mv src-new src-build
(cd src-build && cargo build --release --locked 2>&1 | tail -2)
mkdir -p bin data
install -m 755 src-build/target/release/ngmon bin/ngmon.new && mv bin/ngmon.new bin/ngmon
[ -f ngmon.toml ] || cp src-build/deploy/ngmon.toml ngmon.toml
if ! cmp -s src-build/deploy/ngmon.service /etc/systemd/system/ngmon.service; then
    sudo cp src-build/deploy/ngmon.service /etc/systemd/system/ngmon.service
    sudo systemctl daemon-reload
    sudo systemctl enable ngmon
fi
if ! cmp -s src-build/deploy/nginx.conf "/etc/nginx/sites-available/$NGINX_SITE.conf"; then
    sudo cp src-build/deploy/nginx.conf "/etc/nginx/sites-available/$NGINX_SITE.conf"
    sudo ln -sf "/etc/nginx/sites-available/$NGINX_SITE.conf" "/etc/nginx/sites-enabled/$NGINX_SITE.conf"
    sudo nginx -t && sudo systemctl reload nginx
fi
sudo systemctl restart ngmon
sleep 1
systemctl is-active ngmon
curl -fsS "$URL/v1/info"; echo
REMOTE
