# incus-guard
incudal  一键监测滥用-自动封禁脚本



## 一键安装

\`\`\`bash
curl -fsSL https://raw.githubusercontent.com/mesta1122/incus-guard/main/install_incus_guard.sh | sudo bash
\`\`\`

## 常用参数

​```bash
# 试运行模式，只记日志不执行 freeze/stop/封禁
curl -fsSL https://raw.githubusercontent.com/mesta1122/incus-guard/main/install_incus_guard.sh | sudo bash -s -- --dry-run
​```

## 管理命令

安装完成后，root 下输入：

​```bash
gua
​```

即可打开管理面板，查看运行状态、脚本升级、封禁日志、卸载。
