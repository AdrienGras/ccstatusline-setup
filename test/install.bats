#!/usr/bin/env bats
# Comportement de install.sh.

load test_helper

setup() { setup_fake_home; }

# --- détection ---------------------------------------------------------------

@test "détecte ccstatusline dans le préfixe privé ~/.claude/tools" {
    local expected; expected="$(fake_ccstatusline)"
    run "$INSTALL"
    [ "$status" -eq 0 ]
    [ "$(json_get "$(claude_settings)" .statusLine.command)" = "$expected" ]
}

@test "détecte ccstatusline via le PATH quand il n'est pas dans un préfixe connu" {
    local bin; bin="$(fake_ccstatusline 2.2.19 "$HOME/ailleurs")"
    PATH="$(dirname "$bin"):$PATH" run "$INSTALL"
    [ "$status" -eq 0 ]
    [ "$(json_get "$(claude_settings)" .statusLine.command)" = "$bin" ]
}

@test "échoue proprement quand ccstatusline est introuvable et qu'il n'y a pas de terminal" {
    PATH="/usr/bin:/bin" run "$INSTALL" < /dev/null
    [ "$status" -ne 0 ]
}

# --- validation du binaire ---------------------------------------------------

@test "rejette un --path inexistant" {
    fake_ccstatusline > /dev/null
    run "$INSTALL" --path "$HOME/nexistepas"
    [ "$status" -ne 0 ]
}

@test "rejette un exécutable qui sort en 0 mais n'est pas ccstatusline" {
    fake_ccstatusline > /dev/null
    run "$INSTALL" --path /bin/true
    [ "$status" -ne 0 ]
}

@test "rejette un fichier bien nommé qui ne s'exécute pas correctement" {
    fake_ccstatusline > /dev/null
    local broken="$HOME/casse/ccstatusline"
    mkdir -p "$(dirname "$broken")"
    printf '#!/bin/sh\nexit 3\n' > "$broken"
    chmod +x "$broken"
    run "$INSTALL" --path "$broken"
    [ "$status" -ne 0 ]
}

@test "accepte un binaire atteint par lien symbolique" {
    fake_ccstatusline > /dev/null
    local link="$HOME/.local/bin/ccstatusline"
    mkdir -p "$(dirname "$link")"
    ln -sf "$HOME/.claude/tools/bin/ccstatusline" "$link"
    run "$INSTALL" --path "$link"
    [ "$status" -eq 0 ]
    [ "$(json_get "$(claude_settings)" .statusLine.command)" = "$link" ]
}

@test "--path développe le ~ de tête" {
    local expected; expected="$(fake_ccstatusline)"
    run "$INSTALL" --path '~/.claude/tools/bin/ccstatusline'
    [ "$status" -eq 0 ]
    [ "$(json_get "$(claude_settings)" .statusLine.command)" = "$expected" ]
}

# --- configuration installée -------------------------------------------------

@test "le marqueur __HOME__ est substitué par le HOME réel" {
    fake_ccstatusline > /dev/null
    run "$INSTALL"
    [ "$status" -eq 0 ]
    run grep -c "__HOME__" "$(ccsl_settings)"
    [ "$status" -ne 0 ]
}

@test "les commandPath pointent vers les scripts installés" {
    fake_ccstatusline > /dev/null
    "$INSTALL" > /dev/null
    local first
    first="$(json_get "$(ccsl_settings)" '[.lines[][]? | select(.type=="custom-command") | .commandPath][0]')"
    [ "$first" = "$XDG_CONFIG_HOME/ccstatusline/context-bar.py" ]
}

@test "les scripts installés sont exécutables" {
    fake_ccstatusline > /dev/null
    "$INSTALL" > /dev/null
    [ -x "$XDG_CONFIG_HOME/ccstatusline/context-bar.py" ]
    [ -x "$XDG_CONFIG_HOME/ccstatusline/burn-bar.py" ]
}

@test "la configuration installée est un JSON valide" {
    fake_ccstatusline > /dev/null
    "$INSTALL" > /dev/null
    run jq empty "$(ccsl_settings)"
    [ "$status" -eq 0 ]
}

# --- fusion non destructive --------------------------------------------------

@test "les autres clés de ~/.claude/settings.json sont préservées" {
    fake_ccstatusline > /dev/null
    mkdir -p "$HOME/.claude"
    echo '{"model":"opus","enabledPlugins":{"foo":true}}' > "$(claude_settings)"
    "$INSTALL" > /dev/null
    [ "$(json_get "$(claude_settings)" .model)" = "opus" ]
    [ "$(json_get "$(claude_settings)" .enabledPlugins.foo)" = "true" ]
}

@test "une statusLine préexistante est remplacée" {
    local expected; expected="$(fake_ccstatusline)"
    mkdir -p "$HOME/.claude"
    echo '{"statusLine":{"type":"command","command":"/ancien"}}' > "$(claude_settings)"
    "$INSTALL" > /dev/null
    [ "$(json_get "$(claude_settings)" .statusLine.command)" = "$expected" ]
}

@test "refuse d'écrire si ~/.claude/settings.json n'est pas du JSON valide" {
    fake_ccstatusline > /dev/null
    mkdir -p "$HOME/.claude"
    echo 'pas du json {{{' > "$(claude_settings)"
    run "$INSTALL"
    [ "$status" -ne 0 ]
}

# --- sauvegardes et idempotence ----------------------------------------------

@test "une sauvegarde est créée avant d'écraser un fichier existant" {
    fake_ccstatusline > /dev/null
    "$INSTALL" > /dev/null
    "$INSTALL" > /dev/null
    run bash -c 'ls "$HOME"/.claude/settings.json.bak-* 2>/dev/null | wc -l'
    [ "$output" -ge 1 ]
}

@test "un second passage laisse une configuration valide" {
    fake_ccstatusline > /dev/null
    "$INSTALL" > /dev/null
    run "$INSTALL"
    [ "$status" -eq 0 ]
    run jq empty "$(ccsl_settings)"
    [ "$status" -eq 0 ]
}

# --- version -----------------------------------------------------------------

@test "avertit sur une version différente sans bloquer l'installation" {
    fake_ccstatusline 9.9.9 > /dev/null
    run "$INSTALL"
    [ "$status" -eq 0 ]
    [[ "$output" == *"9.9.9"* ]]
    run jq empty "$(ccsl_settings)"
    [ "$status" -eq 0 ]
}

# --- dry-run -----------------------------------------------------------------

@test "--dry-run n'écrit rien" {
    fake_ccstatusline > /dev/null
    run "$INSTALL" --dry-run
    [ "$status" -eq 0 ]
    [ ! -f "$(ccsl_settings)" ]
    [ ! -f "$(claude_settings)" ]
}

# --- boucle interactive ------------------------------------------------------

@test "la boucle redemande après un chemin invalide puis accepte le bon" {
    if ! command -v script > /dev/null 2>&1; then
        skip "la commande 'script' (pty) est absente"
    fi
    local good; good="$(fake_ccstatusline 2.2.19 "$HOME/cache")"
    printf '/tmp/nexistepas\n%s\n' "$good" > "$BATS_TEST_TMPDIR/replies"

    PATH="/usr/bin:/bin" run_in_pty "'$INSTALL'" \
        < "$BATS_TEST_TMPDIR/replies" > "$BATS_TEST_TMPDIR/out" 2>&1

    grep -q "n'existe pas" "$BATS_TEST_TMPDIR/out"
    [ "$(json_get "$(claude_settings)" .statusLine.command)" = "$good" ]
}
