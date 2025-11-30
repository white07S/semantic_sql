#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_REPO="${PROJECT_ROOT}/.offline-m2"
DEFAULT_CONFIG="${PROJECT_ROOT}/docker/etc/config.properties"
GO_OFFLINE_PLUGIN="de.qaware.maven:go-offline-maven-plugin:1.2.8:resolve-dependencies"
MAVEN_PROFILE="exec-jar"

# Runtime Configuration
RUNTIME_DIR="${PROJECT_ROOT}/runtime"
DOWNLOAD_DIR="${RUNTIME_DIR}/downloads"
INSTALL_DIR="${RUNTIME_DIR}/install"

MAVEN_URL="https://dlcdn.apache.org/maven/maven-3/3.9.11/binaries/apache-maven-3.9.11-bin.zip"

# Java URLs
JAVA_URL_LINUX="https://download.java.net/java/GA/jdk21.0.2/f2283984656d49d69e91c558476027ac/13/GPL/openjdk-21.0.2_linux-x64_bin.tar.gz"
JAVA_URL_MAC_ARM64="https://download.java.net/java/GA/jdk21.0.2/f2283984656d49d69e91c558476027ac/13/GPL/openjdk-21.0.2_macos-aarch64_bin.tar.gz"
JAVA_URL_MAC_X64="https://download.java.net/java/GA/jdk21.0.2/f2283984656d49d69e91c558476027ac/13/GPL/openjdk-21.0.2_macos-x64_bin.tar.gz"

MAVEN_ZIP="${DOWNLOAD_DIR}/maven.zip"

log() {
  printf '[%s] %s\n' "$1" "$2"
}

die() {
  log 'ERROR' "$1"
  exit 1
}

cleanup() {
  if [[ -d "$INSTALL_DIR" ]]; then
    log 'INFO' "Cleaning up runtime installations..."
    rm -rf "$INSTALL_DIR"
  fi
}
trap cleanup EXIT

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

setup_runtime() {
  mkdir -p "$DOWNLOAD_DIR"
  # Clean install dir to prevent unzip prompts and ensure clean state
  rm -rf "$INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"

  # Download Maven if missing
  if [[ ! -f "$MAVEN_ZIP" ]]; then
    if [[ "$MODE" == "online" ]]; then
       log 'INFO' "Downloading Maven..."
       curl -L -o "$MAVEN_ZIP" "$MAVEN_URL"
    else
       die "Maven binary not found at $MAVEN_ZIP and we are in offline mode."
    fi
  fi

  # Download Java (Linux - always ensure available for portability)
  JAVA_TAR_LINUX="${DOWNLOAD_DIR}/java-linux-x64.tar.gz"
  if [[ ! -f "$JAVA_TAR_LINUX" ]]; then
     if [[ "$MODE" == "online" ]]; then
         log 'INFO' "Downloading Java (Linux)..."
         curl -L -o "$JAVA_TAR_LINUX" "$JAVA_URL_LINUX"
     elif [[ "$(uname -s)" == "Linux" ]]; then
         die "Java binary for Linux not found at $JAVA_TAR_LINUX and we are in offline mode."
     fi
  fi

  # Determine current OS requirements
  OS="$(uname -s)"
  ARCH="$(uname -m)"
  CURRENT_JAVA_TAR=""

  if [[ "$OS" == "Darwin" ]]; then
    if [[ "$ARCH" == "arm64" ]]; then
       CURRENT_JAVA_TAR="${DOWNLOAD_DIR}/java-mac-arm64.tar.gz"
       CURRENT_JAVA_URL="$JAVA_URL_MAC_ARM64"
    else
       CURRENT_JAVA_TAR="${DOWNLOAD_DIR}/java-mac-x64.tar.gz"
       CURRENT_JAVA_URL="$JAVA_URL_MAC_X64"
    fi
    
    # Download Mac Java if needed
    if [[ ! -f "$CURRENT_JAVA_TAR" ]]; then
        if [[ "$MODE" == "online" ]]; then
            log 'INFO' "Downloading Java (macOS)..."
            curl -L -o "$CURRENT_JAVA_TAR" "$CURRENT_JAVA_URL"
        else
            die "Java binary for macOS not found at $CURRENT_JAVA_TAR and we are in offline mode."
        fi
    fi
  elif [[ "$OS" == "Linux" ]]; then
      CURRENT_JAVA_TAR="$JAVA_TAR_LINUX"
  else
      die "Unsupported OS: $OS"
  fi

  # Extract Maven
  log 'INFO' "Extracting Maven..."
  unzip -q "$MAVEN_ZIP" -d "$INSTALL_DIR"
  MAVEN_HOME_DIR="$(find "$INSTALL_DIR" -maxdepth 1 -type d -name "apache-maven*")"
  
  # Extract Java
  log 'INFO' "Extracting Java..."
  tar -xzf "$CURRENT_JAVA_TAR" -C "$INSTALL_DIR"
  JAVA_HOME_DIR="$(find "$INSTALL_DIR" -maxdepth 1 -type d -name "jdk*")"
  
  if [[ "$OS" == "Darwin" ]] && [[ -d "$JAVA_HOME_DIR/Contents/Home" ]]; then
    JAVA_HOME_DIR="$JAVA_HOME_DIR/Contents/Home"
  fi

  # Set Environment
  export JAVA_HOME="$JAVA_HOME_DIR"
  export PATH="$MAVEN_HOME_DIR/bin:$JAVA_HOME/bin:$PATH"
  
  log 'INFO' "Using Java from: $JAVA_HOME"
  log 'INFO' "Using Maven from: $MAVEN_HOME_DIR"
  
  # Verify
  java -version
  mvn -version
}

setup_runtime

mkdir -p "$LOCAL_REPO"

MAVEN_ARGS=(-Dmaven.repo.local="$LOCAL_REPO" -P "$MAVEN_PROFILE" -DskipTests)

if [[ "$MODE" == 'online' ]]; then
  log 'INFO' 'Resolving dependencies for offline use'
  mvn "${MAVEN_ARGS[@]}" "$GO_OFFLINE_PLUGIN"
  mvn "${MAVEN_ARGS[@]}" dependency:go-offline
  log 'INFO' 'Building executable jar (online)'
  mvn "${MAVEN_ARGS[@]}" clean install
else
  log 'INFO' 'Offline build using cached repository'
  mvn -o "${MAVEN_ARGS[@]}" install
fi

JAR_PATH="$(ls -1t "${PROJECT_ROOT}"/wren-server/target/wren-server-*-executable.jar 2>/dev/null | head -n1 || true)"
[[ -n "$JAR_PATH" ]] || die 'Unable to locate the executable jar in wren-server/target'

if [[ ! -f "$CONFIG_FILE" ]]; then
  die "Config file not found at ${CONFIG_FILE}"
fi

JAVA_BIN="${JAVA_HOME}/bin/java"

CMD=("$JAVA_BIN" "-Dconfig=${CONFIG_FILE}" '--add-opens=java.base/java.nio=ALL-UNNAMED' '-jar' "$JAR_PATH")
if [[ ${#JAVA_ARGS[@]} -gt 0 ]]; then
  CMD+=("${JAVA_ARGS[@]}")
fi

log 'INFO' "Starting server from ${JAR_PATH}"
"${CMD[@]}"
