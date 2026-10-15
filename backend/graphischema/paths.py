"""Application paths and non-destructive SQLite migration from older builds."""
import os
from pathlib import Path
import sqlite3
import fcntl

def config_directory():
    return Path(os.environ.get("GRAPHI_SCHEMA_CONFIG_DIR", Path.home()/".config"/"graphischema")).expanduser()

def data_directory():
    return Path(os.environ.get("GRAPHI_SCHEMA_DATA_DIR", config_directory()/"projects")).expanduser()

def migrate_legacy_database(destination):
    if destination.parent != config_directory()/"projects" or os.environ.get("GRAPHI_SCHEMA_DISABLE_MIGRATION") == "1":
        return
    candidates = [Path.home()/"Library"/"Application Support"/"GraphiSchema"/"projects"/"graphischema.sqlite3",
                  Path(__file__).resolve().parents[2]/"data"/"graphischema.sqlite3"]
    for source in candidates:
        if source.exists() and source.resolve() != destination.resolve():
            destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            with destination.with_suffix(".migration.lock").open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                if destination.exists(): return
                temporary = destination.with_suffix(".migration.sqlite3")
                try:
                    with sqlite3.connect(f"file:{source}?mode=ro", uri=True) as old, sqlite3.connect(temporary) as new:
                        old.backup(new)
                    temporary.chmod(0o600)
                    temporary.replace(destination)
                finally:
                    temporary.unlink(missing_ok=True)
            return
