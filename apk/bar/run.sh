#!/system/bin/sh
# Собрать наш плагин из заводского прямо на машине. Не ставит.
#
#     sh run.sh <заводской.apk> <выход.apk> [<сборка>]
#
# Рядом должны лежать barpatch.jar, ours.dex, key.pk8 и cert.der (car-kit.sh).
# Код выхода 2 — рецепт не лёг на этот плагин: ставить нечего.
KIT="$(cd "$(dirname "$0")" && pwd)"
STOCK="$1"; OUT="$2"; BUILD="${3:-car}"
[ -f "$STOCK" ] && [ -n "$OUT" ] || { echo "sh run.sh <заводской.apk> <выход.apk> [<сборка>]" >&2; exit 1; }

VER=$(dumpsys package com.flyme.auto.systemuiplugin 2>/dev/null | grep versionName | head -1 | cut -d= -f2)
printf 'build=%s\nfeatures=icons,tasks,fastbar,shade\nfrom=%s %s\n' \
    "$BUILD" "$VER" "$(md5sum "$STOCK" | cut -d' ' -f1)" > "$KIT/stamp.txt"

CLASSPATH="$KIT/barpatch.jar" exec app_process /system/bin dev.mertsalov.barpatch.MainKt \
    build "$STOCK" "$OUT" --ours "$KIT/ours.dex" --stamp "$KIT/stamp.txt" \
    --key "$KIT/key.pk8" --cert "$KIT/cert.der"
