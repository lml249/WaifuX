#!/usr/bin/env python3
"""
测试脚本：手动修改系统壁纸 Index.plist，将 WaifuX 设为锁屏动态壁纸。
用于验证 Choice 结构和 scope 是否正确。

用法: python3 scripts/test-lockscreen-wallpaper.py [video_id]
默认 video_id: pozemka-test
"""

import plistlib
import subprocess
import sys
import shutil
from pathlib import Path
from datetime import datetime

PLIST_PATH = Path.home() / "Library/Application Support/com.apple.wallpaper/Store/Index.plist"
BUNDLE_ID = "com.claretmoon.waifux.app.wallpaperextension"
VIDEO_ID = sys.argv[1] if len(sys.argv) > 1 else "pozemka-test"

def main():
    print(f"🎬 测试锁屏动态壁纸设置")
    print(f"   视频 ID: {VIDEO_ID}")
    print(f"   Provider: {BUNDLE_ID}")
    print(f"   Plist: {PLIST_PATH}")
    print()

    # 1. 读取现有 plist
    if not PLIST_PATH.exists():
        print("❌ Index.plist 不存在！")
        return

    with open(PLIST_PATH, "rb") as f:
        plist = plistlib.load(f)

    displays = plist.get("Displays", {})
    print(f"📺 发现 {len(displays)} 个显示器")

    # 2. 构建 Choice（匹配系统原生结构）
    new_choice = {
        "Configuration": VIDEO_ID.encode("utf-8"),  # 视频 ID 的 UTF-8 Data
        "Files": [],
        "Provider": BUNDLE_ID,
    }

    print(f"\n📝 Choice 结构:")
    print(f"   Provider: {new_choice['Provider']}")
    print(f"   Configuration: {new_choice['Configuration']} (UTF-8 Data)")
    print(f"   Files: {new_choice['Files']}")

    # 3. 更新每个显示器的 Desktop 和 Idle scope
    changed = False
    for display_uuid, display_dict in displays.items():
        print(f"\n🖥️  显示器: {display_uuid[:8]}...")

        for scope in ["Desktop", "Idle"]:
            scope_dict = display_dict.get(scope, {})
            content_dict = scope_dict.get("Content", {})
            choices = content_dict.get("Choices", [])

            # 记录修改前的 Provider 列表
            before_providers = [c.get("Provider", "???") for c in choices]

            # 移除旧的 WaifuX choice
            choices = [c for c in choices if c.get("Provider") != BUNDLE_ID]
            removed = len(before_providers) - len(choices)

            # 追加新的 WaifuX choice
            choices.append(new_choice)

            # 写回
            content_dict["Choices"] = choices
            scope_dict["Content"] = content_dict
            display_dict[scope] = scope_dict
            displays[display_uuid] = display_dict

            providers_after = [c.get("Provider", "???")[:30] for c in choices]
            print(f"   {scope}: {removed} 个旧 Choice 移除, 现有 {len(choices)} 个 → {providers_after}")
            changed = True

    if not changed:
        print("\n⚠️ 没有需要更新的显示器")
        return

    plist["Displays"] = displays

    # 4. 写入临时文件 → 校验 → 覆盖
    temp_path = PLIST_PATH.with_suffix(".plist.tmp")
    try:
        with open(temp_path, "wb") as f:
            plistlib.dump(plist, f, fmt=plistlib.FMT_XML)

        # 校验
        verify_size = temp_path.stat().st_size
        if verify_size == 0:
            raise RuntimeError("写入的文件为空")

        # 备份原文件
        backup_path = PLIST_PATH.with_suffix(f".plist.bak.{datetime.now().strftime('%H%M%S')}")
        shutil.copy2(PLIST_PATH, backup_path)
        print(f"\n💾 已备份原文件: {backup_path.name}")

        # 覆盖
        shutil.move(str(temp_path), str(PLIST_PATH))
        print(f"✅ 已写入 Index.plist ({verify_size} bytes)")

    except Exception as e:
        print(f"\n❌ 写入失败: {e}")
        temp_path.unlink(missing_ok=True)
        return

    # 5. 发送系统通知
    print("\n📢 发送 Darwin 通知...")
    notifications = [
        "com.apple.wallpaper.prefsChanged",
        "com.apple.wallpaper.changed",
        "com.apple.wallpaper.wallpaperDidChange",
    ]
    for notif in notifications:
        result = subprocess.run(
            ["notifyutil", "-p", notif],
            capture_output=True, text=True
        )
        status = "✅" if result.returncode == 0 else "❌"
        print(f"   {status} {notif}")

    # 6. 验证写入结果
    print("\n🔍 验证写入结果...")
    with open(PLIST_PATH, "rb") as f:
        verify_plist = plistlib.load(f)

    for display_uuid, display_dict in verify_plist.get("Displays", {}).items():
        for scope in ["Desktop", "Idle"]:
            choices = display_dict.get(scope, {}).get("Content", {}).get("Choices", [])
            waifux_choices = [c for c in choices if c.get("Provider") == BUNDLE_ID]
            if waifux_choices:
                c = waifux_choices[0]
                config = c.get("Configuration", b"")
                config_str = config.decode("utf-8") if isinstance(config, bytes) and config else repr(config)
                print(f"   ✅ {display_uuid[:8]}.../{scope}: Provider={c['Provider']}, Config={config_str}")
            else:
                print(f"   ❌ {display_uuid[:8]}.../{scope}: 未找到 WaifuX Choice")

    print(f"\n🎯 完成！请锁屏查看效果。")
    print(f"   如果锁屏没有变化，可能需要:")
    print(f"   1. 等待几秒让系统检测到变更")
    print(f"   2. 在系统设置 → 壁纸中手动选择 WaifuX 视频")
    print(f"   3. 检查扩展是否正确加载 (Console.app 搜索 'WaifuX')")


if __name__ == "__main__":
    main()
