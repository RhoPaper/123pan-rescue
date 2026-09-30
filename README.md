# 123pan-rescue

把 **123云盘「我的文件」** 完整、可续传、可对账地搬到本地磁盘。

[English](README.en.md) · 中文

```console
$ ./123pan-rescue.sh

──────────────────────────────────────────────────────────────
 123pan-rescue.sh v2.0.0  123云盘 WebDAV 全量取回
──────────────────────────────────────────────────────────────
 目标目录 : /mnt/data/123pan
 账号     : 138****8888 @ webdav.123pan.cn/webdav
 云端清单 : 25279 个文件 / 815.89GiB
 下载进度 : 已完成 9/28 个顶层目录
 断点记录 : 上次停在「照片们」（重跑 run 即从此继续）
──────────────────────────────────────────────────────────────
 1) 配置 / 修改配置        init
 2) 体检（不下载文件）    preflight
 3) 拉取云端清单          manifest
 4) 开始 / 继续下载       run
 5) 查看进度              status
 6) 完整性对账            verify
 7) 与目录树交叉核对      crosscheck
 8) 高级设置              settings
 9) 清空断点状态          reset
 0) 退出
──────────────────────────────────────────────────────────────
选择 [0-9]:
```

---

## 为什么需要它

123云盘有官方 WebDAV（网页「工具中心 → 第三方挂载 → 添加应用」），但**官方自己也说不要拿它做文件迁移**：

> 不推荐使用 WebDAV 进行文件迁移操作，因其**无法实现秒传和断点续传**，且各类 WebDAV 客户端实现差异较大，易导致失败。挂载目录层级较多或同一文件夹下文件较多时会出现卡顿。

真要把几百 GB 到上 TB 的数据搬回家，直接挂上去裸拷会遇到三件事：

1. **断了不知道断在哪** —— 没有断点记录，只能从头猜；
2. **重跑从头再来** —— 白烧流量（流量是要钱的）；
3. **拉完了不知道拉全没有** —— 25,000 个文件，你没法肉眼核对。

这个脚本把这三件事都补上了：**逐顶层目录分批 + 文件级跳过 + 中断检查点 + 全量对账**。

## 特性

| | |
|---|---|
| 🧭 **交互式菜单** | 不带参数运行就是菜单，第一次用也能点着走完 |
| 🔐 **配置向导** | 服务器 / 账号 / 应用密码 / 目标目录，写入 `~/.config/123pan-rescue/config`（权限 600） |
| ♻️ **真断点续传** | 文件级 `--size-only` 跳过 + 每个顶层目录独立状态，重跑只补缺的 |
| 📌 **中断检查点** | Ctrl-C 时**先**把「正在下载的文件」记下来，**再**结束 rclone |
| 🧮 **全量对账** | 文件数 / 总字节 / 无缺失 / 无大小不符，**三绿**才算成功 |
| 🧱 **清单缩水保护** | 云端索引延迟导致漏列时拒绝覆盖旧清单，避免「假三绿」 |
| 🛡 **只增不删** | 只调用 rclone 的 `copy / copyto / lsjson / lsd`，**绝不** `sync` / `delete` |
| 🔒 **并发保护** | 同一目标目录只允许一个实例（flock），防止手滑跑两遍烧双倍流量 |
| 🧪 **47 项自检** | 本地起假 WebDAV 服务器跑全量回归，含「下载中途强杀再续跑」 |

## 依赖

| 组件 | 用途 |
|---|---|
| **bash 4.4+** | 脚本本体 |
| **rclone 1.60+** | 传输引擎（建议装最新版） |
| **python3** | 对账引擎（脚本内嵌调用，无需装包） |
| curl / flock / coreutils | 连通性探测 / 并发锁 / 文件统计 |

```bash
# Arch
sudo pacman -S rclone python curl util-linux
# Debian / Ubuntu（仓库里的 rclone 可能偏旧，建议用官方脚本装最新版）
sudo apt install -y python3 curl util-linux
curl -fsSL https://rclone.org/install.sh | sudo bash
```

## 快速开始

**前置**：123云盘会员（第三方挂载是会员功能）+ 在网页「工具中心 → 第三方挂载 → 添加应用」建一个应用，
**授权目录选「我的文件」根目录**，权限尽量选**只读**，然后复制生成的**应用密码**。

```bash
git clone git@github.com:RhoPaper/123pan-rescue.git
cd 123pan-rescue

# 方式一：交互式（推荐第一次）
./123pan-rescue.sh

# 方式二：分步
./123pan-rescue.sh init        # 1. 填服务器 / 账号 / 应用密码 / 目标目录，并顺手体检
./123pan-rescue.sh manifest    # 2. 拉云端清单；把打印的总量与网页「已用容量」对一下
./123pan-rescue.sh run         # 3. 下载（建议放进 tmux/nohup，可随时 Ctrl-C）
./123pan-rescue.sh verify      # 4. 对账

# 方式三：一条龙无人值守
./123pan-rescue.sh all
```

挂机跑：

```bash
tmux new -s rescue
./123pan-rescue.sh run
# Ctrl-B D 脱离；tmux attach -t rescue 回来
```

## 子命令

| 命令 | 作用 |
|---|---|
| `init` | 配置向导；写 `~/.config/123pan-rescue/config`（600） |
| `menu` | 交互式菜单 |
| `preflight` | 体检：端点连通性 → 自动探测可用的 WebDAV vendor → 认证 → 列顶层 → 空间是否够 → 目标目录可写 |
| `manifest` | 逐顶层目录拉全量清单（路径 + 大小），后续所有对账的底账 |
| `run` | 下载：按优先级逐顶层目录处理，每项独立断点、独立重试，结尾自动对账 |
| `status` | 看进度（读状态文件，秒出）；`status deep` 会真的逐项核对本地 |
| `verify` | 全量对账 + 写 `verify-report.txt`（纯本地，不耗云端流量） |
| `crosscheck <txt>` | 与「目录树 txt」做独立交叉核对（只报告，不判定） |
| `settings` | 交互式修改并发 / 限速 / 优先级 / 跳过等 |
| `reset` | 清空断点状态（**不动任何已下载文件**） |
| `all` | `preflight` + `manifest` + `run` |
| `version` / `help` | 版本 / 帮助 |

## 参数

```
-d, --dest DIR        目标目录（默认 ~/123pan）
-u, --url URL         WebDAV 地址（默认 https://webdav.123pan.cn/webdav）
-a, --user 账号       123云盘登录账号（手机号）
-p, --pass 密码       应用密码（会进 shell 历史，建议用 init）
-t, --transfers N     并发传输数（默认 4）
-c, --checkers N      并发列目录数（默认 8）
-l, --bwlimit RATE    限速，如 10M（默认不限）
-P, --priority A,B    先下载哪些顶层目录（逗号分隔，__ROOT__ 表示根目录散装文件）
-s, --skip A,B        跳过哪些顶层目录
-y, --yes             所有询问默认同意（无人值守）
-n, --dry-run         演练模式：只列不落盘
-q, --quiet           安静模式
    --no-color        关闭彩色
    --menu            强制进入菜单
    --allow-shrink    允许新清单比旧清单小（确实删过云端文件时才用）
```

### 配置优先级

**命令行参数 > 环境变量 > 配置文件 > 内置默认**

环境变量：`WEBDAV_URL` `WEBDAV_USER` `WEBDAV_PASS` `DEST` `TRANSFERS` `CHECKERS` `MAX_ATTEMPTS`
`RETRY_SLEEP` `BW_LIMIT` `DRY_RUN` `PRIORITY` `SKIP_ITEMS` `ALLOW_SHRINK` `QUIET` `ASSUME_YES`
`NO_COLOR` `CONFIG_FILE` `XDG_CONFIG_HOME`

配置文件（`init` 生成，也可手改）：

```ini
webdav_url=https://webdav.123pan.cn/webdav
webdav_user=13800000000
webdav_pass_obscured=xxxxx          # rclone obscure 混淆后的应用密码
dest=/mnt/data/123pan
transfers=4
checkers=8
retry_sleep=20
max_attempts=5
priority=照片,文档,手机备份,__ROOT__   # 先搬不可再生的，可再下载的排最后
skip_items=下载缓存,临时中转
bw_limit=
```

> `webdav_pass_obscured` 是 **rclone 的混淆（obscure）**，只是防止被一眼看穿，**不是加密**，别外传这个文件。

## 断点与检查点

1. **文件级续传**：rclone 用 `--size-only` 判断，已存在且大小一致的文件直接跳过 —— 重跑不会重下。
2. **目录级状态**：每个顶层目录一份 `.state`，记录 `status / attempts / files_ok / missing / mismatch / last_rc`。已完成的项重跑直接跳过。
3. **中断检查点** `checkpoint.txt`：每次中断或每轮结束都会重写：

```ini
resume_item=照片们                     # 下次从这里继续
rclone_exit=interrupted
last_completed_file=INFO : IMG_6684.JPG: Copied (new)
last_stats=NOTICE: ... 227.554 GiB / 227.554 GiB, 100%, 12.034 MiB/s, ETA 0s
progress=302/13978 文件, 1.9GiB/66.2GiB 字节
in_flight_or_partial_files:
  # 中断瞬间抓到的在途文件（rclone 退出时会删掉 .partial，这是唯一记录）
  EXTRA	9433088字节	照片们/IMG_8848.JPG.73aaca48.partial
```

**关键设计**：rclone 优雅退出时会自动删掉 `*.partial` 临时文件，所以脚本在**杀 rclone 之前先「拍照」**，
把正在下载的文件和已下字节数写进检查点。即使 WebDAV 不支持断点续传，你也精确知道停在哪个文件的第几个字节。

## 对账标准

`verify` 必须同时满足，也就是所谓**三绿**：

- 本地完整文件数 = 云端清单文件数
- 本地完整字节 = 云端清单总字节
- `missing=0` 且 `mismatch=0`

WebDAV 不提供文件哈希（`rclone backend features` 里 `Hashes` 为空），所以最后再补一步**抽样哈希**：
随机挑几十个文件（含最大的几个），本地 `md5sum` 与云端重新下载的副本对比：

```bash
rclone --config ~/123pan/.from123-state/rclone.conf cat "pan123:照片们/xxx.jpg" | md5sum
md5sum ~/123pan/照片们/xxx.jpg
```

## 123云盘的坑（实测）

| 现象 | 说明 / 对策 |
|---|---|
| `WebDAV 认证失败` | 第三方挂载是**会员功能**；免费用户全端单月仅 10GB 提取流量，不适合搬大数据 |
| 列目录很慢 | 云端索引慢，首次 `manifest` 每个目录可能要几分钟；脚本已逐目录列取并支持局部失败重试 |
| 官方不推荐 WebDAV 迁移 | 就是因为没断点续传；本脚本用「逐目录断点 + 文件级跳过 + 中断快照」把这个短板兜住了 |
| 不提供文件哈希 | 因此用「数量 + 总字节 + 抽样哈希」验收 |
| 疑似被限速 | `--stats 15s` 会把每 15 秒的速率写进 `logs/*.log`，这就是可取证的材料 |

**速度参考**：家庭千兆/300M 宽带下，大文件阶段能跑满 26~29 MiB/s；小文件密集目录会掉到 ~12 MiB/s
（每文件请求开销所致，不是限速）。800GB 量级约 12~14 小时。

## 安全建议

- **应用权限选只读**：脚本只需要读，用只读应用能防住误删云端。
- **搬完先别删云端**：本地至少有两份副本（另一块盘 / NAS）之后再考虑清理。
- **用完删掉应用**：网页「第三方挂载 → 授权列表」里把这个应用删除，那把钥匙就失效了；`verify` 是纯本地比对，删掉授权照样能随时复核。
- **别在公网机器上留配置**：配置文件里是混淆过的密码，等同于访问凭据。

## 只在本地测试（不碰真云盘）

```bash
./test/make-testdata.sh     # 生成仿真云盘（中文名 / 空格 / 引号 / emoji / 15 层嵌套 / 单目录 3000 文件 / 200MB 大文件 / 空目录）
./test/selftest.sh          # 起本地 rclone WebDAV 服务器，跑 47 项用例
```

自检覆盖：语法与「无危险调用」静态断言、体检正常路径、密码错误、**认证失败不污染配置**、主机不可达、
清单数量与总字节、根目录散装文件入清单、空间不足守卫、tmpfs 守卫、**下载中途 SIGINT 后的检查点与在途文件记录**、
**续跑跳过已完成项**、**清单缩水保护**、全量对账三绿、**逐文件 md5 保真**、空目录保留、重复运行幂等、
dry-run 演练、并发锁、status / crosscheck。

## 已知限制

- 状态目录名沿用历史的 `.from123-state`（位于目标目录内），便于老安装平滑升级。
- 清单用 TAB 分隔，文件名里含 **TAB** 会解析异常（网盘常见文件名不会遇到）。
- 目标目录落在 tmpfs 上会被拒绝（防止把内存撑爆）。
- 云端「备份」区（电脑备份 / 手机备份）不在「我的文件」树里，WebDAV 通常看不到，需要走官方客户端恢复流程。
- 本工具面向 WebDAV 通用实现，默认值针对 123云盘；换 `--url` 也能用于其他 WebDAV 服务，但未做兼容性测试。

## 贡献

欢迎 Issue / PR。改动请先跑 `./test/selftest.sh`，保持 47 项全绿。

## License

[MIT](LICENSE)
