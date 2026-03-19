import tkinter as tk
from tkinter import ttk

from autorota.employee import Weekday, Availability, AvailDict


class CalendarGrid(ttk.Frame):
    """Scrollable label-grid for calendar-style data.

    Parameters
    ----------
    col_headers  : list[str]
    row_headers  : list[str]
    cells        : list[list[str]]  — rows × columns
    cell_colors  : dict[(row, col), hex_str]  — optional per-cell background
    col_width    : character width of each data column
    row_hdr_width: character width of the row-header column
    cell_height  : pixel padding (ipady) for each cell row
    """

    _HDR_BG  = "#dde1ea"
    _CELL_BG = "#ffffff"
    _GAP_BG  = "#b0b4bc"

    def __init__(
        self,
        parent,
        col_headers: list[str],
        row_headers: list[str],
        cells: list[list[str]],
        cell_colors: dict[tuple[int, int], str] | None = None,
        col_width: int = 13,
        row_hdr_width: int = 16,
        cell_height: int = 6,
    ):
        super().__init__(parent)
        cell_colors = cell_colors or {}

        vsb = ttk.Scrollbar(self, orient="vertical")
        hsb = ttk.Scrollbar(self, orient="horizontal")
        canvas = tk.Canvas(
            self,
            yscrollcommand=vsb.set,
            xscrollcommand=hsb.set,
            borderwidth=0,
            highlightthickness=0,
            bg=self._GAP_BG,
        )
        vsb.config(command=canvas.yview)
        hsb.config(command=canvas.xview)

        vsb.pack(side="right", fill="y")
        hsb.pack(side="bottom", fill="x")
        canvas.pack(side="left", fill="both", expand=True)

        inner = tk.Frame(canvas, bg=self._GAP_BG)
        canvas.create_window((0, 0), window=inner, anchor="nw")
        inner.bind(
            "<Configure>",
            lambda e: canvas.configure(scrollregion=canvas.bbox("all")),
        )

        # --- corner ---
        tk.Label(
            inner, text="", width=row_hdr_width,
            bg=self._HDR_BG, relief="flat",
        ).grid(row=0, column=0, padx=1, pady=1, sticky="nsew")

        # --- column headers ---
        for c, text in enumerate(col_headers):
            tk.Label(
                inner, text=text, width=col_width,
                bg=self._HDR_BG, anchor="center",
                font=("", 9, "bold"), relief="flat",
            ).grid(row=0, column=c + 1, padx=1, pady=1, sticky="nsew")

        # --- rows ---
        for r, row_hdr in enumerate(row_headers):
            tk.Label(
                inner, text=row_hdr, width=row_hdr_width,
                bg=self._HDR_BG, anchor="w", padx=6,
                font=("", 9, "bold"), relief="flat",
            ).grid(row=r + 1, column=0, padx=1, pady=1, sticky="nsew")

            for c, text in enumerate(cells[r]):
                bg = cell_colors.get((r, c), self._CELL_BG)
                tk.Label(
                    inner, text=text, width=col_width,
                    bg=bg, anchor="center", relief="flat",
                    wraplength=col_width * 7,
                ).grid(row=r + 1, column=c + 1, padx=1, pady=1, ipady=cell_height, sticky="nsew")

        # Mousewheel scrolling
        canvas.bind_all(
            "<MouseWheel>",
            lambda e: canvas.yview_scroll(int(-1 * (e.delta / 120)), "units"),
        )


class AvailEditor(ttk.Frame):
    """Interactive weekly availability grid.

    Left-click any cell to cycle its state: YES → MAYBE → NO → YES.
    Modifies the supplied AvailDict in-place immediately.
    """

    _COLORS = {
        Availability.YES:   "#b8f0b8",
        Availability.MAYBE: "#f0f0a8",
        Availability.NO:    "#f0b8b8",
    }
    _SYMBOLS = {
        Availability.YES:   "Y",
        Availability.MAYBE: "M",
        Availability.NO:    "N",
    }
    _CYCLE = {
        Availability.YES:   Availability.MAYBE,
        Availability.MAYBE: Availability.NO,
        Availability.NO:    Availability.YES,
    }
    _HDR_BG = "#dde1ea"
    _GAP_BG = "#b0b4bc"

    def __init__(
        self,
        parent,
        avail: AvailDict,
        start_hour: int = 6,
        end_hour: int = 22,
    ):
        super().__init__(parent)
        self._avail = avail
        self._labels: dict[tuple[Weekday, int], tk.Label] = {}
        self._build(start_hour, end_hour)

    def _build(self, start_hour: int, end_hour: int) -> None:
        hours = list(range(start_hour, end_hour))

        canvas = tk.Canvas(self, highlightthickness=0, bg=self._GAP_BG)
        hsb = ttk.Scrollbar(self, orient="horizontal", command=canvas.xview)
        canvas.configure(xscrollcommand=hsb.set)
        hsb.pack(side="bottom", fill="x")
        canvas.pack(fill="both", expand=True)

        inner = tk.Frame(canvas, bg=self._GAP_BG)
        canvas.create_window((0, 0), window=inner, anchor="nw")
        inner.bind(
            "<Configure>",
            lambda e: canvas.configure(scrollregion=canvas.bbox("all")),
        )

        # Corner
        tk.Label(
            inner, text="", width=8,
            bg=self._HDR_BG, relief="flat",
        ).grid(row=0, column=0, padx=1, pady=1, sticky="nsew")

        # Hour column headers
        for c, hour in enumerate(hours):
            tk.Label(
                inner, text=f"{hour:02}", width=3,
                bg=self._HDR_BG, anchor="center",
                font=("", 8, "bold"), relief="flat",
            ).grid(row=0, column=c + 1, padx=1, pady=1, sticky="nsew")

        # Day rows
        for r, day in enumerate(Weekday):
            tk.Label(
                inner, text=day.name[:3].title(), width=8,
                bg=self._HDR_BG, anchor="w", padx=4,
                font=("", 9, "bold"), relief="flat",
            ).grid(row=r + 1, column=0, padx=1, pady=1, sticky="nsew")

            for c, hour in enumerate(hours):
                a = self._avail[day][hour]
                lbl = tk.Label(
                    inner, text=self._SYMBOLS[a], width=3,
                    bg=self._COLORS[a], anchor="center",
                    relief="flat", cursor="hand2",
                )
                lbl.grid(row=r + 1, column=c + 1, padx=1, pady=1, ipady=3, sticky="nsew")
                lbl.bind("<Button-1>", lambda e, d=day, h=hour: self._cycle(d, h))
                self._labels[(day, hour)] = lbl

    def _cycle(self, day: Weekday, hour: int) -> None:
        current = self._avail[day][hour]
        nxt = self._CYCLE[current]
        self._avail[day][hour] = nxt
        lbl = self._labels[(day, hour)]
        lbl.config(text=self._SYMBOLS[nxt], bg=self._COLORS[nxt])
