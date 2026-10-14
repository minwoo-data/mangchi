#!/usr/bin/env python3
"""mangchi_yaml.py -- deterministic helpers for scripts/codex-run.sh (mangchi, schema_version 1).

The model never eyeballs a Codex answer or re-types a rubric: codex-run.sh calls this file to
cut prompt sections out of axes.md, to number the reviewed file, to join the REJECTed issues with
the review results, to build the verify context, and to validate the YAML.
Schema rules = SKILL.md Phase 3 / Phase 6 and axes.md "공통 출력 포맷".

Subcommands (exit 0 = ok, 1 = invalid input, 2 = usage, 3 = section missing):
  section <axes.md> axis <name> | review-format | verify-format
  number-file <file>                          the file with "%5d| " line numbers (review FILE block)
  resolve-issues <rejects-file> <session-dir> <N>
                                              REJECTed issues joined with the review results -> JSON
  verify-context <resolved.json> <updated-file>
  state <result.json>                         "status<TAB>attempt<TAB>valid" (exit 1 = unreadable)
  prior-tokens <result.json>                  tokens this call has already spent (0 when unknown)
  field <json-file> <dotted.key>
  result --kind review|verify --answer F --axis A [--issues-json F] --status S --json-out F ...
         validates the answer when status is ok, writes the result JSON, prints the summary
Created by: Minwoo Park
"""
import argparse
import json
import os
import re
import sys

# Text out exactly as built: UTF-8, LF only (Windows would otherwise write cp949/CRLF).
sys.stdout.reconfigure(encoding="utf-8", newline="\n")
sys.stderr.reconfigure(encoding="utf-8", newline="\n")

VALID_AXES = ("correctness", "security", "readability", "performance", "design",
              "necessity", "robustness")
LEVELS = ("HIGH", "MEDIUM", "LOW")
# A file name with an extension (optionally a path or a Windows drive), as Codex and Claude cite it.
FILE = r"(?:[A-Za-z]:[\\/])?[\w./\\-]*\w\.[A-Za-z]\w*"
# locus: the whole value is "file.ext:LINE[-LINE]", lines from 1 ("throughout:3" or ":0x" fail).
LOCUS_RE = re.compile(r"(%s):([1-9]\d*)(?:\s*-\s*([1-9]\d*))?" % FILE)
# Phase 6: DISAGREE must cite post-edit code as file.ext:LINE.
FILE_LINE_RE = re.compile(r"%s:[1-9]\d*" % FILE)
# Phase 4: a REJECT cites file.ext:LINE, a pytest-style node id (file.ext::name) or a test name.
CITATION_RE = re.compile(r"%s:[1-9]\d*|\S+\.[A-Za-z]\w*::\w+|\btest_\w+" % FILE)
RANGE_RE = re.compile(r"^\s*([1-9]\d*)(?:\s*-\s*([1-9]\d*))?\s*$")
# A carried issue from an earlier round: R{round}.{axis}#{id} (SKILL.md, FORCED_ACCEPT identifier).
CARRIED_RE = re.compile(r"R([1-9]\d*)\.([a-z]+)#(\d+)")
FENCE_RE = re.compile(r"^```[ \t]*([A-Za-z0-9_+-]*)[ \t]*\r?\n(.*?)^```[ \t]*$", re.M | re.S)
CONTEXT = 10


class Invalid(Exception):
    def __init__(self, code, msg):
        super().__init__(msg)
        self.code = code
        self.msg = msg


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def short(v, n=120):
    s = repr(v)
    return s if len(s) <= n else s[:n] + "...'"


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
    if kind == "format-headings":
        return "\n".join(block[k] for k in subs) + "\n"
    return None


def numbered(lines, lo, hi):
    return ["%5d| %s" % (i, lines[i - 1]) for i in range(lo, hi + 1)]


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


def parse_locus(loc):
    """(file, first, last) for a valid locus, else None."""
    if not isinstance(loc, str):
        return None
    m = LOCUS_RE.fullmatch(loc.strip())
    if not m:
        return None
    a = int(m.group(2))
    b = int(m.group(3) or a)
    return (m.group(1), a, b) if a <= b else None


def extract(text):
    """The final ```yaml fence of the answer (SKILL.md Phase 3: only that fence is parsed).

    An untagged fence counts only when the answer has no ```yaml / ```yml fence at all, and the
    whole text only when it has no fence. A malformed final fence is an error, never a reason to
    fall back to an earlier block."""
    yaml = yaml_mod()
    fences = FENCE_RE.findall(text)
    if fences:
        tagged = [b for t, b in fences if t.lower() in ("yaml", "yml")]
        plain = [b for t, b in fences if not t]
        if tagged:
            body, where = tagged[-1], "the final ```yaml fence"
        elif plain:
            body, where = plain[-1], "the final ``` fence"
        else:
            raise Invalid("no-yaml", "the answer has no ```yaml fence")
    else:
        body, where = text, "the answer (no fence)"
    try:
        data = yaml.safe_load(body)
    except Exception as e:  # YAMLError, or e.g. ValueError for an unquoted 2026-99-99
        first = (str(e).splitlines() or [type(e).__name__])[0]
        raise Invalid("no-yaml", "YAML parse error in %s: %s" % (where, first))
    if not isinstance(data, dict):
        raise Invalid("no-yaml", "%s is not a YAML mapping" % where)
    return data


def check_axis(data, axis):
    got = data.get("axis")
    if got != axis:
        raise Invalid("axis", "axis must be %r (this call's axis), got %s" % (axis, short(got)))


def validate_review(data, axis):
    check_axis(data, axis)
    warnings = []
    verdict = data.get("verdict")
    if verdict not in ("PASS", "REVISE"):
        raise Invalid("verdict", "verdict must be PASS or REVISE, got %s" % short(verdict))
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
        if parse_locus(loc) is None:
            raise Invalid(p + ".locus", '%s.locus must be "file.ext:LINE[-LINE]" (lines from 1, '
                                        'start <= end), got %s' % (p, short(loc)))
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
        out.append({"id": it["id"], "severity": it["severity"], "locus": loc.strip(),
                    "problem": fields["problem"], "proposed_fix": fields["proposed_fix"],
                    "confidence": it["confidence"]})
    if highs > 3:
        warnings.append("%d HIGH issues (axes.md: at most 3 per round)" % highs)
    if verdict == "PASS" and out:
        warnings.append("verdict PASS with %d issue(s)" % len(out))
    if verdict == "PASS" and ncs is not True:
        warnings.append("verdict PASS without no_changes_suggested: true - this round does not "
                        "count toward the 2-PASS stop (Phase 7)")
    return {"axis": axis, "verdict": verdict, "no_changes_suggested": ncs, "issues": out}, warnings


def validate_verify(data, axis, keys):
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
        if isinstance(iid, str):
            iid = iid.strip()
        if not (is_int(iid) or isinstance(iid, str)):
            raise Invalid(p + ".issue_id", "%s.issue_id must be an integer or \"R{m}.{axis}#{id}\"" % p)
        if iid not in keys:
            raise Invalid(p + ".issue_id", "issue_id %s was not sent for verification" % short(iid))
        if iid in seen:
            raise Invalid(p + ".issue_id", "issue_id %s answered twice" % short(iid))
        seen.add(iid)
        verdict = v.get("verdict")
        if verdict not in ("AGREE", "DISAGREE"):
            raise Invalid(p + ".verdict", "%s.verdict must be AGREE or DISAGREE" % p)
        reason = v.get("reason")
        if reason is not None and not isinstance(reason, str):
            raise Invalid(p + ".reason", "%s.reason must be a string" % p)
        if verdict == "DISAGREE" and not (reason and FILE_LINE_RE.search(reason)):
            raise Invalid(p + ".reason", "DISAGREE on issue %s must cite post-edit code as file.ext:LINE"
                          % short(iid))
        out.append({"issue_id": iid, "verdict": verdict, "reason": reason})
    missing = [str(x) for x in keys if x not in seen]
    if missing:
        raise Invalid("verifications", "no answer for issue_id(s) %s" % ", ".join(missing))
    return {"axis": axis, "verifications": out}, []


# ---------------------------------------------------------------- REJECTed issues (Phase 6)

def load_review(session, m):
    path = os.path.join(session, "round-%d.codex.txt.json" % m)
    try:
        rev = json.loads(read(path))
    except (OSError, ValueError) as e:
        raise Invalid("issues-file", "cannot read round %d's review result %s: %s" % (m, path, e))
    if not (isinstance(rev, dict) and rev.get("valid") is True and isinstance(rev.get("review"), dict)):
        raise Invalid("issues-file", "%s holds no valid review (status %s)"
                      % (path, rev.get("status") if isinstance(rev, dict) else None))
    return rev["review"]


def carryover_section(session, n):
    path = os.path.join(session, "round-%d.carryover.md" % (n - 1))
    try:
        lines = read(path).splitlines()
    except OSError:
        raise Invalid("issues-file", "carried issues must be listed under '## carryover' in %s, "
                                     "which does not exist" % path)
    start = next((i for i, l in enumerate(lines) if l.strip() == "## carryover"), None)
    if start is None:
        raise Invalid("issues-file", "%s has no '## carryover' section" % path)
    end = next((j for j in range(start + 1, len(lines)) if lines[j].startswith("## ")), len(lines))
    return "\n".join(lines[start + 1:end]), path


def norm(v):
    if isinstance(v, (dict, list)):
        v = text_field(v)
    return "" if v is None else " ".join(str(v).split())


def resolve_issues(path, session, n):
    """The issues Claude REJECTed, joined with the review that raised them.

    The rejects file supplies only which issue (id = this round's review, or carried =
    "R{m}.{axis}#{id}" from an earlier round), Claude's reason and optionally post_edit_lines. The
    locus, problem, proposed_fix and severity Codex is asked about always come from the review
    result; copies in the rejects file must match it verbatim (PRISM-002)."""
    yaml = yaml_mod()
    try:
        data = yaml.safe_load(read(path))
    except OSError as e:
        raise Invalid("issues-file", "cannot read the issues file: %s" % e)
    except Exception as e:
        raise Invalid("issues-file", "issues file is not YAML/JSON: %s" % (str(e).splitlines() or [""])[0])
    if isinstance(data, dict) and "issues" in data:
        data = data["issues"]
    if not isinstance(data, list) or not data:
        raise Invalid("issues-file", "issues file must hold a non-empty list of REJECTed issues")
    review = load_review(session, n)
    by_id = {i["id"]: i for i in review["issues"]}
    carry = None
    out, seen = [], set()
    for k, it in enumerate(data, 1):
        p = "issue %d" % k
        if not isinstance(it, dict):
            raise Invalid("issues-file", "%s must be a mapping" % p)
        if it.get("decision", "REJECT") != "REJECT":
            raise Invalid("issues-file", "%s: only REJECTed issues go to verify" % p)
        has_id, has_c = "id" in it, "carried" in it
        if has_id == has_c:
            raise Invalid("issues-file", '%s: give exactly one of id (this round\'s review) or carried '
                                         '("R{m}.{axis}#{id}" from an earlier round)' % p)
        if has_id:
            if not is_int(it["id"]):
                raise Invalid("issues-file", "%s: id must be an integer" % p)
            src = by_id.get(it["id"])
            if src is None:
                raise Invalid("issues-file", "id %d is not in round %d's review" % (it["id"], n))
            key, axis, origin = it["id"], review["axis"], n
        else:
            m = CARRIED_RE.fullmatch(str(it["carried"]).strip())
            if not m:
                raise Invalid("issues-file", '%s: carried must look like "R1.correctness#2", got %s'
                              % (p, short(it["carried"])))
            rm, rax, rid = int(m.group(1)), m.group(2), int(m.group(3))
            if rm >= n:
                raise Invalid("issues-file", "%s: a carried issue comes from an earlier round (R%d is not "
                                             "before round %d)" % (p, rm, n))
            prev = load_review(session, rm)
            if prev["axis"] != rax:
                raise Invalid("issues-file", "%s: round %d reviewed axis %s, not %s" % (p, rm, prev["axis"], rax))
            src = {i["id"]: i for i in prev["issues"]}.get(rid)
            if src is None:
                raise Invalid("issues-file", "%s: id %d is not in round %d's review" % (p, rid, rm))
            key, axis, origin = "R%d.%s#%d" % (rm, rax, rid), rax, rm
            if carry is None:
                carry = carryover_section(session, n)
            if not re.search(r"(?<![\w.#])%s(?!\d)" % re.escape(key), carry[0]):
                raise Invalid("issues-file", "%s: %s is not listed under '## carryover' in %s"
                              % (p, key, carry[1]))
            if it.get("post_edit_lines") is None:
                raise Invalid("issues-file", "%s: a carried issue needs post_edit_lines (where it is in "
                                             "today's updated file)" % key)
        if key in seen:
            raise Invalid("issues-file", "duplicate issue %s" % key)
        seen.add(key)
        for f in ("locus", "problem", "proposed_fix", "severity"):
            if it.get(f) is not None and norm(it[f]) != norm(src.get(f)):
                raise Invalid("issues-file", "issue %s: %s differs from the review (round %d); the verify "
                                             "prompt always shows the review's text, so drop the field or "
                                             "copy it verbatim" % (key, f, origin))
        reason = it.get("reason")
        if not (isinstance(reason, str) and CITATION_RE.search(reason)):
            raise Invalid("issues-file", "issue %s: the REJECT reason must cite file.ext:LINE, a test node "
                                         "id or a test_* name (Phase 4 hard validation)" % (key,))
        pel = it.get("post_edit_lines")
        if pel is not None and not RANGE_RE.match(str(pel)):
            raise Invalid("issues-file", 'issue %s: post_edit_lines must look like "118" or "118-121"' % (key,))
        out.append({"key": key, "axis": axis, "round": origin, "carried": has_c,
                    "locus": src["locus"], "severity": src["severity"], "problem": src["problem"],
                    "proposed_fix": src["proposed_fix"], "reason": reason,
                    "post_edit_lines": None if pel is None else str(pel)})
    return out


def line_range(it):
    if it.get("post_edit_lines") is not None:
        m = RANGE_RE.match(it["post_edit_lines"])
        a, b = int(m.group(1)), int(m.group(2) or m.group(1))
        return (a, b) if a <= b else (b, a)
    loc = parse_locus(it["locus"])
    return (loc[1], loc[2]) if loc else (1, 1)


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
        if it["carried"]:
            parts.append('### issue_id: "%s" (carried from round %d, axis %s)' % (it["key"], it["round"], it["axis"]))
        else:
            parts.append("### issue_id: %d" % it["key"])
        parts.append("- locus (as raised): %s" % it["locus"])
        parts.append("- severity: %s" % it["severity"])
        parts.append("- problem: %s" % it["problem"])
        parts.append("- proposed_fix: %s" % it["proposed_fix"])
        parts.append("- Claude REJECT 근거: %s" % it["reason"])
        parts.append("- post-edit %s %d-%d%s:" % (name, lo, hi, note))
        parts.append("```")
        parts.extend(numbered(lines, lo, hi))
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


def cmd_number_file(argv):
    if len(argv) != 1:
        sys.exit(2)
    lines = read(argv[0]).splitlines()
    sys.stdout.write("".join(l + "\n" for l in numbered(lines, 1, len(lines))))


def cmd_resolve_issues(argv):
    if len(argv) != 3 or not argv[2].isdigit():
        sys.exit(2)
    try:
        sys.stdout.write(json.dumps(resolve_issues(argv[0], argv[1], int(argv[2])), ensure_ascii=False) + "\n")
    except Invalid as e:
        sys.stderr.write(e.msg + "\n")
        sys.exit(1)


def cmd_verify_context(argv):
    if len(argv) != 2:
        sys.exit(2)
    try:
        issues = json.loads(read(argv[0]))
    except (OSError, ValueError) as e:
        sys.stderr.write("cannot read the resolved issues %s: %s\n" % (argv[0], e))
        sys.exit(1)
    sys.stdout.write(verify_context(issues, argv[1]))


def load_json(path):
    try:
        v = json.loads(read(path))
    except (OSError, ValueError):
        return None
    return v if isinstance(v, dict) else None


def cmd_state(argv):
    if len(argv) != 1:
        sys.exit(2)
    v = load_json(argv[0])
    if v is None or not isinstance(v.get("status"), str):
        sys.exit(1)
    att = v.get("attempt", 1)
    if not is_int(att) or att not in (1, 2):
        sys.exit(1)
    sys.stdout.write("%s\t%d\t%s" % (v["status"], att, "true" if v.get("valid") is True else "false"))


def spent(tokens):
    if not isinstance(tokens, dict):
        return 0
    for k in ("call_total", "reported", "estimate"):
        if is_int(tokens.get(k)):
            return tokens[k]
    return 0


def cmd_prior_tokens(argv):
    if len(argv) != 1:
        sys.exit(2)
    v = load_json(argv[0]) if os.path.exists(argv[0]) else None
    sys.stdout.write(str(spent(v.get("tokens")) if v else 0))


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


def write_exclusive(path, text):
    """Write into the temp file codex-run.sh created with mktemp; never through a symlink."""
    fd = os.open(path, os.O_WRONLY | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_BINARY", 0))
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def cmd_result(argv):
    ap = argparse.ArgumentParser(prog="mangchi_yaml.py result")
    for opt in ("--kind", "--answer", "--axis", "--status", "--json-out", "--round", "--attempt"):
        ap.add_argument(opt, required=True)
    for opt in ("--issues-json", "--model", "--effort", "--sandbox", "--seconds", "--tokens-reported",
                "--tokens-estimate", "--prior-tokens", "--codex-called", "--cleanup-failed",
                "--prompt", "--out"):
        ap.add_argument(opt, default="")
    a = ap.parse_args(argv)
    reported = int(a.tokens_reported) if a.tokens_reported.isdigit() else None
    estimate = int(a.tokens_estimate) if a.tokens_estimate.isdigit() else 0
    prior = int(a.prior_tokens) if a.prior_tokens.isdigit() else 0
    called = a.codex_called == "1"
    this = (reported if reported is not None else estimate) if called else 0
    res = {"kind": a.kind, "round": int(a.round), "axis": a.axis, "attempt": int(a.attempt),
           "status": a.status, "valid": False, "error_code": None, "error": None, "warnings": [],
           "model": a.model, "effort": a.effort, "sandbox": a.sandbox,
           "seconds": int(a.seconds) if a.seconds.isdigit() else 0, "codex_called": called,
           "tokens": {"reported": reported, "estimate": estimate, "estimate_only": reported is None,
                      "this_attempt": this, "prior_total": prior, "call_total": prior + this},
           "cleanup_failed": a.cleanup_failed or None, "prompt": a.prompt, "out": a.out}
    if a.status == "ok":
        try:
            data = extract(read(a.answer))
            if a.kind == "review":
                res["review"], res["warnings"] = validate_review(data, a.axis)
            else:
                keys = [i["key"] for i in json.loads(read(a.issues_json))]
                res["verify"], res["warnings"] = validate_verify(data, a.axis, keys)
            res["valid"] = True
        except Invalid as e:
            res["status"] = "schema-invalid(%s)" % e.code
            res["error_code"], res["error"] = e.code, e.msg
        except Exception as e:  # never publish an unvalidated answer as ok (PRISM-009)
            res["status"] = "degraded(result-failed)"
            res["error_code"] = "result-failed"
            res["error"] = "%s: %s" % (type(e).__name__, (str(e).splitlines() or [""])[0][:200])
    else:
        res["error"] = "no answer to validate: %s" % a.status
    if a.cleanup_failed:
        res["warnings"].append("scratch cleanup failed: delete %s by hand" % a.cleanup_failed)
    write_exclusive(a.json_out, json.dumps(res, ensure_ascii=False) + "\n")
    summary = ["status=%s" % res["status"]]
    if a.kind == "review" and res.get("review"):
        r = res["review"]
        summary += ["verdict=%s" % r["verdict"], "issues=%d" % len(r["issues"]),
                    "high=%d" % sum(1 for i in r["issues"] if i["severity"] == "HIGH")]
    if a.kind == "verify" and res.get("verify"):
        v = res["verify"]["verifications"]
        summary += ["agree=%d" % sum(1 for x in v if x["verdict"] == "AGREE"),
                    "disagree=%d" % sum(1 for x in v if x["verdict"] == "DISAGREE")]
    summary.append("tokens=%d%s" % (this, "" if reported is not None or not called else "(estimate)"))
    if prior:
        summary.append("call_total=%d" % (prior + this))
    if res["warnings"]:
        summary.append("warnings=%d" % len(res["warnings"]))
    sys.stdout.write(" ".join(summary) + "\n")


def main():
    cmds = {"section": cmd_section, "number-file": cmd_number_file,
            "resolve-issues": cmd_resolve_issues, "verify-context": cmd_verify_context,
            "state": cmd_state, "prior-tokens": cmd_prior_tokens, "field": cmd_field,
            "result": cmd_result}
    if len(sys.argv) < 2 or sys.argv[1] not in cmds:
        sys.stderr.write("usage: mangchi_yaml.py %s ...\n" % "|".join(cmds))
        sys.exit(2)
    cmds[sys.argv[1]](sys.argv[2:])


if __name__ == "__main__":
    main()
