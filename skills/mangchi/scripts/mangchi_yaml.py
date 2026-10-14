#!/usr/bin/env python3
"""mangchi_yaml.py -- deterministic helpers for scripts/codex-run.sh (mangchi, schema_version 1).

The model never eyeballs a Codex answer or re-types a rubric: codex-run.sh calls this file to
cut prompt sections out of axes.md, to build the verify context, and to validate the YAML.
Schema rules = SKILL.md Phase 3 / Phase 6 and axes.md "공통 출력 포맷".

Subcommands (exit 0 = ok, 1 = invalid input, 2 = usage, 3 = section missing):
  section <axes.md> axis <name> | review-format | verify-format
  check-issues <issues-file> <review-json>
  verify-context <issues-file> <updated-file>
  field <json-file> <dotted.key>
  result --kind review|verify --answer F --axis A [--issues F] --status S --json-out F ...
         validates the answer when status is ok, writes the result JSON, prints the summary
Created by: Minwoo Park
"""
import argparse
import json
import re
import sys

# Text out exactly as built: UTF-8, LF only (Windows would otherwise write cp949/CRLF).
sys.stdout.reconfigure(encoding="utf-8", newline="\n")
sys.stderr.reconfigure(encoding="utf-8", newline="\n")

VALID_AXES = ("correctness", "security", "readability", "performance", "design",
              "necessity", "robustness")
LEVELS = ("HIGH", "MEDIUM", "LOW")
LOCUS_RE = re.compile(r":\d+")
LINES_RE = re.compile(r":(\d+)(?:\s*-\s*(\d+))?")
RANGE_RE = re.compile(r"^\s*(\d+)(?:\s*-\s*(\d+))?\s*$")
# Phase 6: DISAGREE must cite post-edit code as file:line.
FILE_LINE_RE = re.compile(r"[\w./\\-]+:\d+")
# Phase 4: a REJECT cites file:LINE or a test name.
CITATION_RE = re.compile(r"[\w./\\-]+:\d+|::|\btest_\w+")
FENCE_RE = re.compile(r"^```[ \t]*(?:ya?ml)?[ \t]*\r?\n(.*?)^```[ \t]*$", re.M | re.S)
CONTEXT = 10


class Invalid(Exception):
    def __init__(self, code, msg):
        super().__init__(msg)
        self.code = code
        self.msg = msg


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def yaml_mod():
    try:
        import yaml
    except ImportError:
        sys.stderr.write("PyYAML missing: python -m pip install pyyaml\n")
        sys.exit(2)
    return yaml


# ---------------------------------------------------------------- axes.md sections

def section(text, kind, name=None):
    lines = text.splitlines()
    if kind == "axis":
        head = "## Axis: `%s`" % name
        start = next((i for i, l in enumerate(lines)
                      if l == head or l.startswith(head + " ")), None)
        if start is None:
            return None
        end = next((j for j in range(start + 1, len(lines))
                    if lines[j].startswith("## ") or lines[j].strip() == "---"), len(lines))
        return "\n".join(lines[start:end]).rstrip() + "\n"
    h2 = next((i for i, l in enumerate(lines) if l.startswith("## 공통 출력 포맷")), None)
    if h2 is None:
        return None
    end2 = next((j for j in range(h2 + 1, len(lines)) if lines[j].startswith("## ")), len(lines))
    block = lines[h2:end2]
    subs = [i for i, l in enumerate(block) if l.startswith("### ")]
    intro = block[:subs[0] if subs else len(block)]

    def sub(prefix):
        i = next((k for k in subs if block[k].startswith(prefix)), None)
        if i is None:
            return None
        nxt = next((k for k in subs if k > i), len(block))
        return block[i:nxt]

    if kind == "review-format":
        rules = sub("### 제약")
        if rules is None or not any(l.startswith("```yaml") for l in intro):
            return None
        return "\n".join(intro + rules).rstrip() + "\n"
    if kind == "verify-format":
        v = sub("### Verify 호출")
        if v is None or not any(l.startswith("```yaml") for l in v):
            return None
        return "\n".join(v).rstrip() + "\n"
    return None


# ---------------------------------------------------------------- validation

def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def text_field(v):
    """Non-empty string, or a non-empty mapping/list (before/after snippets) rendered as YAML."""
    if isinstance(v, str) and v.strip():
        return v
    if isinstance(v, (dict, list)) and v:
        return yaml_mod().safe_dump(v, allow_unicode=True, sort_keys=False).strip()
    return None


def extract(text):
    """The last fenced YAML block that parses to a mapping; the whole text as a fallback."""
    yaml = yaml_mod()
    last_err = "no YAML mapping found in the answer"
    for c in list(reversed(FENCE_RE.findall(text))) + [text]:
        try:
            data = yaml.safe_load(c)
        except yaml.YAMLError as e:
            last_err = "YAML parse error: %s" % str(e).splitlines()[0]
            continue
        if isinstance(data, dict):
            return data
    raise Invalid("no-yaml", last_err)


def check_axis(data, axis):
    got = data.get("axis")
    if got != axis:
        raise Invalid("axis", "axis must be %r (this call's axis), got %r" % (axis, got))


def validate_review(data, axis):
    check_axis(data, axis)
    warnings = []
    verdict = data.get("verdict")
    if verdict not in ("PASS", "REVISE"):
        raise Invalid("verdict", "verdict must be PASS or REVISE, got %r" % (verdict,))
    ncs = data.get("no_changes_suggested")
    if ncs is not None and not isinstance(ncs, bool):
        raise Invalid("no_changes_suggested", "no_changes_suggested must be true or false")
    issues = data.get("issues")
    if issues is None:
        issues = []
    if not isinstance(issues, list):
        raise Invalid("issues", "issues must be a list")
    if verdict == "REVISE" and not issues:
        raise Invalid("issues", "verdict REVISE needs a non-empty issues list")
    out, seen, highs = [], set(), 0
    for k, it in enumerate(issues, 1):
        p = "issues[%d]" % k
        if not isinstance(it, dict):
            raise Invalid(p, "%s must be a mapping" % p)
        if not is_int(it.get("id")):
            raise Invalid(p + ".id", "%s.id must be an integer" % p)
        if it["id"] in seen:
            raise Invalid(p + ".id", "duplicate issue id %d (ids are unique within a round)" % it["id"])
        seen.add(it["id"])
        if it.get("severity") not in LEVELS:
            raise Invalid(p + ".severity", "%s.severity must be HIGH, MEDIUM or LOW" % p)
        loc = it.get("locus")
        if not (isinstance(loc, str) and LOCUS_RE.search(loc)):
            raise Invalid(p + ".locus", '%s.locus must be "file:LINE[-LINE]", got %r' % (p, loc))
        fields = {}
        for f in ("problem", "proposed_fix"):
            fields[f] = text_field(it.get(f))
            if fields[f] is None:
                raise Invalid(p + "." + f, "%s.%s must be non-empty" % (p, f))
        if it.get("confidence") not in LEVELS:
            raise Invalid(p + ".confidence", "%s.confidence must be HIGH, MEDIUM or LOW" % p)
        if it["severity"] == "HIGH":
            highs += 1
            if it["confidence"] == "LOW":
                warnings.append("%s: severity HIGH with confidence LOW (axes.md: lower the severity)" % p)
        out.append({"id": it["id"], "severity": it["severity"], "locus": loc,
                    "problem": fields["problem"], "proposed_fix": fields["proposed_fix"],
                    "confidence": it["confidence"]})
    if highs > 3:
        warnings.append("%d HIGH issues (axes.md: at most 3 per round)" % highs)
    if verdict == "PASS" and out:
        warnings.append("verdict PASS with %d issue(s)" % len(out))
    return {"axis": axis, "verdict": verdict, "no_changes_suggested": ncs, "issues": out}, warnings


def validate_verify(data, axis, ids):
    check_axis(data, axis)
    vs = data.get("verifications")
    if not isinstance(vs, list) or not vs:
        raise Invalid("verifications", "verifications must be a non-empty list")
    out, seen = [], set()
    for k, v in enumerate(vs, 1):
        p = "verifications[%d]" % k
        if not isinstance(v, dict):
            raise Invalid(p, "%s must be a mapping" % p)
        iid = v.get("issue_id")
        if not is_int(iid):
            raise Invalid(p + ".issue_id", "%s.issue_id must be an integer" % p)
        if iid not in ids:
            raise Invalid(p + ".issue_id", "issue_id %d was not sent for verification" % iid)
        if iid in seen:
            raise Invalid(p + ".issue_id", "issue_id %d answered twice" % iid)
        seen.add(iid)
        verdict = v.get("verdict")
        if verdict not in ("AGREE", "DISAGREE"):
            raise Invalid(p + ".verdict", "%s.verdict must be AGREE or DISAGREE" % p)
        reason = v.get("reason")
        if reason is not None and not isinstance(reason, str):
            raise Invalid(p + ".reason", "%s.reason must be a string" % p)
        if verdict == "DISAGREE" and not (reason and FILE_LINE_RE.search(reason)):
            raise Invalid(p + ".reason", "DISAGREE on issue %d must cite post-edit code as file:line" % iid)
        out.append({"issue_id": iid, "verdict": verdict, "reason": reason})
    missing = sorted(set(ids) - seen)
    if missing:
        raise Invalid("verifications", "no answer for issue_id(s) %s" % ", ".join(map(str, missing)))
    return {"axis": axis, "verifications": out}, []


def load_issues(path):
    yaml = yaml_mod()
    try:
        data = yaml.safe_load(read(path))
    except yaml.YAMLError as e:
        raise Invalid("issues-file", "issues file is not YAML/JSON: %s" % str(e).splitlines()[0])
    if isinstance(data, dict) and "issues" in data:
        data = data["issues"]
    if not isinstance(data, list) or not data:
        raise Invalid("issues-file", "issues file must hold a non-empty list of REJECTed issues")
    out, seen = [], set()
    for k, it in enumerate(data, 1):
        p = "issue %d" % k
        if not isinstance(it, dict):
            raise Invalid("issues-file", "%s must be a mapping" % p)
        if not is_int(it.get("id")):
            raise Invalid("issues-file", "%s: id must be an integer" % p)
        if it["id"] in seen:
            raise Invalid("issues-file", "duplicate id %d" % it["id"])
        seen.add(it["id"])
        if it.get("decision", "REJECT") != "REJECT":
            raise Invalid("issues-file", "id %d: only REJECTed issues go to verify" % it["id"])
        loc = it.get("locus")
        if not (isinstance(loc, str) and LOCUS_RE.search(loc)):
            raise Invalid("issues-file", 'id %d: locus must be "file:LINE[-LINE]"' % it["id"])
        if text_field(it.get("problem")) is None:
            raise Invalid("issues-file", "id %d: problem is required" % it["id"])
        reason = it.get("reason")
        if not (isinstance(reason, str) and CITATION_RE.search(reason)):
            raise Invalid("issues-file", "id %d: the REJECT reason must cite file:LINE or a test name "
                                         "(Phase 4 hard validation)" % it["id"])
        pel = it.get("post_edit_lines")
        if pel is not None and not RANGE_RE.match(str(pel)):
            raise Invalid("issues-file", 'id %d: post_edit_lines must look like "118" or "118-121"' % it["id"])
        out.append(it)
    return out


def line_range(it):
    pel = it.get("post_edit_lines")
    m = RANGE_RE.match(str(pel)) if pel is not None else LINES_RE.search(it["locus"])
    a = int(m.group(1))
    b = int(m.group(2) or a)
    return (a, b) if a <= b else (b, a)


def verify_context(issues, upd_path):
    lines = read(upd_path).splitlines()
    n = len(lines)
    name = upd_path.replace("\\", "/").rsplit("/", 1)[-1]
    parts = []
    for it in issues:
        a, b = line_range(it)
        lo, hi = max(1, a - CONTEXT), min(n, b + CONTEXT)
        note = ""
        if lo > hi:  # the locus is past the end of the edited file
            lo, hi = max(1, n - 2 * CONTEXT), n
            note = " (locus %d-%d is past the end: %d lines)" % (a, b, n)
        parts.append("### issue_id: %d" % it["id"])
        parts.append("- locus: %s" % it["locus"])
        if it.get("severity"):
            parts.append("- severity: %s" % it["severity"])
        parts.append("- problem: %s" % text_field(it.get("problem")))
        if text_field(it.get("proposed_fix")):
            parts.append("- proposed_fix: %s" % text_field(it.get("proposed_fix")))
        parts.append("- Claude REJECT 근거: %s" % it["reason"])
        parts.append("- post-edit %s %d-%d%s:" % (name, lo, hi, note))
        parts.append("```")
        parts.extend("%5d| %s" % (i, lines[i - 1]) for i in range(lo, hi + 1))
        parts.append("```")
        parts.append("")
    return "\n".join(parts)


# ---------------------------------------------------------------- commands

def cmd_section(argv):
    if len(argv) < 2 or (argv[1] == "axis" and len(argv) < 3):
        sys.exit(2)
    s = section(read(argv[0]), argv[1], argv[2] if len(argv) > 2 else None)
    if s is None:
        what = "'## Axis: `%s`'" % argv[2] if argv[1] == "axis" else argv[1]
        sys.stderr.write("axes.md section missing: %s\n" % what)
        sys.exit(3)
    sys.stdout.write(s)


def cmd_check_issues(argv):
    if len(argv) != 2:
        sys.exit(2)
    try:
        issues = load_issues(argv[0])
        rev = json.loads(read(argv[1]))
    except Invalid as e:
        sys.stderr.write(e.msg + "\n")
        sys.exit(1)
    except (OSError, ValueError) as e:
        sys.stderr.write("cannot read the review result %s: %s\n" % (argv[1], e))
        sys.exit(1)
    if not (rev.get("valid") and rev.get("review")):
        sys.stderr.write("%s holds no valid review (status %s)\n" % (argv[1], rev.get("status")))
        sys.exit(1)
    known = {i["id"] for i in rev["review"]["issues"]}
    extra = sorted(i["id"] for i in issues if i["id"] not in known)
    if extra:
        sys.stderr.write("issue id(s) %s are not in this round's review\n" % ", ".join(map(str, extra)))
        sys.exit(1)


def cmd_verify_context(argv):
    if len(argv) != 2:
        sys.exit(2)
    try:
        sys.stdout.write(verify_context(load_issues(argv[0]), argv[1]))
    except Invalid as e:
        sys.stderr.write(e.msg + "\n")
        sys.exit(1)


def cmd_field(argv):
    if len(argv) != 2:
        sys.exit(2)
    try:
        v = json.loads(read(argv[0]))
        for k in argv[1].split("."):
            v = v[k]
    except (OSError, ValueError, KeyError, TypeError):
        sys.exit(1)
    sys.stdout.write("" if v is None else str(v))


def cmd_result(argv):
    ap = argparse.ArgumentParser(prog="mangchi_yaml.py result")
    for opt in ("--kind", "--answer", "--axis", "--status", "--json-out", "--round", "--attempt"):
        ap.add_argument(opt, required=True)
    for opt in ("--issues", "--model", "--effort", "--sandbox", "--seconds", "--tokens-reported",
                "--tokens-estimate", "--prompt", "--out"):
        ap.add_argument(opt, default="")
    a = ap.parse_args(argv)
    reported = int(a.tokens_reported) if a.tokens_reported.isdigit() else None
    estimate = int(a.tokens_estimate) if a.tokens_estimate.isdigit() else 0
    res = {"kind": a.kind, "round": int(a.round), "axis": a.axis, "attempt": int(a.attempt),
           "status": a.status, "valid": False, "error_code": None, "error": None, "warnings": [],
           "model": a.model, "effort": a.effort, "sandbox": a.sandbox,
           "seconds": int(a.seconds) if a.seconds.isdigit() else 0,
           "tokens": {"reported": reported, "estimate": estimate, "estimate_only": reported is None},
           "prompt": a.prompt, "out": a.out}
    if a.status == "ok":
        try:
            data = extract(read(a.answer))
            if a.kind == "review":
                res["review"], res["warnings"] = validate_review(data, a.axis)
            else:
                ids = [i["id"] for i in load_issues(a.issues)]
                res["verify"], res["warnings"] = validate_verify(data, a.axis, ids)
            res["valid"] = True
        except Invalid as e:
            res["status"] = "schema-invalid(%s)" % e.code
            res["error_code"], res["error"] = e.code, e.msg
    else:
        res["error"] = "no answer to validate: %s" % a.status
    with open(a.json_out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(res, f, ensure_ascii=False)
        f.write("\n")
    summary = ["status=%s" % res["status"]]
    if a.kind == "review" and res.get("review"):
        r = res["review"]
        summary += ["verdict=%s" % r["verdict"], "issues=%d" % len(r["issues"]),
                    "high=%d" % sum(1 for i in r["issues"] if i["severity"] == "HIGH")]
    if a.kind == "verify" and res.get("verify"):
        v = res["verify"]["verifications"]
        summary += ["agree=%d" % sum(1 for x in v if x["verdict"] == "AGREE"),
                    "disagree=%d" % sum(1 for x in v if x["verdict"] == "DISAGREE")]
    summary.append("tokens=%d%s" % (reported if reported is not None else estimate,
                                     "" if reported is not None else "(estimate)"))
    if res["warnings"]:
        summary.append("warnings=%d" % len(res["warnings"]))
    sys.stdout.write(" ".join(summary))


def main():
    cmds = {"section": cmd_section, "check-issues": cmd_check_issues,
            "verify-context": cmd_verify_context, "field": cmd_field, "result": cmd_result}
    if len(sys.argv) < 2 or sys.argv[1] not in cmds:
        sys.stderr.write("usage: mangchi_yaml.py %s ...\n" % "|".join(cmds))
        sys.exit(2)
    cmds[sys.argv[1]](sys.argv[2:])


if __name__ == "__main__":
    main()
