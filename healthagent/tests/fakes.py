import copy
import uuid
from types import SimpleNamespace


class FakeQuery:
    """Just enough of the supabase-py query builder to test our code without a database."""

    def __init__(self, db, name):
        self._db, self._name = db, name
        self._filters, self._order, self._range = [], None, None
        self._op, self._payload, self._conflict = "select", None, None
        self._columns = None

    def select(self, *args, **_kwargs):
        self._op = "select"
        # PostgREST projects to the named columns; model that so tests can assert a
        # query does NOT return a heavy column such as activity_sessions.samples.
        columns = ",".join(a for a in args if isinstance(a, str)) or "*"
        self._columns = None if "*" in columns else [
            c.strip() for c in columns.split(",") if c.strip()
        ]
        return self

    def eq(self, column, value):
        self._filters.append(lambda r: r.get(column) == value)
        return self

    def neq(self, column, value):
        self._filters.append(lambda r: r.get(column) != value)
        return self

    def in_(self, column, values):
        self._filters.append(lambda r: r.get(column) in values)
        return self

    def gte(self, column, value):
        self._filters.append(lambda r: r.get(column) is not None and r.get(column) >= value)
        return self

    def lte(self, column, value):
        self._filters.append(lambda r: r.get(column) is not None and r.get(column) <= value)
        return self

    @property
    def not_(self):
        query = self

        class _Not:
            def is_(self, column, value):
                assert value == "null"
                query._filters.append(lambda r: r.get(column) is not None)
                return query

        return _Not()

    def order(self, column, desc=False):
        self._order = (column, desc)
        return self

    def range(self, first, last):
        self._range = (first, last)
        return self

    def insert(self, rows):
        self._op, self._payload = "insert", rows
        return self

    def upsert(self, rows, on_conflict=None):
        self._op, self._payload, self._conflict = "upsert", rows, on_conflict
        return self

    def delete(self):
        self._op = "delete"
        return self

    def _matching(self):
        table = self._db.tables.setdefault(self._name, [])
        return [r for r in table if all(f(r) for f in self._filters)]

    def execute(self):
        table = self._db.tables.setdefault(self._name, [])
        if self._op == "select":
            rows = self._matching()
            if self._order:
                column, desc = self._order
                # Real tables supply defaults (e.g. created_at default now()), which this
                # fake does not simulate. Missing keys sort last instead of raising.
                rows = sorted(
                    rows,
                    key=lambda r: (r.get(column) is None, r.get(column)),
                    reverse=desc,
                )
            if self._range:
                rows = rows[self._range[0] : self._range[1] + 1]
            rows = copy.deepcopy(rows)
            if self._columns is not None:
                rows = [{k: r[k] for k in self._columns if k in r} for r in rows]
            return SimpleNamespace(data=rows)
        if self._op == "delete":
            gone = self._matching()
            table[:] = [r for r in table if r not in gone]
            return SimpleNamespace(data=gone)
        payload = self._payload if isinstance(self._payload, list) else [self._payload]
        for row in copy.deepcopy(payload):
            row.setdefault("id", str(uuid.uuid4()))
            if self._op == "upsert" and self._conflict:
                keys = self._conflict.split(",")
                table[:] = [r for r in table if any(r.get(k) != row.get(k) for k in keys)]
            table.append(row)
        return SimpleNamespace(data=copy.deepcopy(payload))


class FakeSupabase:
    def __init__(self, tables=None):
        self.tables = tables or {}

    def table(self, name):
        return FakeQuery(self, name)
