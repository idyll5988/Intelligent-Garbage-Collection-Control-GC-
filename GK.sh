#!/system/bin/sh
[ ! "$MODDIR" ] && MODDIR=${0%/*}
[ -e ${MODDIR}/dev/*/.magisk/busybox ] && BB=$(echo ${MODDIR}/dev/*/.magisk/busybox);
[ -e ${MODDIR}/data/adb/magisk/busybox ] && BB=${MODDIR}/data/adb/magisk/busybox;
[ -e ${MODDIR}/data/adb/ap/bin/busybox ] && BB=${MODDIR}/data/adb/ap/bin/busybox;
[ -e ${MODDIR}/data/adb/ksu/bin/busybox ] && BB=${MODDIR}/data/adb/ksu/bin/busybox;
[ -e ${MODDIR}/system/bin/busybox ] && BB=${MODDIR}/system/bin/busybox;
[ -e ${MODDIR}/system/bin/toybox ] && SOS=${MODDIR}/system/bin/toybox;
[ -e ${MODDIR}/system/bin/sqlite3 ] && SQ=${MODDIR}/system/bin/sqlite3;
[ "$BB" ] && export PATH="/system/bin:$BB:$PATH";
detect_su_format() {
    if su -i -c 'exit 0' >/dev/null 2>&1; then
        echo "su -i -c"
    elif su -c 'exit 0' >/dev/null 2>&1; then
        echo "su -c"
    else
        echo ""
    fi
}
su_write=$(detect_su_format)
$su_write renice -n 10 $$
function lock_value() {
    if [[ -z "$1" || -z "$2" ]]; then
        km2 "参数缺失"
        return 1
    fi
    if [[ ! -f "$1" ]]; then
        km2 "命令:($1) 位置不存在跳过..."
        return 1
    fi
    $su_write "chown root:root \"$1\"" 2>/dev/null
    $su_write "chmod 0644 \"$1\"" 2>/dev/null
    echo "尝试读取文件: $1"
    local curval
    curval=$(<"$1") || { km2 "读取:($1) 失败"; return 1; }
    if [[ "$curval" == "$2" ]]; then
        km1 "命令:$1 参数已存在 ($2) 跳过..."
        return 0
    fi
    if ! $su_write printf "%s" "$2" | tee "$1" 2>/dev/null; then
        km2 "写入:($1) -❌-> 命令 $2 参数失败"
        return 1
    fi
	$su_write "chmod 0444 \"$1\"" 2>/dev/null
    km1 "写入:$1 $curval -✅-> 命令 ($2) 参数成功"
}