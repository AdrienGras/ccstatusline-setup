# ccstatusline-setup

Ma configuration [ccstatusline](https://github.com/sirmalloc/ccstatusline) pour Claude Code,
empaquetée pour être déployée sur une autre machine en deux commandes.

Deux lignes : modèle, effort de réflexion, barre de contexte, tokens, coût de session,
répertoire courant et état git sur la première ; consommation de session et hebdomadaire
sur la seconde.

## Installation

```bash
git clone https://github.com/AdrienGras/ccstatusline-setup.git
cd ccstatusline-setup
./install.sh
```

Puis redémarre Claude Code.

## Prérequis

| Outil | Pourquoi |
|---|---|
| `ccstatusline` | le binaire lui-même — voir ci-dessous |
| `python3` | les deux barres sont des scripts Python (bibliothèque standard uniquement) |
| `jq` | fusion non destructive de `~/.claude/settings.json` |
| `git` | pour cloner |

`python3` et `git` sont présents par défaut sur macOS et sur la plupart des distributions.
`jq` s'installe avec `brew install jq` ou `apt install jq`.

### Installer ccstatusline

Le mode recommandé est le préfixe privé, qui n'exige ni `sudo` ni modification du `PATH` :

```bash
npx ccstatusline@2.2.19
```

et choisir l'installation *pinned* dans le menu. Le binaire atterrit alors dans
`~/.claude/tools/bin/ccstatusline`.

L'installation npm globale fonctionne tout aussi bien :

```bash
npm install -g ccstatusline@2.2.19
```

`install.sh` cherche le binaire dans les emplacements habituels, puis sur le `PATH`.
S'il ne trouve rien, il demande le chemin et le vérifie avant de continuer.

## Ce que fait `install.sh`

1. Résout le binaire `ccstatusline` et vérifie qu'il répond bien.
2. Compare sa version à celle avec laquelle cette configuration a été testée (avertissement seulement).
3. Copie `context-bar.py` et `burn-bar.py` dans `~/.config/ccstatusline/`.
4. Y écrit `settings.json`, en remplaçant le marqueur `__HOME__` par le `HOME` réel.
5. Fusionne **uniquement** la clé `statusLine` dans `~/.claude/settings.json`.

Tout fichier écrasé est d'abord sauvegardé en `<nom>.bak-<horodatage>`.
Le script est idempotent : le relancer ne casse rien.

### Options

```
./install.sh --dry-run          # montre les actions sans rien écrire
./install.sh --path <chemin>    # chemin explicite, sans question posée
```

## Pourquoi une substitution plutôt que des liens symboliques

Le `settings.json` de ccstatusline contient des chemins absolus vers les scripts des barres.
Un `ln -s` laisserait ces chemins pointant vers le `HOME` d'origine — et `/Users/...` sur macOS
ne ressemble pas à `/home/...` sur Linux. D'où le marqueur `__HOME__`, substitué à l'installation.

Les fichiers sont copiés plutôt que liés parce que ccstatusline réécrit son `settings.json`
quand on le configure via son interface : un lien vers le dépôt produirait des diffs git parasites.

## Tests

```bash
./test/install_test.sh
```

Chaque cas s'exécute dans un `HOME` jetable avec un faux binaire ccstatusline ;
le `HOME` réel n'est jamais touché.

## Licence

MIT
