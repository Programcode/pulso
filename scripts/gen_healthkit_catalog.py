#!/usr/bin/env python3
"""Generates Pulso/Health/HealthKitCatalog.generated.swift from the iOS SDK's
HealthKit headers, so the app reads every type the SDK declares instead of a
hand-picked list.

    scripts/gen_healthkit_catalog.py <HealthKit.framework/Headers> <output.swift>

CI runs it against the runner's SDK before building (so the IPA always covers
the SDK it was compiled with) and warns when the committed file is stale.

What it reads:
- HKTypeIdentifiers.h: every quantity, category and characteristic identifier,
  its iOS availability, header section, and the trailing comment that names
  the canonical unit (quantities) or the value enum (categories).
- Every header's NS_ENUMs (category values, workout activity types, ECG
  classifications, state-of-mind labels, characteristics, ...), so enum
  values serialize by name.
"""
import os
import re
import sys

ID_LINE = re.compile(r"HK_EXTERN\s+(\w+)\s+const\s+(\w+)\s+(.*?);\s*(?://\s*(.*))?$")
def enum_value(expr, known, implicit):
    """Value of an enum initializer: decimal or hex literals, shifts and ors
    of those, and earlier cases of the same enum. None when it is anything
    else, so one odd header line can't stop the build."""
    expr = expr.strip()
    for case_name, case_value in sorted(known.items(), key=lambda kv: -len(kv[0])):
        expr = re.sub(r"\b%s\b" % re.escape(case_name), str(case_value), expr)
    expr = re.sub(r"(?<=[0-9A-Fa-f])[uUlL]+\b", "", expr)
    if not re.fullmatch(r"[0-9xXa-fA-F\s()<>|+-]+", expr):
        return None
    try:
        return int(eval(expr, {"__builtins__": {}}, {}))
    except Exception:
        return None


ENUM_START = re.compile(r"typedef\s+NS_ENUM\s*\(\s*\w+\s*,\s*(\w+)\s*\)\s*\{")
ENUM_CASE = re.compile(r"^\s*(\w+)\s*(.*?)\s*(?:=\s*([\w-]+))?\s*,?\s*(?://.*)?$")


def ios_version(attrs):
    m = re.search(r"\bios\((\d+)(?:\.(\d+))?", attrs)
    return (int(m.group(1)), int(m.group(2) or 0)) if m else None


def deprecated(attrs):
    return "DEPRECATED" in attrs or "deprecated(" in attrs


def unavailable_on_ios(attrs):
    return re.search(r"API_UNAVAILABLE\([^)]*\bios\b", attrs) is not None


def wire_key(stem):
    """Swift-style lower camel case: StepCount -> stepCount, VO2Max -> vo2Max,
    UVExposure -> uvExposure, GAD7 -> gad7."""
    m = re.match(r"^([A-Z]+)(.*)$", stem)
    if not m:
        return stem
    caps, rest = m.groups()
    if rest and rest[0].islower() and len(caps) > 1:
        return caps[:-1].lower() + caps[-1] + rest
    return caps.lower() + rest


def display_name(stem):
    words = re.findall(r"[A-Z]+(?=[A-Z][a-z]|$)|[A-Z]?[a-z]+\d*|[A-Z]+\d*|\d+", stem)
    return " ".join(words)


def parse_identifiers(path):
    out = []
    section = "Other"
    for raw in open(path, encoding="utf-8"):
        line = raw.rstrip()
        s = re.match(r"^//\s+([A-Z][A-Za-z &]+)$", line)
        if s:
            section = s.group(1).strip()
            continue
        m = ID_LINE.match(line)
        if not m:
            continue
        kind, name, attrs, comment = m.groups()
        if unavailable_on_ios(attrs):
            continue
        out.append({"kind": kind, "name": name, "ios": ios_version(attrs) or (8, 0),
                    "deprecated": deprecated(attrs), "comment": (comment or "").strip(), "section": section})
    return out


def parse_enums(path, wanted=None):
    """Returns {enum name: [(value, case name without prefix, deprecated)]}.
    Handles implicit increments and aliases (= OtherCase)."""
    enums = {}
    text = open(path, encoding="utf-8").read()
    for m in ENUM_START.finditer(text):
        name = m.group(1)
        if wanted and name not in wanted:
            continue
        body = text[m.end():text.index("}", m.end())]
        values = {}
        cases = []
        nxt = 0
        for raw in body.split("\n"):
            raw = re.sub(r"//.*$", "", raw).strip()
            if not raw or raw.startswith(("//", "/*", "*")):
                continue
            cm = re.match(r"^(\w+)([^=]*?)(?:=\s*(.+?))?\s*,?\s*$", raw)
            if not cm:
                continue
            case, attrs, value = cm.groups()
            v = enum_value(value, values, nxt) if value is not None else nxt
            if v is None:
                print("warning: %s.%s = %s not understood; skipped" % (name, case, value), file=sys.stderr)
                continue
            values[case] = v
            nxt = v + 1
            short = case[len(name):] if case.startswith(name) else case
            cases.append((v, short, deprecated(attrs)))
        enums[name] = cases
    return enums


def value_names(cases):
    """value -> wire name, preferring the non-deprecated case for aliases."""
    names = {}
    for v, short, dep in cases:
        if v not in names or (names[v][1] and not dep):
            names[v] = (wire_key(short), dep)
    return {v: n for v, (n, _) in sorted(names.items())}


def swift_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def os_lit(v):
    return "OperatingSystemVersion(majorVersion: %d, minorVersion: %d, patchVersion: 0)" % v


def main(headers, output):
    ids = parse_identifiers(os.path.join(headers, "HKTypeIdentifiers.h"))
    enums = {}
    for header in sorted(os.listdir(headers)):
        if header.endswith(".h"):
            enums.update(parse_enums(os.path.join(headers, header)))
    cat_enums = {k: v for k, v in enums.items() if k.startswith("HKCategoryValue")}
    sdk = open(os.path.join(headers, "..", "SDK_VERSION")).read().strip() if os.path.exists(
        os.path.join(headers, "..", "SDK_VERSION")) else "unknown"

    q, c, ch, other = [], [], [], []
    for e in ids:
        prefix = e["kind"]
        stem = e["name"][len(prefix):] if e["name"].startswith(prefix) else e["name"]
        if e["kind"] == "HKQuantityTypeIdentifier":
            unit, _, agg = e["comment"].partition(",")
            q.append(dict(e, stem=stem, unit=unit.strip() or "count", aggregation=agg.strip()))
        elif e["kind"] == "HKCategoryTypeIdentifier":
            enum = e["comment"].split()[0] if e["comment"] else ""
            c.append(dict(e, stem=stem, enum=enum if enum in cat_enums and enum != "HKCategoryValue" else None))
        elif e["kind"] == "HKCharacteristicTypeIdentifier":
            ch.append(dict(e, stem=stem))
        else:
            other.append(e)

    lines = [
        "// Generated by scripts/gen_healthkit_catalog.py from the iOS %s SDK headers. Do not edit." % sdk,
        "// swiftlint:disable all",
        "import Foundation",
        "",
        "/// Every HealthKit type identifier the SDK declares, with what the headers",
        "/// say about it. Identifiers are raw strings so a type newer than the",
        "/// running OS resolves to nil at runtime instead of failing to link.",
        "enum HealthKitCatalog {",
        "    static let sdkVersion = %s" % swift_str(sdk),
        "",
        "    struct Quantity: Sendable {",
        "        let identifier: String",
        "        let key: String",
        "        let name: String",
        "        let section: String",
        "        /// Canonical unit from the header comment, in HKUnit(from:) syntax.",
        "        let unit: String",
        "        let aggregation: String",
        "        let minimumOS: OperatingSystemVersion",
        "        let deprecated: Bool",
        "    }",
        "",
        "    struct Category: Sendable {",
        "        let identifier: String",
        "        let key: String",
        "        let name: String",
        "        let section: String",
        "        /// Name of the HKCategoryValue enum; nil when the value is notApplicable.",
        "        let valueEnum: String?",
        "        let minimumOS: OperatingSystemVersion",
        "        let deprecated: Bool",
        "    }",
        "",
        "    struct Characteristic: Sendable {",
        "        let identifier: String",
        "        let key: String",
        "        let name: String",
        "        let minimumOS: OperatingSystemVersion",
        "    }",
        "",
        "    struct Identifier: Sendable {",
        "        let identifier: String",
        "        let key: String",
        "        let name: String",
        "        let kind: String",
        "        let section: String",
        "        let minimumOS: OperatingSystemVersion",
        "    }",
        "",
        "    static let quantities: [Quantity] = [",
    ]
    for e in q:
        lines.append("        Quantity(identifier: %s, key: %s, name: %s, section: %s, unit: %s, aggregation: %s, minimumOS: %s, deprecated: %s)," % (
            swift_str(e["name"]), swift_str(wire_key(e["stem"])), swift_str(display_name(e["stem"])),
            swift_str(e["section"]), swift_str(e["unit"]), swift_str(e["aggregation"]), os_lit(e["ios"]),
            "true" if e["deprecated"] else "false"))
    lines += ["    ]", "", "    static let categories: [Category] = ["]
    for e in c:
        lines.append("        Category(identifier: %s, key: %s, name: %s, section: %s, valueEnum: %s, minimumOS: %s, deprecated: %s)," % (
            swift_str(e["name"]), swift_str(wire_key(e["stem"])), swift_str(display_name(e["stem"])),
            swift_str(e["section"]), swift_str(e["enum"]) if e["enum"] else "nil", os_lit(e["ios"]),
            "true" if e["deprecated"] else "false"))
    lines += ["    ]", "", "    static let characteristics: [Characteristic] = ["]
    for e in ch:
        lines.append("        Characteristic(identifier: %s, key: %s, name: %s, minimumOS: %s)," % (
            swift_str(e["name"]), swift_str(wire_key(e["stem"])), swift_str(display_name(e["stem"])), os_lit(e["ios"])))
    lines += ["    ]", "",
              "    /// Correlation, document, scored-assessment and other identifiers. The app",
              "    /// handles these by hand; the list exists so coverage can be checked.",
              "    static let otherIdentifiers: [Identifier] = ["]
    for e in other:
        stem = e["name"][len(e["kind"]):] if e["name"].startswith(e["kind"]) else e["name"]
        lines.append("        Identifier(identifier: %s, key: %s, name: %s, kind: %s, section: %s, minimumOS: %s)," % (
            swift_str(e["name"]), swift_str(wire_key(stem)), swift_str(display_name(stem)), swift_str(e["kind"]),
            swift_str(e["section"]), os_lit(e["ios"])))
    lines += ["    ]", "",
              "    /// Every NS_ENUM in the HealthKit headers: enum name -> raw value -> wire",
              "    /// name (the Swift case name). Aliases resolve to the non-deprecated case.",
              "    static let enumNames: [String: [Int: String]] = ["]
    for name in sorted(enums):
        pairs = ", ".join("%d: %s" % (v, swift_str(n)) for v, n in value_names(enums[name]).items())
        if pairs:
            lines.append("        %s: [%s]," % (swift_str(name), pairs))
    lines += ["    ]", "}", ""]
    with open(output, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print("quantities=%d categories=%d characteristics=%d other=%d enums=%d" % (
        len(q), len(c), len(ch), len(other), len(enums)), file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
