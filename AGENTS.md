# AGENTS.md

本仓库是一个用于沉淀学习主题、参考代码阅读笔记和工程化理解路径的知识库。当前主要主题包括：

- 数学思想学习；
- LLM 最小推理引擎与 GPU 推理系统理解。

后续工作优先围绕 `ref_llm_learn/` 展开：从 `llama2.c` 等最小参考实现入手，逐步理解 LLM inference runtime 的完整执行路径，并最终映射到 Linux Driver / GPU KMD / GPU Memory Manager / UVM / HMM 视角。

## 通用工作原则

- 默认使用中文进行说明、总结和笔记编写。
- 保持文档为 Markdown，结构清晰，标题层级稳定。
- 优先做代码级别的细化理解，而不是停留在概念介绍。
- 每次分析参考项目时，应尽量从“主路径”出发，再展开局部细节。
- 避免泛泛总结；关键结论应能对应到具体文件、函数、数据结构或执行流程。
- 不要把本仓库改造成大型工程；它首先是学习笔记和参考代码分析仓库。

## 目录约定

- `README.md`：仓库总览、主题入口和长期路线。
- `ref_llm_learn/README.md`：LLM 推理框架学习路线和阶段目标。
- `ref_llm_learn/`：LLM runtime、serving framework、GPU workload 相关笔记。

建议后续在 `ref_llm_learn/` 下逐步增加：

- `notes/`：代码阅读笔记、概念拆解、阶段总结。
- `diagrams/`：调用链、数据流、内存布局等图示源文件或说明。
- `experiments/`：本地运行命令、配置、日志摘录和实验记录。
- `external/` 或 `third_party/`：下载的参考项目源码。

如果下载外部参考项目，优先放在 `ref_llm_learn/external/` 下，并在笔记中记录：

- 项目名；
- 上游仓库地址；
- checkout commit；
- 下载日期；
- 本次分析关注的文件和函数。

不要无说明地修改外部参考项目源码。若为了实验需要修改，应保留 patch 说明或独立记录修改点。

## LLM 推理引擎学习主线

当前优先级：

1. `karpathy/llama2.c`
2. `ggml-org/llama.cpp`
3. `vLLM` / `SGLang`
4. `TensorRT-LLM`
5. GPU KMD / UVM / HMM 映射总结

分析时始终围绕以下主路径：

```text
prompt tokens
  -> embedding
  -> N transformer layers
  -> logits
  -> sampler
  -> next token
```

对 `llama2.c` 的第一阶段分析，重点覆盖：

- tokenizer 输入/输出；
- embedding lookup；
- RMSNorm；
- Q/K/V projection；
- RoPE position encoding；
- attention score；
- KV cache append / reuse；
- FFN / MLP；
- logits；
- sampling。

## 代码阅读输出要求

分析参考项目时，优先形成以下类型输出：

- call graph：从 `main` 或推理入口到 token 生成的主调用链。
- data flow：token、embedding、activation、logits、KV cache 的流动路径。
- memory layout：权重、activation、KV cache、临时 buffer 的组织方式。
- key structs：核心结构体字段含义和生命周期。
- hot loops：最核心循环的位置、输入输出和复杂度。
- driver mapping：从 GPU KMD / Memory Manager 视角解释其压力来源。

推荐笔记格式：

```markdown
# 标题

## 背景

## 本次阅读范围

- 项目：
- commit：
- 关键文件：

## 主路径

## 关键数据结构

## 关键函数

## 内存与性能视角

## GPU Driver / KMD 映射

## 待继续追踪的问题
```

## 下载和运行外部项目

需要下载推荐项目时，先确认当前仓库已有说明，再按最小必要范围执行：

- 优先 clone 官方上游仓库，不使用不明来源镜像。
- clone 后记录 commit，不只记录分支名。
- 若网络、权限或依赖安装受限，应明确说明阻塞点和可复现命令。
- 不要提交大型模型权重、构建产物、日志目录或临时二进制。
- 模型文件、编译产物和大日志应加入 `.gitignore` 或放在不纳入版本控制的位置。

如需运行实验，优先选择小模型和最短路径，目标是理解 runtime，而不是追求 benchmark 分数。

## 修改原则

- 对已有 Markdown 做增量修改，避免一次性重写大量内容。
- 新增笔记时文件名使用小写英文、短横线分隔，例如 `llama2c-forward-pass.md`。
- 引用本地文件时使用相对路径，例如 `ref_llm_learn/README.md`。
- 如果涉及外部代码分析，结论应尽量附带文件路径和函数名。
- 不主动执行破坏性命令，例如删除目录、重置 git 状态或清理用户文件。

## 验证方式

文档类修改通常不需要运行测试。若修改或实验涉及外部项目代码，应根据该项目自身说明运行最小验证命令，并在笔记中记录：

- 命令；
- 环境；
- 成功或失败结果；
- 失败时的关键错误信息。

## 长期目标

本仓库的 LLM 推理引擎学习不是为了单纯使用 AI 应用，而是为了建立以下理解链路：

```text
最小 LLM 推理循环
  -> 本地推理 runtime
  -> 服务端高吞吐推理系统
  -> GPU memory / scheduling / residency pressure
  -> GPU KMD / UVM / HMM / driver 设计问题
```

所有分析应服务于这条主线。
