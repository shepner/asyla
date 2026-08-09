# shellcheck shell=bash
# Source from app scripts: native docker image build for the host CPU (no cross-arch surprises).
# Requires: docker; buildx optional (preferred when present).

docker_native_platform() {
  case "$(uname -m)" in
    x86_64 | amd64) printf '%s' 'linux/amd64' ;;
    aarch64 | arm64) printf '%s' 'linux/arm64' ;;
    armv7l) printf '%s' 'linux/arm/v7' ;;
    *)
      echo "[ERROR] Unsupported host architecture: $(uname -m)" >&2
      return 1
      ;;
  esac
}

docker_native_build() {
  # Usage: docker_native_build <image_tag> <source_dir_with_Dockerfile> [extra buildx args...]
  local tag="$1"
  local src="$2"
  shift 2
  local platform version

  if [ ! -f "$src/Dockerfile" ]; then
    echo "[ERROR] No Dockerfile in $src" >&2
    return 1
  fi

  platform="$(docker_native_platform)" || return 1
  version="dev"
  if command -v git >/dev/null 2>&1 && git -C "$src" rev-parse --is-inside-work-tree &>/dev/null; then
    version="$(git -C "$src" rev-parse --short HEAD 2>/dev/null || echo dev)"
  fi

  echo "[INFO] Building $tag for $platform (from $src, version=$version)"

  if docker buildx version &>/dev/null 2>&1; then
    docker buildx build \
      --platform "$platform" \
      --build-arg "AGENT_COMMONS_APP_VERSION=$version" \
      -t "$tag" \
      --load \
      "$@" \
      "$src"
  else
    # Plain docker build: image arch must match host (no cross-compile)
    docker build \
      --build-arg "AGENT_COMMONS_APP_VERSION=$version" \
      -t "$tag" \
      "$@" \
      "$src"
  fi
}
