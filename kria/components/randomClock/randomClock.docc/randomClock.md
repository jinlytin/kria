# ``kria``

`randomClock` 是 `kria` 项目中的随机闹钟组件模块，负责工作台中的随机提醒能力。

## Overview

随机闹钟功能提供以下能力：

- 随机提醒：按配置区间（分钟）随机触发提醒
- 主动关闭：用户可手动关闭当前提醒并进入下一轮
- 自动关闭：无操作时 10 秒后自动关闭并进入下一轮
- 前台提醒：提醒弹窗在当前桌面显示并激活应用

模块结构：

- `randomClock.swift`：randomClock 组件入口视图
- `views/`：卡片与弹窗视图
- `viewModels/`：随机闹钟状态与调度逻辑
- `services/`：弹窗窗口生命周期和提醒会话协调

## Topics

### Key Views

- ``RandomClockFeatureView``
- ``RandomClockCardView``
- ``RandomClockReminderPopupView``

### Key Logic

- ``RandomClockViewModel``
- ``RandomClockReminderWindowCoordinator``
