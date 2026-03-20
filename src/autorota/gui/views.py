import tkinter as tk
from tkinter import ttk
from collections.abc import Callable
from copy import deepcopy
from datetime import date, timedelta
from pathlib import Path

from autorota.employee import Weekday, Availability, AvailDict, Employee
from autorota.schedule import Schedule
from autorota.shift_utils import loadWeekdaySchedule
from autorota.gui.widgets import CalendarGrid, AvailEditor

_AVAIL_COLOR = {
    Availability.YES:   "#b8f0b8",
    Availability.MAYBE: "#f0f0a8",
    Availability.NO:    "#f0b8b8",
}

_SHIFT_COLOR = "#b8d8f0"

_DAY_ABBR = [d.name[:3].title() for d in Weekday]   # Mon … Sun

_SHIFTS_JSON = Path(__file__).parent.parent / "shifts.json"


def _next_monday() -> date:
    today = date.today()
    days_ahead = (0 - today.weekday()) % 7 or 7
    return today + timedelta(days=days_ahead)


def _short_frame(shift) -> str:
    """24-hour HH:MM – HH:MM label for a Shift."""
    return f"{shift.dt_start.strftime('%H:%M')} – {shift.dt_end.strftime('%H:%M')}"


# ---------------------------------------------------------------------------
# Schedule view
# ---------------------------------------------------------------------------

class ScheduleView(ttk.Frame):
    """Weekly rota calendar: columns = days, rows = shift slots."""

    def __init__(self, parent):
        super().__init__(parent)
        self._build()

    def _build(self):
        ttk.Label(self, text="Schedule", font=("", 13, "bold")).pack(
            anchor="w", pady=(0, 8)
        )

        monday = _next_monday()
        schedule = Schedule.from_default_json(start_date=monday, duration=7)

        days = sorted({s.dt_start.date() for s in schedule.shifts})
        frames = sorted(
            {_short_frame(s) for s in schedule.shifts},
            key=lambda f: f[:5],   # sort by start time string
        )

        col_headers = [d.strftime("%a\n%d %b") for d in days]
        row_headers = frames

        cells: list[list[str]] = []
        colors: dict[tuple[int, int], str] = {}

        for r, frame in enumerate(frames):
            row = []
            for c, day in enumerate(days):
                matching = [
                    s for s in schedule.shifts
                    if s.dt_start.date() == day and _short_frame(s) == frame
                ]
                if matching:
                    shift = matching[0]
                    if shift.assigned_employees:
                        row.append("\n".join(str(e) for e in shift.assigned_employees))
                        colors[(r, c)] = "#c8eec8"
                    else:
                        row.append(f"Unassigned\n({shift.capacity} needed)")
                        colors[(r, c)] = "#f5f5f5"
                else:
                    row.append("—")
                    colors[(r, c)] = "#ebebeb"
            cells.append(row)

        CalendarGrid(
            self, col_headers, row_headers, cells,
            cell_colors=colors, col_width=14, row_hdr_width=16, cell_height=8,
        ).pack(fill="both", expand=True)


# ---------------------------------------------------------------------------
# Employees view
# ---------------------------------------------------------------------------

class EmployeesView(ttk.Frame):
    """Detail-only employee editor; the list lives in the sidebar."""

    def __init__(
        self,
        parent,
        employees: list[Employee],
        refresh_cb: Callable[[], None],
    ):
        super().__init__(parent)
        self._employees = employees
        self._refresh_cb = refresh_cb
        self._detail_pane: ttk.Frame | None = None
        self._build()

    # ------------------------------------------------------------------
    # Layout
    # ------------------------------------------------------------------

    def _build(self):
        ttk.Label(self, text="Employees", font=("", 13, "bold")).pack(
            anchor="w", pady=(0, 8)
        )

        self._placeholder = ttk.Label(
            self,
            text="Select an employee or press New.",
            foreground="#888888",
        )
        self._placeholder.pack(expand=True)

    # ------------------------------------------------------------------
    # Public API (called by App)
    # ------------------------------------------------------------------

    def open_detail(self, emp: Employee | None) -> None:
        self._open_detail(emp)

    def clear_detail(self) -> None:
        self._clear_detail()

    # ------------------------------------------------------------------
    # Detail pane
    # ------------------------------------------------------------------

    def _clear_detail(self):
        if self._detail_pane:
            self._detail_pane.destroy()
            self._detail_pane = None
        self._placeholder.pack(expand=True)

    def _open_detail(self, emp: Employee | None):
        if emp:
            edit_default = deepcopy(emp.default_avail)
            edit_final   = deepcopy(emp.final_avail)
            name_value   = emp.name
        else:
            edit_default = AvailDict()
            edit_final   = AvailDict()
            name_value   = ""

        if self._detail_pane:
            self._detail_pane.destroy()
        self._placeholder.pack_forget()

        pane = ttk.Frame(self)
        pane.pack(fill="both", expand=True)
        self._detail_pane = pane

        # Name entry
        name_row = ttk.Frame(pane)
        name_row.pack(fill="x", pady=(0, 8))
        ttk.Label(name_row, text="Name:").pack(side="left")
        name_var = tk.StringVar(value=name_value)
        ttk.Entry(name_row, textvariable=name_var, width=30).pack(side="left", padx=(6, 0))

        # Tabs — Default / Final availability
        notebook = ttk.Notebook(pane)
        notebook.pack(fill="both", expand=True, pady=(0, 8))

        for tab_label, avail_dict in [
            ("Default Availability",            edit_default),
            ("Final Availability (This Week)",  edit_final),
        ]:
            tab = ttk.Frame(notebook)
            notebook.add(tab, text=tab_label)
            ttk.Label(
                tab,
                text="Click to select  •  Shift+click range  •  Ctrl/Cmd+click toggle",
                foreground="#555555",
            ).pack(anchor="w", padx=6, pady=(6, 4))
            AvailEditor(tab, avail_dict).pack(fill="both", expand=True, padx=6, pady=(0, 6))

        # Save / Cancel
        btn_row = ttk.Frame(pane)
        btn_row.pack(fill="x")
        ttk.Button(
            btn_row, text="Save",
            command=lambda: self._save(emp, name_var, edit_default, edit_final),
        ).pack(side="left", padx=(0, 4))
        ttk.Button(btn_row, text="Cancel", command=self._clear_detail).pack(side="left")

    def _save(
        self,
        emp: Employee | None,
        name_var: tk.StringVar,
        edit_default: AvailDict,
        edit_final: AvailDict,
    ):
        name = name_var.get().strip()
        if not name:
            return

        if emp is not None:
            emp.name          = name
            emp.default_avail = deepcopy(edit_default)
            emp.final_avail   = deepcopy(edit_final)
        else:
            new_emp = Employee(name)
            new_emp.default_avail = deepcopy(edit_default)
            new_emp.final_avail   = deepcopy(edit_final)
            self._employees.append(new_emp)

        self._refresh_cb()
        self._clear_detail()


# ---------------------------------------------------------------------------
# Shifts view
# ---------------------------------------------------------------------------

class ShiftsView(ttk.Frame):
    """Weekly shift pattern: one row per weekday, shifts listed inline."""

    def __init__(self, parent):
        super().__init__(parent)
        self._build()

    def _build(self):
        ttk.Label(self, text="Shifts", font=("", 13, "bold")).pack(
            anchor="w", pady=(0, 8)
        )

        weekday_shifts = loadWeekdaySchedule(_SHIFTS_JSON)

        # Scrollable container
        canvas = tk.Canvas(self, highlightthickness=0)
        vsb = ttk.Scrollbar(self, orient="vertical", command=canvas.yview)
        canvas.configure(yscrollcommand=vsb.set)
        vsb.pack(side="right", fill="y")
        canvas.pack(fill="both", expand=True)

        inner = ttk.Frame(canvas)
        canvas.create_window((0, 0), window=inner, anchor="nw")
        inner.bind(
            "<Configure>",
            lambda e: canvas.configure(scrollregion=canvas.bbox("all")),
        )
        canvas.bind_all(
            "<MouseWheel>",
            lambda e: canvas.yview_scroll(int(-1 * (e.delta / 120)), "units"),
        )

        for day in Weekday:
            row = ttk.Frame(inner)
            row.pack(fill="x", padx=4, pady=3)

            ttk.Label(
                row, text=day.name[:3].title(),
                font=("", 10, "bold"), width=10, anchor="w",
            ).pack(side="left")

            ttk.Separator(row, orient="vertical").pack(side="left", fill="y", padx=(0, 8))

            shifts_today = sorted(
                weekday_shifts.get(day.value, []),
                key=lambda ps: ps.start_hour,
            )
            if shifts_today:
                for ps in shifts_today:
                    label = f"({ps.start_hour:02}:00\u2013{ps.end_hour:02}:00)"
                    chip = tk.Label(
                        row, text=label,
                        bg=_SHIFT_COLOR, relief="flat",
                        padx=6, pady=3, font=("", 9),
                    )
                    chip.pack(side="left", padx=(0, 6))
            else:
                ttk.Label(row, text="—", foreground="#999999").pack(side="left")
