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
"""
import json
import sys

WIDTH = 10
LABEL = "Context: "  # mettre "" pour n'afficher que la barre
CAP_L = "│"          # delimiteurs ; alternatives : "▕"/"▏" "[" "]" "" (aucun)
CAP_R = "│"           # NB: eviter "▏" a droite, identique au remplissage 1/8
PARTIALS = "▏▎▍▌▋▊▉"  # 1/8 .. 7/8
FULL = "█"

CAP_COLOR = (0x63, 0x67, 0x6F)   # brogrammer color8
TEXT_COLOR = (0x82, 0x86, 0x8F)  # brogrammer inactive_tab_foreground

# Teinte pilotee par le taux de remplissage : vert -> jaune -> rouge (brogrammer)
STOPS = [(0.00, (0x2C, 0xC5, 0x5D)),
         (0.50, (0xEC, 0xB9, 0x0F)),
         (0.80, (0xDE, 0x34, 0x2E)),
         (1.00, (0xF7, 0x11, 0x18))]


def ramp(p):
    p = min(1.0, max(0.0, p))
    for (a, ca), (b, cb) in zip(STOPS, STOPS[1:]):
        if a <= p <= b:
            t = 0.0 if b == a else (p - a) / (b - a)
            return tuple(round(ca[i] + (cb[i] - ca[i]) * t) for i in range(3))
    return STOPS[-1][1]


def paint(text, rgb):
    return "\033[38;2;%d;%d;%dm%s\033[39m" % (rgb[0], rgb[1], rgb[2], text)


def fmt(n):
    if n >= 1_000_000:
        m = round(n / 100_000) / 10
        return "%dM" % m if m == int(m) else "%gM" % m
    return "%dk" % round(n / 1000)


def used_tokens(cw):
    cur = cw.get("current_usage")
    if isinstance(cur, (int, float)):
        return float(cur)
    if isinstance(cur, dict):
        return float(sum(cur.get(k, 0) or 0 for k in
                         ("input_tokens", "cache_creation_input_tokens",
                          "cache_read_input_tokens")))
    pct = cw.get("used_percentage")
    total = cw.get("context_window_size")
    if pct is not None and total:
        return float(pct) / 100 * float(total)
    return None


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    cw = (data or {}).get("context_window")
    if not isinstance(cw, dict):
        return
    total = cw.get("context_window_size")
    used = used_tokens(cw)
    if not total or total <= 0 or used is None:
        return

    pct = min(100.0, max(0.0, used / total * 100))
    exact = pct / 100 * WIDTH
    n = int(exact)
    frac = exact - n

    rgb = ramp(pct / 100)
    cells = [paint(FULL, rgb) for _ in range(n)]
    if n < WIDTH:
        step = int(frac * 8)
        if step > 0:
            cells.append(paint(PARTIALS[step - 1], rgb))
        cells.append(" " * (WIDTH - n - (1 if step > 0 else 0)))

    bar = paint(CAP_L, CAP_COLOR) + "".join(cells) + paint(CAP_R, CAP_COLOR)
    label = paint("%s/%s (%d%%)" % (fmt(used), fmt(total), round(pct)), TEXT_COLOR)
    prefix = paint(LABEL, TEXT_COLOR) if LABEL else ""
    sys.stdout.write("%s%s %s" % (prefix, bar, label))


main()
