import { invoke } from "@tauri-apps/api/core";

// ─── Types (mirror Rust models) ─────────────────────────────

interface Employee {
  id: number;
  name: string;
  roles: string[];
  start_date: string;
  target_weekly_hours: number;
  weekly_hours_deviation: number;
  max_daily_hours: number;
  notes: string | null;
  bank_details: string | null;
  default_availability: Record<string, string>;
  availability: Record<string, string>;
}

interface ShiftTemplate {
  id: number;
  name: string;
  weekdays: string[];
  start_time: string;
  end_time: string;
  required_role: string;
  min_employees: number;
  max_employees: number;
}

interface ScheduleEntry {
  shift_id: number;
  date: string;
  weekday: string;
  start_time: string;
  end_time: string;
  required_role: string;
  employee_id: number;
  employee_name: string;
  status: string;
}

interface WeekSchedule {
  rota_id: number;
  week_start: string;
  finalized: boolean;
  entries: ScheduleEntry[];
}

interface ScheduleResult {
  assignments: unknown[];
  warnings: { shift_id: number; needed: number; filled: number }[];
}

// ─── State ──────────────────────────────────────────────────

let employees: Employee[] = [];
let shiftTemplates: ShiftTemplate[] = [];
let currentView = "employees";
let selectedWeek = toLocalISODate(getMonday(new Date()));
let selectedEmployeeId: number | null = null;
let editEmployeeId: number | null = null;
let editShiftTemplateId: number | null = null;
let cleanupCurrentView: (() => void) | null = null;

// ─── API wrappers ───────────────────────────────────────────

async function initDb(): Promise<void> {
  await invoke("init_db");
}

async function fetchEmployees(): Promise<void> {
  employees = await invoke("list_employees");
  renderSidebarEmployees();
}

async function fetchShiftTemplates(): Promise<void> {
  shiftTemplates = await invoke("list_shift_templates");
}

function getMonday(d: Date): Date {
  const date = new Date(d);
  const day = date.getDay();
  const diff = date.getDate() - day + (day === 0 ? -6 : 1);
  date.setDate(diff);
  date.setHours(0, 0, 0, 0);
  return date;
}

/** Format a Date as YYYY-MM-DD using local time (avoids UTC rollback bug). */
function toLocalISODate(d: Date): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

function todayISO(): string {
  return toLocalISODate(new Date());
}

function toTitleCase(s: string): string {
  return s.replace(/\b\w/g, (c) => c.toUpperCase());
}

function parseRoles(csv: string): string[] {
  return csv.split(",").map((r) => toTitleCase(r.trim())).filter(Boolean);
}

// ─── Rendering ──────────────────────────────────────────────

function renderSidebarEmployees() {
  const el = document.getElementById("employee-list")!;
  el.innerHTML = employees
    .map(
      (e) =>
        `<div class="employee-item" data-id="${e.id}">${e.name}</div>`
    )
    .join("");

  el.querySelectorAll(".employee-item").forEach((item) => {
    item.addEventListener("click", () => {
      selectedEmployeeId = parseInt((item as HTMLElement).dataset.id!);
      currentView = "employee-detail";
      document.querySelectorAll(".nav-btn").forEach((b) => b.classList.remove("active"));
      // Close sidebar on mobile
      if (window.matchMedia("(max-width: 768px)").matches) {
        document.getElementById("sidebar")!.classList.add("collapsed");
      }
      renderView();
    });
  });
}

function renderEmployeesView() {
  const content = document.getElementById("content")!;

  // Sort employees by start_date (already sorted from DB, but ensure)
  const sorted = [...employees].sort((a, b) => a.start_date.localeCompare(b.start_date));

  content.innerHTML = `
    <h1>Employees</h1>
    <div class="card">
      <button class="btn-add-item" id="add-employee-btn">+</button>
      <div class="item-list">
        ${sorted.length === 0 ? '<p class="empty-state">No employees yet. Click + to add one.</p>' : ""}
        ${sorted
          .map(
            (e) => `
          <div class="item-row" data-id="${e.id}">
            <div class="item-info">
              <span class="item-name">${e.name}</span>
              <span class="item-meta">${e.roles.join(", ")} &middot; ${e.target_weekly_hours}h/wk &middot; Started ${e.start_date}</span>
            </div>
            <div class="kebab-wrap">
              <button class="kebab-btn" data-id="${e.id}" title="More options">&#8942;</button>
              <div class="kebab-dropdown" id="kebab-${e.id}">
                <button class="kebab-item edit-emp" data-id="${e.id}">Edit</button>
                <button class="kebab-item kebab-delete delete-emp" data-id="${e.id}">Delete</button>
              </div>
            </div>
          </div>`
          )
          .join("")}
      </div>
    </div>
  `;

  document.getElementById("add-employee-btn")!.addEventListener("click", () => {
    currentView = "create-employee";
    document.querySelectorAll(".nav-btn").forEach((b) => b.classList.remove("active"));
    renderView();
  });

  document.querySelectorAll(".item-row").forEach((row) => {
    row.addEventListener("click", (e) => {
      const target = e.target as HTMLElement;
      // Don't navigate if clicking the kebab area
      if (target.closest(".kebab-wrap")) return;
      selectedEmployeeId = parseInt((row as HTMLElement).dataset.id!);
      currentView = "employee-detail";
      document.querySelectorAll(".nav-btn").forEach((b) => b.classList.remove("active"));
      renderView();
    });
  });

  // Kebab toggle
  document.querySelectorAll(".kebab-btn").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const id = (btn as HTMLElement).dataset.id!;
      const dropdown = document.getElementById(`kebab-${id}`)!;
      const isOpen = dropdown.classList.contains("open");
      // Close all open dropdowns first
      document.querySelectorAll(".kebab-dropdown.open").forEach((d) => d.classList.remove("open"));
      if (!isOpen) dropdown.classList.add("open");
    });
  });

  // Close dropdowns on outside click
  document.addEventListener("click", closeKebabs);
  const prevCleanup = cleanupCurrentView;
  cleanupCurrentView = () => {
    prevCleanup?.();
    document.removeEventListener("click", closeKebabs);
  };

  document.querySelectorAll(".edit-emp").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      editEmployeeId = parseInt((btn as HTMLElement).dataset.id!);
      currentView = "edit-employee";
      document.querySelectorAll(".nav-btn").forEach((b) => b.classList.remove("active"));
      renderView();
    });
  });

  document.querySelectorAll(".delete-emp").forEach((btn) => {
    btn.addEventListener("click", async (e) => {
      e.stopPropagation();
      const id = parseInt((e.target as HTMLElement).dataset.id!);
      await invoke("delete_employee", { id });
      await fetchEmployees();
      renderEmployeesView();
    });
  });
}

function closeKebabs() {
  document.querySelectorAll(".kebab-dropdown.open").forEach((d) => d.classList.remove("open"));
}

function renderCreateEmployeeView() {
  const content = document.getElementById("content")!;

  content.innerHTML = `
    <div class="detail-header">
      <button class="back-btn" id="back-to-list">&larr; Back</button>
      <h1>New Employee</h1>
    </div>
    <div class="card">
      <div class="create-form">
        <div class="form-group">
          <label>Name *</label>
          <input id="emp-name" type="text" placeholder="Employee name" />
        </div>
        <div class="form-group">
          <label>Roles * (comma-separated)</label>
          <input id="emp-roles" type="text" placeholder="barista, cashier" />
        </div>
        <div class="form-group">
          <label>Start Date *</label>
          <input id="emp-start-date" type="date" value="${todayISO()}" />
        </div>
        <h3 class="form-section-title">Work Preferences</h3>
        <div class="form-row">
          <div class="form-group">
            <label>Target Weekly Hours *</label>
            <input id="emp-target-weekly" type="number" value="30" step="0.5" min="0" />
          </div>
          <div class="form-group">
            <label>Weekly Deviation (+/-) *</label>
            <input id="emp-deviation" type="number" value="6" step="0.5" min="0" />
          </div>
          <div class="form-group">
            <label>Max Daily Hours *</label>
            <input id="emp-daily" type="number" value="8" step="0.5" min="0" />
          </div>
        </div>
        <h3 class="form-section-title">Optional</h3>
        <div class="form-group">
          <label>Notes</label>
          <textarea id="emp-notes" rows="3" placeholder="Any notes about this employee..."></textarea>
        </div>
        <div class="form-group">
          <label>Bank Details</label>
          <input id="emp-bank" type="text" placeholder="BSB / Account number" />
        </div>
        <button class="btn-primary" id="create-emp-btn" style="margin-top: 1rem;">Create Employee</button>
      </div>
    </div>
  `;

  document.getElementById("back-to-list")!.addEventListener("click", () => {
    currentView = "employees";
    document.querySelectorAll(".nav-btn").forEach((b) => b.classList.remove("active"));
    document.querySelector('[data-view="employees"]')?.classList.add("active");
    renderView();
  });

  document.getElementById("create-emp-btn")!.addEventListener("click", async () => {
    const name = (document.getElementById("emp-name") as HTMLInputElement).value.trim();
    const rolesStr = (document.getElementById("emp-roles") as HTMLInputElement).value.trim();
    const startDate = (document.getElementById("emp-start-date") as HTMLInputElement).value;
    const targetWeekly = parseFloat((document.getElementById("emp-target-weekly") as HTMLInputElement).value);
    const deviation = parseFloat((document.getElementById("emp-deviation") as HTMLInputElement).value);
    const daily = parseFloat((document.getElementById("emp-daily") as HTMLInputElement).value);
    const notes = (document.getElementById("emp-notes") as HTMLTextAreaElement).value.trim() || null;
    const bank = (document.getElementById("emp-bank") as HTMLInputElement).value.trim() || null;

    if (!name || !rolesStr || !startDate) return;

    const roles = parseRoles(rolesStr);

    await invoke("create_employee", {
      employee: {
        id: 0,
        name,
        roles,
        start_date: startDate,
        target_weekly_hours: targetWeekly,
        weekly_hours_deviation: deviation,
        max_daily_hours: daily,
        notes,
        bank_details: bank,
        default_availability: {},
        availability: {},
      },
    });

    await fetchEmployees();
    // Navigate to the employees list
    currentView = "employees";
    document.querySelectorAll(".nav-btn").forEach((b) => b.classList.remove("active"));
    document.querySelector('[data-view="employees"]')?.classList.add("active");
    renderView();
  });
}

async function renderEditEmployeeView() {
  const content = document.getElementById("content")!;
  if (editEmployeeId === null) {
    currentView = "employees";
    renderEmployeesView();
    return;
  }

  const emp: Employee | null = await invoke("get_employee", { id: editEmployeeId });
  if (!emp) {
    currentView = "employees";
    renderEmployeesView();
    return;
  }

  content.innerHTML = `
    <div class="detail-header">
      <button class="back-btn" id="back-to-list">&larr; Back</button>
      <h1>Edit Employee</h1>
    </div>
    <div class="card">
      <div class="create-form">
        <div class="form-group">
          <label>Name *</label>
          <input id="emp-name" type="text" value="${emp.name}" />
        </div>
        <div class="form-group">
          <label>Roles * (comma-separated)</label>
          <input id="emp-roles" type="text" value="${emp.roles.join(", ")}" />
        </div>
        <div class="form-group">
          <label>Start Date *</label>
          <input id="emp-start-date" type="date" value="${emp.start_date}" />
        </div>
        <h3 class="form-section-title">Work Preferences</h3>
        <div class="form-row">
          <div class="form-group">
            <label>Target Weekly Hours *</label>
            <input id="emp-target-weekly" type="number" value="${emp.target_weekly_hours}" step="0.5" min="0" />
          </div>
          <div class="form-group">
            <label>Weekly Deviation (+/-) *</label>
            <input id="emp-deviation" type="number" value="${emp.weekly_hours_deviation}" step="0.5" min="0" />
          </div>
          <div class="form-group">
            <label>Max Daily Hours *</label>
            <input id="emp-daily" type="number" value="${emp.max_daily_hours}" step="0.5" min="0" />
          </div>
        </div>
        <h3 class="form-section-title">Optional</h3>
        <div class="form-group">
          <label>Notes</label>
          <textarea id="emp-notes" rows="3">${emp.notes ?? ""}</textarea>
        </div>
        <div class="form-group">
          <label>Bank Details</label>
          <input id="emp-bank" type="text" value="${emp.bank_details ?? ""}" />
        </div>
        <button class="btn-primary" id="save-emp-btn" style="margin-top: 1rem;">Save Changes</button>
      </div>
    </div>
  `;

  document.getElementById("back-to-list")!.addEventListener("click", () => {
    editEmployeeId = null;
    currentView = "employees";
    document.querySelectorAll(".nav-btn").forEach((b) => b.classList.remove("active"));
    document.querySelector('[data-view="employees"]')?.classList.add("active");
    renderView();
  });

  document.getElementById("save-emp-btn")!.addEventListener("click", async () => {
    const name = (document.getElementById("emp-name") as HTMLInputElement).value.trim();
    const rolesStr = (document.getElementById("emp-roles") as HTMLInputElement).value.trim();
    const startDate = (document.getElementById("emp-start-date") as HTMLInputElement).value;
    const targetWeekly = parseFloat((document.getElementById("emp-target-weekly") as HTMLInputElement).value);
    const deviation = parseFloat((document.getElementById("emp-deviation") as HTMLInputElement).value);
    const daily = parseFloat((document.getElementById("emp-daily") as HTMLInputElement).value);
    const notes = (document.getElementById("emp-notes") as HTMLTextAreaElement).value.trim() || null;
    const bank = (document.getElementById("emp-bank") as HTMLInputElement).value.trim() || null;

    if (!name || !rolesStr || !startDate) return;

    const roles = parseRoles(rolesStr);

    await invoke("update_employee", {
      employee: {
        ...emp,
        name,
        roles,
        start_date: startDate,
        target_weekly_hours: targetWeekly,
        weekly_hours_deviation: deviation,
        max_daily_hours: daily,
        notes,
        bank_details: bank,
      },
    });

    await fetchEmployees();
    editEmployeeId = null;
    currentView = "employees";
    document.querySelectorAll(".nav-btn").forEach((b) => b.classList.remove("active"));
    document.querySelector('[data-view="employees"]')?.classList.add("active");
    renderView();
  });
}

async function renderEmployeeDetailView() {
  const content = document.getElementById("content")!;
  if (selectedEmployeeId === null) {
    currentView = "employees";
    renderEmployeesView();
    return;
  }

  const emp: Employee | null = await invoke("get_employee", { id: selectedEmployeeId });
  if (!emp) {
    currentView = "employees";
    renderEmployeesView();
    return;
  }

  const weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
  const hours = Array.from({ length: 24 }, (_, i) => i);

  content.innerHTML = `
    <div class="detail-header">
      <button class="back-btn" id="back-to-list">&larr; Back</button>
      <h1>${emp.name}</h1>
    </div>
    <div class="card">
      <div class="detail-meta">
        <div class="meta-item"><strong>Roles:</strong> ${emp.roles.join(", ") || "None"}</div>
        <div class="meta-item"><strong>Start Date:</strong> ${emp.start_date}</div>
        <div class="meta-item"><strong>Target Weekly:</strong> ${emp.target_weekly_hours}h (${"\u00B1"}${emp.weekly_hours_deviation}h)</div>
        <div class="meta-item"><strong>Max Daily:</strong> ${emp.max_daily_hours}h</div>
      </div>
      ${emp.notes ? `<div class="detail-notes"><strong>Notes:</strong> ${emp.notes}</div>` : ""}
      ${emp.bank_details ? `<div class="detail-notes"><strong>Bank Details:</strong> ${emp.bank_details}</div>` : ""}
    </div>
    <div class="card">
      <h2 style="font-size:1.1rem; margin-bottom:0.75rem;">Default Availability</h2>
      <div class="avail-toolbar">
        <span style="font-size:0.8rem; color:#555;">Apply to selection:</span>
        <button class="paint-btn" data-state="Yes">Yes <kbd>Y</kbd></button>
        <button class="paint-btn" data-state="Maybe">Maybe <kbd>M</kbd></button>
        <button class="paint-btn" data-state="No">No <kbd>N</kbd></button>
        <span style="font-size:0.75rem; color:#999; margin-left:0.5rem;">Click to select, Shift+click for range</span>
        <button class="btn-primary" id="save-avail" style="margin-left:auto;">Save Availability</button>
      </div>
      <div class="avail-grid-wrap"><div class="avail-grid" id="avail-grid">
        <div class="header-cell"></div>
        ${weekdays.map((d) => `<div class="header-cell">${d}</div>`).join("")}
        ${hours
          .map((h) => {
            const label = `${h.toString().padStart(2, "0")}:00`;
            const cells = weekdays
              .map((d) => {
                const key = `${d}:${h}`;
                const state = emp.default_availability[key] || "Maybe";
                return `<div class="avail-cell" data-day="${d}" data-hour="${h}" data-state="${state}"></div>`;
              })
              .join("");
            return `<div class="hour-label">${label}</div>${cells}`;
          })
          .join("")}
      </div></div>
      <div class="avail-legend">
        <span><span class="legend-swatch yes"></span> Available</span>
        <span><span class="legend-swatch maybe"></span> Maybe</span>
        <span><span class="legend-swatch no"></span> Unavailable</span>
      </div>
    </div>
  `;

  // ─── Back button ───────────────────────────────────────
  document.getElementById("back-to-list")!.addEventListener("click", () => {
    selectedEmployeeId = null;
    currentView = "employees";
    renderView();
  });

  // ─── Selection state ────────────────────────────────────
  const grid = document.getElementById("avail-grid")!;
  const allCells = Array.from(grid.querySelectorAll(".avail-cell")) as HTMLElement[];
  const NUM_DAYS = 7;

  // Cell index -> (col, row) where col=day index, row=hour index
  function cellCoords(idx: number): [number, number] {
    return [idx % NUM_DAYS, Math.floor(idx / NUM_DAYS)];
  }

  function cellAt(col: number, row: number): HTMLElement {
    return allCells[row * NUM_DAYS + col];
  }

  let anchorIndex: number | null = null; // the cell that started the selection

  const SEL_BORDER = "#2980b9";
  const B = 2; // border width in px

  function clearSelection() {
    allCells.forEach((c) => {
      c.classList.remove("avail-selected");
      c.style.boxShadow = "";
    });
  }

  function selectRect(col1: number, row1: number, col2: number, row2: number) {
    const minCol = Math.min(col1, col2);
    const maxCol = Math.max(col1, col2);
    const minRow = Math.min(row1, row2);
    const maxRow = Math.max(row1, row2);
    for (let r = minRow; r <= maxRow; r++) {
      for (let c = minCol; c <= maxCol; c++) {
        const cell = cellAt(c, r);
        cell.classList.add("avail-selected");
        const shadows: string[] = [];
        if (r === minRow) shadows.push(`inset 0 ${B}px 0 0 ${SEL_BORDER}`);
        if (r === maxRow) shadows.push(`inset 0 -${B}px 0 0 ${SEL_BORDER}`);
        if (c === minCol) shadows.push(`inset ${B}px 0 0 0 ${SEL_BORDER}`);
        if (c === maxCol) shadows.push(`inset -${B}px 0 0 0 ${SEL_BORDER}`);
        cell.style.boxShadow = shadows.join(", ");
      }
    }
  }

  function getSelectedCells(): HTMLElement[] {
    return allCells.filter((c) => c.classList.contains("avail-selected"));
  }

  function applyState(state: "Yes" | "Maybe" | "No") {
    const selected = getSelectedCells();
    if (selected.length === 0) return;
    selected.forEach((c) => { c.dataset.state = state; });
  }

  // ─── Grid click: select / shift+click rectangle ───────
  grid.addEventListener("mousedown", (e) => {
    const cell = (e.target as HTMLElement).closest(".avail-cell") as HTMLElement | null;
    if (!cell) return;
    e.preventDefault();

    const idx = allCells.indexOf(cell);
    if (idx === -1) return;

    if (e.shiftKey && anchorIndex !== null) {
      // Rectangle select from anchor to this cell
      const [ac, ar] = cellCoords(anchorIndex);
      const [cc, cr] = cellCoords(idx);
      if (!e.metaKey && !e.ctrlKey) clearSelection();
      selectRect(ac, ar, cc, cr);
    } else if (e.metaKey || e.ctrlKey) {
      // Toggle individual cell
      cell.classList.toggle("avail-selected");
      if (cell.classList.contains("avail-selected")) {
        cell.style.boxShadow = `inset ${B}px ${B}px 0 0 ${SEL_BORDER}, inset -${B}px -${B}px 0 0 ${SEL_BORDER}`;
      } else {
        cell.style.boxShadow = "";
      }
      anchorIndex = idx;
    } else {
      // Single click: clear others, select this one
      clearSelection();
      cell.classList.add("avail-selected");
      cell.style.boxShadow = `inset ${B}px ${B}px 0 0 ${SEL_BORDER}, inset -${B}px -${B}px 0 0 ${SEL_BORDER}`;
      anchorIndex = idx;
    }
  });

  // ─── Toolbar buttons apply state to selection ──────────
  document.querySelectorAll(".paint-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const state = (btn as HTMLElement).dataset.state as "Yes" | "Maybe" | "No";
      applyState(state);
    });
  });

  // ─── Keyboard: Y/M/N apply state to selection ─────────
  function handleAvailKeydown(e: KeyboardEvent) {
    const key = e.key.toLowerCase();
    if (key === "y") { applyState("Yes"); e.preventDefault(); }
    else if (key === "m") { applyState("Maybe"); e.preventDefault(); }
    else if (key === "n") { applyState("No"); e.preventDefault(); }
    else if (key === "a" && (e.metaKey || e.ctrlKey)) {
      // Select all cells
      e.preventDefault();
      allCells.forEach((c) => c.classList.add("avail-selected"));
    } else if (key === "escape") {
      clearSelection();
    }
  }
  document.addEventListener("keydown", handleAvailKeydown);
  cleanupCurrentView = () => document.removeEventListener("keydown", handleAvailKeydown);

  // ─── Save availability ─────────────────────────────────
  document.getElementById("save-avail")!.addEventListener("click", async () => {
    const cells = grid.querySelectorAll(".avail-cell");
    const avail: Record<string, string> = {};
    cells.forEach((cell) => {
      const el = cell as HTMLElement;
      const day = el.dataset.day!;
      const hour = el.dataset.hour!;
      const state = el.dataset.state || "Maybe";
      avail[`${day}:${hour}`] = state;
    });

    const updated: Employee = {
      ...emp,
      default_availability: avail,
      availability: avail,
    };

    await invoke("update_employee", { employee: updated });
    await fetchEmployees();

    const btn = document.getElementById("save-avail") as HTMLButtonElement;
    btn.textContent = "Saved!";
    setTimeout(() => { btn.textContent = "Save Availability"; }, 1500);
  });
}

const DAY_LETTERS: Record<string, string> = {
  Mon: "M", Tue: "T", Wed: "W", Thu: "R", Fri: "F", Sat: "A", Sun: "S",
};

function weekdaysToLetters(days: string[]): string {
  return days.map((d) => DAY_LETTERS[d] || d).join("");
}

async function renderEditShiftTemplateView() {
  const content = document.getElementById("content")!;
  if (editShiftTemplateId === null) {
    currentView = "shifts";
    renderShiftsView();
    return;
  }

  const tmpl = shiftTemplates.find((t) => t.id === editShiftTemplateId);
  if (!tmpl) {
    currentView = "shifts";
    renderShiftsView();
    return;
  }

  const weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

  content.innerHTML = `
    <div class="detail-header">
      <button class="back-btn" id="back-to-shifts">&larr; Back</button>
      <h1>Edit Shift Template</h1>
    </div>
    <div class="card">
      <div class="create-form">
        <div class="form-group">
          <label>Name</label>
          <input id="tmpl-name" type="text" value="${tmpl.name}" />
        </div>
        <div class="form-group">
          <label>Days</label>
          <div class="day-checkboxes">
            ${weekdays.map((d) => `<label class="day-check"><input type="checkbox" value="${d}" ${tmpl.weekdays.includes(d) ? "checked" : ""} />${DAY_LETTERS[d]}</label>`).join("")}
          </div>
        </div>
        <div class="form-row">
          <div class="form-group">
            <label>Start</label>
            <input id="tmpl-start" type="time" value="${tmpl.start_time.slice(0, 5)}" />
          </div>
          <div class="form-group">
            <label>End</label>
            <input id="tmpl-end" type="time" value="${tmpl.end_time.slice(0, 5)}" />
          </div>
          <div class="form-group">
            <label>Role</label>
            <input id="tmpl-role" type="text" value="${tmpl.required_role}" />
          </div>
          <div class="form-group">
            <label>Min Staff</label>
            <input id="tmpl-min" type="number" value="${tmpl.min_employees}" min="1" />
          </div>
          <div class="form-group">
            <label>Max Staff</label>
            <input id="tmpl-max" type="number" value="${tmpl.max_employees}" min="1" />
          </div>
        </div>
        <button class="btn-primary" id="save-tmpl-btn" style="margin-top: 1rem;">Save Changes</button>
      </div>
    </div>
  `;

  document.getElementById("back-to-shifts")!.addEventListener("click", () => {
    editShiftTemplateId = null;
    currentView = "shifts";
    document.querySelectorAll(".nav-btn").forEach((b) => b.classList.remove("active"));
    document.querySelector('[data-view="shifts"]')?.classList.add("active");
    renderView();
  });

  document.getElementById("save-tmpl-btn")!.addEventListener("click", async () => {
    const name = (document.getElementById("tmpl-name") as HTMLInputElement).value.trim();
    const checked = Array.from(document.querySelectorAll(".day-checkboxes input:checked")) as HTMLInputElement[];
    const selectedDays = checked.map((cb) => cb.value);
    const startVal = (document.getElementById("tmpl-start") as HTMLInputElement).value;
    const endVal = (document.getElementById("tmpl-end") as HTMLInputElement).value;
    const role = (document.getElementById("tmpl-role") as HTMLInputElement).value.trim();
    const minEmp = parseInt((document.getElementById("tmpl-min") as HTMLInputElement).value);
    const maxEmp = parseInt((document.getElementById("tmpl-max") as HTMLInputElement).value);

    if (!name || !role || selectedDays.length === 0) return;

    await invoke("update_shift_template", {
      template: {
        ...tmpl,
        name,
        weekdays: selectedDays,
        start_time: startVal + ":00",
        end_time: endVal + ":00",
        required_role: toTitleCase(role),
        min_employees: minEmp,
        max_employees: maxEmp,
      },
    });

    await fetchShiftTemplates();
    editShiftTemplateId = null;
    currentView = "shifts";
    document.querySelectorAll(".nav-btn").forEach((b) => b.classList.remove("active"));
    document.querySelector('[data-view="shifts"]')?.classList.add("active");
    renderView();
  });
}

function renderCreateShiftTemplateView() {
  const content = document.getElementById("content")!;
  const weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

  content.innerHTML = `
    <div class="detail-header">
      <button class="back-btn" id="back-to-shifts">&larr; Back</button>
      <h1>New Shift Template</h1>
    </div>
    <div class="card">
      <div class="create-form">
        <div class="form-group">
          <label>Name</label>
          <input id="tmpl-name" type="text" placeholder="Morning Barista" />
        </div>
        <div class="form-group">
          <label>Days</label>
          <div class="day-checkboxes">
            ${weekdays.map((d) => `<label class="day-check"><input type="checkbox" value="${d}" checked />${DAY_LETTERS[d]}</label>`).join("")}
          </div>
        </div>
        <div class="form-row">
          <div class="form-group">
            <label>Start</label>
            <input id="tmpl-start" type="time" value="07:00" />
          </div>
          <div class="form-group">
            <label>End</label>
            <input id="tmpl-end" type="time" value="12:00" />
          </div>
          <div class="form-group">
            <label>Role</label>
            <input id="tmpl-role" type="text" placeholder="Barista" />
          </div>
          <div class="form-group">
            <label>Min Staff</label>
            <input id="tmpl-min" type="number" value="1" min="1" />
          </div>
          <div class="form-group">
            <label>Max Staff</label>
            <input id="tmpl-max" type="number" value="1" min="1" />
          </div>
        </div>
        <button class="btn-primary" id="add-tmpl-btn" style="margin-top: 1rem;">Create Shift Template</button>
      </div>
    </div>
  `;

  document.getElementById("back-to-shifts")!.addEventListener("click", () => {
    currentView = "shifts";
    document.querySelectorAll(".nav-btn").forEach((b) => b.classList.remove("active"));
    document.querySelector('[data-view="shifts"]')?.classList.add("active");
    renderView();
  });

  document.getElementById("add-tmpl-btn")!.addEventListener("click", async () => {
    const name = (document.getElementById("tmpl-name") as HTMLInputElement).value.trim();
    const checked = Array.from(document.querySelectorAll(".day-checkboxes input:checked")) as HTMLInputElement[];
    const selectedDays = checked.map((cb) => cb.value);
    const startVal = (document.getElementById("tmpl-start") as HTMLInputElement).value;
    const endVal = (document.getElementById("tmpl-end") as HTMLInputElement).value;
    const role = (document.getElementById("tmpl-role") as HTMLInputElement).value.trim();
    const minEmp = parseInt((document.getElementById("tmpl-min") as HTMLInputElement).value);
    const maxEmp = parseInt((document.getElementById("tmpl-max") as HTMLInputElement).value);

    if (!name || !role || selectedDays.length === 0) return;

    await invoke("create_shift_template", {
      template: {
        id: 0,
        name,
        weekdays: selectedDays,
        start_time: startVal + ":00",
        end_time: endVal + ":00",
        required_role: toTitleCase(role),
        min_employees: minEmp,
        max_employees: maxEmp,
      },
    });

    await fetchShiftTemplates();
    currentView = "shifts";
    document.querySelectorAll(".nav-btn").forEach((b) => b.classList.remove("active"));
    document.querySelector('[data-view="shifts"]')?.classList.add("active");
    renderView();
  });
}

function renderShiftsView() {
  const content = document.getElementById("content")!;

  content.innerHTML = `
    <h1>Shift Templates</h1>
    <div class="card">
      <button class="btn-add-item" id="add-tmpl-btn">+</button>
      <div class="item-list">
        ${shiftTemplates.length === 0 ? '<p class="empty-state">No shift templates yet. Click + to add one.</p>' : ""}
        ${shiftTemplates
          .map(
            (t) => `
          <div class="item-row" data-id="${t.id}">
            <div class="item-info">
              <span class="item-name">${t.name}</span>
              <span class="item-meta">${t.required_role} &middot; ${weekdaysToLetters(t.weekdays)} &middot; ${t.start_time.slice(0, 5)}–${t.end_time.slice(0, 5)} &middot; ${t.min_employees}–${t.max_employees} staff</span>
            </div>
            <div class="kebab-wrap">
              <button class="kebab-btn tmpl-kebab-btn" data-id="${t.id}" title="More options">&#8942;</button>
              <div class="kebab-dropdown" id="tmpl-kebab-${t.id}">
                <button class="kebab-item edit-tmpl" data-id="${t.id}">Edit</button>
                <button class="kebab-item kebab-delete delete-tmpl" data-id="${t.id}">Delete</button>
              </div>
            </div>
          </div>`
          )
          .join("")}
      </div>
    </div>
  `;

  document.getElementById("add-tmpl-btn")!.addEventListener("click", () => {
    currentView = "create-shift-template";
    document.querySelectorAll(".nav-btn").forEach((b) => b.classList.remove("active"));
    renderView();
  });

  document.querySelectorAll(".item-row").forEach((row) => {
    row.addEventListener("click", (e) => {
      if ((e.target as HTMLElement).closest(".kebab-wrap")) return;
      editShiftTemplateId = parseInt((row as HTMLElement).dataset.id!);
      currentView = "edit-shift-template";
      renderView();
    });
  });

  document.querySelectorAll(".tmpl-kebab-btn").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const id = (btn as HTMLElement).dataset.id!;
      const dropdown = document.getElementById(`tmpl-kebab-${id}`)!;
      const isOpen = dropdown.classList.contains("open");
      document.querySelectorAll(".kebab-dropdown.open").forEach((d) => d.classList.remove("open"));
      if (!isOpen) dropdown.classList.add("open");
    });
  });

  document.addEventListener("click", closeKebabs);
  const prevCleanup = cleanupCurrentView;
  cleanupCurrentView = () => {
    prevCleanup?.();
    document.removeEventListener("click", closeKebabs);
  };

  document.querySelectorAll(".edit-tmpl").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      editShiftTemplateId = parseInt((btn as HTMLElement).dataset.id!);
      currentView = "edit-shift-template";
      renderView();
    });
  });

  document.querySelectorAll(".delete-tmpl").forEach((btn) => {
    btn.addEventListener("click", async (e) => {
      e.stopPropagation();
      const id = parseInt((e.target as HTMLElement).dataset.id!);
      try {
        await invoke("delete_shift_template", { id });
      } catch (err) {
        alert(`Failed to delete shift template: ${err}`);
      }
      await fetchShiftTemplates();
      renderShiftsView();
    });
  });
}

let rotaViewMode: "template" | "assigned" = "template";

async function renderRotaView() {
  const content = document.getElementById("content")!;
  const weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

  // Fetch shift templates and existing schedule
  await fetchShiftTemplates();
  console.log("[Rota] Fetched", shiftTemplates.length, "shift templates");

  let schedule: WeekSchedule | null = null;
  try {
    schedule = await invoke("get_week_schedule", { weekStart: selectedWeek });
    console.log("[Rota] Week schedule:", schedule ? `rota_id=${schedule.rota_id}, ${schedule.entries.length} entries, finalized=${schedule.finalized}` : "none");
    if (schedule && schedule.entries.length > 0) {
      console.log("[Rota] Entries:", schedule.entries.map(e => `${e.weekday} ${e.start_time}-${e.end_time} ${e.required_role}: ${e.employee_name} (${e.status})`));
    }
  } catch (err) {
    console.warn("[Rota] No schedule for week:", err);
  }

  const hasAssignments = schedule !== null && schedule.entries.length > 0;
  console.log("[Rota] hasAssignments:", hasAssignments, "rotaViewMode:", rotaViewMode);

  content.innerHTML = `
    <h1>Week of ${formatWeekLabel(selectedWeek)}</h1>
    <div class="card">
      <div class="form-row">
        <button class="btn-primary" id="generate-btn">Generate Schedule</button>
      </div>
      <div class="form-group" style="margin-top: 0.5rem;">
        <label>View</label>
        <select id="rota-view-select">
          <option value="template" ${rotaViewMode === "template" ? "selected" : ""}>Template View</option>
          <option value="assigned" ${rotaViewMode === "assigned" ? "selected" : ""} ${!hasAssignments ? "disabled" : ""}>Assigned Shifts${!hasAssignments ? " (no schedule yet)" : ""}</option>
        </select>
      </div>
      <div id="schedule-warnings"></div>
    </div>
    <div class="card" id="schedule-grid">
      ${renderRotaGrid(weekdays, schedule)}
    </div>
  `;

  // Generate button
  document.getElementById("generate-btn")!.addEventListener("click", async () => {
    const btn = document.getElementById("generate-btn") as HTMLButtonElement;
    btn.disabled = true;
    btn.textContent = "Generating...";
    console.log("[Generate] Starting schedule for week:", selectedWeek);
    try {
      const result: ScheduleResult = await invoke("run_schedule", { weekStart: selectedWeek });
      console.log("[Generate] Result:", JSON.stringify(result, null, 2));
      console.log("[Generate] Assignments:", result.assignments.length, "Warnings:", result.warnings.length);
      if (result.warnings.length > 0) {
        const warningsEl = document.getElementById("schedule-warnings")!;
        warningsEl.innerHTML = result.warnings.map(w =>
          `<p style="color: orange;">Warning: Shift ${w.shift_id} needs ${w.needed} staff but only ${w.filled} assigned.</p>`
        ).join("");
      }
      rotaViewMode = "assigned";
      console.log("[Generate] Switching to assigned view, re-rendering...");
      await renderRotaView();
    } catch (err) {
      console.error("[Generate] Error:", err);
      alert(`Schedule error: ${err}`);
      btn.disabled = false;
      btn.textContent = "Generate Schedule";
    }
  });

  // View mode dropdown
  document.getElementById("rota-view-select")!.addEventListener("change", (e) => {
    rotaViewMode = (e.target as HTMLSelectElement).value as "template" | "assigned";
    console.log("[Rota] View mode changed to:", rotaViewMode);
    renderRotaView();
  });
}

interface RotaShiftCard {
  name: string;
  startTime: string;
  endTime: string;
  role: string;
  employees: { name: string; status: string }[];
}

function renderRotaGrid(weekdays: string[], schedule: WeekSchedule | null): string {
  console.log("[RotaGrid] Rendering mode:", rotaViewMode, "entries:", schedule?.entries.length ?? 0);
  const byDay: Record<string, RotaShiftCard[]> = {};
  for (const day of weekdays) byDay[day] = [];

  if (rotaViewMode === "assigned" && schedule && schedule.entries.length > 0) {
    // Group entries by day + shift_id to combine multiple employees per shift
    const shiftMap: Record<string, Record<number, { entry: ScheduleEntry; employees: { name: string; status: string }[] }>> = {};
    for (const day of weekdays) shiftMap[day] = {};

    for (const entry of schedule.entries) {
      if (!shiftMap[entry.weekday]) continue;
      if (!shiftMap[entry.weekday][entry.shift_id]) {
        shiftMap[entry.weekday][entry.shift_id] = { entry, employees: [] };
      }
      shiftMap[entry.weekday][entry.shift_id].employees.push({
        name: entry.employee_name,
        status: entry.status,
      });
    }

    for (const day of weekdays) {
      const shifts = Object.values(shiftMap[day]);
      shifts.sort((a, b) => a.entry.start_time.localeCompare(b.entry.start_time));
      for (const s of shifts) {
        byDay[day].push({
          name: s.entry.required_role,
          startTime: s.entry.start_time,
          endTime: s.entry.end_time,
          role: s.entry.required_role,
          employees: s.employees,
        });
      }
    }
  } else {
    // Template view: expand shift templates into weekday columns
    for (const tmpl of shiftTemplates) {
      for (const day of tmpl.weekdays) {
        if (!byDay[day]) continue;
        byDay[day].push({
          name: tmpl.name,
          startTime: tmpl.start_time.slice(0, 5),
          endTime: tmpl.end_time.slice(0, 5),
          role: tmpl.required_role,
          employees: [],
        });
      }
    }
    // Sort each day by start time
    for (const day of weekdays) {
      byDay[day].sort((a, b) => a.startTime.localeCompare(b.startTime));
    }
  }

  // Find max shifts in any day for consistent grid height
  const maxShifts = Math.max(1, ...weekdays.map((d) => byDay[d].length));
  const isEmpty = weekdays.every((d) => byDay[d].length === 0);

  if (isEmpty) {
    return rotaViewMode === "template"
      ? `<p>No shift templates configured. Go to the <strong>Shifts</strong> tab to add some.</p>`
      : `<p>Schedule generated but no assignments were made. Check that employees and shift templates are configured.</p>`;
  }

  let html = `<div class="rota-grid-wrap"><div class="rota-grid" style="grid-template-columns: repeat(7, 1fr);">`;

  // Header row
  for (const day of weekdays) {
    html += `<div class="rota-day-header">${day}</div>`;
  }

  // Shift cards row by row
  for (let row = 0; row < maxShifts; row++) {
    for (const day of weekdays) {
      const shift = byDay[day][row];
      if (shift) {
        const empHtml = shift.employees.length > 0
          ? shift.employees.map((e) => {
              const cls = e.status === "Confirmed" ? "status-confirmed" : e.status === "Overridden" ? "status-overridden" : "status-proposed";
              return `<div class="rota-employee ${cls}">${e.name}</div>`;
            }).join("")
          : "";

        html += `<div class="rota-shift-card">
          <div class="rota-shift-name">${shift.name}</div>
          <div class="rota-shift-time">${shift.startTime} – ${shift.endTime}</div>
          ${empHtml}
        </div>`;
      } else {
        html += `<div class="rota-shift-empty"></div>`;
      }
    }
  }

  html += `</div></div>`;
  return html;
}

async function renderView() {
  cleanupCurrentView?.();
  cleanupCurrentView = null;
  switch (currentView) {
    case "employees":
      renderEmployeesView();
      break;
    case "create-employee":
      renderCreateEmployeeView();
      break;
    case "edit-employee":
      await renderEditEmployeeView();
      break;
    case "employee-detail":
      await renderEmployeeDetailView();
      break;
    case "shifts":
      renderShiftsView();
      break;
    case "create-shift-template":
      renderCreateShiftTemplateView();
      break;
    case "edit-shift-template":
      await renderEditShiftTemplateView();
      break;
    case "rota":
      await renderRotaView();
      break;
  }
}

// ─── Navigation ─────────────────────────────────────────────

function setupNav() {
  document.querySelectorAll(".nav-btn").forEach((btn) => {
    btn.addEventListener("click", async () => {
      document.querySelectorAll(".nav-btn").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      currentView = (btn as HTMLElement).dataset.view!;

      // Close sidebar on mobile after navigation
      if (window.matchMedia("(max-width: 768px)").matches) {
        document.getElementById("sidebar")!.classList.add("collapsed");
      }

      if (currentView === "shifts") await fetchShiftTemplates();
      renderView();
    });
  });
}

// ─── Week navigation ─────────────────────────────────────────

function formatWeekLabel(isoDate: string): string {
  const d = new Date(isoDate + "T00:00:00");
  return d.toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" });
}

function updateWeekLabel() {
  const el = document.getElementById("week-label");
  if (el) el.textContent = formatWeekLabel(selectedWeek);
}

function shiftWeek(delta: number) {
  const d = new Date(selectedWeek + "T00:00:00");
  d.setDate(d.getDate() + delta * 7);
  selectedWeek = toLocalISODate(getMonday(d));
  updateWeekLabel();
  if (currentView === "rota") renderRotaView();
}

function setupWeekNav() {
  updateWeekLabel();
  document.getElementById("week-prev")!.addEventListener("click", () => shiftWeek(-1));
  document.getElementById("week-next")!.addEventListener("click", () => shiftWeek(1));
}

// ─── Sidebar toggle ─────────────────────────────────────────

function setupSidebar() {
  const sidebar = document.getElementById("sidebar")!;
  const toggle = document.getElementById("sidebar-toggle")!;
  const close = document.getElementById("sidebar-close")!;

  function isMobile() {
    return window.matchMedia("(max-width: 768px)").matches;
  }

  // Start collapsed on mobile
  if (isMobile()) sidebar.classList.add("collapsed");

  toggle.addEventListener("click", () => {
    sidebar.classList.remove("collapsed");
  });

  close.addEventListener("click", () => {
    sidebar.classList.add("collapsed");
  });

  // Close sidebar when navigating on mobile
  sidebar.querySelectorAll(".nav-btn, .employee-item").forEach((el) => {
    el.addEventListener("click", () => {
      if (isMobile()) sidebar.classList.add("collapsed");
    });
  });

  // Collapse/expand on resize
  window.addEventListener("resize", () => {
    if (!isMobile()) {
      sidebar.classList.remove("collapsed");
    }
  });
}

// ─── Boot ───────────────────────────────────────────────────

async function main() {
  try {
    await initDb();
    await fetchEmployees();
    setupSidebar();
    setupWeekNav();
    setupNav();
    renderView();
  } catch (err) {
    document.getElementById("content")!.innerHTML = `
      <div class="card"><p style="color:red">Error: ${err}</p></div>
    `;
  }
}

main();
