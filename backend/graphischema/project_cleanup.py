"""Remove application-owned project preferences; exported user files stay separate."""
import base64
import fcntl
import json
import os
from pathlib import Path
import tempfile

from .paths import config_directory


def cleanup_project_artifacts(store, project_ids):
    project_ids = set(project_ids)
    directory = config_directory()
    settings_file = directory/"settings.json"
    if settings_file.exists():
        with (directory/"settings.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            settings = json.loads(settings_file.read_text(encoding="utf-8"))
            for project_id in project_ids:
                for prefix in ("GraphiSchema.projectFile.", "GraphiSchema.themeMode."):
                    settings.pop(prefix+project_id, None)
            value = settings.get("GraphiSchema.lastWorkspace")
            if isinstance(value, dict) and "$data" in value:
                workspace = json.loads(base64.b64decode(value["$data"]))
                if workspace.get("projectId") in project_ids:
                    settings.pop("GraphiSchema.lastWorkspace", None)
            legacy_path = settings.get("GraphiSchema.projectFile")
            if isinstance(legacy_path, str) and _project_id(Path(legacy_path)) in project_ids:
                settings.pop("GraphiSchema.projectFile", None)
            descriptor, temporary = tempfile.mkstemp(prefix=".settings-cleanup-", dir=directory)
            try:
                with os.fdopen(descriptor, "w", encoding="utf-8") as output:
                    json.dump(settings, output, ensure_ascii=False, indent=2, sort_keys=True)
                os.replace(temporary, settings_file)
            finally:
                Path(temporary).unlink(missing_ok=True)
    if _project_id(store.project_file) in project_ids:
        store.project_file.unlink(missing_ok=True)


def _project_id(path):
    try:
        return json.loads(path.read_text(encoding="utf-8")).get("project", {}).get("id")
    except (OSError, ValueError, AttributeError):
        return None
