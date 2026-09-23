(() => {
  "use strict";

  const rawData = JSON.parse(document.getElementById("roster-data")?.textContent || "[]");
  const state = {
    rows: rawData,
    filtered: [],
    sortField: "subterm_name",
    sortDirection: "asc",
    expanded: new Set(),
    rosterStudents: new Map(),
    rosterStudentErrors: new Map(),
    rosterStudentLoading: new Set(),
    gradePostingLoaded: false,
    gradePostingLoading: false,
    gradePostingError: "",
    gradePostingByRoster: new Map(),
    gradePostingByRosterRow: new Map()
  };
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
    if (row.expected_graduating_discrepancy_ind === "Y") problems.push("Expected-graduate discrepancy");
    if (row.is_overdue === "Y" && row.overall_status !== "SUBMITTED") problems.push("Overdue");
    if (number(row.grade_posting_exception_count) > 0) problems.push(`${row.grade_posting_exception_count} grade posting exception`);
    return {
      ...row,
      expected_graduating_display: `${number(row.expected_graduating_graded_count)} / ${number(row.expected_graduating_student_count)}`,
      problem_text: problems.join("; "),
      has_problem: problems.length > 0
    };
  }
  state.rows = state.rows.map(enrich);

  function statusLabel(status) { return status === "SUBMITTED" ? "Submitted" : status === "PARTIAL" ? "In progress" : "Not started"; }
  function statusClass(status) { return status === "SUBMITTED" ? "status-submitted" : status === "PARTIAL" ? "status-partial" : "status-not-started"; }
  function compare(a, b, field) {
    const av = a[field], bv = b[field];
    if (["roster_size","graded_count","expected_graduating_student_count","expected_graduating_graded_count","duplicate_roster_count","duplicate_student_count","instructor_count","instructors_missing_email","grade_posting_exception_count"].includes(field)) return number(av) - number(bv);
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
      if (problem === "expected-grad-discrepancy" && row.expected_graduating_discrepancy_ind !== "Y") return false;
      if (problem === "expected-grad-ungraded" && !(
        number(row.expected_graduating_student_count) >
        number(row.expected_graduating_graded_count)
      )) return false;
      if (problem === "grade-posting-exception" && number(row.grade_posting_exception_count) === 0) return false;
      if (problem === "posted-via-duplicate" && number(row.grade_posted_via_duplicate_count) === 0) return false;
      if (global) {
        const haystack = normalize([
          row.course_name,row.subterm_name,row.subterm_code,row.instructor_names,row.instructor_emails,
          row.grader_ids,row.roster_id,row.activity_offering_id,row.roster_type,row.problem_text,
          row.expected_graduating_display,row.expected_graduating_count_source
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

  function yesNo(value) { return value === "Y" ? "Yes" : "No"; }

  const postingExceptions = new Set(["GRADE_NOT_POSTED", "GRADE_MISMATCH", "ACTIVE_RECORD_REVIEW", "MISSING_ACADEMIC_RECORD"]);
  function postingLabel(status) {
    return ({POSTED_CORRECTLY:"Posted correctly",POSTED_VIA_DUPLICATE:"Posted through alternate registration",GRADE_NOT_POSTED:"Grade not posted",GRADE_MISMATCH:"Grade mismatch",ACTIVE_RECORD_REVIEW:"Active record needs review",DROPPED_ONLY:"Dropped registration only",MISSING_ACADEMIC_RECORD:"Missing academic record"})[status] || "Not checked";
  }
  function postingClass(status) {
    if (postingExceptions.has(status)) return "posting-exception";
    if (status === "POSTED_CORRECTLY") return "posting-good";
    if (status === "POSTED_VIA_DUPLICATE") return "posting-info";
    return "posting-muted";
  }

  function rosterStudentMarkup(row) {
    const rosterId = row.roster_id;
    if (state.rosterStudentLoading.has(rosterId)) {
      return '<p class="roster-loading">Loading roster…</p>';
    }
    if (state.rosterStudentErrors.has(rosterId)) {
      return `<div class="error">Roster could not be loaded: ${esc(state.rosterStudentErrors.get(rosterId))}</div>`;
    }
    if (!state.rosterStudents.has(rosterId)) {
      return '<p class="muted">Roster details have not been loaded.</p>';
    }
    const students = state.rosterStudents.get(rosterId);
    if (!students.length) {
      return '<p class="muted">No active students were found for this roster.</p>';
    }
    const rows = students.map(student => {
      const posting = state.gradePostingByRosterRow.get(student.roster_row_id);
      const warnings = student.duplicate_student_ind === "Y"
        ? '<span class="issue-pill">Duplicate roster row</span>'
        : '<span class="muted">None found</span>';
      return `<tr>
        <td>${esc(student.student_name || "Name unavailable")}</td>
        <td class="technical">${esc(student.student_id || "Unavailable")}</td>
        <td class="${student.grade_value ? "student-grade" : "student-no"}">${esc(student.grade_value || "—")}</td>
        <td class="${postingClass(posting?.posting_status)}">${esc(posting ? posting.active_academic_grades || "—" : state.gradePostingLoaded ? "Not applicable" : "Run checker")}</td>
        <td class="${postingClass(posting?.posting_status)}">${esc(posting ? postingLabel(posting.posting_status) : state.gradePostingLoaded ? "No submitted result" : "Not checked")}</td>
        <td class="${student.expected_graduate_ind === "Y" ? "student-yes" : ""}">${yesNo(student.expected_graduate_ind)}</td>
        <td>${warnings}</td>
      </tr>`;
    }).join("");
    return `<div class="roster-student-heading">
      <h3>Full roster</h3>
      <span class="result-count">${students.length} student${students.length === 1 ? "" : "s"}</span>
    </div>
    <div class="table-wrap roster-student-table-wrap"><table class="roster-student-table">
      <thead><tr><th>Student</th><th>Eagle ID</th><th>Roster grade</th><th>Academic grade</th><th>Posting status</th><th>Expected graduate</th><th>Warnings</th></tr></thead>
      <tbody>${rows}</tbody>
    </table></div>`;
  }

  async function loadRosterStudents(row) {
    const rosterId = row.roster_id;
    if (state.rosterStudents.has(rosterId) || state.rosterStudentLoading.has(rosterId)) return;
    state.rosterStudentLoading.add(rosterId);
    state.rosterStudentErrors.delete(rosterId);
    render();
    try {
      const termCode = window.dashboardConfig.selectedTerm;
      const url = `/api/rosters/${encodeURIComponent(rosterId)}/students?term_code=${encodeURIComponent(termCode)}`;
      const response = await fetch(url, { headers: { "Accept": "application/json" } });
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(payload.detail || `Request failed (${response.status})`);
      state.rosterStudents.set(rosterId, Array.isArray(payload.students) ? payload.students : []);
    } catch (error) {
      state.rosterStudentErrors.set(rosterId, error.message || "Unknown error");
    } finally {
      state.rosterStudentLoading.delete(rosterId);
      render();
    }
  }

  function updatePostingCheckerUi() {
    const button = document.getElementById("run-posting-check");
    const status = document.getElementById("posting-check-status");
    if (!button || !status) return;
    button.disabled = state.gradePostingLoading;
    button.textContent = state.gradePostingLoading ? "Checking grades…" : state.gradePostingLoaded ? "Run posting checker again" : "Run grade posting checker";
    if (state.gradePostingError) {
      status.className = "error posting-check-status";
      status.textContent = `Grade posting check failed: ${state.gradePostingError}`;
    } else if (state.gradePostingLoading) {
      status.className = "muted posting-check-status";
      status.textContent = "Comparing submitted roster grades with academic records…";
    } else if (state.gradePostingLoaded) {
      const results = [...state.gradePostingByRosterRow.values()];
      const exceptions = results.filter(item => postingExceptions.has(item.posting_status)).length;
      status.className = "posting-check-status";
      status.textContent = `${results.length} submitted grades checked; ${exceptions} exception${exceptions === 1 ? "" : "s"} require review.`;
    } else {
      status.className = "muted posting-check-status";
      status.textContent = "Runs separately from the term load and compares submitted grades with the academic record.";
    }
  }

  async function runGradePostingCheck() {
    if (state.gradePostingLoading) return;
    state.gradePostingLoading = true;
    state.gradePostingError = "";
    updatePostingCheckerUi();
    try {
      const termCode = window.dashboardConfig.selectedTerm;
      const response = await fetch(`/api/grade-posting?term_code=${encodeURIComponent(termCode)}`, {headers:{"Accept":"application/json"}});
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(payload.detail || `Request failed (${response.status})`);
      const results = Array.isArray(payload.results) ? payload.results : [];
      state.gradePostingByRoster.clear();
      state.gradePostingByRosterRow.clear();
      results.forEach(result => {
        state.gradePostingByRosterRow.set(result.roster_row_id, result);
        const summary = state.gradePostingByRoster.get(result.roster_id) || {checked:0,exceptions:0,postedViaDuplicate:0,droppedOnly:0};
        summary.checked += 1;
        if (postingExceptions.has(result.posting_status)) summary.exceptions += 1;
        if (result.posting_status === "POSTED_VIA_DUPLICATE") summary.postedViaDuplicate += 1;
        if (result.posting_status === "DROPPED_ONLY") summary.droppedOnly += 1;
        state.gradePostingByRoster.set(result.roster_id, summary);
      });
      state.rows = state.rows.map(row => {
        const summary = state.gradePostingByRoster.get(row.roster_id) || {};
        return enrich({...row,grade_posting_checked_count:summary.checked || 0,grade_posting_exception_count:summary.exceptions || 0,grade_posted_via_duplicate_count:summary.postedViaDuplicate || 0,grade_posting_dropped_only_count:summary.droppedOnly || 0});
      });
      state.gradePostingLoaded = true;
    } catch (error) {
      state.gradePostingError = error.message || "Unknown error";
    } finally {
      state.gradePostingLoading = false;
      updatePostingCheckerUi();
      render();
    }
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
      <td title="Graded / expected graduates">${esc(row.expected_graduating_display)}</td>
      <td><span class="status ${statusClass(row.overall_status)}">${statusLabel(row.overall_status)}</span></td>
      <td>${esc(row.due_dt || "—")}</td>
      <td>${issuePills(row)}</td>
      <td><button type="button" class="button-secondary detail-toggle" data-roster-id="${esc(row.roster_id)}">${expanded ? "Close" : "Open"}</button></td>
    </tr>${expanded ? `<tr class="detail-row"><td colspan="11"><div class="detail-grid">
      <div><strong>Instructor ID(s)</strong><div class="technical">${esc(row.grader_ids || "Not assigned")}</div></div>
      <div><strong>Instructor count</strong><div>${number(row.instructor_count)}</div></div>
      <div><strong>Missing instructor emails</strong><div>${number(row.instructors_missing_email)}</div></div>
      <div><strong>Roster ID</strong><div class="technical">${esc(row.roster_id)}</div></div>
      <div><strong>Activity offering ID</strong><div class="technical">${esc(row.activity_offering_id)}</div></div>
      <div><strong>Roster type</strong><div class="technical">${esc(row.roster_type)}</div></div>
      <div><strong>Raw status</strong><div class="technical">${esc(row.roster_state)}</div></div>
      <div><strong>Completion</strong><div>${number(row.graded_count)} of ${number(row.roster_size)}</div></div>
      <div><strong>Expected graduates graded</strong><div>${number(row.expected_graduating_graded_count)} of ${number(row.expected_graduating_student_count)}</div></div>
      <div><strong>Expected-graduate source</strong><div>Current active or eligible graduate-discipline program-status expected-completion term</div></div>
      <div><strong>Roster graduate flag</strong><div>${number(row.has_grad_seniors_ind) ? "Yes" : "No"}</div></div>
      <div><strong>Source discrepancy</strong><div>${row.expected_graduating_discrepancy_ind === "Y" ? "Yes — roster flag is set but the calculated count is zero" : "No"}</div></div>
      <div><strong>Subterm code</strong><div>${esc(row.subterm_code)}</div></div>
      <div><strong>Submitted grades checked</strong><div>${state.gradePostingLoaded ? number(row.grade_posting_checked_count) : "Not run"}</div></div>
      <div><strong>Grade posting exceptions</strong><div>${state.gradePostingLoaded ? number(row.grade_posting_exception_count) : "Not run"}</div></div>
      <div><strong>Posted through alternate registration</strong><div>${state.gradePostingLoaded ? number(row.grade_posted_via_duplicate_count) : "Not run"}</div></div>
    </div><div class="roster-student-section">${rosterStudentMarkup(row)}</div></td></tr>` : ""}`;
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
    const expectedGradDiscrepancies = rows.filter(r => r.expected_graduating_discrepancy_ind === "Y").length;
    const postingExceptionCount = rows.reduce((total, row) => total + number(row.grade_posting_exception_count), 0);
    const postedViaDuplicate = rows.reduce((total, row) => total + number(row.grade_posted_via_duplicate_count), 0);
    const rate = rows.length ? Math.round(submitted / rows.length * 100) : 0;
    const set = (id, value) => { const el = document.getElementById(id); if (el) el.textContent = value; };
    set("metric-rosters", rows.length); set("metric-unique-sections", `${uniqueSections} unique sections`); set("metric-submitted", submitted); set("metric-submitted-rate", `${rate}% of visible rosters`); set("metric-partial", partial); set("metric-not-started", notStarted); set("metric-duplicate-rosters", duplicateRosters); set("metric-duplicate-students", duplicateStudents);
    set("health-duplicate-rosters", duplicateRosters); set("health-duplicate-students", duplicateStudents); set("health-overdue", overdue); set("health-zero", zero); set("health-missing-graders", missingGraders); set("health-missing-emails", missingEmails); set("health-expected-grad-discrepancies", expectedGradDiscrepancies); set("health-unique-sections", uniqueSections);
    set("metric-posting-exceptions", state.gradePostingLoaded ? postingExceptionCount : "—");
    set("health-posting-exceptions", state.gradePostingLoaded ? postingExceptionCount : "Not run");
    set("health-posted-via-duplicate", state.gradePostingLoaded ? postedViaDuplicate : "Not run");
    set("completion-label", `${submitted} of ${rows.length} rosters submitted (${rate}%)`);
    document.getElementById("completion-bar").style.width = `${rate}%`;
    document.querySelector(".progress-track").setAttribute("aria-valuenow", String(rate));
    set("visible-count", `${rows.length} visible roster${rows.length === 1 ? "" : "s"}`);
  }

  function render() {
    filterRows();
    tbody.innerHTML = state.filtered.length ? state.filtered.map(rowMarkup).join("") : '<tr><td colspan="11" class="empty-state">No rosters match the current filters.</td></tr>';
    updateMetrics();
  }

  function csvEscape(value) { const s = String(value ?? "").replace(/\s+/g," ").trim(); return /[",\n]/.test(s) ? `"${s.replace(/"/g,'""')}"` : s; }
  function downloadCsv() {
    const headers = ["Course / roster","Subterm","Subterm code","Instructor names","Instructor emails","Instructor IDs","Instructor count","Missing instructor emails","Roster size","Graded","Expected graduates","Expected graduates graded","Expected-graduate source","Roster graduate flag","Expected-graduate discrepancy","Submitted grades checked","Posting exceptions","Posted through alternate registration","Status","Due date","Problems","Roster ID","Activity offering ID","Roster type"];
    const rows = [headers, ...state.filtered.map(r => [r.course_name,r.subterm_name,r.subterm_code,r.instructor_names,r.instructor_emails,r.grader_ids,r.instructor_count,r.instructors_missing_email,r.roster_size,r.graded_count,r.expected_graduating_student_count,r.expected_graduating_graded_count,r.expected_graduating_count_source,r.has_grad_seniors_ind,r.expected_graduating_discrepancy_ind,r.grade_posting_checked_count,r.grade_posting_exception_count,r.grade_posted_via_duplicate_count,statusLabel(r.overall_status),r.due_dt,r.problem_text,r.roster_id,r.activity_offering_id,r.roster_type])];
    const blob = new Blob([rows.map(r => r.map(csvEscape).join(",")).join("\r\n")], {type:"text/csv;charset=utf-8"});
    const link = document.createElement("a");
    const subterm = document.getElementById("subterm_code").value;
    link.href = URL.createObjectURL(blob); link.download = `grading_rosters_${window.dashboardConfig.selectedTerm}${subterm ? "_" + subterm : ""}.csv`; link.click(); URL.revokeObjectURL(link.href);
  }

  document.addEventListener("input", event => { if (event.target.matches("#subterm_code,#global-search,#status-filter,#problem-filter,.column-filter")) render(); });
  document.addEventListener("click", event => {
    const detail = event.target.closest(".detail-toggle");
    if (detail) {
      const id = detail.dataset.rosterId;
      if (state.expanded.has(id)) {
        state.expanded.delete(id);
        render();
      } else {
        const row = state.rows.find(item => item.roster_id === id);
        state.expanded.add(id);
        render();
        if (row) loadRosterStudents(row);
      }
      return;
    }
    const sort = event.target.closest(".sort-button");
    if (sort) { const field = sort.dataset.sort; state.sortDirection = state.sortField === field && state.sortDirection === "asc" ? "desc" : "asc"; state.sortField = field; document.querySelectorAll(".sort-button").forEach(b => b.classList.remove("sort-asc","sort-desc")); sort.classList.add(state.sortDirection === "asc" ? "sort-asc" : "sort-desc"); render(); return; }
    const tab = event.target.closest(".tab-button[data-tab]");
    if (tab) { document.querySelectorAll(".tab-button[data-tab]").forEach(x=>x.classList.remove("active")); document.querySelectorAll(".tab-panel").forEach(x=>x.classList.remove("active")); tab.classList.add("active"); document.getElementById(tab.dataset.tab).classList.add("active"); return; }
    const metric = event.target.closest(".metric-filter");
    if (metric) { document.getElementById("status-filter").value = metric.dataset.status || ""; document.getElementById("problem-filter").value = metric.dataset.problem || ""; document.querySelector('[data-tab="sections-panel"]').click(); render(); }
  });
  document.getElementById("clear-filters").addEventListener("click", () => { ["subterm_code","global-search","status-filter","problem-filter"].forEach(id => document.getElementById(id).value = ""); document.querySelectorAll(".column-filter").forEach(x => x.value = ""); render(); });
  document.getElementById("download-csv").addEventListener("click", downloadCsv);
  document.getElementById("run-posting-check").addEventListener("click", runGradePostingCheck);
  updatePostingCheckerUi();
  render();
})();
