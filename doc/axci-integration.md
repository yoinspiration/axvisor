# AxVisor 与 axci 的集成说明

本文说明本仓库如何通过 [axci](https://github.com/yoinspiration/axci)（集中式 CI 测试框架）接入自动化测试，以及仓库内相关配置文件的作用。

## 架构概览

AxVisor **不在本仓库内实现完整测试流水线**，而是通过 GitHub Actions 的 **[可复用工作流（reusable workflow）](https://docs.github.com/en/actions/using-workflows/reusing-workflows)** 调用 axci 仓库里维护的 `test.yml`。这样做的效果是：

- 测试步骤、镜像拉取、QEMU 执行等逻辑在 axci 中统一演进，多个项目共用同一套行为。
- AxVisor 只需声明**触发条件**、**传入参数**，以及提供**按变更选测目标**的规则文件。

```
┌─────────────────────┐     uses      ┌──────────────────────────────┐
│  axvisor 仓库        │ ────────────► │  yoinspiration/axci          │
│  .github/workflows/ │               │  .github/workflows/test.yml │
│  test.yml           │               │  （实际构建与测试）           │
└─────────────────────┘               └──────────────────────────────┘
         │                                        │
         │  with: axvisor_repo, axvisor_ref …     │
         └────────────────────────────────────────┘
```

## GitHub Actions 入口

入口文件：[`.github/workflows/test.yml`](../.github/workflows/test.yml)。

### 触发方式

| 事件 | 说明 |
|------|------|
| `push` | 推送到 `master` 分支（忽略 tag 推送） |
| `pull_request` | 针对默认分支的 PR |
| `workflow_dispatch` | 在 Actions 界面手动运行，可覆盖 `test_targets`、`base_ref`、`runs_on` |

### 与 axci 的衔接

`jobs.test` 使用：

```yaml
uses: yoinspiration/axci/.github/workflows/test.yml@<branch>
```

当前使用的 axci 分支与 `with.axci_ref` 中声明的引用应保持一致（例如 `test/auto-target-regression`）。**升级 axci 版本时**，需同时修改 `uses` 中的 `@ref` 与 `axci_ref` 参数。

### 传入 axci 的主要参数

| 参数 | 含义 |
|------|------|
| `crate_name` | 固定为 `axvisor`，标识被测 crate 名称。 |
| `test_targets` | 测试目标：`auto`（按变更选测）、`all`、或逗号分隔的 target key 等；手动运行时可改。 |
| `base_ref` | 在 `auto` 模式下与基线 ref 做 diff，用于决定跑哪些 target；PR/push 时由表达式自动推导或使用 `origin/master`。 |
| `runs_on` | Runner 标签的 JSON 数组；默认使用带 `self-hosted`、`Linux`、`X64`、`intel` 等标签的机器。 |
| `axvisor_repo` | 被测 AxVisor 仓库的 `owner/name`（如 `yoinspiration/axvisor`）。**fork 或自建 CI 时**需改为你的仓库。 |
| `axvisor_ref` | 当前要测的 Git 引用，一般为 `github.ref_name`（分支名或 tag 名）。 |

具体参数语义与 axci 内部实现以 axci 仓库文档为准。

## 测试目标选择规则

文件：[`.github/axci-test-target-rules.json`](../.github/axci-test-target-rules.json)。

在 `test_targets=auto` 时，axci 会结合 **git diff** 与 **Cargo 依赖** 等信息，依据该 JSON 决定本次流水线要跑哪些**测试 target**（例如 `axvisor-qemu-aarch64-arceos` 等），以在覆盖面与耗时之间取得平衡。

规则文件大致包含：

- **`non_code`**：仅文档、图片等变更时，通常不会触发全量编译测试。
- **`run_all_patterns` / `run_all_exclude_patterns`**：匹配到这些路径时，倾向于跑更广或全量（例如根 `Cargo.toml`、`xtask/*`、HAL 相关路径等）。
- **`selection_rules`**：按路径 glob 映射到一组 target。
- **`crate_rules` / `crate_path_rules`**：当变更涉及某些 workspace crate 时，映射到对应板级/平台 target。

修改目录结构或新增板级 target 时，往往需要**同步更新**该文件，否则 `auto` 可能漏测或过度测试。

## 与 xtask 的约定

`xtask/` 下的变更在规则中常被视为「影响全局」类改动（例如 `run_all_patterns` 包含 `xtask/*`）。在 `xtask/src/main.rs` 中也有注释提示 CI 会按 axci 规则处理 `xtask` 路径变更。

## 本地与 Git 忽略

[`.gitignore`](../.gitignore) 中忽略：

- `test-results/`：本地或 CI 产出的测试结果目录。
- `modules/`：axci 流程中可能检出的依赖模块目录。

请勿将上述目录提交到仓库。

## 维护清单（变更 axci 时）

1. 更新 [`.github/workflows/test.yml`](../.github/workflows/test.yml) 中 `uses` 的 `@ref` 与 `with.axci_ref`。
2. 若 axci 对 `with` 传入项有新增或重命名，按 axci 发布说明同步修改 workflow。
3. 若测试目标命名或路径约定变化，更新 `.github/axci-test-target-rules.json` 并做一次 PR 验证。

## 参考

- axci 仓库：`https://github.com/yoinspiration/axci`
- GitHub Actions 可复用工作流：见上文官方文档链接。
