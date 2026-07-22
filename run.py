#!/usr/bin/env python3
from taskmanage.app import main

ver = "2026-07-22 14:54:31"
ts = 1784732071
if __name__ == "__main__":
    import os
    os.environ["TASKMANAGE_VERSION"] = ver
    os.environ["TASKMANAGE_BUILD_TS"] = str(ts)
    print(f"TaskManage 主程序启动 ver={ver}")
    main(ts)
