#!/usr/bin/env python3
"""Indicateur de rythme de consommation pour ccstatusline (widget custom-command).

Remplace les widgets natifs session-usage / reset-timer / weekly-usage /
weekly-reset-timer : au lieu d'un simple pourcentage, affiche si le rythme actuel
tient jusqu'au reset de la fenetre de quota.

Usage : burn-bar.py session | burn-bar.py weekly
Lit sur stdin le JSON de statusline de Claude Code (champ rate_limits).
N'affiche rien si les donnees sont absentes, ce qui masque le widget.

Rendu : Session ▕███▎┊     ▏ 20% → 40% ✓ +7h30 ⧗2h30
  - barre  : remplissage = % consomme ; ┊ = ou l'on devrait en etre (temps ecoule)
  - → N%   : projection de la conso au reset si le rythme actuel se maintient
  - ✓ +Xh  : rab de temps ; ⚠ mur Xh : ETA du 100 % quand il tombe avant le reset
  - ⧗Xh    : temps restant avant le reset de la fenetre
La teinte du remplissage et du bloc projection suit la projection : vert -> rouge.
"""
import json
import sys
import time

WIDTH = 10
PARTIALS = "▏▎▍▌▋▊▉"  # 1/8 .. 7/8
FULL = "█"
MARKER = "┊"
CAP_L = "▕"
CAP_R = "▏"

# Sous ce taux de fenetre ecoulee la projection est trop bruitee pour alerter.
CONFIDENCE_FLOOR = 0.10

PERIODS = {
    "session": ("Session", "five_hour", 5 * 3600.0),
    "weekly": ("Weekly", "seven_day", 7 * 86400.0),
    "opus": ("Opus", "seven_day_opus", 7 * 86400.0),
    "sonnet": ("Sonnet", "seven_day_sonnet", 7 * 86400.0),
}

LABEL_COLOR = (0x82, 0x86, 0x8F)
USED_COLOR = (0x9A, 0xA0, 0xAB)
CAP_COLOR = (0x63, 0x67, 0x6F)
MARKER_COLOR = (0xD6, 0xDA, 0xE4)
RESET_COLOR = (0x74, 0x78, 0x7F)
DIM_COLOR = (0x82, 0x86, 0x8F)

# Degrade pilote par la projection (palette brogrammer, cf. context-bar.py)
STOPS = [(0.0, (0x2C, 0xC5, 0x5D)),     # vert   : large
         (80.0, (0xEC, 0xB9, 0x0F)),    # jaune  : ca serre
         (130.0, (0xDE, 0x34, 0x2E)),   # rouge  : depassement
         (200.0, (0xF7, 0x11, 0x18))]   # rouge vif : franc depassement


def ramp(p):
    p = min(STOPS[-1][0], max(0.0, p))
    for (a, ca), (b, cb) in zip(STOPS, STOPS[1:]):
        if a <= p <= b:
            t = 0.0 if b == a else (p - a) / (b - a)
            return tuple(round(ca[i] + (cb[i] - ca[i]) * t) for i in range(3))
    return STOPS[-1][1]


def paint(text, rgb):
    return "\033[38;2;%d;%d;%dm%s\033[39m" % (rgb[0], rgb[1], rgb[2], text)


def fmt_dur(seconds):
    """Duree compacte : <1m, 42m, 1h, 4h36, 3j3h, 2j."""
    if seconds == float("inf"):
        return "∞"
    s = int(max(0.0, seconds))
    if s < 60:
        return "<1m"
    minutes = int(round(s / 60.0))
    if minutes < 60:
        return "%dm" % minutes
    hours, minutes = divmod(minutes, 60)
    if hours < 24:
        return "%dh%02d" % (hours, minutes) if minutes else "%dh" % hours
    days, hours = divmod(hours, 24)
    return "%dj%dh" % (days, hours) if hours else "%dj" % days


def compute(used_pct, resets_at, duration, now):
    """Rythme de consommation sur une fenetre de quota.

    La fenetre a une duree fixe, donc son debut vaut resets_at - duration.
    Retourne None si les entrees ne permettent aucun calcul.
    """
    if duration <= 0 or resets_at is None:
        return None
    used_pct = max(0.0, float(used_pct))
    elapsed = now - (resets_at - duration)
    elapsed_frac = min(1.0, max(1e-6, elapsed / duration))
    remaining = max(0.0, resets_at - now)

    if used_pct <= 0.0:
        projection, juice = 0.0, float("inf")
    else:
        projection = used_pct / elapsed_frac
        rate = used_pct / (elapsed_frac * duration)   # points de % par seconde
        juice = max(0.0, (100.0 - used_pct)) / rate
    margin = float("inf") if juice == float("inf") else juice - remaining

    return {"used_pct": used_pct, "elapsed_frac": elapsed_frac,
            "remaining": remaining, "projection": projection,
            "juice": juice, "margin": margin,
            "low_conf": elapsed_frac < CONFIDENCE_FLOOR}


def render_bar(used_pct, elapsed_frac, rgb):
    exact = min(100.0, used_pct) / 100.0 * WIDTH
    n = int(exact)
    step = int((exact - n) * 8)
    marker = min(WIDTH - 1, int(min(1.0, max(0.0, elapsed_frac)) * WIDTH))

    cells = []
    for i in range(WIDTH):
        if i == marker:
            cells.append(paint(MARKER, MARKER_COLOR))
        elif i < n:
            cells.append(paint(FULL, rgb))
        elif i == n and step > 0:
            cells.append(paint(PARTIALS[step - 1], rgb))
        else:
            cells.append(" ")
    return paint(CAP_L, CAP_COLOR) + "".join(cells) + paint(CAP_R, CAP_COLOR)


def render(label, m):
    rgb = DIM_COLOR if m["low_conf"] else ramp(m["projection"])

    proj = min(999, round(m["projection"]))
    proj_txt = "→ %s%d%%" % ("~" if m["low_conf"] else "", proj)
    if proj >= 999:
        proj_txt = "→ %s>999%%" % ("~" if m["low_conf"] else "")

    if m["used_pct"] >= 100.0:
        suffix = "⛔ limite"
    elif m["margin"] == float("inf"):
        suffix = "✓ ∞"
    elif m["margin"] >= 0:
        suffix = "✓ +%s" % fmt_dur(m["margin"])
    else:
        suffix = "⚠ mur %s" % fmt_dur(m["juice"])

    return " ".join([
        paint(label, LABEL_COLOR),
        render_bar(m["used_pct"], m["elapsed_frac"], rgb),
        paint("%3d%%" % round(m["used_pct"]), USED_COLOR),
        paint(proj_txt, rgb),
        paint(suffix, rgb),
        paint("⧗%s" % fmt_dur(m["remaining"]), RESET_COLOR),
    ])


def main():
    period = sys.argv[1] if len(sys.argv) > 1 else "session"
    if period not in PERIODS:
        return
    label, key, duration = PERIODS[period]

    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    limits = (data or {}).get("rate_limits")
    if not isinstance(limits, dict):
        return
    window = limits.get(key)
    if not isinstance(window, dict):
        return

    try:
        used = float(window.get("used_percentage"))
        resets_at = float(window.get("resets_at"))
    except (TypeError, ValueError):
        return

    m = compute(used, resets_at, duration, time.time())
    if m is None:
        return
    sys.stdout.write(render(label, m))


if __name__ == "__main__":
    main()
