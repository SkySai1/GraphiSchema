"""Project trash and transactional removal of a project's repository records."""
from datetime import datetime, timedelta, timezone

from .legacy_storage import RevisionConflict


class ProjectNotFound(ValueError):
    pass


class ProjectInTrash(ProjectNotFound):
    pass


class ProjectTrashMixin:
    retention = timedelta(days=10)

    @staticmethod
    def _now():
        return datetime.now(timezone.utc)

    @staticmethod
    def _date(value):
        return value.astimezone(timezone.utc).isoformat(timespec="microseconds")

    def _require_active_project(self, connection, project_id):
        project = connection.execute("SELECT * FROM projects WHERE id=?", (project_id,)).fetchone()
        if project is None:
            raise ProjectNotFound("Проект не найден.")
        if project["deleted_at"] is not None:
            raise ProjectInTrash("Проект находится в корзине. Восстановите его через менеджер схем.")
        return project

    @staticmethod
    def _repair_default(connection):
        state = dict(connection.execute("SELECT key,value FROM workspace_state"))
        valid = connection.execute("""SELECT b.id FROM branches b JOIN projects p ON p.id=b.project_id
            WHERE b.id=? AND p.id=? AND p.deleted_at IS NULL""", (state.get("branch_id"), state.get("project_id"))).fetchone()
        if not valid:
            connection.execute("DELETE FROM workspace_state WHERE key IN ('project_id','branch_id')")
            replacement = connection.execute("""SELECT b.id,b.project_id FROM branches b JOIN projects p ON p.id=b.project_id
                WHERE p.deleted_at IS NULL ORDER BY p.updated_at DESC,(b.name='main') DESC,b.created_at,b.id LIMIT 1""").fetchone()
            if replacement:
                for key, value in (("project_id", replacement["project_id"]), ("branch_id", replacement["id"])):
                    connection.execute("INSERT OR REPLACE INTO workspace_state(key,value) VALUES(?,?)", (key, value))
        current = connection.execute("""SELECT c.project_id FROM current_project c JOIN projects p ON p.id=c.project_id
            WHERE p.deleted_at IS NULL AND c.slot=1""").fetchone()
        if not current:
            connection.execute("DELETE FROM current_project")
            replacement = connection.execute("""SELECT v.project_id,v.snapshot,v.revision,v.created_at FROM versions v
                JOIN branches b ON b.head_version_id=v.id JOIN workspace_state s ON s.key='branch_id' AND s.value=b.id""").fetchone()
            if replacement:
                connection.execute("INSERT INTO current_project(slot,project_id,snapshot,revision,updated_at) VALUES(1,?,?,?,?)", tuple(replacement))

    def trash_project(self, project_id):
        with self._lock, self._database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            project = connection.execute("SELECT * FROM projects WHERE id=?", (project_id,)).fetchone()
            if project is None:
                raise ProjectNotFound("Проект не найден.")
            deleted_at, purge_after = project["deleted_at"], project["purge_after"]
            if deleted_at is None:
                now = self._now()
                deleted_at, purge_after = self._date(now), self._date(now+self.retention)
                connection.execute("UPDATE projects SET deleted_at=?,purge_after=? WHERE id=?", (deleted_at, purge_after, project_id))
                self._repair_default(connection)
            branches = [r[0] for r in connection.execute("SELECT id FROM branches WHERE project_id=?", (project_id,))]
            connection.commit()
            return {"projectId": project_id, "deletedAt": deleted_at, "purgeAfter": purge_after, "branchIds": branches}

    def restore_project(self, project_id):
        with self._lock, self._database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            project = connection.execute("SELECT * FROM projects WHERE id=?", (project_id,)).fetchone()
            if project is None:
                raise ProjectNotFound("Проект не найден в корзине.")
            if project["purge_after"] is not None and project["purge_after"] <= self._date(self._now()):
                raise ProjectNotFound("Срок хранения проекта в корзине истёк.")
            connection.execute("UPDATE projects SET deleted_at=NULL,purge_after=NULL WHERE id=?", (project_id,))
            self._repair_default(connection)
            connection.commit()
            return {"projectId": project_id}

    def purge_projects(self, project_ids=None, *, before_purge=None):
        """With no IDs, purge only expired trash. Never cascade into other projects."""
        if not self.database_file.exists():
            if project_ids:
                raise ProjectNotFound("Проект не найден в корзине.")
            return []
        with self._lock, self._database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            if project_ids is None:
                rows = connection.execute("SELECT id FROM projects WHERE deleted_at IS NOT NULL AND purge_after<=?", (self._date(self._now()),)).fetchall()
                project_ids = [r["id"] for r in rows]
            project_ids = list(dict.fromkeys(project_ids))
            results = []
            for project_id in project_ids:
                row = connection.execute("SELECT deleted_at FROM projects WHERE id=?", (project_id,)).fetchone()
                if row is None:
                    raise ProjectNotFound("Проект не найден в корзине.")
                if row["deleted_at"] is None:
                    raise RevisionConflict("Сначала переместите проект в корзину.")
                results.append({"projectId": project_id, "branchIds": [r[0] for r in connection.execute("SELECT id FROM branches WHERE project_id=?", (project_id,))]})
            if project_ids and before_purge:
                before_purge(project_ids)
            connection.execute("PRAGMA secure_delete=ON")
            for project_id in project_ids:
                connection.execute("""UPDATE projects SET origin_project_id=NULL,origin_version_id=NULL
                    WHERE origin_project_id=? OR origin_version_id IN (SELECT id FROM versions WHERE project_id=?)""", (project_id, project_id))
                connection.execute("DELETE FROM revision_aliases WHERE json_extract(snapshot,'$.project.id')=?", (project_id,))
                connection.execute("DELETE FROM branches WHERE project_id=?", (project_id,))
                connection.execute("DELETE FROM versions WHERE project_id=?", (project_id,))
                connection.execute("DELETE FROM projects WHERE id=?", (project_id,))
            if project_ids:
                self._repair_default(connection)
            connection.commit()
            return results
