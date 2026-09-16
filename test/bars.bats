#!/usr/bin/env bats
# Comportement des deux barres Python.
#
# Règle de fond : une entrée douteuse doit donner une sortie VIDE.
# Un widget vide disparaît de la barre d'état ; une trace d'erreur, elle,
# s'y affiche en toutes lettres à chaque rafraîchissement.

load test_helper

context_bar() { printf '%s' "$1" | python3 "$CONFIG_DIR/context-bar.py"; }
burn_bar()    { printf '%s' "$2" | python3 "$CONFIG_DIR/burn-bar.py" "$1"; }

# Horodatage de reset situé à mi-parcours d'une fenêtre de 5 h.
mid_session_reset() { python3 -c 'import time; print(int(time.time() + 2.5 * 3600))'; }

# --- context-bar : rendu -----------------------------------------------------

@test "context-bar affiche la barre et le ratio" {
    run context_bar '{"context_window":{"context_window_size":200000,"used_percentage":50}}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"100k/200k (50%)"* ]]
}

@test "context-bar somme les trois compteurs de current_usage" {
    run context_bar '{"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":1000,"cache_read_input_tokens":9000,"cache_creation_input_tokens":10000}}}'
    [[ "$output" == *"20k/200k (10%)"* ]]
}

@test "context-bar abrège le million" {
    run context_bar '{"context_window":{"context_window_size":1000000,"used_percentage":14}}'
    [[ "$output" == *"/1M ("* ]]
}

@test "context-bar plafonne l'affichage à 100%" {
    run context_bar '{"context_window":{"context_window_size":200000,"current_usage":400000}}'
    [[ "$output" == *"(100%)"* ]]
}

# --- context-bar : entrées à rejeter -----------------------------------------

@test "context-bar reste vide sans fenêtre de contexte" {
    run context_bar '{}'
    [ -z "$output" ]
}

@test "context-bar reste vide sur un NaN littéral" {
    run context_bar '{"context_window":{"context_window_size":200000,"used_percentage":NaN}}'
    [ -z "$output" ]
}

@test "context-bar reste vide sur un Infinity littéral" {
    run context_bar '{"context_window":{"context_window_size":Infinity,"used_percentage":50}}'
    [ -z "$output" ]
}

@test "context-bar reste vide sur un JSON tronqué" {
    run context_bar '{"context_window":{"cont'
    [ -z "$output" ]
}

@test "context-bar reste vide quand la racine JSON n'est pas un objet" {
    run context_bar '[1,2,3]'
    [ -z "$output" ]
}

@test "context-bar reste vide sur une taille de fenêtre nulle ou négative" {
    run context_bar '{"context_window":{"context_window_size":0,"used_percentage":50}}'
    [ -z "$output" ]
    run context_bar '{"context_window":{"context_window_size":-200000,"used_percentage":50}}'
    [ -z "$output" ]
}

@test "context-bar ne prend pas un booléen pour un compteur de tokens" {
    run context_bar '{"context_window":{"context_window_size":200000,"current_usage":true}}'
    [ -z "$output" ]
}

@test "context-bar accepte un nombre transmis sous forme de texte" {
    run context_bar '{"context_window":{"context_window_size":"200000","used_percentage":"50"}}'
    [[ "$output" == *"(50%)"* ]]
}

# --- burn-bar : rendu --------------------------------------------------------

@test "burn-bar affiche label, pourcentage, projection et reste" {
    run burn_bar session "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":25,\"resets_at\":$(mid_session_reset)}}}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Session"* ]]
    [[ "$output" == *"25%"* ]]
    [[ "$output" == *"→ 50%"* ]]
    [[ "$output" == *"⧗"* ]]
}

@test "burn-bar signale le mur quand le rythme dépasse la fenêtre" {
    run burn_bar session "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":90,\"resets_at\":$(mid_session_reset)}}}"
    [[ "$output" == *"⚠ mur"* ]]
}

@test "burn-bar signale la limite atteinte" {
    run burn_bar session "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":100,\"resets_at\":$(mid_session_reset)}}}"
    [[ "$output" == *"⛔ limite"* ]]
}

@test "burn-bar marque la projection d'un tilde tant que la fenêtre est trop jeune" {
    local reset; reset="$(python3 -c 'import time; print(int(time.time() + 4.9 * 3600))')"
    run burn_bar session "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":5,\"resets_at\":$reset}}}"
    [[ "$output" == *"→ ~"* ]]
}

@test "burn-bar lit la fenêtre hebdomadaire" {
    local reset; reset="$(python3 -c 'import time; print(int(time.time() + 3 * 86400))')"
    run burn_bar weekly "{\"rate_limits\":{\"seven_day\":{\"used_percentage\":40,\"resets_at\":$reset}}}"
    [[ "$output" == *"Weekly"* ]]
}

# --- burn-bar : entrées à rejeter --------------------------------------------

@test "burn-bar reste vide sur une période inconnue" {
    run burn_bar mensuel "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":25,\"resets_at\":$(mid_session_reset)}}}"
    [ -z "$output" ]
}

@test "burn-bar reste vide sans rate_limits" {
    run burn_bar session '{}'
    [ -z "$output" ]
}

@test "burn-bar reste vide sur un used_percentage NaN" {
    run burn_bar session '{"rate_limits":{"five_hour":{"used_percentage":NaN,"resets_at":9999999999}}}'
    [ -z "$output" ]
}

@test "burn-bar reste vide sur un resets_at Infinity" {
    run burn_bar session '{"rate_limits":{"five_hour":{"used_percentage":50,"resets_at":Infinity}}}'
    [ -z "$output" ]
}

@test "burn-bar reste vide sur un resets_at négatif" {
    run burn_bar session '{"rate_limits":{"five_hour":{"used_percentage":50,"resets_at":-5}}}'
    [ -z "$output" ]
}

@test "burn-bar interprète un resets_at en millisecondes" {
    local reset_ms; reset_ms="$(python3 -c 'import time; print(int((time.time() + 2.5 * 3600) * 1000))')"
    run burn_bar session "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":25,\"resets_at\":$reset_ms}}}"
    [[ "$output" == *"→ 50%"* ]]
}

# --- aucune trace d'erreur, jamais -------------------------------------------

@test "aucune des deux barres n'écrit de trace d'erreur sur une entrée hostile" {
    local hostile=(
        '{"context_window":null}'
        '{"context_window":{"context_window_size":{},"used_percentage":[]}}'
        '{"rate_limits":{"five_hour":"pas un objet"}}'
        '{"rate_limits":{"five_hour":{"used_percentage":{},"resets_at":{}}}}'
        'null'
        ''
    )
    for payload in "${hostile[@]}"; do
        run context_bar "$payload"
        [[ "$output" != *Traceback* ]]
        run burn_bar session "$payload"
        [[ "$output" != *Traceback* ]]
    done
}
