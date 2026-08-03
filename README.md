# incus-guard

Incudal 一键监测滥用-自动封禁+实例时间管理脚本  请你切一台VPS，宿主机上装一个，净化网络环境，从我做起

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/Milk-WX/incus-guard/main/install_incus_guard.sh | sudo bash
```

## 试运行模式

只记日志，不执行 freeze/stop/封禁：

```bash
curl -fsSL https://raw.githubusercontent.com/Milk-WX/incus-guard/main/install_incus_guard.sh | sudo bash -s -- --dry-run
```

## 管理命令

安装完成后，root 下输入：

```bash
gua
```

即可打开管理面板，查看运行状态、脚本升级、封禁日志、卸载。

## 卸载

```bash
sudo bash /usr/local/sbin/install_incus_guard.sh --uninstall
```
