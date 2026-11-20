# Training your own cleanup model

LocalFlow's cleanup model is a LoRA fine-tune of [Qwen3 1.7B](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit) trained with [mlx-lm](https://github.com/ml-explore/mlx-lm). You can train one on your own dictations so it learns your vocabulary and formatting habits. Everything runs locally on an Apple Silicon Mac (16 GB of memory or more recommended).

## 1. Set up

```bash
cd bench
python3 -m venv .venv
.venv/bin/pip install mlx-lm huggingface_hub
```

## 2. Build training data

`make_train.py` combines pairs of *raw transcript → final text* with built-in synthetic English and Portuguese examples (self-corrections, lists, emails, numbers…).

If you used Wispr Flow, `extract.py` reads a **copy** of its local database and writes your pairs to `bench/data/`:

```bash
python3 -I extract.py
python3 -I make_train.py          # → train/train.jsonl and train/valid.jsonl
```

Without Wispr history, `make_train.py` still produces the synthetic set. You can add your own pairs in the same chat format.

> [!WARNING]
> `bench/data`, `bench/train`, `bench/out` and `bench/models` contain your personal dictations. They are listed in `.gitignore` — never commit them.

## 3. Train, test and fuse

```bash
.venv/bin/python -m mlx_lm lora -c lora-fast.yaml --model mlx-community/Qwen3-1.7B-4bit --adapter-path adapters/qwen3-1.7b
.venv/bin/python llm.py mlx-community/Qwen3-1.7B-4bit --adapter adapters/qwen3-1.7b     # score on held-out cases
.venv/bin/python -m mlx_lm fuse --model mlx-community/Qwen3-1.7B-4bit --adapter-path adapters/qwen3-1.7b --save-path models/cleaner
```

The prompt format in `make_train.py` must match `Sources/FlowCore/Cleanup.swift`.

## 4. Install

```bash
cd ..
scripts/install.sh bench/models/cleaner
```

`install.sh` copies the model into `~/Library/Application Support/LocalFlow/models/cleaner`, replacing the downloaded one.
