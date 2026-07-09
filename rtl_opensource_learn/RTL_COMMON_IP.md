# RTL Common IP / Bus Protocol Overview

本文档用于从 **GPGPU 软件驱动 bring-up / KMD 调试 / SoC 系统集成** 的角度，粗粒度列举芯片开发中常见的硬件 IP、片上总线协议和互连协议。

这里的目标不是替代 AMBA、PCIe 或各 IP 官方 spec，而是帮助软件驱动工程师在遇到如下问题时，能快速定位应该去看哪个硬件模块、哪类信号、哪条总线路径：

- `ioremap()` 后 MMIO 读写卡住；
- `readl()` 返回全 `0xffff_ffff`；
- `writel()` 不返回或者后续访问被阻塞；
- GPU firmware / RISC-V / Cortex-R 小核访问寄存器无响应；
- CPU、GPU、DMA 之间看到的数据不一致；
- interrupt / doorbell / ring buffer 更新不可见；
- UVM / HMM / shared memory / atomic 语义异常；
- RTL 波形中看到 `AWVALID` 拉高但没有 `AWREADY`，或者 `ARVALID` 后没有 `RVALID`。

## 当前已收录条目

| 类别 | 名称 | 主要用途 | 软件调试关注点 | 详细文档 |
| --- | --- | --- | --- | --- |
| Bus Protocol | AXI | SoC 内 master/slave 基本读写通道，常用于 CPU/GPU/PCIe/DMA/寄存器/DDR 控制器之间的数据访问 | MMIO stuck、读全 F、写无响应、地址译码错误、burst/size/ID/PROT 属性错误、B/R response 异常 | [AXI.md](ip_details/AXI.md) |
| Coherent Bus Protocol | AXI-ACE | AXI 的 cache coherent 扩展，用于 CPU cluster、GPU/NPU、IO coherent master 与 coherent interconnect 之间的一致性访问 | CPU/GPU cache 一致性、snoop、shareability、atomic/coherent transaction、DMA coherency、UVM/HMM 可见性 | [AXI_ACE.md](ip_details/AXI_ACE.md) |

## 后续可继续扩展的 IP / 协议方向

后续可以继续在本目录下补充以下条目：

| 类别 | 名称 | GPGPU 软件 bring-up 视角的价值 |
| --- | --- | --- |
| Interconnect | AMBA CHI | 现代 Arm SoC 中替代/演进自 ACE 的 coherent interconnect，涉及 Home Node、Request Node、Snoop Filter、atomic、cache stashing 等 |
| Bus Protocol | APB | 低速寄存器访问总线，常用于 clock/reset/PMU/GPIO/timer 等控制寄存器 |
| Bus Protocol | AHB | 较早期或中低速总线，在 MCU/firmware 子系统中仍常见 |
| IO | PCIe | Host 与 GPU/加速器之间的主要互连，涉及 BAR、MMIO、DMA、MSI/MSI-X、ATS、PRI、PASID、AtomicOp |
| Memory | DDR/HBM Controller | GPU 显存/系统内存访问路径，涉及带宽、QoS、ECC、地址映射、row/bank/channel decode |
| Memory | IOMMU/SMMU | DMA 地址翻译、IOVA、ATS、PRI、PASID、设备页表、UVM/HMM page fault 路径 |
| Interrupt | GIC / Interrupt Controller | GPU interrupt、MSI doorbell、firmware interrupt forwarding、EOI、mask、pending/active 状态 |
| Power | PMU / PPU / Clock / Reset | GPU power domain、reset domain、clock gating、firmware bring-up 卡死定位 |
| IPC | MHU / Mailbox / Doorbell | KMD 与 firmware 通信，ring buffer、doorbell、interrupt ack、shared memory 可见性 |
| Debug | Trace / Perf Counter / Debug Bus | RTL/FPGA/PLD/Palladium bring-up，定位 bus hang、timeout、NoC route、firewall 拒绝 |

## 推荐文档组织方式

```text
rtl_opensource_learn/
├── RTL_COMMON_IP.md
└── ip_details/
    ├── AXI.md
    └── AXI_ACE.md
```

每个 `ip_details/*.md` 文档建议包含：

1. 这个 IP / 协议在 SoC/GPGPU 中的位置；
2. 软件驱动工程师为什么需要理解它；
3. 关键硬件信号或事务类型；
4. 常见 stuck / timeout / all-F / coherency bug 与信号的对应关系；
5. bring-up 时的最小检查表；
6. KMD / firmware / RTL 联合调试时的常见问题。

## GPGPU bring-up 的一条典型访问路径

例如 host driver 写 GPU 寄存器：

```text
Linux KMD
  |
  | writel()/readl()
  v
CPU MMIO / PCIe Root Complex
  |
  v
PCIe TLP
  |
  v
PCIe Endpoint / AXI master bridge
  |
  v
AXI / NoC / Firewall
  |
  v
GPU Register Block / PMU / Interrupt Controller / DDR aperture
```

当软件看到 `writel()` 或 `readl()` stuck 时，问题不一定在 driver 本身，可能发生在：

- PCIe BAR / inbound ATU 配置错误；
- AXI address decode 没有命中 slave；
- firewall / security attribute 拒绝访问；
- target IP 没有 clock 或 reset 未释放；
- AXI slave 不返回 `BVALID` / `RVALID`；
- interconnect 没有 route；
- outstanding transaction 被前一个未完成事务堵住；
- CPU/PCIe bridge 对 posted write / non-posted read 的完成语义不同。

因此，软件侧 debug 需要能把现象映射到硬件总线行为。这个目录的文档就是围绕这个目标维护。