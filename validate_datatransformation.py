#!/usr/bin/env python3
"""
Validator for Vlocity DataPack DataTransformation.json files.

Validates the JSON structure against a known schema for Salesforce Vlocity
OmniDataTransform (DataRaptor) export configuration files. Checks:
  - Valid JSON syntax
  - All required top-level and nested fields are present
  - Correct data types for every field
  - Nested structures (dataPacks, OmniDataTransform, OmniDataTransformItem)

Usage:
    python validate_datatransformation.py [path_to_json]

If no path is given, defaults to DataTransformation.json in the same directory.
"""

import json
import sys
import os

try:
    from jsonschema import Draft7Validator
except ImportError:
    sys.exit("ERROR: 'jsonschema' package is required. Install with: pip install jsonschema")


# ---------------------------------------------------------------------------
# Schema definition for Vlocity DataPack DataTransformation.json
# ---------------------------------------------------------------------------

OMNI_DATA_TRANSFORM_ID_SCHEMA = {
    "type": "object",
    "description": "Reference to the parent OmniDataTransform record.",
    "required": [
        "VlocityRecordSObjectType",
        "VlocityDataPackType",
        "VlocityMatchingRecordSourceKey",
        "Name",
    ],
    "properties": {
        "VlocityRecordSObjectType": {"type": "string"},
        "VlocityDataPackType": {"type": "string"},
        "VlocityMatchingRecordSourceKey": {"type": "string"},
        "Name": {"type": "string"},
    },
    "additionalProperties": False,
}

OMNI_DATA_TRANSFORM_ITEM_SCHEMA = {
    "type": "object",
    "description": "An individual field mapping / transformation item.",
    "required": [
        "Name",
        "VlocityDataPackType",
        "VlocityRecordSObjectType",
        "VlocityDataPackIsIncluded",
        "VlocityRecordSourceKey",
        "GlobalKey",
        "Id",
        "InputObjectName",
        "InputFieldName",
        "InputObjectQuerySequence",
        "OutputObjectName",
        "OutputFieldName",
        "OutputCreationSequence",
        "IsDisabled",
        "IsRequiredForUpsert",
        "IsUpsertKey",
        "FilterGroup",
        "OmniDataTransformationId",
    ],
    "properties": {
        "Name": {"type": "string"},
        "VlocityDataPackType": {"type": "string", "enum": ["SObject"]},
        "VlocityRecordSObjectType": {
            "type": "string",
            "enum": ["OmniDataTransformItem"],
        },
        "VlocityDataPackIsIncluded": {"type": "boolean"},
        "VlocityRecordSourceKey": {"type": "string"},
        "GlobalKey": {"type": "string"},
        "Id": {"type": "string"},
        "InputObjectName": {"type": "string"},
        "InputFieldName": {"type": "string"},
        "InputObjectQuerySequence": {"type": "integer"},
        "OutputObjectName": {"type": "string"},
        "OutputFieldName": {"type": "string"},
        "OutputCreationSequence": {"type": "integer"},
        "OutputFieldFormat": {"type": "string"},
        "IsDisabled": {"type": "boolean"},
        "IsRequiredForUpsert": {"type": "boolean"},
        "IsUpsertKey": {"type": "boolean"},
        "FilterGroup": {"type": "integer"},
        "FilterOperator": {"type": "string"},
        "FilterValue": {"type": "string"},
        "FilterDataType": {"type": "string"},
        "DefaultValue": {"type": "string"},
        "FormulaExpression": {"type": "string"},
        "FormulaResultPath": {"type": "string"},
        "FormulaSequence": {"type": ["string", "integer"]},
        "LinkedFieldName": {"type": "string"},
        "LinkedObjectSequence": {"type": ["string", "integer"]},
        "LookupByFieldName": {"type": "string"},
        "LookupObjectName": {"type": "string"},
        "LookupReturnedFieldName": {"type": "string"},
        "TransformValueMappings": {"type": "string"},
        "MigrationAttribute": {"type": "string"},
        "MigrationCategory": {"type": "string"},
        "MigrationGroup": {"type": "string"},
        "MigrationKey": {"type": "string"},
        "MigrationPattern": {"type": "string"},
        "MigrationProcess": {"type": "string"},
        "MigrationType": {"type": "string"},
        "MigrationValue": {"type": "string"},
        "OmniDataTransformationId": OMNI_DATA_TRANSFORM_ID_SCHEMA,
    },
}

OMNI_DATA_TRANSFORM_SCHEMA = {
    "type": "object",
    "description": "OmniDataTransform (DataRaptor) definition.",
    "required": [
        "Name",
        "VlocityDataPackType",
        "VlocityRecordSObjectType",
        "VlocityDataPackIsIncluded",
        "VlocityRecordSourceKey",
        "Id",
        "Type",
        "SourceObject",
        "InputType",
        "OutputType",
        "IsActive",
        "VersionNumber",
        "OmniDataTransformItem",
    ],
    "properties": {
        "Name": {"type": "string"},
        "VlocityDataPackType": {"type": "string", "enum": ["SObject"]},
        "VlocityRecordSObjectType": {
            "type": "string",
            "enum": ["OmniDataTransform"],
        },
        "VlocityDataPackIsIncluded": {"type": "boolean"},
        "VlocityRecordSourceKey": {"type": "string"},
        "GlobalKey": {"type": "string"},
        "Id": {"type": "string"},
        "Type": {
            "type": "string",
            "enum": ["Extract", "Transform", "Load"],
            "description": "DataRaptor type: Extract, Transform, or Load.",
        },
        "SourceObject": {"type": "string"},
        "InputType": {"type": "string"},
        "OutputType": {"type": "string"},
        "IsActive": {"type": "boolean"},
        "VersionNumber": {"type": "integer", "minimum": 1},
        "Description": {"type": "string"},
        "Namespace": {"type": "string"},
        "UniqueName": {"type": "string"},
        "BatchSize": {"type": ["string", "integer"]},
        "IsRollbackOnError": {"type": "boolean"},
        "IsErrorIgnored": {"type": "boolean"},
        "IsDeletedOnSuccess": {"type": "boolean"},
        "IsProcessSuperBulk": {"type": "boolean"},
        "IsAssignmentRulesUsed": {"type": "boolean"},
        "IsXmlDeclarationRemoved": {"type": "boolean"},
        "IsSourceObjectDefault": {"type": "boolean"},
        "IsFieldLevelSecurityEnabled": {"type": "boolean"},
        "IsNullInputsIncludedInOutput": {"type": "boolean"},
        "RequiredPermission": {"type": "string"},
        "OverrideKey": {"type": "string"},
        "SynchronousProcessThreshold": {"type": ["string", "integer"]},
        "ResponseCacheType": {"type": "string"},
        "ResponseCacheTtlMinutes": {"type": ["string", "integer"]},
        "InputParsingClass": {"type": "string"},
        "OutputParsingClass": {"type": "string"},
        "PreprocessorClassName": {"type": "string"},
        "XmlOutputTagsOrder": {"type": "string"},
        "TargetOutputDocumentIdentifier": {"type": "string"},
        "TargetOutputFileName": {"type": "string"},
        "PreviewJsonData": {"type": "string"},
        "PreviewXmlData": {"type": "string"},
        "PreviewOtherData": {"type": "string"},
        "PreviewSourceObjectData": {"type": "string"},
        "ExpectedInputJson": {"type": "string"},
        "ExpectedInputXml": {"type": "string"},
        "ExpectedInputOtherData": {"type": "string"},
        "ExpectedOutputJson": {"type": "string"},
        "ExpectedOutputXml": {"type": "string"},
        "ExpectedOutputOtherData": {"type": "string"},
        "OmniDataTransformItem": {
            "type": "array",
            "items": OMNI_DATA_TRANSFORM_ITEM_SCHEMA,
            "minItems": 1,
            "description": "List of field-mapping items. At least one is required.",
        },
    },
}

VLOCITY_DATA_PACK_DATA_SCHEMA = {
    "type": "object",
    "description": "Container for the exported DataRaptor definitions.",
    "required": ["OmniDataTransform"],
    "properties": {
        "OmniDataTransform": {
            "type": "array",
            "items": OMNI_DATA_TRANSFORM_SCHEMA,
            "minItems": 1,
        },
        "Id": {"type": "string"},
        "VlocityDataPackRelationshipType": {"type": "string"},
        "VlocityDataPackLabel": {"type": "string"},
        "VlocityDataPackType": {"type": "string"},
        "VlocityDataPackKey": {"type": "string"},
        "VlocityDataPackIsIncluded": {"type": "boolean"},
    },
}

DATA_PACK_ENTRY_SCHEMA = {
    "type": "object",
    "description": "A single DataPack entry in the export.",
    "required": [
        "VlocityPrimarySourceId",
        "VlocityDepthFromPrimary",
        "VlocityDataPackType",
        "VlocityDataPackStatus",
        "VlocityDataPackRelationshipType",
        "VlocityDataPackName",
        "VlocityDataPackLabel",
        "VlocityDataPackKey",
        "VlocityDataPackIsNotSupported",
        "VlocityDataPackIsIncluded",
        "VlocityDataPackData",
        "VlocityDataPackAllRelationships",
        "DataPackAttachmentSize",
        "DataPackAttachmentParentId",
        "DataPackAttachmentId",
        "ActivationStatus",
    ],
    "properties": {
        "VlocityPrimarySourceId": {"type": "string"},
        "VlocityPreviousPageKey": {"type": ["string", "null"]},
        "VlocityMultiPackParentKey": {"type": ["string", "null"]},
        "VlocityDepthFromPrimary": {"type": "integer", "minimum": 0},
        "VlocityDataPackType": {"type": "string"},
        "VlocityDataPackStatus": {
            "type": "string",
            "enum": ["Success", "Error", "Ready", "InProgress", "Ignored"],
        },
        "VlocityDataPackRelationshipType": {"type": "string"},
        "VlocityDataPackRecords": {"type": "array"},
        "VlocityDataPackParents": {"type": "array"},
        "VlocityDataPackName": {"type": "string"},
        "VlocityDataPackMessage": {"type": ["string", "null"]},
        "VlocityDataPackLabel": {"type": "string"},
        "VlocityDataPackKey": {"type": "string"},
        "VlocityDataPackIsNotSupported": {"type": "boolean"},
        "VlocityDataPackIsIncluded": {"type": "boolean"},
        "VlocityDataPackData": VLOCITY_DATA_PACK_DATA_SCHEMA,
        "VlocityDataPackAllRelationships": {"type": "object"},
        "DataPackAttachmentSize": {"type": "integer", "minimum": 0},
        "DataPackAttachmentParentId": {"type": "string"},
        "DataPackAttachmentId": {"type": "string"},
        "ActivationStatus": {"type": "string"},
    },
}

TOP_LEVEL_SCHEMA = {
    "$schema": "http://json-schema.org/draft-07/schema#",
    "title": "Vlocity DataPack DataTransformation Export",
    "description": (
        "Schema for Salesforce Vlocity OmniDataTransform (DataRaptor) "
        "DataPack export files."
    ),
    "type": "object",
    "required": [
        "useVlocityTriggers",
        "status",
        "processMultiple",
        "primaryDataPackType",
        "primaryDataPackKey",
        "maxDepth",
        "isChunked",
        "ignoreAllErrors",
        "forceQueueable",
        "dataPacks",
        "dataPackId",
        "alreadyExportedKeys",
        "name",
        "description",
        "version",
    ],
    "properties": {
        "useVlocityTriggers": {"type": "boolean"},
        "status": {
            "type": "string",
            "enum": ["Complete", "Ready", "Error", "InProgress"],
        },
        "processMultiple": {"type": "boolean"},
        "primaryDataPackType": {"type": "string"},
        "primaryDataPackKey": {"type": "string"},
        "maxDepth": {"type": "integer"},
        "isChunked": {"type": "boolean"},
        "ignoreAllErrors": {"type": "boolean"},
        "forceQueueable": {"type": "boolean"},
        "forceOldDataModel": {"type": ["boolean", "null"]},
        "dataPacks": {
            "type": "array",
            "items": DATA_PACK_ENTRY_SCHEMA,
            "minItems": 1,
            "description": "Must contain at least one DataPack entry.",
        },
        "dataPackId": {"type": "string"},
        "alreadyExportedKeys": {"type": "array", "items": {"type": "string"}},
        "name": {"type": "string", "minLength": 1},
        "description": {"type": "string"},
        "version": {"type": "integer", "minimum": 1},
    },
    "additionalProperties": False,
}


# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------

def run_semantic_checks(data):
    """Additional semantic checks beyond what JSON Schema covers."""
    issues = []

    # Check top-level name matches DataPack name
    top_name = data.get("name", "")
    for i, dp in enumerate(data.get("dataPacks", [])):
        dp_name = dp.get("VlocityDataPackName", "")
        if top_name and dp_name and top_name != dp_name:
            issues.append(
                f"  WARNING: Top-level 'name' ({top_name!r}) differs from "
                f"dataPacks[{i}].VlocityDataPackName ({dp_name!r})."
            )

        # Check OmniDataTransformItem references match parent
        dp_data = dp.get("VlocityDataPackData", {})
        for j, transform in enumerate(dp_data.get("OmniDataTransform", [])):
            t_name = transform.get("Name", "")
            t_source_key = transform.get("VlocityRecordSourceKey", "")

            for k, item in enumerate(transform.get("OmniDataTransformItem", [])):
                ref = item.get("OmniDataTransformationId", {})
                ref_source_key = ref.get("VlocityMatchingRecordSourceKey", "")
                if t_source_key and ref_source_key and t_source_key != ref_source_key:
                    issues.append(
                        f"  WARNING: OmniDataTransformItem[{k}] "
                        f"(GlobalKey={item.get('GlobalKey', '?')}) has "
                        f"OmniDataTransformationId.VlocityMatchingRecordSourceKey "
                        f"({ref_source_key!r}) that does not match parent "
                        f"VlocityRecordSourceKey ({t_source_key!r})."
                    )

                # Verify InputObjectQuerySequence is positive
                seq = item.get("InputObjectQuerySequence")
                if isinstance(seq, int) and seq < 1:
                    issues.append(
                        f"  WARNING: OmniDataTransformItem[{k}] "
                        f"(GlobalKey={item.get('GlobalKey', '?')}) has "
                        f"InputObjectQuerySequence={seq}, expected >= 1."
                    )

            # Verify Type vs InputType/OutputType consistency
            t_type = transform.get("Type", "")
            input_type = transform.get("InputType", "")
            output_type = transform.get("OutputType", "")
            if t_type == "Extract" and output_type not in ("JSON", "XML", "Custom"):
                issues.append(
                    f"  WARNING: Transform '{t_name}' is type 'Extract' but "
                    f"OutputType is '{output_type}' (expected JSON, XML, or Custom)."
                )

    return issues


def validate_file(filepath):
    """Validate a DataTransformation.json file. Returns (success, report)."""
    report_lines = []
    report_lines.append(f"{'=' * 70}")
    report_lines.append(f"Validating: {filepath}")
    report_lines.append(f"{'=' * 70}")

    # 1. Check file exists
    if not os.path.isfile(filepath):
        report_lines.append(f"FAIL: File not found: {filepath}")
        return False, "\n".join(report_lines)

    # 2. Parse JSON
    report_lines.append("\n[1/4] JSON Syntax Check")
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            data = json.load(f)
        report_lines.append("  PASS: Valid JSON syntax.")
    except json.JSONDecodeError as e:
        report_lines.append(f"  FAIL: Invalid JSON syntax - {e}")
        return False, "\n".join(report_lines)

    # 3. Schema validation
    report_lines.append("\n[2/4] JSON Schema Validation (structure, required fields, data types)")
    validator = Draft7Validator(TOP_LEVEL_SCHEMA)
    errors = sorted(validator.iter_errors(data), key=lambda e: list(e.absolute_path))

    if not errors:
        report_lines.append("  PASS: All required fields present with correct data types.")
    else:
        for err in errors:
            path = " -> ".join(str(p) for p in err.absolute_path) or "(root)"
            report_lines.append(f"  FAIL [{path}]: {err.message}")

    # 4. Summarize structure
    report_lines.append("\n[3/4] Structure Summary")
    num_datapacks = len(data.get("dataPacks", []))
    report_lines.append(f"  Top-level name       : {data.get('name', 'N/A')}")
    report_lines.append(f"  Status               : {data.get('status', 'N/A')}")
    report_lines.append(f"  Version              : {data.get('version', 'N/A')}")
    report_lines.append(f"  Primary DataPack Type: {data.get('primaryDataPackType', 'N/A')}")
    report_lines.append(f"  Number of DataPacks  : {num_datapacks}")
    for i, dp in enumerate(data.get("dataPacks", [])):
        dp_data = dp.get("VlocityDataPackData", {})
        transforms = dp_data.get("OmniDataTransform", [])
        report_lines.append(f"  DataPack[{i}]:")
        report_lines.append(f"    Type   : {dp.get('VlocityDataPackType', 'N/A')}")
        report_lines.append(f"    Name   : {dp.get('VlocityDataPackName', 'N/A')}")
        report_lines.append(f"    Status : {dp.get('VlocityDataPackStatus', 'N/A')}")
        report_lines.append(f"    Transforms: {len(transforms)}")
        for j, t in enumerate(transforms):
            items = t.get("OmniDataTransformItem", [])
            report_lines.append(f"      Transform[{j}]: {t.get('Name', 'N/A')}")
            report_lines.append(f"        Type        : {t.get('Type', 'N/A')}")
            report_lines.append(f"        Source      : {t.get('SourceObject', 'N/A')}")
            report_lines.append(f"        Input/Output: {t.get('InputType', '?')} -> {t.get('OutputType', '?')}")
            report_lines.append(f"        Active      : {t.get('IsActive', 'N/A')}")
            report_lines.append(f"        Items       : {len(items)}")
            for k, item in enumerate(items):
                report_lines.append(
                    f"          Item[{k}]: {item.get('InputObjectName', '?')}"
                    f".{item.get('InputFieldName', '?')} -> "
                    f"{item.get('OutputObjectName', '?')}"
                    f".{item.get('OutputFieldName', '?')}"
                )

    # 5. Semantic checks
    report_lines.append("\n[4/4] Semantic Checks")
    semantic_issues = run_semantic_checks(data)
    if not semantic_issues:
        report_lines.append("  PASS: All semantic checks passed.")
    else:
        report_lines.extend(semantic_issues)

    # Final verdict
    report_lines.append(f"\n{'=' * 70}")
    total_schema_errors = len(errors)
    total_semantic_warnings = len(semantic_issues)
    if total_schema_errors == 0 and total_semantic_warnings == 0:
        report_lines.append("RESULT: PASS - File is valid.")
    elif total_schema_errors == 0:
        report_lines.append(
            f"RESULT: PASS with {total_semantic_warnings} warning(s) - "
            "Structure is valid but there are semantic warnings."
        )
    else:
        report_lines.append(
            f"RESULT: FAIL - {total_schema_errors} schema error(s), "
            f"{total_semantic_warnings} semantic warning(s)."
        )
    report_lines.append(f"{'=' * 70}")

    success = total_schema_errors == 0
    return success, "\n".join(report_lines)


def main():
    if len(sys.argv) > 1:
        filepath = sys.argv[1]
    else:
        filepath = os.path.join(os.path.dirname(os.path.abspath(__file__)), "DataTransformation.json")

    success, report = validate_file(filepath)
    print(report)
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
