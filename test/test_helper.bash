#!/usr/bin/env bash
# Aides communes aux suites bats.

# shellcheck disable=SC2034  # consommées par les fichiers .bats
REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"
CONFIG_DIR="$REPO_ROOT/config"

# Chaque test travaille dans un HOME jetable : le HOME réel n'est jamais touché.
setup_fake_home() {
    HOME="$BATS_TEST_TMPDIR/home"
    XDG_CONFIG_HOME="$HOME/.config"
    mkdir -p "$HOME"
    export HOME XDG_CONFIG_HOME
}

# Pose un faux ccstatusline disposé comme une vraie installation
# (<prefix>/bin + <prefix>/lib/node_modules) et renvoie son chemin.
fake_ccstatusline() { # [version] [prefix]
    local version="${1:-2.2.19}"
    local prefix="${2:-$HOME/.claude/tools}"

    mkdir -p "$prefix/bin" "$prefix/lib/node_modules/ccstatusline"
    cat > "$prefix/bin/ccstatusline" <<'FAKE'
#!/bin/sh
# se comporte comme ccstatusline : consomme stdin, écrit une ligne
cat > /dev/null
echo "statusline"
FAKE
    chmod +x "$prefix/bin/ccstatusline"
    printf '{"name":"ccstatusline","version":"%s"}\n' "$version" \
        > "$prefix/lib/node_modules/ccstatusline/package.json"
    printf '%s\n' "$prefix/bin/ccstatusline"
}

claude_settings() { printf '%s\n' "$HOME/.claude/settings.json"; }
ccsl_settings()   { printf '%s\n' "$XDG_CONFIG_HOME/ccstatusline/settings.json"; }

# Valeur d'une clé dans un JSON, ou chaîne vide.
json_get() { jq -r "$2 // empty" "$1" 2>/dev/null; }

# Exécute une commande dans un pseudo-terminal, en lui injectant un fichier de
# réponses. Voir test/pty_run.py pour la raison de ne pas utiliser `script`.
run_in_pty() { # fichier-de-réponses, commande [args...]
    python3 "$(dirname "${BATS_TEST_FILENAME}")/pty_run.py" "$@"
}
