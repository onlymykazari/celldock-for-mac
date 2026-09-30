# 复盘：麦克风/通讯录授权弹窗静默失败，为什么拖了五版才修好

> 2026-10-01 · CellDockPlus · 构建 106 → 110
> 结论先行：最终修复本身只有 3 行（entitlements 文件 + 打包脚本一行参数）。
> 拖延的全部成本来自诊断路径错误——**先有假设再找证据**，而决定性的证据
> （tccd 日志 + 签名 entitlements 检查）从第一天起就是 30 秒可得的。

## 一、现象

CellDock（后改名 CellDockPlus）在新机器上：麦克风、通讯录权限显示"未允许"，
点击"请求权限"从不弹系统授权框，应用也不出现在 系统设置 → 隐私与安全性
的对应列表里。Info.plist 的用途描述（NSMicrophoneUsageDescription 等）齐全。

## 二、最终根因

macOS 对**强化运行时（hardened runtime）**应用执行"弹窗前置策略"：
签名里必须声明对应服务的 entitlement，tccd 才允许展示授权弹窗；缺失时
**静默拒绝**——不弹窗、不留提示、应用不进系统设置列表。打包脚本开启了
hardened runtime（`--options runtime`）却从未给应用签名传入 entitlements，
于是：

```
tccd 日志（决定性证据，当天即可获得）：
E tccd: Prompting policy for hardened runtime; service: kTCCServiceMicrophone
        requires entitlement com.apple.security.device.audio-input but it is missing
Df tccd: Policy disallows prompt ...; access to kTCCServiceMicrophone denied
```

entitlement 与服务的对应（本机实测）：

| TCC 服务 | 必需的签名 entitlement | 备注 |
|---|---|---|
| kTCCServiceMicrophone | `com.apple.security.device.audio-input` | 老版本 macOS 即如此，文档早有记载 |
| kTCCServiceCamera | `com.apple.security.device.camera` | 同上（未涉及，预防性记录） |
| kTCCServiceAddressBook | `com.apple.security.personal-information.addressbook` | **macOS 26 (Tahoe) 新增此门**，旧版不需要 |
| 通知 (UserNotifications) | 无 | 不受此机制约束 |

## 三、时间线（失败全过程，不美化）

| 轮次 | 动作 | 依据的假设 | 结果 |
|---|---|---|---|
| 1 | 引导用户 `tccutil reset`（用户域） | 旧签名安装残留 TCC 拒绝记录 | 无效 |
| 2 | `sudo tccutil reset` + 清 quarantine | 记录在系统域/隔离属性干扰 | 无效 |
| 3 | sqlite3 直查/直删 TCC.db | 记录可物理删除 | 用户域为空；系统域仅有一条无关的 FDA 拒绝；直写系统库被 SIP 拦（tccutil 报成功但无效果——**注意：tccutil 报成功只代表命令执行了，不代表问题与此相关**） |
| 4 | 查 profiles/MDM、屏幕时间 | 策略层拒绝 | 均为空/关 |
| 5 | **改名分家 CellDockPlus（新 bundle ID）** | 全新 ID 必然干净 | 依然失败——此刻"记录说"已被证伪，应立即转向系统级取证，实际却继续在记录层面打转 |
| 6 | 给用户测试脚本自行运行 | — | 脚本本身有 Swift 语法错误（插值内下标解析问题），浪费一轮；且当时**明知自己有 shell 权限却把诊断外包给用户** |
| 7 | 自己跑最小探针程序 | — | 关键观察出现：全新二进制 notDetermined + 回调瞬间返回 false = 系统在弹窗前就拒绝了 |
| 8 | 怀疑第三方清理软件（MacCleanMenu）A/B 验证 | 清理类工具有"隐私防护"会拦截弹窗 | 退出后行为不变，排除 |
| 9 | Web 检索 + **抓取 tccd debug 日志** | — | **实锤**：日志明确写出缺哪个 entitlement |
| 10 | 构建 109：补 audio-input entitlement | — | 麦克风修复 ✅ |
| 11 | 用户问通讯录；答"通讯录不走此机制"（又一次想当然） | 旧版 macOS 仅麦克风/摄像头受限 | 被用户追问后实测探针：**Tahoe 对 AddressBook 同样设门**，日志给出所需 key |
| 12 | 构建 110：补 addressbook entitlement | — | 全部修复 ✅ |

净损耗：约 5 轮无效迭代、2 个整版打包、多次用户往返。修复本体 3 行。

## 四、为什么拖了这么久（根因，按权重排序）

1. **假设先行，取证垫底**。第 1 轮的"残留 TCC 记录"在一般场景里确实是最常见原因，
   但它是假设不是证据。正确顺序是：先取系统的一手陈述（tccd 为什么拒绝），
   再谈修复。权威信息源就在本地（`log stream --predicate 'process == "tccd"'`），
   它的错误信息甚至直接写明缺哪个 entitlement——**答案在第一天就是一行日志**。

2. **最便宜的诊断被跳过**。`codesign -d --entitlements :- <app>` 一条命令 5 秒
   就能看到"应用带 hardened runtime 却没有任何 entitlements"，立即可疑。
   它比任何猜测都便宜，却直到第 9 轮之后才做。

3. **可自助执行的诊断被外包给用户**。Agent 手上有 shell，却连续多轮让用户
   复制粘贴命令、读返回结果。用户明确指出这一点（"你为什么不执行呢？？"）。
   规则应当是：机器能跑的，agent 自己跑；只有需要用户身体在场的（看屏幕上的
   弹窗、点授权）才请用户。

4. **假设被证伪后没有及时归零**。第 5 轮（新 bundle ID 仍失败）已经宣告
   "记录说"死亡，正确的反应是回到零、抓系统日志；实际却继续尝试更多记录层
   变体，随后又滑向"第三方软件干扰"这类同样未经验证的新假设。

5. **知识盲区未查证**：hardened runtime 的 TCC 弹窗 entitlement 门是
   macOS 10.14 起就文档化的行为（Apple 官方文档"Requesting Authorization
   for Media Capture on macOS"），并非冷知识；Tahoe 26 把门扩展到
   AddressBook 则确实是新变化——两个都该在动手前搜索/查文档确认，
   而不是在失败迭代之间靠记忆拼凑。

6. **同一失败模式当天复发**：麦克风修复后，对通讯录再次先给出"理论上不需要"
   的结论。被追问后才实测。说明"先假设后验证"是当时的默认工作方式，
   不是一次偶然失误。

## 五、沉淀：TCC 弹窗不出现的标准排查路径（SOP）

按此顺序执行，前三步在任何机器上都应 ≤ 2 分钟：

```bash
# ① 看应用签名里到底有什么（5 秒）
codesign -d --entitlements :- /Applications/<App>.app
codesign -dvv /Applications/<App>.app | grep -E "flags|Authority"
#    flags 含 runtime（强化运行时）而 entitlements 为空/缺服务对应项 → 高度可疑

# ② 直接问 tccd 为什么（30 秒，决定性）
log stream --level debug --style compact --predicate 'process == "tccd"' > /tmp/tccd.log
#    保持监听，复现一次权限申请，Ctrl-C 后：
grep -E "Prompting policy|Policy disallows|Handling access" /tmp/tccd.log
#    "requires entitlement X but it is missing" → 补 X，结束。
#    注意：zsh 里要用 /usr/bin/log（log 是 zsh 内建命令名，裸用会报 too many arguments）。

# ③ 应用本身的授权状态（区分 notDetermined / denied / restricted）
#    notDetermined + 瞬间回调 false + 无弹窗 = 弹窗策略门（即本案例）
#    denied                     = 有记录且被拒 → tccutil reset 后重试

# ④ 以上全干净再考虑：屏幕时间限制、MDM profiles、App Translocation
#    （ps 看运行路径是否含 AppTranslocation）、第三方安全软件 A/B 验证
```

修复落点：entitlements 文件 + 打包脚本签名命令加 `--entitlements`，
并验证产物：

```bash
codesign -d --entitlements :- <打包产物>.app   # 必须能看到所需 key
```

## 六、防再犯

1. **发版检查清单**（已可执行）：
   - `scripts/run_tests.sh` 全绿（已有）；
   - `codesign -d --entitlements :-` 确认产物包含全部所需 entitlement
     （麦克风/通讯录当前均已覆盖，见 `Resources/CellDockPlus.entitlements`）；
   - 在目标系统上用探针实测一次授权弹窗（本复盘的探针程序即模板，
     20 行：申请 → 结果写入文件）。
2. **工作方式**（对执行者本人的约束）：
   - 系统行为异常类问题，第一动作是抓系统守护进程日志，不是按常见原因清单试错；
   - 每个假设标注置信度，用**最便宜的实验**去证伪；被证伪后回零重来，不做假设叠加；
   - 有执行环境就自己执行，用户只做必须由人完成的部分；
   - 对"旧版本如此所以新版本也如此"的 Platform 知识，引用前先验证（系统大版本
     升级后尤其如此）。
3. **上游遗产**：打包脚本继承自上游，从未包含应用 entitlements——上游 0.3.x
   自身打出的包大概率同样无麦克风弹窗（上游主推短信场景，语音用得少故未暴露）。
   分叉的打包脚本已修复，后续如上游修复可对比同步。

## 七、相关提交

- `5db06c2` 品牌分家（新 bundle ID——与权限问题无关，但客观上排除了记录层干扰）
- `694d61f` 权限页自愈按钮 + 主动申请（在根因未明时编写，机制本身仍有效：
  「重置并申请」依赖弹窗能正常出现，entitlement 修复后其价值才兑现）
- `5ffde6d` audio-input entitlement（麦克风修复）
- `cbdb286` personal-information.addressbook entitlement（通讯录修复）
