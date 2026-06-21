# WS2812 RTL Demo HLD

## 1. 文档目标

本文用于在真正编写 RTL 之前，先明确两个层面的内容：

1. 以 WS2812 demo 为例，一个完整 RTL demo 从需求到波形分析应分成哪些步骤，每一步的具体内容、目标和验收标准是什么。
2. 这个过程中会涉及哪些工具链类别，每类工具的作用、可选工具、业界常用工具、本 demo 推荐工具，以及它们会在 RTL 流程中的哪些步骤使用。

本 demo 的第一目标不是深入 WS2812 协议本身，而是建立一条可重复的开源 RTL 设计、仿真、测试和波形分析流程。

```text
requirement
  -> micro-architecture
  -> RTL coding
  -> testbench
  -> simulation
  -> waveform
  -> debug
  -> note
```

---

## 2. WS2812 Demo 的完整 RTL 过程

### 2.1 Step 0: 需求定义

#### 目标

明确这个 demo 要实现什么，不实现什么，避免一开始陷入过度设计。

#### 具体内容

第一阶段只实现单 bit WS2812 波形发送。

更准确地说，本 demo 设计的不是 WS2812 LED 芯片本身，而是上游的 **WS2812 controller / transmitter**。它负责把上层给出的 bit 或 RGB 数据编码成 WS2812 `DIN` 线上需要的单线时序波形。

系统边界如下：

```text
上层逻辑 / testbench
  input: bit_value 或后续 rgb_data[23:0]
        ↓
本 demo: ws2812_bit_tx / ws2812_tx
  output: ws2812_wave，当前文档中暂名为 dout
        ↓
真实 WS2812 芯片
  input: DIN 接收该波形
  output: DOUT 级联转发后续 LED 的波形
```

因此 HLD 中的 `bit_value` 不是 WS2812 芯片引脚上的输入，而是 **transmitter RTL 的抽象输入**。`dout` 也不是在模拟 WS2812 芯片的级联 `DOUT` 引脚，而是 **transmitter RTL 输出给第一个 WS2812 芯片 `DIN` 的波形**。

如果要建模真实 WS2812 芯片本身，接口会更像：

```verilog
module ws2812_device_model (
    input  wire din,
    output wire dout
);
```

这个模型要做的是从 `din` 波形中解码 bit cell、锁存本 LED 的 24-bit GRB 数据，并把剩余数据整形后从 `dout` 级联输出。那是 device model / behavioral model 的范围，不是当前第一个 RTL transmitter demo 的范围。

这里需要区分两个容易混淆的“周期”：

- `WS2812 bit cell`：芯片 `DIN` 线上一个数据 bit 的完整时间窗口。完整颜色数据通常是 24 个 bit cell，常见发送顺序是 GRB，即 `G[7:0] -> R[7:0] -> B[7:0]`。
- `RTL clk cycle`：本 demo 内部仿真时钟的周期。为了方便学习和数波形，第一阶段把一个 WS2812 bit cell 离散成 10 个 RTL clock cycles。

因此 HLD 中的 `3 cycles / 7 cycles` 不是说 WS2812 芯片只接收 3 个或 7 个外部周期，而是说：在一个数据 bit cell 内，RTL 输出 `dout` 保持高电平或低电平的仿真时钟周期数。

`dout` 是本 RTL transmitter module 的输出信号；接到真实芯片时，它对应 WS2812 的 `DIN` 输入波形。后续实际写 RTL 时，可以考虑把该信号命名为 `ws_out` 或 `led_din`，避免和 WS2812 芯片自己的 `DOUT` 级联输出混淆。

```text
bit_value = 0:
  dout high 3 cycles
  dout low  7 cycles

bit_value = 1:
  dout high 7 cycles
  dout low  3 cycles
```

模块接口建议：

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

暂不实现：

- 完整 24-bit GRB frame；
- 多 LED 串联；
- 真实器件极限时序；
- 参数化时钟频率换算；
- 综合时序约束；
- 上板验证。

#### 输出物

- 本 HLD 文档；
- 后续 `README.md` 中的 demo 说明；
- 明确的最小接口和时序参数。

#### 验收标准

- 能用一句话说明 demo 的功能边界；
- 能列出输入、输出和关键时序参数；
- 能解释为什么第一阶段只做 single-bit。

---

### 2.2 Step 1: 协议和波形拆解

#### 目标

把 WS2812 的协议要求转换成 RTL 可实现、testbench 可检查、波形可观察的周期级行为。

#### 具体内容

WS2812 的输入不是额外的 `clk + data` 两根线，而是一根 `DIN` 线上的 self-timed 串行波形。每个 bit cell 通过高电平持续时间编码 0 或 1：

```text
0 bit: short high + long low
1 bit: long high  + short low
```

也就是说，一个完整 24-bit 颜色值不是“24 个外部 clock cycle”，而是 24 个连续的 bit cell；每个 bit cell 内部再由高电平段和低电平段组成。

本 demo 第一阶段只取其中一个 bit cell 来练习 RTL 设计、仿真、测试和波形观察。为了仿真清晰，暂定一个 bit cell 总长度为 10 个 RTL clock cycles：

| bit value | high cycles | low cycles | total cycles |
| --- | ---: | ---: | ---: |
| `0` | 3 | 7 | 10 |
| `1` | 7 | 3 | 10 |

真实 WS2812/WS2812B 器件通常用纳秒或微秒定义 `T0H/T0L/T1H/T1L`，不同数据手册和兼容芯片会有容差差异。这里的 `3/7` 和 `7/3` 是学习用的仿真友好参数，不是最终上板时必须使用的真实时序参数。

预期波形：

```text
bit_value = 0:
cycle_cnt : 0 1 2 3 4 5 6 7 8 9
dout      : 1 1 1 0 0 0 0 0 0 0

bit_value = 1:
cycle_cnt : 0 1 2 3 4 5 6 7 8 9
dout      : 1 1 1 1 1 1 1 0 0 0
```

需要提前定义：

- `start` 在哪个时钟沿被采样；
- `busy` 覆盖哪些状态；
- `cycle_cnt` 从 0 开始还是从 1 开始；
- high 到 low 的跳转条件是 `cycle_cnt == high_cycles - 1` 还是 `cycle_cnt == high_cycles`；
- low 结束后是否回到 IDLE。

#### 输出物

- `doc/rtl_demo_hld.md` 中的波形定义；
- 后续 `doc/waveform_notes.md` 中的预期波形记录。

#### 验收标准

- 不看 RTL 代码也能手画 `0` bit 和 `1` bit 的波形；
- 能把每个波形边沿对应到 counter 比较条件；
- 能指出 off-by-one bug 会导致什么波形异常。

---

### 2.3 Step 2: 微架构设计

#### 目标

把协议波形拆成 RTL 内部状态、寄存器和转移条件。

#### 具体内容

推荐 FSM：

```text
IDLE
  -> HIGH
  -> LOW
  -> IDLE
```

关键寄存器：

| signal | 类型 | 作用 |
| --- | --- | --- |
| `state` | FSM state | 表示当前处于 IDLE/HIGH/LOW |
| `cycle_cnt` | counter | 统计当前 high 或 low phase 已持续的周期 |
| `busy` | output reg | 表示当前正在发送一个 bit |
| `dout` | output reg | WS2812 单线输出 |
| `latched_bit` | internal reg | 锁存 start 时刻的 `bit_value` |

关键组合条件：

```text
high_cycles = latched_bit ? T1H : T0H
low_cycles  = latched_bit ? T1L : T0L
```

#### 输出物

- FSM 状态定义；
- counter 行为定义；
- signal 观察列表。

#### 验收标准

- 每个状态的输出行为明确；
- 每个状态的跳转条件明确；
- reset 后所有输出和内部寄存器进入确定状态；
- 不存在同一个寄存器由多个 always block 驱动的设计。

---

### 2.4 Step 3: RTL 编码

#### 目标

实现一个简单、可仿真、可观察的 Verilog RTL module。

#### 具体内容

建议文件：

```text
rtl/ws2812_bit_tx.v
```

编码原则：

- 使用清晰的状态机；
- 所有时序寄存器在 reset 中赋确定值；
- `start` 只在 `IDLE` 状态采样；
- `busy` 在 HIGH/LOW 期间保持为 1；
- `dout` 在 IDLE 保持 0；
- 优先可读性，不追求高度参数化。

#### 输出物

- `rtl/ws2812_bit_tx.v`

#### 验收标准

- `iverilog -g2012` 可以编译；
- reset 后 `busy=0`、`dout=0`；
- `start` 后进入发送过程；
- `bit_value=0/1` 能走不同 high/low 周期；
- RTL 中用于波形观察的关键寄存器名称稳定。

---

### 2.5 Step 4: Testbench 设计

#### 目标

构造最小 testbench，能驱动 DUT 并生成可观察波形。

#### 具体内容

建议文件：

```text
tb/tb_ws2812_bit_tx.v
```

testbench 分三部分：

```text
clock generator
  + reset / stimulus
  + monitor / optional checker
```

最小 stimulus：

1. 产生 `clk`；
2. 拉低并释放 `rst_n`；
3. 设置 `bit_value=0`，打一拍 `start`；
4. 等待 `busy` 拉低；
5. 设置 `bit_value=1`，打一拍 `start`；
6. 等待 `busy` 拉低；
7. 结束仿真。

这里的“打一拍”指让 `start` 保持有效 1 个 RTL `clk` cycle。它和前面 `T0H=3 cycles`、`T1H=7 cycles` 使用的是同一个仿真时钟单位，但语义不同：

- `start` 的 1 拍：控制握手脉冲，用来告诉 transmitter 开始发送一个 bit cell；
- `3/7/10 cycles`：transmitter 接收 `start` 后，在输出 `dout` 上生成的 WS2812 bit cell 波形长度。

也就是：

```text
start pulse: 1 RTL clk cycle
  -> trigger transmitter
  -> dout waveform: 10 RTL clk cycles total
       - bit 0: 3 high + 7 low
       - bit 1: 7 high + 3 low
```

需要生成波形：

```verilog
initial begin
    $dumpfile("wave.vcd");
    $dumpvars(0, tb_ws2812_bit_tx);
end
```

#### 输出物

- `tb/tb_ws2812_bit_tx.v`
- `sim/wave.vcd`，生成文件，不提交

#### 验收标准

- testbench 能稳定结束，不依赖手动中断；
- 能在波形中看到 reset、两次 start、两个 bit transaction；
- 能观察 `state/cycle_cnt/dout/busy`；
- 后续可以逐步加入 self-check。

---

### 2.6 Step 5: 仿真运行

#### 目标

用开源 simulator 编译并运行 RTL/testbench，确认工具链命令可复现。

#### 具体内容

建议 Makefile 入口：

```text
sim/Makefile
```

推荐命令：

```bash
make run
make wave
make clean
```

底层命令：

```bash
iverilog -g2012 -o tb_ws2812_bit_tx.vvp ../rtl/ws2812_bit_tx.v ../tb/tb_ws2812_bit_tx.v
vvp tb_ws2812_bit_tx.vvp
gtkwave wave.vcd
```

#### 输出物

- `sim/Makefile`
- `sim/*.vvp`，生成文件，不提交
- `sim/*.vcd`，生成文件，不提交

#### 验收标准

- `make run` 可以从干净状态生成仿真结果；
- 仿真无编译错误；
- 仿真能自动结束；
- 生成波形文件；
- 命令和结果写入笔记。

---

### 2.7 Step 6: 波形观察与分析

#### 目标

通过波形证明 RTL 行为符合 Step 1 的周期级预期。

#### 具体内容

观察信号分组：

```text
[control]
  clk rst_n start bit_value busy

[fsm]
  state

[counter]
  cycle_cnt

[output]
  dout
```

分析顺序：

1. reset 是否使状态和输出回到确定值；
2. start 被哪个 rising edge 采样；
3. `busy` 何时拉高；
4. `state` 是否按 `IDLE -> HIGH -> LOW -> IDLE` 变化；
5. `cycle_cnt` 是否从 0 开始；
6. `dout` high phase 是否持续 3 或 7 cycles；
7. low phase 是否持续 7 或 3 cycles；
8. transaction 结束后 `busy` 和 `dout` 是否回到 0。

#### 输出物

- `doc/waveform_notes.md`
- 必要时保存 GTKWave 配置文件，但第一阶段可以不提交

#### 验收标准

- 能用周期数解释 `dout` 的每段高低电平；
- 能把 `dout` 变化对应到 `state/cycle_cnt`；
- 至少记录一个潜在 off-by-one 检查点；
- 若行为不符合预期，能记录失败现象和修正方向。

---

### 2.8 Step 7: Debug 和修正

#### 目标

形成从波形症状回到 RTL 条件的调试路径。

#### 具体内容

典型问题：

| 现象 | 可能原因 | 检查点 |
| --- | --- | --- |
| high 少 1 个 cycle | 比较条件提前 | `cycle_cnt == high_cycles - 1` 的使用位置 |
| high 多 1 个 cycle | counter 清零或状态跳转滞后 | state 跳转后的 `dout` 更新 |
| `start` 无效 | start 没有对齐 clock 或 DUT 不在 IDLE | start pulse 宽度和 state |
| `busy` 提前拉低 | LOW phase 结束条件错误 | low counter 结束点 |
| reset 后 `dout` 为 X | reset 没有覆盖输出寄存器 | reset 分支赋值 |

#### 输出物

- `doc/debug_log.md`
- RTL 修正 patch
- 更新后的 waveform note

#### 验收标准

- 每个 bug 都能写出：现象、根因、修改点、验证结果；
- 修正后重新运行 `make run`；
- 不通过肉眼猜测直接跳过波形验证。

---

### 2.9 Step 8: 记录和阶段总结

#### 目标

把一次 RTL demo 的过程沉淀成后续 UART/FIFO/AXI-lite 可复用的方法。

#### 具体内容

记录：

- 工具版本；
- 仿真命令；
- RTL 文件；
- testbench 文件；
- 观察信号；
- 波形结论；
- 遇到的问题；
- 下一阶段扩展计划。

#### 输出物

- `README.md`
- `doc/waveform_notes.md`
- `doc/debug_log.md`

#### 验收标准

- 后续重新 clone 仓库后能按文档复现实验；
- 文档能解释为什么 RTL 这么写；
- 文档能解释波形为什么正确；
- 为 24-bit transmitter 留出明确下一步。

---

## 3. 工具链分类和选择

### 3.1 总览表

| 工具类别 | 作用 | 开源可选工具 | 业界常用商用工具 | 本 demo 推荐 | 对应 RTL 流程步骤 |
| --- | --- | --- | --- | --- | --- |
| 编辑器/IDE | 编写 RTL、testbench、文档 | VS Code, Vim, Emacs | DVT Eclipse, Sigasi, vendor IDE | VS Code 或 Vim | Step 0-8 |
| 代码搜索 | 查找 module、signal、状态机 | ripgrep, ctags | Source Insight, Understand, IDE indexer | ripgrep | Step 2-8 |
| 版本管理 | 记录变更、回溯实验过程 | Git | Git, Perforce | Git | Step 0-8 |
| RTL simulator | 编译并执行 RTL/testbench | Icarus Verilog, Verilator | VCS, QuestaSim, Xcelium | Icarus Verilog | Step 5 |
| Testbench 框架 | 编写 stimulus、checker、scoreboard | Verilog TB, cocotb | UVM, vendor SV TB flow | Verilog TB | Step 4-5 |
| 波形格式 | 保存仿真信号变化 | VCD, FST | FSDB, SHM, WLF, VPD | VCD | Step 5-6 |
| 波形查看 | 观察信号、定位边沿 | GTKWave | Verdi, SimVision, Questa Visualizer, DVE | GTKWave | Step 6-7 |
| Lint/静态检查 | 检查语法、风格、潜在 RTL 问题 | Verilator lint, svlint, Verible | SpyGlass Lint, Questa Lint, Ascent Lint | 后续 Verilator lint | Step 3, Step 7 |
| 综合 sanity check | 检查可综合性和基本网表 | Yosys | Design Compiler, Genus, Precision | 后续 Yosys | Step 3 后可选 |
| 构建自动化 | 固化编译、运行、清理命令 | Make, Ninja | Make, vendor Tcl flow, Jenkins flow | Make | Step 5 |
| CI | 自动运行 smoke test | GitHub Actions, GitLab CI | Jenkins, internal farm | 后续 GitHub Actions | Step 8 后可选 |

---

### 3.2 编辑器和代码组织工具

#### 作用

编辑 RTL、testbench、Makefile 和 Markdown，保持文件结构清晰。

#### 可选工具

- 开源：VS Code、Vim、Emacs；
- 商用/成熟项目常见：DVT Eclipse、Sigasi、vendor IDE、Source Insight、Understand。

#### 本 demo 推荐

使用 VS Code 或 Vim 即可。代码搜索优先使用 `rg`。

#### 用在哪些流程

- Step 0: 写需求；
- Step 2: 写微架构；
- Step 3: 写 RTL；
- Step 4: 写 testbench；
- Step 8: 写总结。

---

### 3.3 RTL 仿真工具

#### 作用

把 RTL 和 testbench 编译成可执行仿真模型，并推进仿真时间，得到输出行为和波形。

#### 可选工具

- 开源：Icarus Verilog、Verilator；
- 商用：Synopsys VCS、Siemens QuestaSim、Cadence Xcelium。

#### 本 demo 推荐

第一阶段推荐 Icarus Verilog：

```bash
iverilog -g2012
vvp
```

原因：

- 命令简单；
- 适合小型 Verilog demo；
- 直接支持 `$dumpfile/$dumpvars` 生成 VCD；
- 学习成本低。

Verilator 适合后续：

- lint；
- 更快仿真；
- C++ testbench；
- 大型开源 RTL 项目。

#### 用在哪些流程

- Step 5: 仿真运行；
- Step 7: debug 后重新验证；
- Step 8: 记录可复现命令。

---

### 3.4 Testbench 和验证工具

#### 作用

产生 DUT 输入，检查 DUT 输出，控制仿真结束。

#### 可选工具

- 开源：纯 Verilog testbench、SystemVerilog testbench、cocotb；
- 商用/成熟项目常见：SystemVerilog UVM + VCS/QuestaSim/Xcelium。

#### 本 demo 推荐

第一阶段使用纯 Verilog testbench。

原因：

- 依赖最少；
- 能直接看懂 clock、reset、start 的关系；
- 更适合建立周期级仿真直觉。

后续可以加入：

- self-check task；
- assertion；
- cocotb Python checker。

#### 用在哪些流程

- Step 4: testbench 设计；
- Step 5: 仿真运行；
- Step 6: 生成波形观察点；
- Step 7: 复现 bug 和验证 fix。

---

### 3.5 波形工具

#### 作用

把仿真过程中的信号变化保存下来，并以时间轴方式观察 RTL 行为。

#### 可选工具

- 开源波形格式：VCD、FST；
- 商用波形格式：FSDB、SHM、WLF、VPD；
- 开源查看器：GTKWave；
- 商用查看器：Verdi、SimVision、Questa Visualizer、DVE。

#### 本 demo 推荐

第一阶段使用：

```text
VCD + GTKWave
```

原因：

- 配置简单；
- 所有开源 simulator 都容易生成；
- 足够观察小型 demo；
- 适合学习 clock-by-clock debug。

#### 用在哪些流程

- Step 5: 生成 `wave.vcd`；
- Step 6: 观察和分析波形；
- Step 7: 定位 off-by-one、reset、start 采样问题。

---

### 3.6 Lint 和静态检查工具

#### 作用

在运行仿真之外，提前发现一类 RTL 结构问题。

典型检查：

- 未使用信号；
- 位宽不匹配；
- latch 风险；
- 不完整赋值；
- 多驱动；
- 不可综合写法；
- reset 不完整。

#### 可选工具

- 开源：Verilator lint、svlint、Verible；
- 商用：SpyGlass Lint、Questa Lint、Ascent Lint。

#### 本 demo 推荐

第一阶段不强制。完成 single-bit 仿真后，可以加入：

```bash
verilator --lint-only
```

#### 用在哪些流程

- Step 3: RTL 编码后做基本检查；
- Step 7: debug 时辅助定位结构性问题；
- Step 8: 作为后续质量门槛记录。

---

### 3.7 综合和可综合性检查工具

#### 作用

检查 RTL 是否能被转换成门级逻辑，帮助区分“只适合仿真”的代码和“可以综合成硬件”的代码。

#### 可选工具

- 开源：Yosys；
- FPGA 开源链：Yosys + nextpnr；
- 商用 ASIC：Synopsys Design Compiler、Cadence Genus；
- 商用 FPGA：Xilinx Vivado、Intel Quartus、Microchip Libero。

#### 本 demo 推荐

第一阶段不作为必须项。single-bit demo 稳定后，可以用 Yosys 做 sanity check。

#### 用在哪些流程

- Step 3 之后：检查 RTL 是否基本可综合；
- Step 8 之后：作为下一阶段工程化补充。

---

### 3.8 构建和自动化工具

#### 作用

把编译、运行、打开波形、清理生成文件等命令固化下来，避免每次手写长命令。

#### 可选工具

- 开源：Make、Ninja、shell、Python；
- 商用/成熟项目常见：Make、Tcl flow、Jenkins、内部 build farm。

#### 本 demo 推荐

使用 Makefile：

```bash
make run
make wave
make clean
```

#### 用在哪些流程

- Step 5: 仿真运行；
- Step 6: 打开波形；
- Step 7: debug 后重复验证；
- Step 8: 文档记录可复现命令。

---

## 4. 工具链和 RTL 流程映射

### 4.1 按流程查看工具

| RTL 流程步骤 | 主要工具 | 产物 |
| --- | --- | --- |
| Step 0 需求定义 | Markdown editor, Git | HLD/README |
| Step 1 协议和波形拆解 | Markdown editor, 手画波形, Git | 预期波形说明 |
| Step 2 微架构设计 | Markdown editor, rg, Git | FSM/signal/counter 说明 |
| Step 3 RTL 编码 | VS Code/Vim, rg, optional lint | `rtl/ws2812_bit_tx.v` |
| Step 4 Testbench 设计 | VS Code/Vim, Verilog TB | `tb/tb_ws2812_bit_tx.v` |
| Step 5 仿真运行 | Make, Icarus Verilog, vvp | `.vvp`, `.vcd` |
| Step 6 波形观察 | GTKWave, VCD | waveform notes |
| Step 7 Debug 修正 | GTKWave, editor, simulator, optional lint | RTL patch, debug log |
| Step 8 记录总结 | Markdown editor, Git | README, notes |

### 4.2 按工具查看流程

| 工具 | 主要使用阶段 | 说明 |
| --- | --- | --- |
| Git | Step 0-8 | 记录设计、仿真和笔记变更 |
| rg | Step 2-8 | 查找 signal、module、state |
| VS Code/Vim | Step 0-8 | 编辑所有文本和代码 |
| Icarus Verilog | Step 5, Step 7 | 编译 RTL/testbench |
| vvp | Step 5, Step 7 | 执行仿真 |
| GTKWave | Step 6, Step 7 | 观察波形，定位问题 |
| Make | Step 5-7 | 固化重复命令 |
| Verilator lint | Step 3, Step 7 可选 | 静态检查 |
| Yosys | Step 3 后可选 | 综合 sanity check |

---

## 5. 本 Demo 的推荐最小工具组合

第一阶段只要求：

```text
Git
Make
Icarus Verilog
GTKWave
Markdown editor
```

对应 Ubuntu 安装示例：

```bash
sudo apt update
sudo apt install -y git make iverilog gtkwave
```

可选后续工具：

```bash
sudo apt install -y verilator yosys
```

第一阶段不要因为没有 Verilator、Yosys、cocotb 或 UVM 而阻塞。先完成：

```text
write RTL
  -> write Verilog testbench
  -> run iverilog/vvp
  -> open VCD in GTKWave
  -> explain waveform
```

---

## 6. 第一阶段完成定义

single-bit WS2812 demo 完成时，应满足：

- 有清晰的需求边界；
- 有 `rtl/ws2812_bit_tx.v`；
- 有 `tb/tb_ws2812_bit_tx.v`；
- 有 `sim/Makefile`；
- `make run` 能完成仿真；
- 能生成 `wave.vcd`；
- 能用 GTKWave 看到 `clk/rst_n/start/bit_value/busy/state/cycle_cnt/dout`；
- `0` bit 的 high/low 周期符合 `3/7`；
- `1` bit 的 high/low 周期符合 `7/3`；
- 有 `doc/waveform_notes.md` 记录预期和实际波形；
- 如遇 bug，有 `doc/debug_log.md` 记录现象、根因、修改和验证。

完成这些之后，再进入完整 24-bit WS2812 transmitter。
