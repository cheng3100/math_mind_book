# llama2.c 学习计划：按 README Step 1 主题重整

## 0. 本文定位

本文严格围绕 `ref_llm_learn/README.md` 中 Step 1: `llama2.c` 的要求整理。

Step 1 的目标不是做完整源码注释，也不是做性能优化，而是先建立一个最小但完整的 LLaMA 风格推理闭环理解：

```text
prompt tokens
  -> embedding
  -> N transformer layers
  -> logits
  -> sampler
  -> next token
```

本次阅读对象：

- 项目：`karpathy/llama2.c`
- 本地路径：`ref_llm_learn/external/llama2.c`
- commit：`350e04fe35433e6d2941dce5a1f53308f87058eb`
- 核心文件：`ref_llm_learn/external/llama2.c/run.c`
- 对照文件：
  - `ref_llm_learn/external/llama2.c/model.py`
  - `ref_llm_learn/external/llama2.c/export.py`

## 1. README 给出的三个目标

### 目标 1：理解最小 LLaMA 风格推理循环

`llama2.c` 的价值在于：它把一次 LLM inference 简化成一个 C 文件中的明确循环。

最外层生成循环在 `run.c` 的 `generate()` 中：

```text
encode prompt
  -> token = first prompt token
  -> for pos in sequence:
       logits = forward(token, pos)
       next = prompt token or sample(logits)
       decode and print next
       token = next
```

这说明 autoregressive LLM 的基本形式是：

```text
已知前面的 tokens，预测下一个 token；
把预测出的 token 接回输入，再预测下一个。
```

`llama2.c` 每次 `forward()` 只处理一个当前位置的 token；历史 token 的信息不重新计算，而是依赖 KV cache 保存。

### 目标 2：看清楚一个 token 如何生成下一个 token

一个 token 生成下一个 token 的最短路径是：

```text
当前 token id
  -> embedding lookup 得到 x
  -> 经过每一层 Transformer 更新 x
  -> final RMSNorm
  -> classifier projection 得到 logits
  -> sampler 从 logits 中选出 next token id
```

其中 `x` 是贯穿所有层的 residual stream。每一层都做两次残差更新：

```text
x = x + Attention(RMSNorm(x))
x = x + FFN(RMSNorm(x))
```

对应 `run.c` 的核心函数是：

- `generate()`：负责 token 循环和采样控制。
- `forward()`：负责一次 token 的 Transformer 推理。
- `sample()`：负责从 logits 中选择下一个 token。

### 目标 3：把 Transformer 图中的模块对应到 C 数组和循环

Transformer 图中的模块在 `llama2.c` 中不是框架算子，而是 C 数组、指针偏移和 for 循环。

核心对应关系：

| Transformer 模块 | C 代码实体 | 作用 |
| --- | --- | --- |
| 模型配置 | `Config` | 保存 `dim/n_layers/n_heads/n_kv_heads/vocab_size/seq_len` |
| 模型权重 | `TransformerWeights` | 指向 mmap 后 checkpoint 中的权重矩阵 |
| 中间激活 | `RunState` | 保存 `x/xb/q/att/logits/KV cache` 等运行时 buffer |
| Embedding | `token_embedding_table` | token id 到 hidden vector |
| Attention norm | `rms_att_weight` + `rmsnorm()` | attention 前归一化 |
| Q/K/V projection | `wq/wk/wv` + `matmul()` | 生成 query/key/value |
| Attention score | `q dot k` loop | 计算当前位置对历史位置的关注分数 |
| RoPE | Q/K 二维旋转 loop | 给 Q/K 注入位置信息 |
| KV cache | `key_cache/value_cache` | 复用历史 token 的 K/V |
| FFN/MLP | `w1/w2/w3` + SwiGLU loop | token-wise 非线性变换 |
| Logits | `wcls` + `matmul()` | hidden vector 到 vocab 分数 |
| Sampling | `sample()` | logits 到 next token |

下面按 README 中给出的 9 个重点逐项分析。

## 2. 九个重点主题

## 2.1 Tokenizer 输入/输出

### 要解决的问题

模型不能直接处理字符串。Tokenizer 负责在：

```text
text string <-> token ids
```

之间转换。

### C 代码入口

`generate()` 中：

```c
int* prompt_tokens = malloc((strlen(prompt)+3) * sizeof(int));
encode(tokenizer, prompt, 1, 0, prompt_tokens, &num_prompt_tokens);
```

这里：

- 输入是用户 prompt 字符串。
- 输出是 `prompt_tokens[]` 整数数组。
- `bos=1` 表示在开头加入 BOS token。
- `eos=0` 表示 generate 模式下不强制追加 EOS。

### 在推理循环中的作用

`generate()` 的循环逻辑是：

```c
int token = prompt_tokens[0];
int pos = 0;
while (pos < steps) {
    float* logits = forward(transformer, token, pos);

    if (pos < num_prompt_tokens - 1) {
        next = prompt_tokens[pos + 1];
    } else {
        next = sample(sampler, logits);
    }

    token = next;
    pos++;
}
```

关键理解：

- prompt 阶段：`next` 被强制设为 prompt 中的下一个 token，不采样。
- 生成阶段：prompt 消耗完后，才从 `logits` 中采样。
- `forward()` 每次只看当前 `token` 和当前位置 `pos`。

### 数据流

```text
prompt string
  -> encode()
  -> prompt_tokens[]
  -> token scalar
  -> forward(token, pos)
```

## 2.2 Embedding lookup

### 要解决的问题

token id 是离散整数，不能直接参与矩阵计算。Embedding lookup 把 token id 转成 `dim` 维浮点向量。

### C 代码对应

`forward()` 开头：

```c
float* content_row = w->token_embedding_table + token * dim;
memcpy(x, content_row, dim*sizeof(*x));
```

对应 PyTorch：

```python
h = self.tok_embeddings(tokens)
```

### 数组含义

`token_embedding_table` 形状：

```text
(vocab_size, dim)
```

`token * dim` 表示取第 `token` 行。

输出写入：

```text
s->x: (dim,)
```

`x` 是当前 token 的 residual stream，后面每一层都会在它上面做 residual add。

### 数据流

```text
token id
  -> token_embedding_table[token]
  -> x(dim)
```

## 2.3 RMSNorm

### 要解决的问题

在 attention 和 FFN 前，对当前 hidden state 做归一化，让数值尺度更稳定。

LLaMA 使用 RMSNorm，而不是 LayerNorm。

### C 代码实现

```c
void rmsnorm(float* o, float* x, float* weight, int size) {
    float ss = 0.0f;
    for (int j = 0; j < size; j++) {
        ss += x[j] * x[j];
    }
    ss /= size;
    ss += 1e-5f;
    ss = 1.0f / sqrtf(ss);
    for (int j = 0; j < size; j++) {
        o[j] = weight[j] * (ss * x[j]);
    }
}
```

计算公式：

```text
o[j] = weight[j] * x[j] / sqrt(mean(x^2) + eps)
```

### 在每层中的两个位置

Attention 前：

```c
rmsnorm(s->xb, x, w->rms_att_weight + l*dim, dim);
```

FFN 前：

```c
rmsnorm(s->xb, x, w->rms_ffn_weight + l*dim, dim);
```

对应 PyTorch：

```python
h = x + self.attention.forward(self.attention_norm(x), freqs_cos, freqs_sin)
out = h + self.feed_forward.forward(self.ffn_norm(h))
```

### 数据流

```text
x(dim)
  -> rmsnorm
  -> xb(dim)
```

注意：`xb` 是归一化后的分支输入，`x` 保留为 residual stream。

## 2.4 Q/K/V projection

### 要解决的问题

Attention 需要回答两个问题：

```text
当前 token 应该关注历史上的哪些 token？
关注后应该取回哪些信息？
```

Q/K/V 的分工：

- `Q`：Query，当前 token 发出的查询。
- `K`：Key，历史 token 提供的匹配索引。
- `V`：Value，历史 token 提供的内容信息。

一句话理解：

```text
Q 和 K 决定关注权重，V 决定被加权汇总的内容。
```

### C 代码对应

`forward()` 中：

```c
matmul(s->q, s->xb, w->wq + l*dim*dim, dim, dim);
matmul(s->k, s->xb, w->wk + l*dim*kv_dim, dim, kv_dim);
matmul(s->v, s->xb, w->wv + l*dim*kv_dim, dim, kv_dim);
```

其中 `matmul()` 的语义是：

```c
void matmul(float* xout, float* x, float* w, int n, int d)
```

计算：

```text
W(d, n) @ x(n) -> xout(d)
```

所以三组 projection 是：

| Projection | 输入 | 权重 | 输出 | 代码 |
| --- | --- | --- | --- | --- |
| Q | `xb(dim)` | `wq(dim, dim)` | `q(dim)` | `matmul(s->q, s->xb, wq, dim, dim)` |
| K | `xb(dim)` | `wk(kv_dim, dim)` | `k(kv_dim)` | `matmul(s->k, s->xb, wk, dim, kv_dim)` |
| V | `xb(dim)` | `wv(kv_dim, dim)` | `v(kv_dim)` | `matmul(s->v, s->xb, wv, dim, kv_dim)` |

### 和 PyTorch 的对应

`model.py`：

```python
xq, xk, xv = self.wq(x), self.wk(x), self.wv(x)
```

`export.py` 中权重写出顺序：

```python
serialize_fp32(out_file, layer.attention.wq.weight)
serialize_fp32(out_file, layer.attention.wk.weight)
serialize_fp32(out_file, layer.attention.wv.weight)
```

`run.c` 中权重读取顺序：

```c
w->wq = ptr;
w->wk = ptr;
w->wv = ptr;
```

所以：

```text
model.py layer.attention.wq.weight -> run.c TransformerWeights.wq
model.py layer.attention.wk.weight -> run.c TransformerWeights.wk
model.py layer.attention.wv.weight -> run.c TransformerWeights.wv
```

### `dim/head_size/kv_dim` 的关系

`forward()` 中：

```c
int head_size = dim / p->n_heads;
int kv_dim = (p->dim * p->n_kv_heads) / p->n_heads;
int kv_mul = p->n_heads / p->n_kv_heads;
```

等价于：

```text
head_size = dim / n_heads
kv_dim    = n_kv_heads * head_size
kv_mul    = n_heads / n_kv_heads
```

这说明：

- Q 有 `n_heads` 个 head，总维度是 `dim`。
- K/V 有 `n_kv_heads` 个 head，总维度是 `kv_dim`。
- 当 `n_kv_heads < n_heads` 时，多个 Q heads 共享一个 K/V head。

### grouped-query / multi-query 在 C 中如何体现

Attention 中读取 K/V 的地址：

```c
float* k = s->key_cache + loff + t * kv_dim + (h / kv_mul) * head_size;
float* v = s->value_cache + loff + t * kv_dim + (h / kv_mul) * head_size;
```

其中：

```text
h = query head id
h / kv_mul = 对应的 kv head id
```

例子：

```text
n_heads = 8
n_kv_heads = 2
kv_mul = 4
query heads 0,1,2,3 -> kv head 0
query heads 4,5,6,7 -> kv head 1
```

PyTorch 中对应逻辑是：

```python
xk = repeat_kv(xk, self.n_rep)
xv = repeat_kv(xv, self.n_rep)
```

区别是：

- PyTorch 版本显式 repeat K/V。
- C 版本不复制，通过 `(h / kv_mul)` 做索引映射。

## 2.5 Attention score

### 要解决的问题

有了 Q/K/V 后，需要计算当前 token 对历史每个 token 的关注程度。

### C 代码对应

```c
for (h = 0; h < p->n_heads; h++) {
    float* q = s->q + h * head_size;
    float* att = s->att + h * p->seq_len;

    for (int t = 0; t <= pos; t++) {
        float* k = s->key_cache + loff + t * kv_dim + (h / kv_mul) * head_size;
        float score = 0.0f;
        for (int i = 0; i < head_size; i++) {
            score += q[i] * k[i];
        }
        score /= sqrtf(head_size);
        att[t] = score;
    }

    softmax(att, pos + 1);
}
```

### 数学含义

对当前 head：

```text
score[t] = dot(q_current, k_t) / sqrt(head_size)
att = softmax(score[0..pos])
```

为什么只到 `pos`？

```c
for (int t = 0; t <= pos; t++)
```

这是 causal attention：当前位置只能看自己和过去，不能看未来。

### 数据流

```text
q_current(head_size)
key_cache[layer][0..pos](head_size)
  -> dot product
  -> score[0..pos]
  -> softmax
  -> att[0..pos]
```

## 2.6 RoPE position encoding

### 要解决的问题

Transformer attention 本身只看 token 内容相似度，不天然知道 token 的绝对/相对位置。RoPE 通过旋转 Q/K，把位置信息注入 attention score。

### C 代码对应

```c
for (int i = 0; i < dim; i+=2) {
    int head_dim = i % head_size;
    float freq = 1.0f / powf(10000.0f, head_dim / (float)head_size);
    float val = pos * freq;
    float fcr = cosf(val);
    float fci = sinf(val);
    int rotn = i < kv_dim ? 2 : 1;
    for (int v = 0; v < rotn; v++) {
        float* vec = v == 0 ? s->q : s->k;
        float v0 = vec[i];
        float v1 = vec[i+1];
        vec[i]   = v0 * fcr - v1 * fci;
        vec[i+1] = v0 * fci + v1 * fcr;
    }
}
```

### 为什么旋转 Q/K，不旋转 V

Attention 权重由 `dot(q, k)` 决定，所以位置信息需要进入 Q/K。

V 是被加权取回的内容，不参与相似度匹配，因此不需要 RoPE。

### `rotn` 的含义

```c
int rotn = i < kv_dim ? 2 : 1;
```

- `i < kv_dim`：Q 和 K 都有这个维度，所以 Q/K 都旋转。
- `i >= kv_dim`：只有 Q 有这个维度，所以只旋转 Q。

这是因为：

```text
Q 总维度 = dim
K 总维度 = kv_dim
```

当 `n_kv_heads < n_heads` 时，`kv_dim < dim`。

### 位置关系

RoPE 在代码中位于：

```text
Q/K/V projection 之后
attention score 之前
```

也就是：

```text
xb -> q/k/v -> RoPE(q,k) -> q dot k
```

## 2.7 KV cache append / reuse

### 要解决的问题

自回归生成时，每一步都会新增一个 token。如果每一步都重新计算所有历史 token 的 K/V，成本会很高。

KV cache 的作用是：

```text
历史 token 的 K/V 只算一次，后续重复读取。
```

### C 代码对应：append

每层开始时：

```c
int loff = l * p->seq_len * kv_dim;
s->k = s->key_cache + loff + pos * kv_dim;
s->v = s->value_cache + loff + pos * kv_dim;
```

随后：

```c
matmul(s->k, s->xb, w->wk + l*dim*kv_dim, dim, kv_dim);
matmul(s->v, s->xb, w->wv + l*dim*kv_dim, dim, kv_dim);
```

注意这里 `s->k` 和 `s->v` 不是普通临时数组，而是直接指向 KV cache 中当前位置：

```text
key_cache[layer][pos]
value_cache[layer][pos]
```

这就是 append。

### C 代码对应：reuse

Attention score 读取历史 K：

```c
float* k = s->key_cache + loff + t * kv_dim + (h / kv_mul) * head_size;
```

Value 加权求和读取历史 V：

```c
float* v = s->value_cache + loff + t * kv_dim + (h / kv_mul) * head_size;
```

其中 `t = 0..pos`，表示从历史 cache 中读所有可见 token。

### KV cache 一维布局

逻辑形状：

```text
key_cache:   (n_layers, seq_len, kv_dim)
value_cache: (n_layers, seq_len, kv_dim)
```

一维地址：

```text
base
  + layer * seq_len * kv_dim
  + pos * kv_dim
  + kv_head * head_size
  + i
```

### 和后续 serving 框架的关系

`llama2.c` 使用单请求、连续、预分配 KV cache。

这足够理解基本原理，但还没有处理：

- 多请求并发；
- 请求长度不同；
- KV cache block 分配；
- cache 复用和释放；
- 显存碎片；
- continuous batching。

这些正是后续 vLLM/SGLang 的核心问题。

## 2.8 FFN / MLP

### 要解决的问题

Attention 负责 token 之间的信息交互；FFN/MLP 负责对每个 token 的 hidden state 做非线性变换。

LLaMA 使用 SwiGLU 风格 FFN：

```text
w2(silu(w1(x)) * w3(x))
```

### C 代码对应

FFN 前归一化：

```c
rmsnorm(s->xb, x, w->rms_ffn_weight + l*dim, dim);
```

两条 hidden projection：

```c
matmul(s->hb, s->xb, w->w1 + l*dim*hidden_dim, dim, hidden_dim);
matmul(s->hb2, s->xb, w->w3 + l*dim*hidden_dim, dim, hidden_dim);
```

SwiGLU：

```c
for (int i = 0; i < hidden_dim; i++) {
    float val = s->hb[i];
    val *= (1.0f / (1.0f + expf(-val)));
    val *= s->hb2[i];
    s->hb[i] = val;
}
```

Down projection：

```c
matmul(s->xb, s->hb, w->w2 + l*dim*hidden_dim, hidden_dim, dim);
```

Residual add：

```c
x[i] += s->xb[i];
```

### 和 PyTorch 的对应

`model.py`：

```python
return self.dropout(self.w2(F.silu(self.w1(x)) * self.w3(x)))
```

映射关系：

| C | PyTorch | 形状 | 含义 |
| --- | --- | --- | --- |
| `w1` | `feed_forward.w1.weight` | `(hidden_dim, dim)` | gate projection |
| `w3` | `feed_forward.w3.weight` | `(hidden_dim, dim)` | up projection |
| `w2` | `feed_forward.w2.weight` | `(dim, hidden_dim)` | down projection |
| `hb` | `silu(w1(x)) * w3(x)` | `(hidden_dim,)` | FFN hidden 激活 |

### 数据流

```text
x(dim)
  -> RMSNorm
  -> xb(dim)
  -> w1 -> hb(hidden_dim)
  -> w3 -> hb2(hidden_dim)
  -> silu(hb) * hb2
  -> w2 -> xb(dim)
  -> x += xb
```

## 2.9 Logits 和 sampling

### 要解决的问题

Transformer 最终输出的是一个 hidden vector，还不是 token。需要把 hidden vector 映射到整个词表上的分数，然后选择下一个 token。

### Logits C 代码对应

所有层结束后：

```c
rmsnorm(x, x, w->rms_final_weight, dim);
matmul(s->logits, x, w->wcls, p->dim, p->vocab_size);
return s->logits;
```

含义：

```text
x(dim)
  -> final RMSNorm
  -> classifier projection
  -> logits(vocab_size)
```

`wcls` 对应 PyTorch：

```python
self.output = nn.Linear(params.dim, params.vocab_size, bias=False)
```

如果使用 weight tying：

```c
w->wcls = shared_weights ? w->token_embedding_table : ptr;
```

即输出分类权重和输入 embedding 表共享。

### Sampling C 代码对应

`generate()` 中：

```c
next = sample(sampler, logits);
```

`sample()` 中有三种路径：

```text
temperature == 0
  -> greedy argmax

topp <= 0 or topp >= 1
  -> softmax 后按全分布采样

0 < topp < 1
  -> top-p / nucleus sampling
```

采样前如果 temperature 非 0：

```c
for (int q=0; q<sampler->vocab_size; q++) {
    logits[q] /= sampler->temperature;
}
softmax(logits, sampler->vocab_size);
```

### 数据流

```text
x(dim)
  -> logits(vocab_size)
  -> probability distribution
  -> next token id
```

## 3. 九个主题串成一条主路径

把上面 9 个重点连起来，一次 token 推理是：

```text
1. tokenizer 输入/输出
   prompt string -> prompt_tokens[] -> current token

2. embedding lookup
   token -> x(dim)

3. RMSNorm
   x -> xb，作为 attention 输入

4. Q/K/V projection
   xb -> q/k/v

5. RoPE position encoding
   q/k 注入当前位置 pos

6. KV cache append / reuse
   当前 k/v 写入 cache；历史 k/v 从 cache 读取

7. attention score
   q dot historical k -> softmax -> attention weights

8. FFN / MLP
   attention residual 后，对 x 做 SwiGLU MLP residual

9. logits 和 sampling
   final x -> logits -> next token
```

更接近代码执行顺序的版本是：

```text
prompt tokens
  -> token
  -> embedding lookup
  -> for each layer:
       RMSNorm
       Q/K/V projection
       RoPE position encoding
       KV cache append
       attention score over cached K
       weighted sum over cached V
       attention output projection + residual
       RMSNorm
       FFN / MLP + residual
  -> final RMSNorm
  -> logits
  -> sampler
  -> next token
```

## 4. 最小代码地图

阅读 `run.c` 时，可以按下面顺序定位，不要从文件头到尾泛读。

| 阅读目标 | 函数/结构 | 重点 |
| --- | --- | --- |
| 模型尺寸 | `Config` | `dim/n_heads/n_kv_heads/seq_len` |
| 权重布局 | `TransformerWeights`, `memory_map_weights()` | checkpoint 如何映射到权重指针 |
| 运行时状态 | `RunState`, `malloc_run_state()` | activation 和 KV cache 分配 |
| 主生成循环 | `generate()` | prompt 阶段与生成阶段区别 |
| 单 token 推理 | `forward()` | Transformer 主路径 |
| 归一化 | `rmsnorm()` | RMSNorm 公式 |
| 矩阵乘 | `matmul()` | 所有 projection 的基础 |
| 采样 | `sample()` | logits 到 next token |

## 5. 与 GPU Driver / KMD 视角的连接

虽然 `llama2.c` 是 CPU 教学实现，但它已经暴露了后续 GPU 推理系统中的核心压力来源。

| llama2.c 主题 | GPU/KMD 视角 |
| --- | --- |
| embedding/weights | 大块只读权重加载、映射、residency |
| Q/K/V projection | 高频 GEMM，权重带宽和 kernel launch 问题 |
| attention score | 随 context 增长读取历史 K，带宽压力增加 |
| KV cache | 长生命周期动态显存，容量、碎片、分页管理压力 |
| FFN/MLP | 大量 GEMM/Tensor Core 计算，算力主力部分 |
| logits/sampling | 可能引入 CPU/GPU 同步和小算子开销 |
| autoregressive loop | decode 阶段逐 token 串行依赖，低 latency 要求高 |

后续看 `llama.cpp`、vLLM、SGLang 时，应持续追问：

```text
llama2.c 中这个简单数组/循环，在真实 GPU runtime 中变成了什么？
```

例如：

- `matmul()` 会变成 backend GEMM kernel。
- 连续 KV cache 会变成 paged/block KV cache。
- 单请求循环会变成 continuous batching scheduler。
- 简单 malloc/calloc 会变成 GPU memory pool / allocator / residency 管理。

## 6. 下一步学习任务

围绕 Step 1，建议继续补三份更小的笔记：

1. `llama2c-forward-callgraph.md`：只画 `generate()` 到 `forward()` 的调用链。
2. `llama2c-qkv-kvcache.md`：只分析 Q/K/V projection 和 KV cache 地址计算。
3. `llama2c-shapes.md`：代入一个具体模型配置，手算每个 buffer 的 shape 和大小。

完成这三份后，再进入 `llama.cpp`，否则容易被 GGUF、backend、quantization、GPU offload 等工程复杂度淹没。
