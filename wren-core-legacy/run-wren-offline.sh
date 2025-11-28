#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MVNW="${PROJECT_ROOT}/mvnw"
LOCAL_REPO="${PROJECT_ROOT}/.offline-m2"
DEFAULT_CONFIG="${PROJECT_ROOT}/docker/etc/config.properties"
GO_OFFLINE_PLUGIN="de.qaware.maven:go-offline-maven-plugin:1.2.8:resolve-dependencies"
MAVEN_PROFILE="exec-jar"

log() {
  printf '[%s] %s\n' "$1" "$2"
}

die() {
  log 'ERROR' "$1"
  exit 1
}

if [[ ! -x "$MVNW" ]]; then
  die "Cannot find executable Maven wrapper at $MVNW"
fi

CONFIG_FILE="$DEFAULT_CONFIG"
MODE_OVERRIDE=""
JAVA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || die "--config expects a path argument"
      CONFIG_FILE="$2"
      shift 2
      ;;
    --offline)
      MODE_OVERRIDE='offline'
      shift
      ;;
    --online)
      MODE_OVERRIDE='online'
      shift
      ;;
    --java-arg)
      [[ $# -ge 2 ]] || die "--java-arg expects a value"
      JAVA_ARGS+=("$2")
      shift 2
      ;;
    --help|-h)
      cat <<'USAGE'
Usage: ./run-wren-offline.sh [options] [-- extra-java-args]

Options:
  --config <path>   Override path to config.properties (default: docker/etc/config.properties)
  --offline         Force offline mode (skip network probe)
  --online          Force online mode
  --java-arg <arg>  Append an explicit argument to the java command
  --help            Show this help

Any remaining arguments after '--' are forwarded to the java process.
USAGE
      exit 0
      ;;
    --)
      shift
      JAVA_ARGS+=("$@")
      break
      ;;
    *)
      JAVA_ARGS+=("$1")
      shift
      ;;
  esac
done

detect_mode() {
  if [[ "$MODE_OVERRIDE" == 'online' ]]; then
    echo 'online'
    return
  elif [[ "$MODE_OVERRIDE" == 'offline' ]]; then
    echo 'offline'
    return
  fi

  if command -v curl >/dev/null 2>&1; then
    if curl -sSf --max-time 3 https://repo.maven.apache.org/maven2/ >/dev/null 2>&1; then
      echo 'online'
    else
      echo 'offline'
    fi
  else
    log 'WARN' 'curl not found; assuming offline mode'
    echo 'offline'
  fi
}

MODE="$(detect_mode)"
log 'INFO' "Detected mode: $MODE"

mkdir -p "$LOCAL_REPO"

MAVEN_ARGS=(-Dmaven.repo.local="$LOCAL_REPO" -P "$MAVEN_PROFILE" -DskipTests)

if [[ "$MODE" == 'online' ]]; then
  log 'INFO' 'Resolving dependencies for offline use'
  "$MVNW" "${MAVEN_ARGS[@]}" "$GO_OFFLINE_PLUGIN"
  "$MVNW" "${MAVEN_ARGS[@]}" dependency:go-offline
  log 'INFO' 'Building executable jar (online)'
  "$MVNW" "${MAVEN_ARGS[@]}" clean install
else
  log 'INFO' 'Offline build using cached repository'
  "$MVNW" -o "${MAVEN_ARGS[@]}" install
fi

JAR_PATH="$(ls -1t "${PROJECT_ROOT}"/wren-server/target/wren-server-*-executable.jar 2>/dev/null | head -n1 || true)"
[[ -n "$JAR_PATH" ]] || die 'Unable to locate the executable jar in wren-server/target'

if [[ ! -f "$CONFIG_FILE" ]]; then
  die "Config file not found at ${CONFIG_FILE}"
fi

JAVA_BIN="${JAVA_HOME:+${JAVA_HOME}/bin/}java"
JAVA_BIN="${JAVA_BIN:-java}"

CMD=("$JAVA_BIN" "-Dconfig=${CONFIG_FILE}" '--add-opens=java.base/java.nio=ALL-UNNAMED' '-jar' "$JAR_PATH")
if [[ ${#JAVA_ARGS[@]} -gt 0 ]]; then
  CMD+=("${JAVA_ARGS[@]}")
fi

log 'INFO' "Starting server from ${JAR_PATH}"
exec "${CMD[@]}"
