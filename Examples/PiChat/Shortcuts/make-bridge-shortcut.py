#!/usr/bin/env python3
"""Builds and signs "PiChat Bridge.shortcut", the shortcut whose notification automation runs shortcuts for PiChat.

    Examples/PiChat/Shortcuts/make-bridge-shortcut.py [--bundle-id com.example.PiChat] [--team ABCDE12345]

Signing uses `shortcuts sign` (macOS, signed in to iCloud). The output goes to PiChat/, where the app bundles it.
The automation's logic, keyed on the notification's title (see ShortcutBridge.Command):

    PiChat Bridge Connected                            (marks the bridge as installed; grants access on a manual run)
    If the shortcut was started by a PiChat notification:
        If Title is "Run Shortcut":                    Subtitle = request ID, Body = shortcut name
            Input  = PiChat Shortcut Input (Subtitle)
            Output = Run Shortcut (Body) with Input
            PiChat Shortcut Output (Subtitle, Output)
        If Title is "List Shortcuts":
            PiChat Shortcut List (Get My Shortcuts)
"""

import argparse
import pathlib
import plistlib
import subprocess
import tempfile
import uuid

HERE = pathlib.Path(__file__).resolve().parent
OUTPUT = HERE.parent / "PiChat" / "PiChat Bridge.shortcut"


def ident():
    return str(uuid.uuid4()).upper()


def trigger_output(prop=None):
    value = {"Type": "TriggerOutput", "TriggerIdentifier": "WFNotificationTrigger"}
    if prop:
        value["Aggrandizements"] = [{"Type": "WFPropertyVariableAggrandizement", "PropertyName": prop}]
    return value


def attachment(value):
    return {"Value": value, "WFSerializationType": "WFTextTokenAttachment"}


def token_string(value):
    return {"Value": {"string": "\ufffc", "attachmentsByRange": {"{0, 1}": value}}, "WFSerializationType": "WFTextTokenString"}


def action_output(uuid_, name):
    return {"Type": "ActionOutput", "OutputUUID": uuid_, "OutputName": name}


def build(bundle_id, team):
    app = {"BundleIdentifier": bundle_id, "Name": "PiChat"}
    if team:
        app["TeamIdentifier"] = team

    def intent(name, **parameters):
        return {
            "WFWorkflowActionIdentifier": f"{bundle_id}.{name}",
            "WFWorkflowActionParameters": {
                "UUID": parameters.pop("UUID", ident()),
                "AppIntentDescriptor": {**app, "AppIntentIdentifier": name},
                **parameters,
            },
        }

    def action(identifier, **parameters):
        return {"WFWorkflowActionIdentifier": f"is.workflow.actions.{identifier}", "WFWorkflowActionParameters": parameters}

    def if_title(title, body):
        group = ident()
        return [
            action(
                "conditional",
                WFInput={"Type": "Variable", "Variable": attachment(trigger_output("Title"))},
                WFControlFlowMode=0,
                WFCondition=4,
                WFConditionalActionString=title,
                GroupingIdentifier=group,
            ),
            *body,
            action("exit"),
            action("conditional", WFControlFlowMode=2, GroupingIdentifier=group, UUID=ident()),
        ]

    input_uuid, output_uuid, list_uuid = ident(), ident(), ident()
    request = token_string(trigger_output("Subtitle"))
    run = if_title("Run Shortcut", [
        intent("ShortcutInputIntent", UUID=input_uuid, request=request),
        action(
            "runworkflow",
            UUID=output_uuid,
            WFWorkflow=attachment(trigger_output("Body")),
            WFWorkflowName=attachment(trigger_output("Body")),
            WFInput=attachment(action_output(input_uuid, "PiChat Shortcut Input")),
        ),
        intent("ShortcutOutputIntent", request=request, output=token_string(action_output(output_uuid, "Shortcut Result"))),
    ])
    listing = if_title("List Shortcuts", [
        action("getmyworkflows", UUID=list_uuid),
        intent("ShortcutListIntent", shortcuts=token_string(action_output(list_uuid, "My Shortcuts"))),
    ])
    started_by_notification = ident()
    actions = [
        action("comment", WFCommentActionText=(
            "Runs shortcuts for PiChat's agent. Turn on the notification automation above, set it to run "
            "immediately, then run this shortcut once and allow it to access PiChat. PiChat only runs the "
            "shortcuts you allow in its Shortcuts settings."
        )),
        intent("BridgeConnectedIntent"),
        action(
            "conditional",
            WFInput={"Type": "Variable", "Variable": attachment(trigger_output())},
            WFControlFlowMode=0,
            WFCondition=100,
            GroupingIdentifier=started_by_notification,
        ),
        *run,
        *listing,
        action("conditional", WFControlFlowMode=2, GroupingIdentifier=started_by_notification, UUID=ident()),
    ]
    return {
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowClientVersion": "5037.109",
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 61440},
        "WFWorkflowHasShortcutInputVariables": True,
        "WFWorkflowHasOutputFallback": False,
        "WFWorkflowInputContentItemClasses": ["WFStringContentItem"],
        "WFWorkflowOutputContentItemClasses": [],
        "WFWorkflowTypes": [],
        "WFWorkflowImportQuestions": [],
        "WFQuickActionSurfaces": [],
        "WFWorkflowActions": actions,
        "WFWorkflowTriggers": [{
            "WFTriggerIdentifier": "WFNotificationTrigger",
            "WFTriggerUUID": ident(),
            "WFTriggerSerializedParameters": {
                "SelectedApps": app,
                "Conditions": {
                    "Value": {
                        "WFActionParameterFilterPrefix": 1,
                        "WFActionParameterFilterTemplates": [],
                        "WFContentPredicateBoundedDate": False,
                    },
                    "WFSerializationType": "WFContentPredicateTableTemplate",
                },
            },
        }],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bundle-id", default="com.finnvoorhees.PiChat")
    parser.add_argument("--team", default=None, help="the app's team ID (optional)")
    parser.add_argument("--output", type=pathlib.Path, default=OUTPUT)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as directory:
        unsigned = pathlib.Path(directory) / "PiChat Bridge.shortcut"
        unsigned.write_bytes(plistlib.dumps(build(args.bundle_id, args.team), fmt=plistlib.FMT_BINARY))
        subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", unsigned, "--output", args.output], check=True)
    print(f"Wrote {args.output}")


if __name__ == "__main__":
    main()
