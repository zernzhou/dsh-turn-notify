# dsh-turn-notify

Windows 桌面通知：DSH 的一轮任务结束时，如果窗口不在前台，右下角弹一条系统通知。

在你看页面的时候**不弹**——判断依据是前台窗口的进程名，不是页面焦点。

## 要求

- Windows 10 / 11
- DSH `0.2.2` 系列（`engines.dsh` 声明为 `>=0.2.2-rc.1 <0.3.0`）
- 系统通知未被专注助手 / 通知设置屏蔽

## 安装

本地目录（开发时）：

```
plugin_manager(action: "install_bundle", target: "<本包绝对路径>")
```

或发布到 npm 后：

```
plugin_manager(action: "install_bundle", target: "dsh-turn-notify@0.1.0")
```

安装会写入当前 profile，**对该 profile 下所有会话生效**，重启后仍在。

## 卸载

```
plugin_manager(action: "remove_bundle", target: "dsh-turn-notify")
```

## 配置

插件行支持两个可选配置项，默认值如下：

```yaml
- id: turn-notify
  name: 'dsh-turn-notify'
  config:
    title: DSH 任务完成
    body: 一轮任务已结束，回来看看。
```

## 它做了什么

1. 订阅 `session/event`（会话事件批次；该构建里唯一会真正触发的会话事件名）
2. 只在批次中出现**比加载水位线更新**的 `turn/end` 时触发，所以重放历史不会弹
3. 启动一次 `notify.ps1`，由它判断前台进程：属于 DSH 就退出，否则弹通知
4. 每次完成弹一张卡，**最多三张向上叠**，各带自己的用时，逐张点击关闭；第 4 张在有人关掉之前不显示

不读取、不写入任何会话数据；没有客户端代码，页面不会因此白屏。

## 排障

日志：`%TEMP%\dsh-turn-notify\events.log`

- 只有 `turn-notify loaded`：事件名对不上，插件没收到任何 turn 结束
- 有 `event turn/end` 但没有 `notified from`：被 2 秒去重拦了
- 有 `notified from` 但没看到通知：系统通知被屏蔽，或前台进程名误判

前台进程名的匹配规则在 `notify.ps1` 里：包含 `dpharness` / `dsh` / `deepseek` 即视为"用户正在看"，可用 `-AppMatch <进程名>` 强制指定。

## License

MIT
