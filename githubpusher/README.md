# DSH GitHub 推送器

一个自包含的小工具包，用来把 `dsh-custom-plugins` 仓库推到 GitHub。
（本机之所以需要它：**这台机器的网络连不上证书吊销列表**，schannel 会拒绝握手，
所以推送前必须先关掉吊销检查 —— 包里已经处理好。）

## 包里有什么

| 文件 | 说明 |
| --- | --- |
| `push.ps1` | 一条命令完成：找 git → 配好 TLS 变通 → 装凭据（若缺）→ 提交 → 推送 →（可选）备份 |
| `credential.txt` | **⚠️ 密钥**：一行 `https://SunFLV:<token>@github.com`，脚本会自动把它装进 Windows 凭据管理器 |
| `README.md` | 本文件 |

## 怎么用

```powershell
# 只提交+推送
.\push.ps1

# 指定提交信息
.\push.ps1 -Message "dsh-model-server: ..."

# 顺便镜像备份（robocopy + git bundle）到 Z 盘
.\push.ps1 -Backup

# 仓库在别处 / 用别的 git
.\push.ps1 -Repo D:\somewhere\dsh-custom-plugins -GitDir C:\tools\mingit
```

脚本会自动在三个位置找 git：`-GitDir` → 本目录下的 `mingit\cmd\git.exe` → 本机现有的便携 git
（`E:\Users\xiang\Documents\DSH_AUTO\.tools\mingit`）→ PATH。

> **包里没有带 git 本体**（约 37 MB）。若目标机器上没有 git，把便携 MinGit 解压到本目录的
> `mingit\`（即 `mingit\cmd\git.exe`）即可被自动找到；或者传 `-GitDir`。
> MinGit 下载：https://git-scm.com/download/win （取 `MinGit-*-64-bit.zip`）

## 它替你处理的三个坑（都是实测踩出来的）

1. **TLS 吊销检查**：不配就报 `schannel: ... CRYPT_E_NO_REVOCATION_CHECK (0x80092012)`。
   脚本写入全局配置 `http.sslBackend=schannel` + `http.schannelCheckRevoke=false`
   （只关 CRL/OCSP，证书链本身仍然验证）。
   ⚠️ 实测写成"仓库内"配置**不生效**，必须是全局 + 显式指定后端。
2. **提交信息里的引号**：PowerShell 会把多行/带引号的信息拆成 pathspec。脚本用 `-m` 单行；
   要写多行请用 `git commit -F <文件>`。
3. **别把密钥提交进去**：脚本在提交前会检查暂存列表，命中
   `*.key`、`*.log`、`*.pid`、`node_modules`、`*.bak`、`*.broken-*`、`*.conflict-*`、`*.safety-*`
   就直接**拒绝提交**。

## ⚠️ 安全警告

`credential.txt` 里是**可直接推送该仓库的凭据**：

- 只放在可信介质；别丢进任何仓库、聊天记录、网盘公开链接；
- 一旦怀疑泄露，去 https://github.com/settings/tokens 撤销并重建，然后替换这个文件
  （重建后下次运行 `push.ps1` 会重新装进凭据管理器）；
- 换了机器：把这个文件夹拷过去，跑一次 `push.ps1` 即可（它会装凭据）；
- 凭据默认存在 **Windows 凭据管理器**（加密），不在 `.git-credentials` 明文里。

## 换仓库/换用户怎么办

`credential.txt` 是 `协议://用户名:token@主机` 形式。换账号就改这一行；
换远端仓库用：

```powershell
git -C <repo> remote set-url origin https://github.com/<用户>/<仓库>.git
```
