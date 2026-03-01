# CI 测试自动化说明

本文档描述 AxVisor 的 CI 自动化测试脚本体系，覆盖：

- 自动化测试脚本统一入口
- 测试结果分析与报告
- 回归测试用例清单

## 1. 目录结构

- `scripts/ci/run_ci_suite.sh`: 统一测试执行脚本（静态检查 + 运行测试 + 日志落盘）
- `scripts/ci/analyze_ci_results.py`: 日志分析脚本，生成 Markdown 和 JUnit 报告
- `scripts/ci/regression-cases.tsv`: 回归测试 case 清单
- `ci-artifacts/`: CI 运行产物目录（日志、结果、报告）

## 2. 测试流程

CI 任务采用以下固定流程：

1. 执行静态检查（`cargo fmt --check`、`cargo xtask clippy`）
2. 根据场景执行运行时测试：
   - QEMU: `cargo xtask qemu`
   - BOARD: `cargo xtask uboot`
3. 将每一步状态写入 `ci-artifacts/results/results.tsv`
4. 使用分析脚本生成报告：
   - `ci-artifacts/report/summary.md`
   - `ci-artifacts/report/junit.xml`

## 3. 回归测试清单

回归测试用例在 `scripts/ci/regression-cases.tsv` 中维护，按 case 维度记录：

- `case_id`: 回归 case 唯一标识
- `scenario`: `qemu` 或 `board`
- `arch` / `board`: 目标平台信息
- `vmconfigs`: 客户机配置文件
- `vmimage_name`: 镜像名（QEMU 场景）

新增 case 时建议同步更新对应 workflow 的 matrix。

## 4. 本地执行方法

### 4.1 执行单个 QEMU case

```bash
CI_SCENARIO=qemu \
CI_CASE_ID=qemu-aarch64-arceos \
CI_CASE_NAME=ArceOS \
MATRIX_ARCH=aarch64 \
MATRIX_VMCONFIGS=configs/vms/arceos-aarch64-qemu-smp1.toml \
MATRIX_VMIMAGE_NAME=qemu_aarch64_arceos \
bash scripts/ci/run_ci_suite.sh
```

### 4.2 分析结果并生成报告

```bash
python3 scripts/ci/analyze_ci_results.py --artifact-dir ci-artifacts --fail-on-error
```

## 5. 在 GitHub Actions 中的产物

`test-qemu.yml` 与 `test-board.yml` 已接入：

- 自动上传 `ci-artifacts`
- 自动将 `summary.md` 输出到 `GITHUB_STEP_SUMMARY`
- 通过 `analyze_ci_results.py --fail-on-error` 控制任务最终状态

## 6. 可配置项

`run_ci_suite.sh` 支持以下环境变量：

- `CI_ENABLE_STATIC_CHECKS=0|1`：是否执行静态检查（默认 `1`）
- `CI_ENABLE_FMT_CHECK=0|1`：是否执行格式检查（默认 `1`）
- `CI_ENABLE_CLIPPY_CHECK=0|1`：是否执行 clippy 检查（默认 `1`）
- `CI_ALLOW_TEST_WHEN_STATIC_FAIL=0|1`：静态检查失败后是否继续跑运行测试（默认 `0`）
