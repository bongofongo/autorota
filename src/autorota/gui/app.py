import tkinter as tk
from tkinter import ttk

from autorota.gui.views import ScheduleView, EmployeesView, AvailabilityView, ShiftsView


class App(tk.Tk):
    def __init__(self):
        super().__init__()

        self.title("Autorota")
        self.geometry("1050x680")
        self.minsize(700, 450)

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
        self._sidebar = ttk.Frame(self, width=160, relief="flat")
        self._sidebar.pack(side="left", fill="y", padx=(8, 0), pady=8)
        self._sidebar.pack_propagate(False)

        self._content = ttk.Frame(self)
        self._content.pack(side="left", fill="both", expand=True, padx=8, pady=8)

        self._build_sidebar()

        self._views: dict[str, ttk.Frame] = {
            "schedule":    ScheduleView(self._content),
            "employees":   EmployeesView(self._content),
            "availability": AvailabilityView(self._content),
            "shifts":      ShiftsView(self._content),
        }
        self._current_view: ttk.Frame | None = None

    def _build_sidebar(self) -> None:
        ttk.Label(self._sidebar, text="Autorota", font=("", 14, "bold")).pack(
            anchor="w", pady=(4, 12)
        )

        nav_items = [
            ("Schedule",     "schedule"),
            ("Employees",    "employees"),
            ("Availability", "availability"),
            ("Shifts",       "shifts"),
        ]
        for label, key in nav_items:
            ttk.Button(
                self._sidebar, text=label,
                command=lambda k=key: self._switch_view(k),
            ).pack(fill="x", pady=2)

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
