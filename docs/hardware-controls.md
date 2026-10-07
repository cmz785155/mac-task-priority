# M4 Pro 硬件控制调查

2026-10-08，本机 Mac16,8 / macOS 27.0.1。只读检查，没有写入 AppleCLPC、AGX、SMC、核心掩码、温控阈值或系统启动安全配置。

- `sysctl` 未发现可验证的 CPU/GPU 频率或功耗上限控制项。`hw.tbfrequency` 是时间基准，不是 CPU 主频。
- AppleCLPC 服务存在，但缺少实验工具使用的精确目标属性：前导反引号的 `pkg-avg-therm-power-target` 和 `pkg-low-power-target`。存在的 `#pkg-avg-therm-power-target-tc` 等是不同属性，不能当成瓦数目标来写。
- AGXAccelerator 检查未发现已验证的任意 GPU 频率或瓦数上限入口。
- `powermetrics` 是采样工具，不提供这些设置；其功率是估算值。
- SMC 可读取两把风扇，范围为 2317–7826 RPM，当前 F0Md / F1Md 为系统管理值 3；读取成功不证明可安全接管风扇或修改芯片限制。本轮未写风扇。

结论：本轮未找到适用于该机型和系统的可靠任意 CPU/GPU 频率、瓦数上限设置方法。这不是证明所有私有接口都不存在；未经验证的属性写入或仅在另一芯片上校准的实验，不作为已支持功能。

外部线索：[Denryoku](https://github.com/ZachLiu519/denryoku) 使用未公开 AppleCLPC 接口，在 M5 上校准，项目明确标注 Experimental，并提醒属性回读不等于实际约束仍在生效。因此本机缺少对应属性时不创建新属性、不套用其功率曲线。

指定任务调度使用 macOS `setpriority(PRIO_PROCESS, pid, nice)`，负 nice 表示更有利的 CPU 调度，需要管理员权限。它不改变芯片频率、GPU 调度或功耗上限，性能收益必须用实际任务吞吐量验证。

参考：[Apple setpriority 手册](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/setpriority.2.html)。

## GitHub 现成实现比较

- [Denryoku](https://github.com/ZachLiu519/denryoku)：AppleCLPC 功率预算实验，主要 M5 校准；[macOS 27 问题报告](https://github.com/ZachLiu519/denryoku/issues/2)记录了属性消失及写入返回成功但无实际作用。报告机型为 M5 Pro，不等于我们的 M4 Pro 已做同样写入测试；本机只读结果也缺少相应属性。
- [thermo-control-mcp](https://github.com/june4432/thermo-control-mcp)：MIT，Swift SMC 风扇控制，作者记录在同型号 Mac16,8 上 2300→6200 RPM 与到期恢复；这是作者的测试，不是本机验证。需要 root 守护进程及未公开 Ftst 机制，涉及接管系统风扇管理，不能称为保留原散热策略的普通设置。
- [MacFanControl](https://github.com/raminsharifi/MacFanControl)：MIT，Rust 终端界面，支持手动风扇、范围限制和退出恢复；主要实测 M3 Pro，M4 支持是基于机制推断。
- [macos-smc-fan](https://github.com/agoodkind/macos-smc-fan)：原始机制研究，适合核对 SMC 协议和不同芯片差异；不直接复制未核对的许可代码。
- [Procexp-Mac](https://github.com/microsoft/Procexp-Mac)：原生进程工具，提供 nice/优先级动作，可参考实现；本项目仅需要小范围调度功能，不引入它的持续采样和其他进程动作。代码复用前需核对具体文件许可。

本轮只读取上述项目资料和源码，没有安装它们的守护进程、运行外部控制代码或写入风扇/硬件功率参数。

## 本机任务优先级验证

本机 1.4.0 测试版已编译并安装。显式管理员测试只创建一次性 sleep 进程，检查 nice 0→-5→0、到期恢复、提前取消恢复、应用身份进程退出恢复、外部优先级修改保留，以及拒绝过期身份/root UID/任意档位/过长会话。全部通过；没有调节正在运行的用户工作任务。

这些测试验证设置与恢复，不是性能基准；尚未测得真实大模型或剪辑任务的吞吐量收益。CPU/GPU 硬件参数与现有电源模式保持原状。当时尚未更新 GitHub 发布版；2.0.1 已整理为公开测试版。
