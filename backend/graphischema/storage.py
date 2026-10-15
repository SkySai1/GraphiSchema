"""Project-scoped SQLite snapshots, branch heads and commit ancestry."""
from __future__ import annotations
from contextlib import contextmanager
from contextvars import ContextVar
from pathlib import Path
from uuid import uuid4
import sqlite3
from .legacy_storage import (ProjectStore as LegacyProjectStore, RevisionConflict, VersionNotFound,
                             _serialize, _timestamp, _changed_fields, _element_diff)
from .models import DiagramProject

REQUEST_SCOPE: ContextVar[tuple[str | None, str | None]] = ContextVar("graphischema_workspace", default=(None, None))

class ProjectNotFound(ValueError):
    pass

class ProjectStore(LegacyProjectStore):
    def __init__(self, data_dir: Path, starter_file: Path):
        super().__init__(data_dir, starter_file)
        self._repository_ready = False

    @contextmanager
    def _database(self):
        from .paths import migrate_legacy_database
        if not self.database_file.exists():
            migrate_legacy_database(self.database_file)
        with super()._database() as connection:
            if not self._repository_ready:
                self._migrate_repository(connection)
                self._repository_ready = True
            yield connection

    def _migrate_repository(self, connection):
        connection.execute("BEGIN IMMEDIATE")
        connection.execute("""CREATE TABLE IF NOT EXISTS projects (id TEXT PRIMARY KEY,title TEXT NOT NULL,
            created_at TEXT NOT NULL,updated_at TEXT NOT NULL,origin_project_id TEXT,origin_version_id INTEGER)""")
        connection.execute("""CREATE TABLE IF NOT EXISTS branches (id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,name TEXT NOT NULL COLLATE NOCASE,
            head_version_id INTEGER NOT NULL,base_version_id INTEGER,created_at TEXT NOT NULL,UNIQUE(project_id,name))""")
        connection.execute("CREATE TABLE IF NOT EXISTS workspace_state(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
        columns = {row["name"] for row in connection.execute("PRAGMA table_info(versions)")}
        for name, declaration in (("branch_id", "TEXT"), ("parent_id", "INTEGER"),
                                  ("project_number", "INTEGER"),
                                  ("message", "TEXT NOT NULL DEFAULT ''"), ("source", "TEXT NOT NULL DEFAULT 'edit'")):
            if name not in columns:
                connection.execute(f"ALTER TABLE versions ADD COLUMN {name} {declaration}")
        grouped = {}
        for row in connection.execute("SELECT id,project_id,title,revision,created_at,branch_id,project_number FROM versions ORDER BY id").fetchall():
            grouped.setdefault(row["project_id"], []).append(row)
        for project_id, versions in grouped.items():
            connection.execute("INSERT OR IGNORE INTO projects(id,title,created_at,updated_at) VALUES(?,?,?,?)",
                               (project_id, versions[-1]["title"], versions[0]["created_at"], versions[-1]["created_at"]))
            main = connection.execute("SELECT id FROM branches WHERE project_id=? AND name='main'", (project_id,)).fetchone()
            branch_id = main["id"] if main else "branch_"+uuid4().hex
            if not main:
                connection.execute("INSERT INTO branches(id,project_id,name,head_version_id,created_at) VALUES(?,?,?,?,?)",
                                   (branch_id, project_id, "main", versions[-1]["id"], versions[0]["created_at"]))
            previous = None
            for number, row in enumerate(versions, 1):
                if row["project_number"] is None:
                    connection.execute("UPDATE versions SET project_number=? WHERE id=?", (number, row["id"]))
                if row["branch_id"] is None:
                    connection.execute("UPDATE versions SET branch_id=?,parent_id=?,message=? WHERE id=?",
                                       (branch_id, previous, "Начальный снимок" if previous is None else "Мигрированный снимок", row["id"]))
                previous = row["id"]
        current = connection.execute("SELECT project_id,revision FROM current_project WHERE slot=1").fetchone()
        if connection.execute("SELECT 1 FROM workspace_state WHERE key='project_id'").fetchone() is None:
            main = connection.execute("SELECT id FROM branches WHERE project_id=? AND name='main'", (current["project_id"],)).fetchone()
            snapshot = connection.execute("SELECT id FROM versions WHERE project_id=? AND revision=? ORDER BY id DESC LIMIT 1",
                                          (current["project_id"], current["revision"])).fetchone()
            if snapshot:
                connection.execute("UPDATE branches SET head_version_id=? WHERE id=?", (snapshot["id"], main["id"]))
            self._set_default(connection, current["project_id"], main["id"])
        connection.execute("CREATE INDEX IF NOT EXISTS versions_project_branch ON versions(project_id,branch_id,id DESC)")
        connection.execute("CREATE INDEX IF NOT EXISTS versions_parent ON versions(parent_id)")
        connection.execute("CREATE UNIQUE INDEX IF NOT EXISTS versions_project_number ON versions(project_id,project_number)")
        self._install_repository_constraints(connection)
        connection.commit()

    @staticmethod
    def _install_repository_constraints(connection):
        # Enforce ownership in SQLite as well as in the API. Branch heads and
        # ancestry must never connect repositories belonging to different projects.
        for action in ("INSERT", "UPDATE"):
            connection.execute(f"""CREATE TRIGGER IF NOT EXISTS branches_scope_{action.lower()}
                BEFORE {action} ON branches BEGIN
                SELECT RAISE(ABORT,'branch head belongs to another project') WHERE NOT EXISTS
                    (SELECT 1 FROM versions WHERE id=NEW.head_version_id AND project_id=NEW.project_id);
                SELECT RAISE(ABORT,'branch base belongs to another project') WHERE NEW.base_version_id IS NOT NULL AND NOT EXISTS
                    (SELECT 1 FROM versions WHERE id=NEW.base_version_id AND project_id=NEW.project_id);
                END""")
            connection.execute(f"""CREATE TRIGGER IF NOT EXISTS versions_scope_{action.lower()}
                BEFORE {action} ON versions BEGIN
                SELECT RAISE(ABORT,'commit parent belongs to another project') WHERE NEW.parent_id IS NOT NULL AND NOT EXISTS
                    (SELECT 1 FROM versions WHERE id=NEW.parent_id AND project_id=NEW.project_id);
                SELECT RAISE(ABORT,'commit branch belongs to another project') WHERE EXISTS
                    (SELECT 1 FROM branches WHERE id=NEW.branch_id AND project_id<>NEW.project_id);
                END""")
        connection.execute("""CREATE TRIGGER IF NOT EXISTS versions_project_immutable BEFORE UPDATE OF project_id ON versions
            WHEN NEW.project_id<>OLD.project_id BEGIN SELECT RAISE(ABORT,'commit project is immutable'); END""")

    def _set_default(self, connection, project_id, branch_id):
        for key, value in (("project_id", project_id), ("branch_id", branch_id)):
            connection.execute("INSERT OR REPLACE INTO workspace_state(key,value) VALUES(?,?)", (key, value))

    def _scope(self, connection, project_id=None, branch_id=None):
        requested_project, requested_branch = REQUEST_SCOPE.get()
        project_id, branch_id = project_id or requested_project, branch_id or requested_branch
        if branch_id:
            branch = connection.execute("SELECT * FROM branches WHERE id=?", (branch_id,)).fetchone()
            if branch is None or (project_id and branch["project_id"] != project_id):
                raise ProjectNotFound("Ветка не принадлежит выбранному проекту или не найдена.")
            return branch
        if not project_id:
            state = dict(connection.execute("SELECT key,value FROM workspace_state").fetchall())
            project_id, branch_id = state.get("project_id"), state.get("branch_id")
            if branch_id:
                branch = connection.execute("SELECT * FROM branches WHERE id=? AND project_id=?", (branch_id, project_id)).fetchone()
                if branch:
                    return branch
        branch = connection.execute("SELECT * FROM branches WHERE project_id=? ORDER BY (name='main') DESC,created_at,id LIMIT 1", (project_id,)).fetchone()
        if branch is None:
            raise ProjectNotFound("Проект не найден.")
        return branch

    def workspace(self):
        with self._lock, self._database() as connection:
            return dict(self._scope(connection))

    def load(self):
        with self._lock, self._database() as connection:
            branch = self._scope(connection)
            row = connection.execute("SELECT snapshot FROM versions WHERE id=? AND project_id=?", (branch["head_version_id"], branch["project_id"])).fetchone()
            if row is None:
                raise ProjectNotFound("Снимок текущей ветки не найден.")
            return DiagramProject.model_validate_json(row["snapshot"])

    def _insert_version(self, connection, project, branch_id, parent_id, message, source):
        revision, now = self.revision(project), _timestamp()
        number = connection.execute("SELECT COALESCE(MAX(project_number),0)+1 FROM versions WHERE project_id=?", (project.project.id,)).fetchone()[0]
        cursor = connection.execute("""INSERT INTO versions(project_id,title,revision,snapshot,created_at,branch_id,parent_id,message,source,project_number)
            VALUES(?,?,?,?,?,?,?,?,?,?)""", (project.project.id, project.project.title, revision, _serialize(project), now,
                                         branch_id, parent_id, message, source, number))
        return cursor.lastrowid, revision, now

    def save(self, project, expected_revision=None, *, message="Изменение схемы", source="edit", force_commit=False):
        with self._lock, self._database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            requested_project, requested_branch = REQUEST_SCOPE.get()
            if requested_project and requested_project != project.project.id:
                raise ValueError("ID схемы не совпадает с ID открытого проекта.")
            if connection.execute("SELECT 1 FROM projects WHERE id=?", (project.project.id,)).fetchone() is None:
                if requested_branch:
                    raise ProjectNotFound("Нельзя сохранять другой проект в открытой ветке.")
                self._create_project(connection, project)
                connection.commit()
                return self.revision(project)
            branch = self._scope(connection, project_id=project.project.id, branch_id=requested_branch if requested_project else None)
            current = connection.execute("SELECT revision FROM versions WHERE id=?", (branch["head_version_id"],)).fetchone()
            if expected_revision is not None and expected_revision != current["revision"]:
                raise RevisionConflict("Проект уже изменён в другой вкладке. Обновите данные перед сохранением.")
            revision = self.revision(project)
            if revision != current["revision"] or force_commit:
                version_id, revision, now = self._insert_version(connection, project, branch["id"], branch["head_version_id"], message, source)
                connection.execute("UPDATE branches SET head_version_id=? WHERE id=?", (version_id, branch["id"]))
                connection.execute("UPDATE projects SET title=?,updated_at=? WHERE id=?", (project.project.title, now, project.project.id))
                connection.execute("UPDATE current_project SET project_id=?,snapshot=?,revision=?,updated_at=? WHERE slot=1",
                                   (project.project.id, _serialize(project), revision, now))
            if not requested_project and not requested_branch:
                self._set_default(connection, project.project.id, branch["id"])
            connection.commit()
            return revision

    def _create_project(self, connection, project, origin_project_id=None, origin_version_id=None, *, source="create", message="Новый проект"):
        now, branch_id = _timestamp(), "branch_"+uuid4().hex
        connection.execute("INSERT INTO projects(id,title,created_at,updated_at,origin_project_id,origin_version_id) VALUES(?,?,?,?,?,?)",
                           (project.project.id, project.project.title, now, now, origin_project_id, origin_version_id))
        version_id, _, _ = self._insert_version(connection, project, branch_id, None, message, source)
        connection.execute("INSERT INTO branches(id,project_id,name,head_version_id,created_at) VALUES(?,?,?,?,?)", (branch_id, project.project.id, "main", version_id, now))
        if REQUEST_SCOPE.get() == (None, None):
            self._set_default(connection, project.project.id, branch_id)
        return {"projectId": project.project.id, "branchId": branch_id}

    def create_project(self, title, template=None, *, origin_project_id=None, origin_version_id=None):
        project = template.model_copy(deep=True) if template else DiagramProject()
        project.project.id, project.project.title = "project_"+uuid4().hex, title.strip()
        project = DiagramProject.model_validate(project.model_dump())
        with self._lock, self._database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            result = self._create_project(connection, project, origin_project_id, origin_version_id)
            connection.commit()
            return result

    def import_project(self, project):
        """Import a portable snapshot as an independent repository, even on ID collision."""
        project = project.model_copy(deep=True)
        origin_id, project.project.id = project.project.id, "project_"+uuid4().hex
        with self._lock, self._database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            workspace = self._create_project(connection, project, origin_project_id=origin_id,
                                             message="Импорт JSON · новый проект", source="import")
            connection.commit()
            return workspace

    def open_project(self, project):
        """Resume a known JSON project; retain divergent file contents in its own branch."""
        with self._lock, self._database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            project_id = project.project.id
            if connection.execute("SELECT 1 FROM projects WHERE id=?", (project_id,)).fetchone() is None:
                workspace = self._create_project(connection, project, source="import", message="Открытие JSON")
            else:
                branch = connection.execute("""SELECT b.* FROM branches b JOIN versions v ON v.id=b.head_version_id
                    WHERE b.project_id=? AND v.revision=? ORDER BY (b.name='main') DESC,b.created_at,b.id LIMIT 1""",
                    (project_id, self.revision(project))).fetchone()
                if branch is None:
                    main = connection.execute("SELECT * FROM branches WHERE project_id=? ORDER BY (name='main') DESC,created_at,id LIMIT 1", (project_id,)).fetchone()
                    branch_id = "branch_"+uuid4().hex
                    version_id, _, _ = self._insert_version(connection, project, branch_id, main["head_version_id"], "Открытие изменённого JSON", "import")
                    connection.execute("INSERT INTO branches(id,project_id,name,head_version_id,base_version_id,created_at) VALUES(?,?,?,?,?,?)",
                                       (branch_id, project_id, "Файл "+uuid4().hex[:8], version_id, main["head_version_id"], _timestamp()))
                else:
                    branch_id = branch["id"]
                workspace = {"projectId": project_id, "branchId": branch_id}
            connection.commit()
            return workspace

    def list_projects(self):
        with self._lock, self._database() as connection:
            rows = connection.execute("""SELECT p.*,COUNT(b.id) AS branch_count FROM projects p LEFT JOIN branches b ON b.project_id=p.id
                GROUP BY p.id ORDER BY p.updated_at DESC,p.id""").fetchall()
            return [{"id": r["id"], "title": r["title"], "createdAt": r["created_at"], "updatedAt": r["updated_at"],
                     "branchCount": r["branch_count"], "originProjectId": r["origin_project_id"], "originVersionId": r["origin_version_id"]} for r in rows]

    def list_branches(self, project_id=None):
        with self._lock, self._database() as connection:
            project_id = project_id or self._scope(connection)["project_id"]
            rows = connection.execute("""SELECT b.*,v.revision,v.project_number FROM branches b JOIN versions v ON v.id=b.head_version_id AND v.project_id=b.project_id
                WHERE b.project_id=? ORDER BY (b.name='main') DESC,b.created_at,b.id""", (project_id,)).fetchall()
            return [{"id": r["id"], "projectId": r["project_id"], "name": r["name"], "headVersionId": r["head_version_id"],
                     "headVersionNumber": r["project_number"], "baseVersionId": r["base_version_id"], "revision": r["revision"], "createdAt": r["created_at"]} for r in rows]

    def create_branch(self, name, from_version_id=None):
        name = name.strip()
        if not name or len(name) > 80 or any(ord(character) < 32 for character in name):
            raise ValueError("Название ветки должно содержать от 1 до 80 символов.")
        with self._lock, self._database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            current = self._scope(connection)
            names = connection.execute("SELECT name FROM branches WHERE project_id=?", (current["project_id"],)).fetchall()
            if any(row["name"].casefold() == name.casefold() for row in names):
                raise ValueError("Ветка с таким названием уже существует.")
            version_id = current["head_version_id"] if from_version_id is None else from_version_id
            if connection.execute("SELECT id FROM versions WHERE id=? AND project_id=?", (version_id, current["project_id"])).fetchone() is None:
                raise VersionNotFound("Нельзя создать ветку от снимка другого проекта.")
            branch_id = "branch_"+uuid4().hex
            try:
                connection.execute("INSERT INTO branches(id,project_id,name,head_version_id,base_version_id,created_at) VALUES(?,?,?,?,?,?)",
                                   (branch_id, current["project_id"], name, version_id, version_id, _timestamp()))
            except sqlite3.IntegrityError as exc:
                raise ValueError("Ветка с таким названием уже существует.") from exc
            connection.commit()
            return {"projectId": current["project_id"], "branchId": branch_id}

    def _version_metadata(self, row):
        return {"id": row["id"], "projectId": row["project_id"], "title": row["title"], "revision": row["revision"], "createdAt": row["created_at"],
                "branchId": row["branch_id"], "parentId": row["parent_id"], "message": row["message"], "source": row["source"], "projectNumber": row["project_number"]}

    def list_versions(self, limit=100):
        with self._lock, self._database() as connection:
            branch = self._scope(connection)
            result, seen, version_id = [], set(), branch["head_version_id"]
            while version_id and version_id not in seen and len(result) < max(1, min(limit, 10000)):
                seen.add(version_id)
                row = connection.execute("SELECT id,project_id,title,revision,created_at,branch_id,parent_id,message,source,project_number FROM versions WHERE id=? AND project_id=?", (version_id, branch["project_id"])).fetchone()
                if row is None:
                    break
                result.append(self._version_metadata(row))
                version_id = row["parent_id"]
            return result

    def commit_tree(self):
        with self._lock, self._database() as connection:
            branch = self._scope(connection)
            rows = connection.execute("SELECT id,project_id,title,revision,created_at,branch_id,parent_id,message,source,project_number FROM versions WHERE project_id=? ORDER BY id DESC", (branch["project_id"],)).fetchall()
            result = {"projectId": branch["project_id"], "activeBranchId": branch["id"], "commits": [self._version_metadata(row) for row in rows]}
            result["branches"] = self.list_branches(branch["project_id"])
            return result

    def get_version(self, version_id):
        with self._lock, self._database() as connection:
            project_id = self._scope(connection)["project_id"]
            row = connection.execute("SELECT snapshot FROM versions WHERE id=? AND project_id=?", (version_id, project_id)).fetchone()
            if row is None:
                raise VersionNotFound(f"Снимок версии {version_id} не найден в выбранном проекте.")
            return DiagramProject.model_validate_json(row["snapshot"])

    def get_version_number(self, version_id):
        with self._lock, self._database() as connection:
            project_id = self._scope(connection)["project_id"]
            row = connection.execute("SELECT project_number FROM versions WHERE id=? AND project_id=?", (version_id, project_id)).fetchone()
            if row is None:
                raise VersionNotFound("Коммит не найден в выбранном проекте.")
            return row["project_number"]

    def get_project_at_revision(self, revision):
        with self._lock, self._database() as connection:
            project_id = self._scope(connection)["project_id"]
            row = connection.execute("SELECT snapshot FROM versions WHERE revision=? AND project_id=? ORDER BY id DESC LIMIT 1", (revision, project_id)).fetchone()
            if row:
                return DiagramProject.model_validate_json(row["snapshot"])
            row = connection.execute("SELECT snapshot FROM revision_aliases WHERE legacy_revision=?", (revision,)).fetchone()
            if row:
                project = DiagramProject.model_validate_json(row["snapshot"])
                return project if project.project.id == project_id else None
            return None

    def diff_version(self, version_id):
        baseline, current = self.get_version(version_id), self.load()
        with self._lock, self._database() as connection:
            row = connection.execute("SELECT title,revision FROM versions WHERE id=?", (version_id,)).fetchone()
        return {"versionId": version_id, "versionTitle": row["title"], "baseRevision": row["revision"], "currentRevision": self.revision(current),
                "project": _changed_fields(baseline.project.model_dump(), current.project.model_dump()),
                "diagram": _changed_fields(baseline.diagram.model_dump(), current.diagram.model_dump()),
                "presentation": _changed_fields(baseline.presentation.model_dump(), current.presentation.model_dump()),
                "containers": _element_diff(baseline.containers, current.containers), "nodes": _element_diff(baseline.nodes, current.nodes), "edges": _element_diff(baseline.edges, current.edges)}

    def storage_info(self):
        with self._lock, self._database() as connection:
            projects = connection.execute("SELECT COUNT(*) FROM projects").fetchone()[0]
            versions = connection.execute("SELECT COUNT(*) FROM versions").fetchone()[0]
        sizes = {}
        for suffix in ("", "-wal", "-shm"):
            try:
                sizes[suffix] = Path(str(self.database_file)+suffix).stat().st_size
            except FileNotFoundError:
                sizes[suffix] = 0
        return {"databasePath": str(self.database_file), "databaseBytes": sizes[""], "walBytes": sizes["-wal"], "shmBytes": sizes["-shm"],
                "totalBytes": sum(sizes.values()), "projectCount": projects, "versionCount": versions}
