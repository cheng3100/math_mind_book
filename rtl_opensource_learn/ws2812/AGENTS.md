# AGENTS.md

本目录用于推进第一个开源 RTL demo：`WS2812` 单线 RGB LED 时序驱动器。

这个 demo 的核心目标不是先写出复杂 RTL，而是建立一条可重复的开源 RTL 学习闭环：

```text
RTL design
  -> RTL simulation
  -> testbench stimulus / checker
  -> waveform dump
  -> waveform observation
  -> debug note
  -> incremental fix
```

后续所有修改都应服务于这条闭环。

## 1. 第一阶段目标

### 1.1 主要目标：掌握开源 RTL 工具链完整流程

第一阶段重点是跑通并理解：

- 如何组织一个小型 RTL demo 目录；
- 如何编写最小可仿真的 Verilog RTL；
- 如何写 testbench 产生 clock、reset、start 和输入数据；
- 如何用开源 simulator 编译并运行 RTL 仿真；
- 如何生成 VCD/FST 波形；
- 如何使用 waveform viewer 观察 `clk/rst/start/state/counter/dout`；
- 如何根据波形定位 counter、FSM、reset、busy/done 之类的常见问题；
- 如何把一次实验过程记录成 Markdown 笔记。

### 1.2 次要目标：WS2812 RTL 语法与设计细节

WS2812 协议、FSM、counter、shift register 是本阶段的练习载体，不是唯一目标。

因此实现时应优先保持：

- RTL 结构简单；
- 状态机清晰；
- testbench 易读；
- 波形信号完整；
- 每一步都能通过仿真解释。

不要一开始追求高度参数化、复杂复用、综合优化或接近工业项目的编码风格。

### 1.3 推荐推进顺序

```text
single-bit WS2812 waveform
  -> 24-bit GRB transmitter
  -> self-checking testbench
  -> waveform debug notes
  -> optional lint
  -> optional synthesis sanity check
```

第一版只需要证明：

```text
bit_value = 0 -> short high + long low
bit_value = 1 -> long high + short low
```

## 2. 目录约定

建议保持如下结构：

```text
rtl_opensource_learn/ws2812/
├── AGENTS.md
├── README.md
├── rtl/
│   ├── ws2812_bit_tx.v
│   └── ws2812_tx.v
├── tb/
│   ├── tb_ws2812_bit_tx.v
│   └── tb_ws2812_tx.v
├── sim/
│   └── Makefile
└── docs/
    ├── protocol.md
    ├── waveform_notes.md
    └── debug_log.md
```

生成文件不要提交：

```text
*.vcd
*.fst
*.vvp
*.log
obj_dir/
```

## 3. 工具链分类

本 demo 优先使用开源工具。每类工具都需要理解其在成熟商用项目中的对应产品，避免只会运行命令而不知道它在真实 ASIC/FPGA 流程中的位置。

### 3.1 RTL 编辑与代码组织

| 类别 | 开源工具 | 商用/成熟项目常见产品 | 本 demo 用法 |
| --- | --- | --- | --- |
| 编辑器 | VS Code / Vim / Emacs | VS Code + vendor plugins / DVT Eclipse / Sigasi | 编写 Verilog、Markdown、Makefile |
| 代码搜索 | ripgrep / ctags | Source Insight / Understand / IDE indexer | 查找 module、signal、state |
| 版本管理 | Git | Git / Perforce | 记录每次 RTL/testbench/笔记变更 |

### 3.2 RTL 编译与仿真

| 类别 | 开源工具 | 商用/成熟项目常见产品 | 本 demo 用法 |
| --- | --- | --- | --- |
| Verilog 仿真 | Icarus Verilog | Synopsys VCS / Siemens QuestaSim / Cadence Xcelium | 第一阶段主 simulator |
| SystemVerilog/高性能仿真 | Verilator | VCS / QuestaSim / Xcelium | 后续 lint、快速仿真、C++ model |
| Python testbench | cocotb | UVM + commercial simulator | 后续扩展 self-checking testbench |

第一阶段默认使用：

```bash
iverilog -g2012
vvp
```

如果本机没有安装工具，先在文档中记录缺失命令和安装建议，不要把工具二进制或构建产物提交到仓库。

### 3.3 波形生成与观察

| 类别 | 开源工具 | 商用/成熟项目常见产品 | 本 demo 用法 |
| --- | --- | --- | --- |
| 波形格式 | VCD / FST | FSDB / SHM / WLF / VPD | 第一阶段生成 VCD，后续可用 FST |
| 波形查看 | GTKWave | Verdi / SimVision / Questa Visualizer / DVE | 观察 `state/counter/dout` |
| 波形调试 | GTKWave markers/search | Verdi nWave / SimVision debug | 手动定位边沿、计数器边界、FSM 跳转 |

第一阶段波形观察重点：

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

### 3.4 Lint、风格检查与静态分析

| 类别 | 开源工具 | 商用/成熟项目常见产品 | 本 demo 用法 |
| --- | --- | --- | --- |
| RTL lint | Verilator lint / svlint | SpyGlass Lint / Questa Lint / Ascent Lint | 后续检查未驱动、宽度、latch 风险 |
| 格式化 | verible-verilog-format | Verible / vendor style tools | 后续统一风格 |
| 语法/风格规则 | Verible / svlint | SpyGlass / Questa Lint rules | 后续形成最小规则集 |

第一阶段不强制 lint 通过，但出现以下问题要记录：

- 多个 always block 驱动同一寄存器；
- counter 位宽不够；
- 未完整 reset；
- combinational block 默认赋值不完整；
- testbench 误把仿真延迟当作硬件行为。

### 3.5 综合与网表检查

| 类别 | 开源工具 | 商用/成熟项目常见产品 | 本 demo 用法 |
| --- | --- | --- | --- |
| 逻辑综合 | Yosys | Synopsys Design Compiler / Cadence Genus / Siemens Precision | 后续做语法和可综合性 sanity check |
| FPGA 综合 | Yosys + nextpnr | Vivado / Quartus / Libero | 可选，不作为第一阶段必需项 |
| 形式等价/检查 | SymbiYosys | Formality / Conformal | 暂不作为第一阶段目标 |

第一阶段可以暂时不做综合。若后续运行 Yosys，只记录最小命令、结果和关键 warning。

### 3.6 构建与自动化

| 类别 | 开源工具 | 商用/成熟项目常见产品 | 本 demo 用法 |
| --- | --- | --- | --- |
| 构建入口 | Make | Make / Ninja / vendor flow scripts | 固化 `run/wave/clean` |
| 脚本 | shell / Python | Python / Tcl / Perl | 后续生成测试配置或日志摘要 |
| CI | GitHub Actions | Jenkins / GitLab CI / Build farm | 后续可做仿真 smoke test |

Makefile 应保持简单，优先提供：

```text
make run
make wave
make clean
```

## 4. 第一阶段最小验收标准

完成 single-bit demo 时，应至少具备：

- `rtl/ws2812_bit_tx.v`：单 bit transmitter；
- `tb/tb_ws2812_bit_tx.v`：能测试 `0` bit 和 `1` bit；
- `sim/Makefile`：能编译、运行、打开波形；
- `docs/waveform_notes.md`：记录预期波形、实际观察和关键结论；
- README 或笔记中记录本机工具版本，或说明工具缺失。

最小行为标准：

```text
T0H = 3 cycles, T0L = 7 cycles
T1H = 7 cycles, T1L = 3 cycles
```

仿真中应能清楚解释：

- `start` 被哪个时钟沿采样；
- `busy` 从何时拉高、何时拉低；
- `dout` 高电平持续了几个周期；
- `cycle_cnt` 从 0 开始还是从 1 开始；
- FSM 在哪个条件下从 HIGH 转 LOW；
- off-by-one 错误如何在波形里被发现。

## 5. 笔记要求

每次推进都要优先留下可复现记录，而不是只留下最终代码。

推荐笔记格式：

```markdown
# 标题

## 本次目标

## 修改文件

## 运行命令

## 观察信号

## 预期波形

## 实际结果

## 问题与修正

## 下一步
```

对 RTL demo 的结论应尽量对应到：

- 文件路径；
- module 名；
- signal 名；
- FSM state；
- counter 比较条件；
- 仿真命令；
- 波形时间点或周期数。

## 6. 修改原则

- 默认使用中文写说明和笔记。
- RTL 和 testbench 使用 ASCII。
- 优先小步提交：先 single-bit，再 24-bit，再 self-check。
- 不提交 VCD/FST/VVP/log/obj_dir 等生成文件。
- 不把本目录扩展成大型 SoC 工程。
- 修改外部开源 RTL 时必须记录来源、commit、修改原因和 patch 点；当前阶段优先自己写最小 demo，不下载大型项目。

## 7. 和后续学习路线的关系

WS2812 只是入口。它要沉淀的不是 LED 协议本身，而是下面这套通用 RTL debug 方法：

```text
observable waveform symptom
  -> FSM state
  -> counter / register transition
  -> RTL condition
  -> root cause
  -> fix and rerun simulation
```

这套方法后续要迁移到：

- UART TX/RX；
- FIFO full/empty；
- AXI-lite VALID/READY；
- interrupt pending/active；
- CPU pipeline stall/flush/redirect；
- PLD 或 FPGA waveform debug。
