#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import os
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Row:
    case_id: str
    step_name: str
    status: str
    exit_code: int
    duration_sec: int
    log_file: str


ERROR_HINT_PATTERNS = [
    re.compile(r"panicked at", re.IGNORECASE),
    re.compile(r"\berror\b", re.IGNORECASE),
    re.compile(r"assertion failed", re.IGNORECASE),
    re.compile(r"failed", re.IGNORECASE),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Analyze AxVisor CI results and generate reports.")
    parser.add_argument("--artifact-dir", default="ci-artifacts", help="Artifact root directory")
    parser.add_argument(
        "--fail-on-error",
        action="store_true",
        help="Exit non-zero when any test step fails",
    )
    return parser.parse_args()


def load_rows(result_file: Path) -> list[Row]:
    if not result_file.exists():
        raise FileNotFoundError(f"result file not found: {result_file}")

    rows: list[Row] = []
    with result_file.open("r", encoding="utf-8") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for rec in reader:
            rows.append(
                Row(
                    case_id=rec["case_id"],
                    step_name=rec["step_name"],
                    status=rec["status"],
                    exit_code=int(rec["exit_code"]),
                    duration_sec=int(rec["duration_sec"]),
                    log_file=rec["log_file"],
                )
            )
    return rows


def tail_lines(path: Path, max_lines: int = 40) -> list[str]:
    if not path.exists():
        return ["<log file missing>"]
    content = path.read_text(encoding="utf-8", errors="replace").splitlines()
    return content[-max_lines:]


def collect_hints(log_lines: list[str]) -> list[str]:
    hints: list[str] = []
    for line in log_lines:
        for pat in ERROR_HINT_PATTERNS:
            if pat.search(line):
                hints.append(line.strip())
                break
    dedup = []
    seen = set()
    for item in hints:
        if item not in seen:
            seen.add(item)
            dedup.append(item)
    return dedup[:5]


def write_summary(rows: list[Row], summary_path: Path) -> tuple[int, int, int]:
    total = len(rows)
    passed = sum(1 for r in rows if r.status == "PASS")
    failed = sum(1 for r in rows if r.status == "FAIL")
    skipped = sum(1 for r in rows if r.status == "SKIP")

    lines: list[str] = []
    lines.append("# AxVisor CI 测试报告")
    lines.append("")
    lines.append("## 总览")
    lines.append("")
    lines.append(f"- 总步骤数: **{total}**")
    lines.append(f"- 通过: **{passed}**")
    lines.append(f"- 失败: **{failed}**")
    lines.append(f"- 跳过: **{skipped}**")
    lines.append("")
    lines.append("## 明细")
    lines.append("")
    lines.append("| Case ID | Step | Status | Exit Code | Duration(s) | Log |")
    lines.append("|---|---|---|---:|---:|---|")
    for row in rows:
        lines.append(
            f"| `{row.case_id}` | `{row.step_name}` | {row.status} | {row.exit_code} | "
            f"{row.duration_sec} | `{row.log_file}` |"
        )

    fail_rows = [r for r in rows if r.status == "FAIL"]
    if fail_rows:
        lines.append("")
        lines.append("## 失败分析")
        lines.append("")
        for row in fail_rows:
            log_path = Path(row.log_file)
            tail = tail_lines(log_path, max_lines=40)
            hints = collect_hints(tail)
            lines.append(f"### `{row.case_id}` / `{row.step_name}`")
            lines.append(f"- 日志: `{row.log_file}`")
            if hints:
                lines.append("- 关键线索:")
                for hint in hints:
                    lines.append(f"  - `{hint}`")
            lines.append("")
            lines.append("```text")
            lines.extend(tail)
            lines.append("```")
            lines.append("")

    summary_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return passed, failed, skipped


def write_junit(rows: list[Row], junit_path: Path) -> None:
    tests = len(rows)
    failures = sum(1 for r in rows if r.status == "FAIL")
    skipped = sum(1 for r in rows if r.status == "SKIP")

    suite = ET.Element(
        "testsuite",
        {
            "name": "axvisor-ci",
            "tests": str(tests),
            "failures": str(failures),
            "skipped": str(skipped),
        },
    )

    for row in rows:
        case = ET.SubElement(
            suite,
            "testcase",
            {
                "classname": row.case_id,
                "name": row.step_name,
                "time": str(row.duration_sec),
            },
        )
        if row.status == "FAIL":
            fail = ET.SubElement(case, "failure", {"message": f"exit={row.exit_code}"})
            snippet = "\n".join(tail_lines(Path(row.log_file), max_lines=60))
            fail.text = snippet
        elif row.status == "SKIP":
            ET.SubElement(case, "skipped", {"message": "step skipped"})

        sysout = ET.SubElement(case, "system-out")
        sysout.text = f"log_file={row.log_file}"

    tree = ET.ElementTree(suite)
    ET.indent(tree, space="  ", level=0)
    tree.write(junit_path, encoding="utf-8", xml_declaration=True)


def main() -> int:
    args = parse_args()
    artifact_dir = Path(args.artifact_dir)
    result_file = artifact_dir / "results" / "results.tsv"
    report_dir = artifact_dir / "report"
    report_dir.mkdir(parents=True, exist_ok=True)

    rows = load_rows(result_file)
    if not rows:
        (report_dir / "summary.md").write_text(
            "# AxVisor CI 测试报告\n\n未发现任何可分析的测试步骤。\n",
            encoding="utf-8",
        )
        write_junit(rows, report_dir / "junit.xml")
        return 1 if args.fail_on_error else 0

    _, failed, _ = write_summary(rows, report_dir / "summary.md")
    write_junit(rows, report_dir / "junit.xml")

    analysis_exit = 1 if (args.fail_on_error and failed > 0) else 0
    (report_dir / "analysis_exit_code.txt").write_text(f"{analysis_exit}\n", encoding="utf-8")
    return analysis_exit


if __name__ == "__main__":
    os.umask(0o022)
    raise SystemExit(main())
