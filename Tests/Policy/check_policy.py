"""Run Tests/Vectors/policy.json through the dext's policy evaluator.

Usage: python3 -I Tests/Policy/check_policy.py   (from the repo root)

Checks the generated table is current, compiles Driver/XLRDriver/Policy.cpp
with the host compiler and Tests/Policy/policy_cli.cpp, and compares each
vector's verdict. check_vectors.py runs the same vectors through the
independent Python reading of SPEC.md; both must pass (ADR 0003
consequence 3).
"""

import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
DRIVER = ROOT / "Driver/XLRDriver"


def main():
    if subprocess.run([sys.executable, "-I", str(ROOT / "Tools/policygen/policygen.py"), "--check"]).returncode:
        return 1
    with tempfile.TemporaryDirectory() as tmp:
        binary = pathlib.Path(tmp) / "policy_cli"
        subprocess.run(["clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror", "-O1", f"-I{DRIVER}",
                        str(DRIVER / "Policy.cpp"), str(ROOT / "Tests/Policy/policy_cli.cpp"), "-o", str(binary)],
                       check=True)
        vectors = json.loads((ROOT / "Tests/Vectors/policy.json").read_text())["vectors"]
        lines = []
        for v in vectors:
            c, d = v["command"], v["device"]
            payload = c["payload"] if "payload" in c else "00" * c["payload_length"]
            trust = " trusted" if v.get("trusted") else ""
            lines.append(f"{c['category']} {c['index']} {d['model']} {' '.join(map(str, d['firmware']))} {payload or '-'}{trust}")
        out = subprocess.run([str(binary)], input="\n".join(lines) + "\n", capture_output=True, text=True,
                             check=True).stdout.split()
    failures = 0
    for v, got in zip(vectors, out):
        expected = "allow" if v["decoded"]["allow"] else v["decoded"]["reason"]
        if got != expected:
            failures += 1
            print(f"FAIL {v['id']}: dext says {got}, vector says {expected}")
    if len(out) != len(vectors):
        print(f"FAIL: {len(out)} answers for {len(vectors)} vectors")
        failures += 1
    print(f"{len(vectors) - failures}/{len(vectors)} policy vectors pass in the dext's evaluator")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
