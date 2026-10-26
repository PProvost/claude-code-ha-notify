#!/usr/bin/env python3
"""Structural checks for the Home Assistant package.

yamllint says the file is well-formed YAML. These checks say the parts refer to
each other correctly: that every script called exists, that every variable
passed to a script is one of its declared fields, that every required field is
supplied, that the entities used are either defined here or are the two To-do
lists the install creates by hand, and that the !secret names match
secrets.example.yaml. Those are the mistakes a typo produces and a linter
cannot see.

Usage: tests/check-ha-package.py [package.yaml]
"""

import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
PACKAGE = (pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1
           else ROOT / "home-assistant" / "packages" / "claude_code_notify.yaml")
SECRETS_EXAMPLE = ROOT / "home-assistant" / "secrets.example.yaml"

# The two Local To-do lists are created in the UI, so they cannot be defined in
# the package. The install instructions pin these exact entity IDs.
UI_CREATED_ENTITIES = {"todo.claude_muted", "todo.claude_pending"}

# Built-in services in the script domain, which are not scripts of ours.
SCRIPT_DOMAIN_SERVICES = {
    "script.turn_on", "script.turn_off", "script.toggle", "script.reload",
}

failures = []
checks = 0


def check(ok, label, detail=""):
    global checks
    checks += 1
    if ok:
        print(f"  ok   {label}")
    else:
        print(f"  FAIL {label}")
        if detail:
            print(f"       {detail}")
        failures.append(label)


class SecretTag(str):
    """A !secret reference, carrying the secret's name."""


def secret_constructor(loader, node):
    return SecretTag(loader.construct_scalar(node))


class HALoader(yaml.SafeLoader):
    pass


HALoader.add_constructor("!secret", secret_constructor)


def walk(node, path=()):
    """Yields (path, value) for every mapping and list element in the tree."""
    yield path, node
    if isinstance(node, dict):
        for k, v in node.items():
            yield from walk(v, path + (k,))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from walk(v, path + (i,))


def main():
    try:
        shown = PACKAGE.relative_to(ROOT)
    except ValueError:
        shown = PACKAGE
    print(f"Checking {shown}")
    config = yaml.load(PACKAGE.read_text(), Loader=HALoader)

    # --- shape --------------------------------------------------------------
    for domain in ("automation", "script", "input_boolean", "input_datetime"):
        check(domain in config, f"the package defines {domain}")

    automations = config.get("automation") or []
    scripts = config.get("script") or {}

    ids = [a.get("id") for a in automations]
    check(all(ids), "every automation has an id, so traces work",
          f"ids: {ids}")
    check(len(ids) == len(set(ids)), "automation ids are unique", f"ids: {ids}")
    for expected in ("claude_code_phone", "claude_code_night_mode",
                     "claude_code_morning_release"):
        check(expected in ids, f"automation {expected} is present")
    for expected in ("claude_code_notify", "claude_code_hold"):
        check(expected in scripts, f"script {expected} is present")

    # --- script calls resolve ----------------------------------------------
    defined_scripts = {f"script.{name}" for name in scripts}
    called = set()
    for _, node in walk(config):
        if not isinstance(node, dict):
            continue
        action = node.get("action")
        if (isinstance(action, str) and action.startswith("script.")
                and action not in SCRIPT_DOMAIN_SERVICES
                and not isinstance(action, SecretTag)):
            called.add(action)
        if action == "script.turn_on":
            target = node.get("target") or {}
            entity = target.get("entity_id")
            for e in ([entity] if isinstance(entity, str) else entity or []):
                if e.startswith("script."):
                    called.add(e)
    unknown = called - defined_scripts
    check(not unknown, "every script called is defined in this package",
          f"unknown: {sorted(unknown)}")
    check(called == defined_scripts, "every script defined is actually called",
          f"defined: {sorted(defined_scripts)} called: {sorted(called)}")

    # --- script fields ------------------------------------------------------
    # Every variable handed to one of our scripts must be a field it declares,
    # and every required field must be supplied. A typo here fails silently in
    # Home Assistant: the script runs with the field simply unset.
    for _, node in walk(config):
        if not isinstance(node, dict):
            continue
        action = node.get("action")
        target_script = None
        passed = None
        if isinstance(action, str) and action in defined_scripts:
            target_script = action.split(".", 1)[1]
            passed = node.get("data") or {}
        elif action == "script.turn_on":
            target = node.get("target") or {}
            entity = target.get("entity_id")
            if isinstance(entity, str) and entity in defined_scripts:
                target_script = entity.split(".", 1)[1]
                passed = (node.get("data") or {}).get("variables") or {}
        if target_script is None:
            continue
        declared = set((scripts[target_script].get("fields") or {}).keys())
        required = {n for n, f in (scripts[target_script].get("fields") or {}).items()
                    if f.get("required")}
        extra = set(passed) - declared
        check(not extra,
              f"{target_script}: every variable passed is a declared field",
              f"not declared: {sorted(extra)}")
        missing = required - set(passed)
        check(not missing,
              f"{target_script}: every required field is supplied",
              f"missing: {sorted(missing)}")

    # --- entities resolve ---------------------------------------------------
    defined_entities = set()
    for domain in ("input_boolean", "input_datetime"):
        for name in (config.get(domain) or {}):
            defined_entities.add(f"{domain}.{name}")
    defined_entities |= defined_scripts | UI_CREATED_ENTITIES

    referenced = set()
    for path, node in walk(config):
        if isinstance(node, dict) and "entity_id" in node:
            entity = node["entity_id"]
            for e in ([entity] if isinstance(entity, str) else entity or []):
                if isinstance(e, str) and "." in e and "{{" not in e:
                    referenced.add(e)
    unknown = referenced - defined_entities
    check(not unknown,
          "every entity referenced is defined here or created by the install",
          f"unknown: {sorted(unknown)}")

    # The night schedule points its time triggers at the two helpers.
    for helper in ("input_datetime.claude_night_start",
                   "input_datetime.claude_night_end"):
        check(helper in defined_entities, f"{helper} is defined")

    # --- secrets match the example -----------------------------------------
    used_secrets = {
        node for _, node in walk(config) if isinstance(node, SecretTag)
    }
    documented = set(yaml.safe_load(SECRETS_EXAMPLE.read_text()) or {})
    check(used_secrets, "the package reads its values from secrets.yaml",
          f"found: {sorted(used_secrets)}")
    check(used_secrets <= documented,
          "every secret used is documented in secrets.example.yaml",
          f"undocumented: {sorted(used_secrets - documented)}")
    check(documented <= used_secrets,
          "secrets.example.yaml documents nothing unused",
          f"unused: {sorted(documented - used_secrets)}")

    # --- the payload contract ----------------------------------------------
    # The webhook handles 'clear' itself and never passes it on, so the notify
    # script's selector must offer the other three and not clear.
    kind_field = (scripts["claude_code_notify"].get("fields") or {}).get("kind") or {}
    options = (((kind_field.get("selector") or {}).get("select") or {})
               .get("options") or [])
    check(set(options) == {"stop", "permission", "idle"},
          "claude_code_notify accepts exactly the three forwarded event kinds",
          f"options: {options}")

    print(f"\n{checks} check(s), {len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
