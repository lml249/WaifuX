#!/usr/bin/env python3
"""
恢复脚本：从系统壁纸配置中移除 WaifuX Choice，恢复原始壁纸。
"""

import plistlib
import subprocess
from pathlib import Path

PLIST_PATH = Path.home() / "Library/Application Support/com.apple.wallpaper/Store/Index.plist"
BUNDLE_ID = "com.waifux.app.wallpaperextension"

def main():
    if not PLIST_PATH.exists():
        print("❌ Index.plist 不存在")
        return

    with open(PLIST_PATH, "rb") as f:
        plist = plistlib.load(f)

    displays = plist.get("Displays", {})
    changed = False

    for display_uuid, display_dict in displays.items():
        for scope in ["Desktop", "Idle"]:
            scope_dict = display_dict.get(scope, {})
            content_dict = scope_dict.get("Content", {})
            choices = content_dict.get("Choices", [])

            before = len(choices)
            choices = [c for c in choices if c.get("Provider") != BUNDLE_ID]

            if len(choices) < before:
                content_dict["Choices"] = choices
                scope_dict["Content"] = content_dict
                display_dict[scope] = scope_dict
                displays[display_uuid] = display_dict
                changed = True
                print(f"  ✅ {display_uuid[:8]}.../{scope}: 移除了 {before - len(choices)} 个 WaifuX Choice")

    if not changed:
        print("ℹ️  没有找到 WaifuX Choice")
        return

    plist["Displays"] = displays

    with open(PLIST_PATH, "wb") as f:
        plistlib.dump(plist, f, fmt=plistlib.FMT_XML)

    print(f"\n✅ 已恢复 Index.plist")

    # 发送通知
    for notif in ["com.apple.wallpaper.prefsChanged", "com.apple.wallpaper.changed"]:
        subprocess.run(["notifyutil", "-p", notif], capture_output=True)

    print("📢 已发送恢复通知")

if __name__ == "__main__":
    main()
