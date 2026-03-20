import tkinter as tk
from tkinter import ttk

from autorota.employee import Employee
from autorota.gui.views import ScheduleView, EmployeesView, ShiftsView


class App(tk.Tk):
    def __init__(self):
        super().__init__()

        self.title("Autorota")
        self.geometry("1050x680")
        self.minsize(700, 450)

        self._employees: list[Employee] = []

        self._build_menu()
        self._build_layout()
        self._switch_view("schedule")

    # ------------------------------------------------------------------
    # Construction
    # ------------------------------------------------------------------

    def _build_menu(self) -> None:
        menubar = tk.Menu(self)

        file_menu = tk.Menu(menubar, tearoff=0)
        file_menu.add_command(label="New Schedule", command=lambda: self._switch_view("schedule"))
        file_menu.add_separator()
        file_menu.add_command(label="Quit", command=self.quit)
        menubar.add_cascade(label="File", menu=file_menu)

        self.config(menu=menubar)

    def _build_layout(self) -> None:
        self._sidebar = ttk.Frame(self, width=175, relief="flat")
        self._sidebar.pack(side="left", fill="y", padx=(8, 0), pady=8)
        self._sidebar.pack_propagate(False)

        self._content = ttk.Frame(self)
        self._content.pack(side="left", fill="both", expand=True, padx=8, pady=8)

        self._build_sidebar()

        self._views: dict[str, ttk.Frame] = {
            "schedule":  ScheduleView(self._content),
            "employees": EmployeesView(
                self._content,
                self._employees,
                self._refresh_employee_list,
            ),
            "shifts":    ShiftsView(self._content),
        }
        self._current_view: ttk.Frame | None = None

    def _build_sidebar(self) -> None:
        ttk.Label(self._sidebar, text="Autorota", font=("", 14, "bold")).pack(
            anchor="w", pady=(4, 8)
        )

        nav_items = [
            ("Schedule",  "schedule"),
            ("Employees", "employees"),
            ("Shifts",    "shifts"),
        ]
        for label, key in nav_items:
            ttk.Button(
                self._sidebar, text=label,
                command=lambda k=key: self._switch_view(k),
            ).pack(fill="x", pady=2)

        ttk.Separator(self._sidebar, orient="horizontal").pack(fill="x", pady=(10, 6))
        ttk.Label(self._sidebar, text="Employees", font=("", 10, "bold")).pack(anchor="w")

        lb_wrap = ttk.Frame(self._sidebar)
        lb_wrap.pack(fill="both", expand=True, pady=(4, 0))
        vsb = ttk.Scrollbar(lb_wrap, orient="vertical")
        self._emp_listbox = tk.Listbox(
            lb_wrap, yscrollcommand=vsb.set,
            selectmode="single", activestyle="none",
            font=("", 10),
        )
        vsb.config(command=self._emp_listbox.yview)
        vsb.pack(side="right", fill="y")
        self._emp_listbox.pack(fill="both", expand=True)
        self._emp_listbox.bind("<<ListboxSelect>>", self._on_emp_select)

        btn_row = ttk.Frame(self._sidebar)
        btn_row.pack(fill="x", pady=(4, 0))
        ttk.Button(btn_row, text="New",    command=self._new_employee).pack(
            side="left", expand=True, fill="x", padx=(0, 1)
        )
        ttk.Button(btn_row, text="Delete", command=self._delete_employee).pack(
            side="left", expand=True, fill="x", padx=(1, 0)
        )

    # ------------------------------------------------------------------
    # Employee list helpers
    # ------------------------------------------------------------------

    def _refresh_employee_list(self) -> None:
        self._emp_listbox.delete(0, tk.END)
        for emp in self._employees:
            self._emp_listbox.insert(tk.END, emp.name)

    def _on_emp_select(self, _event) -> None:
        sel = self._emp_listbox.curselection()
        if sel:
            self._switch_view("employees")
            self._views["employees"].open_detail(self._employees[sel[0]])  # type: ignore[union-attr]

    def _new_employee(self) -> None:
        self._emp_listbox.selection_clear(0, tk.END)
        self._switch_view("employees")
        self._views["employees"].open_detail(None)  # type: ignore[union-attr]

    def _delete_employee(self) -> None:
        sel = self._emp_listbox.curselection()
        if not sel:
            return
        self._employees.pop(sel[0])
        self._refresh_employee_list()
        self._views["employees"].clear_detail()  # type: ignore[union-attr]

    # ------------------------------------------------------------------
    # Navigation
    # ------------------------------------------------------------------

    def _switch_view(self, name: str) -> None:
        if self._current_view is not None:
            self._current_view.pack_forget()
        view = self._views[name]
        view.pack(fill="both", expand=True)
        self._current_view = view


def main() -> None:
    app = App()
    app.mainloop()


if __name__ == "__main__":
    main()
