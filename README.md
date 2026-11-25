# Camdevice

Camdevice 是一个相机原型，包含适用于 Seeed Studio XIAO ESP32S3 Sense 的拍照固件和一个用 SwiftUI 编写的 macOS 照片管理应用。

## 项目结构

| 路径 | 用途 |
| --- | --- |
| [`src/main.cpp`](src/main.cpp) | 相机固件，拍摄 JPEG 并保存到 microSD 卡或板载 LittleFS 的 `DCIM` 目录 |
| [`platformio.ini`](platformio.ini) | PlatformIO 构建配置 |
| [`Camdevice/Camdevice.xcodeproj`](Camdevice/Camdevice.xcodeproj) | macOS 应用的 Xcode 工程，最低支持 macOS 14 |
| [`Button-Wiring.png`](Button-Wiring.png) | 快门按钮接线图 |
| [`Camdevice/DEVICE_PROTOCOL.md`](Camdevice/DEVICE_PROTOCOL.md) | macOS 应用的 BLE 和 USB 设备识别约定 |

## 构建与运行

在项目根目录用 PlatformIO 构建相机固件。

```sh
pio run -e xiao_esp32s3_sense
```

在 Xcode 中打开 `Camdevice/Camdevice.xcodeproj`，选择 Camdevice 和 My Mac，然后点击 Run。

## 当前功能

- 固件支持实体快门和 USB 串口触发拍照。烧录后运行 `python3 tools/camdevice_terminal.py`，输入 `pz` 拍照，输入 `dc` 将设备里的照片导出到 `~/Desktop/Camdevice`。
- App 首次使用时会请你选择照片文件夹。导出的照片直接写入该文件夹，在「照片文件夹」页可预览、在访达中打开或更换位置。旧版相册中的照片仍保存在 `~/Library/Application Support/PenCam/Album`。
- 用支持数据传输的 USB-C 线连接相机，关闭拍照终端或串口监视器，然后在 macOS 应用打开「USB-C 导出」。应用会识别运行 Camdevice 固件的相机，可直接拍照和导出照片，也支持符合设备识别约定的 USB 存储卷。
- 更新相机固件后，在「USB-C 导出」中选择「清理闪存照片」并确认，即可删除板载 LittleFS 里的 Camdevice 照片。microSD 和 Mac 文件夹里的照片会保留。
- macOS 应用支持发现兼容的 BLE 设备。蓝牙照片传输尚未实现。
