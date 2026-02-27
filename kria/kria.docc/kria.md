# ``kria``

`kria` 是一个 macOS 工作台项目，支持通过组件化方式集成多个效率工具。

当前已集成组件：

- `randomClock`：随机闹钟提醒组件

## Overview

项目分层建议：

- `kriaApp/`：应用入口与场景声明
- `components/`：按功能拆分的组件目录
- `Products/`：构建产物（由 Xcode 生成）

运行方式：

- 通过 `KriaWorkbenchApp` 启动工作台主窗口
- 工作台当前展示随机闹钟卡片
- 提醒通过独立弹窗展示，支持手动/自动关闭

## Topics

### App Entry

- ``KriaWorkbenchApp``

### Workbench API

- ``WorkbenchView``
- ``KriaWorkbenchLauncher``

### Component: randomClock

- ``RandomAlarmController``
- ``AlarmPopupCoordinator``
- ``RandomAlarmCard``
