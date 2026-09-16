#!/usr/bin/env python3
"""Exécute une commande dans un pseudo-terminal en lui injectant des réponses.

    pty_run.py <fichier-de-réponses> <commande> [args...]

Sert aux tests de la boucle interactive de install.sh, qui lit son entrée sur
/dev/tty et a donc besoin d'un vrai terminal. La commande `script` ferait
l'affaire, mais sa syntaxe et sa gestion de stdin diffèrent entre util-linux
et BSD : un pilote en Python est le seul chemin commun aux deux systèmes.

Écrit sur sa sortie standard tout ce que la commande a produit (échos du
terminal compris) et propage son code de retour.
"""
import fcntl
import os
import pty
import select
import subprocess
import sys
import termios

TIMEOUT = 30.0          # garde-fou : un test ne doit jamais bloquer la CI
MIN_ARGS = 3            # le script, le fichier de réponses, puis la commande
CHUNK = 65536


def attach_controlling_tty():
    """Fait du pty le terminal de contrôle du processus fils.

    Sans cela le fils hérite bien du pty sur ses trois descripteurs, mais
    l'ouverture de /dev/tty échoue : c'est la session, pas le descripteur,
    qui désigne le terminal de contrôle.
    """
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


def main():
    if len(sys.argv) < MIN_ARGS:
        sys.exit("usage: pty_run.py <fichier-de-réponses> <commande> [args...]")
    replies_path, command = sys.argv[1], sys.argv[2:]

    with open(replies_path, "rb") as handle:
        replies = handle.read()

    master, slave = pty.openpty()
    # S603 : la commande vient de la ligne de commande d'un script de test.
    # PLW1509 : preexec_fn n'est risqué qu'avec des threads, et ce pilote est
    # mono-thread ; attacher le terminal de contrôle exige de toute façon de
    # s'exécuter entre le fork et l'exec.
    process = subprocess.Popen(  # noqa: S603, PLW1509
        command, stdin=slave, stdout=slave, stderr=slave,
        close_fds=True, preexec_fn=attach_controlling_tty)
    os.close(slave)
    os.write(master, replies)

    output = bytearray()
    while True:
        ready, _, _ = select.select([master], [], [], TIMEOUT)
        if not ready:
            process.kill()
            break
        try:
            chunk = os.read(master, CHUNK)
        except OSError:
            break            # le terminal se ferme quand la commande se termine
        if not chunk:
            break
        output += chunk

    os.close(master)
    sys.stdout.buffer.write(bytes(output))
    sys.stdout.buffer.flush()
    sys.exit(process.wait())


if __name__ == "__main__":
    main()
