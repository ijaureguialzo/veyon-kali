#!/usr/bin/env bash
# veyon-source.sh — checkout ÚNICO y siempre actualizado del repositorio Git
#                    de Veyon.
#
# Todos los procesos de compilación de este proyecto comparten la misma copia
# del repositorio Git de Veyon (build/veyon por defecto):
#
#   * make download-src             → clona/actualiza el checkout y sus submodules
#   * make arm64 / make amd64       → montan ESE checkout (read-only) en Docker
#   * scripts/build-veyon-macos.sh  → copia ESE checkout al workspace de macOS
#                                     y lo actualiza antes de compilar
#   * scripts/regen-*-patch.sh      → generan los parches contra ESE checkout
#
# Uso:
#     scripts/veyon-source.sh path      # imprime la ruta del checkout único
#     scripts/veyon-source.sh update    # clona si falta y lo deja actualizado
#
# Variables de entorno:
#     VEYON_SRC_DIR            ruta del checkout (alias heredado: VEYON_UPSTREAM_DIR).
#                              Las rutas relativas se resuelven contra la raíz
#                              del proyecto.
#     VEYON_REPO_URL           upstream (por defecto https://github.com/veyon/veyon.git)
#     VEYON_BRANCH             rama a mantener actualizada (por defecto, la que
#                              sigue el checkout; si no hay ninguna, la del upstream)
#     VEYON_VERSION            versión (tag, rama o commit) a la que fijar el
#                              checkout; tiene prioridad sobre VEYON_BRANCH.
#                              Puede definirse en el fichero .env de la raíz
#                              del proyecto (no versionado; ver .env.example).
#     VEYON_SOURCE_RESET=1     descarta los cambios locales y vuelve al upstream
#     VEYON_SOURCE_OFFLINE=1   no accede a la red; usa el checkout tal cual

set -euo pipefail

# Ningún comando de este script debe abrir un pager: el script se ejecuta
# desde el Makefile, donde la salida va al terminal, y un "less" bloquearía
# la compilación esperando a que se pulse 'q'.
export GIT_PAGER=cat
export PAGER=cat

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Variables locales opcionales (raíz del proyecto): la versión a compilar
# (VEYON_VERSION), el upstream, la rama, etc.  El fichero .env no está
# versionado (.gitignore); .env.example documenta qué puede contener.  Las
# variables ya presentes en el entorno tienen prioridad sobre el .env.
if [ -f "$PROJECT_DIR/.env" ]; then
    while IFS='=' read -r _env_key _env_value; do
        case "$_env_key" in ''|\#*) continue ;; esac
        _env_key="${_env_key%\#*}"   # tolera comentarios a final de línea
        _env_key="${_env_key#export }"
        _env_key="${_env_key# }"; _env_key="${_env_key% }"
        _env_value="${_env_value%%\#*}"
        _env_value="${_env_value# }"; _env_value="${_env_value% }"
        if ! [[ "$_env_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            continue
        fi
        # las variables ya presentes en el entorno tienen prioridad
        if [ -z "${!_env_key:-}" ]; then
            export "$_env_key=$_env_value"
        fi
    done < "$PROJECT_DIR/.env"
    unset _env_key _env_value
fi

REPO_URL="${VEYON_REPO_URL:-https://github.com/veyon/veyon.git}"

# ── Localización del checkout ──────────────────────────────────────────────
# Las rutas relativas se resuelven contra la raíz del proyecto para que todos
# los procesos (Makefile, scripts de macOS, scripts de parches) acaben
# apuntando al MISMO directorio aunque se invoquen desde sitios distintos.
_raw_src_dir="${VEYON_SRC_DIR:-${VEYON_UPSTREAM_DIR:-$PROJECT_DIR/build/veyon}}"
case "$_raw_src_dir" in
    /*) SRC_DIR="$_raw_src_dir" ;;
    *)  SRC_DIR="$PROJECT_DIR/$_raw_src_dir" ;;
esac

die() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<EOF
Uso: $(basename "${BASH_SOURCE[0]}") <path|update>

  path    imprime la ruta del checkout único de Veyon
  update  clona el repositorio si no existe y lo deja actualizado

Entorno:
  VEYON_SRC_DIR           ruta del checkout (alias heredado: VEYON_UPSTREAM_DIR)
  VEYON_REPO_URL          upstream (por defecto https://github.com/veyon/veyon.git)
  VEYON_BRANCH            rama a mantener actualizada
  VEYON_VERSION           versión/tag a la que fijar el checkout (prioridad
                          sobre VEYON_BRANCH; también desde el fichero .env)
  VEYON_SOURCE_RESET=1    descarta los cambios locales y vuelve al upstream
  VEYON_SOURCE_OFFLINE=1  no accede a la red; usa el checkout tal cual
EOF
}

# ── Estado del checkout ────────────────────────────────────────────────────
# Rama local activa (vacía si HEAD está desligado).
current_branch() {
    git -C "$SRC_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true
}

# Rama por defecto del upstream (origin/HEAD → main).
default_branch() {
    local ref
    ref="$(git -C "$SRC_DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    if [ -n "$ref" ]; then
        printf '%s\n' "${ref#origin/}"
    else
        printf 'main\n'
    fi
}

# Ref remoto al que hay que traer el checkout (origin/<rama>).
remote_ref() {
    printf 'origin/%s\n' "$1"
}

# ── Clonado ────────────────────────────────────────────────────────────────
clone_source() {
    echo "── clonar $REPO_URL ──"
    mkdir -p "$(dirname "$SRC_DIR")"
    git clone --recursive "$REPO_URL" "$SRC_DIR"
}

# ── Actualización ──────────────────────────────────────────────────────────
update_source() {
    command -v git >/dev/null 2>&1 || die "git no está instalado"

    echo "── checkout único: $SRC_DIR ──"

    if [ ! -e "$SRC_DIR" ]; then
        clone_source
    elif [ ! -e "$SRC_DIR/.git" ]; then
        die "$SRC_DIR existe pero no es un checkout de Git"
    fi

    # Rama a mantener al día: la impuesta, la del checkout o la del upstream.
    local branch="${VEYON_BRANCH:-$(current_branch)}"
    if [ -z "$branch" ]; then
        branch="$(default_branch)"
    fi

    if [ "${VEYON_SOURCE_OFFLINE:-0}" = "1" ]; then
        echo "── offline: no se actualiza el checkout ──"
    else
        echo "── fetch $REPO_URL ──"
        git -C "$SRC_DIR" fetch --prune --tags origin \
            || die "no se pudo actualizar el checkout (¿sin red?)"

        if [ -n "${VEYON_VERSION:-}" ]; then
            # Version fijada: el checkout va a ese ref (tag, rama o commit),
            # en modo detached.  Tiene prioridad sobre VEYON_BRANCH.
            git -C "$SRC_DIR" rev-parse --verify --quiet "${VEYON_VERSION}^{commit}" >/dev/null \
                || die "VEYON_VERSION='${VEYON_VERSION}' no existe en el upstream"
            git -C "$SRC_DIR" checkout -f -q "$VEYON_VERSION"
            echo "── fijado a ${VEYON_VERSION} ──"
        else
            local target
            target="$(remote_ref "$branch")"
            git -C "$SRC_DIR" rev-parse --verify --quiet "$target" >/dev/null \
                || die "la rama $target no existe en el upstream"

            if [ "${VEYON_SOURCE_RESET:-0}" = "1" ]; then
                echo "── reset a $target (se descartan los cambios locales) ──"
                git -C "$SRC_DIR" checkout -f -B "$branch" "$target"
                git -C "$SRC_DIR" clean -fd
            else
                if [ -n "$(git -C "$SRC_DIR" status --porcelain)" ]; then
                    echo "   AVISO: hay cambios locales en el checkout; se conservan"
                fi
                git -C "$SRC_DIR" checkout -q "$branch" 2>/dev/null \
                    || git -C "$SRC_DIR" checkout -q -B "$branch" "$target"
                git -C "$SRC_DIR" merge --ff-only "$target" >/dev/null \
                    || die "no se puede actualizar el checkout a $target (¿cambios locales o historia divergente?); usa VEYON_SOURCE_RESET=1 o 'git -C $SRC_DIR reset --hard $target'"
                git -C "$SRC_DIR" branch --set-upstream-to="$target" "$branch" >/dev/null 2>&1 || true

                # El checkout puede llevar commits locales por delante del
                # upstream: no se destruyen, pero se avisa para que quede
                # claro que la copia no es idéntica a la del upstream.
                local ahead
                ahead="$(git -C "$SRC_DIR" rev-list --count "$target..$branch" 2>/dev/null || echo 0)"
                if [ "${ahead:-0}" -gt 0 ]; then
                    echo "   AVISO: el checkout está $ahead commit(s) por delante de $target"
                fi
            fi
        fi
    fi

    echo "── submodules ──"
    git -C "$SRC_DIR" submodule sync --recursive >/dev/null
    git -C "$SRC_DIR" submodule update --init --recursive

    echo "── estado ──"
    if [ -n "${VEYON_VERSION:-}" ]; then
        echo "    versión pedida: ${VEYON_VERSION}"
    fi
    git --no-pager -C "$SRC_DIR" log -1 --format='    %h %ad %s' --date=short
    git --no-pager -C "$SRC_DIR" status -sb | head -1 | sed 's/^/    /'
}

# ── CLI ────────────────────────────────────────────────────────────────────
case "${1:-}" in
    path)
        printf '%s\n' "$SRC_DIR"
        ;;
    update)
        update_source
        ;;
    ""|help|-h|--help)
        usage
        ;;
    *)
        echo "Opción desconocida: $1" >&2
        usage >&2
        exit 2
        ;;
esac
