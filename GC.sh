#!/system/bin/sh
MODDIR=${0%/*}
MODPATH="/data/adb/modules/GC"
LOG_DIR="${MODDIR}/ll/log"
[[ ! -e ${LOG_DIR} ]] && mkdir -p ${LOG_DIR}
source "${MODPATH}/scripts/GK.sh"
MAX_LOG_SIZE=1048576
# 调整脏段触发阈值
DIRTY_SEG_THRESHOLD=200
MIN_GC_DURATION=90
# 调整最小脏段减少量
MIN_SEG_REDUCTION=1500  
# 调整强制触发 GC 阈值
FORCE_GC_THRESHOLD=80000
# 调整允许高强度 GC 的最大系统负载
MAX_LOAD_FOR_INTENSIVE_GC=25.0
# 调整触发激进 GC 模式的阈值
AGGRESSIVE_MODE_THRESHOLD=150000
# 调整触发增强 GC 模式的阈值
GC_URGENT_BOOST_THRESHOLD=50000
GC_URGENT_BOOST_LEVEL=1
# 调整 GC 超时时间为 10 分钟
MAX_GC_TIMEOUT=600  
SUPER_GC_LEVEL=2
LOAD_REDUCTION_THRESHOLD=15.0

# 启动延迟3分钟
for i in $(seq 180 -1 1); do
    sleep 1
done

log_message() {
    local message="$1"
    echo "$(date "+%Y年%m月%d日 %H时%M分%S秒") $message" >> "${LOG_DIR}/磁盘.log"
}

log_message "===== 脚本启动 ====="
log_message "设备型号: $(getprop ro.product.model)"
log_message "Android版本: $(getprop ro.build.version.release)"
log_message "内核版本: $(uname -r)"
log_message "当前时间: $(date '+%Y-%m-%d %H:%M:%S')"
log_message "模块路径: ${MODPATH}"
log_message "日志目录: ${LOG_DIR}"

get_system_load() {
    awk '{print $1}' /proc/loadavg
}

cleanup_log() {
    local log_path="${LOG_DIR}/磁盘.log"
    if [[ "$(stat -c%s "${log_path}")" -ge "$MAX_LOG_SIZE" ]]; then
        log_message "⚠️ 日志文件超过1MB，执行轮转"
        tail -n 100 "$log_path" > "${log_path}.tmp"
        mv "${log_path}.tmp" "$log_path"
    fi
}

get_battery_status() {
    local status=$(dumpsys battery | grep -m1 "status:" | awk '{print $2}')
    case $status in
        1) echo "unknown" ;;
        2) echo "charging" ;;
        3) echo "discharging" ;;
        4) echo "not_charging" ;;
        5) echo "full" ;;
        *) 
            if dumpsys battery | grep -q "AC powered: true"; then
                echo "charging"
            else
                echo "discharging"
            fi 
            ;;
    esac
}

get_screen_status() {
    if dumpsys power 2>/dev/null | grep -q "mWakefulness=Awake"; then
        echo "on"
    elif dumpsys window policy 2>/dev/null | grep -q "mInteractive=true"; then
        echo "on"
    elif dumpsys deviceidle 2>/dev/null | grep -q "mScreenOn=true"; then
        echo "on"
    elif dumpsys power 2>/dev/null | grep -q "Display Power: state=ON"; then
        echo "on"
    else
        echo "off"
    fi
}

float_compare() {
    awk -v n1="$1" -v n2="$3" "BEGIN {if (n1 $2 n2) exit 0; exit 1}"
}

smart_gc_control() {
    local get_f2fs_sysfs="$1"
    local target_dirty_segs="$2"
    local screen_status="$3"
    
    local start_time=$(date +%s)
    local start_dirty=$target_dirty_segs
    
    # 修复：正确获取系统负载
    local system_load=$(get_system_load)
    log_message "📊 系统负载: $system_load"
    
    local gc_level=1
    local aggressive_mode=0

    # 根据脏段级别设置不同GC强度
    if [ "$target_dirty_segs" -ge "$AGGRESSIVE_MODE_THRESHOLD" ]; then
        # 最高级别GC
        aggressive_mode=1
        gc_level=$SUPER_GC_LEVEL
        MIN_SEG_REDUCTION_TEMP=$((MIN_SEG_REDUCTION * 2))
        log_message "🔥 启用激进模式! 脏段超过 $AGGRESSIVE_MODE_THRESHOLD | 清理目标: $MIN_SEG_REDUCTION_TEMP"
    elif [ "$target_dirty_segs" -ge "$GC_URGENT_BOOST_THRESHOLD" ]; then
        # 中等强度GC
        gc_level=$GC_URGENT_BOOST_LEVEL
        MIN_SEG_REDUCTION_TEMP=$MIN_SEG_REDUCTION
        log_message "🚀 启用增强GC模式! 脏段超过 $GC_URGENT_BOOST_THRESHOLD | 清理目标: $MIN_SEG_REDUCTION_TEMP"
    else
        # 标准GC
        MIN_SEG_REDUCTION_TEMP=$MIN_SEG_REDUCTION
    fi

    if [ "$screen_status" = "on" ]; then
        if float_compare "$system_load" "<=" "$MAX_LOAD_FOR_INTENSIVE_GC"; then
            if [ "$gc_level" -lt "$SUPER_GC_LEVEL" ]; then
                gc_level=$SUPER_GC_LEVEL
            fi
            log_message "📲 亮屏状态: 使用高效GC (级别$gc_level)"
        else
            if [ "$gc_level" -gt 1 ]; then
                gc_level=1
            fi
            log_message "📲 高负载亮屏状态: 使用低功耗GC (级别1)"
        fi
    else
        if float_compare "$system_load" "<" "10"; then
            gc_level=3
            log_message "🌙 灭屏且系统负载低于10: 使用高效GC (级别$gc_level)"
        else
            log_message "🌙 灭屏状态: 使用后台GC (gc_idle=1)"
            lock_value "$get_f2fs_sysfs/gc_idle" "1"
        fi
    fi
    
    sleep 3
    
    if [ "$gc_level" -gt 0 ]; then
        lock_value "$get_f2fs_sysfs/gc_urgent" "$gc_level"
    fi
    log_message "⏳ GC启动 | 初始脏段: $start_dirty | 目标脏段: <$DIRTY_SEG_THRESHOLD"
    
    local last_dirty=$start_dirty
    local last_update=$start_time
    local last_progress_time=$start_time
    local no_progress_count=0
    
    while true; do
        sleep 5
        local current_time=$(date +%s)
        local run_time=$((current_time - start_time))
        local current_dirty=$(cat "$get_f2fs_sysfs/dirty_segments" 2>/dev/null || echo "N/A")
        local reduction=$((last_dirty - current_dirty))
        
        # 动态调整GC级别
        local current_system_load=$(get_system_load)
        if [ "$gc_level" -lt "$SUPER_GC_LEVEL" ] && float_compare "$current_system_load" "<=" "$LOAD_REDUCTION_THRESHOLD"; then
            gc_level=$SUPER_GC_LEVEL
            lock_value "$get_f2fs_sysfs/gc_urgent" "$gc_level"
            log_message "📈 系统负载降低到 $LOAD_REDUCTION_THRESHOLD 以下，提升GC级别到 $gc_level"
        fi
        
        # 无进展检测
        if [ "$reduction" -lt 50 ]; then
            no_progress_count=$((no_progress_count + 1))
        else
            no_progress_count=0
        fi
        
        if [ $((current_time - last_update)) -ge 10 ]; then
            local reduction_pct=$(echo "$reduction $last_dirty" | awk '{printf "%.2f", $1 * 100 / $2}')
            log_message "🔄 GC进行中 | 已运行: ${run_time}s | 当前脏段: $current_dirty | 变化: $reduction (${reduction_pct}%) | 无进展次数: $no_progress_count"
            last_update=$current_time
            last_dirty=$current_dirty
            
            if [ $reduction -gt 0 ]; then
                last_progress_time=$current_time
            fi
        fi
        
        local stop_gc=false
        local time_since_progress=$((current_time - last_progress_time))
        
        # 1. 脏段降至安全水平
        if [ "$current_dirty" -lt "$DIRTY_SEG_THRESHOLD" ]; then
            log_message "✅ 脏段数已降至安全水平 (<$DIRTY_SEG_THRESHOLD)"
            stop_gc=true
        fi
        
        # 2. 达到最小运行时间且总减少量达标
        local total_reduction=$((start_dirty - current_dirty))
        if [ $run_time -ge $MIN_GC_DURATION ] && [ $total_reduction -ge $MIN_SEG_REDUCTION_TEMP ]; then
            log_message "✅ 达到最小减少量 ($total_reduction ≥ $MIN_SEG_REDUCTION_TEMP)"
            stop_gc=true
        fi
        
        # 3. 超时处理 - 修复变量名
        if [ $run_time -ge $MAX_GC_TIMEOUT ]; then
            log_message "⏱ GC超时 ($MAX_GC_TIMEOUT秒)"
            stop_gc=true
        fi
        
        # 4. 长时间无进展 (90秒)
        if [ $time_since_progress -ge 90 ]; then
            log_message "🛑 90秒无进展，停止GC"
            stop_gc=true
        fi
        
        # 5. 连续多次无进展 (10次*5秒=50秒)
        if [ $no_progress_count -ge 10 ]; then
            log_message "🛑 连续10次检测无进展，停止GC"
            stop_gc=true
        fi
        
        if $stop_gc; then
            break
        fi
    done
    
    # 停止GC
    if [ "$gc_level" -gt 0 ]; then
        lock_value "$get_f2fs_sysfs/gc_urgent" "0"
    else
        lock_value "$get_f2fs_sysfs/gc_idle" "0"
    fi
    
    local final_dirty=$(cat "$get_f2fs_sysfs/dirty_segments" 2>/dev/null || echo "N/A")
    local total_run_time=$(( $(date +%s) - start_time ))
    local total_reduction=$((start_dirty - final_dirty))
    local total_reduction_pct=$(echo "$total_reduction $start_dirty" | awk '{printf "%.2f", $1 * 100 / $2}')
    
    log_message "✅ GC完成 | 总耗时: ${total_run_time}s | 脏段变化: $start_dirty → $final_dirty | 总变化: ${total_reduction} (${total_reduction_pct}%)"
}

# 仅监控/data分区
monitor_data_partition() {
    local screen_status="$1"
    local battery_status="$2"
    
    log_message "🔍 开始检测分区: data (/data)"
    
    # 获取设备路径
    local device_path=$(df -P "/data" 2>/dev/null | awk 'NR==2 {print $1}')
    if [ -z "$device_path" ]; then
        log_message "❌ data: 无法获取设备路径"
        return 1
    fi
    
    # 提取设备名称
    local device_name=$(basename "$device_path")
    local f2fs_sysfs_path="/sys/fs/f2fs/$device_name"
    
    # 检查是否为F2FS分区
    if [ ! -d "$f2fs_sysfs_path" ]; then
        log_message "⚠️ data: 非F2FS分区 (设备: $device_path)"
        return 2
    fi
    
    # 获取分区信息
    local usage_info=$(df -h "/data" | awk 'NR==2 {print $5}')
    log_message "📊 data: 使用率 $usage_info"
    
    # 读取段信息
    local target_free_segs=$(cat "$f2fs_sysfs_path/free_segments" 2>/dev/null || echo "0")
    local target_dirty_segs=$(cat "$f2fs_sysfs_path/dirty_segments" 2>/dev/null || echo "0")
    log_message "📝 data: 段状态 | 空闲: $target_free_segs | 脏段: $target_dirty_segs"

    # 检查是否需要触发GC
    if [ "$target_dirty_segs" -ge "$FORCE_GC_THRESHOLD" ]; then
        log_message "❗ data: 脏段超过强制阈值，执行GC"
        smart_gc_control "$f2fs_sysfs_path" "$target_dirty_segs" "$screen_status"
    elif [ "$target_dirty_segs" -ge "$DIRTY_SEG_THRESHOLD" ]; then
        log_message "🔴 data: 触发GC | 脏段: $target_dirty_segs ≥ $DIRTY_SEG_THRESHOLD"
        smart_gc_control "$f2fs_sysfs_path" "$target_dirty_segs" "$screen_status"
    else
        log_message "🟢 data: 存储状态正常"
    fi
    
    log_message "✅ data: 检测完成"
    return 0
}

while true; do
    $su_write renice -n 10 $$
    cleanup_log
    log_message "---- 新一轮检测开始 ----"
    
    # 获取系统状态
    screen_status=$(get_screen_status)
    battery_status=$(get_battery_status)
    log_message "🔋 设备状态 | 屏幕: $screen_status | 电池: $battery_status"

    # 仅监控/data分区
    monitor_data_partition "$screen_status" "$battery_status"

    # 根据电池状态调整检测间隔
    local sleep_time=300
    if [ "$battery_status" = "discharging" ]; then
        sleep_time=600
        log_message "🔋 电池放电状态，延长检测间隔"
    fi
    
    log_message "---- 本轮检测结束，休眠${sleep_time}秒后继续 ----"
    sleep $sleep_time
done
