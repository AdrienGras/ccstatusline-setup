#!/usr/bin/env python3
"""Barre de contexte pour ccstatusline (widget custom-command).

Remplace le widget natif "context-bar", dont les caracteres ▓/░ sont codes en dur.
Lit sur stdin le JSON de statusline de Claude Code ; n'affiche rien si le contexte
est absent (demarrage, preview), ce qui masque le widget comme le faisait l'original.

Rendu : ▕███▊      ▏ 140k/1M (14%)
  - remplissage au 1/8 de cellule pres (pas de saut par crans de 10 %)
  - couleur unie sur toute la barre, qui evolue vert -> jaune -> rouge
    selon le taux de remplissage (comme les barres de burn-bar.py)
  - pas de caractere de fond : la partie vide est vide

Toute entree invalide donne une sortie vide plutot qu'une trace d'erreur :
ce script ecrit dans une barre d'etat, pas dans un terminal que l'on lit.
Poser CCSL_DEBUG=1 pour faire remonter les exceptions pendant une mise au point.
"""
import json
import math
import os
import sys

WIDTH = 10
LABEL = "Context: "  # mettre "" pour n'afficher que la barre
CAP_L = "│"          # delimiteurs ; alternatives : "▕"/"▏" "[" "]" "" (aucun)
CAP_R = "│"           # NB: eviter "▏" a droite, identique au remplissage 1/8
PARTIALS = "▏▎▍▌▋▊▉"  # 1/8 .. 7/8
FULL = "█"

MILLION = 1_000_000

CAP_COLOR = (0x63, 0x67, 0x6F)   # brogrammer color8
TEXT_COLOR = (0x82, 0x86, 0x8F)  # brogrammer inactive_tab_foreground

# Teinte pilotee par le taux de remplissage : vert -> jaune -> rouge (brogrammer)
STOPS = [(0.00, (0x2C, 0xC5, 0x5D)),
         (0.50, (0xEC, 0xB9, 0x0F)),
         (0.80, (0xDE, 0x34, 0x2E)),
         (1.00, (0xF7, 0x11, 0x18))]

USAGE_FIELDS = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")


def finite(value):
    """Convertit en float fini, ou None.

    Rejette None, les booleens (sinon True vaudrait 1 token), les types non
    numeriques, et surtout NaN / Infinity : le module json les accepte par
    defaut, et ils traversent les comparaisons sans erreur jusqu'a faire
    echouer int() beaucoup plus loin.
    """
    if value is None or isinstance(value, bool):
        return None
    if not isinstance(value, (int, float, str)):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def load_statusline(stream):
    """Objet JSON de statusline, ou None si l'entree est inexploitable."""
    def reject(name):
        raise ValueError(f"constante non numerique refusee : {name}")

    try:
        data = json.load(stream, parse_constant=reject)
    except (ValueError, TypeError, OSError, UnicodeDecodeError):
        return None
    return data if isinstance(data, dict) else None


def ramp(fill):
    fill = min(1.0, max(0.0, fill))
    for index in range(len(STOPS) - 1):
        low, low_rgb = STOPS[index]
        high, high_rgb = STOPS[index + 1]
        if low <= fill <= high:
            ratio = 0.0 if high == low else (fill - low) / (high - low)
            return tuple(round(low_rgb[i] + (high_rgb[i] - low_rgb[i]) * ratio) for i in range(3))
    return STOPS[-1][1]


def paint(text, rgb):
    return f"\033[38;2;{rgb[0]};{rgb[1]};{rgb[2]}m{text}\033[39m"


def fmt(count):
    if count >= MILLION:
        millions = round(count / 100_000) / 10
        return f"{millions:.0f}M" if millions == int(millions) else f"{millions:g}M"
    return f"{round(count / 1000)}k"


def used_tokens(window):
    """Tokens consommes, quelle que soit la forme du champ, ou None."""
    current = window.get("current_usage")

    if isinstance(current, dict):
        total = 0.0
        seen = False
        for field in USAGE_FIELDS:
            value = finite(current.get(field))
            if value is not None:
                total += max(0.0, value)
                seen = True
        return total if seen else None

    direct = finite(current)
    if direct is not None:
        return max(0.0, direct)

    percentage = finite(window.get("used_percentage"))
    size = finite(window.get("context_window_size"))
    if percentage is not None and size is not None and size > 0:
        return max(0.0, percentage) / 100 * size
    return None


def build(window):
    """Barre rendue, ou None si la fenetre de contexte n'est pas exploitable."""
    total = finite(window.get("context_window_size"))
    used = used_tokens(window)
    if total is None or total <= 0 or used is None:
        return None

    pct = min(100.0, max(0.0, used / total * 100))
    exact = pct / 100 * WIDTH
    filled = int(exact)
    step = int((exact - filled) * 8)

    rgb = ramp(pct / 100)
    cells = [paint(FULL, rgb) for _ in range(filled)]
    if filled < WIDTH:
        if step > 0:
            cells.append(paint(PARTIALS[step - 1], rgb))
        cells.append(" " * (WIDTH - filled - (1 if step > 0 else 0)))

    bar = paint(CAP_L, CAP_COLOR) + "".join(cells) + paint(CAP_R, CAP_COLOR)
    label = paint(f"{fmt(used)}/{fmt(total)} ({round(pct)}%)", TEXT_COLOR)
    prefix = paint(LABEL, TEXT_COLOR) if LABEL else ""
    return f"{prefix}{bar} {label}"


def main():
    data = load_statusline(sys.stdin)
    if data is None:
        return
    window = data.get("context_window")
    if not isinstance(window, dict):
        return
    rendered = build(window)
    if rendered:
        sys.stdout.write(rendered)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Une trace d'erreur dans la barre d'etat est pire qu'un widget vide.
        if os.environ.get("CCSL_DEBUG"):
            raise
