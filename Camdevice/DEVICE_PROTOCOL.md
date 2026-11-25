# Camdevice 设备识别约定

### 蓝牙

设备在 BLE 广播中声明服务 UUID `C405D5C7-16FA-48EA-86C7-497F5BE293F0`。设备名称可放在广播或扫描响应中。Mac 只扫描该服务。列表显示 CoreBluetooth 为该外设分配的 UUID，它可能因 Mac 而异。照片传输协议尚未接入。

### USB-C

设备通过 USB Mass Storage 把卷挂载到 Mac。在卷根目录提供 `CAMDEVICE.JSON`：

```json
{
  "serviceUUID": "C405D5C7-16FA-48EA-86C7-497F5BE293F0",
  "uuid": "D8156E44-D285-4FEC-AD04-4A92B2653226",
  "name": "我的相机"
}
```

`uuid` 是示例值，每台设备应有自己的持久 UUID。照片放在卷根目录的 `DCIM` 目录或其子目录。App 在用户点「导出照片」时读取照片。

### USB 串口拍照与导出

当前固件通过 USB 串口接受指令。macOS App 的「USB-C 导出」在 `/dev/cu.usbmodem*` 上以 115200 波特率发送 `id\n`，收到 `CAMDEVICE READY 1` 后显示相机。也可关闭 App 的串口操作和 PlatformIO 的串口监视器后运行：

```sh
python3 tools/camdevice_terminal.py
```

输入 `pz` 拍照并保存到 microSD 或板载 LittleFS。每次拍照前初始化摄像头，拍完释放驱动并返回 `OK Camera stopped.`，失败时返回以 `ERROR ` 开头的状态行。

`dc` 的响应从 `CAMDEVICE EXPORT 1` 开始。每张照片由 `FILE IMG_0001.JPG <字节数>` 这样的头部与紧随其后的指定字节数 JPEG 组成。下一条头部或结束行 `END` 紧接 JPEG 数据。App 将照片保存到用户选择的文件夹。终端脚本默认保存到 `~/Desktop/Camdevice`，可以用 `--port` 指定串口，用 `--output` 更改目标目录，输入 `q` 退出。

`fc` 查询清理能力。支持清理的固件返回 `CAMDEVICE FLASH CLEAR 1`。App 在用户确认永久删除后发送 `cl`。固件仅删除板载 LittleFS 的 `DCIM` 中符合 `IMG_0000.JPG` 命名格式的普通文件，即使相机当前保存照片到 microSD。固件完成后返回 `CAMDEVICE FLASH CLEARED <已删除数> <删除失败数>`，无法挂载或读取目录时返回以 `ERROR ` 开头的状态行。
