#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=${MAILFICIENT_GREENMAIL_BUILD_DIR:-"$ROOT_DIR/build"}
IMAGE=${MAILFICIENT_GREENMAIL_IMAGE:-greenmail/standalone:2.1.13}
CONTAINER_NAME="mailficient-greenmail-qa-$$"
LOG_FILE=$(mktemp /tmp/mailficient-greenmail-qa.XXXXXX.log)
PRELOAD_DIR=$(mktemp -d /tmp/mailficient-greenmail-preload.XXXXXX)
STARTED=0

cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$status" -ne 0 ] && [ "$STARTED" -eq 1 ]; then
    docker logs "$CONTAINER_NAME" >"$LOG_FILE" 2>&1 || true
    printf '%s\n' "GreenMail log: $LOG_FILE" >&2
  else
    rm -f "$LOG_FILE"
  fi
  rm -rf "$PRELOAD_DIR"
  if [ "$STARTED" -eq 1 ]; then
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

PRELOAD_INBOX="$PRELOAD_DIR/large@example.com/INBOX"
mkdir -p "$PRELOAD_INBOX"
# mktemp creates its root as 0700, while the container deliberately runs as a
# non-root user. The read-only fixture mount still needs directory traversal.
chmod 0755 "$PRELOAD_DIR" "$PRELOAD_DIR/large@example.com" "$PRELOAD_INBOX"
message_number=1
while [ "$message_number" -le 751 ]; do
  message_file=$(printf '%s/message-%04d.eml' "$PRELOAD_INBOX" "$message_number")
  {
    printf 'From: Fixture Sender %04d <fixture-%04d@example.test>\r\n' \
      "$message_number" "$message_number"
    printf 'To: large@example.com\r\n'
    printf 'Subject: GreenMail large inbox %04d\r\n' "$message_number"
    printf 'Message-ID: <greenmail-large-%04d@example.test>\r\n' "$message_number"
    printf 'Date: Tue, 25 Aug 2026 12:00:00 +0000\r\n'
    printf 'MIME-Version: 1.0\r\n'
    printf 'Content-Type: text/plain; charset=UTF-8\r\n'
    printf 'Content-Transfer-Encoding: 7bit\r\n\r\n'
    printf 'GreenMail large inbox body %04d\r\n' "$message_number"
  } >"$message_file"
  message_number=$((message_number + 1))
done

command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'Docker is required for the isolated GreenMail qualification.' >&2
  exit 1
}
[ -f "$BUILD_DIR/build.ninja" ] || {
  printf 'No configured build found at %s. Run meson setup first.\n' "$BUILD_DIR" >&2
  exit 1
}

meson compile -C "$BUILD_DIR" greenmail-tests
docker run --detach --rm --name "$CONTAINER_NAME" \
  --publish 127.0.0.1::3465 \
  --publish 127.0.0.1::3993 \
  --publish 127.0.0.1::8080 \
  --volume "$PRELOAD_DIR:/greenmail-preload:ro" \
  --env GREENMAIL_OPTS='-Dgreenmail.setup.test.all -Dgreenmail.hostname=0.0.0.0 -Dgreenmail.users=qa:mailficient-e2e@example.com -Dgreenmail.users.login=email -Dgreenmail.preload.dir=/greenmail-preload' \
  "$IMAGE" >/dev/null
STARTED=1

mapped_port() {
  docker port "$CONTAINER_NAME" "$1/tcp" | sed -n '1s/.*://p'
}

IMAPS_PORT=$(mapped_port 3993)
SMTPS_PORT=$(mapped_port 3465)
API_PORT=$(mapped_port 8080)
if [ -z "$IMAPS_PORT" ] || [ -z "$SMTPS_PORT" ] || [ -z "$API_PORT" ]; then
  printf '%s\n' 'Docker did not publish every GreenMail loopback port.' >&2
  exit 1
fi

attempt=0
while ! curl --fail --silent --show-error \
    "http://127.0.0.1:$API_PORT/api/service/readiness" >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 60 ]; then
    printf '%s\n' 'GreenMail did not become ready within 30 seconds.' >&2
    exit 1
  fi
  sleep 0.5
done

cd "$ROOT_DIR"
if [ -n "${MAILFICIENT_GREENMAIL_TEST_PATH:-}" ]; then
  set -- -p "$MAILFICIENT_GREENMAIL_TEST_PATH"
else
  set --
fi
GSETTINGS_BACKEND=memory \
MAILFICIENT_TEST_GREENMAIL=1 \
MAILFICIENT_TEST_GREENMAIL_IMAPS_PORT="$IMAPS_PORT" \
MAILFICIENT_TEST_GREENMAIL_SMTPS_PORT="$SMTPS_PORT" \
  "$BUILD_DIR/greenmail-tests" "$@"

if [ -n "${MAILFICIENT_GREENMAIL_TEST_PATH:-}" ]; then
  printf 'GreenMail qualification passed: %s\n' "$MAILFICIENT_GREENMAIL_TEST_PATH"
else
  printf '%s\n' 'GreenMail IMAPS/SMTPS/IDLE/draft/send/folder/server-search/reconnect/751-message initial-import qualification passed.'
fi
