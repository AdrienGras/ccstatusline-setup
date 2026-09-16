#!/usr/bin/env python3
"""Indicateur de rythme de consommation pour ccstatusline (widget custom-command).

Remplace les widgets natifs session-usage / reset-timer / weekly-usage /
weekly-reset-timer : au lieu d'un simple pourcentage, affiche si le rythme actuel
tient jusqu'au reset de la fenetre de quota.

Usage : burn-bar.py session | weekly | opus | sonnet
Lit sur stdin le JSON de statusline de Claude Code (champ rate_limits).
N'affiche rien si les donnees sont absentes, ce qui masque le widget.

Rendu : Session ▕███▎┊     ▏ 20% → 40% ✓ +7h30 ⧗2h30
  - barre  : remplissage = % consomme ; ┊ = ou l'on devrait en etre (temps ecoule)
  - → N%   : projection de la conso au reset si le rythme actuel se maintient
  - ✓ +Xh  : rab de temps ; ⚠ mur Xh : ETA du 100 % quand il tombe avant le reset
  - ⧗Xh    : temps restant avant le reset de la fenetre
La teinte du remplissage et du bloc projection suit la projection : vert -> rouge.

Toute entree invalide donne une sortie vide plutot qu'une trace d'erreur :
ce script ecrit dans une barre d'etat, pas dans un terminal que l'on lit.
Poser CCSL_DEBUG=1 pour faire remonter les exceptions pendant une mise au point.
"""
import json
import math
import os
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

FULL_PCT = 100.0
PROJECTION_CAP = 999      # au-dela, on affiche ">999%" plutot qu'un nombre absurde
SECONDS_PER_MINUTE = 60
MINUTES_PER_HOUR = 60
HOURS_PER_DAY = 24

# Un horodatage epoch en secondes reste tres en dessous ; au-dessus, c'est des
# millisecondes. Convertir plutot que d'afficher un reset dans 50 000 ans.
MILLISECOND_THRESHOLD = 1e11

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


def finite(value):
    """Convertit en float fini, ou None.

    Rejette None, les booleens, les types non numeriques, et surtout
    NaN / Infinity : le module json les accepte par defaut, et ils traversent
    les comparaisons sans erreur jusqu'a faire echouer int() ou round()
    beaucoup plus loin, au milieu du rendu.
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


def ramp(projection):
    projection = min(STOPS[-1][0], max(0.0, projection))
    for index in range(len(STOPS) - 1):
        low, low_rgb = STOPS[index]
        high, high_rgb = STOPS[index + 1]
        if low <= projection <= high:
            ratio = 0.0 if high == low else (projection - low) / (high - low)
            return tuple(round(low_rgb[i] + (high_rgb[i] - low_rgb[i]) * ratio) for i in range(3))
    return STOPS[-1][1]


def paint(text, rgb):
    return f"\033[38;2;{rgb[0]};{rgb[1]};{rgb[2]}m{text}\033[39m"


def fmt_dur(seconds):
    """Duree compacte : <1m, 42m, 1h, 4h36, 3j3h, 2j."""
    if seconds == float("inf"):
        return "∞"
    total = int(max(0.0, seconds))
    if total < SECONDS_PER_MINUTE:
        return "<1m"
    minutes = round(total / float(SECONDS_PER_MINUTE))
    if minutes < MINUTES_PER_HOUR:
        return f"{minutes}m"
    hours, minutes = divmod(minutes, MINUTES_PER_HOUR)
    if hours < HOURS_PER_DAY:
        return f"{hours}h{minutes:02d}" if minutes else f"{hours}h"
    days, hours = divmod(hours, HOURS_PER_DAY)
    return f"{days}j{hours}h" if hours else f"{days}j"


def normalise_epoch(resets_at):
    """Horodatage de reset en secondes, ou None s'il n'a aucun sens."""
    if resets_at is None or resets_at <= 0:
        return None
    return resets_at / 1000.0 if resets_at > MILLISECOND_THRESHOLD else resets_at


def compute(used_pct, resets_at, duration, now):
    """Rythme de consommation sur une fenetre de quota.

    La fenetre a une duree fixe, donc son debut vaut resets_at - duration.
    Retourne None si les entrees ne permettent aucun calcul.
    """
    if duration <= 0 or resets_at is None:
        return None
    used_pct = min(float(PROJECTION_CAP), max(0.0, used_pct))
    elapsed = now - (resets_at - duration)
    elapsed_frac = min(1.0, max(1e-6, elapsed / duration))
    remaining = max(0.0, resets_at - now)

    if used_pct <= 0.0:
        projection, juice = 0.0, float("inf")
    else:
        projection = used_pct / elapsed_frac
        rate = used_pct / (elapsed_frac * duration)   # points de % par seconde
        juice = max(0.0, FULL_PCT - used_pct) / rate
    margin = float("inf") if juice == float("inf") else juice - remaining

    return {"used_pct": used_pct, "elapsed_frac": elapsed_frac,
            "remaining": remaining, "projection": projection,
            "juice": juice, "margin": margin,
            "low_conf": elapsed_frac < CONFIDENCE_FLOOR}


def render_bar(used_pct, elapsed_frac, rgb):
    exact = min(FULL_PCT, used_pct) / FULL_PCT * WIDTH
    filled = int(exact)
    step = int((exact - filled) * 8)
    marker = min(WIDTH - 1, int(min(1.0, max(0.0, elapsed_frac)) * WIDTH))

    cells = []
    for index in range(WIDTH):
        if index == marker:
            cells.append(paint(MARKER, MARKER_COLOR))
        elif index < filled:
            cells.append(paint(FULL, rgb))
        elif index == filled and step > 0:
            cells.append(paint(PARTIALS[step - 1], rgb))
        else:
            cells.append(" ")
    return paint(CAP_L, CAP_COLOR) + "".join(cells) + paint(CAP_R, CAP_COLOR)


def render(label, metrics):
    rgb = DIM_COLOR if metrics["low_conf"] else ramp(metrics["projection"])
    tilde = "~" if metrics["low_conf"] else ""

    projection = min(PROJECTION_CAP, round(metrics["projection"]))
    if projection >= PROJECTION_CAP:
        projection_txt = f"→ {tilde}>{PROJECTION_CAP}%"
    else:
        projection_txt = f"→ {tilde}{projection}%"

    if metrics["used_pct"] >= FULL_PCT:
        suffix = "⛔ limite"
    elif metrics["margin"] == float("inf"):
        suffix = "✓ ∞"
    elif metrics["margin"] >= 0:
        suffix = f"✓ +{fmt_dur(metrics['margin'])}"
    else:
        suffix = f"⚠ mur {fmt_dur(metrics['juice'])}"

    return " ".join([
        paint(label, LABEL_COLOR),
        render_bar(metrics["used_pct"], metrics["elapsed_frac"], rgb),
        paint(f"{round(metrics['used_pct']):3d}%", USED_COLOR),
        paint(projection_txt, rgb),
        paint(suffix, rgb),
        paint(f"⧗{fmt_dur(metrics['remaining'])}", RESET_COLOR),
    ])


def main():
    period = sys.argv[1] if len(sys.argv) > 1 else "session"
    if period not in PERIODS:
        return
    label, key, duration = PERIODS[period]

    data = load_statusline(sys.stdin)
    if data is None:
        return
    limits = data.get("rate_limits")
    if not isinstance(limits, dict):
        return
    window = limits.get(key)
    if not isinstance(window, dict):
        return

    used = finite(window.get("used_percentage"))
    resets_at = normalise_epoch(finite(window.get("resets_at")))
    if used is None or resets_at is None:
        return

    metrics = compute(used, resets_at, duration, time.time())
    if metrics is None:
        return
    sys.stdout.write(render(label, metrics))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Une trace d'erreur dans la barre d'etat est pire qu'un widget vide.
        if os.environ.get("CCSL_DEBUG"):
            raise
