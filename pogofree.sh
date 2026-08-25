#!/bin/sh
# Snapmaker U1 PogoFree installer. Run this file as root on the printer.
exec /usr/bin/python3 - "$@" <<'PY'
import argparse
import datetime as dt
import difflib
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


DEFAULT_CONFIG = Path("/home/lava/printer_data/config/printer.cfg")
DEFAULT_STATE_DIR = Path("/home/lava/printer_data/config/pogo-free")
MARKER_BEGIN = "# >>> U1_POGO_FREE DISABLED SECTION BEGIN"
MARKER_END = "# <<< U1_POGO_FREE DISABLED SECTION END"
STATE_VERSION = 3

PARK_DETECTORS = (
    "[park_detector extruder]",
    "[park_detector extruder1]",
    "[park_detector extruder2]",
    "[park_detector extruder3]",
)
EXTRUDERS = ("[extruder]", "[extruder1]", "[extruder2]", "[extruder3]")
TOOLHEADS = {
    1: ("extruder", "e0", "[fan_generic e0_fan]"),
    2: ("extruder1", "e1", "[fan_generic e1_fan]"),
    3: ("extruder2", "e2", "[fan_generic e2_fan]"),
    4: ("extruder3", "e3", "[fan_generic e3_fan]"),
}
MANAGED_SECTIONS = (
    *PARK_DETECTORS,
    "[fan]",
    *EXTRUDERS,
    *(entry[2] for entry in TOOLHEADS.values()),
    "[purifier]",
    "[output_pin diy_purifier_power]",
    "[fan_generic diy_purifier_test]",
)


def fail(message):
    print("错误：" + message, file=sys.stderr)
    raise SystemExit(1)


def ask(prompt):
    """Read interactive input from the terminal, not this script's heredoc stdin."""
    try:
        with open("/dev/tty", "r", encoding="utf-8") as terminal:
            print(prompt, end="", flush=True)
            return terminal.readline().strip()
    except OSError:
        fail("无法读取终端输入；请使用 --mode 参数进行非交互安装")


def find_section(lines, header):
    start = None
    for index, line in enumerate(lines):
        if line.strip() == header:
            start = index
            break
    if start is None:
        return None
    end = len(lines)
    for index in range(start + 1, len(lines)):
        stripped = lines[index].strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            end = index
            break
    return start, end


def section_text(lines, header):
    location = find_section(lines, header)
    if location is None:
        return None
    start, end = location
    return "".join(lines[start:end])


def replace_section(lines, header, replacement, before_header=None):
    location = find_section(lines, header)
    if location is None:
        if replacement is None:
            return lines
        replacement_lines = replacement.splitlines(keepends=True)
        if before_header:
            anchor = find_section(lines, before_header)
            if anchor is not None:
                return lines[:anchor[0]] + replacement_lines + lines[anchor[0]:]
        if lines and lines[-1].strip():
            lines.append("\n")
        return lines + replacement_lines
    start, end = location
    new_lines = [] if replacement is None else replacement.splitlines(keepends=True)
    return lines[:start] + new_lines + lines[end:]


def remove_disabled_blocks(lines):
    output = []
    index = 0
    while index < len(lines):
        if lines[index].strip() == MARKER_BEGIN:
            index += 1
            while index < len(lines) and lines[index].strip() != MARKER_END:
                index += 1
            if index == len(lines):
                fail("检测到不完整的 U1_POGO_FREE 配置标记")
            index += 1
        else:
            output.append(lines[index])
            index += 1
    return output


def disable_section(lines, header, reason):
    location = find_section(lines, header)
    if location is None:
        return lines
    start, end = location
    disabled = [
        MARKER_BEGIN + "\n",
        "# " + reason + "\n",
    ]
    for line in lines[start:end]:
        disabled.append("# " + line if line.strip() else "#\n")
    disabled.append(MARKER_END + "\n")
    return lines[:start] + disabled + lines[end:]


def key_value(section, key):
    for line in section[1:]:
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if stripped.startswith(key + ":"):
            return stripped.split(":", 1)[1].strip()
    return None


def set_key(section, key, value):
    retained = [section[0]]
    for line in section[1:]:
        stripped = line.strip()
        if not stripped.startswith("#") and stripped.startswith(key + ":"):
            continue
        retained.append(line)
    retained.insert(1, f"{key}: {value}\n")
    return retained


def remove_key(section, key):
    return [
        line for line in section
        if line.strip().startswith("#") or not line.strip().startswith(key + ":")
    ]


def update_section(lines, header, update):
    location = find_section(lines, header)
    if location is None:
        fail("printer.cfg 缺少必要配置段：" + header)
    start, end = location
    section = update(lines[start:end])
    return lines[:start] + section + lines[end:]


def restore_original_sections(text, state):
    lines = remove_disabled_blocks(text.splitlines(keepends=True))
    for header in MANAGED_SECTIONS:
        lines = replace_section(
            lines,
            header,
            state["sections"].get(header),
            state["section_anchors"].get(header),
        )
    return lines


def patch_detectors(lines):
    for header in PARK_DETECTORS:
        def update(section):
            grab_pin = key_value(section, "grab_valid_pin")
            grab_range = key_value(section, "grab_valid_analog_range")
            if not grab_pin or not grab_range:
                fail(header + " must define grab_valid_pin and grab_valid_analog_range")
            section = set_key(section, "active_pin", grab_pin)
            section = set_key(section, "active_analog_range", grab_range)
            section = remove_key(section, "state_logic")
            return section
        lines = update_section(lines, header, update)
    return lines


def patch_shared_fan_binding(lines):
    for header in EXTRUDERS:
        def update(section):
            section = set_key(section, "fan", "fan")
            return set_key(section, "fan_speed_check_enable", "False")
        lines = update_section(lines, header, update)
    return lines


def patch_plan_a(lines, toolhead):
    _, mcu, generic_header = TOOLHEADS[toolhead]

    def update_fan(section):
        section = set_key(section, "pin", f"{mcu}:PB3")
        section = set_key(section, "tachometer_pin", f"{mcu}:PB4")
        section = set_key(section, "tachometer_poll_interval", "0.001")
        section = set_key(section, "cycle_time", "0.005")
        return set_key(section, "shutdown_speed", "0")

    lines = update_section(lines, "[fan]", update_fan)
    lines = disable_section(
        lines,
        generic_header,
        "Disabled by U1 Pogo-Free Plan A: global [fan] owns this toolhead fan pin.",
    )
    return patch_shared_fan_binding(patch_detectors(lines))


def patch_plan_b(lines):
    # The stock purifier also owns PA8/PE15. Disable it before assigning PA8 to [fan].
    lines = disable_section(
        lines,
        "[purifier]",
        "Disabled by U1 Pogo-Free Plan B: PA8 and PE15 are reassigned to the shared fan.",
    )
    lines = disable_section(
        lines,
        "[fan_generic diy_purifier_test]",
        "Disabled by U1 Pogo-Free Plan B: global [fan] owns PA8.",
    )

    def update_fan(section):
        section = set_key(section, "pin", "!PA8")
        section = remove_key(section, "tachometer_pin")
        section = remove_key(section, "tachometer_poll_interval")
        section = set_key(section, "cycle_time", "0.0005")
        return set_key(section, "shutdown_speed", "0")

    lines = update_section(lines, "[fan]", update_fan)
    power_section = "[output_pin diy_purifier_power]\npin: PE15\nvalue: 1\nshutdown_value: 0\n"
    lines = replace_section(lines, "[output_pin diy_purifier_power]", power_section)
    return patch_shared_fan_binding(patch_detectors(lines))


def read_printer_state():
    url = "http://127.0.0.1:7125/printer/objects/query?print_stats"
    try:
        with urllib.request.urlopen(url, timeout=2) as response:
            payload = json.load(response)
        return payload["result"]["status"]["print_stats"]["state"]
    except (OSError, ValueError, KeyError, urllib.error.URLError):
        return None


def wait_until_ready(timeout=25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen("http://127.0.0.1:7125/server/info", timeout=2) as response:
                payload = json.load(response)
            if payload["result"].get("klippy_state") == "ready":
                return True
        except (OSError, ValueError, KeyError, urllib.error.URLError):
            pass
        time.sleep(1)
    return False


def write_atomically(path, content):
    stat = path.stat()
    tmp = path.with_name(path.name + ".pogo-free.tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())
    os.chown(tmp, stat.st_uid, stat.st_gid)
    os.chmod(tmp, stat.st_mode)
    os.replace(tmp, path)


def create_or_load_state(config, state_path):
    if state_path.exists():
        try:
            state = json.loads(state_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            fail("无法读取安装器状态文件：" + str(exc))
        if state.get("version") != STATE_VERSION:
            fail("安装器状态文件版本不受支持")
        return state

    original_text = config.read_text(encoding="utf-8")
    lines = original_text.splitlines(keepends=True)
    if any("U1_DIY_REWIRE" in line or "U1_POGO_FREE" in line for line in lines):
        fail(
            "printer.cfg 已包含旧版 DIY 修改。请先恢复未经修改的 printer.cfg，"
            "再运行本安装器。"
        )
    sections = {header: section_text(lines, header) for header in MANAGED_SECTIONS}
    section_anchors = {}
    for header in MANAGED_SECTIONS:
        location = find_section(lines, header)
        if location is None:
            section_anchors[header] = None
            continue
        _, end = location
        anchor = None
        for line in lines[end:]:
            stripped = line.strip()
            if stripped.startswith("[") and stripped.endswith("]"):
                anchor = stripped
                break
        section_anchors[header] = anchor
    for header in (*PARK_DETECTORS, "[fan]", *EXTRUDERS):
        if sections[header] is None:
            fail("printer.cfg 缺少必要配置段：" + header)
    state = {
        "version": STATE_VERSION,
        "created_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "baseline_config": str(config),
        "mode": "stock",
        "toolhead": None,
        "last_backup": None,
        "ends_with_newline": original_text.endswith("\n"),
        "sections": sections,
        "section_anchors": section_anchors,
    }
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return state


def print_diff(old, new, config):
    diff = difflib.unified_diff(
        old.splitlines(), new.splitlines(), fromfile=str(config), tofile=str(config), lineterm=""
    )
    print("\n".join(diff))


def choose_mode():
    print("Snapmaker U1 PogoFree 安装器")
    print("1) 方案 A：复用一个工具头的风扇接口")
    print("2) 方案 B：官方顶盖 6Pin 接口 + 外置 MOSFET")
    print("3) 恢复安装器管理的原始配置")
    print("4) 查看安装器状态")
    answer = ask("请选择 [1-4]：")
    modes = {"1": "plan-a", "2": "plan-b", "3": "restore", "4": "status"}
    if answer not in modes:
        fail("选择无效")
    return modes[answer]


def choose_toolhead():
    answer = ask("方案 A 控制风扇的工具头 [1-4]：")
    try:
        toolhead = int(answer)
    except ValueError:
        fail("工具头必须是 1、2、3 或 4")
    if toolhead not in TOOLHEADS:
        fail("工具头必须是 1、2、3 或 4")
    return toolhead


def restart_klipper():
    result = subprocess.run(["/etc/init.d/S60klipper", "restart"], check=False)
    if result.returncode:
        fail("Klipper 重启命令执行失败")


def main():
    parser = argparse.ArgumentParser(description="Snapmaker U1 PogoFree 安装器")
    parser.add_argument("--mode", choices=("plan-a", "plan-b", "restore", "status"))
    parser.add_argument("--toolhead", type=int, choices=tuple(TOOLHEADS))
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--state-dir", type=Path, default=DEFAULT_STATE_DIR)
    parser.add_argument("--yes", action="store_true", help="跳过交互确认")
    parser.add_argument("--check", action="store_true", help="仅显示差异，不写入配置")
    parser.add_argument("--no-restart", action="store_true", help="不自动重启 Klipper")
    args = parser.parse_args()

    config = args.config.resolve()
    if not config.is_file():
        fail("找不到 printer.cfg：" + str(config))
    if config == DEFAULT_CONFIG and os.geteuid() != 0:
        fail("请在打印机上使用 root 账户运行")

    mode = args.mode or choose_mode()
    state_path = args.state_dir / "pogo-free-state.json"
    if mode == "status":
        if not state_path.exists():
            print("尚未找到安装器状态文件；该 printer.cfg 尚未被本安装器修改。")
            return
        state = json.loads(state_path.read_text(encoding="utf-8"))
        print(json.dumps({key: state.get(key) for key in ("created_at", "mode", "toolhead", "last_backup")}, ensure_ascii=False, indent=2))
        return

    if mode == "plan-a":
        toolhead = args.toolhead if args.toolhead is not None else choose_toolhead()
    else:
        toolhead = None

    print_state = read_printer_state()
    if print_state in ("printing", "paused"):
        fail("打印机当前状态为 " + print_state + "，打印或暂停期间禁止修改配置")

    if mode == "plan-b" and not args.yes:
        print("方案 B 使用官方顶盖 6Pin 接口，请按 PCB 丝印连接 24V、PWM、GND 和外置 MOSFET。")
        answer = ask("确认硬件接线已完成，继续吗？[y/N]：").lower()
        if answer != "y":
            print("已取消。")
            return
    if mode == "restore" and not args.yes:
        answer = ask("恢复为安装器记录的原始配置吗？[y/N]：").lower()
        if answer != "y":
            print("已取消。")
            return

    state = create_or_load_state(config, state_path)
    old = config.read_text(encoding="utf-8")
    base_lines = restore_original_sections(old, state)
    if mode == "plan-a":
        new = "".join(patch_plan_a(base_lines, toolhead))
    elif mode == "plan-b":
        new = "".join(patch_plan_b(base_lines))
    else:
        new = "".join(base_lines)
        if not state["ends_with_newline"] and new.endswith("\n"):
            new = new[:-1]

    if old == new:
        print("配置无需修改。")
        return
    if args.check:
        print_diff(old, new, config)
        return

    backup_dir = args.state_dir / "backups"
    backup_dir.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    backup = backup_dir / f"printer.cfg.{mode}.{stamp}.bak"
    shutil.copy2(config, backup)
    write_atomically(config, new)

    state["mode"] = mode
    state["toolhead"] = toolhead
    state["last_backup"] = str(backup)
    state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("备份：" + str(backup))

    if args.no_restart:
        print("配置已写入，请在准备好后手动重启 Klipper。")
        return

    restart_klipper()
    if wait_until_ready():
        print("Klipper 已就绪。" + ("已恢复原始受管配置。" if mode == "restore" else "安装完成。"))
        return

    print("Klipper 未能就绪，正在恢复备份...", file=sys.stderr)
    write_atomically(config, backup.read_text(encoding="utf-8"))
    restart_klipper()
    fail("已自动回滚，请检查备份文件和 Klipper 日志")


if __name__ == "__main__":
    main()
PY
