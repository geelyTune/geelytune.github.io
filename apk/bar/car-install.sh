#!/system/bin/sh
KIT="$(cd "$(dirname "$0")" && pwd)"
PKG=com.flyme.auto.systemuiplugin
DIR=/system/priv-app/AutoSystemUIPlugin
APK=$DIR/AutoSystemUIPlugin.apk
BAK=/data/local/gt-backup
LOWER=/mnt/gt-lower
MODE="$1"; shift
FORCE=0; CLEAN=0
for a in "$@"; do
    case "$a" in
        --force) FORCE=1 ;;
        --clean) CLEAN=1 ;;
    esac
done

die() { echo "ОШИБКА: $*"; exit 1; }

parked() {
    cmd car_service get-property-value 11400400 0 2>/dev/null | grep -q 'int32Values: \[4\]'
}

upper() {
    mount | grep ' on /system type overlay' | sed -n 's/.*upperdir=\([^,)]*\).*/\1/p' | head -1
}

stock_to() {
    if [ -n "$(upper)" ]; then
        mkdir -p $LOWER
        mount --bind / $LOWER || die "не удалось открыть заводской слой /system"
        cp $LOWER$APK "$1"; rc=$?
        umount $LOWER; rmdir $LOWER
        [ $rc = 0 ] || die "в заводском слое нет плагина"
    else
        ver=$(dumpsys package $PKG 2>/dev/null | grep versionName | head -1 | cut -d= -f2)
        copy="$BAK/AutoSystemUIPlugin.stock-$ver.apk"
        if [ ! -s "$copy" ]; then
            touch $DIR/.gt-w 2>/dev/null || die "/system закрыт на запись: после первого adb remount перезагрузите машину и запустите установку снова"
            rm -f $DIR/.gt-w
            if unzip -l $APK 2>/dev/null | grep -q 'assets/geelytune-build.txt' || unzip -p $APK classes.dex 2>/dev/null | grep -q 'dev/mertsalov/geelytune'; then
                die "на машине стоит наша сборка плагина, а копии заводского $ver в $BAK нет"
            fi
            mkdir -p $BAK
            cp $APK "$copy.tmp" && mv "$copy.tmp" "$copy" || die "не удалось сохранить заводской плагин в $BAK"
            echo "   заводской плагин $ver сохранён: $copy"
        fi
        cp "$copy" "$1"
    fi
}

place() {
    cp "$1" $APK || die "не удалось записать $APK (adb remount прошёл?)"
    chown root:root $APK
    chmod 644 $APK
    restorecon $APK 2>/dev/null || chcon u:object_r:system_file:s0 $APK
    rm -f $DIR/oat/arm64/*.odex $DIR/oat/arm64/*.vdex
    cmd package compile -f -m speed $PKG >/dev/null 2>&1 || echo "   перекомпиляция не прошла — плагин может не пережить перезагрузку"
}

restart_ui() {
    logcat -c
    logcat -b crash -c
    kill $(pidof com.android.systemui) 2>/dev/null
    i=0
    while [ $i -lt 30 ]; do
        sleep 1
        i=$((i + 1))
        [ $i -ge 3 ] && [ -n "$(pidof com.android.systemui)" ] && return 0
    done
    return 1
}

crashed() {
    logcat -d -b crash | grep -q 'com.android.systemui'
}

ours_up() {
    i=0
    while [ $i -lt 30 ]; do
        crashed && return 1
        logcat -d -s GTBarCore:V | grep -q 'core started' && break
        sleep 1
        i=$((i + 1))
    done
    [ $i -lt 30 ] || return 1
    sleep 5
    [ -n "$(pidof com.android.systemui)" ] && ! crashed
}

trim_shortcuts() {
    s=$(settings get secure sysui_plugin_shortcut_settings)
    [ -n "$s" ] && [ "$s" != null ] || return 0
    n=$(echo "$s" | tr ',' '\n' | grep -c .)
    [ "$n" -le 3 ] && return 0
    mkdir -p $BAK
    echo "$s" > "$BAK/shortcuts-$(date +%Y%m%d-%H%M%S).txt"
    settings put secure sysui_plugin_shortcut_settings "$(echo "$s" | cut -d, -f1-3)"
    echo "   ярлыков было $n, заводская панель держит три — лишние сняты, список сохранён в $BAK"
}

kind() {
    if [ "$(md5sum $APK | cut -d' ' -f1)" = "$(md5sum "$1" | cut -d' ' -f1)" ]; then echo stock
    elif unzip -l $APK 2>/dev/null | grep -q 'assets/geelytune-build.txt'; then echo ours
    elif unzip -p $APK classes.dex 2>/dev/null | grep -q 'dev/mertsalov/geelytune'; then echo ours
    else echo other
    fi
}

revert() {
    trim_shortcuts
    place "$KIT/stock.apk"
    restart_ui || die "SystemUI не поднялся после возврата — перезагрузите машину"
    echo "   заводской плагин возвращён"
}

[ "$(id -u)" = 0 ] || die "нужен root: adb root"
parked || die "переведите машину в режим парковки (P)"

rm -f "$KIT/stock.apk" "$KIT/out.apk"
stock_to "$KIT/stock.apk"
VER=$(dumpsys package $PKG 2>/dev/null | grep versionName | head -1 | cut -d= -f2)
echo "   прошивка плагина: $VER"

case "$MODE" in
install)
    now=$(kind "$KIT/stock.apk")
    if [ "$now" = other ] && [ $FORCE = 0 ]; then
        echo "   на машине чужая сборка плагина (не заводская и не наша) — её правки пропадут"
        exit 3
    fi
    if [ "$now" != stock ]; then
        mkdir -p $BAK
        cp $APK "$BAK/AutoSystemUIPlugin.before-$(date +%Y%m%d-%H%M%S).apk"
    fi
    echo "   сборка плагина на машине (около минуты)..."
    sh "$KIT/run.sh" "$KIT/stock.apk" "$KIT/out.apk" "$(cat "$KIT/version.txt")" >/dev/null 2>"$KIT/build.log"
    rc=$?
    if [ $rc = 2 ]; then
        echo "   плагин этой прошивки не поддерживается: $(grep ОТКАЗ "$KIT/build.log")"
        echo "   на машине ничего не изменено"
        exit 2
    fi
    [ $rc = 0 ] || die "сборка не удалась: $(tail -1 "$KIT/build.log")"
    place "$KIT/out.apk"
    echo "   перезапуск панели..."
    if restart_ui && ours_up; then
        echo "   готово: сборка $(cat "$KIT/version.txt"), прошивка $VER"
        exit 0
    fi
    echo "   панель не поднялась с нашим плагином — возвращаю заводской"
    revert
    exit 4
    ;;
remove)
    if [ $CLEAN = 1 ] && [ -n "$(upper)" ]; then
        trim_shortcuts
        rm -rf "$(upper)/priv-app/AutoSystemUIPlugin"
        sync
        echo "   плагин убран из /system целиком, машина перезагружается"
        reboot
        exit 0
    fi
    revert
    ;;
*)
    die "режим: install или remove"
    ;;
esac
