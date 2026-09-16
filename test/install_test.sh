#!/usr/bin/env bash
#
# Tests de install.sh. Chaque cas tourne dans un HOME jetable :
# le HOME réel n'est jamais touché.

set -u

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$REPO_DIR/install.sh"
PASS=0; FAIL=0

pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ $# -ge 2 ] && printf '       %s\n' "$2"; FAIL=$((FAIL + 1)); }

check() { # description, attendu, obtenu
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "attendu '$2', obtenu '$3'"; fi
}

# Crée un faux HOME contenant une installation ccstatusline factice,
# disposée comme une vraie (prefix/bin + prefix/lib/node_modules).
new_home() { # version
    _h="$(mktemp -d "${TMPDIR:-/tmp}/ccsl-test.XXXXXX")"
    _prefix="$_h/.claude/tools"
    mkdir -p "$_prefix/bin" "$_prefix/lib/node_modules/ccstatusline"
    cat > "$_prefix/bin/ccstatusline" <<'FAKE'
#!/bin/sh
# se comporte comme ccstatusline : consomme stdin, écrit une ligne
cat > /dev/null
echo "statusline"
FAKE
    chmod +x "$_prefix/bin/ccstatusline"
    printf '{"name":"ccstatusline","version":"%s"}\n' "${1:-2.2.19}" \
        > "$_prefix/lib/node_modules/ccstatusline/package.json"
    printf '%s\n' "$_h"
}

echo
echo "install.sh"
echo

# --- détection automatique ---------------------------------------------------

H="$(new_home)"
OUT="$(HOME="$H" XDG_CONFIG_HOME="$H/.config" "$INSTALL" 2>&1)"
check "détecte ccstatusline dans le préfixe privé ~/.claude/tools" 0 $?

CFG="$H/.config/ccstatusline/settings.json"
if [ -f "$CFG" ]; then pass "settings.json installé"; else fail "settings.json installé"; fi

if grep -q "__HOME__" "$CFG" 2>/dev/null; then
    fail "le placeholder __HOME__ est substitué" "il reste des __HOME__"
else
    pass "le placeholder __HOME__ est substitué"
fi

check "les commandPath pointent vers le HOME réel" \
    "$H/.config/ccstatusline/context-bar.py" \
    "$(jq -r '[.lines[][]? | select(.type=="custom-command") | .commandPath][0]' "$CFG" 2>/dev/null)"

if [ -x "$H/.config/ccstatusline/burn-bar.py" ]; then
    pass "les scripts sont exécutables"
else
    fail "les scripts sont exécutables"
fi

check "statusLine.command pointe vers le binaire résolu" \
    "$H/.claude/tools/bin/ccstatusline" \
    "$(jq -r '.statusLine.command' "$H/.claude/settings.json" 2>/dev/null)"

# --- fusion non destructive --------------------------------------------------

H="$(new_home)"
mkdir -p "$H/.claude"
cat > "$H/.claude/settings.json" <<'EOF'
{"model": "opus", "enabledPlugins": {"foo": true}, "statusLine": {"type": "command", "command": "/ancien"}}
EOF
HOME="$H" XDG_CONFIG_HOME="$H/.config" "$INSTALL" >/dev/null 2>&1

check "les autres clés de settings.json sont préservées" \
    "opus" "$(jq -r '.model' "$H/.claude/settings.json")"
check "enabledPlugins est préservé" \
    "true" "$(jq -r '.enabledPlugins.foo' "$H/.claude/settings.json")"
check "l'ancienne statusLine est remplacée" \
    "$H/.claude/tools/bin/ccstatusline" \
    "$(jq -r '.statusLine.command' "$H/.claude/settings.json")"

# --- idempotence -------------------------------------------------------------

HOME="$H" XDG_CONFIG_HOME="$H/.config" "$INSTALL" >/dev/null 2>&1
check "second passage : exit 0" 0 $?
check "second passage : config toujours valide" \
    "true" "$(jq -e . "$H/.config/ccstatusline/settings.json" >/dev/null 2>&1 && echo true)"
if ls "$H/.claude/settings.json.bak-"* >/dev/null 2>&1; then
    pass "une sauvegarde est créée avant écrasement"
else
    fail "une sauvegarde est créée avant écrasement"
fi

# --- échecs attendus ---------------------------------------------------------

H="$(mktemp -d "${TMPDIR:-/tmp}/ccsl-test.XXXXXX")"   # aucun ccstatusline
HOME="$H" XDG_CONFIG_HOME="$H/.config" PATH="/usr/bin:/bin" \
    "$INSTALL" </dev/null >/dev/null 2>&1
if [ $? -ne 0 ]; then
    pass "échoue proprement quand ccstatusline est introuvable sans terminal"
else
    fail "échoue proprement quand ccstatusline est introuvable sans terminal"
fi

H="$(new_home)"
HOME="$H" XDG_CONFIG_HOME="$H/.config" "$INSTALL" --path /bin/ls >/dev/null 2>&1
if [ $? -ne 0 ]; then
    pass "rejette un --path qui n'est pas ccstatusline"
else
    fail "rejette un --path qui n'est pas ccstatusline"
fi

H="$(new_home)"
HOME="$H" XDG_CONFIG_HOME="$H/.config" "$INSTALL" --path "$H/nexistepas" >/dev/null 2>&1
if [ $? -ne 0 ]; then
    pass "rejette un --path inexistant"
else
    fail "rejette un --path inexistant"
fi

# --- validation d'identité ---------------------------------------------------

H="$(new_home)"
HOME="$H" XDG_CONFIG_HOME="$H/.config" "$INSTALL" --path /bin/true >/dev/null 2>&1
if [ $? -ne 0 ]; then
    pass "rejette un exécutable qui sort en 0 mais n'est pas ccstatusline"
else
    fail "rejette un exécutable qui sort en 0 mais n'est pas ccstatusline"
fi

H="$(new_home)"
BROKEN="$H/bin-casse/ccstatusline"
mkdir -p "$(dirname "$BROKEN")"
printf '#!/bin/sh\nexit 3\n' > "$BROKEN"; chmod +x "$BROKEN"
HOME="$H" XDG_CONFIG_HOME="$H/.config" "$INSTALL" --path "$BROKEN" >/dev/null 2>&1
if [ $? -ne 0 ]; then
    pass "rejette un fichier bien nommé qui ne s'exécute pas correctement"
else
    fail "rejette un fichier bien nommé qui ne s'exécute pas correctement"
fi

# Cas réel : le binaire est un lien symbolique vers dist/ccstatusline.js.
H="$(new_home)"
LINKED="$H/.local/bin/ccstatusline"
mkdir -p "$(dirname "$LINKED")"
ln -sf "$H/.claude/tools/bin/ccstatusline" "$LINKED"
HOME="$H" XDG_CONFIG_HOME="$H/.config" "$INSTALL" --path "$LINKED" >/dev/null 2>&1
check "accepte un binaire atteint par lien symbolique" \
    "$LINKED" "$(jq -r '.statusLine.command' "$H/.claude/settings.json" 2>/dev/null)"

# --- --path explicite et ~ --------------------------------------------------

H="$(new_home)"
HOME="$H" XDG_CONFIG_HOME="$H/.config" \
    "$INSTALL" --path '~/.claude/tools/bin/ccstatusline' >/dev/null 2>&1
check "--path développe le ~ de tête" \
    "$H/.claude/tools/bin/ccstatusline" \
    "$(jq -r '.statusLine.command' "$H/.claude/settings.json" 2>/dev/null)"

# --- avertissement de version ------------------------------------------------

H="$(new_home 9.9.9)"
OUT="$(HOME="$H" XDG_CONFIG_HOME="$H/.config" "$INSTALL" 2>&1)"
if printf '%s' "$OUT" | grep -q "9.9.9"; then
    pass "avertit sur une version différente sans bloquer"
else
    fail "avertit sur une version différente sans bloquer"
fi
check "l'avertissement de version ne bloque pas l'installation" \
    "true" "$(jq -e . "$H/.config/ccstatusline/settings.json" >/dev/null 2>&1 && echo true)"

# --- dry-run -----------------------------------------------------------------

H="$(new_home)"
HOME="$H" XDG_CONFIG_HOME="$H/.config" "$INSTALL" --dry-run >/dev/null 2>&1
if [ -f "$H/.config/ccstatusline/settings.json" ]; then
    fail "--dry-run n'écrit rien"
else
    pass "--dry-run n'écrit rien"
fi

# --- boucle interactive (nécessite un pty) ----------------------------------

if command -v script >/dev/null 2>&1; then
    H="$(mktemp -d "${TMPDIR:-/tmp}/ccsl-test.XXXXXX")"
    GOOD="$(new_home)/.claude/tools/bin/ccstatusline"
    # d'abord un mauvais chemin, puis le bon : la boucle doit redemander
    printf '/tmp/nexistepas\n%s\n' "$GOOD" > "$H/replies"
    HOME="$H" XDG_CONFIG_HOME="$H/.config" \
        script -qec "'$INSTALL'" /dev/null < "$H/replies" > "$H/out" 2>&1
    if grep -q "n'existe pas" "$H/out" 2>/dev/null \
       && [ "$(jq -r '.statusLine.command' "$H/.claude/settings.json" 2>/dev/null)" = "$GOOD" ]; then
        pass "la boucle redemande après un chemin invalide puis accepte le bon"
    else
        fail "la boucle redemande après un chemin invalide puis accepte le bon" \
             "$(tail -3 "$H/out" 2>/dev/null | tr '\n' ' ')"
    fi
else
    printf '  \033[2mskip\033[0m boucle interactive (commande "script" absente)\n'
fi

echo
printf '%d ok, %d échec(s)\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
