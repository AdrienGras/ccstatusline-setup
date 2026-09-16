#!/usr/bin/env bash
#
# Installe la configuration ccstatusline (statusline Claude Code) de ce dépôt.
# Compatible macOS et Linux. Idempotent : relançable sans dommage.
#
# Usage :
#   ./install.sh                     # détection automatique, prompt si introuvable
#   ./install.sh --path /chemin/bin  # chemin explicite (non interactif)
#   ./install.sh --dry-run           # montre ce qui serait fait

set -eu

EXPECTED_VERSION="2.2.19"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$REPO_DIR/config"
DEST_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ccstatusline"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
STAMP="$(date +%Y%m%d-%H%M%S)"

CC_PATH=""
DRY_RUN=0

# --- sortie -----------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
    C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''; C_OFF=''
fi

info()  { printf '%s\n' "$*"; }
ok()    { printf '%s✓%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn()  { printf '%s!%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()   { printf '%s✗%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }
dim()   { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }

run() {
    if [ "$DRY_RUN" -eq 1 ]; then dim "  [dry-run] $*"; else "$@"; fi
}

# --- arguments --------------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        --path)     [ $# -ge 2 ] || die "--path attend un argument"; CC_PATH="$2"; shift 2 ;;
        --path=*)   CC_PATH="${1#--path=}"; shift ;;
        --dry-run)  DRY_RUN=1; shift ;;
        -h|--help)  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          die "argument inconnu : $1" ;;
    esac
done

# --- prérequis --------------------------------------------------------------

for tool in jq python3; do
    command -v "$tool" >/dev/null 2>&1 || die "prérequis manquant : $tool"
done

# --- résolution de ccstatusline ---------------------------------------------

# Développe un ~ de tête et retire les guillemets d'un copier-coller.
expand_path() {
    _p="$1"
    _p="${_p%\"}"; _p="${_p#\"}"
    _p="${_p%\'}"; _p="${_p#\'}"
    # shellcheck disable=SC2088  # motif de case : le tilde doit rester littéral
    case "$_p" in
        "~")   printf '%s\n' "$HOME" ;;
        "~/"*) printf '%s\n' "$HOME/${_p#\~/}" ;;
        *)     printf '%s\n' "$_p" ;;
    esac
}

# Suit les liens symboliques sans readlink -f, absent des macOS anciens.
resolve_link() {
    _p="$1"; _n=0
    while [ -L "$_p" ] && [ "$_n" -lt 16 ]; do
        _t="$(readlink "$_p")"
        case "$_t" in
            /*) _p="$_t" ;;
            *)  _p="$(dirname "$_p")/$_t" ;;
        esac
        _n=$((_n + 1))
    done
    printf '%s\n' "$_p"
}

# Un binaire est valide s'il porte le bon nom ET s'exécute sur du JSON.
# ccstatusline n'a pas de --version, donc pas de contrôle d'identité direct :
# le seul test d'exécution ne suffit pas (/bin/ls le passerait aussi).
is_ccstatusline() {
    _bin="$1"
    [ -n "$_bin" ] && [ -f "$_bin" ] && [ -x "$_bin" ] || return 1
    case "$_bin$(resolve_link "$_bin")" in
        *ccstatusline*) ;;
        *) return 1 ;;
    esac
    printf '{}' | "$_bin" >/dev/null 2>&1
}

detect_ccstatusline() {
    for _c in \
        "$HOME/.claude/tools/bin/ccstatusline" \
        "$HOME/.bun/bin/ccstatusline" \
        "$HOME/.local/bin/ccstatusline"
    do
        is_ccstatusline "$_c" && { printf '%s\n' "$_c"; return 0; }
    done
    _c="$(command -v ccstatusline 2>/dev/null || true)"
    is_ccstatusline "$_c" && { printf '%s\n' "$_c"; return 0; }
    return 1
}

prompt_for_path() {
    [ -e /dev/tty ] || die "ccstatusline introuvable et pas de terminal : relance avec --path <chemin>"

    {
        echo
        echo "ccstatusline est introuvable aux emplacements habituels."
        echo
        echo "Installe-le, puis indique son chemin :"
        echo "    npm install -g ccstatusline@$EXPECTED_VERSION"
        echo
        echo "Le chemin ressemble à ~/.claude/tools/bin/ccstatusline"
        echo "ou au binaire du préfixe npm (npm config get prefix)/bin/ccstatusline."
        echo "Entrée vide pour abandonner."
        echo
    } >&2

    while :; do
        printf 'Chemin vers ccstatusline : ' >&2
        IFS= read -r _reply < /dev/tty || die "lecture interrompue"
        [ -n "$_reply" ] || die "abandon."

        _reply="$(expand_path "$_reply")"

        if is_ccstatusline "$_reply"; then
            printf '%s\n' "$_reply"
            return 0
        fi

        if [ ! -e "$_reply" ]; then
            warn "ce chemin n'existe pas."
        elif [ -d "$_reply" ]; then
            warn "c'est un dossier — donne le fichier binaire lui-même."
        elif [ ! -x "$_reply" ]; then
            warn "ce fichier n'est pas exécutable (chmod +x ?)."
        else
            warn "ce fichier existe mais ne se comporte pas comme ccstatusline."
        fi
    done
}

if [ -n "$CC_PATH" ]; then
    CC_PATH="$(expand_path "$CC_PATH")"
    is_ccstatusline "$CC_PATH" || die "--path : '$CC_PATH' n'est pas un ccstatusline valide"
    ok "ccstatusline (fourni) : $CC_PATH"
elif CC_PATH="$(detect_ccstatusline)"; then
    ok "ccstatusline détecté : $CC_PATH"
else
    CC_PATH="$(prompt_for_path)"
    ok "ccstatusline validé : $CC_PATH"
fi

# --- contrôle de version (non bloquant) -------------------------------------

# <prefix>/bin/ccstatusline -> <prefix>/lib/node_modules/ccstatusline/package.json
# Disposition identique pour le mode « pinned » et pour un npm global.
installed_version() {
    _prefix="$(dirname "$(dirname "$1")")"
    _pkg="$_prefix/lib/node_modules/ccstatusline/package.json"
    [ -f "$_pkg" ] || return 1
    jq -r '.version // empty' "$_pkg" 2>/dev/null
}

FOUND_VERSION="$(installed_version "$CC_PATH" || true)"
if [ -z "$FOUND_VERSION" ]; then
    dim "  version indéterminée (disposition d'installation inhabituelle) — on continue."
elif [ "$FOUND_VERSION" != "$EXPECTED_VERSION" ]; then
    warn "version $FOUND_VERSION installée, config testée avec $EXPECTED_VERSION."
    warn "Si la statusline s'affiche mal, réinstalle en $EXPECTED_VERSION."
else
    ok "version $FOUND_VERSION"
fi

# --- installation de la configuration ---------------------------------------

backup() {
    [ -e "$1" ] || return 0
    run cp -p "$1" "$1.bak-$STAMP"
    dim "  sauvegarde : $(basename "$1").bak-$STAMP"
}

run mkdir -p "$DEST_DIR"

for script in context-bar.py burn-bar.py; do
    backup "$DEST_DIR/$script"
    run cp "$SRC_DIR/$script" "$DEST_DIR/$script"
    run chmod +x "$DEST_DIR/$script"
done
ok "scripts installés dans $DEST_DIR"

# settings.json : on substitue __HOME__ par le HOME réel.
backup "$DEST_DIR/settings.json"
if [ "$DRY_RUN" -eq 1 ]; then
    dim "  [dry-run] génération de $DEST_DIR/settings.json"
else
    TMP="$(mktemp "${TMPDIR:-/tmp}/ccsl.XXXXXX")"
    # Pas de sed -i : son comportement diffère entre GNU et BSD/macOS.
    sed "s#__HOME__#$HOME#g" "$SRC_DIR/settings.json" > "$TMP"
    jq empty "$TMP" || die "settings.json généré invalide"
    mv "$TMP" "$DEST_DIR/settings.json"
fi
ok "configuration écrite dans $DEST_DIR/settings.json"

# --- branchement dans Claude Code -------------------------------------------

# On fusionne uniquement la clé statusLine : le reste du fichier de
# l'utilisateur (plugins, permissions…) doit rester intact.
run mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
backup "$CLAUDE_SETTINGS"

if [ "$DRY_RUN" -eq 1 ]; then
    dim "  [dry-run] fusion de .statusLine dans $CLAUDE_SETTINGS"
else
    [ -f "$CLAUDE_SETTINGS" ] || printf '{}\n' > "$CLAUDE_SETTINGS"
    jq empty "$CLAUDE_SETTINGS" 2>/dev/null \
        || die "$CLAUDE_SETTINGS n'est pas un JSON valide — corrige-le d'abord"

    TMP="$(mktemp "${TMPDIR:-/tmp}/ccsl.XXXXXX")"
    jq --arg cmd "$CC_PATH" \
       '.statusLine = {type: "command", command: $cmd, padding: 0, refreshInterval: 10}' \
       "$CLAUDE_SETTINGS" > "$TMP"
    mv "$TMP" "$CLAUDE_SETTINGS"
fi
ok "statusLine branchée dans $CLAUDE_SETTINGS"

echo
info "Terminé. Redémarre Claude Code pour voir la statusline."
