# ccstatusline-setup

Ma statusline [ccstatusline](https://github.com/sirmalloc/ccstatusline) pour Claude Code,
empaquetée pour s'installer ailleurs en deux commandes. macOS et Linux.

```
 Opus 5  Thinking: high  Context: │██████████▌      │ 104k/200k (52%)  128.4k  $1.84      ~/mon-projet  ⎇ main  (+12,-3)
 Session ▕███████┊  ▏ 68% → 91% ✓ +34m ⧗1h37                      Weekly ▕████▌┊    ▏ 44% → 103% ⚠ mur 2j6h ⧗3j3h
```

Ligne 1 : le contexte qui se remplit, en vert→jaune→rouge.
Ligne 2 : ta consommation réelle **et sa projection** — le `┊` marque où tu devrais en être,
`→ 103%` dit où tu finiras au rythme actuel, et `⚠ mur 2j6h` te dit quand tu taperas la limite.

## Installation

```bash
git clone git@github.com:AdrienGras/ccstatusline-setup.git
cd ccstatusline-setup
./install.sh
```

Redémarre Claude Code, c'est tout.

Le script trouve ton binaire ccstatusline tout seul. S'il n'y arrive pas, il te demande
son chemin et vérifie qu'il répond avant d'aller plus loin. Rien n'est écrasé sans sauvegarde,
et tu peux le relancer autant de fois que tu veux.

## Prérequis

**`ccstatusline`** — si tu ne l'as pas encore :

```bash
npx ccstatusline@2.2.19
```

puis choisis l'installation *pinned* dans le menu (pas de `sudo`, pas de `PATH` à bricoler).
`npm install -g ccstatusline@2.2.19` marche aussi bien.

**`python3`**, **`jq`**, **`git`** — les deux premiers portent les barres et la fusion de config.
Sur macOS il ne manque généralement que `jq` : `brew install jq`.

## Options

```bash
./install.sh --dry-run          # montre tout ce qu'il ferait, n'écrit rien
./install.sh --path <chemin>    # chemin explicite, aucune question posée
```

<details>
<summary><b>Ce que l'installeur touche exactement</b></summary>

<br>

| Fichier | Action |
|---|---|
| `~/.config/ccstatusline/context-bar.py` | copié |
| `~/.config/ccstatusline/burn-bar.py` | copié |
| `~/.config/ccstatusline/settings.json` | écrit, avec `__HOME__` remplacé par ton `HOME` |
| `~/.claude/settings.json` | seule la clé `statusLine` est fusionnée |

Tes plugins, permissions et autres réglages Claude Code ne sont pas touchés : la fusion passe
par `jq` et ne réécrit que `statusLine`. Chaque fichier écrasé est d'abord copié en
`<nom>.bak-<horodatage>`.

</details>

<details>
<summary><b>Pourquoi une substitution et pas des liens symboliques</b></summary>

<br>

Le `settings.json` de ccstatusline stocke des chemins **absolus** vers les scripts des barres.
Un `ln -s` les laisserait pointer vers le `HOME` d'origine — et `/Users/toi` sur macOS ne
ressemble en rien à `/home/toi` sur Linux. D'où le marqueur `__HOME__`, substitué à l'installation.

Les fichiers sont copiés plutôt que liés parce que ccstatusline réécrit son `settings.json`
dès qu'on le configure via son interface : un lien vers le dépôt produirait des diffs git parasites
à chaque réglage.

Même logique pour la détection du binaire : elle ne passe **pas** par le `PATH`, parce que le mode
d'installation recommandé pose le binaire dans `~/.claude/tools/bin/`, qui n'y figure pas.
L'installeur sonde donc les emplacements connus, puis le `PATH`, puis te demande.

</details>

<details>
<summary><b>Tests</b></summary>

<br>

```bash
./test/install_test.sh
```

Chaque cas s'exécute dans un `HOME` jetable avec un faux binaire ccstatusline — détection,
fusion non destructive, idempotence, rejet des mauvais chemins, boucle interactive.
Ton `HOME` réel n'est jamais touché.

</details>

## Licence

MIT
