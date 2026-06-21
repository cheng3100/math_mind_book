# WS2812 RTL / Verilog 开源学习路线

> 目标：从一个可完全掌控的 WS2812 时序驱动器开始，建立 **Verilog RTL、仿真、testbench、波形分析和调试** 的基础能力；后续再进入 UART、FIFO、AXI-lite 与开源 CPU RTL。

---

## 1. 为什么选择 WS2812

WS2812 RGB LED 的单线协议适合作为 RTL 入门项目，因为它同时覆盖：

- 时钟驱动的时序逻辑
- counter / timer
- 有限状态机（FSM）
- 串行协议编码
- reset / start / busy 控制
- testbench stimulus
- VCD/FST waveform 观察
- 时序参数换算与边界条件

它的输出 `dout` 本身就是协议波形，因此可以直接把 RTL 状态、计数器和最终输出关联起来。

---

## 2. 总体路线

```text
WS2812 timing transmitter
        ↓
UART TX / RX
        ↓
Single-clock FIFO
        ↓
Async FIFO / CDC basics
        ↓
AXI-lite register slave
        ↓
Simple RISC-V core
        ↓
CPU exception / trap return / pipeline flush
```

这条路线的目的不是立刻成为 RTL designer，而是先形成以下调试能力：

```text
Verilog source
    ↓
register / counter / FSM state
    ↓
clock-by-clock transition
    ↓
protocol waveform
    ↓
waveform-based root cause analysis
```

后续映射到工作中的场景：

```text
WS2812 FSM / counter
    → UART / FIFO / AXI handshake
    → GIC interrupt state
    → CPU pipeline valid / stall / flush / redirect
    → PLD waveform debug
```

---

## 3. 推荐工具链

### 3.1 第一阶段：轻量、快速建立直觉

| 用途 | 推荐工具 | 说明 |
|---|---|---|
| RTL 编译与仿真 | Icarus Verilog (`iverilog`) | 上手简单，适合 Verilog 入门和小型 testbench |
| 波形查看 | GTKWave | 打开 VCD/FST，查看信号和时间关系 |
| 编辑器 | VS Code | 建议安装 Verilog/SystemVerilog 语法高亮插件 |
| 构建入口 | `Makefile` | 固化 build / run / wave 命令 |

### 3.2 第二阶段：接近开源 SoC / CPU 项目

| 用途 | 推荐工具 | 说明 |
|---|---|---|
| 高性能 RTL 仿真 | Verilator | 大型开源 RTL 项目中非常常见 |
| Python testbench | cocotb | 后续可用 Python 写 stimulus / checker |
| 波形格式 | FST | 比 VCD 更紧凑，适合较长仿真 |
| lint / synthesis | Verilator lint、Yosys | 后续理解 RTL 质量与综合约束 |

### 3.3 Ubuntu 安装示例

```bash
sudo apt update
sudo apt install -y iverilog gtkwave make git

# 后续阶段再安装
sudo apt install -y verilator yosys
```

验证安装：

```bash
iverilog -V
gtkwave --version
verilator --version
yosys -V
```

---

## 4. 项目目录建议

```text
rtl_opensource_learn/
├── README.md
├── ws2812/
│   ├── rtl/
│   │   └── ws2812_tx.v
│   ├── tb/
│   │   └── tb_ws2812_tx.v
│   ├── sim/
│   │   ├── Makefile
│   │   └── wave.vcd              # generated, do not commit
│   ├── docs/
│   │   ├── protocol.md
│   │   ├── waveform_notes.md
│   │   └── debug_log.md
│   └── README.md
├── uart/
├── fifo/
├── axi_lite/
└── cpu_rtl/
```

建议将 generated file 放进 `.gitignore`：

```gitignore
*.vcd
*.fst
*.vvp
*.log
*.lxt
obj_dir/
```

---

## 5. WS2812 协议学习范围

> 不同 WS2812/WS2812B/兼容器件的数据手册会给出略不同的典型值和容差。第一阶段不要追求真实器件的极限时序，先用“仿真友好、清晰可见”的离散时钟周期参数建立工具链与波形直觉。

每个数据 bit 都由高电平和低电平组成：

```text
bit = 0:
  ┌───┐
──┘   └────────
  short high + long low

bit = 1:
  ┌───────┐
──┘       └────
  long high + short low
```

一帧通常按 GRB 顺序发送：

```text
G[7:0] → R[7:0] → B[7:0]
```

帧尾保持低电平足够长时间后，LED latch / reset。

---

## 6. Phase 1：最小单 bit 波形实验

### 6.1 学习目标

- 能编译 Verilog
- 能运行 testbench
- 能生成 VCD
- 能用 GTKWave 加载波形
- 能解释 `clk`、`rst_n`、counter、`dout` 的关系
- 能预测一个 `0` bit 和一个 `1` bit 的高低电平持续周期

### 6.2 最小模块接口建议

```verilog
module ws2812_bit_tx (
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    input  wire bit_value,
    output reg  busy,
    output reg  dout
);
```

第一版不用追求完整 24-bit RGB；只需要发送一个 bit：

```text
IDLE → HIGH → LOW → DONE/IDLE
```

### 6.3 第一版必须观察的信号

```text
clk
rst_n
start
bit_value
busy
state
cycle_cnt
dout
```

### 6.4 仿真前的预测练习

假设：

```text
T0H = 3 cycles
T0L = 7 cycles
T1H = 7 cycles
T1L = 3 cycles
```

在运行前先手画：

```text
bit_value = 0:
cycle_cnt : 0 1 2 3 4 5 6 7 8 9
DOUT      : 1 1 1 0 0 0 0 0 0 0

bit_value = 1:
cycle_cnt : 0 1 2 3 4 5 6 7 8 9
DOUT      : 1 1 1 1 1 1 1 0 0 0
```

然后对照真实波形。此过程比“只看代码”更重要。

---

## 7. Phase 2：完整 24-bit WS2812 transmitter

### 7.1 增加功能

- `rgb_data[23:0]` 输入
- 固定 GRB 序列
- 每一 bit 的发送
- bit counter
- reset/latch low period
- `busy` / `done` 信号

### 7.2 推荐 FSM

```text
IDLE
  ↓ start
LOAD
  ↓
SEND_HIGH
  ↓ high counter expires
SEND_LOW
  ↓ low counter expires
NEXT_BIT
  ├── more bits → SEND_HIGH
  └── last bit  → RESET_LOW
                    ↓
                  IDLE
```

### 7.3 波形分析重点

- `state` 是否每拍按预期变化
- `bit_index` 是否从 23 递减到 0，或按设计递增
- `shift_reg` 的移位方向是否正确
- `dout` 的 high time 是否只由当前 bit 决定
- `RESET_LOW` 是否足够长
- `busy` 是否覆盖整个 transmission
- `start` 在 `busy=1` 时是否被正确忽略或排队

---

## 8. Phase 3：建立规范 testbench 思维

### 8.1 Testbench 应分三部分

```text
clock generator
    +
reset / stimulus
    +
monitor / self-check
```

### 8.2 最小 testbench 职责

- 产生稳定时钟
- 拉低 / 释放 reset
- 发送 `start`
- 设置不同数据模式：全 0、全 1、交替位、单 bit
- dump waveform
- 检查 `busy` 和 `done`

### 8.3 建议测试用例

| Case | 输入数据 | 要验证的内容 |
|---|---:|---|
| all-zero | `24'h000000` | 全部 bit 为 `0` 的 pulse width |
| all-one | `24'hFFFFFF` | 全部 bit 为 `1` 的 pulse width |
| alternating | `24'hAA55AA` | bit 切换时高电平长度是否正确 |
| one-hot | `24'h000001` | 最后一个 bit 的边界行为 |
| back-to-back start | 两次连续 start | busy 期间 start 的处理策略 |
| reset during send | send 中 reset | FSM / dout / counter 是否安全回到初始状态 |

---

## 9. 常用仿真命令

### 9.1 Icarus Verilog

```bash
iverilog -g2012 \
  -o sim/ws2812_tb.vvp \
  rtl/ws2812_tx.v \
  tb/tb_ws2812_tx.v

vvp sim/ws2812_tb.vvp

gtkwave sim/wave.vcd
```

### 9.2 生成 VCD 的 testbench 片段

```verilog
initial begin
    $dumpfile("sim/wave.vcd");
    $dumpvars(0, tb_ws2812_tx);
end
```

### 9.3 推荐的 `Makefile` 目标

```makefile
TOP      := tb_ws2812_tx
RTL      := rtl/ws2812_tx.v
TB       := tb/tb_ws2812_tx.v
OUT      := sim/$(TOP).vvp
WAVE     := sim/wave.vcd

.PHONY: all run wave clean

all: run

run:
	mkdir -p sim
	iverilog -g2012 -o $(OUT) $(RTL) $(TB)
	vvp $(OUT)

wave: run
	gtkwave $(WAVE)

clean:
	rm -f sim/*.vvp sim/*.vcd sim/*.fst
```

---

## 10. 波形阅读方法

每次看波形都按固定顺序，不要一开始只盯着 `dout`：

1. `clk` 是否符合预期
2. `rst_n` 的释放是否发生在时钟边沿附近并可控
3. `start` 被哪一个时钟边沿采样
4. FSM 从什么状态转到什么状态
5. counter 从何值开始、何时清零、何时到终值
6. `bit_value` / `shift_reg` 在哪一拍被锁存
7. `dout` 何时从 0→1、何时从 1→0
8. `busy` / `done` 是否覆盖完整 transaction

建议在 GTKWave 中建立 signal group：

```text
[control]
  clk rst_n start busy done

[fsm]
  state next_state

[counters]
  cycle_cnt bit_index reset_cnt

[data]
  rgb_data shift_reg current_bit

[output]
  dout
```

---

## 11. RTL 思维中最容易犯的错误

### 11.1 把 `always @(posedge clk)` 当作顺序软件代码

错误直觉：

```verilog
counter <= counter + 1;
if (counter == 9)
    state <= DONE;
```

以为 `if` 会看到 `counter + 1` 后的新值。

实际情况：在非阻塞赋值 `<=` 中，右值基于当前时钟沿到来前的旧寄存器值计算；更新在当前 time step 的后续 NBA 阶段统一生效。

### 11.2 counter 边界 off-by-one

最常见症状：预期 3 个 cycle 的 high pulse，实际得到 2 或 4 个 cycle。

调试方法：

- 明确 counter 从 `0` 还是 `1` 开始
- 明确比较条件是 `== N-1` 还是 `== N`
- 在波形中数完整的 rising-edge 间隔

### 11.3 同一寄存器在多个 always block 中赋值

这会造成 RTL 语义不清晰，综合后行为也可能与预期不同。

规则：一个时序寄存器尽量只由一个 `always_ff` / `always @(posedge clk)` 驱动。

### 11.4 combinational logic 没有完整默认赋值

容易推导 latch。

后续使用 SystemVerilog 时，推荐：

```verilog
always_comb begin
    next_state = state;
    // default assignments first
end
```

### 11.5 reset 不完整

所有与协议输出相关的状态，例如 `state`、counter、`busy`、`dout`、bit index、shift register，都应在 reset 后落在确定状态。

---

## 12. 从 WS2812 映射到 CPU / AXI / PLD 调试

| WS2812 概念 | 后续 RTL / SoC 对应概念 |
|---|---|
| state transition | CPU pipeline state / GIC state / AXI channel FSM |
| cycle counter | timeout counter / timer / performance counter |
| `start` + `busy` | request / ready-valid transaction |
| `dout` pulse width | AXI handshake timing / interrupt pulse / clock-domain event |
| shift register | serializer / command packet / instruction shift path |
| reset-low latch | protocol completion / drain / quiescent period |
| waveform check | PLD trigger / RTL simulation / assertion debug |

最终你要建立的共同调试框架是：

```text
observable symptom
    ↓
state / counter / register transition
    ↓
clock-by-clock waveform
    ↓
RTL condition that enabled the transition
    ↓
root cause
```

这套方法可以直接迁移到：

- AXI `VALID/READY`
- GIC `pending/active`
- CPU `valid/stall/flush/redirect`
- Cortex-R exception entry / `eret`
- NOC timeout / CDC handshake

---

## 13. 后续阶段计划

### Milestone A: WS2812

完成标准：

- [ ] 可以从零编译和运行 Verilog testbench
- [ ] 能使用 GTKWave 打开 VCD
- [ ] 能解释单 bit `0` / `1` 的波形差异
- [ ] 能定位至少一个 counter off-by-one bug
- [ ] 能完成 24-bit GRB transmission
- [ ] 能写最基本的 self-check

### Milestone B: UART

完成标准：

- [ ] UART TX 发送 8N1
- [ ] UART RX 采样并检查 framing error
- [ ] 理解 baud divider 和 sampling point

### Milestone C: FIFO

完成标准：

- [ ] 单时钟 FIFO
- [ ] full / empty / almost-full
- [ ] overflow / underflow test
- [ ] 后续扩展 async FIFO 与 CDC

### Milestone D: AXI-lite

完成标准：

- [ ] register read / write
- [ ] AW/W/B 与 AR/R channel 独立处理
- [ ] valid/ready backpressure test
- [ ] 理解 response timing

### Milestone E: CPU RTL

候选项目：

- PicoRV32：适合先理解简单 CPU 数据通路
- CV32E40P：适合进一步研究 trap、`mret`、flush、redirect

重点不是一次读完整 CPU，而是围绕 testcase 观察：

```text
illegal instruction
interrupt entry
mret
pipeline flush
fetch redirect
CSR restore
```

---

## 14. 学习记录模板

每完成一个小实验，将记录写到对应目录的 `docs/debug_log.md`：

```markdown
## YYYY-MM-DD: <实验名称>

### 目标

- 

### 输入条件

- clock frequency:
- timing parameters:
- stimulus:

### 预期波形

```text

```

### 实际波形

- waveform file:
- key signal observations:

### 问题与分析

- symptom:
- suspected RTL condition:
- root cause:

### 修复

```verilog
// relevant patch
```

### 结论

- 

### 与后续复杂 RTL 的映射

- 

### 下一步

- [ ] 
```

---

## 15. 当前下一步

1. 建立 `ws2812/rtl`、`ws2812/tb`、`ws2812/sim`、`ws2812/docs` 目录。
2. 编写只发送单个 bit 的 `ws2812_bit_tx.v`。
3. 编写最小 testbench，分别发送 `0` 与 `1`。
4. 生成 `wave.vcd` 并在 GTKWave 中观察。
5. 在运行前手画预期波形，运行后检查 high/low cycle 数。
6. 故意制造一个 off-by-one bug，再通过波形定位并修复。

> 原则：每一阶段都要先预测，再仿真，再从波形回推 RTL；不要只通过“仿真 PASS”判断自己已经理解。 
