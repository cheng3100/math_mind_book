# AXI IP Details for GPGPU Driver Bring-up

本文档从 **GPGPU 软件驱动 bring-up / KMD 调试 / RTL 波形分析** 的角度介绍 AXI。重点不是完整复述 AMBA AXI spec，而是回答软件工程师最常遇到的问题：

- 为什么一次 `readl()` 会卡住？
- 为什么 `writel()` 后设备没有反应？
- 为什么 MMIO 读到全 `0xffff_ffff`？
- 为什么 PCIe host 访问 GPU 内部寄存器时，RTL 看到 `AWVALID` 但没有 `AWREADY`？
- 为什么某个 firmware 小核访问 PMU / GIC / PPU 寄存器会 bus hang？
- 软件现象如何对应到 AXI 的 `AW` / `W` / `B` / `AR` / `R` 通道？

## 1. AXI 在 GPGPU SoC 中的位置

在一个 GPGPU / NPU / AI SoC 中，AXI 通常位于多个 master 和 slave 之间：

```text
CPU / PCIe EP bridge / GPU firmware core / DMA / GPU copy engine
        |
        v
AXI Master Interface
        |
        v
NoC / AXI interconnect / Firewall / Address decoder
        |
        v
AXI Slave Interface
        |
        +--> GPU register block
        +--> PMU / PPU / clock / reset controller
        +--> GIC / interrupt controller
        +--> SRAM / TCM / DDR / HBM controller
        +--> mailbox / MHU / doorbell block
```

从软件视角看，很多访问最终都会落到 AXI：

```text
Linux KMD writel/readl
  -> PCIe MMIO / inbound bridge
  -> AXI master transaction
  -> NoC / firewall
  -> target AXI slave
```

或者：

```text
GPU firmware load/store
  -> CPU core data bus
  -> AXI master transaction
  -> target register / SRAM / interrupt controller
```

因此，软件看到的 stuck、timeout、all-F、SError、bus fault，很多都可以映射到 AXI transaction 没有正常完成。

## 2. AXI 的五个基本通道

AXI 读写分离，写通道有三个，读通道有两个。

| 通道 | 方向 | 作用 | 软件调试意义 |
| --- | --- | --- | --- |
| `AW` | Master -> Slave | Write address channel | 写访问地址、burst、size、protection 属性是否正确 |
| `W` | Master -> Slave | Write data channel | 写数据、byte lane、last beat 是否正确 |
| `B` | Slave -> Master | Write response channel | 写事务是否完成，是否返回 error |
| `AR` | Master -> Slave | Read address channel | 读访问地址、burst、size、protection 属性是否正确 |
| `R` | Slave -> Master | Read data/response channel | 读数据是否返回，是否返回 error |

软件 stuck 的核心判断：

- 写 stuck：重点看 `AW`、`W`、`B`；
- 读 stuck：重点看 `AR`、`R`；
- 读全 F：可能不是 AXI 数据真的为全 F，也可能是上层 PCIe/config/bridge 对 failed completion 的表现；
- 写无效果：可能写事务完成了，但地址、byte enable、security、clock/reset、posted write ordering 或目标寄存器语义有问题。

## 3. VALID / READY 握手机制

AXI 每个通道都采用 `VALID` / `READY` 握手。

一次传输在某个 clock cycle 同时满足：

```text
VALID == 1 && READY == 1
```

时才算该通道 beat 被接受。

### 3.1 软件 stuck 与握手的关系

| RTL 现象 | 可能含义 | 软件侧表现 |
| --- | --- | --- |
| `AWVALID=1`，`AWREADY=0` 长时间保持 | 写地址没有被 interconnect/slave 接收 | `writel()` 或后续 barrier/readback 可能 stuck |
| `WVALID=1`，`WREADY=0` 长时间保持 | 写数据没有被接收 | 写事务无法完成 |
| `AW/W` 已握手，但没有 `BVALID` | slave 未返回写响应，或 response 被 NoC/bridge 卡住 | non-posted 语义下写可能 stuck；posted write 可能在后续 read/barrier 暴露 |
| `ARVALID=1`，`ARREADY=0` 长时间保持 | 读地址没有被接收 | `readl()` stuck |
| `AR` 已握手，但没有 `RVALID` | slave 未返回读数据，或 response 被卡住 | `readl()` stuck |
| `RVALID=1` 但 `RREADY=0` | master 没有接收读数据，可能 master/bridge 背压 | 可能导致后续 outstanding 被堵 |
| `BVALID=1` 但 `BREADY=0` | master 没有接收写响应 | 可能导致写 response 队列堵塞 |

## 4. 写事务：AW / W / B

### 4.1 写地址通道 AW

常见信号：

| 信号 | 作用 | bring-up / debug 关注点 |
| --- | --- | --- |
| `AWVALID` | master 发起写地址有效 | 是否真的有写 transaction 发出 |
| `AWREADY` | slave/interconnect 接收写地址 | 如果一直为 0，说明地址通道被堵 |
| `AWADDR` | 写地址 | 是否是预期物理地址 / AXI 地址；是否经过 PCIe inbound ATU 转换 |
| `AWID` | transaction ID | 多 outstanding 时用于匹配 response；ID 错可能导致乱序/response 匹配问题 |
| `AWLEN` | burst 长度，beats-1 | MMIO 寄存器通常应是单 beat；异常 burst 可能被 slave 拒绝 |
| `AWSIZE` | 每个 beat 字节数，`2^AWSIZE` | `writeb/writew/writel/writeq` 对应不同 size；size 不匹配可能触发 error |
| `AWBURST` | burst 类型 | 寄存器访问通常是 INCR 或 FIXED；错误 burst 可能不被支持 |
| `AWCACHE` | cache/buffer/modifiable 属性 | 影响 bufferable/cacheable 行为；MMIO 通常应 device-like / non-cacheable |
| `AWPROT` | privilege/security/instruction 属性 | 安全域/firewall 调试重点，非安全访问 secure-only slave 可能被拒 |
| `AWQOS` | QoS 优先级 | 性能/QoS 问题时关注，基本功能 bring-up 次要 |
| `AWREGION` | region 标识 | 某些 NoC/decoder 使用，配置错可能 route 错误 |

### 4.2 写数据通道 W

| 信号 | 作用 | bring-up / debug 关注点 |
| --- | --- | --- |
| `WVALID` | 写数据有效 | 是否发出写数据 |
| `WREADY` | slave/interconnect 接收写数据 | 如果一直为 0，写数据通道被堵 |
| `WDATA` | 写数据 | 是否与软件写入值一致，注意大小端和 lane |
| `WSTRB` | byte strobe | `writeb/writew/writel` 最关键；byte lane 错会导致寄存器未被真正写到 |
| `WLAST` | burst 最后一个 beat | 单 beat 写应在该 beat 拉高；不拉高可能导致 slave 等待后续 beat |

### 4.3 写响应通道 B

| 信号 | 作用 | bring-up / debug 关注点 |
| --- | --- | --- |
| `BVALID` | 写响应有效 | 没有 `BVALID` 说明写事务未完成 |
| `BREADY` | master 接收写响应 | 若为 0，master/bridge 背压 |
| `BID` | response 对应的 write ID | 必须与 `AWID` 匹配 |
| `BRESP` | 写响应结果 | 判断 OKAY / error |

常见 `BRESP`：

| `BRESP` | 名称 | 含义 | 软件可能表现 |
| --- | --- | --- | --- |
| `00` | OKAY | 正常完成 | 写成功或至少总线层完成 |
| `01` | EXOKAY | exclusive access 成功 | 普通 MMIO 少见 |
| `10` | SLVERR | slave error | 目标 slave 拒绝或内部错误，可能触发 bus fault/SError |
| `11` | DECERR | decode error | 地址没有命中任何 slave，常见于地址映射/ATU/NoC route 错误 |

## 5. 读事务：AR / R

### 5.1 读地址通道 AR

| 信号 | 作用 | bring-up / debug 关注点 |
| --- | --- | --- |
| `ARVALID` | master 发起读地址有效 | 是否真的发出读 transaction |
| `ARREADY` | slave/interconnect 接收读地址 | 一直为 0 表示地址通道被堵 |
| `ARADDR` | 读地址 | 是否是预期 AXI 地址 |
| `ARID` | transaction ID | 用于匹配返回数据 |
| `ARLEN` | burst 长度 | MMIO 通常单 beat |
| `ARSIZE` | 每 beat 字节数 | `readb/readw/readl/readq` 对应不同 size |
| `ARBURST` | burst 类型 | 寄存器访问通常不应出现复杂 burst |
| `ARCACHE` | cache/buffer 属性 | MMIO 通常 non-cacheable/device-like |
| `ARPROT` | privilege/security/instruction 属性 | secure/non-secure、privileged/user 访问检查 |
| `ARQOS` | QoS | 性能问题时关注 |

### 5.2 读数据通道 R

| 信号 | 作用 | bring-up / debug 关注点 |
| --- | --- | --- |
| `RVALID` | 返回数据有效 | 没有 `RVALID` 时 `readl()` 会等待完成 |
| `RREADY` | master 接收数据 | 为 0 表示 master/bridge 背压 |
| `RDATA` | 返回数据 | 是否为预期寄存器值 |
| `RID` | 返回数据对应 ID | 必须与 `ARID` 匹配 |
| `RRESP` | 读响应结果 | OKAY / SLVERR / DECERR |
| `RLAST` | burst 最后一个 beat | 单 beat 读应拉高 |

常见 `RRESP` 与 `BRESP` 类似：

| `RRESP` | 名称 | 含义 | 软件可能表现 |
| --- | --- | --- | --- |
| `00` | OKAY | 正常返回数据 | `readl()` 返回有效数据 |
| `01` | EXOKAY | exclusive access 成功 | 普通 MMIO 少见 |
| `10` | SLVERR | slave error | 可能读到错误 completion，或触发异常 |
| `11` | DECERR | decode error | 地址未命中，常见于 base/offset/route 错误 |

## 6. 软件现象到 AXI 问题的映射

### 6.1 `readl()` 卡住

重点观察：

```text
ARVALID / ARREADY / ARADDR / ARPROT / ARSIZE
RVALID / RREADY / RRESP / RDATA / RLAST
```

常见原因：

1. `ARVALID=1` 但 `ARREADY=0`：interconnect 没有接收地址；
2. `AR` 已握手但没有 `RVALID`：target slave 没返回；
3. `RRESP=DECERR`：地址 decode 错；
4. `RRESP=SLVERR`：slave 内部错误、clock/reset/security 拒绝；
5. `ARPROT` 表示 non-secure，但目标只允许 secure；
6. PCIe inbound ATU 把 host address 转成了错误 AXI address；
7. 目标 IP 没有 clock 或仍在 reset；
8. NoC/firewall 把访问拦截但没有正确返回 error response。

### 6.2 `writel()` 看似返回，但设备无反应

重点观察：

```text
AWVALID / AWREADY / AWADDR / AWPROT / AWSIZE
WVALID / WREADY / WDATA / WSTRB / WLAST
BVALID / BREADY / BRESP
```

常见原因：

1. 写是 posted write，CPU 侧 `writel()` 返回不代表 target 已经执行副作用；
2. `WSTRB` lane 错，软件以为写了 bit，但目标寄存器对应 byte lane 没被 strobe；
3. `AWADDR` offset 错，写到了 reserved 或 alias 区域；
4. `AWSIZE` 与 slave 支持宽度不匹配；
5. `WLAST` 错误，slave 等待 burst 完成；
6. `BRESP=SLVERR/DECERR` 被上层 bridge 吞掉或没有暴露给软件；
7. 目标 IP clock/reset/power domain 未打开；
8. 寄存器是 write-one-to-clear / write-one-to-set / read-only，软件理解错语义；
9. 写之后缺少 readback/barrier，导致顺序和可见性不符合预期。

### 6.3 读全 `0xffff_ffff`

可能含义：

1. PCIe config / MMIO failed completion 被 host 转成全 F；
2. 目标 slave 实际返回全 F；
3. 地址 decode 到 default slave，default slave 返回固定值；
4. device 掉线、link down、BAR 没使能；
5. AXI security/firewall 拒绝后，上层 bridge 返回全 F；
6. 访问的是未上电 power domain 的寄存器窗口。

需要结合 RTL：

- 有没有 `ARVALID`；
- `ARADDR` 是否正确；
- 有没有 `RVALID`；
- `RRESP` 是 OKAY 还是 error；
- `RDATA` 是否真的是全 F。

### 6.4 `AWVALID` 有但 `AWREADY` 没有

这通常表示写地址阶段没有被接受。可能原因：

1. NoC route 没配置；
2. target slave reset 中；
3. clock gating 导致 slave 不响应；
4. firewall/security 阻断但没有返回错误；
5. interconnect outstanding 队列满；
6. address decoder 没有 default slave；
7. master 发出的属性组合不被接受，例如 burst/size/prot/cache 不合法。

### 6.5 `AW/W` 完成但没有 `BVALID`

这说明写请求已经被接收，但没有完成响应。可能原因：

1. slave 内部执行写副作用时卡住；
2. register block 没有产生 write response；
3. NoC response path route 错；
4. `BID` 或 ID tracking 逻辑错误；
5. `WLAST` 没有正确结束 burst；
6. clock domain crossing FIFO 卡住。

## 7. AXI 属性与软件 API 的关系

### 7.1 `writeb/writew/writel/writeq` 与 `AWSIZE/WSTRB`

| 软件接口 | 常见访问宽度 | AXI 关注点 |
| --- | --- | --- |
| `writeb()` | 8 bit | `AWSIZE`、`WSTRB` 只打开一个 byte lane |
| `writew()` | 16 bit | `AWSIZE`、`WSTRB` 打开两个 byte lane |
| `writel()` | 32 bit | `AWSIZE=2`，通常 4 byte strobe |
| `writeq()` | 64 bit | `AWSIZE=3`，通常 8 byte strobe，平台不一定支持所有 MMIO 场景 |
| `memcpy_toio()` / `memset_io()` | 多 beat 或多个单 beat | 可能生成连续 MMIO 写，需注意目标是否支持 burst/顺序/宽度 |

注意：Linux driver 对 MMIO 的普通 `memset()` / `memcpy()` 不一定适合，应该使用 `memset_io()` / `memcpy_toio()` / `memcpy_fromio()` 等 I/O accessor。

### 7.2 `AWPROT/ARPROT` 与安全域

`AxPROT` 通常包含：

| bit | 常见含义 | 调试意义 |
| --- | --- | --- |
| bit[0] | privileged / unprivileged | 目标可能只允许 privileged |
| bit[1] | secure / non-secure | Arm SoC 安全域问题重点 |
| bit[2] | instruction / data | 通常 MMIO 是 data access |

如果 PCIe inbound AXI master 发出的访问是 non-secure，而 PPU/secure register block 只允许 secure，软件可能看到：

- 读全 F；
- `RRESP=SLVERR`；
- `BRESP=SLVERR`；
- 访问 hang；
- firewall log 中有 security violation。

这类问题在 host 通过 PCIe 初始化 R82/PPU/PMU 时很常见。

### 7.3 `AxCACHE` 与 device / normal memory

`AxCACHE` 描述 bufferable/cacheable/modifiable 等属性。软件上通常对应：

- MMIO register：device / strongly ordered / non-cacheable 语义；
- shared memory / coherent DMA buffer：normal memory + coherent 属性；
- framebuffer / VRAM aperture：可能是 write-combine / non-cacheable / cacheable，取决于平台和映射方式。

如果属性错误，可能导致：

- 写合并导致寄存器副作用顺序异常；
- CPU/GPU 共享内存可见性异常；
- DMA buffer cache 维护不正确；
- 性能明显异常。

## 8. Atomic operation 与 AXI 的关系

标准 AXI4 主要定义普通 read/write transaction。软件或 GPU ISA 中的 `atomicAdd` / `atomicCAS` 本质是 read-modify-write 语义，但 AXI4 普通 read/write 不会自动保证跨 master 的 RMW 原子性。

因此需要区分：

| 层次 | 是否等价于 AXI 普通读写 | 说明 |
| --- | --- | --- |
| GPU 内部 L2 atomic | 否 | 通常在 GPU L2/atomic unit 内完成，对 GPU 内部线程原子 |
| AXI exclusive access | 部分相关 | 可用于实现某些 CPU/firmware lock，但依赖 exclusive monitor 和 slave/interconnect 支持 |
| AXI-ACE atomic/coherent transaction | 更相关 | 用于 coherent domain 内的原子/一致性事务 |
| PCIe AtomicOp | 不属于 AXI | PCIe TLP 层面的 fetch-add/swap/CAS |

对于 GPGPU KMD，需要明确：

- CUDA/OpenCL atomic 是否只保证 GPU 内部 memory scope；
- 如果目标地址是 host memory / shared memory，是否需要 coherent interconnect、PCIe AtomicOp、CXL、NVLink 或平台特定能力；
- AXI 普通 MMIO read/write 不能自然推出跨 CPU/GPU 的 atomic 一致性。

## 9. Bring-up 最小检查表

当软件访问某个寄存器/内存窗口失败时，可以按以下顺序查：

1. 软件地址是否正确：CPU VA -> PA -> PCIe BAR/inbound -> AXI address；
2. BAR / ATU / address decoder 是否配置正确；
3. 目标 IP 的 clock/reset/power domain 是否 ready；
4. RTL 是否看到 `AWVALID` 或 `ARVALID`；
5. `AWADDR/ARADDR` 是否为预期地址；
6. `AWPROT/ARPROT` 是否满足 secure/privileged 要求；
7. `AWSIZE/ARSIZE` 与访问宽度是否匹配；
8. `WSTRB` 是否打开了正确 byte lane；
9. `AWREADY/WREADY/ARREADY` 是否握手；
10. 写是否返回 `BVALID`，`BRESP` 是什么；
11. 读是否返回 `RVALID`，`RRESP/RDATA` 是什么；
12. NoC/firewall/default slave 是否有 error log；
13. 是否存在 outstanding transaction 堵塞；
14. 是否需要 readback 或 memory barrier 暴露 posted write completion；
15. 如果是 shared memory，是否还涉及 cache maintenance / coherency / IOMMU/SMMU。

## 10. 常用 RTL 波形触发条件

不同仿真/PLD 工具语法不同，但思路类似。

### 10.1 触发某个写地址

```text
AWVALID && AWREADY && AWADDR[31:0] == 32'hxxxx_xxxx
```

注意：某些 SoC 的 `AWADDR[39:32]` 可能包含 region、security、chiplet、NoC route 等非普通地址语义。软件调试时不要默认高位一定是普通物理地址。

### 10.2 触发某个读地址

```text
ARVALID && ARREADY && ARADDR[31:0] == 32'hxxxx_xxxx
```

### 10.3 触发 error response

```text
BVALID && BREADY && BRESP != 2'b00
RVALID && RREADY && RRESP != 2'b00
```

### 10.4 触发长时间没有 ready

```text
AWVALID && !AWREADY for N cycles
ARVALID && !ARREADY for N cycles
```

这类 trigger 很适合定位 bus hang。

## 11. 软件与 RTL 联合 debug 建议

1. 软件 log 中打印访问的 CPU physical address、BAR offset、寄存器 offset；
2. RTL 中同时抓 PCIe inbound bridge 输出和目标 slave 输入，判断问题在 bridge、NoC 还是 slave；
3. 对写操作增加 readback，区分 posted write 返回和目标真正完成；
4. 先用最小宽度和单 beat 访问验证，再测试 burst/memcpy_io；
5. 对 secure register block，明确 PCIe/CPU/R82 master 发出的 `AxPROT`；
6. 对 power/reset/clock 类寄存器，先确认访问路径本身不会依赖尚未打开的 clock domain；
7. 对 shared memory/ring buffer，除了 AXI，还要检查 cacheability、barrier、snoop/coherency、IOMMU/SMMU 属性。

## 12. 一句话总结

AXI 对软件驱动工程师最重要的价值是：

> 它把 `readl()` / `writel()` 这种软件动作，拆成可以在 RTL 波形中观察的地址、数据、响应、属性和握手信号。

只要能把软件现象映射到 `AW/W/B/AR/R` 五个通道，就能更快判断问题是在 KMD、PCIe bridge、NoC/firewall、clock/reset，还是目标 IP 本身。