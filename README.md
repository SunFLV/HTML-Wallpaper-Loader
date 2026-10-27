# HTML 壁纸加载器（零安装桌面版）

把任意网页 / 本地 HTML 文件 / HTML 代码渲染成 **真正的 Windows 桌面**，且**桌面图标与操作层停留在壁纸之上**。

无需 npm、无需安装任何运行库、无需编译原生模块、**也不需要 Edge/Chrome**：只用 Windows 自带的 **PowerShell 5.1** + 系统自带的 **WebView2 运行时**（Win10/11 出厂就有），页面由**本程序自己拥有的一体化小浏览器**渲染（见下文「内置小浏览器」）。

---

## 快速开始

1. 双击 **`start.cmd`**（或直接运行）：

```powershell
powershell -ExecutionPolicy Bypass -File .\wallpaper.ps1
```

2. 壁纸立刻铺满桌面，桌面图标、右键菜单、拖拽等照常可用。
3. 任务栏通知区出现**托盘图标**：左键开设置，右键出菜单。

> 想看日志/排查问题，就在控制台里直接跑 `wallpaper.ps1`（`start.cmd` 是隐藏窗口版）。

## 托盘图标

启动后通知区会出现小程序图标：

| 操作 | 作用 |
| --- | --- |
| **左键单击** | 打开 / 唤起设置窗口 |
| **右键** | 弹出菜单 |

右键菜单项：

- **打开设置** — 调出 GUI（加粗为默认项）
- **重新贴合桌面** — 重新解析桌面父窗口并重新铺满，资源管理器重启 / 分辨率变化后用它
- **切换挂接模式** — 在 `defview / workerw / progman / zorder / bottom` 间循环
- **打开配置文件夹** — 编辑 `config.json`
- **退出** — 关闭壁纸并结束后台进程

## 快捷键（与托盘并存）

| 快捷键 | 作用 |
| --- | --- |
| `Ctrl+Alt+S` | 打开 / 唤起设置窗口 |
| `Ctrl+Alt+M` | 切换挂接模式（挂上了却看不到壁纸时用它循环） |
| `Ctrl+Alt+E` | 打开配置文件夹（编辑 `config.json`） |
| `Ctrl+Alt+Q` | 退出 |

热键由 WinForms 定时器轮询，不会阻塞托盘的消息循环。

## 它是怎么做到的

核心思路：把浏览器窗口去掉标题栏/边框后，塞进 Windows 桌面底层，让**桌面图标与操作层留在它之上**。

Windows 桌面窗口层级因系统版本而异，没有「一种写法通吃」。脚本内置 **5 种挂接模式**，依次尝试，并允许运行中用托盘/快捷键实时切换：

| 模式 | 做法 | 说明 |
| --- | --- | --- |
| `workerw` | **默认。** 向 `Progman` 发送未公开消息 `0x052C` 让 Explorer 生成专用壁纸 `WorkerW`，再把窗口父化进「紧挨图标层 `SHELLDLL_DefView` 之后」的那个 `WorkerW`（Wallpaper Engine / Lively 同款做法）。找不到全屏可接受的 `WorkerW` 时回退到 `Progman`（Win11 抬升桌面自动加 `WS_EX_LAYERED`） | 绝大多数 Win10/Win11 上真正可用 |
| `zorder` | 不重父化，仅用 `SetWindowPos` 插到图标层正后方 | 顶层窗口回退 |
| `bottom` | 普通顶层窗口钉在桌面 z 序最底 | 顶层窗口兜底 |
| `defview` | 旧回退：作为图标层宿主的子窗口、排在 `DefView` 正后方 | 仅在上述都失败时才试 |
| `progman` | 旧回退：作为 `Progman` 的子窗口、排在 `DefView` 正后方 | 仅在上述都失败时才试 |

**为什么现在默认 `workerw`、而不是之前用的 `defview`/`Progman`？** 这是对照 Wallpaper Engine / Lively 源码（开源）纠正出来的：

动态壁纸软件真正的做法是——先向 `Progman` 发 `0x052C`（Wallpaper Engine 逆向得到、Lively 源码里 `SetupDesktop.cs` 的 `SetWallpaper()` 用的就是它），让 Explorer **新生成一个专用的壁纸 `WorkerW`**；再把窗口父化进「**紧挨着承载 `SHELLDLL_DefView`（图标层）的那个 `WorkerW` 的下一个兄弟 `WorkerW`**」。图标层画在这个壁纸 `WorkerW` 之上，所以图标永远在我们之上；而我们又压在真实壁纸位图之上 → 壁纸可见、图标在上。

之前的版本错在两点：① 从没发过 `0x052C`，没有专用壁纸容器，直接往 `Progman`/`DefView` 里塞 → 被压在不透明的桌面背景之后而**看不见**；② 早先的 `workerw` 是在一堆 `WorkerW` 里乱挑，挑中的第一个往往拒绝接受子窗口。

现在的 `workerw` 只在「**该 `WorkerW` 全屏且能接受子窗口**」时才采用（否则回退 `Progman` + 抬升桌面分层技巧），并把窗口铺满整个虚拟屏幕、去掉标题栏边框、从任务栏隐藏、不抢焦点。

> 跑起来若挂上却看不到，多半是模式不对：**点托盘 → 切换挂接模式**（或按 `Ctrl+Alt+M`）依次试 `workerw / zorder / bottom / defview / progman`，总有一个在你的系统上可见。看到日志里 `verify:` 行的 `iconsOnTop` 应为 `True`。

## 内置小浏览器（为什么不再启动 Edge/Chrome）

早期版本用 `msedge --app=...` 起一个浏览器进程再把它的窗口塞进桌面层，结果有两个：

1. **依赖外部浏览器**，看起来像"我的壁纸是一个 Edge 窗口"；
2. **边框去不掉**：Chromium 自己绘制非客户区，即使剥掉 `WS_CAPTION`/`WS_THICKFRAME`/`WS_SYSMENU` 再 `SWP_FRAMECHANGED`，窗口仍保留约 7px 内缩（实测窗口 1920×1200、客户区只有 1906×1193）。跨进程无法子类化，任何外部进程都改不动它——像素采样证明边缘那 7px 就是真实壁纸透出来的"边框"。

解决办法：**页面装进我们自己的窗口**。`browsercore.ps1` 直接在 WinForms `FormBorderStyle None` 的窗体内托管 WebView2 控件，客户区就等于页面，实测内缩 `0/0/0/0`（顶层与挂进壁纸 WorkerW 之后都是），彻底无边框、无标题栏，也无需安装任何东西。

引擎优先级（自动探测，无需配置）：

| 引擎 | 说明 |
| --- | --- |
| `webview2` | **首选。** 系统自带 Microsoft Edge WebView2 运行时（Chromium 引擎）+ `vendor\` 里两个托管 DLL。通过注册表 GUID `{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}` 与 `%ProgramFiles (x86)%\Microsoft\EdgeWebView\Application\<版本>\` 定位运行时 |
| `ie` | `System.Windows.Forms.WebBrowser`（IE/Trident），每台 Windows 都有，作为次选 |
| `edge` | 兜底：`msedge --app` 起外部窗口并重父化（会有上面说的 7px 边框） |

`vendor\` 三个文件来自 NuGet 包 `Microsoft.Web.WebView2`（1.0.4314.35）：`Microsoft.Web.WebView2.Core.dll`、`Microsoft.Web.WebView2.WinForms.dll`、`WebView2Loader.dll`（原生加载器，必须让 `vendor\` 排在 `PATH` 最前）。

另外两条实现要点：

- **先挂接、后显示**：窗口在隐藏状态下就被父化进壁纸 WorkerW，之后才 `ShowWindow(SW_SHOWNOACTIVATE)`，因此不会出现"带边框的顶层窗口闪一下"（之前那次屏幕闪动就是尚未挂接的窗口）。
- **WebView2 各窗口的 `file://` localStorage 互不相通**（实测），所以设置窗口的配置由**宿主转发**：页面通过 `document.title` 里的 `[[htmlbg:kind:payload]]` 标记向宿主发消息，宿主用 `ExecuteScriptAsync` 把配置推给壁纸页（`window.__htmlbgApplyCfg`）。

## 两种配置方式（GUI + 配置文件）

### 1) GUI
`Ctrl+Alt+S`（或托盘左键）打开设置窗口（由内置小浏览器渲染的普通窗口，带标题栏，可移动/最小化/关闭）：
- **来源**：网址 / 本地 HTML 文件 / HTML 代码 / 内置极光动画
- **显示**：缩放、不透明度、背景色
- **行为**：自动刷新、隐藏鼠标、点击穿透
- **界面**：暗色 / 亮色 / 跟随系统、主题色
- **配置文件**：导出、导入、从配置文件恢复、恢复默认

改动保存后立即通过宿主转发给壁纸页（约 0.4~0.8 秒），桌面立刻更新。

### 2) 配置文件
直接编辑项目根目录的 **`config.json`**，下次启动生效：

```json
{
  "version": 1,
  "source": {
    "type": "builtin",   // builtin | url | file | code
    "url": "",           // type=url 时填网页地址
    "file": "",          // type=file 时填本地文件路径
    "html": ""           // type=code 时填 HTML 代码
  },
  "display": { "scale": 1, "opacity": 1, "background": "#0a0a12" },
  "behavior": { "reloadMinutes": 0, "hideCursor": false, "clickThrough": false },
  "ui": { "theme": "dark", "accent": "#7c5cff" }
}
```

启动时脚本会把它转成 `config-inject.js`（自动生成，勿手改）注入页面。
- 想让 `config.json` 重新生效 → 设置里点「从配置文件恢复」。
- 想把当前配置存成文件 → 「导出配置」，保存为 `config.json`。

## 预设页面：高考倒计时 + 文档自动滚动预览

内置一个开箱即用的预设页 **`presets/exam-dock.html`**：右侧一块毛玻璃面板，上方是
**高考倒计时**（天 / 时 / 分 / 秒），下方是**自动滚动的文档预览**。

### 为什么所有操作都在「设置」里

**桌面上的按钮点不到，这是结构决定的，不是 bug。**

在桌面空白区域做 `WindowFromPoint` 命中测试，返回的永远是 `SysListView32`
（explorer 的桌面图标层），而不是我们的壁纸窗口 —— 鼠标事件被图标层吃掉。
而壁纸必须保持在 `DefView` **之下**，否则桌面图标就被盖住了（`iconsOnTop=True`
正是靠这个保证的）。所以：

> 壁纸能看不能点。**所有文件导入、参数调节一律在设置窗口（`Ctrl+Alt+S`）里完成。**

### 支持的文件格式

| 格式 | 说明 |
| --- | --- |
| `.docx` | Word 文档，保留标题层级与列表符号 |
| `.xlsx` | Excel 表格，按工作表分组、逐行输出 |
| `.pptx` | PowerPoint，按幻灯片与页内文本框提取文字 |
| `.pdf` | 解析内容流里的文本，中文按 `ToUnicode` 映射还原 |
| `.csv` / `.txt` | 纯文本，自动识别常见编码与分隔符 |
| 图片 `png/jpg/gif/webp/bmp/svg` | 直接按比例显示 |

老版 `.doc`（二进制 OLE 格式）不支持，会提示请在 Word 里另存为 `.docx`。

### 怎么用

1. `Ctrl+Alt+S` 打开设置 → **预设页面** → 选「高考倒计时 + 文档滚动预览」。
2. 在下面的选项里设置：**考试日期**、**倒计时标题**、**是否显示倒计时**。
3. **文件导入**区 → 找到对应槽位（默认叫「文档」）→ 点「选择…」，用系统原生
   对话框挑文件。选完点「保存并应用」，壁纸立刻开始滚动。
4. **文档字号**（12–40px）和**滚动速度**（5–120px/s）都在设置里调，随时生效。
5. **位置和大小**：不用手填坐标，直接点几个磁铁预设 ——
   「左上 / 上中 / 右上 / 左中 / 居中 / 右中 / 左下 / 下中 / 右下」九个位置 +
   「紧凑 / 标准 / 宽屏 / 巨幕」四档大小。

根目录里附了 `test_sample.docx / .xlsx / .pptx / .pdf / .csv / .txt` 六个样例，
可以直接拿来试用每种格式。

### 它内部是怎么工作的

```
设置窗口 ──选择文件──▶ 宿主 (wallpaper.ps1)  ──读字节，分片 base64──▶ 预设页 iframe
    ▲                        │                                            │
    └── 「已载入 6 段」 ◀──────┴──────────── 状态回报 (filestatus) ◀──────────┘
```

1. **槽位发现**：宿主把当前 HTML 扫一遍找 `<input type="file">`（`Get-HtmlFileSlots`），
   页面自己在运行期也会上报一遍（`filebridge.js`），两者合并后在设置里列出。
   所以**任何用了 file input 的 HTML 都能不经修改直接接入**。
2. **字节通道**：页面自己读不到本地文件 —— 它是 `file://` 页面，跨源 fetch 和虚拟
   域名都会被 Chromium 拒掉（实测 `Failed to fetch`）。所以由**宿主**读文件字节，
   按 144 KB 一片切片成 base64 推回页面，页面拼出真正的 `File` 塞进 input，
   再派发 `change` 事件 —— 页面代码完全不用改。
3. **自动滚动**：`requestAnimationFrame` 驱动 `translateY`，到底停 1.4 秒后回到开头；
   鼠标悬停暂停（虽然桌面点不到，鼠标移动仍然有效）、滚轮可以手动微调。
   单文件大小上限 32 MB。

## 文件说明

| 文件 | 说明 |
| --- | --- |
| `presets\exam-dock.html` | 内置预设页：高考倒计时 + 文档滚动预览 |
| `presets\presets.js` | 预设清单（名称 / 页面 / 默认配置），新增预设在这里登记 |
| `presets\docs.js` | 浏览器侧多格式文档解析器（docx/xlsx/pptx/pdf/csv/txt/图片） |
| `presets\filebridge.js` | 注入每个页面的文件桥：上报 file input 槽位、接收宿主推来的字节 |
| `presetcore.ps1` | 宿主侧的预设/文件内核：槽位扫描、原生文件对话框、字节下发 |
| `start.cmd` | 隐藏窗口一键启动（含 `-STA`，托盘必需） |
| `wallpaper.ps1` | 主程序：引擎探测、托盘图标、热键、宿主↔页面消息桥、调用桌面挂接引擎 |
| `desktopcore.ps1` | 桌面挂接引擎（Win32 绑定 + 5 种挂接模式），被 `wallpaper.ps1` 引用 |
| `browsercore.ps1` | **内置小浏览器**：WebView2 / IE / 外部 Edge 三级引擎、窗口与状态机 |
| `vendor\` | WebView2 SDK 的 3 个 DLL（Core / WinForms / Loader），随程序分发 |
| `diag.ps1` | 桌面窗口树诊断工具（看不到壁纸时 dump 层级） |
| `icon.ico` | 托盘图标（由 `icon.png` 生成的 PNG-in-ICO） |
| `wallpaper.html` / `wallpaper.js` | 铺满桌面的渲染窗口 |
| `settings.html` / `settings.js` | 设置 GUI 窗口 |
| `config.json` | 手改配置文件 |
| `config-inject.js` | 由脚本从 config.json 生成（勿手改） |
| `styles.css` | 样式（毛玻璃面板、明暗主题） |
| `index.html` / `app.js` | 纯浏览器预览版（双击即可，不需要桌面挂接） |
| `icon.png` | 托盘/窗口备用图标 |

## 排查

在控制台里直接运行（而不是 `start.cmd`）可以看到实时日志：

```powershell
powershell -ExecutionPolicy Bypass -STA -File .\wallpaper.ps1
```

启动时会打印引擎、窗口定位与挂接自检：

```
Engine  : webview2
Runtime : C:\Program Files (x86)\Microsoft\EdgeWebView\Application\155.0.4283.62
Wallpaper: file:///C:/Users/xiang/Desktop/HTMLBG/wallpaper.html
Desktop  : DefView 65844   progman 65836   wallpaper WorkerW: 590812
  verify: mode=workerw  host=WorkerW 590812  titleBarRemoved=True  isChild=True  parented=True  iconsOnTop=True  window=1920x1200  client=1920x1200
Attached : mode 'workerw' - desktop icons stay on top.
Page rendered via webview2. Everything runs in the tray.
```

判定：

- `Engine : webview2` → 用的是内置小浏览器；`ie` / `edge` 表示发生了回退
- `titleBarRemoved` / `isChild` / `parented` **三个应为 `True`**
- **`iconsOnTop` 必须为 `True`** —— 这才是真正有意义的检查：图标层是否画在我们之上。为 `True` 说明桌面图标/右键/拖拽都正常可用
- **`window` 与 `client` 必须完全相等**（如 `1920x1200` / `1920x1200`）—— 不相等就意味着还有非客户区残留，也就是"边框"。内置小浏览器恒为相等；只有 `edge` 兜底模式会小 14×7
- 设置窗口保存后应打印 `config forwarded to wallpaper (#1, ...)`，即宿主转发成功
- 若出现 `note: window still reports a N/N/N/N px frame` → 只在 `edge` 兜底模式下可能出现，脚本已把窗口偏移出可视区被裁掉，功能不受影响
- 若 `Attached : mode 'none'` → 所有模式都被系统拒绝，看上面的 `SetParent refused` 诊断行

### 窗口标题里的标记是干什么的

`wallpaper.html` / `settings.html` 的 `<title>` 里分别带了 `HTMLBG-WP` / `HTMLBG-SET` 标记。内置小浏览器模式下我们直接持有窗口句柄，不需要靠标题找窗口；这两个标记是给 `edge` 兜底模式用的——那时窗口属于另一个进程，只能按标题定位。

顺带记录当年踩过的两个坑（也是标记方案的由来）：

1. Chromium 会创建多个 `Chrome_WidgetWin_*`，`Process.MainWindowHandle` 常返回隐藏的辅助窗口；按「类名 + 可见性 + 尺寸」猜，会把样式和挂接作用到错句柄上——**真正可见的那个窗口毫发无损，于是标题栏还在、也没进壁纸层**。
2. Electron 应用（VS Code、Discord 等）同样使用 `Chrome_WidgetWin_1`，光靠类名会误抓别的软件——所以还要校验窗口所属进程名。

### 五种挂接模式（为什么需要切换）

Windows 桌面窗口的内部布局每个版本虽然不同，但「挂上去却看不见」**绝大多数时候不是选错宿主，而是少了关键一步**：向 `Progman` 发送未公开消息 `0x052C`。**它的 `wParam` 必须是 `0xD`（`lParam` `0x1`）**——若发成 `(0,0)`，Explorer 会**静默无操作**，壁纸层根本不会被创建，于是窗口明明「挂成功了」（`parented=True`）却永远画不出来。脚本默认走 `workerw`：先发 `0x052C(0xD)` 让 Explorer 生成专用壁纸 `WorkerW`，再把窗口父化进去，并按 `workerw → defview → progman → zorder → bottom` 顺序回退；运行中仍可随时用托盘「切换挂接模式」或 `Ctrl+Alt+M` 切换。

**为什么之前怎么调都看不见？** 根因正是这个 `0x052C` 的 `wParam`：早期一直发的是 `(0,0)`，壁纸层从未生成，于是无论退回到 `DefView` 还是 `Progman`，最终都被压在桌面不透明背景之后 → 看不见；只有极个别 `bottom`/`zorder`（纯顶层窗口）能"看见"，但它们做不到"既在壁纸之上、又在图标之下"。补上 `0x052C(0xD)` 后，`workerw` 模式就能拿到真正的壁纸 `WorkerW`（Windows 11 抬升桌面下它是 `Progman` 的子窗口），父化进去即位于真实壁纸之上、图标之下。

### 关于 `lastError=203`（重要：它是假的）

日志里的 `lastError=203`（`ERROR_ENVVAR_NOT_FOUND`）**完全不可信**，不要照着它排查。实测证据：对一个根本不存在的窗口句柄调用 `SetWindowLong`，本该返回 `1400`（无效句柄），返回的同样是 `203`——说明这个值是 PowerShell/CLR 启动时残留的噪声，跟 `SetParent` 本身无关。脚本改以 `GetAncestor(hwnd, GA_PARENT)` 判定成败，错误码仅作参考。

### **`GetParent()` 在骗你（曾经坑过好几轮）**

`SetParent` 其实是成功的，`GetParent()` 返回了假结果：`GetParent` **只对子窗口返回父窗口**，而 `WS_CHILD` 又必须在 `SetParent` 之后设置——检查的那一刻窗口还是顶层，`GetParent` 于是返回 `NULL`。实测：

```
SetParent(f2, f1)
  GetParent(f2)            = 0        ← 谎报
  GetAncestor(f2,GA_PARENT) = 459660  ← 真实
  GetWindow(f1, GW_CHILD)   = 591208  ← 真实，f2 确实是 f1 的子窗口
```

更糟：脚本一度信了假结果，走「失败」分支把**已经挂好的窗口又拆了下来**。结论：验证一律用 `GetAncestor(GA_PARENT)`，不要用 `GetParent()`；判断「是否顶层」要比较 `GetAncestor() == GetDesktopWindow()`，不是 `== 0`。

> 附：早期基于「自己的窗口也挂不进去」推断出的 UIPI 结论是**误判**，真实原因是 `GetParent()` 谎报；实测 powershell / explorer / msedge 三者完整性均为 `Medium`，不存在 UIPI 拦截。（脚本里仍保留完整性级别诊断，便于在新机器上判断。）

## 已知限制

- **挂接模式**：不同 Windows 版本/显卡下，「能看见」的宿主窗口不同。脚本默认 `workerw`，
  若看不到壁纸，用托盘「切换挂接模式」或 `Ctrl+Alt+M` 循环 `workerw / defview / progman / zorder / bottom`。
- **DPI 缩放**：脚本在启动时调用 `SetProcessDPIAware()`。不调用的话 `GetSystemMetrics()`
  返回 DPI 虚拟化后的数值，且会在 WinForms 初始化后**中途变化**（实测同一段代码两次调用
  得到 1680×1050 和 3360×2100，即 200% 缩放屏），导致壁纸只铺了四分之一。
- **桌面上的按钮点不到**（重要）：桌面空白区域的鼠标事件始终被图标层 `SysListView32`
  接走，而壁纸必须待在图标层下面（否则图标被盖住）。所以壁纸**只能看不能点**，
  一切文件导入与参数调节都在设置窗口（`Ctrl+Alt+S`）里完成。
- 嵌入外部网站受目标站 `X-Frame-Options` 限制，部分网站无法作为壁纸显示。
- 默认引擎是系统自带的 WebView2 运行时；极端情况下（无 WebView2 且无 IE）才会退回
  外部浏览器，可用 `-Browser "C:\path\to\chrome.exe"` 手动指定。
- 浏览器配置目录在 `%LOCALAPPDATA%\HTMLWallpaperProfile`（WebView2 的 user data）。
  注意 WebView2 各窗口的 `file://` localStorage 并不互通，跨窗口的配置同步由宿主转发。
- 若 `defview`/`workerw`/`progman` 任一被采用，重启资源管理器（explorer）或切换系统壁纸后，
  桌面 WorkerW 会被重建，脚本看门狗会自动重新贴合；极端情况下用托盘「重新贴合桌面」或重启本程序。

## 桌面结构诊断（看不到壁纸时）

若挂接后仍然看不到，运行 `diag.ps1` 把当前桌面窗口树 dump 出来，把输出贴给我：

```powershell
powershell -ExecutionPolicy Bypass -STA -File .\diag.ps1 -OutFile diag.txt
```

它会列出 `Progman / WorkerW / SHELLDLL_DefView / SysListView32` 的真实层级、各自的
style/exstyle/client rect，并指出每个候选宿主能否接受子窗口——据此可精确决定该用哪种模式。
