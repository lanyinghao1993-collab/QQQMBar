# QQQMBar

macOS 26 原生菜单栏 QQQM 定投计划助手。它只读取、计算、显示和确认计划；没有 IBKR 下单代码、交易 socket 或自动交易能力。

当前 Popover 为固定 `344 × 600 pt` 自适应明暗仪表盘。它使用 AppKit `transient` Popover，打开时不主动激活为普通前台窗口；点击桌面或其他 App 会按菜单栏组件的方式收起。

## 安装

在 Finder 中双击 `build-and-install.command`。脚本使用本机 Swift 工具链构建并安装到 `~/Applications/QQQMBar.app`；替换期间只使用临时回滚副本，成功后立即清理，不长期保留旧版本。

该脚本产生仅供本机安装的 ad-hoc 签名 App。若要分发到其他 Mac，必须使用你的 Apple Developer ID 签名并完成 notarization；本机目前没有可用的 Developer ID 证书。

首次启动会先载入安全的本地 fixture。QQQM 日线来自 Nasdaq，VIX 来自 FRED，恐惧与贪婪指数来自 CNN 官方页面使用的数据接口，QQQM P/E 使用 Invesco 官方季度 fact sheet；自动刷新固定在每个美股交易日收盘后 15 分钟（`16:15 America/New_York`），错过时只补一次，不再因为每次打开面板而刷新。仍可在菜单中手动立即刷新。账户持仓由 Codex 中已授权的 Interactive Brokers 插件在 `16:20 America/New_York` 以只读方式每日同步一次。

30 日主图展示最近 30 个交易日的收盘价、由同一组真实收盘价计算的 EMA20 趋势线、真实成交买点与卖点，并在底部给出区间低点、高点和区间涨跌；当前没有卖出成交时明确显示为 0，不生成虚假卖点。可用鼠标在图上选择日期查看精确收盘价。

界面使用 macOS 系统材质、动态标签色与系统强调色，不强制深色。系统“外观”设为自动时，QQQMBar 会随系统在浅色与深色之间切换。

视觉系统参考 Famous Holdings：深色使用近黑墨青底、冷灰层级与单一青色主强调；浅色使用独立调校的冷白、深墨文字与更深的青色保证对比度。颜色只承担数据语义：趋势与资金使用绿色、VIX 风险使用暖琥珀、亏损与卖出使用珊瑚、CNN 恐惧贪婪使用连续区间色；不再为单一指标保留孤立的紫色。

界面图形全部由快照中的真实字段或可复算指标驱动：价格面积图来自 Nasdaq 收盘价，B/S 点来自 IBKR QQQM 成交；持仓模块直接对照平均成本与最新价，不使用会放大微小价差的比例尺；账户资产构成条来自 NAV、QQQM 市值与可用资金；计划资金模块按可用资金除以本期金额计算可覆盖期数；CNN 模块来自官方恐惧与贪婪指数，定投历史柱高按真实成交金额比例绘制。联网刷新会优先使用 Nasdaq 30 日动量、FRED VIX 与 CNN 指数重算本周建议；CNN 暂不可用时才使用明确标注的 RSI+VIX 备用模型。

定投基数固定为每期 `US$400`，并限制在 `US$200 / 300 / 400 / 500 / 600` 五档：显著下跌、低情绪或高 VIX 时多投；明显上涨、强情绪且低 VIX 时少投；其余维持基准。菜单栏圆点会在计划日前 3 天出现，绿色表示多投、青色表示基准、琥珀色表示少投、红色表示逾期或数据异常。该规则仅生成提醒，不会自动下单。

## 数据与安全

- 启用 App Sandbox 后，所有本地数据位于 `~/Library/Containers/com.lyh.qqqmbar/Data/Library/Application Support/QQQMBar/`。
- `snapshot-v2.json` 使用原子写入；确认记录按 recommendation ID 保存，新的建议不会继承旧确认状态。
- 网络刷新失败时保留最后一份已校验快照，不会用空值覆盖可用数据。
- 读取与导入时会校验价格顺序、数值有效性、买入金额，以及日内高低价关系；界面中的市值、未实现盈亏、NAV 占比会基于同一最新价重新计算，避免不同时间点数据混用。
- 不要把 IBKR、行情或 OAuth token 放入 JSON 文件。未来同步凭证必须保存到 macOS Keychain。
- 独立 macOS App 不持有 IBKR 登录凭证，也不能直接继承 Codex 插件的会话。同步由 Codex 的 IBKR 插件读取后写入本地只读快照；App 自身仍不包含下单接口。

## 开发

- Deployment target：macOS 26.0
- SwiftUI、Charts、ServiceManagement、Liquid Glass
- `LSUIElement=true`，不显示 Dock 图标
- Xcode 可直接打开 `QQQMBar.xcodeproj`；命令行构建不要求完整 Xcode。

## 来源

基于用户提供的 `QQQMBar_macOS26_v0.1.zip`（SHA-256：`985d36f581801e43e06334082f116db1bcc582eb23f0c3c51775a1072c8d70a4`）建立；原型中的测试数据仅作为显式 fixture 保留。
