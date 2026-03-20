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

    Click a cell to select it; Shift+click for range; Ctrl/Cmd+click to
    toggle individual cells.  Use the toolbar buttons or Y / M / N keys
    to apply an availability to all selected cells.  Esc clears selection.
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
    _HDR_BG    = "#dde1ea"
    _GAP_BG    = "#b0b4bc"
    _SEL_COLOR = "#1a73e8"   # blue selection ring

    def __init__(
        self,
        parent,
        avail: AvailDict,
        start_hour: int = 6,
        end_hour: int = 22,
    ):
        super().__init__(parent)
        self._avail      = avail
        self._labels:    dict[tuple[Weekday, int], tk.Label] = {}
        self._wrappers:  dict[tuple[Weekday, int], tk.Frame]  = {}
        self._selected:  set[tuple[Weekday, int]] = set()
        self._anchor:    tuple[Weekday, int] | None = None
        self._hours:     list[int] = []
        self._canvas:    tk.Canvas | None = None
        self._grid_host: tk.Frame | None = None   # destroyed/recreated on hour change

        self._start_var = tk.StringVar(value=f"{start_hour:02d}")
        self._end_var   = tk.StringVar(value=f"{end_hour:02d}")

        self._build_toolbar()
        self._build_grid()

        # Trace fires after spinbox value is committed
        self._start_var.trace_add("write", self._on_hours_changed)
        self._end_var.trace_add("write",   self._on_hours_changed)

    # ------------------------------------------------------------------
    # Build
    # ------------------------------------------------------------------

    def _build_toolbar(self) -> None:
        toolbar = ttk.Frame(self)
        toolbar.pack(fill="x", pady=(0, 6))

        # Availability buttons
        ttk.Label(toolbar, text="Set selected to:").pack(side="left", padx=(0, 8))
        for avail, text in [
            (Availability.YES,   "Yes  [Y]"),
            (Availability.MAYBE, "Maybe  [M]"),
            (Availability.NO,    "No  [N]"),
        ]:
            tk.Button(
                toolbar, text=text,
                bg=self._COLORS[avail], activebackground=self._COLORS[avail],
                relief="flat", padx=10, pady=3, cursor="hand2",
                command=lambda a=avail: self._apply(a),
            ).pack(side="left", padx=(0, 4))

        # Hour range controls (right side)
        ttk.Separator(toolbar, orient="vertical").pack(side="left", fill="y", padx=(12, 8))
        ttk.Label(toolbar, text="Show:").pack(side="left", padx=(0, 4))
        ttk.Spinbox(
            toolbar, from_=0, to=22, width=4, format="%02.0f",
            textvariable=self._start_var,
        ).pack(side="left")
        ttk.Label(toolbar, text="–").pack(side="left", padx=4)
        ttk.Spinbox(
            toolbar, from_=1, to=23, width=4, format="%02.0f",
            textvariable=self._end_var,
        ).pack(side="left")

    def _build_grid(self) -> None:
        start, end = self._parse_hours()
        if start is None:
            return

        self._hours = list(range(start, end))
        self._selected.clear()
        self._anchor = None
        self._labels.clear()
        self._wrappers.clear()

        if self._grid_host is not None:
            self._grid_host.destroy()

        self._grid_host = ttk.Frame(self)
        self._grid_host.pack(fill="both", expand=True)

        self._canvas = tk.Canvas(self._grid_host, highlightthickness=0, bg=self._GAP_BG)
        hsb = ttk.Scrollbar(self._grid_host, orient="horizontal", command=self._canvas.xview)
        self._canvas.configure(xscrollcommand=hsb.set)
        hsb.pack(side="bottom", fill="x")
        self._canvas.pack(fill="both", expand=True)

        inner = tk.Frame(self._canvas, bg=self._GAP_BG)
        self._canvas.create_window((0, 0), window=inner, anchor="nw")
        inner.bind(
            "<Configure>",
            lambda e: self._canvas.configure(scrollregion=self._canvas.bbox("all")),
        )

        # Key bindings
        for key, avail in [
            ("y", Availability.YES), ("Y", Availability.YES),
            ("m", Availability.MAYBE), ("M", Availability.MAYBE),
            ("n", Availability.NO), ("N", Availability.NO),
        ]:
            self._canvas.bind(f"<KeyPress-{key}>", lambda e, a=avail: self._apply(a))
        self._canvas.bind("<Escape>", lambda e: self._deselect_all())

        # Corner
        tk.Label(inner, text="", width=8, bg=self._HDR_BG, relief="flat").grid(
            row=0, column=0, padx=1, pady=1, sticky="nsew"
        )

        # Hour headers
        for c, hour in enumerate(self._hours):
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

            for c, hour in enumerate(self._hours):
                a = self._avail[day][hour]
                wrapper = tk.Frame(inner, bg=self._GAP_BG)
                wrapper.grid(row=r + 1, column=c + 1, padx=1, pady=1, sticky="nsew")
                lbl = tk.Label(
                    wrapper, text=self._SYMBOLS[a], width=3,
                    bg=self._COLORS[a], anchor="center",
                    relief="flat", cursor="hand2",
                )
                lbl.pack(fill="both", expand=True, padx=1, pady=1, ipady=2)
                lbl.bind("<Button-1>", lambda e, d=day, h=hour: self._on_click(e, d, h))
                self._labels[(day, hour)]   = lbl
                self._wrappers[(day, hour)] = wrapper

    # ------------------------------------------------------------------
    # Hour range helpers
    # ------------------------------------------------------------------

    def _parse_hours(self) -> tuple[int, int] | tuple[None, None]:
        """Return (start, end) if valid, else (None, None)."""
        try:
            start = int(float(self._start_var.get()))
            end   = int(float(self._end_var.get()))
        except ValueError:
            return None, None
        if not (0 <= start <= 22 and 1 <= end <= 23 and start < end):
            return None, None
        return start, end

    def _on_hours_changed(self, *_) -> None:
        if self._parse_hours() != (None, None):
            self._build_grid()

    # ------------------------------------------------------------------
    # Interaction
    # ------------------------------------------------------------------

    def _on_click(self, event: tk.Event, day: Weekday, hour: int) -> None:
        self._canvas.focus_set()
        is_shift = bool(event.state & 0x1)
        is_multi = bool(event.state & 0x4) or bool(event.state & 0x8)  # Ctrl / Cmd

        if is_shift and self._anchor is not None:
            self._range_select(self._anchor, (day, hour))
        elif is_multi:
            key = (day, hour)
            if key in self._selected:
                self._selected.discard(key)
            else:
                self._selected.add(key)
                self._anchor = key
        else:
            self._selected = {(day, hour)}
            self._anchor = (day, hour)

        self._refresh_visuals()

    def _range_select(
        self, anchor: tuple[Weekday, int], end: tuple[Weekday, int]
    ) -> None:
        r1, c1 = anchor[0].value, self._hours.index(anchor[1])
        r2, c2 = end[0].value,    self._hours.index(end[1])
        r_min, r_max = min(r1, r2), max(r1, r2)
        c_min, c_max = min(c1, c2), max(c1, c2)
        self._selected = {
            (Weekday(r), self._hours[c])
            for r in range(r_min, r_max + 1)
            for c in range(c_min, c_max + 1)
        }

    def _deselect_all(self) -> None:
        self._selected.clear()
        self._anchor = None
        self._refresh_visuals()

    def _apply(self, avail: Availability) -> None:
        for day, hour in self._selected:
            self._avail[day][hour] = avail
        self._refresh_visuals()

    def _refresh_visuals(self) -> None:
        for (day, hour), lbl in self._labels.items():
            a = self._avail[day][hour]
            lbl.config(text=self._SYMBOLS[a], bg=self._COLORS[a])
            sel = (day, hour) in self._selected
            self._wrappers[(day, hour)].config(
                bg=self._SEL_COLOR if sel else self._GAP_BG
            )
