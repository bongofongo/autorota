import { invoke } from "@tauri-apps/api/core";

// ─── Types (mirror Rust models) ─────────────────────────────

interface Employee {
  id: number;
  first_name: string;
  last_name: string;
  nickname: string | null;
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
  assignment_id: number;
  shift_id: number;
  date: string;
  weekday: string;
  start_time: string;
  end_time: string;
  required_role: string;
  employee_id: number;
  employee_name: string;
  status: string;
  max_employees: number;
}

interface ShiftInfo {
  id: number;
  date: string;
  weekday: string;
  start_time: string;
  end_time: string;
  required_role: string;
  min_employees: number;
  max_employees: number;
}

interface WeekSchedule {
  rota_id: number;
  week_start: string;
  finalized: boolean;
  entries: ScheduleEntry[];
  shifts: ShiftInfo[];
}

interface ShortfallWarning {
  shift_id: number;
  needed: number;
  filled: number;
  weekday: string;
  start_time: string;
  end_time: string;
  required_role: string;
}

interface ScheduleResult {
  assignments: unknown[];
  warnings: ShortfallWarning[];
}

interface Role {
  id: number;
  name: string;
}

// ─── Helpers ────────────────────────────────────────────────

function displayName(e: Employee): string {
  return e.nickname?.trim() || `${e.first_name} ${e.last_name}`;
}

// ─── State ──────────────────────────────────────────────────

let employees: Employee[] = [];
let shiftTemplates: ShiftTemplate[] = [];
let roles: Role[] = [];
let currentView = "employees";
let selectedWeek = toLocalISODate(getMonday(new Date()));
let selectedEmployeeId: number | null = null;
let editEmployeeId: number | null = null;
let editShiftTemplateId: number | null = null;
let cleanupCurrentView: (() => void) | null = null;
let lastScheduleWarnings: ShortfallWarning[] = [];
let warningsCollapsed = false;
let editMode = false;

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

async function fetchRoles(): Promise<void> {
  roles = await invoke("list_roles");
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

function getWeekCategory(weekStart: string): "past" | "current" | "future" {
  const currentMonday = toLocalISODate(getMonday(new Date()));
  if (weekStart < currentMonday) return "past";
  if (weekStart === currentMonday) return "current";
  return "future";
}

function shiftDateForDay(weekStart: string, dayAbbrev: string): string {
  const offsets: Record<string, number> = { Mon: 0, Tue: 1, Wed: 2, Thu: 3, Fri: 4, Sat: 5, Sun: 6 };
  const d = new Date(weekStart + "T00:00:00");
  d.setDate(d.getDate() + (offsets[dayAbbrev] ?? 0));
  return toLocalISODate(d);
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
        `<div class="employee-item" data-id="${e.id}">${displayName(e)}</div>`
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
              <span class="item-name">${displayName(e)}</span>
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
        <div class="form-row">
          <div class="form-group">
            <label>First Name *</label>
            <input id="emp-first-name" type="text" placeholder="First name" />
          </div>
          <div class="form-group">
            <label>Last Name *</label>
            <input id="emp-last-name" type="text" placeholder="Last name" />
          </div>
        </div>
        <div class="form-group">
          <label>Nickname (optional)</label>
          <input id="emp-nickname" type="text" placeholder="Display nickname" />
        </div>
        <div class="form-group">
          <label>Roles *</label>
          <div class="role-tags" id="emp-role-tags">
            ${roles.map((r) => `<button type="button" class="role-tag" data-role="${r.name}">${r.name}</button>`).join("")}
          </div>
          ${roles.length === 0 ? '<p class="empty-state" style="margin:0">No roles defined yet. Add roles in the Templates tab.</p>' : ""}
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

  document.querySelectorAll("#emp-role-tags .role-tag").forEach((tag) => {
    tag.addEventListener("click", () => tag.classList.toggle("selected"));
  });

  document.getElementById("create-emp-btn")!.addEventListener("click", async () => {
    const firstName = (document.getElementById("emp-first-name") as HTMLInputElement).value.trim();
    const lastName = (document.getElementById("emp-last-name") as HTMLInputElement).value.trim();
    const nickname = (document.getElementById("emp-nickname") as HTMLInputElement).value.trim() || null;
    const selectedRoles = Array.from(document.querySelectorAll("#emp-role-tags .role-tag.selected")).map((t) => (t as HTMLElement).dataset.role!);
    const startDate = (document.getElementById("emp-start-date") as HTMLInputElement).value;
    const targetWeekly = parseFloat((document.getElementById("emp-target-weekly") as HTMLInputElement).value);
    const deviation = parseFloat((document.getElementById("emp-deviation") as HTMLInputElement).value);
    const daily = parseFloat((document.getElementById("emp-daily") as HTMLInputElement).value);
    const notes = (document.getElementById("emp-notes") as HTMLTextAreaElement).value.trim() || null;
    const bank = (document.getElementById("emp-bank") as HTMLInputElement).value.trim() || null;

    if (!firstName || !lastName || selectedRoles.length === 0 || !startDate) return;

    await invoke("create_employee", {
      employee: {
        id: 0,
        first_name: firstName,
        last_name: lastName,
        nickname,
        roles: selectedRoles,
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
        <div class="form-row">
          <div class="form-group">
            <label>First Name *</label>
            <input id="emp-first-name" type="text" value="${emp.first_name}" />
          </div>
          <div class="form-group">
            <label>Last Name *</label>
            <input id="emp-last-name" type="text" value="${emp.last_name}" />
          </div>
        </div>
        <div class="form-group">
          <label>Nickname (optional)</label>
          <input id="emp-nickname" type="text" value="${emp.nickname ?? ""}" placeholder="Display nickname" />
        </div>
        <div class="form-group">
          <label>Roles *</label>
          <div class="role-tags" id="emp-role-tags">
            ${roles.map((r) => `<button type="button" class="role-tag${emp.roles.includes(r.name) ? " selected" : ""}" data-role="${r.name}">${r.name}</button>`).join("")}
          </div>
          ${roles.length === 0 ? '<p class="empty-state" style="margin:0">No roles defined yet. Add roles in the Templates tab.</p>' : ""}
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

  document.querySelectorAll("#emp-role-tags .role-tag").forEach((tag) => {
    tag.addEventListener("click", () => tag.classList.toggle("selected"));
  });

  document.getElementById("save-emp-btn")!.addEventListener("click", async () => {
    const firstName = (document.getElementById("emp-first-name") as HTMLInputElement).value.trim();
    const lastName = (document.getElementById("emp-last-name") as HTMLInputElement).value.trim();
    const nickname = (document.getElementById("emp-nickname") as HTMLInputElement).value.trim() || null;
    const selectedRoles = Array.from(document.querySelectorAll("#emp-role-tags .role-tag.selected")).map((t) => (t as HTMLElement).dataset.role!);
    const startDate = (document.getElementById("emp-start-date") as HTMLInputElement).value;
    const targetWeekly = parseFloat((document.getElementById("emp-target-weekly") as HTMLInputElement).value);
    const deviation = parseFloat((document.getElementById("emp-deviation") as HTMLInputElement).value);
    const daily = parseFloat((document.getElementById("emp-daily") as HTMLInputElement).value);
    const notes = (document.getElementById("emp-notes") as HTMLTextAreaElement).value.trim() || null;
    const bank = (document.getElementById("emp-bank") as HTMLInputElement).value.trim() || null;

    if (!firstName || !lastName || selectedRoles.length === 0 || !startDate) return;

    await invoke("update_employee", {
      employee: {
        ...emp,
        first_name: firstName,
        last_name: lastName,
        nickname,
        roles: selectedRoles,
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

function getComingWeekRange(): string {
  const today = new Date();
  const day = today.getDay(); // 0=Sun, 1=Mon...
  const daysUntilNextMonday = day === 0 ? 1 : day === 1 ? 7 : 8 - day;
  const monday = new Date(today);
  monday.setDate(today.getDate() + daysUntilNextMonday);
  monday.setHours(0, 0, 0, 0);
  const sunday = new Date(monday);
  sunday.setDate(monday.getDate() + 6);
  const fmt = (d: Date) => d.toLocaleDateString("en-GB", { day: "numeric", month: "short" });
  return `${fmt(monday)} \u2013 ${fmt(sunday)} ${sunday.getFullYear()}`;
}

function createAvailGridInteraction(gridEl: HTMLElement): {
  applyState: (s: "Yes" | "Maybe" | "No") => void;
  readCells: () => Record<string, string>;
  clearSelection: () => void;
  selectAll: () => void;
} {
  const allCells = Array.from(gridEl.querySelectorAll(".avail-cell")) as HTMLElement[];
  const NUM_DAYS = 7;
  const SEL_BORDER = "#2980b9";
  const B = 2;
  let anchorIndex: number | null = null;

  function cellCoords(idx: number): [number, number] {
    return [idx % NUM_DAYS, Math.floor(idx / NUM_DAYS)];
  }
  function cellAt(col: number, row: number): HTMLElement {
    return allCells[row * NUM_DAYS + col];
  }
  function clearSelection() {
    allCells.forEach((c) => { c.classList.remove("avail-selected"); c.style.boxShadow = ""; });
  }
  function selectRect(col1: number, row1: number, col2: number, row2: number) {
    const minCol = Math.min(col1, col2), maxCol = Math.max(col1, col2);
    const minRow = Math.min(row1, row2), maxRow = Math.max(row1, row2);
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
  function readCells(): Record<string, string> {
    const avail: Record<string, string> = {};
    allCells.forEach((el) => {
      avail[`${el.dataset.day}:${el.dataset.hour}`] = el.dataset.state || "Maybe";
    });
    return avail;
  }
  function selectAll() {
    allCells.forEach((c) => c.classList.add("avail-selected"));
  }

  gridEl.addEventListener("mousedown", (e) => {
    const cell = (e.target as HTMLElement).closest(".avail-cell") as HTMLElement | null;
    if (!cell) return;
    e.preventDefault();
    const idx = allCells.indexOf(cell);
    if (idx === -1) return;
    if (e.shiftKey && anchorIndex !== null) {
      const [ac, ar] = cellCoords(anchorIndex);
      const [cc, cr] = cellCoords(idx);
      if (!e.metaKey && !e.ctrlKey) clearSelection();
      selectRect(ac, ar, cc, cr);
    } else if (e.metaKey || e.ctrlKey) {
      cell.classList.toggle("avail-selected");
      if (cell.classList.contains("avail-selected")) {
        cell.style.boxShadow = `inset ${B}px ${B}px 0 0 ${SEL_BORDER}, inset -${B}px -${B}px 0 0 ${SEL_BORDER}`;
      } else {
        cell.style.boxShadow = "";
      }
      anchorIndex = idx;
    } else {
      clearSelection();
      cell.classList.add("avail-selected");
      cell.style.boxShadow = `inset ${B}px ${B}px 0 0 ${SEL_BORDER}, inset -${B}px -${B}px 0 0 ${SEL_BORDER}`;
      anchorIndex = idx;
    }
  });

  return { applyState, readCells, clearSelection, selectAll };
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

  function buildGridHTML(data: Record<string, string>): string {
    return `<div class="avail-grid">
      <div class="header-cell"></div>
      ${weekdays.map((d) => `<div class="header-cell">${d}</div>`).join("")}
      ${hours.map((h) => {
        const label = `${h.toString().padStart(2, "0")}:00`;
        const cells = weekdays.map((d) => {
          const key = `${d}:${h}`;
          const state = data[key] || "Maybe";
          return `<div class="avail-cell" data-day="${d}" data-hour="${h}" data-state="${state}"></div>`;
        }).join("");
        return `<div class="hour-label">${label}</div>${cells}`;
      }).join("")}
    </div>`;
  }

  const legend = `<div class="avail-legend">
    <span><span class="legend-swatch yes"></span> Available</span>
    <span><span class="legend-swatch maybe"></span> Maybe</span>
    <span><span class="legend-swatch no"></span> Unavailable</span>
  </div>`;

  const weekLabel = getComingWeekRange();

  content.innerHTML = `
    <div class="detail-header">
      <button class="back-btn" id="back-to-list">&larr; Back</button>
      <h1>${displayName(emp)}</h1>
      <button class="btn-secondary" id="edit-employee-btn">Edit</button>
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
    <details class="card avail-section" open>
      <summary>Default Availability</summary>
      <div class="avail-toolbar" id="default-avail-toolbar">
        <button class="paint-btn" data-state="Yes">Yes <kbd>Y</kbd></button>
        <button class="paint-btn" data-state="Maybe">Maybe <kbd>M</kbd></button>
        <button class="paint-btn" data-state="No">No <kbd>N</kbd></button>
      </div>
      <div class="avail-grid-wrap" id="default-avail-wrap">${buildGridHTML(emp.default_availability)}</div>
      ${legend}
    </details>
    <details class="card avail-section" open>
      <summary>Availability for ${weekLabel}</summary>
      <div class="avail-toolbar" id="week-avail-toolbar">
        <button class="paint-btn" data-state="Yes">Yes <kbd>Y</kbd></button>
        <button class="paint-btn" data-state="Maybe">Maybe <kbd>M</kbd></button>
        <button class="paint-btn" data-state="No">No <kbd>N</kbd></button>
        <button id="reset-week-avail" class="btn-reset">↺ Reset</button>
        <button id="save-week-avail" class="btn-primary">&#10003;</button>
      </div>
      <div class="avail-grid-wrap" id="week-avail-wrap">${buildGridHTML(emp.availability)}</div>
      ${legend}
    </details>
  `;

  // ─── Back button ───────────────────────────────────────
  document.getElementById("back-to-list")!.addEventListener("click", () => {
    selectedEmployeeId = null;
    currentView = "employees";
    renderView();
  });

  document.getElementById("edit-employee-btn")!.addEventListener("click", () => {
    editEmployeeId = selectedEmployeeId;
    currentView = "edit-employee";
    renderView();
  });

  // ─── Wire up both grids ────────────────────────────────
  const defaultGridEl = document.querySelector("#default-avail-wrap .avail-grid") as HTMLElement;
  const weekGridEl = document.querySelector("#week-avail-wrap .avail-grid") as HTMLElement;
  const defaultGrid = createAvailGridInteraction(defaultGridEl);
  const weekGrid = createAvailGridInteraction(weekGridEl);

  // Track which grid was last interacted with for keyboard routing
  let activeGrid = defaultGrid;
  defaultGridEl.addEventListener("mousedown", () => { activeGrid = defaultGrid; });
  weekGridEl.addEventListener("mousedown", () => { activeGrid = weekGrid; });

  // currentEmp tracks the last-saved state so partial saves don't clobber each other
  let currentEmp = { ...emp };

  async function autoSaveDefault() {
    currentEmp = { ...currentEmp, default_availability: defaultGrid.readCells() };
    await invoke("update_employee", { employee: currentEmp });
    await fetchEmployees();
  }

  // ─── Default toolbar paint buttons (auto-save) ─────────
  document.querySelectorAll("#default-avail-toolbar .paint-btn").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const state = (btn as HTMLElement).dataset.state as "Yes" | "Maybe" | "No";
      defaultGrid.applyState(state);
      await autoSaveDefault();
    });
  });

  // ─── Week toolbar paint buttons (no auto-save) ─────────
  document.querySelectorAll("#week-avail-toolbar .paint-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const state = (btn as HTMLElement).dataset.state as "Yes" | "Maybe" | "No";
      weekGrid.applyState(state);
    });
  });

  // ─── Save week availability ────────────────────────────
  document.getElementById("save-week-avail")!.addEventListener("click", async () => {
    const btn = document.getElementById("save-week-avail") as HTMLButtonElement;
    currentEmp = { ...currentEmp, availability: weekGrid.readCells() };
    await invoke("update_employee", { employee: currentEmp });
    await fetchEmployees();
    btn.textContent = "Saved!";
    setTimeout(() => { btn.textContent = "\u2713"; }, 1500);
  });

  // ─── Reset week to default ─────────────────────────────
  document.getElementById("reset-week-avail")!.addEventListener("click", async () => {
    const defaultData = defaultGrid.readCells();
    const weekCells = weekGridEl.querySelectorAll(".avail-cell") as NodeListOf<HTMLElement>;
    weekCells.forEach((el) => {
      el.dataset.state = defaultData[`${el.dataset.day}:${el.dataset.hour}`] || "Maybe";
    });
    currentEmp = { ...currentEmp, availability: defaultData };
    await invoke("update_employee", { employee: currentEmp });
    await fetchEmployees();
  });

  // ─── Keyboard: Y/M/N apply state to active grid ───────
  function handleAvailKeydown(e: KeyboardEvent) {
    const key = e.key.toLowerCase();
    if (key === "y") {
      activeGrid.applyState("Yes"); e.preventDefault();
      if (activeGrid === defaultGrid) autoSaveDefault();
    } else if (key === "m") {
      activeGrid.applyState("Maybe"); e.preventDefault();
      if (activeGrid === defaultGrid) autoSaveDefault();
    } else if (key === "n") {
      activeGrid.applyState("No"); e.preventDefault();
      if (activeGrid === defaultGrid) autoSaveDefault();
    } else if (key === "a" && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      activeGrid.selectAll();
    } else if (key === "escape") {
      activeGrid.clearSelection();
    }
  }
  function handleOutsideClick(e: MouseEvent) {
    if (!defaultGridEl.contains(e.target as Node) && !weekGridEl.contains(e.target as Node)) {
      defaultGrid.clearSelection();
      weekGrid.clearSelection();
    }
  }

  document.addEventListener("keydown", handleAvailKeydown);
  document.addEventListener("mousedown", handleOutsideClick);
  cleanupCurrentView = () => {
    document.removeEventListener("keydown", handleAvailKeydown);
    document.removeEventListener("mousedown", handleOutsideClick);
  };
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
            <select id="tmpl-role">
              ${roles.map((r) => `<option value="${r.name}"${r.name === tmpl.required_role ? " selected" : ""}>${r.name}</option>`).join("")}
            </select>
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
    const role = (document.getElementById("tmpl-role") as HTMLSelectElement).value;
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
        required_role: role,
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
            <select id="tmpl-role">
              ${roles.length === 0 ? '<option value="">No roles – add one first</option>' : ""}
              ${roles.map((r) => `<option value="${r.name}">${r.name}</option>`).join("")}
            </select>
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
    const role = (document.getElementById("tmpl-role") as HTMLSelectElement).value;
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
        required_role: role,
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
    <h1>Roles</h1>
    <div class="card">
      <div class="item-list">
        ${roles.length === 0 ? '<p class="empty-state">No roles yet. Add one below.</p>' : ""}
        ${roles
          .map(
            (r) => `
          <div class="item-row role-row" data-id="${r.id}">
            <div class="item-info">
              <span class="item-name role-name-display" data-id="${r.id}">${r.name}</span>
            </div>
            <div class="kebab-wrap">
              <button class="kebab-btn role-kebab-btn" data-id="${r.id}" title="More options">&#8942;</button>
              <div class="kebab-dropdown" id="role-kebab-${r.id}">
                <button class="kebab-item rename-role" data-id="${r.id}">Rename</button>
                <button class="kebab-item kebab-delete delete-role" data-id="${r.id}">Delete</button>
              </div>
            </div>
          </div>`
          )
          .join("")}
      </div>
      <div class="add-role-row" style="display:flex;gap:0.5rem;padding:0.75rem 1rem 0.5rem;">
        <input id="new-role-input" type="text" placeholder="New role name" style="flex:1;" />
        <button class="btn-primary" id="add-role-btn">Add Role</button>
      </div>
    </div>

    <h1 style="margin-top:2rem;">Shift Templates</h1>
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

  // ── Role management ────────────────────────────────────────
  document.getElementById("add-role-btn")!.addEventListener("click", async () => {
    const input = document.getElementById("new-role-input") as HTMLInputElement;
    const name = input.value.trim();
    if (!name) return;
    try {
      await invoke("create_role", { name });
      await fetchRoles();
      renderShiftsView();
    } catch (err) {
      alert(`Failed to create role: ${err}`);
    }
  });

  // Enter key on role input
  document.getElementById("new-role-input")!.addEventListener("keydown", (e) => {
    if (e.key === "Enter") document.getElementById("add-role-btn")!.click();
  });

  document.querySelectorAll(".role-kebab-btn").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const id = (btn as HTMLElement).dataset.id!;
      const dropdown = document.getElementById(`role-kebab-${id}`)!;
      const isOpen = dropdown.classList.contains("open");
      document.querySelectorAll(".kebab-dropdown.open").forEach((d) => d.classList.remove("open"));
      if (!isOpen) dropdown.classList.add("open");
    });
  });

  document.querySelectorAll(".rename-role").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const id = parseInt((btn as HTMLElement).dataset.id!);
      const role = roles.find((r) => r.id === id);
      if (!role) return;
      const nameEl = document.querySelector(`.role-name-display[data-id="${id}"]`) as HTMLElement;
      if (!nameEl) return;
      const input = document.createElement("input");
      input.type = "text";
      input.value = role.name;
      input.className = "inline-edit-input";
      nameEl.replaceWith(input);
      input.focus();
      input.select();

      const save = async () => {
        const newName = input.value.trim();
        if (newName && newName !== role.name) {
          try {
            await invoke("update_role", { id, name: newName });
            await fetchRoles();
            await fetchShiftTemplates();
            await fetchEmployees();
          } catch (err) {
            alert(`Failed to rename role: ${err}`);
          }
        }
        renderShiftsView();
      };
      input.addEventListener("blur", save);
      input.addEventListener("keydown", (ev) => { if (ev.key === "Enter") input.blur(); });
    });
  });

  document.querySelectorAll(".delete-role").forEach((btn) => {
    btn.addEventListener("click", async (e) => {
      e.stopPropagation();
      const id = parseInt((btn as HTMLElement).dataset.id!);
      try {
        await invoke("delete_role", { id });
        await fetchRoles();
        renderShiftsView();
      } catch (err) {
        alert(`${err}`);
      }
    });
  });
}

let rotaViewMode: "template" | "assigned" = "template";
// True when the user has explicitly chosen a view mode for the current week.
// Reset on week navigation so the auto-default can fire once per week.
let rotaViewModeExplicit = false;

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
  const weekCategory = getWeekCategory(selectedWeek);
  console.log("[Rota] hasAssignments:", hasAssignments, "rotaViewMode:", rotaViewMode, "weekCategory:", weekCategory);

  // For past/current weeks with assignments, default to assigned view —
  // but only if the user hasn't explicitly chosen a view mode for this week.
  if (!rotaViewModeExplicit && weekCategory !== "future" && hasAssignments && rotaViewMode === "template") {
    rotaViewMode = "assigned";
  }

  const categoryBadge = weekCategory === "past"
    ? `<span class="week-badge week-badge-past">Past</span>`
    : weekCategory === "current"
      ? `<span class="week-badge week-badge-current">Current Week</span>`
      : "";

  const canGenerate = weekCategory === "future";
  const canEdit = !(schedule?.finalized);

  // When in edit mode, force assigned view
  if (editMode && rotaViewMode !== "assigned") {
    rotaViewMode = "assigned";
  }

  content.innerHTML = `
    <h1>Week of ${formatWeekLabel(selectedWeek)} ${categoryBadge}</h1>
    <div class="card">
      <div class="form-row" style="gap: 0.5rem;">
        ${canGenerate ? `<button class="btn-primary" id="generate-btn">Generate Schedule</button>` : ""}
        ${canEdit ? `<button class="${editMode ? "btn-primary" : "btn-secondary"}" id="edit-mode-btn">${editMode ? "Exit Edit Mode" : "Edit Mode"}</button>` : ""}
      </div>
      <div class="form-group" style="margin-top: 0.5rem;">
        <label>View</label>
        <select id="rota-view-select" ${editMode ? "disabled" : ""}>
          <option value="template" ${rotaViewMode === "template" ? "selected" : ""}>Template View</option>
          <option value="assigned" ${rotaViewMode === "assigned" ? "selected" : ""} ${!hasAssignments && !editMode ? "disabled" : ""}>Assigned Shifts${!hasAssignments && !editMode ? " (no schedule yet)" : ""}</option>
        </select>
      </div>
      ${renderScheduleWarnings(lastScheduleWarnings)}
    </div>
    <div class="card" id="schedule-grid">
      ${renderRotaGrid(weekdays, schedule)}
    </div>
  `;

  // Generate button (only present for future weeks)
  const generateBtn = document.getElementById("generate-btn");
  if (generateBtn) {
    generateBtn.addEventListener("click", async () => {
      const btn = generateBtn as HTMLButtonElement;
      btn.disabled = true;
      btn.textContent = "Generating...";
      console.log("[Generate] Starting schedule for week:", selectedWeek);
      try {
        const result: ScheduleResult = await invoke("run_schedule", { weekStart: selectedWeek });
        console.log("[Generate] Result:", JSON.stringify(result, null, 2));
        console.log("[Generate] Assignments:", result.assignments.length, "Warnings:", result.warnings.length);
        lastScheduleWarnings = result.warnings;
        warningsCollapsed = false;
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
  }

  // Edit mode toggle
  const editModeBtn = document.getElementById("edit-mode-btn");
  if (editModeBtn) {
    editModeBtn.addEventListener("click", async () => {
      if (!editMode) {
        // Entering edit mode: materialise shifts if no rota exists
        if (!schedule) {
          try {
            await invoke("materialise_week", { weekStart: selectedWeek });
          } catch (err) {
            alert(`Failed to prepare week: ${err}`);
            return;
          }
        }
        await fetchEmployees();
        editMode = true;
        rotaViewMode = "assigned";
      } else {
        editMode = false;
      }
      await renderRotaView();
    });
  }

  // Warning toggle
  document.getElementById("warning-toggle")?.addEventListener("click", () => {
    warningsCollapsed = !warningsCollapsed;
    renderRotaView();
  });

  // View mode dropdown
  document.getElementById("rota-view-select")!.addEventListener("change", (e) => {
    rotaViewMode = (e.target as HTMLSelectElement).value as "template" | "assigned";
    rotaViewModeExplicit = true;
    console.log("[Rota] View mode changed to:", rotaViewMode);
    renderRotaView();
  });

  // Attach interactive listeners for drag-drop and edit mode
  if (rotaViewMode === "assigned" && !(schedule?.finalized)) {
    attachRotaInteractiveListeners(schedule);
  }
}

interface RotaShiftCard {
  shiftId: number;
  date: string;
  name: string;
  startTime: string;
  endTime: string;
  role: string;
  maxEmployees: number;
  employees: { assignmentId: number; employeeId: number; name: string; status: string }[];
}

function renderScheduleWarnings(warnings: ShortfallWarning[]): string {
  if (warnings.length === 0) return "";
  const count = warnings.length;
  const label = `⚠ ${count} shift${count > 1 ? "s" : ""} could not be fully staffed`;
  const lines = warnings.map(w => {
    const staffed = `${w.filled}/${w.needed} staff`;
    return `<div class="warning-text">${w.weekday} ${w.start_time}–${w.end_time} (${w.required_role}): ${staffed} assigned</div>`;
  }).join("");
  const chevron = warningsCollapsed ? "▶" : "▼";
  return `<div class="schedule-warning${warningsCollapsed ? " collapsed" : ""}">
    <div class="warning-header" id="warning-toggle">
      <span class="warning-chevron">${chevron}</span>
      <strong class="warning-text">${label}</strong>
    </div>
    <div class="warning-body">${lines}</div>
  </div>`;
}

function renderRotaGrid(weekdays: string[], schedule: WeekSchedule | null): string {
  console.log("[RotaGrid] Rendering mode:", rotaViewMode, "editMode:", editMode, "entries:", schedule?.entries.length ?? 0);
  const byDay: Record<string, RotaShiftCard[]> = {};
  for (const day of weekdays) byDay[day] = [];

  const weekCategory = getWeekCategory(selectedWeek);
  const isInteractive = rotaViewMode === "assigned" && !(schedule?.finalized);

  if (rotaViewMode === "assigned" && schedule) {
    // In edit mode, build from schedule.shifts so empty shifts also appear
    // In normal assigned mode, build from entries only
    if (editMode && schedule.shifts.length > 0) {
      // Build cards from all shifts, attaching any assignments
      const entryByShift: Record<number, { assignmentId: number; employeeId: number; name: string; status: string }[]> = {};
      for (const entry of schedule.entries) {
        if (!entryByShift[entry.shift_id]) entryByShift[entry.shift_id] = [];
        entryByShift[entry.shift_id].push({
          assignmentId: entry.assignment_id,
          employeeId: entry.employee_id,
          name: entry.employee_name,
          status: entry.status,
        });
      }
      for (const shift of schedule.shifts) {
        const day = shift.weekday.slice(0, 3);
        if (!byDay[day]) continue;
        byDay[day].push({
          shiftId: shift.id,
          date: shift.date,
          name: shift.required_role,
          startTime: shift.start_time,
          endTime: shift.end_time,
          role: shift.required_role,
          maxEmployees: shift.max_employees,
          employees: entryByShift[shift.id] || [],
        });
      }
      for (const day of weekdays) {
        byDay[day].sort((a, b) => a.startTime.localeCompare(b.startTime));
      }
    } else if (schedule.entries.length > 0) {
      // Group entries by day + shift_id to combine multiple employees per shift
      const shiftMap: Record<string, Record<number, { entry: ScheduleEntry; employees: { assignmentId: number; employeeId: number; name: string; status: string }[] }>> = {};
      for (const day of weekdays) shiftMap[day] = {};

      for (const entry of schedule.entries) {
        if (!shiftMap[entry.weekday]) continue;
        if (!shiftMap[entry.weekday][entry.shift_id]) {
          shiftMap[entry.weekday][entry.shift_id] = { entry, employees: [] };
        }
        shiftMap[entry.weekday][entry.shift_id].employees.push({
          assignmentId: entry.assignment_id,
          employeeId: entry.employee_id,
          name: entry.employee_name,
          status: entry.status,
        });
      }

      for (const day of weekdays) {
        const shifts = Object.values(shiftMap[day]);
        shifts.sort((a, b) => a.entry.start_time.localeCompare(b.entry.start_time));
        for (const s of shifts) {
          byDay[day].push({
            shiftId: s.entry.shift_id,
            date: s.entry.date,
            name: s.entry.required_role,
            startTime: s.entry.start_time,
            endTime: s.entry.end_time,
            role: s.entry.required_role,
            maxEmployees: s.entry.max_employees,
            employees: s.employees,
          });
        }
      }
    }
  } else if (rotaViewMode !== "template" && schedule && schedule.shifts.length > 0) {
    // Use materialised shifts when a schedule exists and template view is not selected
    for (const shift of schedule.shifts) {
      const day = shift.weekday.slice(0, 3);
      if (!byDay[day]) continue;
      byDay[day].push({
        shiftId: shift.id,
        date: shift.date,
        name: shift.required_role,
        startTime: shift.start_time,
        endTime: shift.end_time,
        role: shift.required_role,
        maxEmployees: shift.max_employees,
        employees: [],
      });
    }
    for (const day of weekdays) {
      byDay[day].sort((a, b) => a.startTime.localeCompare(b.startTime));
    }
  } else {
    // Template view: expand shift templates into weekday columns
    for (const tmpl of shiftTemplates) {
      for (const day of tmpl.weekdays) {
        if (!byDay[day]) continue;
        byDay[day].push({
          shiftId: 0,
          date: shiftDateForDay(selectedWeek, day),
          name: tmpl.name,
          startTime: tmpl.start_time.slice(0, 5),
          endTime: tmpl.end_time.slice(0, 5),
          role: tmpl.required_role,
          maxEmployees: tmpl.max_employees,
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
      : `<p>No shifts found. ${editMode ? "No shift templates configured." : "Check that employees and shift templates are configured."}</p>`;
  }

  let html = `<div class="rota-grid-wrap"><div class="rota-grid" style="grid-template-columns: repeat(7, 1fr);">`;

  // Header row
  const today = todayISO();
  for (const day of weekdays) {
    const dayDate = shiftDateForDay(selectedWeek, day);
    const dayPast = dayDate < today;
    html += `<div class="rota-day-header${dayPast ? " day-past" : ""}">${day}</div>`;
  }

  // Shift cards row by row
  for (let row = 0; row < maxShifts; row++) {
    for (const day of weekdays) {
      const shift = byDay[day][row];
      if (shift) {
        const isPast = shift.date < today;
        const canInteract = isInteractive && !isPast;

        const empHtml = shift.employees.length > 0
          ? shift.employees.map((e) => {
              const cls = e.status === "Confirmed" ? "status-confirmed" : e.status === "Overridden" ? "status-overridden" : "status-proposed";
              const swappable = canInteract ? ` data-assignment-id="${e.assignmentId}" data-shift-id="${shift.shiftId}" data-employee-id="${e.employeeId}"` : "";
              let actions = "";
              if (editMode && !isPast) {
                actions += `<span class="edit-remove-btn" data-assignment-id="${e.assignmentId}" title="Remove">&times;</span>`;
                if (e.status === "Proposed") {
                  actions += `<span class="edit-confirm-btn" data-assignment-id="${e.assignmentId}" title="Confirm">&#x2713;</span>`;
                }
              }
              return `<div class="rota-employee ${cls}${canInteract ? " swappable" : ""}"${swappable}><span class="rota-employee-name">${displayName(e)}</span>${actions}</div>`;
            }).join("")
          : "";

        const addBtn = editMode && !isPast && shift.employees.length < shift.maxEmployees
          ? `<button class="edit-add-employee-btn" data-shift-id="${shift.shiftId}" data-rota-id="${schedule?.rota_id}">+ Add</button>`
          : "";

        const cardAttrs = canInteract && shift.shiftId ? ` data-shift-id="${shift.shiftId}" data-max-employees="${shift.maxEmployees}"` : "";

        const deleteBtn = editMode && !isPast && shift.shiftId
          ? `<button class="edit-delete-shift-btn" data-shift-id="${shift.shiftId}" title="Delete shift"><svg width="10" height="10" viewBox="0 0 12 13" fill="currentColor" aria-hidden="true"><rect x="1" y="2.5" width="10" height="1" rx="0.5"/><rect x="3.5" y="0.5" width="5" height="1.5" rx="0.5"/><path d="M2 4l.6 7.5A.5.5 0 002.6 12h6.8a.5.5 0 00.5-.5L10.5 4H2zm2.5 1.5h1v5h-1v-5zm3 0h1v5h-1v-5z"/></svg></button>`
          : "";

        const timeHtml = editMode && !isPast && shift.shiftId
          ? `<div class="rota-shift-time editable-time">
               <span class="edit-time" data-shift-id="${shift.shiftId}" data-field="start" data-value="${shift.startTime}">${shift.startTime}</span>
               &ndash;
               <span class="edit-time" data-shift-id="${shift.shiftId}" data-field="end" data-value="${shift.endTime}">${shift.endTime}</span>
             </div>`
          : `<div class="rota-shift-time">${shift.startTime} &ndash; ${shift.endTime}</div>`;

        html += `<div class="rota-shift-card${editMode ? " edit-mode" : ""}${isPast ? " shift-past" : ""}"${cardAttrs}>
          ${deleteBtn}
          <div class="rota-shift-name">${shift.name}</div>
          ${timeHtml}
          ${empHtml}
          ${addBtn}
        </div>`;
      } else {
        html += `<div class="rota-shift-empty"></div>`;
      }
    }
  }

  // Add shift buttons at the bottom of each weekday column (edit mode only)
  if (editMode && schedule) {
    for (const day of weekdays) {
      const dayDate = shiftDateForDay(selectedWeek, day);
      const isPast = dayDate < today;
      if (!isPast) {
        html += `<div class="rota-add-shift-cell" style="position: relative;">
          <button class="edit-add-shift-btn" data-date="${dayDate}" data-rota-id="${schedule.rota_id}">+ Add Shift</button>
        </div>`;
      } else {
        html += `<div class="rota-shift-empty"></div>`;
      }
    }
  }

  html += `</div></div>`;
  return html;
}

function attachRotaInteractiveListeners(schedule: WeekSchedule | null) {
  // Swap mode: mousedown on employee badge → highlight swap targets → mouseup to swap
  let swapSource: { assignmentId: number; shiftId: number } | null = null;

  function cancelSwap() {
    swapSource = null;
    document.querySelectorAll(".swap-source").forEach((el) => el.classList.remove("swap-source"));
    document.querySelectorAll(".swap-target").forEach((el) => el.classList.remove("swap-target"));
    document.querySelectorAll(".swap-hover").forEach((el) => el.classList.remove("swap-hover"));
  }

  document.querySelectorAll<HTMLElement>(".rota-employee.swappable").forEach((el) => {
    el.addEventListener("mousedown", (e) => {
      // Ignore if clicking edit mode action buttons
      if ((e.target as HTMLElement).closest(".edit-remove-btn, .edit-confirm-btn")) return;
      e.preventDefault();

      const assignmentId = parseInt(el.dataset.assignmentId!);
      const shiftId = parseInt(el.dataset.shiftId!);
      swapSource = { assignmentId, shiftId };

      el.classList.add("swap-source");

      // Highlight all employee badges in OTHER shifts as swap targets
      document.querySelectorAll<HTMLElement>(".rota-employee.swappable").forEach((target) => {
        const targetShiftId = parseInt(target.dataset.shiftId!);
        if (targetShiftId !== shiftId) {
          target.classList.add("swap-target");
        }
      });
    });

    el.addEventListener("mouseenter", () => {
      if (swapSource && parseInt(el.dataset.shiftId!) !== swapSource.shiftId) {
        el.classList.add("swap-hover");
      }
    });

    el.addEventListener("mouseleave", () => {
      el.classList.remove("swap-hover");
    });

    el.addEventListener("mouseup", async () => {
      if (!swapSource) return;
      const targetAssignmentId = parseInt(el.dataset.assignmentId!);
      const targetShiftId = parseInt(el.dataset.shiftId!);

      if (targetShiftId === swapSource.shiftId) {
        cancelSwap();
        return;
      }

      const sourceId = swapSource.assignmentId;
      cancelSwap();

      try {
        await invoke("swap_assignments", { idA: sourceId, idB: targetAssignmentId });
        await renderRotaView();
      } catch (err) {
        alert(`Failed to swap: ${err}`);
      }
    });
  });

  // Cancel swap on mouseup anywhere else
  document.addEventListener("mouseup", () => {
    if (swapSource) cancelSwap();
  }, { once: false });

  // Edit mode listeners
  if (editMode) {
    // Remove buttons
    document.querySelectorAll<HTMLElement>(".edit-remove-btn").forEach((btn) => {
      btn.addEventListener("click", async (e) => {
        e.stopPropagation();
        const id = parseInt(btn.dataset.assignmentId!);
        try {
          await invoke("delete_assignment", { id });
          await renderRotaView();
        } catch (err) {
          alert(`Failed to remove assignment: ${err}`);
        }
      });
    });

    // Confirm buttons
    document.querySelectorAll<HTMLElement>(".edit-confirm-btn").forEach((btn) => {
      btn.addEventListener("click", async (e) => {
        e.stopPropagation();
        const id = parseInt(btn.dataset.assignmentId!);
        try {
          await invoke("update_assignment_status", { id, status: "Confirmed" });
          await renderRotaView();
        } catch (err) {
          alert(`Failed to confirm assignment: ${err}`);
        }
      });
    });

    // Add employee buttons
    document.querySelectorAll<HTMLElement>(".edit-add-employee-btn").forEach((btn) => {
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        // Close any existing picker
        document.querySelectorAll(".employee-picker").forEach((p) => p.remove());

        const shiftId = parseInt(btn.dataset.shiftId!);
        const rotaId = parseInt(btn.dataset.rotaId!);

        // Get employees already assigned to this shift
        const assignedIds = new Set<number>();
        const card = btn.closest(".rota-shift-card");
        if (card) {
          card.querySelectorAll<HTMLElement>(".rota-employee[data-employee-id]").forEach((el) => {
            assignedIds.add(parseInt(el.dataset.employeeId!));
          });
        }

        const available = employees.filter((emp) => !assignedIds.has(emp.id));
        if (available.length === 0) {
          alert("No available employees to add.");
          return;
        }

        const picker = document.createElement("div");
        picker.className = "employee-picker";
        for (const emp of available) {
          const item = document.createElement("div");
          item.className = "employee-picker-item";
          item.textContent = displayName(emp);
          item.addEventListener("click", async () => {
            picker.remove();
            try {
              await invoke("create_assignment", {
                assignment: {
                  id: 0,
                  rota_id: rotaId,
                  shift_id: shiftId,
                  employee_id: emp.id,
                  status: "Overridden",
                  employee_name: displayName(emp),
                },
              });
              await renderRotaView();
            } catch (err) {
              alert(`Failed to add assignment: ${err}`);
            }
          });
          picker.appendChild(item);
        }

        // Position relative to the button
        btn.style.position = "relative";
        btn.insertAdjacentElement("afterend", picker);

        // Close on outside click
        const closeHandler = (ev: MouseEvent) => {
          if (!picker.contains(ev.target as Node)) {
            picker.remove();
            document.removeEventListener("click", closeHandler);
          }
        };
        // Delay to avoid immediate close from current click
        setTimeout(() => document.addEventListener("click", closeHandler), 0);
      });
    });

    // Delete shift buttons
    document.querySelectorAll<HTMLElement>(".edit-delete-shift-btn").forEach((btn) => {
      btn.addEventListener("click", async (e) => {
        e.stopPropagation();
        const shiftId = parseInt(btn.dataset.shiftId!);
        try {
          await invoke("delete_shift", { id: shiftId });
          await renderRotaView();
        } catch (err) {
          alert(`Failed to delete shift: ${err}`);
        }
      });
    });

    // Inline time editing
    document.querySelectorAll<HTMLElement>(".edit-time").forEach((span) => {
      span.addEventListener("click", (e) => {
        e.stopPropagation();
        const shiftId = parseInt(span.dataset.shiftId!);
        const field = span.dataset.field!; // "start" or "end"
        const currentValue = span.dataset.value!;

        const input = document.createElement("input");
        input.type = "time";
        input.value = currentValue;
        input.className = "inline-time-input";
        span.replaceWith(input);
        input.focus();

        let saved = false;
        const save = async () => {
          if (saved) return;
          saved = true;
          const newValue = input.value;
          if (!newValue || newValue === currentValue) {
            await renderRotaView();
            return;
          }
          const card = input.closest(".rota-shift-card");
          let startTime = currentValue;
          let endTime = currentValue;
          if (field === "start") {
            startTime = newValue;
            const endSpan = card?.querySelector<HTMLElement>('.edit-time[data-field="end"]');
            endTime = endSpan?.dataset.value || currentValue;
          } else {
            const startSpan = card?.querySelector<HTMLElement>('.edit-time[data-field="start"]');
            startTime = startSpan?.dataset.value || currentValue;
            endTime = newValue;
          }
          try {
            await invoke("update_shift_times", { id: shiftId, startTime, endTime });
            await renderRotaView();
          } catch (err) {
            alert(`Failed to update time: ${err}`);
            await renderRotaView();
          }
        };

        input.addEventListener("blur", save);
        input.addEventListener("keydown", (ke) => {
          if (ke.key === "Enter") input.blur();
          if (ke.key === "Escape") renderRotaView();
        });
      });
    });

    // Add shift buttons
    document.querySelectorAll<HTMLElement>(".edit-add-shift-btn").forEach((btn) => {
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        document.querySelectorAll(".add-shift-form").forEach((f) => f.remove());

        const date = btn.dataset.date!;
        const rotaId = parseInt(btn.dataset.rotaId!);

        const roleOptions = roles.length > 0
          ? roles.map((r) => `<option value="${r.name}">${r.name}</option>`).join("")
          : `<option value="General">General</option>`;

        const form = document.createElement("div");
        form.className = "add-shift-form";
        form.innerHTML = `
          <label>Start <input type="time" class="asf-start" value="09:00"></label>
          <label>End <input type="time" class="asf-end" value="17:00"></label>
          <label>Role <select class="asf-role">${roleOptions}</select></label>
          <button class="asf-create btn-primary">Create</button>
        `;

        btn.insertAdjacentElement("afterend", form);

        form.querySelector(".asf-create")!.addEventListener("click", async () => {
          const startTime = (form.querySelector(".asf-start") as HTMLInputElement).value;
          const endTime = (form.querySelector(".asf-end") as HTMLInputElement).value;
          const requiredRole = (form.querySelector(".asf-role") as HTMLSelectElement).value;
          if (!startTime || !endTime) { alert("Please set both start and end times."); return; }
          form.remove();
          try {
            await invoke("create_ad_hoc_shift", { rotaId, date, startTime, endTime, requiredRole });
            await renderRotaView();
          } catch (err) {
            alert(`Failed to create shift: ${err}`);
          }
        });

        const closeHandler = (ev: MouseEvent) => {
          if (!form.contains(ev.target as Node)) {
            form.remove();
            document.removeEventListener("click", closeHandler);
          }
        };
        setTimeout(() => document.addEventListener("click", closeHandler), 0);
      });
    });
  }
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

      if (currentView === "shifts") {
        await fetchShiftTemplates();
        await fetchRoles();
      }
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
  lastScheduleWarnings = [];
  editMode = false;
  rotaViewModeExplicit = false;
  rotaViewMode = "template";
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

// ─── Global focus management ────────────────────────────────

// WKWebView (and some other webviews) don't blur inputs when clicking outside them.
// This ensures tapping anywhere outside an active input dismisses it.
document.addEventListener("click", (e) => {
  const active = document.activeElement;
  if (
    (active instanceof HTMLInputElement || active instanceof HTMLTextAreaElement) &&
    e.target !== active
  ) {
    active.blur();
  }
});

// ─── Boot ───────────────────────────────────────────────────

async function main() {
  try {
    await initDb();
    await fetchEmployees();
    await fetchRoles();
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
