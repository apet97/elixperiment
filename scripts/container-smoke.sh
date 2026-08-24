#!/usr/bin/env bash

# Build and exercise the production image without using production authority.
# Every credential below is a fixed, non-production test value. The disposable
# database name is validated and removed on exit.

set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

command -v docker >/dev/null 2>&1 || {
  printf 'container-smoke: docker is required\n' >&2
  exit 1
}

command -v trivy >/dev/null 2>&1 || {
  printf 'container-smoke: trivy is required\n' >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || {
  printf 'container-smoke: jq is required\n' >&2
  exit 1
}

git_sha=$(git rev-parse HEAD)
short_sha=${git_sha:0:12}
release_version=$(awk -F'"' '/^[[:space:]]*version: "/ {print $2; exit}' mix.exs)
image=${1:-"pumble-automation:smoke-${short_sha}"}
partition="_container_${$}_${RANDOM}"
database="pumble_automation_test${partition}"
container_name="pumble-automation-smoke-${$}-${RANDOM}"
canary_file="${repo_root}/.env.container-smoke-canary"
canary="container-smoke-canary-${$}-${RANDOM}-must-not-ship"
canary_created=false
database_created=false

case "$partition" in
  _container_[0-9]*_[0-9]*) ;;
  *)
    printf 'container-smoke: refusing unsafe database partition\n' >&2
    exit 1
    ;;
esac

cleanup() {
  status=$?
  trap - EXIT INT TERM

  docker rm --force "$container_name" >/dev/null 2>&1 || true

  if [[ "$database_created" == true ]]; then
    MIX_ENV=test MIX_TEST_PARTITION="$partition" \
      mix ecto.drop --force >/dev/null 2>&1 || true
  fi

  if [[ "$canary_created" == true && "$canary_file" == "$repo_root/.env.container-smoke-canary" ]]; then
    unlink "$canary_file" >/dev/null 2>&1 || true
  fi

  exit "$status"
}

trap cleanup EXIT INT TERM

sha256_stream() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    printf 'container-smoke: sha256sum or shasum is required\n' >&2
    return 1
  fi
}

if [[ "${CONTAINER_SMOKE_SKIP_BUILD:-false}" == true ]]; then
  docker image inspect "$image" >/dev/null
else
  if [[ -e "$canary_file" ]]; then
    printf 'container-smoke: refusing to overwrite %s\n' "$canary_file" >&2
    exit 1
  fi

  printf '%s\n' "$canary" >"$canary_file"
  canary_created=true

  DOCKER_BUILDKIT=1 docker build \
    --pull \
    --no-cache \
    --build-arg "GIT_SHA=${git_sha}" \
    --build-arg "RELEASE_VERSION=${release_version}" \
    --tag "$image" \
    .
fi

actual_revision=$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$image")
actual_version=$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "$image")
configured_user=$(docker image inspect --format '{{ .Config.User }}' "$image")
configured_entrypoint=$(docker image inspect --format '{{ json .Config.Entrypoint }}' "$image")

[[ "$actual_revision" == "$git_sha" ]] || {
  printf 'container-smoke: image revision label is not the tested commit\n' >&2
  exit 1
}

[[ "$actual_version" == "$release_version" ]] || {
  printf 'container-smoke: image version label is wrong\n' >&2
  exit 1
}

[[ "$configured_user" == "10001:10001" ]] || {
  printf 'container-smoke: image user is not numeric non-root\n' >&2
  exit 1
}

[[ "$configured_entrypoint" == '["/sbin/tini","--"]' ]] || {
  printf 'container-smoke: image entrypoint is not pinned tini\n' >&2
  exit 1
}

if docker image inspect "$image" | grep -F -q -- "$canary" || \
   docker history --no-trunc "$image" | grep -F -q -- "$canary"; then
  printf 'container-smoke: canary reached image metadata or history\n' >&2
  exit 1
fi

printf '%s' "$canary" | docker run --rm --interactive --entrypoint /bin/sh "$image" -c '
  needle=$(cat)
  ! grep -R -F -q -- "$needle" /app 2>/dev/null
'

docker run --rm --entrypoint /bin/sh "$image" -c '
  test ! -e /app/mix.exs
  test ! -d /app/assets
  test ! -d /app/config
  test ! -d /app/.git
  test -x /sbin/tini
  test -s /etc/ssl/certs/ca-certificates.crt
  test -f /usr/share/zoneinfo/UTC
  ! find /app -name ".env" -o -name ".env.*" | grep -q .
  ! find /app -name "seeds.exs" -o -name ".formatter.exs" | grep -q .
  ! find /app -type d -path "*/priv/release_test" | grep -q .
'

# Fixable HIGH/CRITICAL findings are an unconditional release failure. Trivy
# can also report vendor-acknowledged findings for which no fixed package
# exists. Those findings remain visible and require an explicit, recorded risk
# acceptance for this exact scan; they are never silently ignored.
scan_json=$(
  trivy image \
    --scanners vuln \
    --severity HIGH,CRITICAL \
    --no-progress \
    --skip-version-check \
    --format json \
    "$image"
)

fixable_high=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "HIGH" and (.FixedVersion // "") != "")] | length' <<<"$scan_json")
fixable_critical=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL" and (.FixedVersion // "") != "")] | length' <<<"$scan_json")
unfixed_high=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "HIGH" and (.FixedVersion // "") == "")] | length' <<<"$scan_json")
unfixed_critical=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL" and (.FixedVersion // "") == "")] | length' <<<"$scan_json")
unfixed_inventory=$(jq -r '
  [
    .Results[]?.Vulnerabilities[]?
    | select((.Severity == "HIGH" or .Severity == "CRITICAL") and (.FixedVersion // "") == "")
    | [.Severity, .VulnerabilityID, .PkgName, .Status, .InstalledVersion]
  ]
  | unique
  | sort
  | .[]
  | @tsv
' <<<"$scan_json")

if ((unfixed_high > 0 || unfixed_critical > 0)); then
  unfixed_sha256=$(printf '%s\n' "$unfixed_inventory" | sha256_stream)
else
  unfixed_sha256=none
fi

if ((fixable_high > 0 || fixable_critical > 0)); then
  printf 'container-smoke: fixable HIGH/CRITICAL vulnerabilities block release\n' >&2
  jq -r '
    .Results[]?.Vulnerabilities[]?
    | select((.Severity == "HIGH" or .Severity == "CRITICAL") and (.FixedVersion // "") != "")
    | [.Severity, .VulnerabilityID, .PkgName, .InstalledVersion, .FixedVersion]
    | @tsv
  ' <<<"$scan_json" >&2
  exit 1
fi

if ((unfixed_high > 0 || unfixed_critical > 0)) && \
    [[ "${CONTAINER_SMOKE_ACCEPT_UNFIXED_SHA256:-}" != "$unfixed_sha256" ]]; then
  printf 'container-smoke: unresolved no-fix findings require recorded risk acceptance\n' >&2
  printf '%s\n' "$unfixed_inventory" >&2
  printf 'container-smoke: unresolved inventory sha256=%s\n' "$unfixed_sha256" >&2
  printf 'container-smoke: rerun with CONTAINER_SMOKE_ACCEPT_UNFIXED_SHA256=%s only after recording this exact review\n' \
    "$unfixed_sha256" >&2
  exit 1
fi

printf 'container-smoke: scan PASS fixable_high=0 fixable_critical=0 accepted_unfixed_high=%s accepted_unfixed_critical=%s accepted_unfixed_sha256=%s\n' \
  "$unfixed_high" "$unfixed_critical" "$unfixed_sha256"

MIX_ENV=test MIX_TEST_PARTITION="$partition" mix ecto.create
database_created=true

runtime_env=(
  --env "DATABASE_URL=ecto://postgres:postgres@host.docker.internal:5432/${database}"
  --env "DATABASE_SSL=false"
  --env "PUBLIC_BASE_URL=http://localhost:4000"
  --env "PORT=4000"
  --env "SECRET_KEY_BASE=ssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssss"
  --env "SESSION_SIGNING_SALT=release-test-salt"
  --env "PUMBLE_CLIENT_ID=release-test-client"
  --env "PUMBLE_CLIENT_SECRET=release-test-client-secret"
  --env "PUMBLE_APP_KEY=release-test-application-key"
  --env "PUMBLE_SIGNING_SECRET=release-test-signing-secret"
  --env "ENCRYPTION_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  --env "ENCRYPTION_KEY_VERSION=1"
)

# Docker Desktop resolves this name automatically. Linux Engine needs the
# explicit host-gateway mapping to reach the PostgreSQL service published on
# the CI runner without sharing the host network namespace.
runtime_network=(
  --add-host "host.docker.internal:host-gateway"
)

runtime_hardening=(
  --read-only
  --tmpfs "/tmp:rw,noexec,nosuid,size=16m"
  --cap-drop ALL
  --security-opt no-new-privileges:true
)

if ! docker run --rm \
    "${runtime_network[@]}" \
    "${runtime_hardening[@]}" \
    "${runtime_env[@]}" \
    "$image" \
    /app/bin/pumble_automation eval '
      <<_digest::binary-size(32)>> = :crypto.hash(:sha256, "container-crypto-probe")
      :ok = :ssl.start()

      options = [
        verify: :verify_peer,
        cacertfile: ~c"/etc/ssl/certs/ca-certificates.crt",
        server_name_indication: ~c"example.com",
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]

      {:ok, socket} = :ssl.connect(~c"example.com", 443, options, 10_000)
      :ok = :ssl.close(socket)
    ' >/dev/null 2>&1; then
  printf 'container-smoke: outbound TLS verification failed\n' >&2
  exit 1
fi

docker run --rm \
  "${runtime_network[@]}" \
  "${runtime_hardening[@]}" \
  "${runtime_env[@]}" \
  "$image" \
  /app/bin/migrate >/dev/null

docker run --detach \
  --name "$container_name" \
  "${runtime_network[@]}" \
  "${runtime_hardening[@]}" \
  "${runtime_env[@]}" \
  --publish 127.0.0.1::4000 \
  "$image" >/dev/null

container_uid=$(docker exec "$container_name" id -u)
[[ "$container_uid" == "10001" ]] || {
  printf 'container-smoke: running process is not UID 10001\n' >&2
  exit 1
}

docker exec "$container_name" /bin/sh -c '
  if touch /app/.write-probe >/dev/null 2>&1; then
    exit 1
  fi
  touch /tmp/write-probe
'

port_binding=$(docker port "$container_name" 4000/tcp | head -n 1)
host_port=${port_binding##*:}

live_code=000
ready_code=000

for _attempt in $(seq 1 60); do
  live_code=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --header 'Host: localhost' "http://127.0.0.1:${host_port}/health/live" 2>/dev/null || true)
  ready_code=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --header 'Host: localhost' "http://127.0.0.1:${host_port}/health/ready" 2>/dev/null || true)

  if [[ "$live_code" == 200 && "$ready_code" == 200 ]]; then
    break
  fi

  if [[ $(docker inspect --format '{{ .State.Running }}' "$container_name") != true ]]; then
    docker logs "$container_name" >&2
    printf 'container-smoke: container stopped before becoming healthy\n' >&2
    exit 1
  fi

  sleep 1
done

[[ "$live_code" == 200 && "$ready_code" == 200 ]] || {
  docker logs "$container_name" >&2
  printf 'container-smoke: health probes did not become ready\n' >&2
  exit 1
}

printf 'container-smoke: PASS image=%s revision=%s uid=10001 read_only=true crypto=verified tls=verified tzdata=present health=200/200\n' \
  "$image" "$git_sha"
