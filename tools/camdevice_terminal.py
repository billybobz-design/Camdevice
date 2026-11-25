#!/usr/bin/env python3
"""Operate the XIAO camera over its native USB serial port on macOS."""

import argparse
import errno
import fcntl
import glob
import os
from pathlib import Path
import re
import select
import tempfile
import termios
import tty


class CameraPort:
    def __init__(self, fd):
        self.fd = fd
        self.pending = bytearray()

    def command(self, command):
        os.write(self.fd, (command + "\n").encode("ascii"))

    def fill(self):
        if not select.select([self.fd], [], [], 20)[0]:
            raise TimeoutError("等待开发板响应超时。")
        block = os.read(self.fd, 65536)
        if not block:
            raise OSError("USB 已断开。")
        self.pending.extend(block)

    def line(self):
        while (index := self.pending.find(b"\n")) < 0:
            if len(self.pending) > 1024:
                raise ValueError("收到无效的设备响应。")
            self.fill()
        line = bytes(self.pending[:index]).rstrip(b"\r")
        del self.pending[:index + 1]
        return line

    def copy_bytes(self, count, output):
        while count:
            if not self.pending:
                self.fill()
            length = min(count, len(self.pending))
            output.write(self.pending[:length])
            del self.pending[:length]
            count -= length


def save_photo(camera, folder, filename, size):
    destination = folder / filename
    with tempfile.NamedTemporaryFile(dir=folder, prefix=".camdevice-", delete=False) as output:
        partial = Path(output.name)
        try:
            camera.copy_bytes(size, output)
            output.flush()
            suffix = 1
            while True:
                try:
                    os.link(partial, destination)
                    return destination
                except FileExistsError:
                    suffix += 1
                    destination = folder / f"{Path(filename).stem} ({suffix}).JPG"
        finally:
            partial.unlink(missing_ok=True)


def export(camera, folder):
    camera.command("dc")
    header = camera.line()
    if header != b"CAMDEVICE EXPORT 1":
        raise ValueError(header.decode("utf-8", errors="replace"))
    count = 0
    while (line := camera.line()) != b"END":
        match = re.fullmatch(rb"FILE (IMG_\d{4}\.JPG) ([1-9]\d{0,7})", line)
        if not match:
            raise ValueError("设备文件头格式不正确。")
        filename = match[1].decode("ascii")
        print(f"已保存 {save_photo(camera, folder, filename, int(match[2]))}")
        count += 1
    print(f"导出完成，共 {count} 张。")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", help="USB 串口，例如 /dev/cu.usbmodem1101")
    parser.add_argument("--output", type=Path, default=Path.home() / "Desktop" / "Camdevice")
    args = parser.parse_args()

    if not args.port:
        ports = sorted(glob.glob("/dev/cu.usbmodem*"))
        if len(ports) != 1:
            parser.error("请连接一块开发板，或用 --port 指定串口。" + (" 找到：" + ", ".join(ports) if ports else ""))
        args.port = ports[0]

    try:
        fd = os.open(args.port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK | os.O_EXLOCK)
        try:
            fcntl.ioctl(fd, termios.TIOCEXCL)
            try:
                run_terminal(fd, args.output.expanduser())
            finally:
                try:
                    fcntl.ioctl(fd, termios.TIOCNXCL)
                except OSError:
                    pass
        finally:
            os.close(fd)
    except OSError as error:
        if error.errno in {errno.EBUSY, errno.EWOULDBLOCK}:
            parser.exit(1, "串口正被占用。请关闭 App 的 USB 操作或其他串口工具，再重试。\n")
        parser.exit(1, f"{error}\n")
    except ValueError as error:
        parser.exit(1, f"{error}\n")
    except (EOFError, KeyboardInterrupt):
        print()


def run_terminal(fd, folder):
    os.set_blocking(fd, True)
    tty.setraw(fd, termios.TCSANOW)
    settings = termios.tcgetattr(fd)
    settings[4] = settings[5] = termios.B115200
    termios.tcsetattr(fd, termios.TCSANOW, settings)
    termios.tcflush(fd, termios.TCIFLUSH)
    camera = CameraPort(fd)
    camera.command("id")
    for _ in range(12):
        if camera.line() == b"CAMDEVICE READY 1":
            break
    else:
        raise ValueError("该串口没有运行 Camdevice 固件。")

    print("已连接。pz 拍照 · dc 导出 · q 退出")
    while True:
        command = input("camdevice> ").strip().lower()
        if command == "q":
            break
        if command == "pz":
            camera.command("pz")
            while True:
                line = camera.line().decode("utf-8", errors="replace")
                print(line)
                if line.startswith(("OK ", "ERROR ")):
                    break
        elif command == "dc":
            folder.mkdir(parents=True, exist_ok=True)
            export(camera, folder)
        elif command:
            print("请输入 pz、dc 或 q。")


if __name__ == "__main__":
    main()
