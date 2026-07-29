(() => {
  "use strict";

  const rawData = JSON.parse(document.getElementById("roster-data")?.textContent || "[]");
  const state = { rows: rawData, filtered: [], sortField: "subterm_name", sortDirection: "asc", expanded: new Set() };
  const tbody = document.getElementById("sections-body");
  const esc = value => String(value ?? "").replace(/[&<>'"]/g, ch => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[ch]));
  const normalize = value => String(value ?? "").toLowerCase().trim();
  const number = value => Number(value || 0);

  function enrich(row) {
    const problems = [];
    if (number(row.duplicate_roster_count) > 0) problems.push(`${row.duplicate_roster_count} extra roster`);
    if (number(row.duplicate_student_count) > 0) problems.push(`${row.duplicate_student_count} duplicate student`);
    if (number(row.roster_size) === 0) problems.push("0 students");
    if (number(row.instructor_count) === 0) problems.push("No instructor");
    if (number(row.instructors_missing_email) > 0) problems.push(`${row.instructors_missing_email} instructor email unavailable`);
    if (row.is_overdue === "Y" && row.overall_status !== "SUBMITTED") problems.push("Overdue");
    return { ...row, problem_text: problems.join("; "), has_problem: problems.length > 0 };
  }
  state.rows = state.rows.map(enrich);

  function statusLabel(status) { return status === "SUBMITTED" ? "Submitted" : status === "PARTIAL" ? "In progress" : "Not started"; }
  function statusClass(status) { return status === "SUBMITTED" ? "status-submitted" : status === "PARTIAL" ? "status-partial" : "status-not-started"; }
  function compare(a, b, field) {
    const av = a[field], bv = b[field];
    if (["roster_size","graded_count","duplicate_roster_count","duplicate_student_count","instructor_count","instructors_missing_email"].includes(field)) return number(av) - number(bv);
    return String(av ?? "").localeCompare(String(bv ?? ""), undefined, { numeric: true, sensitivity: "base" });
  }

  function filterRows() {
    const subterm = document.getElementById("subterm_code").value;
    const global = normalize(document.getElementById("global-search").value);
    const status = document.getElementById("status-filter").value;
    const problem = document.getElementById("problem-filter").value;
    const columnFilters = [...document.querySelectorAll(".column-filter")].map(input => ({ field: input.dataset.field, value: normalize(input.value) }));

    state.filtered = state.rows.filter(row => {
      if (subterm && row.subterm_code !== subterm) return false;
      if (status && row.overall_status !== status) return false;
      if (problem === "problems" && !row.has_problem) return false;
      if (problem === "duplicate-roster" && number(row.duplicate_roster_count) === 0) return false;
      if (problem === "duplicate-student" && number(row.duplicate_student_count) === 0) return false;
      if (problem === "overdue" && !(row.is_overdue === "Y" && row.overall_status !== "SUBMITTED")) return false;
      if (problem === "zero" && number(row.roster_size) !== 0) return false;
      if (problem === "missing-grader" && number(row.instructor_count) !== 0) return false;
      if (problem === "missing-email" && number(row.instructors_missing_email) === 0) return false;
      if (global) {
        const haystack = normalize([
          row.course_name,row.subterm_name,row.subterm_code,row.instructor_names,row.instructor_emails,
          row.grader_ids,row.roster_id,row.activity_offering_id,row.roster_type,row.problem_text
        ].join(" "));
        if (!haystack.includes(global)) return false;
      }
      return columnFilters.every(filter => !filter.value || normalize(row[filter.field]).includes(filter.value));
    }).sort((a,b) => compare(a,b,state.sortField) * (state.sortDirection === "asc" ? 1 : -1));
  }

  function issuePills(row) {
    if (!row.has_problem) return '<span class="muted">None found</span>';
    return row.problem_text.split("; ").map(text => `<span class="issue-pill">${esc(text)}</span>`).join("");
  }

  function rowMarkup(row) {
    const expanded = state.expanded.has(row.roster_id);
    return `<tr class="data-row">
      <td>${esc(row.course_name || "Unnamed roster")}</td>
      <td>${esc(row.subterm_name || row.subterm_code)}</td>
      <td>${esc(row.instructor_names || "Not assigned")}</td>
      <td>${esc(row.instructor_emails || "Email unavailable")}</td>
      <td>${number(row.roster_size)}</td>
      <td>${number(row.graded_count)}</td>
      <td><span class="status ${statusClass(row.overall_status)}">${statusLabel(row.overall_status)}</span></td>
      <td>${esc(row.due_dt || "—")}</td>
      <td>${issuePills(row)}</td>
      <td><button type="button" class="button-secondary detail-toggle" data-roster-id="${esc(row.roster_id)}">${expanded ? "Close" : "Open"}</button></td>
    </tr>${expanded ? `<tr class="detail-row"><td colspan="10"><div class="detail-grid">
      <div><strong>Instructor ID(s)</strong><div class="technical">${esc(row.grader_ids || "Not assigned")}</div></div>
      <div><strong>Instructor count</strong><div>${number(row.instructor_count)}</div></div>
      <div><strong>Missing instructor emails</strong><div>${number(row.instructors_missing_email)}</div></div>
      <div><strong>Roster ID</strong><div class="technical">${esc(row.roster_id)}</div></div>
      <div><strong>Activity offering ID</strong><div class="technical">${esc(row.activity_offering_id)}</div></div>
      <div><strong>Roster type</strong><div class="technical">${esc(row.roster_type)}</div></div>
      <div><strong>Raw status</strong><div class="technical">${esc(row.roster_state)}</div></div>
      <div><strong>Completion</strong><div>${number(row.graded_count)} of ${number(row.roster_size)}</div></div>
      <div><strong>Subterm code</strong><div>${esc(row.subterm_code)}</div></div>
    </div></td></tr>` : ""}`;
  }

  function updateMetrics() {
    const rows = state.filtered;
    const submitted = rows.filter(r => r.overall_status === "SUBMITTED").length;
    const partial = rows.filter(r => r.overall_status === "PARTIAL").length;
    const notStarted = rows.filter(r => r.overall_status === "NOT_STARTED").length;
    const uniqueSections = new Set(rows.map(r => r.activity_offering_id).filter(Boolean)).size;
    const duplicateRosters = rows.filter(r => number(r.duplicate_roster_count) > 0).length;
    const duplicateStudents = rows.filter(r => number(r.duplicate_student_count) > 0).length;
    const overdue = rows.filter(r => r.is_overdue === "Y" && r.overall_status !== "SUBMITTED").length;
    const zero = rows.filter(r => number(r.roster_size) === 0).length;
    const missingGraders = rows.filter(r => number(r.instructor_count) === 0).length;
    const missingEmails = rows.filter(r => number(r.instructors_missing_email) > 0).length;
    const rate = rows.length ? Math.round(submitted / rows.length * 100) : 0;
    const set = (id, value) => { const el = document.getElementById(id); if (el) el.textContent = value; };
    set("metric-rosters", rows.length); set("metric-unique-sections", `${uniqueSections} unique sections`); set("metric-submitted", submitted); set("metric-submitted-rate", `${rate}% of visible rosters`); set("metric-partial", partial); set("metric-not-started", notStarted); set("metric-duplicate-rosters", duplicateRosters); set("metric-duplicate-students", duplicateStudents);
    set("health-duplicate-rosters", duplicateRosters); set("health-duplicate-students", duplicateStudents); set("health-overdue", overdue); set("health-zero", zero); set("health-missing-graders", missingGraders); set("health-missing-emails", missingEmails); set("health-unique-sections", uniqueSections);
    set("completion-label", `${submitted} of ${rows.length} rosters submitted (${rate}%)`);
    document.getElementById("completion-bar").style.width = `${rate}%`;
    document.querySelector(".progress-track").setAttribute("aria-valuenow", String(rate));
    set("visible-count", `${rows.length} visible roster${rows.length === 1 ? "" : "s"}`);
  }

  function render() {
    filterRows();
    tbody.innerHTML = state.filtered.length ? state.filtered.map(rowMarkup).join("") : '<tr><td colspan="10" class="empty-state">No rosters match the current filters.</td></tr>';
    updateMetrics();
  }

  function csvEscape(value) { const s = String(value ?? "").replace(/\s+/g," ").trim(); return /[",\n]/.test(s) ? `"${s.replace(/"/g,'""')}"` : s; }
  function downloadCsv() {
    const headers = ["Course / roster","Subterm","Subterm code","Instructor names","Instructor emails","Instructor IDs","Instructor count","Missing instructor emails","Roster size","Graded","Status","Due date","Problems","Roster ID","Activity offering ID","Roster type"];
    const rows = [headers, ...state.filtered.map(r => [r.course_name,r.subterm_name,r.subterm_code,r.instructor_names,r.instructor_emails,r.grader_ids,r.instructor_count,r.instructors_missing_email,r.roster_size,r.graded_count,statusLabel(r.overall_status),r.due_dt,r.problem_text,r.roster_id,r.activity_offering_id,r.roster_type])];
    const blob = new Blob([rows.map(r => r.map(csvEscape).join(",")).join("\r\n")], {type:"text/csv;charset=utf-8"});
    const link = document.createElement("a");
    const subterm = document.getElementById("subterm_code").value;
    link.href = URL.createObjectURL(blob); link.download = `grading_rosters_${window.dashboardConfig.selectedTerm}${subterm ? "_" + subterm : ""}.csv`; link.click(); URL.revokeObjectURL(link.href);
  }

  document.addEventListener("input", event => { if (event.target.matches("#subterm_code,#global-search,#status-filter,#problem-filter,.column-filter")) render(); });
  document.addEventListener("click", event => {
    const detail = event.target.closest(".detail-toggle");
    if (detail) { const id = detail.dataset.rosterId; state.expanded.has(id) ? state.expanded.delete(id) : state.expanded.add(id); render(); return; }
    const sort = event.target.closest(".sort-button");
    if (sort) { const field = sort.dataset.sort; state.sortDirection = state.sortField === field && state.sortDirection === "asc" ? "desc" : "asc"; state.sortField = field; document.querySelectorAll(".sort-button").forEach(b => b.classList.remove("sort-asc","sort-desc")); sort.classList.add(state.sortDirection === "asc" ? "sort-asc" : "sort-desc"); render(); return; }
    const tab = event.target.closest(".tab-button[data-tab]");
    if (tab) { document.querySelectorAll(".tab-button[data-tab]").forEach(x=>x.classList.remove("active")); document.querySelectorAll(".tab-panel").forEach(x=>x.classList.remove("active")); tab.classList.add("active"); document.getElementById(tab.dataset.tab).classList.add("active"); return; }
    const metric = event.target.closest(".metric-filter");
    if (metric) { document.getElementById("status-filter").value = metric.dataset.status || ""; document.getElementById("problem-filter").value = metric.dataset.problem || ""; document.querySelector('[data-tab="sections-panel"]').click(); render(); }
  });
  document.getElementById("clear-filters").addEventListener("click", () => { ["subterm_code","global-search","status-filter","problem-filter"].forEach(id => document.getElementById(id).value = ""); document.querySelectorAll(".column-filter").forEach(x => x.value = ""); render(); });
  document.getElementById("download-csv").addEventListener("click", downloadCsv);
  render();
})();
