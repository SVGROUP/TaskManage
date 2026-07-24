#!/bin/sh
# TaskManage 容器启动脚本：择优 remote 拉取 + 启动 + 事件驱动自升级。

APP_DIR=/TASK
PORT="${PORT:-50010}"
UPGRADE_BLOCKED_FLAG="${UPGRADE_BLOCKED_FLAG:-$APP_DIR/upgrade_blocked}"
UPGRADE_TAG="${UPGRADE_TAG:-TASK}"
UPGRADE_BASE_URL="${UPGRADE_BASE_URL:-http://atut.efdata.fun:45678/sv/auth/api}"

select_best_remote() {
    REMOTE1="github.com"
    REMOTE2="gitee.com"
    LATENCY1=$(ping -c 2 "$REMOTE1" 2>/dev/null | tail -1 | awk '{print $4}' | cut -d '/' -f 2 | cut -d '.' -f 1)
    LATENCY2=$(ping -c 2 "$REMOTE2" 2>/dev/null | tail -1 | awk '{print $4}' | cut -d '/' -f 2 | cut -d '.' -f 1)
    if [ -z "$LATENCY1" ]; then LATENCY1=9999; fi
    if [ -z "$LATENCY2" ]; then LATENCY2=9999; fi
    if [ "$LATENCY1" -lt "$LATENCY2" ]; then
        echo "origin"
    else
        echo "gitee"
    fi
}

git_pull_best() {
    best_remote=$(select_best_remote)
    echo "Using remote: $best_remote"
    # 发布库采用孤儿分支 force-push，历史会被重写；普通 git pull 会因“unrelated histories”失败。
    # 改用 fetch + reset --hard 硬跟远端，对被覆盖的新历史免疫；--depth 1 保持浅克隆，客户端 .git 也不膨胀。
    # -c credential.helper= 强制不使用 credentials，公共库匿名拉取
    if ! git -c credential.helper= fetch --depth 1 "$best_remote" master; then
        if [ "$best_remote" != "origin" ]; then
            echo "$best_remote 拉取失败，自动 fallback 到 origin"
            git -c credential.helper= fetch --depth 1 origin master
        else
            exit 1
        fi
    fi
    git reset --hard FETCH_HEAD
}

# 从 ATUS 拉取当前 tool 的 release_hash（GitHub push 成功后 CI 上报的权威 hash）。
# 输出到 stdout；拿不到（服务端不可达 / 老服务端无该字段 / 空值）都返回空字符串。
fetch_expected_hash() {
    resp=$(curl -sf --connect-timeout 5 --max-time 10 \
        "${UPGRADE_BASE_URL}/upgrade?t=${UPGRADE_TAG}" 2>/dev/null)
    if [ -z "$resp" ]; then
        return 0
    fi
    # 简单 JSON 解 release_hash；容器内有 python3
    printf '%s' "$resp" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    v = d.get("release_hash", "") or ""
    sys.stdout.write(v.strip())
except Exception:
    pass
' 2>/dev/null
}

# 校验拉取下来的发布库 HEAD 是否与 ATUS 通告的 release_hash 一致。
# 一致 / 服务端未提供 hash（老服务端兼容）→ 返回 0（放行）
# 不一致 → 落 upgrade_blocked 告警 JSON，返回 1（拒绝重启）
verify_release_hash() {
    expected=$(fetch_expected_hash)
    if [ -z "$expected" ]; then
        echo "[hash-verify] ATUS 未返回 release_hash（老服务端或字段为空），跳过校验放行"
        return 0
    fi
    local_hash=$(git rev-parse HEAD 2>/dev/null)
    if [ -z "$local_hash" ]; then
        echo "[hash-verify] 本地 git rev-parse HEAD 失败，跳过校验放行"
        return 0
    fi
    if [ "$local_hash" = "$expected" ]; then
        echo "[hash-verify] release_hash 一致 (${local_hash})，允许升级"
        return 0
    fi
    echo "[hash-verify][WARN] 不匹配：local=${local_hash} expected=${expected}，拒绝升级"
    # 落一个告警 flag：taskmanage/upgrade.py 长轮询下轮会拾起并推飞书
    mkdir -p "$APP_DIR"
    now_ts=$(date +%s)
    printf '{"tool":"%s","local":"%s","expected":"%s","ts":%s}\n' \
        "$UPGRADE_TAG" "$local_hash" "$expected" "$now_ts" > "$UPGRADE_BLOCKED_FLAG"
    return 1
}

# 端口是否空闲：无 LISTEN 监听者返回 0（空闲），有监听者返回 1（占用）
# 容器精简镜像无 ss/fuser/lsof，改读 /proc/net/tcp[6] 判断。
# 端口十六进制：50010 = 0xC35A；state 0A = LISTEN。
# 只看 LISTEN（忽略 TIME_WAIT 等连接残留），避免误判为占用。
port_is_free() {
    hex_port=$(printf '%04X' "$PORT")
    if grep -iE "^[[:space:]]*[0-9]+:[[:space:]]*[0-9A-F]{8}:${hex_port}[[:space:]]+[0-9A-F]{8}:[0-9A-F]{4}[[:space:]]+0A" /proc/net/tcp /proc/net/tcp6 >/dev/null 2>&1; then
        return 1   # 有 LISTEN => 占用
    fi
    return 0       # 无 LISTEN => 空闲
}

# 停掉旧进程：优先按记录的 PID 精确关闭 → 名字兼底 → 等退出 → 超时强杀
# → 确认端口 LISTEN 真正消失后才返回，彻底消除新旧进程抢端口的重叠窗口。
stop_app() {
    # 1) 有记录的 PID 先精确杀
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null
    fi
    # 2) 名字兼底（PID 丢失/首次启动前残留进程）
    pkill -f "python3 run.py" 2>/dev/null

    # 等旧进程退出（最多 ~15s）
    i=0
    while [ "$i" -lt 30 ]; do
        pgrep -f "python3 run.py" >/dev/null 2>&1 || break
        i=$((i + 1))
        sleep 0.5
    done

    # 仍未退出则强杀
    if pgrep -f "python3 run.py" >/dev/null 2>&1; then
        echo "旧进程未在超时内退出，强制 SIGKILL"
        [ -n "$APP_PID" ] && kill -9 "$APP_PID" 2>/dev/null
        pkill -9 -f "python3 run.py" 2>/dev/null
        sleep 1
    fi

    # 确认端口 LISTEN 已释放（最多再等 ~10s），避免慢释放导致 bind 失败
    i=0
    while [ "$i" -lt 20 ]; do
        if port_is_free; then break; fi
        i=$((i + 1))
        sleep 0.5
    done
    APP_PID=""
}

start_app() {
    python3 run.py &
    APP_PID=$!
}

restart_app() {
    stop_app
    start_app
}

if ! git remote | grep -q "^gitee$"; then
    echo "gitee remote not found, adding..."
    git remote add gitee https://gitee.com/SVGROUP/TASK.git
fi

# 首次启动：拉最新代码 + 校验 hash 一致才启动。
# 首启若 hash 不一致（极端情况：镜像里 clone 到的 tag 跟当下 CI 通告不一致），
# 用旧代码起来对外服务比无服务好；告警文件会被 python 进程推到飞书。
git_pull_best
verify_release_hash || echo "[hash-verify] 首启不阻塞，用当前代码启动服务，等下次 CI 修复"
start_app

while true; do
    if [ -f "$APP_DIR/upgrade" ]; then
        git_pull_best
        if verify_release_hash; then
            restart_app
        else
            echo "[hash-verify] 本轮拒绝升级，保留旧进程继续对外服务"
        fi
        # 无论是否重启，都消费掉 upgrade 标志：
        # - 允许升级 → 已 restart_app，flag 应删
        # - 拒绝升级 → python 端 upgrade.py 的 _triggered_versions 已记住该 version
        #   不会再次 touch flag，直到 CI 出新 version；此处删掉旧 flag 防 inotify 死转
        rm -f "$APP_DIR/upgrade"
    fi
    # 事件驱动：$APP_DIR/upgrade 一被创建立即唤醒；无 inotify 则退回短 sleep。
    if command -v inotifywait >/dev/null 2>&1; then
        inotifywait -qq -t 300 -e create -e modify -e moved_to "$APP_DIR/" 2>/dev/null || sleep 5
    else
        sleep 10
    fi
done
