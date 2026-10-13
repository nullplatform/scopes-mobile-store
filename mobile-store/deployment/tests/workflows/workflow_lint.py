"""Static checks of the mobile-store workflows, run by workflows_test.bats.

usage: python3 workflow_lint.py <scope dir> <check> <workflow yaml>...

checks:
  files    every script step names a file that exists under $SERVICE_PATH
  outputs  every variable a step consumes (CONSUMES below) is declared in the
           output of an earlier step, or comes from the engine (ENGINE_PROVIDED
           and the configuration of the included values.yaml)
  consumes every variable CONSUMES lists really appears in the files of that
           consumer (keeps the table honest)

Includes are resolved like np service workflow exec does: the included
workflows come first, and a step of the including workflow is inserted
before/after the named step, replaces a step with its name, or is appended.
"""
import glob
import os
import re
import sys

import yaml

ENGINE_PROVIDED = {"SERVICE_PATH", "CONTEXT", "NP_ACTION_CONTEXT", "SCOPE_ID", "DEPLOYMENT_ID",
                   "SERVICE_ACTION", "SERVICE_ACTION_TYPE", "NOTIFICATION_ACTION"}
AWS = ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN"]

# consumer key -> (variables it consumes, files/globs that consume them, relative to the scope dir)
CONSUMES = {
    "run_platforms": (
        AWS + ["PLATFORMS", "ASSETS_JSON", "ASSETS_BUCKET", "ASSETS_REGION", "WORKDIR"],
        ["deployment/scripts/run_platforms", "deployment/platform/*/setup",
         "deployment/scripts/prepare_platform_binary", "deployment/scripts/download_asset",
         "deployment/scripts/validators"]),
    "layer:signing": (
        AWS + ["PLATFORMS", "SIGNING_LAYER", "BINARY_PATH_ANDROID", "BINARY_PATH_IOS",
               "SCOPE_CONFIGURATION", "WORKDIR"],
        ["deployment/scripts/layer_executor", "deployment/signing/*/setup"]),
    "layer:distribution": (
        AWS + ["PLATFORMS", "DISTRIBUTION_LAYER", "SCOPE_CONFIGURATION", "ASSETS_REGION", "WORKDIR"],
        ["deployment/scripts/layer_executor", "deployment/distribution/*/setup"]),
    "layer:gate": (
        ["CHANNEL", "DISTRIBUTION_LAYER", "GATE_LAYER"],
        ["deployment/scripts/layer_executor", "deployment/gate/*/setup", "deployment/scripts/validators"]),
    "check:signing": (["SIGNING_LAYER"], ["deployment/scripts/layer_executor"]),
    "check:distribution": (["DISTRIBUTION_LAYER"], ["deployment/scripts/layer_executor"]),
    "check:gate": (["GATE_LAYER"], ["deployment/scripts/layer_executor"]),
    "do_publish": (
        ["DISTRIBUTION_LAYER", "GATE_LAYER", "GATE_RESULT", "CHANNEL", "ROLLOUT_PERCENTAGE", "PLATFORMS",
         "SIGNED_BINARY_PATH_ANDROID", "SIGNED_BINARY_PATH_IOS", "FIREBASE_PROJECT",
         "FIREBASE_APP_ID_ANDROID", "FIREBASE_APP_ID_IOS", "GOOGLE_APPLICATION_CREDENTIALS",
         "RELEASE_SEMVER", "APPLICATION_SLUG", "DIMENSION", "WORKDIR"],
        ["deployment/scripts/do_publish", "deployment/distribution/*/publish",
         "deployment/distribution/*/distribute"]),
    "do_rollback": (
        AWS + ["DISTRIBUTION_LAYER", "PLATFORMS", "CHANNEL", "SIGNING_LAYER", "PREVIOUS_DEPLOYMENT_ID",
               "PREVIOUS_RELEASE_SEMVER", "FIREBASE_PROJECT", "FIREBASE_APP_ID_ANDROID",
               "GOOGLE_APPLICATION_CREDENTIALS", "ASSETS_BUCKET", "ASSET_TYPE", "SCOPE_CONFIGURATION",
               "ASSET_NAME", "RELEASE_SEMVER", "APPLICATION_SLUG", "DIMENSION", "WORKDIR"],
        ["deployment/scripts/do_rollback", "deployment/distribution/*/rollback",
         "deployment/distribution/*/distribute", "deployment/scripts/resolve_release_asset",
         "deployment/scripts/validators", "deployment/scripts/download_asset",
         "deployment/platform/*/setup", "deployment/signing/*/setup"]),
    "ensure_asset_name": (
        ["PLATFORMS"],
        ["deployment/scripts/ensure_asset_name"]),
    "record_rollout_state": (
        ["DISTRIBUTION_LAYER", "CHANNEL", "RELEASE_SEMVER"],
        ["deployment/scripts/record_rollout_state"]),
    "instance_list": (
        ["DISTRIBUTION_LAYER", "PLATFORMS", "FIREBASE_APP_ID_ANDROID", "FIREBASE_APP_ID_IOS",
         "GOOGLE_APPLICATION_CREDENTIALS", "WORKDIR"],
        ["instance/scripts/list", "deployment/distribution/*/list_releases",
         "deployment/scripts/firebase_access_token"]),
}


def load(path, scope):
    with open(path) as f:
        workflow = yaml.safe_load(f) or {}
    steps, configuration = [], {}
    for include in workflow.get("include") or []:
        included_steps, included_configuration = load(include.replace("$SERVICE_PATH", scope), scope)
        steps = merge(steps, included_steps)
        configuration.update(included_configuration)
    configuration.update(workflow.get("configuration") or {})
    return merge(steps, workflow.get("steps") or []), configuration


def merge(base, overrides):
    base = list(base)
    for step in overrides:
        names = [s.get("name") for s in base]
        if step.get("before") in names:
            base.insert(names.index(step["before"]), step)
        elif step.get("after") in names:
            base.insert(names.index(step["after"]) + 1, step)
        elif step.get("name") in names:
            base[names.index(step["name"])] = step
        else:
            base.append(step)
    return base


def consumer_key(step):
    file = os.path.basename(step.get("file", ""))
    configuration = step.get("configuration") or {}
    if file == "layer_executor":
        prefix = "check" if str(configuration.get("LAYER_CHECK", "")).lower() == "true" else "layer"
        return f"{prefix}:{configuration.get('LAYER_TYPE')}"
    if file == "list" and "/instance/" in step.get("file", ""):
        return "instance_list"
    return file


def outputs(step):
    return {o["name"] for o in step.get("output") or [] if o.get("type") == "environment"}


def check_files(scope, steps, path):
    errors = []
    for step in steps:
        if step.get("type") != "script":
            continue
        file = step.get("file", "").replace("$SERVICE_PATH", scope)
        if not os.path.isfile(file):
            errors.append(f"{path}: step '{step.get('name')}' runs a missing file {step.get('file')}")
    return errors


def check_outputs(scope, steps, configuration, path):
    errors, available = [], set(ENGINE_PROVIDED) | set(configuration)
    for step in steps:
        key = consumer_key(step)
        for var in CONSUMES.get(key, ([], []))[0]:
            if var not in available:
                errors.append(f"{path}: step '{step.get('name')}' consumes {var}, which no earlier step declares in its output")
        available |= outputs(step)
    return errors


def check_consumes(scope):
    errors = []
    for key, (variables, patterns) in CONSUMES.items():
        text = ""
        for pattern in patterns:
            files = glob.glob(os.path.join(scope, pattern))
            if not files:
                errors.append(f"{key}: no file matches {pattern}")
            for file in files:
                with open(file) as f:
                    text += f.read()
        for var in variables:
            if var in AWS:
                if not re.search(r"\baws\s", text):
                    errors.append(f"{key}: listed as consuming {var} but never calls aws")
                continue
            # Indirect references: BINARY_PATH_$PLATFORM_UPPER covers BINARY_PATH_ANDROID/IOS.
            stem = re.sub(r"_(ANDROID|IOS)$", "_", var)
            if not re.search(r"\b" + re.escape(var) + r"\b", text) and not (
                    stem != var and re.search(r"\b" + re.escape(stem) + r"\$", text)):
                errors.append(f"{key}: listed as consuming {var} but its files never reference it")
    return errors


def main():
    scope, check, paths = sys.argv[1], sys.argv[2], sys.argv[3:]
    errors = []
    if check == "consumes":
        errors = check_consumes(scope)
    for path in paths:
        steps, configuration = load(path, scope)
        if not steps:
            errors.append(f"{path}: no steps")
        if check == "files":
            errors += check_files(scope, steps, path)
        elif check == "outputs":
            errors += check_outputs(scope, steps, configuration, path)
    for error in errors:
        print(error)
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
