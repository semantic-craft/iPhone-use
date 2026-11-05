---
name: iphone-use
description: "通过本地 iphone-use MCP 服务操作已连接的真实 iPhone（USB 屏幕采集/AFC/安装/日志 + 蓝牙 HID 指针与键盘 + Gemini 3.8 Flash 多步 task）。当用户要求在真机（如 Hermes）上截图、点击、滑动、输入文字、解锁、传输相册/应用文件、启动应用或执行多步移动端任务时使用。不要用于 iOS 模拟器（Simulator 请用 mobilebuildmcp）。"
---

# iPhone Use（Ghosthand 融合版真机控制技能）

通过本地 `iphone-use` MCP 服务（HTTP 控制面默认 `127.0.0.1:7390`，stdio 入口 `scripts/mcp.sh`）观察并操控通过 USB 与蓝牙连接在 Mac 上的真实 iPhone。同时支持 **Antigravity Desktop (AGY)** 与 **Codex** 双端调用。

## 1. 服务自举与就绪诊断（`--resident-quiet` + `setup_status`）

1. **按需静默自举**：调用任意 `iphone-use` MCP 工具时，若本地 `127.0.0.1:7390` 尚未运行，stdio 服务会自动以 `--resident-quiet` 模式拉起后台守护进程并等待就绪。也可显式运行：
   ```bash
   python3 <skill_dir>/scripts/ensure_service.py --wait 6
   ```
2. **先查就绪状态**：开始任务或遇到连接异常时，优先调用 `setup_status`（如 `setup_status(device: "Hermes")`），按返回的确定性步骤排查：
   - `trust`：在 iPhone 上点击“信任此电脑”并授予 macOS 相机/屏幕采集权限。
   - `unlock`：iPhone 处于锁屏状态，需调用 `unlock(passcode)` 或请用户在真机上解锁。
   - `usbUnreadable`：重插 USB 线或检查采集会话。
   - `bluetoothUnavailable` / `pair` / `connecting`：确认 Mac 蓝牙开启并在 iPhone 蓝牙设置中连接此 Mac；触控圆点依赖 `设置 > 辅助功能 > 触控 > 辅助触控`（也可通过 USB 通道调用 `assistivetouch(enabled: true)` 开启）。
   - `ready`：视频帧、蓝牙 HID 与指针均已就绪。

## 2. 设备寻址与租约锁（`acquire` / `wait` / `release`）

1. **按名或前缀寻址**：所有工具均接受 `device: "Hermes"`（不区分大小写）、`"default"`（单机接入时）、完整 `id` 或唯一 `id` 前缀。多台 iPhone 接入时必须显式传入 `device` 或 `lease`。
2. **写操作前先拿租约**：执行多步操控前调用 `acquire(device: "Hermes", reason: "<任务简述>", label: "<会话名>")` 获取单调递增租约号（默认空闲超时 `600s`），后续动作传入 `lease`，任务结束调用 `release(lease)` 释放。
   - 若设备被其他会话持有且返回 `device-leased`，可调用 `wait(device: "Hermes", reason: "...", waitSeconds: 60)` 排队等待，切勿盲目 `force: true` 抢占正在执行的任务（除非用户明确要求强制接管）。
   - 只读工具（`list_devices`、`screenshot`、`ocr_screen`、`screentext`、`setup_status`、`photo_list`、`photo_pull`、`file_list`、`file_pull`、`app_list`、`device_info`、`device_logs`）在不传 `lease` 时可直接读取。

## 3. 画面观察、动作后静止检测与 Ghosthand 操作铁律

1. **同调用返回静止画面与文字**：几乎所有动作工具（`tap`、`tap_text`、`double_tap`、`triple_tap`、`hold`、`swipe`、`hold_drag`、`scroll`、`type_text`、`press_key`、`home`、`wake`、`unlock`、`open_app`、`act`）均内置动作后静止检测循环（Post-Action Stillness Loop），支持直接传入：
   - `screentext: true`：动作完成并等待画面静止后，同调用返回当前屏幕 OCR 文本。
   - `screenshot: true`：同调用附带静止后的屏幕截图。
   - `wait_text: "<目标文本>"` 与 `timeout_ms: 5000`：等待目标文本出现在屏幕上再返回。
2. **`wait_text` 绝不盲目重试铁律**：当动作携带 `wait_text` 因超时返回 `wait-text-timeout` 时，**点击或输入动作本身已经发生**；严禁无脑重发同一点击，必须先检查返回的 `screentext` 或调用 `screenshot` 确认当前界面状态。
3. **文字优先于坐标估算（含主屏图标点击与报错可见列表）**：看到目标按钮文字时，优先用 `tap_text(text: "...", screentext: true)` 或 `act` 批量动作，减少坐标试探。所有截图/像素坐标均基于 `maxEdge = 1000` 缩放图。
   - **主屏/底栏图标点击（`icon: true` 或 `offset_x`/`offset_y`）**：iOS 主屏幕 App 图标或底部 Tab 栏的文字标签位于图标正下方，直接点文字可能无法触发图标。此时传入 `tap_text(text: "微信", icon: true)`（或 CLI `iphone-use tap_icon "微信"`，以及自定义像素偏移 `offset_x`/`offset_y`），服务端会自动向上偏移点击文字正上方的图标中心。
   - **报错自带当前可见文本列表（`saw: [...]`）**：当 `tap_text` 未找到目标文本时，错误响应会自动附带当前画面识别到的前 30 条文字（`saw: [...]`），无需额外再调一次 `ocr_screen` 即可判断是拼写差异、页面未加载还是需要先滚动。
   - **列表滚动查找与收集（`scroll` 的 `until_text` / `collect`）**：在设置页或长列表中查找元素时，可直接调用 `scroll(direction: "down", until_text: "隐私与安全性", max_scrolls: 10)` 或收集全列表文本 `scroll(direction: "down", collect: true, max_scrolls: 8)`；内部会自动过滤顶部状态栏时钟/电量（`y < 6%`）与底部 Home 指示条（`y > 92%`）的干扰，在滚到底部连续无新内容时自动停止（`stopReason: "reached-end"`）。
   - **OCR 置信度与内容区过滤**：`ocr_screen` 与 `screentext` 支持 `min_confidence: 0.5`（过滤低置信度噪点）与 `content_only: true`（仅保留中部内容区文本，剔除状态栏与底部横条），每条 OCR 结果均携带 `"source": "pixels"` 溯源标记。
4. **锁屏密码 `unlock` 绝不重试铁律**：`unlock(passcode)` 若报错或未能进入主屏，**绝对禁止重试第二次**（连续输错密码会导致真机永久停用锁死），必须立即停止并交由人工处理。
5. **原生高清截图 `screenshot(native: true)`**：常规观察用默认 USB 采集流 `screenshot`；当用户明确需要保存在相册级清晰度的原生截图时，传 `screenshot(native: true)`（通过 HID `Cmd+Shift+3` 触发并经 USB 读取后自动清理相机胶卷原图，响应带 `X-Note: deleted`）。
6. **消息发送与输入框清空铁律（`submit: true`）**：在微信、iMessage、搜索框等文本提交场景中，**绝对禁止盲目点击输入框右侧坐标**（真机连接外接蓝牙键盘时，右下角通常是功能菜单 `+`，点击只会展开相册/拍摄面板并让文字滞留在输入框）。发送文字必须使用 `type_text(text: "...", submit: true)` 原子化完成候选词上屏与回车提交；发送后必须核验输入框已清空且消息已在聊天区域上屏，严禁将输入框内未发出的文本误判为发送成功。
7. **单回合多步 Python 组合脚本（`iphone-use exec` / `phone_exec.py`）**：当任务包含条件分支、循环抓取或需要沉淀可复用的应用级辅助函数时，可使用 `phone_exec.py`（或 CLI `iphone-use exec <<'PY'`）在单次调用内组合 `open_app`、`tap_text`、`tap_icon`、`scroll_until`、`scroll_collect`、`wait_for_text`、`screen` 等原语，并可将常用流程保存在 `~/.iphone-use/agent-workspace/agent_helpers.py` 跨会话自动加载：
   ```bash
   python3 <skill_dir>/scripts/phone_exec.py <<'PY'
   open_app("Settings", wait_text="General")
   item = scroll_until("Privacy & Security", max_scrolls=8)
   if item:
       tap_text("Privacy & Security", screentext=True)
   PY
   ```

## 4. USB 系统通道（相册 / 文件 / 应用 / 日志 / AssistiveTouch）

无需点亮屏幕即可通过 USB 访问系统元数据，解锁后可读写媒体与容器文件：
- **相册通道**：`photo_list`、`photo_pull`、`photo_push`（将 Mac 本地图片/视频如 `.mp4` 导入 `/DCIM/100APPLE` 供 TikTok/小红书等直接选用）、`photo_delete`。
  - **铁律**：严禁使用 `file_remove` 删除 `/DCIM` 下的文件（AFC 直接删文件会导致系统相册残留破损缩略图，服务端会以 `dcim-remove-forbidden` 拒绝）；删除相册媒体必须用 `photo_delete`。
- **文件通道**：`file_list`、`file_pull`、`file_push`、`file_remove`（支持 `bundle_id` 访问开启 File Sharing 的应用 `Documents` 容器或 `/var/mobile/Media`）。
- **应用与诊断通道**：`app_list`、`open_app(app: "TikTok", wait_text: "...", screentext: true)`、`device_info`（锁屏可用，读取机型、iOS 版本、序列号、电池、存储、SIM 与 AssistiveTouch 状态）、`device_logs`、`assistivetouch(enabled: true|false)`。

## 5. Gemini 3.8 Flash 自主多步 `task(prompt, resume)` 与安全门禁

对于跨界面的自然语言多步任务，可调用 `task(device: "Hermes", lease: "<id>", prompt: "...", thinking_level: "low|medium|high")`：
- 内部基于 `gemini-3.8-flash` Interactions API（`computer_use` mobile `0..999` 网格坐标 + `previous_interaction_id` 多轮状态链）自主循环执行。
- **三层敏感操作门禁**：遇到公开社交发布（如点击 `Post` / `发布`）、资金支付、密码输入或不可逆删除时，通过模型显式调用 `yield_to_user`、服务端 `safety_decision` 或客户端 OCR 命中拦截，任务会停在 `state: "yielded"` 并返回 `task` ID 与 `yield_reason`。
- 收到 `yielded` 后，向用户展示发布前最后一步截图与待确认操作；获用户明确批准后，再调用 `task(resume: "<task_id>", approve: true, prompt: "...")` 继续完成。

## 6. MCP 传输断开时的单次自愈（`mcp_call.py`）

若宿主（Codex 或 AGY）内置 MCP 通道报 `Transport closed`：
1. 运行 `python3 <skill_dir>/scripts/ensure_service.py --wait 6` 确认本地服务在线。
2. 使用 `<skill_dir>/scripts/mcp_call.py` 发起单次全新 stdio 调用（支持全部 46 个工具）：
   ```bash
   python3 <skill_dir>/scripts/mcp_call.py setup_status --arguments '{"device":"Hermes"}'
   python3 <skill_dir>/scripts/mcp_call.py screenshot --arguments '{"device":"Hermes","screentext":true}' --output-dir /tmp/iphone-use
   ```
3. 若写操作返回 `"may_have_executed": true`，重试前必须先 `screenshot` 或 `screentext` 核实画面是否已变化。
