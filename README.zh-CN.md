# Wispstage

Wispstage 是给 macOS 应用做端到端测试的框架，同时是一个 Claude Code 插件。它在你的电脑上直接驱动被测应用：经辅助功能读界面、按按钮、打字，每一步跑一组通用检查，在关键步截图，最后给出汇总。它不改被测应用的行为，也不需要虚拟机，测试期间只多一个驱动进程。

场景用 Swift 写，放在被测项目自己的场景包里。插件提供三样东西：驱动库 WispstageKit、测试舞台库 Wispstage（链接进被测应用的测试宿主）、命令行 `wispstage`，外加一个教 Claude 接入与写场景的技能。

和 XCUITest 这类要把被测应用放在前台跑的方案相比，它多了后台模式：被测窗口压在墙纸之下，测试期间你照常用电脑。每一步都自带一组通用检查（截断、压叠、越界、占位文字、提示音等，见「运行结果」），场景里不用逐条写。接到第 2 级后，测试只碰单独的测试宿主，正式发布的应用一行测试代码都不带。

## 两种运行模式

每次运行由你指定，不指定时用后台模式。

| | 后台模式（默认） | 前台模式 |
|---|---|---|
| 被测窗口 | 压到桌面墙纸之下，你看不见 | 真到前台 |
| 你的电脑 | 照常用：不动光标、不抢前台、不抢键盘、不出提示音 | 测试期间占用屏幕、键盘与光标；开跑前倒数 5 秒 |
| 前提 | 被测应用的测试宿主链接了 Wispstage（接入第 2 级） | 无 |
| 测得到的 | 场景调用 `t.requireForeground(...)` 或 `t.globalKey(...)` 之前的全部行为；从这一步起该场景余下的部分跳过，在 `summary.txt` 的 `Skipped in background mode` 一节列出 | 全部，包括全局快捷键与 key 窗口相关的行为 |

后台模式会在每个场景前后比对光标位置，用来发现测试自己挪动了你的光标；场景期间你动过鼠标或触控板，这一项就不判。

前台模式跑的过程中，如果光标被别人挪动，驱动会暂停这一步，等光标静止后重做一次。重做时光标又动了，这个场景就记为「被打断」（`interrupted`）：后面的步骤不再跑，既不算通过也不算失败，在 `summary.txt` 的 `Interrupted by user input` 一节列出。

## 安装

在终端运行：

```bash
claude plugin marketplace add yales66/wispstage
claude plugin install wispstage@wispstage
```

想从本机克隆的副本装，就先克隆再从本地目录添加（下文用 `<仓库目录>` 指克隆下来的目录）：

```bash
git clone https://github.com/yales66/wispstage wispstage
claude plugin marketplace add ./wispstage
claude plugin install wispstage@wispstage
```

装好后，Claude Code 的 Bash 里可以直接用 `wispstage` 命令；在普通终端里用 `<仓库目录>/bin/wispstage`，或把它链接进 PATH。第一次调用时它会先用 `swift build` 编译命令行，编译缓存放在 `~/Library/Caches/wispstage/`（可用环境变量 `WISPSTAGE_CACHE` 换位置），插件源码更新后下次调用会自动重编。需要 Xcode 16 以上或 Swift 6 工具链。被测应用要求 macOS 14 以上（这是部署目标，实测过的系统是 macOS 27）。

## 权限

在系统设置的「隐私与安全性」里，给运行 wispstage 的终端应用（在 Claude Code 里用就是运行 Claude Code 的那个终端）打开「辅助功能」与「屏幕录制」。这一步只能由你本人在系统设置里操作。前台模式还要允许终端向系统发送键鼠事件。`wispstage run` 开跑前会逐项检查，缺了就退出并报 `The terminal running the driver lacks permissions: <缺的项>. Grant them to the terminal in System Settings > Privacy & Security, then run again.`，缺的项写作 `Accessibility`（辅助功能）、`Screen Recording`（屏幕录制）或 `event posting`（发送事件）。

## 接入分级

已有的项目可以一级一级接，接到哪一级就用到哪一级。

| 级 | 应用要改什么 | 得到什么 |
|---|---|---|
| 0 | 不改，运行 `wispstage init` 生成场景包 | 只能前台模式；按文字与角色找元素；日历、通知等系统服务是真的 |
| 1 | 给看得见、能操作的元素加辅助功能标识，命名为「区.元素」，如 `settings.save` | 按标识找元素，场景不随文案和语言变化 |
| 2 | 建一个只在测试时用的测试宿主可执行目标，链接 Wispstage，在 `NSApplication` 建好之后、`run` 之前调 `Wispstage.install()`；场景包 `main.swift` 里的 `defaultExecutable` 改指测试宿主 | 后台模式；提示音检查有了来源 |
| 3 | 把用到的系统服务（日历、通知、授权、计时器时钟、网络）改成接口，测试宿主装替身 | 测试不碰你真实的数据，不弹授权框 |

正式发布的应用不链接 Wispstage，正式代码里不出现测试分支。

每一级具体怎么改、场景 API 怎么用，见 `skills/wispstage/references/integration.md` 与 `skills/wispstage/references/api.md`。一个场景大致长这样：

```swift
scenario("smoke.launch") { t in
    try t.launch(LaunchSpec(executable: t.configuration.defaultExecutable, ready: .anyWindow), step: "launch")
    try t.click(.id("settings.save"))
    try t.shot(id: "main.title")
}
```

## 第一次跑

1. 在项目根运行 `wispstage init`。`--executable` 填被测可执行文件相对项目根的路径（只能填相对路径）。SwiftPM 项目不填时默认 `.build/debug/<应用名>`，其中应用名取 `--app-name`，没给就取项目目录名，不会自动认 Package.swift 里的目标名。Xcode 工程默认把 `.app` 编进项目外的 DerivedData，先让构建产物落到项目根下（如 `xcodebuild -derivedDataPath build/xcode`），再填 `.app` 包里 `Contents/MacOS/<名>` 的相对路径。
2. 构建被测应用，确认上一步的路径下有可执行文件；不对就改场景包 `main.swift` 里的 `defaultExecutable`。生成的 `E2E/Package.swift` 按绝对路径依赖你本机的插件副本，提交前把这项依赖换成 `.package(url: "https://github.com/yales66/wispstage", from: "0.1.0")`，并把 `.product(name: "WispstageKit", ...)` 里的 `package:` 改成 `"wispstage"`。
3. 打开生成的 `SmokeScenarios.swift`，把 `anchorID` 改成你应用里一个元素的辅助功能标识（还没加标识就先留着，场景会退回去找第一段静态文字）。
4. 运行 `wispstage run --mode foreground smoke.`。接到第 2 级之前只能用前台模式：后台模式要靠测试舞台藏窗口，连不上舞台会直接报错。
5. 打开 `build/e2e-runs/<时间戳>/summary.txt` 看结果（见「运行结果」）。

## 命令一览

| 命令 | 作用 |
|---|---|
| `wispstage init [--app-name 名] [--executable 路径] [--dir 目录]` | 在当前项目生成场景包（默认放在 `E2E/`，含一个冒烟场景）与项目根的 `.wispstage.json`；已有的文件不覆盖 |
| `wispstage list [过滤…]` | 列出场景名，不启动应用 |
| `wispstage run [--mode foreground\|background] [--shots=key\|all\|none] [过滤…]` | 跑场景；过滤写场景全名或前缀，如 `smoke.`。`--shots` 管自动的整窗截图：`key`（默认）截首步、末步与失败步，`all` 每步截，`none` 自动截图与失败截图都不截。场景里显式写的 `t.shot`、`t.shot(id:)` 不受 `--shots` 影响，照截。本次运行保留下来的截图，不论自动截的还是显式截的，都与基准比较；失败截图不比较 |
| `wispstage baseline accept <运行目录> [场景过滤…]` | 把某次运行的截图存为基准，之后每轮自动逐像素比较 |
| `wispstage windows (--pid N \| --bundle-id ID)` | 列一个已在运行的应用在屏幕上的窗口 |
| `wispstage listing (--pid N \| --bundle-id ID) [--out 文件]` | 导出它的界面清单，并列出看得见却没有辅助功能标识的元素 |
| `wispstage shot (--pid N \| --bundle-id ID) [--window 窗口号] [--id 标识] [--out 目录]` | 截它的窗口，或按标识裁出一个元素 |
| `wispstage summary <运行目录>` | 按 `results.json` 重新生成 `summary.txt` |

`list`、`run`、`baseline` 从当前目录往上找 `.wispstage.json`，再交给其中写明的场景包执行；`scenarioPackage` 是相对这个文件所在目录的路径。格式是：

```json
{"scenarioPackage": "E2E", "product": "myapp-e2e"}
```

## 运行结果

每轮运行在场景包配置的产物目录（默认 `<项目根>/build/e2e-runs/<时间戳>/`）下留下：

- `summary.txt`：通过、失败、跳过的计数，失败场景的失败步骤与原因，只列不判的改进清单（缺标识、点按区域太小、没对齐、对比度、局部遮挡），以及与基准截图的视觉差异和高亮图路径（有差异也不判失败）。
- `results.json`：同样的内容，供程序读取。
- 每个场景一个目录：逐步日志 `steps.log`，按 `--shots` 截的整窗图与文字版界面清单，局部截图，失败时的整棵辅助功能树，应用的事件与标准错误输出。

判失败的检查包括：应用崩溃或卡死、未替换的占位文字、英文单复数错误、文字压叠、文字越出窗口、文字被截断、按键没有被接收而发出提示音（要接到第 2 级，否则日志注明提示音没有来源、不判失败）；后台模式下另查被测窗口有没有抢走键盘或前台。

## 开发

```bash
swift test --package-path <仓库目录>
```

插件的 Claude 技能在 `skills/wispstage/`，插件清单在 `.claude-plugin/`。CI 在 GitHub 的 macOS 机器上跑同样的构建和测试（`.github/workflows/ci.yml`）；需要图形会话或屏幕录制权限的测试，在机器没有这些条件时自动跳过。

## 许可证

MIT，见 [LICENSE](LICENSE)。
