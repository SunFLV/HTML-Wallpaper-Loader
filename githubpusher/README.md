# GitHub 推送器（通用）

一个自包含的小工具包，把**当前项目文件夹**推到 GitHub。
（本机之所以需要它：**这台机器的网络连不上证书吊销列表**，schannel 会拒绝握手，
所以推送前必须关掉吊销检查 —— 脚本已经按仓库处理。）

## 包里有什么

| 文件 | 说明 |
| --- | --- |
| `push.ps1` | 一条命令完成：找 git → 装凭据（若缺）→（可选）用 API 建远端仓库 → `git init`（若缺）→ 提交 → 推送 →（可选）备份 |
| `credential.txt` | **⚠️ 密钥**：一行 `https://USER:TOKEN@github.com`，脚本自动装进 Windows 凭据管理器；已被 `.gitignore` 排除，永不进仓库 |
| `README.md` | 本文件 |

## 怎么用

```powershell
# 提交 + 推送（默认仓库 = 本文件夹的上一级，即项目根）
.\push.ps1

# 指定提交信息
.\push.ps1 -Message "browsercore: ..."

# 远端仓库不存在就用 API 现场创建（公开），并指定仓库名
.\push.ps1 -Create -RepoName HTML-Wallpaper-Loader

# 镜像备份（robocopy + git bundle）到 ~/Documents/repo-backups
.\push.ps1 -Backup

# 仓库在别处 / 用别的 git / 别的凭据账号
.\push.ps1 -Repo D:\somewhere\proj -GitDir C:\tools\mingit
.\push.ps1 -ForceCredential      # 覆盖凭据管理器里的旧条目
```

脚本会在四个位置找 git：`-GitDir` → 本目录 `mingit\cmd\git.exe` → 已知便携 git（C:/E: 下的
`DSH_AUTO\.tools\mingit`）→ PATH。

> **包里没有带 git 本体**（约 37 MB）。目标机器上没有 git 时，把便携 MinGit 解压到本目录的
> `mingit\`（即 `mingit\cmd\git.exe`）即可被自动找到，或传 `-GitDir`。
> MinGit：<https://git-scm.com/download/win>（取 `MinGit-*-64-bit.zip`）

## 它替你处理的四个坑（都是实测踩出来的）

1. **TLS 吊销检查**：不配就报 `schannel: ... CRYPT_E_NO_REVOCATION_CHECK (0x80092012)`。
   脚本写**仓库内**配置 `http.sslVerify=false` + `http.schannelCheckRevoke=false`
   （不动全局配置，别的项目不受影响），推送失败还会自动用
   `-c http.sslBackend=schannel` 重试一次。
2. **PowerShell 把 git 的 stderr 当异常**：git 常把正常信息写到 stderr，
   `$ErrorActionPreference='Stop'` 会让 `git remote get-url`（首次没有 origin 时）
   直接终止脚本。所有 git 调用走 `Invoke-Git` 包装，按**退出码**判断成败。
3. **凭据探测不能阻塞**：`git credential fill` 在没有条目时会交互式提问并挂住；
   脚本改用 `cmdkey /list` 判断是否已有 github.com 条目。
4. **别把密钥提交进去**：项目 `.gitignore` 排除 `githubpusher/credential.txt`，
   提交前还会检查暂存列表，命中 `credential.txt`、`*.key`、`*.log`、`*.pid`、
   `node_modules`、`*.bak`、`.workbuddy/` 等就**拒绝提交**。

## ⚠️ 安全警告

`credential.txt` 里是**可直接推送该账号仓库的凭据**（token 权限 `repo`）：

- 只放在可信介质；别丢进任何仓库、聊天记录、网盘公开链接；
- 一旦怀疑泄露，去 <https://github.com/settings/tokens> 撤销并重建，替换这个文件，
  再跑一次 `push.ps1 -ForceCredential`；
- 换机器：拷这个文件夹过去跑一次即可（它会装凭据）；
- 凭据存在 **Windows 凭据管理器**（加密），不落 `.git-credentials` 明文。

## 换仓库/换用户怎么办

`credential.txt` 是 `协议://用户名:token@主机` 形式，换账号改这一行。
仓库名默认取项目文件夹名，用 `-RepoName` 覆盖；`-Create` 会用 API 建仓库。
手动改远端：

```powershell
git -C <repo> remote set-url origin https://github.com/<用户>/<仓库>.git
```
