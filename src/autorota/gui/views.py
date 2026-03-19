import tkinter as tk
from tkinter import ttk
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
    """Two-pane employee manager: list on the left, editor on the right."""

    def __init__(self, parent):
        super().__init__(parent)
        self._employees: list[Employee] = []
        self._detail_pane: ttk.Frame | None = None
        self._build()

    # ------------------------------------------------------------------
    # Layout
    # ------------------------------------------------------------------

    def _build(self):
        ttk.Label(self, text="Employees", font=("", 13, "bold")).pack(
            anchor="w", pady=(0, 8)
        )

        paned = ttk.PanedWindow(self, orient="horizontal")
        paned.pack(fill="both", expand=True)

        # Left — employee list
        list_frame = ttk.Frame(paned, width=200)
        list_frame.pack_propagate(False)
        paned.add(list_frame, weight=0)

        lb_wrap = ttk.Frame(list_frame)
        lb_wrap.pack(fill="both", expand=True)
        vsb = ttk.Scrollbar(lb_wrap, orient="vertical")
        self._listbox = tk.Listbox(
            lb_wrap, yscrollcommand=vsb.set,
            selectmode="single", activestyle="none",
            font=("", 10),
        )
        vsb.config(command=self._listbox.yview)
        vsb.pack(side="right", fill="y")
        self._listbox.pack(fill="both", expand=True)
        self._listbox.bind("<<ListboxSelect>>", self._on_list_select)

        btn_row = ttk.Frame(list_frame)
        btn_row.pack(fill="x", pady=(4, 0))
        ttk.Button(btn_row, text="New",    command=self._new_employee).pack(side="left", expand=True, fill="x", padx=(0, 1))
        ttk.Button(btn_row, text="Delete", command=self._delete_employee).pack(side="left", expand=True, fill="x", padx=(1, 0))

        # Right — detail area
        self._detail_container = ttk.Frame(paned)
        paned.add(self._detail_container, weight=1)

        self._placeholder = ttk.Label(
            self._detail_container,
            text="Select an employee or press New.",
            foreground="#888888",
        )
        self._placeholder.pack(expand=True)

    # ------------------------------------------------------------------
    # List management
    # ------------------------------------------------------------------

    def _refresh_list(self):
        self._listbox.delete(0, tk.END)
        for emp in self._employees:
            self._listbox.insert(tk.END, emp.name)

    def _on_list_select(self, _event):
        sel = self._listbox.curselection()
        if sel:
            self._open_detail(self._employees[sel[0]])

    def _new_employee(self):
        self._listbox.selection_clear(0, tk.END)
        self._open_detail(None)

    def _delete_employee(self):
        sel = self._listbox.curselection()
        if not sel:
            return
        self._employees.pop(sel[0])
        self._refresh_list()
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

        pane = ttk.Frame(self._detail_container)
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
                text="Click a cell to cycle:  Y = yes   M = maybe   N = no",
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

        self._refresh_list()
        self._clear_detail()


# ---------------------------------------------------------------------------
# Availability view
# ---------------------------------------------------------------------------

class AvailabilityView(ttk.Frame):
    """Hour-by-hour weekly availability grid (Y / M / N)."""

    def __init__(self, parent):
        super().__init__(parent)
        self._build()

    def _build(self):
        ttk.Label(self, text="Availability", font=("", 13, "bold")).pack(
            anchor="w", pady=(0, 4)
        )
        ttk.Label(
            self,
            text="Showing default availability for a demo employee.",
            foreground="#666666",
        ).pack(anchor="w", pady=(0, 8))

        emp = Employee("Demo Employee")
        self._render(emp.default_avail)

    def _render(self, avail: AvailDict, start_hour: int = 6, end_hour: int = 22):
        hours = list(range(start_hour, end_hour))
        col_headers = [f"{h:02}:00" for h in hours]
        row_headers = _DAY_ABBR

        cells: list[list[str]] = []
        colors: dict[tuple[int, int], str] = {}

        for r, day in enumerate(Weekday):
            row = []
            for c, hour in enumerate(hours):
                a = avail[day][hour]
                row.append(a.name[0])          # Y / M / N
                colors[(r, c)] = _AVAIL_COLOR[a]
            cells.append(row)

        CalendarGrid(
            self, col_headers, row_headers, cells,
            cell_colors=colors, col_width=5, row_hdr_width=6, cell_height=4,
        ).pack(fill="both", expand=True)


# ---------------------------------------------------------------------------
# Shifts view
# ---------------------------------------------------------------------------

class ShiftsView(ttk.Frame):
    """Weekly shift pattern loaded from shifts.json."""

    def __init__(self, parent):
        super().__init__(parent)
        self._build()

    def _build(self):
        ttk.Label(self, text="Shifts", font=("", 13, "bold")).pack(
            anchor="w", pady=(0, 8)
        )

        weekday_shifts = loadWeekdaySchedule(_SHIFTS_JSON)

        # Build all unique frames using a dummy date so we can call .frame
        from datetime import datetime
        _dummy = date(2000, 1, 3)   # a Monday

        all_frames: list[str] = []
        seen: set[str] = set()
        for day_idx in range(7):
            for ps in weekday_shifts.get(day_idx, []):
                label = f"{ps.start_hour:02}:00 – {ps.end_hour:02}:00"
                if label not in seen:
                    all_frames.append(label)
                    seen.add(label)
        all_frames.sort()

        col_headers = _DAY_ABBR
        row_headers = all_frames

        cells: list[list[str]] = []
        colors: dict[tuple[int, int], str] = {}

        for r, frame in enumerate(all_frames):
            row = []
            for c, day in enumerate(Weekday):
                match = any(
                    f"{ps.start_hour:02}:00 – {ps.end_hour:02}:00" == frame
                    for ps in weekday_shifts.get(day.value, [])
                )
                row.append("✓" if match else "")
                if match:
                    colors[(r, c)] = _SHIFT_COLOR
            cells.append(row)

        CalendarGrid(
            self, col_headers, row_headers, cells,
            cell_colors=colors, col_width=8, row_hdr_width=16, cell_height=6,
        ).pack(fill="both", expand=True)
